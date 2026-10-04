# 简历内容与源码、实验的对应关系

四条研究主线来自项目描述。上游实现、作者历史结果和本仓库实际完成的验证分别注明；个人参与范围和项目时间需要按真实经历填写。

| 简历主线 | 应讲明白的工程问题 | 代码入口 | 现有证据 |
|---|---|---|---|
| 编译与算子映射 | 显式 head_dim、GQA 共享 KV、布局/tile/DMA、MoE 与 tail | [GQA](../study/core/02_packed_gqa_schedule.py)、[MoE](../study/core/14_moe_routing.py)、[AGU](../study/core/13_agu.py) | 小 Linear、26 项编译器测试、tiny 编译 A/B |
| 微架构与 RTL | m/l/O 递推、状态保留、多行并行、直接 PV 写回、依赖管理 | [state bank](../study/core/04_softmax_state_bank.sv)、[engine](../study/core/06_softmax_row_engine.sv)、[PV](../study/core/07_packed_pv_writeback.sv) | R4 模块 2 项 PASS；2.69×/3.22× 是历史单层模型表 |
| 量化与硬件搜索 | 精度/准确率约束，array/SRAM/topology 取舍，校准、Pareto、剪枝 | [CostTrace](../study/core/03_cost_trace.py)、[功耗](../study/core/11_system_power.py)、[目标](../study/core/12_dse_objective.py) | 校准摘要、精度 profile、81,920 COMPLETE 历史记录；缺完整 trial 库 |
| 系统评估 | 资源匹配、瓶颈迁移、TPS/延迟/能效语义 | [指标](../study/core/10_system_metrics.py) | 2 项指标测试、历史表重算；缺 GPU 原始采样和最终报告 |

**五分钟讲解顺序**

1. 任务与边界：长上下文 Prefill 的 NPU 映射与协同优化；说明模型预测、RTL 模块验证、GPU 测量各负责什么。
2. 正确映射：Qwen3 hidden 与 Q 投影宽度并不相等；解释 GQA、tail、小 reference 与地址/布局核对。
3. 发现瓶颈：从 trace 看地址更新、规约、状态搬运和 PV 整形，结合动态工作量提出假设。
4. 优化闭环：用递推公式解释 state bank，再拆 state-only、direct-PV、R-way 的消融；给出依赖、尾行和连续发射测试。
5. 收益与限制：固定精度/shape/阵列对比，进入系统后解释 decode 瓶颈、资源分配、idle energy 和缺失证据。

**四个值得深入的问题**

为什么 Packed GQA 有用：逻辑 KV heads 少，物理阵列宽度固定；共享和打包改善无效槽位及重复搬运。head tail、broadcast 与 residency 必须一起核对。

为什么 R4 以后收益递减：只有部分 query-row 工作被并行化，矩阵、FFN/MoE、HBM 和控制仍在；更多 bank 还可能浪费最小 SRAM macro 容量。展示延迟和面积随 R 的消融。

8.2 万点怎么跑：主要执行 symbolic compiler/cost model，没有逐点跑完整 RTL 或加载全权重。讲清校准、压缩 schedule、缓存、并行、COMPLETE 与 PRUNED 的定义。

单层 2.69× 为何只有约 5.3% 系统 TPS：steady-state interval 取最慢阶段，历史 Dense 最大 TPS 点已由 decode 限速。E2E、TTFT 和 TPS 不会同比改善。

**成绩应附带的条件**

| 指标 | 讲解时保留的条件 |
|---|---|
| 2.69× / 3.22× | 一层、S90k/B8、固定 W/A/KV 与阵列；校准模型，MoE fixed-balanced |
| 81,920 COMPLETE | 五组各 16,384；另有剪枝；数据库尚未恢复 |
| 96% | 235B、具体 W4/A4/KV4 与 FP setting、48/50；逐题日志待补，不代表完整 BFCL 榜单 |
| +5.3% / +13.3% TPS | B8、90k 输入/8k 输出、匹配资源、1.25× E2E 约束；解析组合 |
| +46.8% / +65.0% 能效 | 暂无同版本最终报告；现有 v3 表重算不同，标记待核对 |

完整来源见[数字核对](../study/02_numbers_and_evidence.md)。截图的 3–7 月与材料中 8–9 月后续改动需区分，不能自动把后来结果计入较早阶段。

**本仓库已形成的实践记录**

- 固定源码版本，保存 RTL 运行副本，整理 14 个核心阅读文件及 88 处注释。
- 建立 CPU 数学/编译、tiny schedule A/B 和 R4 RTL 入口。
- 核对动态指令和矩阵算术计数，保存真实检查日志。
- 逐项追踪描述中的数字，记录缺失配置、依赖、DSE/GPU 数据。

之后每次自己的改动，都补“问题 → 预测 → 一处改动 → 正确性 → 性能/资源 → 配置与日志”，据实际完成内容更新讲述。
