# 核心代码阅读索引

以下链接直接进入工程源码。注释解释数据布局、状态递推、调度取舍和验证断言，保留原有计算逻辑。两仓库合计 88 处；本仓库 43 处。

| 实际文件 | 新增核心注释 |
|---|---:|
| [PLENA_Simulator/PLENA_Compiler/aten/plena/program_attention.py](../PLENA_Simulator/PLENA_Compiler/aten/plena/program_attention.py) | 7 |
| [PLENA_Simulator/PLENA_Compiler/aten/cost_emitter.py](../PLENA_Simulator/PLENA_Compiler/aten/cost_emitter.py) | 6 |
| [PLENA_Simulator/analytic_models/serving_benchmark/system_metrics.py](../PLENA_Simulator/analytic_models/serving_benchmark/system_metrics.py) | 7 |
| [PLENA_Simulator/analytic_models/power/system_power.py](../PLENA_Simulator/analytic_models/power/system_power.py) | 6 |
| [PLENA_Simulator/analytic_models/dse/objective.py](../PLENA_Simulator/analytic_models/dse/objective.py) | 5 |
| [PLENA_Simulator/PLENA_Compiler/aten/agu.py](../PLENA_Simulator/PLENA_Compiler/aten/agu.py) | 6 |
| [PLENA_Simulator/PLENA_Compiler/aten/moe.py](../PLENA_Simulator/PLENA_Compiler/aten/moe.py) | 6 |

按 [项目阶段](PROJECT_JOURNEY.md) 阅读，并在每个阶段保存自己的配置、预测和观测。别把指令数、模拟周期、目标时延和主机运行秒数混成一个指标。
