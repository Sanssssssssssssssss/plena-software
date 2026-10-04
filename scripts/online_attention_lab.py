r"""第一课：GQA 的完整 attention 与分块 online softmax，CPU 可直接运行。

这是学习用数学实验；没有模拟低精度舍入、RTL 周期或 HBM 事务。
运行：.venv\Scripts\python.exe scripts\online_attention_lab.py
"""
import math

import torch


def streaming_attention(q, k, v, tile):
    # q/k/v: [batch, query_heads, sequence, head_dim]；这里已做 GQA 的 KV 共享展开。
    b, heads, length, dim = q.shape
    assert tile > 0 and k.shape == v.shape == q.shape
    # 每个 query 行只保存 m（历史最大值）、l（分母）、o（未归一化加权和）。
    m = torch.full((b, heads, length, 1), -torch.inf, dtype=q.dtype)
    l = torch.zeros_like(m)
    o = torch.zeros_like(q)
    query_positions = torch.arange(length)[:, None]
    for start in range(0, length, tile):
        stop = min(start + tile, length)
        scores = q @ k[:, :, start:stop].transpose(-1, -2) / math.sqrt(dim)
        # causal mask：query i 不能看未来 key j>i。先处理左侧 tile，避免全空初始行。
        scores.masked_fill_(query_positions < torch.arange(start, stop)[None, :], -torch.inf)
        new_m = torch.maximum(m, scores.amax(-1, keepdim=True))
        # 最大值改变后，旧分母和旧输出都必须搬到新的指数基准；漏乘 alpha 是常见错误。
        alpha = torch.exp(m - new_m)
        p = torch.exp(scores - new_m)
        l = alpha * l + p.sum(-1, keepdim=True)
        o = alpha * o + p @ v[:, :, start:stop]
        m = new_m
    return o / l


if __name__ == "__main__":
    torch.manual_seed(42)
    b, hq, hkv, s, d = 2, 4, 2, 33, 8
    q = torch.randn(b, hq, s, d, dtype=torch.float64)
    k = torch.randn(b, hkv, s, d, dtype=torch.float64)
    v = torch.randn_like(k)
    # Hq/Hkv=2：每两个 query heads 共享同一组 K/V；硬件应复用读取，不必真的复制。
    k, v = (x.repeat_interleave(hq // hkv, dim=1) for x in (k, v))
    scores = q @ k.transpose(-1, -2) / math.sqrt(d)
    scores.masked_fill_(torch.ones(s, s, dtype=torch.bool).triu(1), -torch.inf)
    reference = torch.softmax(scores, -1) @ v
    # 非整除 tile 专门覆盖尾块；改变 tile 不应改变数学结果。
    for tile in (1, 4, 8, 16, 33):
        actual = streaming_attention(q, k, v, tile)
        torch.testing.assert_close(actual, reference, rtol=1e-12, atol=1e-12)
        print(f"tile={tile:2d}, max_abs_error={(actual-reference).abs().max().item():.3e}, PASS")
