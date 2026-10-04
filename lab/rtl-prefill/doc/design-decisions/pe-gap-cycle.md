# Design Decision: One-Cycle Gap Between Dot Products in `mxint_default_pe`

**Date:** 2026-05-24
**Affected module:** `src/basic_components/systolic_gemm_mx/rtl/mxint_default_pe.sv`
**Affected downstream:** `mx_mini_systolic_array.sv` → `mx_systolic_array.sv` → `mx_systolic_mcu.sv`

## Background

The PE auto-completes a length-`ACC_DEPTH` dot product. When the final MAC settles into the accumulator:

- `out_valid` pulses high for **one cycle** (`acc_counter == ACC_DEPTH`)
- The same comb signal drives `fix_accumulator.clear_accumulator` to zero the accumulator
- `acc_counter` wraps to `0` at the next edge, ready for the next dot product

## The conflict

If a new MAC fires (`mac_fire_d == 1`) on the **same cycle** as `out_valid`, the `fix_accumulator` sees both `clear_accumulator=1` and `data_in_valid=1`. Inside `fix_accumulator`:

```systemverilog
always_ff @(posedge clk)
    if (rst || clear_accumulator) data_out <= '0;     // clear wins
    else if (data_in_valid)       data_out <= partial_sum;
```

The clear branch takes precedence — the incoming MAC is **discarded**, and the next dot product starts with one missing operand at position 0.

## The two options considered

### Option 1 (chosen): MCU inserts a gap cycle

The upstream driver / MCU is responsible for deasserting `system_top_valid` and `system_left_valid` for **at least one cycle** after `out_valid` pulses, before driving the next batch of `ACC_DEPTH` MACs.

**Pros:**
- Keeps `fix_accumulator` as a small, generic block (`clear` wins, single-purpose)
- Mirrors how the MCU already works: it owns scheduling between operations (M_MM → M_MM_WO), so inserting a gap is a natural extension
- Easier to reason about — every PE behaves identically without internal special cases
- Aligns with how PLENA's `mx_systolic_mcu` already counts `2 * COMPUTE_DIM + SYSTOLIC_PROCESSING_OVERHEAD` drain cycles between input cycles (gap-cycles are already part of the protocol)

**Cons:**
- Lose one cycle of throughput per dot product
- The MCU must know the PE's `ACC_DEPTH` to time the gap (parameter coupling)

### Option 2 (rejected): "load-on-clear" semantics in `fix_accumulator`

Modify `fix_accumulator` so `clear && data_in_valid` means "load `data_in` directly, ignoring previous `data_out`":

```systemverilog
if (rst) data_out <= '0;
else if (clear_accumulator && data_in_valid) data_out <= data_in;  // start fresh
else if (clear_accumulator)                  data_out <= '0;
else if (data_in_valid)                      data_out <= partial_sum;
```

**Pros:**
- Gap-free back-to-back streaming → 100% MAC throughput
- No coupling between MCU and PE's internal ACC_DEPTH timing

**Cons:**
- Changes `fix_accumulator` semantics (it's used by other modules too — needs careful review)
- Three-way priority in the always_ff is harder to verify
- Hides the dot-product boundary inside the PE — debugging gets harder when accumulation appears to "restart" without an obvious signal

## Decision

**Chosen: Option 1.** The MCU is the right place to manage temporal scheduling. PEs stay simple and uniform. The throughput loss is one cycle per `ACC_DEPTH`, which at the typical `ACC_DEPTH = 16` is a ~6% penalty — acceptable for the simplicity gained.

## Implementation contract

**Driver / MCU MUST guarantee:**
> For every cycle `T` where `out_valid == 1`, `system_top_valid` AND `system_left_valid` must remain low for at least cycle `T+1` (i.e., `mac_fire` low during cycle `T+1`, which means `mac_fire_d` low during cycle `T+2` — the cycle where `clear_accumulator` is asserted).

Equivalent simpler statement: **stop driving for one cycle whenever `out_valid` fires.**

## Verification

The current testbench (`mxint_default_pe_tb.py`) satisfies this naturally — it drives `K = ACC_DEPTH` MACs back-to-back, then stops driving and polls for `out_valid`. The stop-driving period covers the gap-cycle requirement.

When extending to multi-batch tests, ensure the test:
1. Drives `ACC_DEPTH` consecutive MACs
2. Waits for `out_valid` and samples `out_int`
3. Inserts at least one idle cycle (both valids deasserted) **before** the next batch begins
