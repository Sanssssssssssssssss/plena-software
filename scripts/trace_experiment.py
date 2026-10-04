"""小型编译 A/B：同一模型/shape，只更换 softmax/PV schedule，无权重下载。"""
from pathlib import Path
import json
import sys
import time
from collections import Counter

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT / p) for p in (
    "scripts", "PLENA_Simulator", "PLENA_Simulator/PLENA_Tools",
    "PLENA_Simulator/PLENA_Compiler")]
from compiler.aten.tests.test_cost_frontend import (
    _tiny_packed_hardware, _tiny_packed_qwen3, compile_native_decoder_cost_trace,
)


def main():
    results = {}
    for name, options in (
        ("rtl-v5", dict(vector_scalar_schedule="rtl-v5")),
        ("rtl-v6-R1", dict(vector_scalar_schedule="rtl-v6", softmax_row_lanes=1)),
        ("rtl-v6-R4", dict(vector_scalar_schedule="rtl-v6", softmax_row_lanes=4)),
    ):
        if name.startswith("rtl-v6"):
            options.update(softmax_vector_schedule="multi-row-v1",
                           softmax_state_schedule="row-bank-simd-v3",
                           pv_accumulation_schedule="direct-packed-rmw-v1")
        started = time.perf_counter()
        trace = compile_native_decoder_cost_trace(
            model_config=_tiny_packed_qwen3(), hardware_config=_tiny_packed_hardware(),
            seq_len=7, batch_size=4, num_layers=1, packed_qk_schedule="head-major-v1",
            cost_trace_granularity="detailed", use_cache=False, **options)
        results[name] = {
            "compile_seconds": time.perf_counter() - started,
            "static_instructions": trace.static_instruction_count,
            "dynamic_instructions": trace.dynamic_instruction_count,
            "attention_opcodes": dict(trace.stages["layer/attention"].dynamic_opcodes),
            "matrix_opcodes": {k: v for k, v in trace.dynamic_opcodes.items() if k.startswith("M_")},
            "compressed_memory_event_count": len(trace.memory_events),
            "packed_gqa": trace.metadata.get("packed_gqa", {}),
        }
    # 新指令把相同矩阵计算与 packed 写回合并，名字改变但算术次数应守恒。
    # 固定本实验的 shape 后归一化比较；这不是任意 shape 的 FLOP 等价证明。
    for row in results.values():
        arithmetic = Counter()
        for opcode, count in row["matrix_opcodes"].items():
            arithmetic[opcode.replace("_PACKED_ACC", "")] += count
        row["matrix_arithmetic_counts"] = dict(arithmetic)
    assert results["rtl-v5"]["matrix_arithmetic_counts"] == results["rtl-v6-R4"]["matrix_arithmetic_counts"]
    assert results["rtl-v6-R4"]["attention_opcodes"]["V_SFM_MAX_ROWS"] > 0
    output = ROOT / "runs/tiny-trace-ab.json"
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps({
        "scope": "local tiny compiler counts; not latency, accuracy, or thesis reproduction",
        "dependency_substitute": "PLENA_Tools 0f103539 with local quant import alias",
        "workload": "hidden=32, qheads=4, kvheads=2, head_dim=4, S=7, B=4, one layer",
        "results": results,
    }, indent=2), encoding="utf-8")
    for name, row in results.items():
        print(name, "dynamic instructions:", row["dynamic_instructions"],
              "compile seconds:", round(row["compile_seconds"], 3))
    print("Matrix work invariant PASS;", output)


if __name__ == "__main__":
    main()
