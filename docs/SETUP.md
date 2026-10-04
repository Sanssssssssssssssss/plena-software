# 软件环境与完整研究入口

日常 CPU 检查使用根目录 `requirements-cpu.txt` 和 `scripts/run_cpu.py`，Windows/Linux 均按自己的 Python 路径运行。入口把 `scripts`（旧 quant 包名别名）、Simulator、Compiler、Tools 加入 PYTHONPATH，环境不依赖归档工作区。

## 事务级模拟器

完整 Rust 工程在 `PLENA_Simulator/transactional_emulator/`，保留 Cargo 清单、测试平台、原 Docker/Nix 配置。需要 Rust/Cargo、just 和对应 Python 依赖：

```bash
cd PLENA_Simulator
just docker-dev
# 容器中按上游 justfile:
just test-aten-linear
# 或生成并运行既有工作负载：just build-emulator <testbench-name>
```

直接构建入口为 `cargo build --release --manifest-path PLENA_Simulator/transactional_emulator/Cargo.toml`。原 Docker/Nix 配置完整保留，但本轮未构建容器或运行事务级模拟器；缺失 Tools pin 仍需留意。详见 [原模拟器 README](../PLENA_Simulator/README.md) 和 [justfile](../PLENA_Simulator/justfile)。

## 量化与 BFCL

`PLENA_Software` 是独立软件项目，保留 `pyproject.toml`、`uv.lock`、`calib`、`quant_eval`、`prefill_DSE`、测试和内嵌 OSWorld。不要把根目录 CPU smoke 环境当作其完整 CUDA 环境。

在有匹配 CUDA/PyTorch 的机器上按 [软件原 README](../PLENA_Software/README.md) 与 [getting-started](../PLENA_Software/docs/getting-started.md) 建独立环境：

```bash
cd PLENA_Software
uv sync
source env.local.sh
python prefill_DSE/run_prefill_dse.py --help
```

GPU 原栈包含 MASE、CUDA PyTorch 与 fast-hadamard-transform；安装也可能需要编译工具和模型访问。这里仅保留入口，本轮未运行此安装和评测。

`prefill_DSE/search_space_qwen3.yaml` 是代码默认引用但未随研究 commit 提供的文件；必须取回原配置或显式传入自己的配置。没有伪造“原始配置”。研究 Workspace 另有模型 JSON、trial 基础配置及最终结果缺失，见 [结果核对](RESULTS.md)。已有 `plena_settings.toml` 不能自动替代所有历史试验配置。

## 产物边界

根目录 smoke 写 `runs/`；量化和 Workspace 脚本有各自输出路径，启动前读参数并固定实验目录。模型、虚拟环境、缓存和大型构建产物均不应提交。新配置必须另起实验名，并标注为新示例/新实验。
