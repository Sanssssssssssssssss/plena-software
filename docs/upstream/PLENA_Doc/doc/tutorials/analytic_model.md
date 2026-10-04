# Tutorial 2 — Running the Analytic Model

This tutorial walks through running PLENA's **analytic performance model** —
the fast, closed-form estimator that reports time-to-first-token (TTFT) and
tokens-per-second (TPS) for a given LLM and hardware configuration without
running any cycle-level simulation.

Use it when you want to:

- Sweep thousands of `HardwareConfig` candidates in a DSE loop.
- Sanity-check a config before paying for transactional / RTL simulation.
- Compare two designs on the same workload in seconds.

> Background: see the [Analytic Model](../analytic_model.md) and
> [Design Space](../design_space.md) docs for what the model captures (and
> what it deliberately approximates).

---

## 1. Prerequisites

A working `PLENA_Simulator` install — see
[Getting Started — Section 2](../getting-started.md#2-setting-up-plena_simulator).
You do **not** need to build the Rust emulator for this tutorial; the
analytic model is pure Python.

```bash
cd PLENA_Simulator
direnv allow                # If you have not already
```

`plena_settings.toml` at the repo root provides the hardware parameters the
model reads. The analytic model looks at the `[ANALYTIC.*]` sections, so
make sure that section reflects the design point you want to evaluate (it
ships with sensible defaults — MLEN=2048, VLEN=2048, BLEN=128, HLEN=128).

---

## 2. List the model library

The analytic model is workload-driven: it needs a JSON description of the
LLM architecture. A library of pre-built ones ships in
`PLENA_Compiler/doc/Model_Lib/`.

```bash
python3 analytic_models/performance/llama_model.py \
    --list-models \
    --model-lib "$(pwd)/PLENA_Compiler/doc/Model_Lib"
```

You should see entries like:

```
Available models:
  estimated-llama-3.1-405b
  gpt-oss-20b
  llada-8b
  llama-3-8b
  llama-3.1-70b
  llama-3.1-8b
  llama-3.1-8b-w8a8
  llama-3.2-1b
  llama-3.3-70b
  qwen2_5_7b
  qwen3-32b
  smolvlm2-2.2b-text
  smolvlm2-2.2b-vision
```

---

## 3. Run TPS / TTFT for one workload

The `build-perf-model` recipe wraps the CLI with sensible defaults
(`batch=4`, `input_seq=2048`, `output_seq=1024`):

```bash
just build-perf-model llama-3.1-8b
```

Pass batch / sequence overrides positionally:

```bash
# just build-perf-model <model> [batch] [input_seq] [output_seq]
just build-perf-model llama-3.1-8b 1 4096 1024
just build-perf-model llama-3.2-1b 8 2048  512
```

Under the hood this calls:

```bash
python3 analytic_models/performance/llama_model.py \
    --model llama-3.1-8b \
    --batch-size 1 \
    --input-seq 4096 \
    --output-seq 1024 \
    --model-lib "$(pwd)/PLENA_Compiler/doc/Model_Lib" \
    --config "$(pwd)/plena_settings.toml" \
    --isa-lib "$(pwd)/analytic_models/performance/customISA_lib.json"
```

The output is a per-stage breakdown — prefill latency (→ TTFT), per-token
decode latency (→ TPS), and the contribution of each instruction class.

---

## 4. Interpreting the output

A typical run prints sections similar to:

```
Hardware:   MLEN=2048 VLEN=2048 BLEN=128 HLEN=128, HBM=...
Workload:   llama-3.1-8b, batch=1, input=4096, output=1024
Prefill:    <X> ms  →  TTFT = <X> ms
Decode:     <Y> ms / token  →  TPS = <1000/Y>
```

What to look at first:

- **TPS vs TTFT trade-off** — sweeping `MLEN` / `VLEN` typically shifts
  utilisation between prefill (compute-bound) and decode (memory-bound).
- **HBM prefetch / writeback budgets** — the `[ANALYTIC.CONFIG.HBM_*]`
  knobs in `plena_settings.toml` are usually the dominant lever for
  long-context decode TPS.
- **Per-instruction breakdown** — large `H_PREFETCH_*` time means the model
  is HBM-bound; large `M_MAC` time means it is systolic-bound.

For JSON output that is easy to post-process, add `--json` to the underlying
CLI (the `build-perf-model` recipe does not forward this; call the Python
script directly):

```bash
python3 analytic_models/performance/llama_model.py \
    --model llama-3.1-8b \
    --batch-size 1 --input-seq 4096 --output-seq 1024 \
    --model-lib "$(pwd)/PLENA_Compiler/doc/Model_Lib" \
    --config   "$(pwd)/plena_settings.toml" \
    --isa-lib  "$(pwd)/analytic_models/performance/customISA_lib.json" \
    --json --quiet
```

---

## 5. Swap workloads

```bash
just build-perf-model llama-3.1-70b      # Bigger model, same defaults
just build-perf-model llama-3.2-1b       # Smaller model, fast iteration
just build-perf-model qwen3-32b
just build-perf-model gpt-oss-20b
```

For **diffusion LLMs (LLaDA)**, use the dedicated flag and step count
(again calling the script directly since the just recipe does not expose
these):

```bash
python3 analytic_models/performance/llama_model.py \
    --model llada-8b \
    --llada --diffusion-steps 64 --seq-len 4096 \
    --batch-size 1 \
    --model-lib "$(pwd)/PLENA_Compiler/doc/Model_Lib" \
    --config   "$(pwd)/plena_settings.toml" \
    --isa-lib  "$(pwd)/analytic_models/performance/customISA_lib.json"
```

---

## 6. Sweep hardware configurations

The model reads `plena_settings.toml` on every invocation, so the simplest
sweep is to copy the file, edit the knobs you want to vary, and pass the
copy via `--config`:

```bash
cp plena_settings.toml /tmp/cfg_a.toml
# edit MLEN / VLEN / HBM_WIDTH in /tmp/cfg_a.toml

python3 analytic_models/performance/llama_model.py \
    --model llama-3.1-8b --batch-size 1 --input-seq 4096 --output-seq 1024 \
    --model-lib "$(pwd)/PLENA_Compiler/doc/Model_Lib" \
    --config   /tmp/cfg_a.toml \
    --isa-lib  "$(pwd)/analytic_models/performance/customISA_lib.json" \
    --json --quiet > /tmp/cfg_a_result.json
```

The knobs worth varying are listed in [Design Space](../design_space.md):

| Knob | Section in TOML | Effect |
|---|---|---|
| `MLEN`, `VLEN`, `BLEN`, `HLEN` | `[ANALYTIC.CONFIG.*]` | Systolic / vector dimensions. |
| `HBM_WIDTH`, `HBM_SIZE`, `HBM_*_Prefetch_Amount` | `[ANALYTIC.CONFIG.HBM_*]` | Off-chip bandwidth / capacity. |
| `MATRIX_SRAM_SIZE`, `VECTOR_SRAM_SIZE` | `[ANALYTIC.CONFIG.*_SRAM_SIZE]` | On-chip SRAM capacity. |
| `MATRIX_SRAM_TYPE`, `HBM_*_TYPE` precisions | `[ANALYTIC.PRECISION.*]` | Element / scale widths for MXFP / MXINT formats. |

For a closed-loop sweep, drive the same `LLaMAModel.run()` API
programmatically — that is exactly what `PLENA_Software`'s online DSE does
(see [Co-Design Toolchain](../co_design.md) and
[Getting Started — Section 4](../getting-started.md#wiring-plena_software-to-plena_simulator-online-dse)).

---

## 7. Custom models

If your architecture is not in `Model_Lib`, hand the script a JSON config
directly:

```bash
python3 analytic_models/performance/llama_model.py \
    --model-path /path/to/my_model.json \
    --batch-size 1 --input-seq 8192 --output-seq 1024 \
    --config "$(pwd)/plena_settings.toml" \
    --isa-lib "$(pwd)/analytic_models/performance/customISA_lib.json"
```

The JSON schema is small (hidden size, num layers, KV head counts, FFN
multiplier, vocab size). Copy any file under
`PLENA_Compiler/doc/Model_Lib/` as a template.

---

## 8. Task files for reproducible runs

For paper-style sweeps, define the workload in a task JSON and pass
`--task-file`:

```json
// /tmp/task_8b_4k.json
{
  "model": "llama-3.1-8b",
  "batch_size": 1,
  "input_seq": 4096,
  "output_seq": 1024,
  "device_num": 1
}
```

```bash
python3 analytic_models/performance/llama_model.py \
    --task-file /tmp/task_8b_4k.json \
    --model-lib "$(pwd)/PLENA_Compiler/doc/Model_Lib" \
    --config   "$(pwd)/plena_settings.toml" \
    --isa-lib  "$(pwd)/analytic_models/performance/customISA_lib.json"
```

---

## 9. Troubleshooting

**`--config is required for inference`**
You called the script without `--config` or `--isa-lib`. The just recipe
fills both in for you — prefer `just build-perf-model …` unless you need a
flag the recipe doesn't expose.

**Numbers look wildly off compared to RTL**
Check that `[MODE]` in `plena_settings.toml` is set the way you expect. The
analytic model reads `[ANALYTIC.*]`, the emulator reads `[TRANSACTIONAL.*]`;
they can disagree silently if you edited only one.

**Custom JSON model errors out on missing keys**
Compare your JSON against `llama-3.1-8b.json` — required fields include
`hidden_size`, `num_layers`, `num_heads`, `num_kv_heads`, `ffn_dim`, and
`vocab_size`.

---

## Next steps

- [Tutorial 1 — Running the Transactional Emulator](transactional_emulator.md)
  — get cycle-approximate numbers for the same configuration.
- [Tutorial 3 — Running an RTL Simulation](rtl_simulation.md) — confirm a
  shortlisted design against the SystemVerilog implementation.
- [Co-Design Toolchain](../co_design.md) — using the analytic model inside a
  Bayesian DSE loop.
- [Design Space](../design_space.md) — the parameter ranges PLENA typically
  sweeps.
