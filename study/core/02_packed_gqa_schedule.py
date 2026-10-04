# 学习注： 来源 PLENA-Prefill/PLENA_Compiler/aten/plena/program_attention.py，原始行 1–103。
# 学习注： 这是核心阅读副本；运行仍用原目录及其依赖。只新增注释，没有修改逻辑。
"""Flash-attention operations for the PLENA program builder."""

from __future__ import annotations

import math
import os
from dataclasses import dataclass

from compiler.asm_templates._imm import IMM2_BOUND, add_large_int, load_large_int
from compiler.aten.isa_builder import RepeatAxis
from compiler.aten.plena.kv_residency import KVResidencyPlan, plan_kv_residency
from compiler.aten.plena.native_layout import SoftmaxRowGroupPlan
from compiler.aten.plena.vars import InputVar, VRAMMatrixVar


@dataclass(frozen=True)
# 学习注：同一 KV head 对应多个 Q heads。目标是打包利用阵列并复用 KV 数据。
class PackedGQASchedule:
    """Compile-time schedule for one logical packed-GQA attention block."""

    batch_size: int
    seq_len: int
    kv_seq_len: int
    rows_per_batch: int
    num_kv_heads: int
    gqa_ratio: int
    physical_broadcast: int
    chunks_per_kv: int
    full_chunks: int
    tail_heads: int
    q_blocks: int
    k_blocks: int
    resident_kv: bool
    resident_kv_tiles: int
    kv_residency_plan: KVResidencyPlan

    @classmethod
    # 学习注：这里只建立调度计划，没有运行 attention 数值计算。
    def build(
        cls,
        *,
        batch_size: int,
        seq_len: int,
        kv_seq_len: int,
        rows_per_batch: int,
        num_kv_heads: int,
        gqa_ratio: int,
        physical_broadcast: int,
        mlen: int,
        mram_tile_capacity: int,
        kv_residency_policy: str = "raw-tiles",
    ) -> "PackedGQASchedule":
        values = {
            "batch_size": batch_size,
            "seq_len": seq_len,
            "kv_seq_len": kv_seq_len,
            "rows_per_batch": rows_per_batch,
            "num_kv_heads": num_kv_heads,
            "gqa_ratio": gqa_ratio,
            "physical_broadcast": physical_broadcast,
            "mlen": mlen,
            "mram_tile_capacity": mram_tile_capacity,
        }
        # 学习注：合法 shape 先检查，否则后面的 ceil 和地址计算会掩盖配置错误。
        for name, value in values.items():
            if value <= 0:
                raise ValueError(f"{name} must be positive, got {value}")
        if rows_per_batch < max(seq_len, kv_seq_len):
            raise ValueError(
                f"rows_per_batch={rows_per_batch} cannot cover "
                f"seq_len={seq_len}, kv_seq_len={kv_seq_len}"
            )

        # 学习注：逻辑 GQA 比例不一定等于物理广播宽度；不足一组会产生 head tail。
        chunks_per_kv = math.ceil(gqa_ratio / physical_broadcast)
        full_chunks, tail_heads = divmod(gqa_ratio, physical_broadcast)
        # 学习注：query 和 key 都按 MLEN 切块；长上下文的工作量来自块对组合。
        q_blocks = math.ceil(seq_len / mlen)
        k_blocks = math.ceil(kv_seq_len / mlen)
        resident_kv_tiles = 2 * k_blocks
        # 学习注：SRAM 是否放得下 K/V 决定 streaming 或部分驻留，直接影响重复 DMA。
        residency = plan_kv_residency(
            k_blocks=k_blocks,
            mlen=mlen,
            matrix_sram_tiles=mram_tile_capacity,
            requested_residency_fraction=(
                0.0 if kv_residency_policy == "streaming" else None
            ),
            policy=kv_residency_policy,
            force_streaming=kv_residency_policy == "streaming",
        )
        # 学习注：编译输出和成本统计应共用这个计划，避免性能模型统计另一套算法。
        return cls(
            batch_size=batch_size,
            seq_len=seq_len,
            kv_seq_len=kv_seq_len,
            rows_per_batch=rows_per_batch,
            num_kv_heads=num_kv_heads,
            gqa_ratio=gqa_ratio,
            physical_broadcast=physical_broadcast,
            chunks_per_kv=chunks_per_kv,
            full_chunks=full_chunks,
            tail_heads=tail_heads,
            q_blocks=q_blocks,
            k_blocks=k_blocks,
            resident_kv=residency.full_resident,
            resident_kv_tiles=resident_kv_tiles,
            kv_residency_plan=residency,
        )

