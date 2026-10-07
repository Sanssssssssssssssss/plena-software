# 来源与本仓库改动

本仓库收录 [AICrossSim/PLENA](https://github.com/AICrossSim/PLENA) 的 Simulator 与 Software 研究分支。PLENA 基础框架与第三方代码保留文件中的版权声明。Llama 到 Qwen3 的项目迁移、优化及最终成绩见 [README](README.md) 和 [RESULTS](docs/RESULTS.md)；2026-10-04 的仓库整理另增加 43 处中文注释、独立运行脚本和本机验证。

所有 PLENA 核心依赖已直接纳入普通 Git 文件。导入的 `.gitmodules` 存在 `docs/provenance/gitmodules/` 中作为来源记录；不参与 checkout。第三方 Python/Rust 包仍由原有依赖清单安装。模型权重、环境、构建缓存、原始压缩包不入 Git。

源码清单：[逐文件原始/当前 SHA256 与 commit](docs/provenance/source-manifest.json)；[注释清单](docs/provenance/annotations.json)。本仓库 2,104 个导入文件按清单核对；43 处新增注释之外的源码字节与导入版本一致，Python 文件还比对了 AST。上游 README、配置、脚本和版权头保留原内容；本仓库的运行入口位于 `scripts/`。

Simulator 导入版本为 `fddfcb9a`，量化软件为 `d8c9bbcb`，官方文档为 `7bf6d763`。Compiler、Tools 与硬件的关系见[版本配套表](docs/COMPATIBILITY.md)；RTL 归档哈希与导入说明保存在[硬件仓库](https://github.com/Sanssssssssssssssss/plena-hardware/blob/main/PROVENANCE.md)。

历史记录与独立仓库复测按目录保存，见[日志索引](evidence/README.md)。原始文件保留日期和 manifest；2026-10-04 独立仓库验证的配置及结果见 [VALIDATION](docs/VALIDATION.md)。

本仓库继承 `plena-prefill-lab` 的提交历史，旧学习副本仍可从 Git 历史查看。原 `RTLFile` 本地工作区保留作归档核对。

## 版权与引用

保留各源码文件版权头和组件中已有 LICENSE。可选桌面评测 [OSWorld](PLENA_Software/quant_eval/benchmarks/OSWorld/LICENSE) 采用 Apache-2.0；[ASAP7 SRAM 校准材料](PLENA_Simulator/analytic_models/area_new/calibration/ASAP7_SRAM_LICENSE)保留其 BSD-3-Clause 声明。硬件与 TileLink 的版权说明位于[配套硬件仓库](https://github.com/Sanssssssssssssssss/plena-hardware/blob/main/PROVENANCE.md)。未给没有许可证的研究组件另行补写统一授权。

2026-10-07 文档整理：精简首页，增加直接到核心代码的链接及日志索引，将 OSWorld 标为可选第三方评测，历史模型成绩集中链接到 RESULTS。源码、依赖版本、版权和历史日志未改动。

原论文：[Combating the Memory Walls: Optimization Pathways for Long-Context Agentic LLM Inference](https://arxiv.org/abs/2509.09505)。需要学术引用时使用对应上游 README 的 BibTeX。
