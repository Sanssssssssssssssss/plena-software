"""PLENA Test Workload Generators.

This package provides workload generators for PLENA RTL simulation testing.
Each generator creates test data, assembly code, and memory files needed
to run a specific operation on the PLENA hardware.

Usage:
    from tools.testworkloads import LinearWorkload, BMMWorkload, PrefetchWorkload, RMSNormWorkload

    # Generate a linear layer workload
    workload = LinearWorkload(batch_size=8, in_features=128, out_features=256)
    paths = workload.generate()

    # Generate a batched matrix multiply workload
    workload = BMMWorkload(batch=4, m=64, k=64, n=64)
    paths = workload.generate()

    # Generate a prefetch-only workload (data movement only, no computation)
    workload = PrefetchWorkload(batch_size=8, in_features=128)
    paths = workload.generate()

    # Generate an RMS normalization workload
    workload = RMSNormWorkload(batch_size=8, hidden_size=128)
    paths = workload.generate()

CLI Usage:
    # Linear workload
    python -m tools.testworkloads.linear --batch 8 --in-features 128 --out-features 256

    # BMM workload
    python -m tools.testworkloads.bmm --batch 4 --m 64 --k 64 --n 64

    # Prefetch workload
    python -m tools.testworkloads.prefetch --batch 8 --in-features 128

    # RMS norm workload
    python -m tools.testworkloads.rms_norm --batch 8 --hidden-size 128
"""

from .base import WorkloadGenerator
from .linear import LinearWorkload
from .bmm import BMMWorkload
from .prefetch import PrefetchWorkload
from .rms_norm import RMSNormWorkload

__all__ = [
    "WorkloadGenerator",
    "LinearWorkload",
    "BMMWorkload",
    "PrefetchWorkload",
    "RMSNormWorkload",
]
