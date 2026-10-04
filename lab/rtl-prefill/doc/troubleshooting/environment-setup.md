# Environment Setup Troubleshooting

## Issue 1: `GLIBC_2.38 not found` when importing PyTorch

**Symptom:**
```
ImportError: /lib64/libc.so.6: version `GLIBC_2.38' not found
  (required by /nix/store/.../gcc-15.2.0-lib/lib/libstdc++.so.6)
```

**Root Cause:**
The `.envrc` adds Nix's gcc-15.2.0 `libstdc++.so.6` to `LD_LIBRARY_PATH`. This library was built against glibc 2.38, but the system glibc (`/lib64/libc.so.6`) is 2.34 (RHEL 9). You cannot mix glibc versions — adding Nix's glibc to `LD_LIBRARY_PATH` also fails with symbol errors.

**Fix:**
Remove `GCC_LIB_PATH` from the `LD_LIBRARY_PATH` export in `.envrc`. PyTorch bundles its own compatible `libstdc++`.

In `.envrc`, change:
```bash
export LD_LIBRARY_PATH="/run/opengl-driver/lib:${TORCH_LIB_PATH}:${GCC_LIB_PATH}:${ZLIB_LIB_PATH}:${LD_LIBRARY_PATH:-}"
```
to:
```bash
export LD_LIBRARY_PATH="/run/opengl-driver/lib:${TORCH_LIB_PATH}:${ZLIB_LIB_PATH}:${LD_LIBRARY_PATH:-}"
```

After editing, run `direnv reload` or open a new terminal.

---

## Issue 2: `ModuleNotFoundError: No module named 'plena_quant'`

**Symptom:**
```
ModuleNotFoundError: No module named 'plena_quant'
```

**Root Cause:**
The `PLENA_Tools` git submodule was not initialized. The directory exists but is empty.

**Fix:**
```bash
git submodule update --init --recursive
```

Then reinstall the editable packages:
```bash
rm .venv/.deps-installed
direnv reload
# Or manually:
uv pip install -e PLENA_Tools
uv pip install -e PLENA_Compiler
```

---

## Issue 3: `systolic_array.sv does not exist`

**Symptom:**
```
AssertionError: .../rtl/systolic_array.sv does not exist.
```

**Root Cause:**
The testbench `systolic_array_tb.py` referenced `module = "systolic_array"`, but the actual RTL file is named `mx_systolic_array.sv`.

**Fix:**
In `src/basic_components/systolic_gemm_mx/test/systolic_array_tb.py`, change:
```python
module = "systolic_array",
```
to:
```python
module = "mx_systolic_array",
```

---

## Quick Checklist for New Environment Setup

1. Install Nix and enable flakes
2. Clone the repo with submodules: `git clone --recurse-submodules <repo-url>`
3. Enter the directory (direnv will auto-setup if `direnv allow` has been run)
4. Verify: `python3 -c "import torch; print(torch.__version__)"`
5. Verify: `python3 -c "import plena_quant; print('ok')"`
