# 独立仓库验收 · 2026-10-04

完整源码已在新的本地目录和全新 `git clone` 中核对。软件有 2,104 个上游文件；所有 Compiler/Tools/OSWorld 子模块已展开为普通 Git 文件。43 处注释直接位于实际代码中。导入清单、注释去除后的原始字节、历史证据哈希及本仓库文档链接均通过检查。

| 全新克隆中的检查 | 结果 | 日志 |
|---|---|---|
| GQA online-attention 数学 reference | tile=1/4/8/16/33，全通过，float64 误差 <9e-16 | [数学](../evidence/repository-validation-2026-10-04/fresh-clone/online-attention.log) |
| 编译器大立即数 | 26 项通过，约 116.54s（主机耗时） | [编译器](../evidence/repository-validation-2026-10-04/fresh-clone/compiler-immediates.log) |
| 研究前端与系统指标 | 3 项通过：R4/direct PV lowering、TPS/goodput、跨阶段 idle energy | [研究检查](../evidence/repository-validation-2026-10-04/fresh-clone/research-checks.log) |
| 小型编译 A/B | v5/R1/R4：14,966 / 14,518 / 13,510；矩阵工作不变量通过 | [trace JSON](../evidence/repository-validation-2026-10-04/fresh-clone/tiny-trace-ab.json) |
| 历史比例与资源算术 | 保留原始表格口径与缺失标记 | [核对 JSON](../evidence/repository-validation-2026-10-04/fresh-clone/evidence-audit.json) |

新克隆使用独立 Windows Python 3.12 环境，由根 requirements 安装，无归档目录的 editable package。CPU 检查总约 130.02s；这不是目标 NPU 的执行延迟。脚本从所在目录定位源码，支持更换 clone 路径。[计时收据](../evidence/repository-validation-2026-10-04/fresh-clone/cpu-receipt.json)与[证据 manifest](../evidence/repository-validation-2026-10-04/manifest.json)保存执行 commit、源文件哈希、原始/发布日志哈希和时间。

CPU 实测 commit 为 `3eb9c29`；之后的 `68c2c25` 更新学习路径、证据说明与 audit 输出，audit 已重新执行，计算代码及导入源码哈希未改变。最终发布另加入这些日志与文档。

未运行 GPU 评测、完整 DSE、DC 综合、Rust 事务级模拟器或全量 quant_eval 测试。相关完整源码、已有配置和构建入口保留。缺失的 Tools pin、默认搜索 YAML、原始模型/实验配置及正式结果，仍按 [COMPATIBILITY](COMPATIBILITY.md) 与 [RESULTS](RESULTS.md) 标记。
