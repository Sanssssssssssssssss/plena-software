$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$oldPythonPath = $env:PYTHONPATH
New-Item -ItemType Directory -Force "$root\study\logs" | Out-Null
try {
    $env:PYTHONPATH = "$root\lab\python-aliases;$root\PLENA-Prefill;$root\PLENA-Prefill\PLENA_Tools;$root\PLENA-Prefill\PLENA_Compiler"
    Push-Location $root
    & "$root\.venv\Scripts\python.exe" -m pytest `
        PLENA-Prefill/PLENA_Compiler/aten/tests/test_cost_frontend.py::test_rtl_v6_multirow_state_and_direct_pv_lowering `
        PLENA-Prefill/analytic_models/serving_benchmark/test_serving_benchmark.py::test_system_metrics_separate_throughput_from_slo_goodput `
        PLENA-Prefill/analytic_models/serving_benchmark/test_serving_benchmark.py::test_disaggregated_pipeline_charges_cross_stage_idle_static_energy `
        -q *> "$root\study\logs\prefill-checks.log"
    $result = $LASTEXITCODE
    Get-Content "$root\study\logs\prefill-checks.log"
    if ($result -ne 0) { throw "Prefill checks failed: exit $result" }
} finally {
    Pop-Location
    $env:PYTHONPATH = $oldPythonPath
}
