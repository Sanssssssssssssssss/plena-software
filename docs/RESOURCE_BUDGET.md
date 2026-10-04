> 本文保留 2026-10-04 初次整理的观察和历史条件；独立仓库的新验收见 [VALIDATION](VALIDATION.md)。

**本机已经能做的实验与完整复现预算**

机器实查：Core Ultra 9 185H，16 核/22 线程，物理内存约 31.42 GiB，RTX 4070 Laptop 8188 MiB；WSL Ubuntu 可见内存约 15 GiB、swap 4 GiB。[硬件收据](../evidence/history-2026-10-04/local-hardware.json)。

本地环境独立放在 `.venv`（Windows CPU Python）与 `.venv-wsl`（Linux RTL 工具）。CPU PyTorch 2.7.1，不需要加载真实 32B/235B 权重。WSL 使用 PyPI 打包的 Verilator 5.34.0 和 cocotb 1.9.2。

**直接运行**

所有 PowerShell 命令先进入工作目录：

当前入口见 [软件 README](../README.md) 与 [硬件 README](https://github.com/Sanssssssssssssssss/plena-hardware)。下面的计时表是初次整理记录。

| 入口 | 本次结果 | 验证范围 / 耗时 |
|---|---|---|
| `run_cpu.py` | PASS，Linear 158 条机器码 | 数学实验、10 项立即数测试、生成器、旧解析 smoke；总约 4.2s |
| 上游完整 large-immediate suite | 26 PASS | 已单独运行约 99.1s；日常入口只保留 10 项轻量检查 |
| `run_prefill_checks.ps1` | 3 PASS | RTL-v6 编译 lowering、指标语义、跨阶段 idle energy；pytest 2.07s |
| `trace_experiment.py` | PASS | v5/R1/R4 固定 tiny shape 编译；各约 0.44–0.47s，不含 Python/Torch 启动 |
| `run_rtl.sh` | 2 PASS | 四行 Softmax、VLEN8、E5M6；首次成功 build+test 约 97.1s，缓存复跑 15.17s |
| `audit_evidence.py` | PASS | 版本、文件存在性、XML 计数、历史比例和内存算术；不重新测性能 |

CPU 日志见[cpu-receipt.json](../evidence/history-2026-10-04/cpu-receipt.json)。[首次成功 RTL 日志](../evidence/history-2026-10-04/rtl-softmax-first-success.log)中用例本身分别约 0.061s / 0.005s，多数时间用于工具启动和生成、编译 C++；这些秒数不能当目标芯片执行时间。

初次整理的脚本输出曾位于 `study/logs` 与 `study/runs/linear`；当前两个仓库均使用自己的 `runs/`，硬件构建另在所属工程的 `build/`。硬件 `scripts/run_rtl.py` 在结束时还原生成器修改的 `configuration.svh`。保留实验时另存目录，不同时启动修改同一配置/构建目录的作业。

**环境中需要知道的差异**

1. 研究分支要求 `PLENA_Tools=a359963…`，远端与现有包中均未获得。当前替代为 `0f103539…`，当前 `scripts/quant` 仅兼容旧导入名称；通过 focused checks 不代表两个 Tools 版本数值等价。
2. 上游 editable 安装没有暴露旧 `quant` 包名，学习入口显式设置局部 PYTHONPATH。安装记录和依赖列表保存在[Windows requirements](../evidence/history-2026-10-04/requirements-windows.txt)与[WSL requirements](../evidence/history-2026-10-04/requirements-wsl.txt)。
3. WSL 网络下载在本次失败，因此通过 Windows 下载 Linux wheels 后离线安装，缓存位于 `.cache/linux-wheels`。没有要求安装全局 CUDA 环境。
4. Verilator wheel 的 make 配置遗漏 GCC PCH 的 `-include`，`run_rtl.sh` 用局部 MAKEFLAGS 补齐并限制 4 个编译任务。仿真报告识别 Verilator 5.34；这个工具构建并非原作者完整环境镜像。
5. 压缩包运行副本导出自 tracked HEAD，原包的两份 dirty Synopsys debug 脚本仍保留在快照目录。DC 综合需要相应授权和工艺库，本次未运行。

旧解析 `llama_model.py` 在 Qwen3 上用 hidden/head_count 推导 head_dim，而目标配置显式为 128；其 smoke 输出不能用来支持简历结论。学习性能模型时使用研究分支。

**权重和 KV 到底需要多少内存**

权重粗估 `参数量 × 位宽 / 8`；对 GQA，KV 存储为：

\[
M_{KV}=2\times L\times H_{KV}\times D\times S\times B\times b_{KV}/8.
\]

以下用 B=8、最终序列 S=90,000+8,000=98,000，32B 的 L/Hkv/D=64/8/128，235B 为 94/4/128。权重参数量按型号近似；单位是十进制 GB：

| 模型 | 16-bit 权重 | 4-bit 权重 | 16-bit KV | 4-bit KV | 4-bit 权重+KV |
|---|---:|---:|---:|---:|---:|
| 32B | 64.0 | 16.0 | 205.52 | 51.38 | 67.38 |
| 235B | 470.0 | 117.5 | 150.93 | 37.73 | 155.23 |

KV 形状参考[32B 本地配置](https://github.com/AICrossSim/PLENA_Compiler/blob/d89ad594c798daa54f63f914aebad5317653489a/doc/Model_Lib/qwen3-32b.json)与[Qwen 官方 235B 配置](https://huggingface.co/Qwen/Qwen3-235B-A22B-Instruct-2507/raw/main/config.json)。存储计算脚本见 `audit_evidence.py`。

这些数未含 scale、zero-point、量化打包约束、激活、workspace、KV 分页、通信 buffer、复制和框架占用。W4/A4/KV4 的模型格式也不表示现成 vLLM 内核能直接运行同一格式。即使纯容量看似够，还要确认软件支持及合法 TP/EP 配置。

8 GB GPU 连名义 32B 的纯 4-bit 权重也放不下；本机适合小 shape 和 CPU 编译/成本模型。235B 的 A22B 表示每 token 活跃量，不意味着只需存 22B 权重。CPU offload 可改变容量分配，但不能视为同硬件基线。

如果用朴素 attention 存完整 score，B8、Hq64、S90k、FP16 就约 `8×64×90000²×2 = 8.29 TB`，还没算其他张量；这也是学习 online/block attention 时必须理解的资源问题。小数学 reference 验证算法，长序列执行需要流式内核。

**8.2 万 DSE 的 CPU 时间怎么估**

搜索每个点主要运行编译成本模型，不需要把 32B 权重完整放进 GPU。当前 tiny 编译约 0.45s 只能描述 tiny 配置；90k 长序列、MoE、拓扑搜索及模型缓存会显著改变成本。

先补齐依赖和基础配置，再固定目标工作负载，选 8–16 个覆盖不同 R/阵列/拓扑的候选，记录单点 wall time、峰值 RSS、缓存状态和 PRUNED 比例。有效并行度 p 受内存与 CPU 竞争约束，不能直接用 22 线程代入。

\[
T\approx(N_c t_c+N_p t_p)/p_{effective}+T_{setup}+T_{serial}.
\]

仅对 81,920 个完成点，忽略剪枝及其他开销的情景计算：

| 每个完成点均耗时 | p=4 | p=8 |
|---|---:|---:|
| 1s | 5.69h | 2.84h |
| 10s | 56.89h | 28.44h |
| 60s | 341.33h | 170.67h |

这些是算术情景，不是本机完整 DSE 的实测预测。历史 attempts 为 191,886，pruned 点也有代价。WSL 目前约 15 GiB 内存，应先测单点 RSS 再扩 worker；symbolic compression/缓存对速度的影响可能大于增加进程数。

**完整实验需要分别预算**

| 工作 | 合适资源 / 当前材料 |
|---|---|
| 数学、编译、模块 RTL | 本机可运行，现有入口和日志已齐 |
| 目标 90k 单层成本 A/B、小 DSE | 以 CPU 为主；先修复缺失的版本与正式配置，再用少量候选测量 |
| Ramulator2 校准 | Linux CPU、可复现 DMA traces、Ramulator 配置；需要构建该工具链和复查模型误差 |
| DC 面积/活动能耗校准 | DC 授权、对应 ASAP7/宏库、约束、切换活动和原始报告；单凭 RTL 不足以恢复全部校准 |
| 32B/235B 准确率 | 支持相同量化路径的多 GPU、权重、BFCL 样本及逐题日志；可先取回历史产物 |
| A100/vLLM 系统基线 | 与作者记录匹配的多卡 A100 拓扑、固定软件栈、输出时序、功耗采样；历史实测平台为 8×A100，12/16 卡结果含外推 |

GPU 预算用 `卡数 × 作业小时 × 当时单卡小时价 + 存储/传输`，应先用一个完整代表点含加载、预热和失败重试计时。本次未发起云 GPU 作业；也没有使用估算数去补写缺失的历史测量。

建议你现在先完成：数学递推 → 小编译 A/B → R4 RTL 三步。每一步写一页自己的预测、观测和解释；这三页会比背一串最终百分比更接近独立做项目的能力。
