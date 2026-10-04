# Getting Started

This page walks through setting up the three repositories that make up the
PLENA toolchain on a fresh machine, and then verifying that the installation
works end-to-end.

| Repository | What it contains | Primary language |
|---|---|---|
| [**PLENA_Simulator**](https://github.com/AICrossSim/PLENA_Simulator) | Transactional (cycle-approximate) emulator, analytic latency / utilisation models, and the model-driven compile/emulate harness. | Rust + Python 3.12 |
| [**PLENA_RTL**](https://github.com/AICrossSim/PLENA_RTL) | SystemVerilog RTL for the accelerator, Verilator/cocotb testbenches, and the Synopsys synthesis flow. | SystemVerilog + Python 3.12 |
| [**PLENA_Software**](https://github.com/AICrossSim/PLENA_Software) | Quantisation + accuracy-evaluation toolkit for MX-quantised LLMs, plus the online Bayesian-optimisation DSE driver that calls into PLENA_Simulator. | Python ≥ 3.11.9 |

`PLENA_Simulator` and `PLENA_RTL` share the same two submodules —
[`PLENA_Compiler`](https://github.com/AICrossSim/PLENA_Compiler) and
[`PLENA_Tools`](https://github.com/AICrossSim/PLENA_Tools) — and both are
provisioned through a Nix flake driven by `direnv`. `PLENA_Software` is
standalone (no Nix dependency) and uses `uv` to manage a plain Python
virtual environment.

Pick the subset you need:

- **Just running inference simulations / design-space exploration** →
  `PLENA_Simulator` alone is enough.
- **Hardware verification or synthesis** → also install `PLENA_RTL`.
- **Quantisation accuracy sweeps, paper-table reproductions, or online
  hardware DSE driven by accuracy + simulator feedback** → also install
  `PLENA_Software`.

---

## 1. Prerequisites

Install these once on your host machine.

### Required for PLENA_Simulator and PLENA_RTL

- **[Nix package manager](https://nixos.org/download)** with flakes enabled.
  After installing, add the following to `~/.config/nix/nix.conf` (or
  `/etc/nix/nix.conf` for a multi-user install):

  ```
  experimental-features = nix-command flakes
  ```

- **[direnv](https://direnv.net/)** — drives automatic environment activation
  when you `cd` into either repository. After installing, hook it into your
  shell:

  ```bash
  # bash
  echo 'eval "$(direnv hook bash)"' >> ~/.bashrc
  source ~/.bashrc

  # zsh
  echo 'eval "$(direnv hook zsh)"' >> ~/.zshrc
  source ~/.zshrc
  ```

- **Git** with submodule support (any modern version).

### Required only for PLENA_Simulator's Docker path

- **Docker Engine** with the Compose plugin (`docker compose`).
- *(Optional)* **NVIDIA Container Toolkit** if you want GPU support inside the
  container.

### Required only for PLENA_RTL synthesis

- **Synopsys Design Compiler** (`dc_shell`). The repository's `justfile`
  defaults to sourcing `SYN_2024.09-SP2_RHELx86.sh`; edit the `synopsys_env`
  variable in `justfile` if your install lives elsewhere.

### Required only for PLENA_Software

- **Python ≥ 3.11.9** on the host (the repo's `pyproject.toml` enforces this
  lower bound — older Python releases will fail `uv sync`).
- **[uv](https://github.com/astral-sh/uv)** for environment and dependency
  management. PLENA_Software does *not* use Nix.
- **A CUDA-capable GPU** is strongly recommended; quantisation and PPL
  evaluation run on GPU by default. PyTorch is pinned to the cu128 wheel
  index.

> The Nix flake brings in everything else automatically for PLENA_Simulator
> and PLENA_RTL: Rust toolchain, Verilator, Verible, Python 3.12, clang/LLVM,
> cmake, ninja, just, uv, etc. You do **not** need to install these on the
> host.

---

## 2. Setting up PLENA_Simulator

There are two supported workflows. **Option A (Nix + direnv)** is the
recommended path for day-to-day development. **Option B (Docker)** wraps the
exact same Nix environment in a container, which is useful when you cannot or
do not want to install Nix on the host.

### Option A — Native Nix + direnv

```bash
# 1. Clone with submodules
git clone --recurse-submodules https://github.com/AICrossSim/PLENA_Simulator.git
cd PLENA_Simulator

# 2. Allow direnv to load the environment for this directory
direnv allow
```

The first `direnv allow` triggers `.envrc`, which will:

1. Enter the Nix dev shell (`use flake`), provisioning Rust, Python 3.12,
   clang, cmake, ninja, just, uv, etc.
2. Create a `.venv/` virtual environment with `uv` (Python 3.12).
3. `uv sync` the dependencies declared in `pyproject.toml` and install the
   project in editable mode.
4. Wire `PYTHONPATH` to include `PLENA_Tools/` so `plena_quant` /
   `plena_utils` are importable.
5. Point `LD_LIBRARY_PATH` at the PyTorch shared libraries inside `.venv`
   (`tch-rs` / `torch-sys` reuses them via `LIBTORCH_USE_PYTORCH=1`).
6. Run the `.githooks/check-compiler` and `.githooks/check-tools` freshness
   checks against the submodules.

The initial run downloads ~1–2 GB (libtorch, PyTorch wheel, Rust crates) and
typically takes 5–15 minutes. Subsequent shell entries are near-instant
because the venv is cached behind the `.venv/.deps-installed` marker file.

If you ever need to enter the shell without direnv (for example, in a CI
job), use:

```bash
nix develop
git submodule update --init --recursive
uv sync && uv pip install -e .
```

### Option B — Docker

The Docker image bundles the same Nix flake, so the only host requirement is
Docker. Your working tree is bind-mounted at `/workspace`, so edits on the
host are picked up live inside the container.

```bash
git clone --recurse-submodules https://github.com/AICrossSim/PLENA_Simulator.git
cd PLENA_Simulator

# Build the dev image, start it, and drop into a shell
just docker-dev
```

`just docker-dev` is equivalent to:

```bash
docker compose -f docker/docker-compose.yml build dev
docker compose -f docker/docker-compose.yml up -d dev
docker compose -f docker/docker-compose.yml exec dev bash
```

Inside the container, initialise submodules and pre-build the Rust emulator
once (these artefacts persist on the host through the bind mount):

```bash
git submodule update --init --recursive
(cd transactional_emulator && cargo build --release)
```

You can also run one-off commands without an interactive shell:

```bash
just docker-run bash -c "just latency llama-3.1-8b"
just docker-test test-aten-linear
```

For GPU workloads, use the `cuda` Compose profile (requires NVIDIA Container
Toolkit on the host):

```bash
docker compose -f docker/docker-compose.yml --profile cuda up -d dev-cuda
docker compose -f docker/docker-compose.yml exec dev-cuda bash
```

!!! note "Bind-mount ownership"
    The repository is owned by your host user, but the container runs as
    `root`. The image marks `/workspace` as a git `safe.directory`, so Nix's
    flake evaluator does not reject it with a dubious-ownership error. Keep
    that setting if you build a custom image on top of the provided one.

### Verifying the PLENA_Simulator install

From inside the Nix shell (Option A) or the dev container (Option B), run
the lightweight ATen-style operator tests:

```bash
just test-sw                    # Quant utilities round-trip on CPU
just test-aten-linear           # Compile + emulate a linear layer end-to-end
just latency-list-models        # Lists the analytic-model model registry
just latency llama-3.1-8b       # Analytic TTFT / TPS for the default config
```

If all four succeed, the toolchain is wired up correctly.

---

## 3. Setting up PLENA_RTL

PLENA_RTL uses the same Nix-flake + direnv pattern as the simulator. The dev
shell exposes Verilator, Verible, clang/LLVM (with both the default and
LLVM 14 toolchains for synthesis flow compatibility), graphviz, and the
Python 3.12 stack that cocotb testbenches need.

### Quick start (direnv)

```bash
git clone --recurse-submodules https://github.com/AICrossSim/PLENA_RTL.git
cd PLENA_RTL
direnv allow
```

The `.envrc` performs the same steps as the simulator's, with two
differences:

- It pulls in **cocotb 1.9.2** (with `[bus]` extras), `bitstring`, and
  `colorlog` directly via `uv pip install` rather than `uv sync` — the
  RTL repo does not use `pyproject.toml` for dependency resolution yet.
- After setting up the venv, it `git fetch`-es each submodule (`PLENA_Compiler`,
  `PLENA_Tools`) against `origin/main` and automatically `git pull`s any that
  are behind. To suppress this, set `PLENA_AUTO_UPDATE_COMPILER=0` /
  `PLENA_AUTO_UPDATE_TOOLS=0` in your shell.

### Manual install (without direnv)

If you cannot use direnv (for example, in a CI runner), reproduce the same
steps explicitly:

```bash
nix develop                              # Enter the dev shell

python3.12 -m venv .venv
source .venv/bin/activate

pip install torch==2.7.1+cu126 \
    --extra-index-url https://download.pytorch.org/whl/cu126
pip install numpy "cocotb[bus]==1.9.2" bitstring colorlog toml \
    tqdm pytest transformers matplotlib

pip install -e .
pip install -e PLENA_Tools
pip install -e PLENA_Compiler
```

### Verifying the PLENA_RTL install

The unit testbenches under `src/basic_components/fp_operation/test/` exercise
the floating-point primitives through Verilator + cocotb:

```bash
just test-hw     # Runs the FP partition / normalise / add / mult / exp / recip TBs
just test-sw     # Pure-Python sqrt / reciprocal reference tests
```

To run a full workload through the RTL simulator (generates a workload,
elaborates the design, and drives it with cocotb):

```bash
just rtl-sim linear              # Default batch=8, in=128, out=256
just rtl-sim linear false        # Reuse cached Verilator build
just rtl-sim bmm false --batch 8 # Custom workload args
```

Synthesis is gated behind your local Synopsys install. Once `dc_shell` is on
the PATH:

```bash
just synth fp_adder               # Default 1000 ps clock, normal compile
just synth fp_adder 500 ultra     # 500 ps target, compile_ultra
just synth-report fp_adder        # Show the latest build's summary
```

---

## 4. Setting up PLENA_Software

PLENA_Software is the quantisation + accuracy-evaluation half of the
toolchain. It is also the entry point for **online hardware DSE** — the
Bayesian-optimisation loop that proposes new `HardwareConfig` candidates and
scores them in-process via PLENA_Simulator's analytic `LLaMAModel`.

Unlike the other two repositories, PLENA_Software does **not** use Nix or
direnv. The install is a plain `uv venv` + `uv sync`.

### Quick start

```bash
git clone https://github.com/AICrossSim/PLENA_Software.git
cd PLENA_Software

uv venv                          # Python ≥ 3.11.9
source .venv/bin/activate
uv sync                          # Core deps: mase[mx-ptq], lm-eval, transformers, ...
```

`uv sync` honours the `[tool.uv.sources]` pins in `pyproject.toml`, which
fetch:

- **`mase[mx-ptq]`** from the `releases/plena-experiments` branch of
  `DeepWok/mase` — the quantisation framework that provides
  `quantize_module_transform_pass`, GPTQ, and rotation search.
- **`fast-hadamard-transform`** as a transitive git dependency, built with
  `no-build-isolation` (required by the upstream package).
- **PyTorch** from the `pytorch-cu128` index.

### Optional extras

The `[project.optional-dependencies]` table exposes several extras. Add the
ones you need:

```bash
uv sync --extra docs       # mkdocs-material + mkdocstrings for local doc builds
uv sync --extra evalplus   # evalplus + stop-sequencer for HumanEval+/MBPP+
uv sync --extra serve      # fastapi + uvicorn for the eval server
uv sync --extra bfcl       # Berkeley Function Calling Leaderboard harness
uv sync --extra dse        # botorch + gpytorch for online hardware DSE
uv sync --all-extras       # Everything at once
```

### Verifying the PLENA_Software install

Run a single MXFP4-quantised perplexity evaluation on Llama-3.2-1B. This is
the canonical end-to-end smoke test from the repo's own getting-started
guide and should complete in roughly a minute on a single GPU:

```bash
cat > /tmp/quickstart.toml <<'TOML'
by = "regex_name"

["model\\.layers\\.\\d+\\.self_attn\\.(q|k|v|o)_proj"]
name = "mxfp"
weight_block_size = 32
weight_exponent_width = 2
weight_frac_width = 1
data_in_block_size = 32
data_in_exponent_width = 2
data_in_frac_width = 1

["model\\.layers\\.\\d+\\.mlp\\.(gate|up|down)_proj"]
name = "mxfp"
weight_block_size = 32
weight_exponent_width = 2
weight_frac_width = 1
data_in_block_size = 32
data_in_exponent_width = 2
data_in_frac_width = 1
TOML

python -m quant_eval.cli.eval_ppl \
    --model_name unsloth/Llama-3.2-1B \
    --quant_config /tmp/quickstart.toml \
    --device_id cuda:0
```

A successful run ends with a `ppl: …` line — that number is the model's
WikiText perplexity under the configured MXFP4 weight + activation
quantisation.

### Wiring PLENA_Software to PLENA_Simulator (online DSE)

The DSE driver runs a Gaussian-process + Expected-Improvement loop over the
nine PLENA `HardwareConfig` knobs (`BLEN`, `MLEN`, `VLEN`, `HLEN`, vector
SRAM, HBM size / width / prefetch) and maximises TPS for a given workload by
calling `LLaMAModel.run()` in-process. Because the upstream `PLENA_Simulator`
has historically had broken Git submodules, the simulator is **imported via
`sys.path` injection**, not pip-installed. Clone it as a *sibling* of
`PLENA_Software`:

```bash
# From the parent directory that holds PLENA_Software/
git clone --recurse-submodules https://github.com/AICrossSim/PLENA_Simulator.git
```

Then, with `--extra dse` synced and the simulator cloned, launch:

```bash
python plena_experiments/online_dse/scripts/online_dse_gp_ei.py \
    plena_experiments/online_dse/configs/dse_llama3_8b.json
```

Results land under `results/online_dse/{cache.json, results.json}` (override
with `--cache PATH` / `-o PATH`). See
`plena_experiments/online_dse/README.md` inside the repository for the full
config schema.

### Paper-reproduction bundles

The `plena_experiments/` directory ships runnable bundles that reproduce
each headline result table from the paper:

- `plena_experiments/table5/` — main quantisation sweep (Llama-2 / Llama-3
  across three bit configs).
- `plena_experiments/table6/` — component-level ablations.
- `plena_experiments/table7/` — downstream task accuracy.

Each subdirectory contains shell scripts that drive the `quant_eval` CLIs
end-to-end.

---

## 5. Configuration

Both `PLENA_Simulator` and `PLENA_RTL` read hardware parameters from a
TOML file (`plena_settings.toml` at the repository root of each project).
The file selects an active mode and exposes one section per mode:

- `analytic` — used by the latency and utilisation models.
- `transactional` — used by the Rust transactional emulator and the RTL
  testbenches.

Switch modes by editing the `[MODE]` section. Each section then exposes:

- Hardware dimensions: **MLEN, BLEN, VLEN, HLEN**.
- Memory geometry: HBM channels, SRAM sizes, prefetch / writeback budgets.
- Per-instruction latencies, used by both the analytic latency model and the
  emulator's scheduler.

See [Hardware Configuration](hardware_config.md) for the full schema and
[Design Space](design_space.md) for the parameter ranges we typically sweep.

---

## 6. Common next steps

Once you can run `just test-aten-linear` (simulator), `just test-hw` (RTL),
or `python -m quant_eval.cli.eval_ppl` (software), the rest of the
documentation is the right place to go deeper:

- [Transactional Emulator](transactional_emulator.md) — what the emulator
  models and how to extend it.
- [Analytic Model](analytic_model.md) — the closed-form latency / utilisation
  estimators.
- [Compiler](compiler.md) — direct-mapping vs ATen-based lowering flows.
- [Accuracy Evaluator](accuracy_evaluator.md) — quantisation + PPL / task
  evaluation flows that live in PLENA_Software.
- [ISA Specification](isa_spec.md) — the instruction set the emulator and
  RTL both implement.
- [Co-Design Toolchain](co_design.md) — driving the DSE inner loop, including
  the online GP+EI DSE that bridges PLENA_Software and PLENA_Simulator.

---

## 7. Troubleshooting

**`direnv: error .envrc is blocked.`**
You need to explicitly trust the file after each significant change to it.
Run `direnv allow` from the repository root.

**`error: experimental Nix feature 'flakes' is disabled`**
Add `experimental-features = nix-command flakes` to your Nix config (see
[Prerequisites](#1-prerequisites)).

**`fatal: detected dubious ownership in repository at '/workspace'`**
You are inside the dev container and the bind-mounted tree is owned by your
host user. The provided Dockerfile already writes `/root/.gitconfig` with the
right `safe.directory` entry; if you customised the image, replicate that.

**Submodules look stale / `PLENA_Compiler is behind remote`**
The simulator's `.envrc` only checks freshness; it does not auto-pull unless
you set `PLENA_AUTO_UPDATE_COMPILER=1`. The RTL repo's `.envrc` does
auto-pull by default — set `PLENA_AUTO_UPDATE_COMPILER=0` to disable it.
You can always pull manually with:

```bash
git submodule update --remote --merge
```

**Rust build can't find `libtorch`**
The simulator's flake pins a libtorch derivation and exports `LIBTORCH=` for
`cargo build`. If you are building outside the Nix shell, set
`LIBTORCH_USE_PYTORCH=1` so `tch-rs` borrows the libtorch shipped with the
Python `torch` wheel, and make sure
`.venv/lib/python3.12/site-packages/torch/lib` is on `LD_LIBRARY_PATH`.

**PLENA_Software's online DSE can't find PLENA_Simulator**
The DSE driver imports `LLaMAModel` via `sys.path` injection rather than
through pip, so `PLENA_Simulator` must be cloned as a **sibling directory**
of `PLENA_Software` (i.e. `../PLENA_Simulator`). If you cloned it elsewhere,
either symlink it into place or edit the path injection in
`plena_experiments/online_dse/scripts/online_dse_gp_ei.py`.

**`uv sync` fails on `fast-hadamard-transform`**
This package is pulled transitively as a git dependency and must be built
with `no-build-isolation` — which the repo's `[tool.uv]` table already sets.
If the build still fails, make sure you have a working C / CUDA toolchain on
the host (`gcc`, matching `nvcc` for your PyTorch CUDA version) before
re-running `uv sync`.
