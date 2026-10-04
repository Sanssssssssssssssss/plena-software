"""Batched matrix multiplication workload generator for PLENA.

Generates test workloads for batched matrix multiplication:
(batch, m, k) @ (batch, k, n) -> (batch, m, n)
"""

import argparse
import sys
from pathlib import Path
from typing import Dict, Optional

import torch
from torch import Tensor

# Add necessary paths
_PROJECT_PATH = Path(__file__).resolve().parent.parent.parent
_TOOLS_PATH = _PROJECT_PATH / "tools"
if str(_TOOLS_PATH) not in sys.path:
    sys.path.insert(0, str(_TOOLS_PATH))

_PLENA_TOOLS_PATH = _PROJECT_PATH / "PLENA_Tools"
if str(_PLENA_TOOLS_PATH) not in sys.path:
    sys.path.insert(0, str(_PLENA_TOOLS_PATH))

_COMPILER_PATH = _PROJECT_PATH / "PLENA_Compiler"
if str(_COMPILER_PATH) not in sys.path:
    sys.path.insert(0, str(_COMPILER_PATH))

from .base import WorkloadGenerator

# Import after path setup
from asm_templates import batched_matmul_asm
from plena_utils.load_config import load_hardware_tile_sizes
from cfl_tools import SRC_PATH

# Load hardware tile sizes from configuration.svh
_HW_TILE_SIZES = load_hardware_tile_sizes(SRC_PATH / "definitions")


class BMMWorkload(WorkloadGenerator):
    """Batched matrix multiplication workload generator.

    Generates test data for: (batch, m, k) @ (batch, k, n) -> (batch, m, n)

    This is useful for attention-style computations where multiple
    matrix multiplications are batched together.

    This generates:
    - Random input tensor A: (batch, m, k)
    - Random input tensor B: (batch, k, n)
    - Golden result computed with quantized values
    - Assembly code for the operation
    - Compiled machine code
    - HBM memory files in hex format
    """

    # Hardware tile sizes (loaded from configuration.svh)
    MLEN = _HW_TILE_SIZES["MLEN"]  # Matrix tile size
    BLEN = _HW_TILE_SIZES["BLEN"]  # Vector tile size

    def __init__(
        self,
        batch: int = 4,
        m: int = 64,
        k: int = 64,
        n: int = 64,
        **kwargs,
    ):
        """Initialize BMM workload generator.

        Args:
            batch: Batch size
            m: First matrix rows
            k: Shared dimension (A cols / B rows)
            n: Second matrix cols
            **kwargs: Additional arguments passed to WorkloadGenerator

        Note:
            All dimensions must be divisible by MLEN or BLEN as appropriate:
            - k must be divisible by MLEN
            - m must be divisible by BLEN
            - n must be divisible by BLEN
        """
        super().__init__(**kwargs)

        # Validate dimensions against hardware constraints
        assert k % self.MLEN == 0, f"k must be divisible by {self.MLEN}"
        assert m % self.BLEN == 0, f"m must be divisible by {self.BLEN}"
        assert n % self.BLEN == 0, f"n must be divisible by {self.BLEN}"

        self.batch = batch
        self.m = m
        self.k = k
        self.n = n

    def generate(self) -> dict:
        """Generate BMM workload files.

        Returns:
            Dictionary with paths to all generated files
        """
        # Initialize output paths
        paths = self._init_memory_files()

        # 1. Generate random tensors
        # A: (batch, m, k) - activation-like tensor
        # B: (batch, k, n) - weight-like tensor
        tensor_a = torch.randn(self.batch, self.m, self.k)
        tensor_b = torch.randn(self.batch, self.k, self.n)

        # 2. Quantize tensors to MXFP
        q_tensor_a = self._quantize_to_mxfp(tensor_a.reshape(-1, self.k)).reshape(self.batch, self.m, self.k)
        q_tensor_b = self._quantize_to_mxfp(tensor_b.reshape(-1, self.n)).reshape(self.batch, self.k, self.n)

        # 3. Compute golden result (using quantized values)
        # torch.bmm expects (batch, m, k) @ (batch, k, n) -> (batch, m, n)
        golden_result = torch.bmm(q_tensor_a, q_tensor_b)

        # 4. Save raw tensors
        tensor_paths = self._save_tensors({
            "tensor_a": tensor_a,
            "tensor_b": tensor_b,
            "q_tensor_a": q_tensor_a,
            "q_tensor_b": q_tensor_b,
        })
        paths["tensors"] = tensor_paths

        # 5. Generate HBM memory files
        # Flatten tensors for HBM storage
        # Store in order: A then B
        flat_a = tensor_a.reshape(-1, self.k)  # (batch*m, k)
        flat_b = tensor_b.reshape(-1, self.n)  # (batch*k, n)

        ele_path, scale_path = self._save_hbm_hex([flat_a, flat_b], append=False)
        paths["hbm_ele"] = ele_path
        paths["hbm_scale"] = scale_path

        # 6. Generate assembly code
        asm_code = self._generate_assembly()
        machine_code_path = self._save_assembly(asm_code)
        paths["machine_code"] = machine_code_path
        paths["asm"] = self.build_dir / "generated_asm_code.asm"

        # 7. Initialize SRAM preload files (empty for basic BMM)
        paths["fp_sram"] = self._save_fp_sram_hex([0.0] * 8)
        paths["int_sram"] = self._save_int_sram_hex([0] * 8)

        # 8. Save golden result
        golden_paths = self._save_golden(golden_result)
        paths["golden"] = golden_paths

        # 9. Set environment variables
        self._set_env_vars(paths)

        return paths

    def _generate_assembly(self) -> str:
        """Generate assembly code for BMM operation.

        Returns:
            Assembly code string
        """
        # Register allocation for batched_matmul_asm
        # alive_registers: [a_actual, w_actual, result_actual]
        alive_registers = [1, 2, 3]

        # Prefetch amounts (how much data to prefetch at once)
        w_prefetch_amount = self.k  # Prefetch full K dimension
        a_prefetch_amount = self.k  # Prefetch full K dimension

        # Generate BMM assembly
        asm_code = batched_matmul_asm(
            mlen=self.MLEN,
            blen=self.BLEN,
            b=self.batch,
            m=self.m,
            k=self.k,
            n=self.n,
            alive_registers=alive_registers,
            w_base_hbm_offset_reg=0,  # Address register 0 for B tensor
            w_prefetch_amount=w_prefetch_amount,
            a_base_hbm_offset_reg=1,  # Address register 1 for A tensor
            a_prefetch_amount=a_prefetch_amount,
            result_base_address=0,  # Start of vector SRAM for results
        )

        return asm_code

    def get_config(self) -> dict:
        """Get the workload configuration.

        Returns:
            Dictionary with configuration parameters
        """
        return {
            "workload_type": "bmm",
            "batch": self.batch,
            "m": self.m,
            "k": self.k,
            "n": self.n,
            "mlen": self.MLEN,
            "blen": self.BLEN,
            "quant_config": self.quant_config,
            "seed": self.seed,
        }


def main():
    """CLI entry point for BMM workload generation."""
    parser = argparse.ArgumentParser(
        description="Generate batched matrix multiplication workload for PLENA RTL simulation"
    )
    parser.add_argument(
        "--batch", type=int, default=4,
        help="Batch size"
    )
    parser.add_argument(
        "--m", type=int, default=64,
        help="First matrix rows (must be divisible by 8)"
    )
    parser.add_argument(
        "--k", type=int, default=64,
        help="Shared dimension (must be divisible by 8)"
    )
    parser.add_argument(
        "--n", type=int, default=64,
        help="Second matrix cols (must be divisible by 8)"
    )
    # Alternative naming for attention-style workloads
    parser.add_argument(
        "--seq-len", type=int, default=None,
        help="Sequence length (sets m=seq_len, k=seq_len if provided)"
    )
    parser.add_argument(
        "--hidden", type=int, default=None,
        help="Hidden dimension (sets n=hidden if provided)"
    )
    parser.add_argument(
        "--build-dir", type=str, default=None,
        help="Output directory for generated files"
    )
    parser.add_argument(
        "--seed", type=int, default=42,
        help="Random seed for reproducibility"
    )
    args = parser.parse_args()

    # Handle attention-style naming
    m = args.m
    k = args.k
    n = args.n

    if args.seq_len is not None:
        m = args.seq_len
        k = args.seq_len
    if args.hidden is not None:
        n = args.hidden

    # Create workload generator
    workload = BMMWorkload(
        batch=args.batch,
        m=m,
        k=k,
        n=n,
        build_dir=args.build_dir,
        seed=args.seed,
    )

    # Generate files
    print(f"Generating BMM workload:")
    print(f"  Shape: ({args.batch}, {m}, {k}) @ ({args.batch}, {k}, {n})")
    print(f"  Build dir: {workload.build_dir}")

    paths = workload.generate()

    print(f"\nGenerated files:")
    for key, value in paths.items():
        if isinstance(value, dict):
            for subkey, subvalue in value.items():
                print(f"  {key}/{subkey}: {subvalue}")
        else:
            print(f"  {key}: {value}")

    print(f"\nConfiguration:")
    config = workload.get_config()
    for key, value in config.items():
        print(f"  {key}: {value}")


if __name__ == "__main__":
    main()
