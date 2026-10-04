# Tutorial 3 — Running an RTL Simulation

This tutorial walks through driving PLENA's SystemVerilog implementation
with a real workload using **Verilator + cocotb**, courtesy of the
[PLENA_RTL](https://github.com/AICrossSim/PLENA_RTL) repository. By the end
you will have:

1. Generated a Linear workload (inputs, weights, ASM, machine code, golden
   tensor).
2. Elaborated the RTL with Verilator and driven it with a cocotb testbench.
3. Verified the RTL's HBM / VRAM dump against the golden reference.

> RTL simulation is **cycle-accurate** but **slow** — use it for sign-off on
> a small number of shortlisted designs, not for DSE. See
> [Tutorial 1](transactional_emulator.md) for the cycle-approximate
> alternative.

---

## 1. Prerequisites

A working `PLENA_RTL` install — see
[Getting Started — Section 3](../getting-started.md#3-setting-up-plena_rtl).
Verilator, Verible, cocotb 1.9.2, and the Python 3.12 stack should all be on
your `$PATH` after entering the dev shell:

```bash
cd PLENA_RTL
direnv allow                # If you have not already
verilator --version         # Sanity check: should print Verilator x.xxx
```

Optionally, run the basic floating-point unit testbenches first to confirm
the toolchain works end-to-end:

```bash
just test-hw                # FP partition / normalise / add / mult / recip / exp TBs
```

If those all pass, the `verilator + cocotb` plumbing is good and you can
move on to a full workload.

---

## 2. Run the canonical Linear simulation

From the repo root:

```bash
just rtl-sim linear
```

The first run takes several minutes because Verilator has to elaborate the
full design. Subsequent runs reuse the compiled simulator unless you pass
`rebuild=true`.

```
┌─────────────────────────┐    workload     ┌──────────────────────────┐
│ tools/testworkloads/    │ ──────────────▶ │ build/test/linear/       │
│   linear.py             │  inputs.bin     │  generated_machine_code  │
│   (generates ASM +      │  hbm.mem        │  fp_sram.mem             │
│    golden tensor)       │  golden_result  │  int_sram.mem            │
└─────────────────────────┘                 └─────────────┬────────────┘
                                                          │
                                                          ▼
                                            ┌──────────────────────────┐
                                            │ src/system/test/         │
                                            │   SimTop_tb.py (cocotb)  │
                                            │   + Verilator simulator  │
                                            └─────────────┬────────────┘
                                                          │ HBM / VRAM dump
                                                          ▼
                                            ┌──────────────────────────┐
                                            │ verification/            │
                                            │   verify_rtl_sim.py      │
                                            │   (diff vs golden)       │
                                            └──────────────────────────┘
```

A successful run prints:

```
Simulation Status: PASSED
...
Test Complete
Status: PASSED (simulation + verification)
```

---

## 3. What `just rtl-sim` actually does

The recipe is in three stages, all written to a per-workload build
directory (default `build/test/linear/`):

| Step | What runs | Output |
|---|---|---|
| 1 | `python -m tools.testworkloads.linear --build-dir <DIR>` | `inputs.bin`, `hbm.mem`, `fp_sram.mem`, `int_sram.mem`, `golden_result.pt`, `generated_machine_code.mem`, `generated_asm_code.asm`, `verification_params.json` (or `comparison_params.json`). |
| 2 | `python src/system/test/SimTop_tb.py --workload-dir <DIR>` | `sim.log`, `dump.vcd`, RTL-produced `hbm_result.mem` and `vector_result.mem`. |
| 3 | `python -m verification.verify_rtl_sim --workload-dir <DIR>` | PASS / FAIL diff against the golden tensor. |

The recipe sets several environment variables before invoking the cocotb
testbench so the SV memory initialisers can read the right files:

```text
WORKLOAD_DIR          = build/test/linear
FAKE_HBM_INIT_FILE    = build/test/linear/hbm.mem
INSTR_FILE            = build/test/linear/generated_machine_code.mem
FP_MEM_INIT_FILE      = build/test/linear/fp_sram.mem
INT_MEM_INIT_FILE     = build/test/linear/int_sram.mem
VECTOR_MEM_RESULT_FILE= build/test/linear/vector_result.mem
HBM_RESULT_FILE       = build/test/linear/hbm_result.mem
WAVES                 = 1
SIMTOP_TRACE          = 1
SKIP_BUILD            = 0   # set to 1 to reuse Verilator cache
```

Knowing this is useful when you want to bypass the recipe and run the
testbench directly (e.g. from a debugger).

---

## 4. Reuse the Verilator build

Verilator elaboration is the bottleneck. Pass `false` (or `0` / `no`) for
the `rebuild` argument to skip it:

```bash
just rtl-sim linear false                      # Reuse cached RTL build
just rtl-sim linear false --batch 16           # …and pass workload args
```

Anything after the `rebuild` flag is forwarded verbatim to the workload
generator, so you can resize the problem without rebuilding the simulator:

```bash
just rtl-sim linear false --batch 8 --in-features 256 --out-features 512
```

For the **bmm** (batched matmul) workload:

```bash
just rtl-sim bmm                               # Default sizes, rebuild
just rtl-sim bmm false --batch 8               # Custom batch, no rebuild
```

Workload generators live under `tools/testworkloads/`. Each `*.py` exposes
its own `argparse` interface (`--batch`, `--in-features`, `--seed`,
`--mx-format`, etc.); run e.g. `python -m tools.testworkloads.linear --help`
to see the full surface.

---

## 5. Inspect the artefacts

After a run, `build/test/linear/` contains everything needed to debug:

| File | Use |
|---|---|
| `generated_asm_code.asm` | Human-readable ASM that drives the simulation. |
| `generated_machine_code.mem` | Hex machine code loaded into the instruction memory. |
| `hbm.mem` | Initial HBM image (weights + activations packed per `precision.svh`). |
| `hbm_result.mem`, `vector_result.mem` | Memory dumps taken at simulation end. |
| `golden_result.pt` | Torch tensor of the expected result. |
| `verification_params.json` / `comparison_params.json` | Tells the verifier where the result lives and how to reshape it. |
| `dump.vcd` | Waveform — open with GTKWave / Surfer for cycle-level debugging. |
| `sim.log` | cocotb / Verilator stdout. |

To replay verification on an existing build without re-simulating:

```bash
python -m verification.verify_rtl_sim --workload-dir build/test/linear --verbose
```

---

## 6. Customise the hardware configuration

PLENA_RTL is parameterised at elaboration time. The two places to edit are:

- `src/definitions/configuration.svh` — `MLEN`, `BLEN`, `VLEN`, `HLEN`,
  SRAM / HBM sizes. The workload generator reads tile sizes from here via
  `plena_utils.load_hardware_tile_sizes`, so the test stays consistent with
  the RTL.
- `src/definitions/precision.svh` — MXFP / MXINT element + scale widths.

After editing either file, run with `rebuild=true` (the default) so
Verilator re-elaborates:

```bash
just rtl-sim linear true       # Force rebuild after editing *.svh
```

The repo-level `plena_settings.toml` mirrors the same knobs for tooling
that doesn't go through the SV headers (e.g. ASM-template precision
loading). Keep the two in sync if you change defaults.

---

## 7. View waveforms

Each run emits `dump.vcd` (enabled via `WAVES=1` / `SIMTOP_TRACE=1`):

```bash
gtkwave build/test/linear/dump.vcd
# or, if you prefer surfer / wavetools:
surfer build/test/linear/dump.vcd
```

The top of the design hierarchy is `SimTop` — start there, then drill into
`u_plena_core` for the systolic array / vector unit signals.

---

## 8. Synthesis (optional)

If you have Synopsys Design Compiler on the host, the same repo can
synthesise individual modules:

```bash
just synth fp_adder                # Default 1000 ps clock, normal compile
just synth fp_adder 500 ultra      # 500 ps target clock, compile_ultra
just synth-report fp_adder         # Show latest build's summary
```

See [Getting Started — Section 3](../getting-started.md#3-setting-up-plena_rtl)
for the `synopsys_env` path you may need to update in `justfile`.

---

## 9. Clean up

```bash
just rtl-sim-clean linear              # Remove build/test/linear
just rtl-sim-clean '' true             # Remove ALL build/test/*
```

Verilator's `obj_dir/` cache inside the per-workload build directory is
also wiped when you re-run with `rebuild=true`.

---

## 10. Troubleshooting

**`verilator: command not found`**
You are not inside the Nix shell. Run `direnv allow` (or `nix develop`)
from `PLENA_RTL` first.

**`No verification params found, skipping verification`**
The workload generator did not produce a `verification_params.json` /
`comparison_params.json`. That happens for workloads that do not yet have a
golden-reference comparator wired up — the simulation itself still runs;
inspect `sim.log` and `hbm_result.mem` manually.

**RTL simulation times out**
Increase the cocotb timeout in `src/system/test/SimTop_tb.py`, or shrink
the workload (`--batch 1 --in-features 64 --out-features 64`) while you
debug.

**Numerical mismatch against golden**
Open `generated_asm_code.asm` and confirm the ASM matches what you expect.
A small mismatch (last-bit) is usually a precision-rounding difference
between the CPU golden path and the RTL's MX-format arithmetic — re-check
`precision.svh` vs the workload generator's MX format settings.

**Submodules out of date**
The simulator's `.envrc` auto-pulls `PLENA_Compiler` and `PLENA_Tools`
unless you set `PLENA_AUTO_UPDATE_COMPILER=0` / `PLENA_AUTO_UPDATE_TOOLS=0`.
If the test fails immediately on ASM template imports, force a pull:

```bash
git submodule update --remote --merge
```

---

## Next steps

- [Tutorial 1 — Running the Transactional Emulator](transactional_emulator.md)
  — same workload at ~100× the speed.
- [Tutorial 2 — Running the Analytic Model](analytic_model.md) — closed-form
  cost estimates for the same hardware configuration.
- [Compiler](../compiler.md) — how the ASM you see in `generated_asm_code.asm`
  is produced.
- [Hardware Configuration](../hardware_config.md) — the full schema of
  `configuration.svh` / `precision.svh`.
