#!/usr/bin/env python3
from pathlib import Path
import sys
# Use 4 levels up, not 5
sys.path.insert(0, str(Path(__file__).parent.parent.parent.parent / "tools"))

import logging
import pytest
import cocotb
from cocotb.triggers import RisingEdge
from cocotb.clock import Clock
from cfl_cocotb import veri_runner
from cfl_cocotb.runner import SRC_PATH
from cfl_cocotb.fp_generation import FpGenerator

logger = logging.getLogger("testbench")
logger.setLevel(logging.INFO)

def pack_v(bus_elems, elem_width):
    """Pack list of element words [0..VLEN-1] into single int bus (lane 0 at LSB)."""
    v = 0
    mask = (1 << elem_width) - 1
    for i, w in enumerate(bus_elems):
        v |= (int(w) & mask) << (i * elem_width)
    return v

def unpack_v(bus, lanes, elem_w):
    mask = (1 << elem_w) - 1
    return [ (bus >> (i * elem_w)) & mask for i in range(lanes) ]

def pretty_list(xs):
    return "[" + ", ".join(f"{x:.6g}" if isinstance(x, float) else str(x) for x in xs) + "]"

@cocotb.test()
async def shift_vm_test(dut):
    cocotb.log.info("========== Vector Machine Shift Test ==========")

    # Match precision.svh and configuration.svh
    EXP, MANT, VLEN = 7, 8, 8
    ELEM_W = 1 + EXP + MANT
    gen = FpGenerator(EXP, MANT)

    # Clock and reset
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    dut.rst.value = 1
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)

    # Defaults
    dut.v_out_ready.value = 1
    dut.broadcast_fp2.value = 0
    dut.reduct_v_control.value = 0  # STALL_V_REDUCT

    # Config (match your precision/VLEN)
    EXP, MANT, VLEN = 7, 8, 8
    ELEM_W = 1 + EXP + MANT

    # Program writeback addr (optional)
    dut.result_waddr.value = 0
    dut.result_waddr_update.value = 1
    await RisingEdge(dut.clk)
    dut.result_waddr_update.value = 0

    # Prepare vector A [1..VLEN]
    vals = list(range(1, VLEN + 1))
    v_a_bus = pack_v(vals, ELEM_W)

    # Shift immediate (lanes)
    shift_amount = 2
    dut.s_wtarget.value = shift_amount

    # Issue SHIFT op: SHIFT_V_LANES_ELEMENT = 4'h8 = 8
    SHIFT_OP = 8
    dut.element_v_control.value = SHIFT_OP

    # Drive A for one cycle
    dut.v_a_in.value = v_a_bus
    dut.v_a_valid.value = 1
    await RisingEdge(dut.clk)
    dut.v_a_valid.value = 0

    # Deassert op back to STALL
    dut.element_v_control.value = 0

    # Wait up to N cycles for non-zero v_out
    got_packed = 0
    seen_nonzero = False
    when = -1
    MAX_WAIT = 32
    for t in range(MAX_WAIT):
        await RisingEdge(dut.clk)
        got = int(dut.v_out.value)
        if got != 0 and not seen_nonzero:
            got_packed = got
            seen_nonzero = True
            when = t  # cycles after deasserting v_a_valid
            # keep running a couple more cycles to mimic your waveform observation
    # If nothing seen, sample last value anyway
    if not seen_nonzero:
        got_packed = int(dut.v_out.value)

    # Expected shifted lanes
    expected = ([0] * shift_amount) + vals[:VLEN - shift_amount]
    actual = unpack_v(got_packed, VLEN, ELEM_W)

    cocotb.log.info(f"Observed v_out after {when if seen_nonzero else MAX_WAIT} cycles")
    cocotb.log.info(f"v_out (packed)=0x{got_packed:0{(VLEN*ELEM_W+3)//4}X}")
    cocotb.log.info(f"expected lanes: {expected}")
    cocotb.log.info(f"actual   lanes: {actual}")

    assert actual == expected, "Shift output mismatch"


@cocotb.test()
async def add_vv_latency_test(dut):
    """
    Measure RTL latency for ADD_V_ELEMENT (V_ADD_VV).
    Simulator predicts: V_ADD_VV pipelined = VECTOR_ADD_CYCLES = 1 cycle.
    """
    import cocotb.utils
    CLOCK_PERIOD_NS = 10  # 10ns clock
    EXP, MANT, VLEN = 7, 8, 8
    ELEM_W = 1 + EXP + MANT
    gen = FpGenerator(EXP, MANT)
    # VECTOR_ADD_CYCLES = 7 in RTL (configuration.svh, non-DC_LIB_EN mode)
    # V_ADD_VV pipelined = VECTOR_ADD_CYCLES = 7 for behavioral simulation
    SIM_PREDICTED_CYCLES = 7

    cocotb.log.info("========== V_ADD_VV Latency Test (RTL vs Simulator) ==========")

    cocotb.start_soon(Clock(dut.clk, CLOCK_PERIOD_NS, units="ns").start())
    dut.rst.value = 1
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)

    # Default signals
    if hasattr(dut, "broadcast_fp2"):    dut.broadcast_fp2.value = 0
    if hasattr(dut, "reduct_v_control"): dut.reduct_v_control.value = 0
    if hasattr(dut, "s_in"):             dut.s_in.value = 0
    if hasattr(dut, "s_in_valid"):       dut.s_in_valid.value = 0
    if hasattr(dut, "result_waddr"):        dut.result_waddr.value = 0
    if hasattr(dut, "result_waddr_update"): dut.result_waddr_update.value = 0
    if hasattr(dut, "v_out_ready"):      dut.v_out_ready.value = 1

    # Set ADD_V_ELEMENT = 4'h1 = 1
    dut.element_v_control.value = 1

    # Build input vectors A=[1..8], B=[1..8]
    vals_a = [float(i + 1) for i in range(VLEN)]
    vals_b = [float(i + 1) for i in range(VLEN)]
    _, enc_a = gen.generate_specified_value_fp_input(vals_a)
    _, enc_b = gen.generate_specified_value_fp_input(vals_b)
    v_a_bus = pack_v(enc_a[:VLEN], ELEM_W)
    v_b_bus = pack_v(enc_b[:VLEN], ELEM_W)

    dut.v_a_in.value = v_a_bus
    if hasattr(dut, "v_b_in"):
        dut.v_b_in.value = v_b_bus

    # Record start time and pulse valid
    start_ns = cocotb.utils.get_sim_time(units='ns')
    if hasattr(dut, "v_a_valid"):
        dut.v_a_valid.value = 1
    if hasattr(dut, "v_b_valid"):
        dut.v_b_valid.value = 1
    await RisingEdge(dut.clk)
    if hasattr(dut, "v_a_valid"):
        dut.v_a_valid.value = 0
    if hasattr(dut, "v_b_valid"):
        dut.v_b_valid.value = 0

    # Wait for element_v_out_valid
    rtl_cycles = None
    for cycle in range(1, 100):
        await RisingEdge(dut.clk)
        if hasattr(dut, "element_v_out_valid") and int(dut.element_v_out_valid.value) == 1:
            end_ns = cocotb.utils.get_sim_time(units='ns')
            rtl_cycles = (end_ns - start_ns) / CLOCK_PERIOD_NS
            break

    if rtl_cycles is not None:
        cocotb.log.info("=" * 60)
        cocotb.log.info(f"[LATENCY] V_ADD_VV (VLEN={VLEN}, EXP={EXP}, MANT={MANT})")
        cocotb.log.info(f"[LATENCY]   RTL measured cycles:      {rtl_cycles:.0f}")
        cocotb.log.info(f"[LATENCY]   Simulator prediction:     {SIM_PREDICTED_CYCLES}")
        cocotb.log.info(f"[LATENCY]   Match: {'YES' if abs(rtl_cycles - SIM_PREDICTED_CYCLES) <= 1 else 'NO (within 1 cycle tolerance)'}")
        cocotb.log.info("=" * 60)
    else:
        cocotb.log.error("[LATENCY] TIMEOUT: element_v_out_valid never asserted")


@pytest.mark.dev
def test_vector_machine():
    veri_runner(
        group="vector_machine",
        module="vector_machine",
        additional_include_paths=[
            str(SRC_PATH / "basic_components" / "buffer"),
            str(SRC_PATH / "basic_components" / "common"),
            str(SRC_PATH / "basic_components" / "fp_operation"),
            str(SRC_PATH / "basic_components" / "hadamard_transform"),
            str(SRC_PATH / "basic_components" / "synopsis_ip_inst"),
            str(SRC_PATH / "basic_components" / "conversion"),
            str(SRC_PATH / "basic_components" / "fixed_operation"),
            str(SRC_PATH / "basic_components" / "int_operation"),
            str(SRC_PATH / "basic_components" / "synopsis"),
            str(SRC_PATH / "basic_components" / "cast"),
        ],
        definitions_path=[str(SRC_PATH / "definitions")],
        trace=True,
    )

if __name__ == "__main__":
    test_vector_machine()