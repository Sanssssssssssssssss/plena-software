r"""复跑 CPU 入门链：数学核对、编译器测试、Linear 产物、解析模型。
命令：.venv\Scripts\python.exe study\run_cpu.py
"""
from pathlib import Path
import json
import os
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
RTL = ROOT / "PLENA/PLENA_RTL"
SIM = ROOT / "PLENA/PLENA_Simulator"
LOG = ROOT / "study/logs"
OUT = ROOT / "study/runs/linear"
env = dict(os.environ, PYTHONUTF8="1")
env["PYTHONPATH"] = os.pathsep.join(str(RTL / p) for p in ("tools", "PLENA_Compiler", "PLENA_Tools"))


def run(name, args):
    started = time.perf_counter()
    with (LOG / f"{name}.log").open("w", encoding="utf-8") as log:
        subprocess.run([sys.executable, *map(str, args)], cwd=ROOT, env=env,
                       stdout=log, stderr=subprocess.STDOUT, check=True, timeout=180)
    seconds = time.perf_counter() - started
    print(f"{name}: PASS ({seconds:.2f}s)")
    return seconds


if __name__ == "__main__":
    LOG.mkdir(parents=True, exist_ok=True)
    timings = {}
    timings["online_attention"] = run("online-attention", [ROOT / "study/online_attention_lab.py"])
    # 复用上游立即数边界测试。完整 26 项已单独跑过；日常入口选 10 项轻量用例。
    timings["compiler"] = run("compiler-smoke", [RTL / "PLENA_Compiler/asm_templates/tests/test_large_immediate.py", "TestLoadLargeInt"])
    # 上游生成器会改 INSTRUCTION_STORAGE_OFFSET；保留原字节，结束后还原。
    config = RTL / "src/definitions/configuration.svh"
    before = config.read_bytes()
    try:
        timings["linear_generation"] = run("linear-generate", ["-m", "testworkloads.linear", "--batch", 4,
            "--in-features", 16, "--out-features", 32, "--build-dir", OUT])
    finally:
        config.write_bytes(before)
    words = (OUT / "generated_machine_code.mem").read_text().splitlines()
    assert words and all(0 <= int(w, 16) < 2**32 for w in words if w.strip())
    assert (OUT / "golden_result.pt").is_file()
    timings["legacy_analytic"] = run("analytic-qwen3-32b", [SIM / "analytic_models/performance/llama_model.py",
        "--model", "qwen3-32b", "--batch-size", 1, "--input-seq", 128, "--output-seq", 16,
        "--model-lib", SIM / "PLENA_Compiler/doc/Model_Lib", "--config", SIM / "plena_settings.toml",
        "--isa-lib", SIM / "analytic_models/performance/customISA_lib.json", "--json", "--quiet"])
    (LOG / "cpu-receipt.json").write_text(json.dumps({"status": "pass", "seconds": timings,
        "machine_code_words": len(words), "scope": "CPU smoke; generated reference is not RTL verification; legacy estimator is not the prefill research model"}, indent=2), encoding="utf-8")
