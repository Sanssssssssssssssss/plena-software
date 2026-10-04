# 来源与本仓库改动

本项目整理自 [AICrossSim/PLENA](https://github.com/AICrossSim/PLENA) 及其组件。研究算法、RTL、编译器和历史成绩归原作者；本仓库增加完整源码编排、中文核心注释、独立运行入口、结果核对和学习文档。历史作者工作不表示本仓库维护者的个人贡献。

所有 PLENA 核心依赖已直接纳入普通 Git 文件。导入的 `.gitmodules` 存在 `docs/provenance/gitmodules/` 中作为来源记录；不参与 checkout。第三方 Python/Rust 包仍由原有依赖清单安装。模型权重、环境、构建缓存、原始压缩包不入 Git。

源码清单：[逐文件原始/当前 SHA256 与 commit](docs/provenance/source-manifest.json)；[实际源码中的注释清单](docs/provenance/annotations.json)。两仓库共 88 处核心注释，移除了注释后文本一致，Python 文件还比对 AST。导入的上游 README、配置、脚本和版权头保留原内容；其中原作者机器路径不是本仓库运行入口。

RTL 归档：`03_PLENA_RTL_source_20260924.tar.zst`，SHA256 `979103A40F877590A4A8213F35DA4E3269CB889BF3E10E850BF5ED2B57026CC8`。打包名含 9 月 24 日；其 HEAD `1e0eb060` 的提交日期为 8 月 22 日。源码从 tracked commit 导出；原包两份 dirty Synopsys debug 脚本及旧 build 保留在本地原工作区。

历史证据位于 [evidence/history-2026-10-04](evidence/history-2026-10-04)，保留上一轮发布的字节、日期和 manifest。这里包括作者归档产物和初次本机检查，不能统称本轮实测。本轮独立仓库验收见 [docs/VALIDATION.md](docs/VALIDATION.md)。

软件仓库继承 `plena-prefill-lab` 的提交历史，旧学习副本可在 Git 历史查看。硬件仓库从上述可追溯快照创建。原 `RTLFile` 本地工作区保留作归档核对。

## 版权与引用

保留各源码文件版权头和组件中已有 LICENSE。公开 RTL 基线的 Apache-2.0 和 THIRD_PARTY_LICENSES、OSWorld 的 LICENSE、ASAP7 SRAM 的许可声明按各自适用范围保留。未给没有许可证的研究快照另行补写统一授权。

原论文：[Combating the Memory Walls: Optimization Pathways for Long-Context Agentic LLM Inference](https://arxiv.org/abs/2509.09505)。需要学术引用时使用对应上游 README 的 BibTeX。
