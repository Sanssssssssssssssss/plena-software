#!/usr/bin/env bash
# Linux/WSL：bash study/run_rtl.sh
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
if [[ -f "$ROOT/.venv-wsl/bin/activate" ]]; then
    source "$ROOT/.venv-wsl/bin/activate"
elif [[ -f "$ROOT/.venv/bin/activate" ]]; then
    source "$ROOT/.venv/bin/activate"
else
    echo "Create a Linux Python environment first; see docs/SETUP.md" >&2
    exit 1
fi
WHEEL_ROOT=$(python -c 'import sysconfig; print(sysconfig.get_paths()["purelib"] + "/verilator")')
if [[ -x "$WHEEL_ROOT/bin/verilator" ]]; then
    export VERILATOR_ROOT="$WHEEL_ROOT"
    export PATH="$VERILATOR_ROOT/bin:$PATH"
fi
# PyPI 5.34.0 wheel 的 make 配置遗漏 GCC 预编译头前缀；仅本次 make 补齐。
export MAKEFLAGS="-j4 CFG_CXXFLAGS_PCH_I=-include"
export VERILATOR_JOBS=4 SIMTOP_TRACE=0
export PYTHONPATH="$ROOT/lab/rtl-prefill/tools:$ROOT/lab/rtl-prefill/PLENA_Tools:$ROOT/lab/rtl-prefill/PLENA_Compiler"
cd "$ROOT/lab/rtl-prefill"
mkdir -p "$ROOT/study/logs"
# 工作副本来自快照的 tracked files；旧 build 产物没有带过来。
# 先移除本脚本的旧结果，避免本次构建中断后误读上次 PASS。
python -c 'from pathlib import Path; Path("src/vector_machine/test/build/softmax_row_engine_test_wrapper/test_0/results.xml").unlink(missing_ok=True)'
python src/vector_machine/test/softmax_row_engine_tb.py > "$ROOT/study/logs/rtl-softmax.log" 2>&1
# 原 runner 可能打印 Failed 后仍返回 0，必须检查真正的 cocotb XML。
python - <<'PY'
from pathlib import Path
import xml.etree.ElementTree as ET
p = Path('src/vector_machine/test/build/softmax_row_engine_test_wrapper/test_0/results.xml')
tests = list(ET.parse(p).iter('testcase'))
assert tests and all(t.find('failure') is None and t.find('error') is None for t in tests), p
print(f'RTL softmax: {len(tests)} tests PASS')
PY
