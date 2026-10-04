**简历数字核对：有材料，但证据完整度不同**

核对对象为[用户提供的项目描述](references/project-description.png)、公开研究分支和 RTL 压缩包。作者历史记录、保存的结果文件、本次本机运行分别标明；重新计算一个比例不会使它变成新的性能实测。

| 描述中的结果 | 找到的证据与重算 | 当前判断 |
|---|---|---|
| Qwen3-32B/235B 的 GQA、MoE 编译路径 | 研究 Compiler 的 layout、attention、MoE、cost_frontend 及测试 | 有实现；本次只跑了 tiny 配置和局部检查，未跑完整真实权重模型 |
| 四行 Online Softmax、本地递推状态、PV 写回 | RTL 快照对应模块、历史 XML；本次 R4 模块 2 项 PASS | 功能模块有当前验证；未完成 full-core workload 验证 |
| Dense 单层 2.69× | 30,086.52 / 11,196.59 = **2.6871×** | 能追溯到历史模型 A/B 表，不是实机 NPU 计时 |
| MoE 单层 3.22× | 27,405.57 / 8,513.12 = **3.2192×** | 同上，fixed-balanced 单层，不代表完整 235B 驻留单芯片 |
| 8.2 万组候选 | 5 × 16,384 COMPLETE = **81,920**；记录总 attempts=191,886 | 有历史表与 campaign 脚本；完整 trial 库未找到，未独立审计所有候选 |
| W4/A4/KV4，94%–96% BFCL-Multiple | 235B CSV 中 E6M5/E8M5 为 **48/50=96%**；32B 相同位宽导入 profile 为 92% 或 98% | 96% 有 50 条汇总；94% 下界尚未与同配置、同样本结果对齐 |
| 系统吞吐 +5.3% / +13.3% | 历史 v3 表重算 **5.292% / 13.254%** | 比例能对上；为 A100 数据与 NPU 模型的解析组合 |
| 系统能效 +46.8% / +65.0% | 同一历史 v3 最大 TPS 表得到 **47.480% / 67.538%** | 与截图不同；9 月模型有修订，最终原始报告缺失，尚不能确认截图值 |

比例和盘点可重跑 `study/audit_evidence.py`；结果在[evidence-audit.json](evidence/2026-10-04/evidence-audit.json)。

**2.69×/3.22× 应当怎样测出来**

历史条件为 seq=90,000、B=8、MLEN/VLEN=2048、BLEN=128、W4/A4/KV4、内部 FP E6M5、KV-25、单芯片 80 GB HBM、一个 decoder layer。基线 rtl-v5 与 Combined R4 比较。来源：[项目记录第 7.5 节](https://github.com/AICrossSim/PLENA_Simulator/blob/fddfcb9a7c3eaa1ad9f1c24da829a4422b324650/Workspace/final_thesis_complete_project_history_20260818.md#L688)。

可信的完整链应保留：A/B 两份相同 shape/精度配置 → 编译 schedule 和动态工作量 → compute/HBM 分解 → 总 layer latency → speedup。还要检查真实有效矩阵工作和物理 HBM bytes 没有因漏算而变少，并保存 state-only、PV-only、R1/R2/R4 的消融。

当前记录的 compute latency 使用 ideal-II1 架构模型；大 VLEN 的面积/功耗包含结构外推。不能把表里的毫秒描述成全芯片 RTL 周期精确仿真或板卡运行时间。本次 tiny A/B 证明机制在小配置下改变了编译指令，没有重现这两项长上下文延迟。

**8.2 万方案的计数与日志**

| Campaign | COMPLETE | PRUNED | FAIL（历史记录） |
|---|---:|---:|---:|
| 32B，P2 面积预算 | 16,384 | 22,712 | 0 |
| 32B，P4 | 16,384 | 27,661 | 0 |
| 235B，P4 | 16,384 | 17,116 | 0 |
| 235B，P8 | 16,384 | 22,000 | 0 |
| 235B，P12 | 16,384 | 20,477 | 0 |

P 是 A100-equivalent 面积预算因子，每个预算单位 743.4 mm²；实际 NPU 芯片数需另看设计记录。预算脚本见[run_disaggregate_prefill_campaigns_v1.sh](https://github.com/AICrossSim/PLENA_Simulator/blob/fddfcb9a7c3eaa1ad9f1c24da829a4422b324650/Workspace/qwen3_32b_dense_analytic/run_disaggregate_prefill_campaigns_v1.sh)。

要独立确认 81,920，需取回数据库或逐 trial compact records，核对状态、物理配置去重、候选版本、约束及 objective。源文档中 `fidelity_qualified_completed=0` 表示没有候选满足最严格 full-RTL/timing 条件；不等于 81,920 个模型 trial 都执行失败。当前材料不足以重做完整 trial 审计。

**准确率的证据边界**

[235B 汇总 CSV](https://github.com/AICrossSim/PLENA_Simulator/blob/fddfcb9a7c3eaa1ad9f1c24da829a4422b324650/qwen3_235b_accuracy_gt_0.9_combined.csv) 共 63 行，均是 total=50 的精度配置汇总。严格筛选 weight=act=kv=`MXINT_4`：

| 内部 FP | correct / total | accuracy |
|---|---:|---:|
| E6M5 | 48 / 50 | 96% |
| E8M5 | 48 / 50 | 96% |
| E5M6 | 46 / 50 | 92% |

这些条目的 `runtime_sec=577.80` 是历史 CSV 字段；不同条目还记录了权重复用，不能简单相加为独立 GPU 作业成本。`log_dir` 指向作者原机器，目前本地没有对应生成输出。

[32B 导入 profile](https://github.com/AICrossSim/PLENA_Simulator/blob/fddfcb9a7c3eaa1ad9f1c24da829a4422b324650/Workspace/qwen3_32b_dense_analytic/software_accuracy_inputs/software_precision_profiles_accuracy_gt_0p9.json) 的 MXINT4/MXINT4/MXINT4：E5M6=98%，E6M5/E8M5=92%。这里只存标量分数；没有逐题结果来确认 94% 的来源。

补证需要：BFCL 数据集版本、Multiple 类别与样本 ID、prompt 模板、评估命令、seed、精度/GPTQ 配置、逐条生成及判分文件。50 条样本的一题就是 2 个百分点；它不能直接代表整个 BFCL 官方榜单成绩。内部 FP、量化格式、scale/block 配置也必须与 W/A/KV 位宽一起记录。

**系统吞吐与能效怎么核算**

每批输出 `8 × 8,000 = 64,000 tokens`。历史 v3 最大 TPS 点为：

| 模型 | A100 output TPS → 组合 TPS | A100 tokens/J → 组合 tokens/J |
|---|---|---|
| 32B | 224.66 → 236.55 | 0.066616 → 0.098245 |
| 235B | 294.797 → 333.87 | 0.055952 → 0.093741 |

提升率统一为 `(new / baseline − 1) × 100%`。来源：[项目记录第 16 节](https://github.com/AICrossSim/PLENA_Simulator/blob/fddfcb9a7c3eaa1ad9f1c24da829a4422b324650/Workspace/final_thesis_complete_project_history_20260818.md#L1850)。表中数字已四舍五入，重算也受此精度限制。

能效结果不能与另外的 maximum-efficiency 端点混用。v3 最大 TPS 端点的单批 E2E 分别从 284.869s→340.399s、217.098s→269.112s，满足记录采用的 1.25× E2E 约束；吞吐改善不表示请求延迟也改善。

当前 9 月代码在[system_metrics.py](https://github.com/AICrossSim/PLENA_Simulator/blob/fddfcb9a7c3eaa1ad9f1c24da829a4422b324650/analytic_models/serving_benchmark/system_metrics.py)补计跨阶段等待时的静态能耗，selector 也从仅 prefill Pareto 改为所有可行完成候选。这个变更可能影响与截图的差异，但没有最终结果文件，不能认定它就是 46.8%/65.0% 的来源。

系统结果的其他条件：32B 最大 TPS 点为 R8；235B 为 R16 结构外推；能耗含 ideal clock gating 和较乐观 SRAM leakage；12/16 A100 点含从测量副本扩展的估计；无真实 PLENA→A100 KV 导入、排队与 continuous batching 测量。原始 A100 timed runs、功耗采样、拓扑、vLLM 版本和 GPU 配置是复核的必要输入。

**确实找到了哪些日志**

1. RTL 包有 17 份历史 results.xml，合计 29 个 testcase，其中 4 个失败：`fp_cp_adder`、`fp_cp_asym_mult`、`fp_cp_exp`、`system/test`。这些产物来自不同目录，不能当成一次同版本全套回归；失败也尚未逐个重现诊断。
2. 研究分支有 HBM、面积、功耗校准 CSV/JSON 和验证摘要。例如[HBM V4 校准](https://github.com/AICrossSim/PLENA_Simulator/blob/fddfcb9a7c3eaa1ad9f1c24da829a4422b324650/analytic_models/performance/calibration/hbm_dma_service_v4.json)、[RTL-v6 面积系数](https://github.com/AICrossSim/PLENA_Simulator/blob/fddfcb9a7c3eaa1ad9f1c24da829a4422b324650/analytic_models/area_new/calibration/vector_rtl_v6_delta_coefficients.json)、[RTL-v6 功耗系数](https://github.com/AICrossSim/PLENA_Simulator/blob/fddfcb9a7c3eaa1ad9f1c24da829a4422b324650/analytic_models/power/calibration/vector_rtl_v6_power_delta.json)。系数文件不等于完整原始 DC/活动采样作业。
3. 有准确率汇总、项目历史文字、搜索脚本与报告生成代码。最终 DSE 目录、正式 A100 runs、system v3/v5 报告和部分模型/基础配置未找到；精确缺失路径见[evidence-audit.json](evidence/2026-10-04/evidence-audit.json)。
4. 本次新生成：[编译器 26 项日志](evidence/2026-10-04/compiler-large-immediate.log)、[研究检查 3 项](evidence/2026-10-04/prefill-checks.log)、[tiny 编译 A/B](evidence/2026-10-04/tiny-trace-ab.json)、[RTL 仿真日志](evidence/2026-10-04/rtl-softmax.log)及[XML](evidence/2026-10-04/rtl-softmax-results.xml)。

**后续补材料的优先级**

先找同版本最终报告与其输入：系统结果 JSON、DSE compact trials/数据库、A100 run directories、准确率逐题日志、对应锁定的 Tools commit。已有结果拿回来重算通常比重新跑一遍集群实验更省资源。

若无法取回，建立新的复现实验标签，固定现有版本后按资源预算从小规模做起。新的测量应形成自己的结论，不能倒推或补造历史日志。当前适合对外表述为“基于编译 schedule 与校准成本模型的预测结果”，并具体说明自己实际跑过的模块与验证范围。
