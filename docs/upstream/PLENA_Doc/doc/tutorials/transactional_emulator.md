# Tutorial 1 — Running the Transactional Emulator

This tutorial walks through compiling a single ATen-style operator (a Linear
layer) all the way down to PLENA machine code and executing it on the Rust
**transactional emulator** that ships with [PLENA_Simulator](https://github.com/AICrossSim/PLENA_Simulator).

By the end you will have:

1. Generated PLENA ISA for `Y = X @ W` from a Python program.
2. Run it through the cycle-approximate emulator (with Ramulator / DRAMSys
   modelling off-chip HBM).
3. Compared the emulator output against a CPU golden reference.

> The emulator is **cycle-approximate**, not cycle-accurate. See the
> [Transactional Emulator](../transactional_emulator.md) page for what it
> does and does not model.

---

## 1. Prerequisites

You need a working `PLENA_Simulator` install (see [Getting Started — Section 2](../getting-started.md#2-setting-up-plena_simulator)).
Confirm the environment is live:

```bash
cd PLENA_Simulator
direnv allow                # If you have not already
just --list | head          # Should print the recipes from the justfile
```

The first time you enter the shell, the Rust crate is built. To pre-build
the emulator binary so the first run is faster:

```bash
(cd transactional_emulator && cargo build --release)
```

Make sure the `[MODE]` section of `plena_settings.toml` at the repo root is
set to `transactional` so the precision settings the testbench loads match
what the emulator expects:

```toml
[MODE]
active = "transactional"
```

---

## 2. Run the canonical Linear test

From the repo root:

```bash
just test-aten-linear
```

That single recipe drives the full flow shown below.

```
┌──────────────────────────┐   PLENA ISA   ┌────────────────────────────┐
│ linear_test.py           │ ─────────────▶│ transactional_emulator     │
│   • build CPU golden     │   memory      │   • Rust, cargo --release  │
│   • compile via          │   images      │   • Ramulator / DRAMSys    │
│     PlenaCompiler        │ ─────────────▶│   • dumps VRAM contents    │
└──────────────────────────┘               └──────────────┬─────────────┘
                                                          │
                                                          ▼
                                             ┌────────────────────────┐
                                             │ run_and_assert()       │
                                             │  numerical comparison  │
                                             └────────────────────────┘
```

### What `just test-aten-linear` actually does

Internally, the recipe runs
`transactional_emulator/testbench/aten/linear_test.py`, which:

1. Builds a random `(batch=64, in=128)` activation `X` and `(128, 256)`
   weight `W`.
2. Computes a CPU golden `Y = X @ W` via the `OpRegistry` set to
   `Backend.CPU`.
3. Switches the registry to `Backend.PLENA` and re-runs `ops.linear(prog, …)`
   — this dispatches to a PLENA-specific lowering that emits ISA into
   `PlenaCompiler`.
4. Writes the generated ASM, HBM image, FP/INT SRAM images and a
   `comparison_params.json` to
   `transactional_emulator/testbench/aten/build/linear/`.
5. Invokes the Rust emulator on those memory images via
   `run_and_assert(build_dir, "linear", mlen, blen)`, which compares the
   emulator's VRAM dump against the golden tensor.

A successful run ends with a numeric-match line and exit code 0.

---

## 3. Inspect the generated artefacts

After the run, look under
`transactional_emulator/testbench/aten/build/linear/`:

| File | Purpose |
|---|---|
| `generated_asm_code.asm` | Human-readable PLENA assembly produced by `PlenaCompiler.compile()`. |
| `generated_machine_code.mem` | Hex machine code loaded into the emulator's instruction memory. |
| `hbm_for_behave_sim.bin` | Initial HBM image (weights + activations packed in MX precision). |
| `fp_sram.bin`, `int_sram.bin` | Pre-initialised on-chip SRAM (FP constants + integer fast paths). |
| `comparison_params.json` | Tells `run_and_assert` where `Y` lives in VRAM and how to reshape it. |

To eyeball the ASM, open `generated_asm_code.asm` and look for
`H_PREFETCH_M` / `H_PREFETCH_V` / `M_MAC` / `H_STORE_V` — these are the
instruction classes the emulator schedules. The
[ISA Specification](../isa_spec.md) explains each one.

---

## 4. Run a different operator

Several other ATen-style operators are wired up the same way:

```bash
just test-aten-softmax           # fp variant softmax
just test-aten-rms-norm          # RMSNorm
just test-aten-layer-norm        # LayerNorm
just test-aten-ffn               # 2-layer FFN
just test-aten-flash-attention   # on-chip FlashAttention GQA
just test-aten-bmm               # batched matmul (direct-emit path)
just test-aten-rope              # RoPE position embedding
just test-aten-embedding-add     # token + position embedding add
just test-aten-conv2d            # 2D conv (sweeps several presets)
```

Each `*_test.py` follows the same three-phase structure: build CPU golden →
compile via `PlenaCompiler` → execute on the emulator and diff. Use them as
templates for new operators.

---

## 5. Run a full model on the emulator

For multi-layer / multi-step runs, use the unified driver:

```bash
# Compile-only (no emulation), useful to inspect ISA size
just aten-compile smollm2 --config sliced_64x64x16_b1

# Compile + emulate
just aten-emulate llada-8b   --config native_256x256x64_b1
just aten-emulate smolvlm2   --case vision-layers --layers 5
```

Model nicknames and per-model configs live under
`transactional_emulator/testbench/configs/` (YAML files). The driver picks
the right ASM templates, memory layout, and precision settings for the model
you ask for.

---

## 6. Run a low-level test that exercises the emulator directly

The `just build-emulator <arg>` recipe skips the compiler path and runs one
of the hand-written testbenches under
`transactional_emulator/testbench/`. It also dumps post-run memory:

```bash
just build-emulator <testbench_name>          # release, --quiet
just build-emulator-debug <testbench_name>    # verbose tracing
```

The recipe rebuilds the workload, calls the Rust binary with
`--opcode / --hbm / --fpsram / --intsram` pointing at the freshly generated
images, and finishes with `PLENA_Tools/verification/view_mem.py` so you can
read the result memory in tensor form.

---

## 7. Customising the run

- **Change the hardware sizes**: edit `plena_settings.toml` →
  `[TRANSACTIONAL.CONFIG.*]` (BLEN, MLEN, VLEN, HLEN, HBM geometry,
  per-instruction latencies). The testbench reloads these on every run.
- **Change the workload sizes**: each `*_test.py` reads its parameters via
  `gi("name", default)`. You can override defaults from the GUI or by
  editing the file.
- **Toggle MX format**: precision settings (MXFP vs MXINT, exponent / scale
  width) live under `[TRANSACTIONAL.PRECISION.*]` in `plena_settings.toml`.

---

## 8. Troubleshooting

**`error: linker 'cc' not found` or libtorch errors**
You are not inside the Nix shell. Run `direnv allow` from the repo root, or
`nix develop`.

**Test fails with a large numerical mismatch**
Re-run with `just build-emulator-debug linear` (substitute the workload
you're testing) to get cycle-by-cycle traces. Mismatches are usually caused
by precision settings in `plena_settings.toml` not matching what the
testbench expects.

**Cargo rebuilds from scratch every time**
The `build-emulator` recipe deletes `transactional_emulator/build` (the
workload outputs), not Cargo's `target/` cache. If `target/` is being wiped,
something is invalidating the build script — check that `LIBTORCH` /
`LIBTORCH_USE_PYTORCH` are still set after entering the shell.

---

## Next steps

- [Tutorial 2 — Running the Analytic Model](analytic_model.md) — the fast
  closed-form cost estimator for the same configurations.
- [Tutorial 3 — Running an RTL Simulation](rtl_simulation.md) — drive the
  full SystemVerilog design with the same workload.
- [Transactional Emulator](../transactional_emulator.md) — design rationale
  and what the emulator models.
- [ISA Specification](../isa_spec.md) — the instructions you see in
  `generated_asm_code.asm`.
