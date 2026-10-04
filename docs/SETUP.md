# 克隆与运行

使用 Python 3.12。基础实验只需要 CPU；完整模型准确率、DC 综合和 A100 测量不包含在快速入口中。

**获取源码**

```sh
git clone https://github.com/Sanssssssssssssssss/plena-prefill-lab.git
cd plena-prefill-lab
python study/bootstrap.py
python study/bootstrap.py --check
```

bootstrap 获取固定的主仓库、文档、Prefill 分支和 CPU/RTL 所需子模块。Tools 使用可获得的 `0f103539` 代替不可获得的 `a359963…`；研究目录因此与原 Tools gitlink 有已说明的差异。不要用递归更新覆盖这个替代。

**Windows CPU**

```powershell
python -m venv .venv
.venv\Scripts\python.exe -m pip install -r requirements.txt
.venv\Scripts\python.exe study/run_cpu.py
.\study\run_prefill_checks.ps1
.venv\Scripts\python.exe study/trace_experiment.py
.venv\Scripts\python.exe study/audit_evidence.py
```

**Linux CPU**

```sh
python3.12 -m venv .venv
.venv/bin/python -m pip install -r requirements.txt
.venv/bin/python study/run_cpu.py
PYTHONPATH="lab/python-aliases:PLENA-Prefill:PLENA-Prefill/PLENA_Tools:PLENA-Prefill/PLENA_Compiler" .venv/bin/python -m pytest PLENA-Prefill/PLENA_Compiler/aten/tests/test_cost_frontend.py::test_rtl_v6_multirow_state_and_direct_pv_lowering PLENA-Prefill/analytic_models/serving_benchmark/test_serving_benchmark.py::test_system_metrics_separate_throughput_from_slo_goodput PLENA-Prefill/analytic_models/serving_benchmark/test_serving_benchmark.py::test_disaggregated_pipeline_charges_cross_stage_idle_static_energy -q
.venv/bin/python study/trace_experiment.py
.venv/bin/python study/audit_evidence.py
```

入口设置局部 PYTHONPATH，无需 editable 安装。`lab/python-aliases/quant` 只修复旧导入名，未证明替代 Tools 与原版数值等价。

**RTL：Linux 或 WSL Ubuntu**

需要 g++、make、Perl 与 Linux Python。WSL 和 Windows 的 venv 分开：

```sh
# 在 WSL 中进入克隆目录。
python3.12 -m venv .venv-wsl
.venv-wsl/bin/python -m pip install -r requirements.txt
.venv-wsl/bin/python -m pip install verilator==5.34.0
bash study/run_rtl.sh
```

原生 Linux 可在已有 `.venv` 安装同版本 Verilator 后运行。脚本识别两种环境，补齐 wheel 的 GCC PCH 参数，限制 4 个编译任务，关闭波形，并检查本次生成的 XML。

PowerShell 可转换实际工作路径：

```powershell
$linuxRepo = (wsl -d Ubuntu -- wslpath -a (Get-Location).Path).Trim()
wsl -d Ubuntu -- bash "$linuxRepo/study/run_rtl.sh"
```

**输出与验证范围**

`study/logs` 和 `study/runs/linear` 保存新实验输出，被 Git 忽略。固定历史记录在 [study/evidence/2026-10-04](../study/evidence/2026-10-04)，附有来源哈希和机器路径替换说明。

`run_cpu.py` 暂时修改并最终还原上游 configuration.svh 的 instruction offset；不要并行修改同一配置。旧 Qwen 解析 smoke 的 head_dim 推导存在限制，不能用于性能结论。R4 模块仿真也不等于 full-core 验收。

完整复现缺失项见[证据核对](../study/02_numbers_and_evidence.md)，资源估算见[预算](../study/03_local_runs_and_budget.md)。
