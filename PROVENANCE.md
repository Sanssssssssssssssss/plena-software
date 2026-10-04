# 来源、版本与仓库内容

基于 AICrossSim PLENA 开展学习整理与局部复现。上游算法、编译器、RTL 和历史研究数据归原作者；本仓库新增学习文档、中文注释、运行入口、小实验和证据核对。

| 内容 | 来源 / 固定版本 |
|---|---|
| 主仓库 | [AICrossSim/PLENA](https://github.com/AICrossSim/PLENA)，`5b06df9ab13840b8834766311313e2d27bfbebed` |
| Prefill 分支 | [PLENA_Simulator](https://github.com/AICrossSim/PLENA_Simulator)，`fddfcb9a7c3eaa1ad9f1c24da829a4422b324650` |
| 研究 Compiler | [PLENA_Compiler](https://github.com/AICrossSim/PLENA_Compiler)，`0ba3b657725bf083feec06c8e356e2d6235cd4d5` |
| 研究 Tools 替代 | [PLENA_Tools](https://github.com/AICrossSim/PLENA_Tools)，`0f10353947eb442c73f27f4ed30925f3e83e73a1`；原要求 `a359963…` 未获得 |
| 官方文档 | [PLENA_Doc](https://github.com/AICrossSim/PLENA_Doc)，`7bf6d7636a3298159686773f4343cb7d7d743f17` |
| `lab/rtl-prefill/` | 用户提供 RTL 归档的 tracked HEAD `1e0eb060118669afbb8d03b100d1bdbd30c76cdd`；当前无法从公共 RTL remote 获取，故保存源码副本 |
| 归档 Compiler / Tools | `17b2bd098570ae85a652e0c911bd4fbca534bea7` / `af11f546094f0c3d8a158913cbd95d4da8349ee2` |

原归档 `03_PLENA_RTL_source_20260924.tar.zst` 的 SHA256：

```text
979103A40F877590A4A8213F35DA4E3269CB889BF3E10E850BF5ED2B57026CC8
```

大归档和旧 build 留在本机；运行副本来自 tracked HEAD，未包含归档工作树中两份修改过的 Synopsys debug 脚本。历史 XML 单独保存，成功和失败均保留。

**阅读副本**

`study/core` 的 14 个文件只新增中文注释，02/03 为选段。[sources.json](study/core/sources.json) 保存原路径、行段、哈希、注释数；[生成脚本](study/build_reading_copy.py)核对还原原文与 Python AST。阅读副本不作为独立运行模块。

**许可与归属**

各来源的许可和版权声明继续适用，本仓库没有为整个组合仓库授予统一新许可。当前公开 RTL main 提供 Apache-2.0 与第三方声明；归档版本和部分研究仓库没有同样的顶层许可文件，不能据此自动扩大授权。参考[上游许可](https://github.com/AICrossSim/PLENA_RTL/blob/783ee48ea81607308aba40a7dfe83b52868d1b71/LICENSE)和[第三方说明](https://github.com/AICrossSim/PLENA_RTL/blob/783ee48ea81607308aba40a7dfe83b52868d1b71/THIRD_PARTY_LICENSES.md)。

源码已有的 lowRISC/OpenTitan、TileLink 等声明保留。DesignWare wrapper 的综合路径需要相应授权和库；本仓库没有包含 Synopsys 安装环境或模型权重。

**证据**

[evidence](study/evidence/2026-10-04) 包括本次真实运行、导入历史 XML 与历史表重算。复制时仅将机器路径替换为占位符，manifest 保存复制前后哈希；历史材料没有改标为本机新测量。详见[manifest](study/evidence/2026-10-04/manifest.json)。
