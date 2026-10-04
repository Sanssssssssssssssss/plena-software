"""Run the bounded CPU validation; no weights or GPU required."""
from pathlib import Path
import json
import os
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
SIM = ROOT / 'PLENA_Simulator'


def main():
    logs = ROOT / 'runs'
    logs.mkdir(exist_ok=True)
    env = dict(os.environ, PYTHONUTF8='1', PYTHONPATH=os.pathsep.join(map(str, (
        ROOT / 'scripts', SIM, SIM / 'PLENA_Compiler', SIM / 'PLENA_Tools'))))
    jobs = {
        'online-attention': [ROOT / 'scripts/online_attention_lab.py'],
        'compiler-immediates': [SIM / 'PLENA_Compiler/asm_templates/tests/test_large_immediate.py'],
        'research-checks': ['-m', 'pytest', '-q',
            'PLENA_Simulator/PLENA_Compiler/aten/tests/test_cost_frontend.py::test_rtl_v6_multirow_state_and_direct_pv_lowering',
            'PLENA_Simulator/analytic_models/serving_benchmark/test_serving_benchmark.py::test_system_metrics_separate_throughput_from_slo_goodput',
            'PLENA_Simulator/analytic_models/serving_benchmark/test_serving_benchmark.py::test_disaggregated_pipeline_charges_cross_stage_idle_static_energy'],
        'tiny-trace-ab': [ROOT / 'scripts/trace_experiment.py'],
    }
    receipt = {'scope': 'CPU checks; no full-model accuracy or performance reproduction', 'jobs': {}}
    for name, args in jobs.items():
        started = time.perf_counter()
        with (logs / f'{name}.log').open('w', encoding='utf-8') as out:
            result = subprocess.run([sys.executable, *map(str, args)], cwd=ROOT, env=env,
                                    stdin=subprocess.DEVNULL, stdout=out, stderr=subprocess.STDOUT, timeout=300)
        receipt['jobs'][name] = {'exit_code': result.returncode, 'seconds': time.perf_counter() - started}
        (logs / 'cpu-receipt.json').write_text(json.dumps(receipt, indent=2), encoding='utf-8')
        if result.returncode:
            raise RuntimeError(f'{name} failed; see {logs / (name + ".log")}')
        print(f'{name}: PASS ({receipt["jobs"][name]["seconds"]:.2f}s)', flush=True)


if __name__ == '__main__':
    main()
