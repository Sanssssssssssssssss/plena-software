# 版本配套与交换产物

| 工程 | 主源码 | Compiler | Tools | 验证范围 |
|---|---|---|---|---|
| software / PLENA_Simulator | `fddfcb9a`，yx/prefill-DSE | `0ba3b657` | 实际 `0f103539`；要求 `a359963d` 缺失 | CPU 数学、立即数、tiny cost trace、系统指标 |
| software / PLENA_Software | `d8c9bbcb`，yx/qwen-prefill-only-optimisations | 独立 PyTorch 量化评估栈 | OSWorld `d05f7bdc` 已内嵌 | 源码盘点；本轮不运行 GPU 评测 |
| hardware 根目录 / RTL-v6 | 归档 HEAD `1e0eb060` | `17b2bd09` | `af11f546` | R4 Softmax 与 packed PV 模块 |
| hardware / reference/upstream-release | 公开 RTL `783ee48e` | `d89ad594` | `0f103539` | 小 Linear 生成、RTL 仿真、golden 对照 |

完整 commit、逐文件哈希见 [source-manifest.json](provenance/source-manifest.json)。软件还保存官方文档 `7bf6d763`。研究 Tools 的替代版本只经过表列检查，不能视为缺失提交的等价替代。

研究编译器与快照编译器分别代表成本研究和该 RTL 快照的实现配套。跨工程不能直接覆盖 Compiler/Tools。研究 cost trace 的通过不证明同一程序能在公开基线执行；RTL-v6 模块通过也不等于完整芯片运行研究 workload。

交换沿用原文件：`generated_asm_code.asm` → `generated_machine_code.mem`，HBM/FP SRAM/INT SRAM 镜像，`golden_result.pt`、`verification_params.json` 或 `comparison_params.json`；RTL 产生 `hbm_result.mem` 等写回镜像。不重新定义 ISA。

跨仓库运行前：

1. 固定双方 commit，并逐项核对 `operation.svh` 的 opcode/指令字段和目标 RTL 支持的指令。
2. 对照 `precision.svh` 与编译配置的 MX 格式、W/A/KV 位宽、FP EXP/MANT；对照 `configuration.svh` 的 MLEN/VLEN/BLEN、SRAM 容量和行数。
3. 由该硬件工程配套生成器生成镜像和指令偏移；不要手工改 offset。先用 tiny shape 跑 golden，再扩大形状。
4. 保存生成器、配置、机器码与结果的哈希，以及完整比较日志。不同 profile 的构建和测试顺序运行。

当前没有“研究 Simulator → RTL-v6 full core”或“研究 Simulator → 公开 RTL”的端到端兼容认证。
