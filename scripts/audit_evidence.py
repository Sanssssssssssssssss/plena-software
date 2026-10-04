"""重算历史表格比例，盘点本地证据；不会把历史数字变成本机实测。"""
from pathlib import Path
import csv
import json
import subprocess
import xml.etree.ElementTree as ET
from datetime import datetime, timezone

ROOT = Path(__file__).resolve().parents[1]
PREFILL = ROOT / "PLENA_Simulator"
LOG = ROOT / "runs"


def git(path, *args):
    if not (ROOT / path / ".git").exists():
        return None
    return subprocess.check_output(["git", "-C", str(ROOT / path), *args], text=True).strip()


def main():
    LOG.mkdir(parents=True, exist_ok=True)
    missing = [
        "Workspace/qwen3_32b_dense_analytic/qwen3-32b.json",
        "Workspace/qwen3_235b_a22b_analytic/qwen3-235b-a22b-instruct.json",
        "Workspace/qwen3_32b_transactional_prefetch_sweep/runs/gqa_logical_kv_optimized_20260710/trial_0000/plena_settings.toml",
        "Workspace/qwen3_32b_dense_analytic/runs/disaggregate_prefill_dse_config_v1",
        "Workspace/measurements/runpod_a100/plena_runpod_a100_v1/formal_v2",
        "Workspace/reports/serving/primary_90k8_system_search_v3.md",
        "Workspace/reports/serving/primary_90k8_system_search_v5_results.json",
    ]
    rows = list(csv.DictReader((PREFILL / "qwen3_235b_accuracy_gt_0.9_combined.csv").open(encoding="utf-8-sig")))
    accuracy_235 = [{k: r[k] for k in ("trial_id", "weight_precision", "act", "kv", "fp_setting", "accuracy", "correct", "total", "runtime_sec", "log_dir")}
                    for r in rows if r["weight_precision"] == r["act"] == r["kv"] == "MXINT_4"]
    profiles = json.loads((PREFILL / "Workspace/qwen3_32b_dense_analytic/software_accuracy_inputs/software_precision_profiles_accuracy_gt_0p9.json").read_text())["precision_profiles"]
    accuracy_32 = [p for p in profiles if all(p[k].get("kind") == "MXINT" and p[k].get("width") == 4 for k in ("WEIGHT_WIDTH", "ACT_WIDTH", "KV_WIDTH"))]
    history = []
    history_root = ROOT / "rtl-snapshot-20260924/PLENA_RTL"
    if not history_root.exists():
        history_root = ROOT / "evidence/history-2026-10-04/historical-rtl"
    for path in history_root.rglob("results.xml"):
        tests = list(ET.parse(path).iter("testcase"))
        history.append({"path": path.relative_to(ROOT).as_posix(), "tests": len(tests),
                        "failures": [t.attrib["name"] for t in tests if t.find("failure") is not None or t.find("error") is not None]})
    memory = {}
    for model, parameters, layers, kv_heads in (("32B", 32e9, 64, 8), ("235B", 235e9, 94, 4)):
        # 参数量是模型名的近似值；KV 用官方 config 的层数、KV heads、head_dim。
        kv_elements = 2 * layers * kv_heads * 128 * 98000 * 8
        memory[model] = {"weights_4bit_GB": parameters * .5 / 1e9,
                         "weights_16bit_GB": parameters * 2 / 1e9,
                         "kv4_GB": kv_elements * .5 / 1e9, "kv16_GB": kv_elements * 2 / 1e9,
                         "weights_plus_kv4_GB": (parameters + kv_elements) * .5 / 1e9}
    result = {
        "generated_utc": datetime.now(timezone.utc).isoformat(),
        "imported_components": json.loads((ROOT / "docs/provenance/source-manifest.json").read_text())["components"],
        "research_tools_requested": "a359963dec3cd0443051cacf063316684f96fa27",
        "research_tools_status": "requested commit unavailable; substituted 0f103539, quant namespace alias used for focused checks",
        "archive_sha256": "979103A40F877590A4A8213F35DA4E3269CB889BF3E10E850BF5ED2B57026CC8",
        "expected_artifacts": {p: (PREFILL / p).exists() for p in missing},
        "historical_rtl_xml": history,
        "historical_rtl_xml_source": history_root.relative_to(ROOT).as_posix(),
        "historical_rtl_summary": {"files": len(history), "tests": sum(r["tests"] for r in history), "failures": sum(len(r["failures"]) for r in history)},
        "accuracy235_csv_rows": len(rows), "accuracy235_w4a4kv4": accuracy_235,
        "accuracy32_w4a4kv4": accuracy_32,
        "historical_table_recalculation": {
            "dense_single_layer_speedup": 30086.52 / 11196.59,
            "moe_single_layer_speedup": 27405.57 / 8513.12,
            "completed_dse_trials": 5 * 16384,
            "attempted_dse_trials": sum((39096, 44045, 33500, 38384, 36861)),
            "dense_output_tps_percent": (236.55 / 224.66 - 1) * 100,
            "moe_output_tps_percent": (333.87 / 294.797 - 1) * 100,
            "dense_output_tokens_per_j_percent": (.098245 / .066616 - 1) * 100,
            "moe_output_tokens_per_j_percent": (.093741 / .055952 - 1) * 100,
        },
        "ideal_storage_estimate_B8_S98000_decimal_GB": memory,
        "dse_ideal_hours_excluding_pruned_and_overhead": [
            {"seconds_per_completed_trial": s, "effective_parallelism": p,
             "hours": 81920 * s / p / 3600} for s in (1, 10, 60) for p in (4, 8)],
    }
    assert len(accuracy_235) == 3 and len(accuracy_32) == 3, "Check profile field names or changed inputs"
    (LOG / "evidence-audit.json").write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps({k: result[k] for k in ("historical_rtl_summary", "historical_table_recalculation", "ideal_storage_estimate_B8_S98000_decimal_GB")}, indent=2))


if __name__ == "__main__":
    main()
