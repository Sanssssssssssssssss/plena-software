**核心源码阅读顺序**

14 个文件只新增中文注释。02、03 是完整声明组成的选段，其余为完整文件。它们用于阅读，项目运行依赖仍在原目录。[sources.json](sources.json) 记录来源、行段、哈希和注释数；[生成脚本](../build_reading_copy.py) 可重新核对文本与 Python AST。

| 次序 | 阅读文件 | 必须能回答 |
|---|---|---|
| 1 | [Linear 生成](01_linear_workload.py) | 输入怎样变成量化张量、内存、汇编、机器码和 golden？ |
| 2 | [Packed GQA](02_packed_gqa_schedule.py) | 多个 Q heads 如何共享 KV？逻辑 shape 与阵列填充差在哪？ |
| 3 | [CostTrace](03_cost_trace.py) | 静态指令、动态指令、DMA 和能耗动作有什么区别？ |
| 4 | [AGU](13_agu.py) | 何时可省地址更新？何时因依赖或 setup 成本回退？ |
| 5 | [MoE 路由](14_moe_routing.py) | TopK、分桶、等步长路由和负载均衡假设如何区分？ |
| 6 | [状态 bank](04_softmax_state_bank.sv) | 每个 query 行的 m/l 放在哪里？首次使用如何识别？ |
| 7 | [状态 SIMD](05_softmax_state_simd.sv) | 三个 phase 分别实现哪条数学递推？ |
| 8 | [多行 engine](06_softmax_row_engine.sv) | ready/valid、scoreboard、地址冲突如何限制发射？ |
| 9 | [PV 写回](07_packed_pv_writeback.sv) | 覆盖/累加如何选择读旧 O？写哪一组 lane？ |
| 10 | [PV 累加器](08_packed_pv_accumulator.sv) | 如何避免背靠背事务的上下文串位？ |
| 11 | [RTL 测试](09_softmax_test.py) | 尾行、递推、输出缩放、连续发射分别由什么断言验证？ |
| 12 | [系统指标](10_system_metrics.py) | 为什么局部 2.69×，系统吞吐只提高约 5.3%？ |
| 13 | [能耗](11_system_power.py) | 哪些是动作能耗、背景功耗、理想假设及未计入项？ |
| 14 | [DSE 目标](12_dse_objective.py) | 优化哪两个目标？准确率、面积、HBM 是怎样的约束？ |

第一遍走 1→2→3→6→7→8→11→12，先连通数据流；第二遍补 AGU、MoE、PV、能耗和搜索。每次看完一个模块，画出它的输入、保存的状态、输出、等待条件，再运行对应实验。

后续深入的原文件：[cost_frontend.py](https://github.com/AICrossSim/PLENA_Compiler/blob/0ba3b657725bf083feec06c8e356e2d6235cd4d5/aten/cost_frontend.py)、[native_layout.py](https://github.com/AICrossSim/PLENA_Compiler/blob/0ba3b657725bf083feec06c8e356e2d6235cd4d5/aten/plena/native_layout.py)、[RTL-v6 单层 A/B 报告入口](https://github.com/AICrossSim/PLENA_Simulator/blob/fddfcb9a7c3eaa1ad9f1c24da829a4422b324650/analytic_models/dse/report_rtl_v6_single_layer_ab.py)。
