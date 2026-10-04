"""Local import compatibility for unavailable pinned PLENA_Tools revision.

Only activated by CPU smoke scripts' PYTHONPATH; numerical equivalence to the
missing original revision is not established by this alias.
"""
from pathlib import Path

__path__ = [str(Path(__file__).resolve().parents[2] / "PLENA_Simulator/PLENA_Tools/plena_quant")]
