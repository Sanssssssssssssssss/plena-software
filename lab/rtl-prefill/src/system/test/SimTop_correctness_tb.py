#!/usr/bin/env python3
"""
Full-system RTL correctness test for PLENA.

Strategy:
  1. Generate a linear program via PLENAProgram (BLEN=8, MLEN=16).
  2. Compute float32 golden output: Y = X_mxfp.T @ W_mxfp.
  3. Set up HBM mem files and run cocotb/Verilator simulation.
  4. Capture matrix-machine output rows via m_out_v_fp handshake.
  5. Decode 12-bit FP (E6M5) from captured rows and compare to golden.
"""

import json
import os, logging, re
import sys
from pathlib import Path

_RTL_ROOT = Path(__file__).resolve().parents[3]
_PLENA_TOOLS = _RTL_ROOT / "PLENA_Tools"
_COMPILER_ROOT = _RTL_ROOT / "PLENA_Compiler"
for _p in [str(_PLENA_TOOLS), str(_COMPILER_ROOT)]:
    if _p not in sys.path:
        sys.path.insert(0, _p)

_RTL_TOOLS = str(_RTL_ROOT / "tools")
if _RTL_TOOLS not in sys.path:
    sys.path.insert(0, _RTL_TOOLS)

import torch
import pytest
import cocotb
from cocotb.log import SimLog
from cocotb.triggers import Timer, RisingEdge
from cfl_cocotb.runner import veri_runner, SRC_PATH
from cfl_cocotb.testbench import Testbench
from cfl_cocotb.streaming import StreamDriver
from plena_quant.mxfp import bin_2_fp

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from sim_env_utils.build_sys_tools import init_mem
from memory_mapping.memory_map import map_data_to_fake_hbm_for_rtl_sim

from cfl_tools.logger import get_logger

logger = get_logger("correctness_tb")
logger.setLevel(logging.INFO)

CORRECTNESS_DEBUG = os.getenv("SIMTOP_DIAG")
SIMTOP_TRACE = os.getenv("SIMTOP_TRACE", "0") == "1"
SIMTOP_TIMEOUT_US = int(os.getenv("SIMTOP_TIMEOUT_US", "10000"))
SIMTOP_DIAG_CYCLES = int(os.getenv("SIMTOP_DIAG_CYCLES", "220"))

INSTRUCTION_LENGTH = 64
MLEN = 16
BLEN = 8
HBM_V_PREFETCH_AMOUNT = 16
VALID_ROWS = MLEN
V_FP_EXP_WIDTH  = 6
V_FP_MANT_WIDTH = 5
V_FP_BITS = 1 + V_FP_EXP_WIDTH + V_FP_MANT_WIDTH


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _quantize_to_kvmx(tensor: torch.Tensor) -> torch.Tensor:
    from plena_quant.mxfp import _mx_fp_quantize_hardware
    bm_x, _, _, _ = _mx_fp_quantize_hardware(
        tensor, width=4, exponent_width=1, exponent_bias_width=8, block_size=[8])
    return bm_x.reshape(tensor.shape)


def _quantize_to_actmxfp(tensor: torch.Tensor) -> torch.Tensor:
    from plena_quant.mxfp import _mx_fp_quantize_hardware
    bm_x, _, _, _ = _mx_fp_quantize_hardware(
        tensor, width=8, exponent_width=4, exponent_bias_width=8, block_size=[8])
    return bm_x.reshape(tensor.shape)


def _load_precision_settings() -> dict:
    pat = re.compile(r"\s*(?:parameter|localparam)\s+(?:\w+\s+)?(\w+)\s*=\s*(\d+)")
    settings = {}
    with open(str(SRC_PATH / "definitions" / "precision.svh")) as f:
        for line in f:
            m = pat.match(line)
            if m:
                settings[m.group(1)] = int(m.group(2))
    return settings


def _decode_row(row_int: int) -> list:
    mask = (1 << V_FP_BITS) - 1
    return [float(bin_2_fp((row_int >> (i * V_FP_BITS)) & mask,
                           exp_width=V_FP_EXP_WIDTH, mant_width=V_FP_MANT_WIDTH))
            for i in range(MLEN)]


def _lower_loop_pseudo_ops(asm_text: str) -> str:
    """Expand compiler loop pseudo-ops before assembling for RTL.

    The RTL decoder does not implement C_LOOP_START/C_LOOP_END. Treat them as
    software-side pseudo-instructions and textually unroll their bodies.
    """
    loop_start_re = re.compile(r'^C_LOOP_START\s+(gp\d+),\s*(\d+)\b')
    loop_end_re = re.compile(r'^C_LOOP_END\s+(gp\d+)\b')
    lines = asm_text.split('\n')

    def parse_block(index: int, end_reg: str | None = None) -> tuple[list[str], int]:
        lowered = []
        while index < len(lines):
            line = lines[index]
            stripped = line.strip()

            start_match = loop_start_re.match(stripped)
            if start_match:
                reg = start_match.group(1)
                count = int(start_match.group(2))
                body, index = parse_block(index + 1, reg)
                for _ in range(count):
                    lowered.extend(body)
                continue

            end_match = loop_end_re.match(stripped)
            if end_match:
                reg = end_match.group(1)
                if end_reg is None:
                    raise ValueError(f"Unexpected {stripped}")
                if reg != end_reg:
                    raise ValueError(f"Mismatched loop end {reg}; expected {end_reg}")
                return lowered, index + 1

            lowered.append(line)
            index += 1

        if end_reg is not None:
            raise ValueError(f"Missing C_LOOP_END {end_reg}")
        return lowered, index

    lowered, _ = parse_block(0)
    lowered_text = '\n'.join(lowered)
    if re.search(r'^\s*C_LOOP_(?:START|END)\b', lowered_text, flags=re.MULTILINE):
        raise ValueError("Loop pseudo-op lowering left C_LOOP_START/C_LOOP_END in ASM")
    return lowered_text


def _insert_pipeline_bubbles(asm_text: str) -> str:
    """Insert 2 NOP bubbles before instructions that read registers (RAW hazard)."""
    nop = 'S_ADDI_INT gp0, gp0, 0'
    _MM_RE = re.compile(r'^M_MM\b(?!_WO)')
    targets = ('C_SET_ADDR_REG', 'C_SET_SCALE_REG', 'C_SET_STRIDE_REG',
               'H_PREFETCH_M', 'H_PREFETCH_V', 'M_MM_WO')
    result = []
    for line in asm_text.split('\n'):
        stripped = line.strip()
        if stripped.startswith(targets) or _MM_RE.match(stripped):
            result.append(nop)
            result.append(nop)
        result.append(line)
    return '\n'.join(result)


def _dequant_mx_blocks(blocks, bias, exp_width, man_width, block_size, num_rows, scale_bias=127):
    """Dequantize MX blocks + bias back to float, matching RTL's interpretation."""
    num_blocks_per_row = MLEN // block_size
    elem_bias = 1 if exp_width == 1 else ((1 << (exp_width - 1)) - 1)
    rows = []
    total_rows = len(blocks) // num_blocks_per_row
    assert total_rows == num_rows, f"Block count implies {total_rows} rows, expected {num_rows}"
    for row_idx in range(total_rows):
        row_vals = []
        for blk_idx in range(num_blocks_per_row):
            flat_idx = row_idx * num_blocks_per_row + blk_idx
            block = blocks[flat_idx]
            scale = int(bias[flat_idx])
            for elem_int in block:
                sign     = (elem_int >> (exp_width + man_width)) & 1
                exp_bits = (elem_int >> man_width) & ((1 << exp_width) - 1)
                mant_bits = elem_int & ((1 << man_width) - 1)
                if exp_bits == 0:
                    val = (mant_bits / (1 << man_width)) * (2.0 ** (1 - elem_bias))
                else:
                    val = (1.0 + mant_bits / (1 << man_width)) * (2.0 ** (exp_bits - elem_bias))
                if sign:
                    val = -val
                val *= 2.0 ** (scale - scale_bias)
                row_vals.append(val)
        rows.append(row_vals)
    return torch.tensor(rows, dtype=torch.float32)


def _sim_asm_registers(asm_text):
    """Extract V-scale base and W HBM base from generated ASM by simulating registers."""
    regs = {f'gp{i}': 0 for i in range(16)}
    v_scale_base, w_hbm_base = None, None
    a0_reg = 0
    in_w_section = False
    for raw_line in asm_text.split('\n'):
        line = raw_line.strip()
        if line.startswith(';'):
            if 'Load SubMatrix Col W' in line:
                in_w_section = True
            continue
        m = re.match(r'S_ADDI_INT\s+(gp\d+),\s+(gp\d+),\s+(-?\d+)', line)
        if m:
            regs[m.group(1)] = regs.get(m.group(2), 0) + int(m.group(3)); continue
        m = re.match(r'S_LUI_INT\s+(gp\d+),\s+(-?\d+)', line)
        if m:
            regs[m.group(1)] = int(m.group(2)) << 12; continue
        m = re.match(r'C_SET_SCALE_REG\s+(gp\d+)', line)
        if m and v_scale_base is None and not in_w_section:
            v_scale_base = regs.get(m.group(1), 0); continue
        m = re.match(r'C_SET_ADDR_REG\s+a0,\s+(gp\d+),\s+(gp\d+)', line)
        if m:
            a0_reg = regs.get(m.group(1), 0) + regs.get(m.group(2), 0); continue
        if re.match(r'H_PREFETCH_M\b', line) and w_hbm_base is None:
            w_hbm_base = a0_reg
    return v_scale_base or 0, w_hbm_base or 0


# ---------------------------------------------------------------------------
# Cocotb testbench
# ---------------------------------------------------------------------------

class SimTopCorrectness(Testbench):
    def __init__(self, dut) -> None:
        super().__init__(dut, dut.clk, dut.rst)
        if not hasattr(self, "log"):
            self.log = SimLog("%s" % type(self).__qualname__)
        self.driver = StreamDriver(
            dut.clk, dut.instruction, dut.instruction_valid, dut.instruction_ready)
        self.captured_rows: list = []

    async def _capture_matrix_out(self):
        """Background coroutine: record every matrix-machine output row."""
        cycle = 0
        while True:
            await RisingEdge(self.dut.clk)
            cycle += 1
            try:
                valid = int(self.dut.dut.m_out_valid.value)
            except Exception:
                continue
            if CORRECTNESS_DEBUG and (cycle <= SIMTOP_DIAG_CYCLES or cycle % 500 == 0):
                self._log_diagnostics(cycle, valid, 1)
            if valid:
                try:
                    row_val = int(self.dut.dut.m_out_v_fp.value)
                    self.captured_rows.append(row_val)
                except ValueError:
                    self.log.warning(f"m_out_v_fp has X bits at cycle {cycle}")

    def _log_diagnostics(self, cycle, valid, ready):
        """Log pipeline signals for debugging (only when SIMTOP_DIAG is set)."""
        def _s(sig):
            try: return int(sig.value)
            except: return '?'

        d = self.dut.dut
        iv  = _s(self.dut.instruction_valid)
        ir  = _s(self.dut.instruction_ready)
        exe_mop = _s(d.dbg_exe_m_op)
        dec_mop = _s(d.dbg_dec_m_op)
        exe_cop = _s(d.dbg_exe_c_op)
        stall = _s(d.pipeline_stall)
        hmip = _s(d.hbm_m_prefetch_in_progress)
        hvip = _s(d.hbm_v_prefetch_in_progress)
        hmreq = _s(d.hbm_m_req_prefetch_data)
        hvreq = _s(d.hbm_v_req_prefetch_data)
        hmval = _s(d.hbm_m_prefetch_valid)
        hvval = _s(d.hbm_v_prefetch_valid)
        me  = _s(d.m_mcu_active)
        mmv = _s(d.m_m_valid)
        clq = _s(d.dbg_complete_loading_q)
        wfo = _s(d.matrix_machine_init.wait_for_output)
        eip = _s(d.matrix_machine_init.mcu_active)
        pc = d.pipeline_control_init
        pc_stall = _s(pc.pipeline_stall)
        pc_sip = _s(pc.stall_in_process)
        pc_memv = _s(pc.mem_vwrite_stall_req)
        det_op = _s(pc.determine_stage_op)
        exe_op = _s(pc.exe_stage_op)

        self.log.info(
            f"cyc={cycle:5d} instr={iv}/{ir} m_out={valid}/{ready} cap={len(self.captured_rows)} "
            f"stall={stall} pc={pc_stall}/{pc_sip}/{pc_memv} dec_m={dec_mop} exe_m/c={exe_mop}/{exe_cop} "
            f"det/exe=0x{det_op:x}/0x{exe_op:x} "
            f"hbm_m={hmip}:{hmreq}/{hmval} hbm_v={hvip}:{hvreq}/{hvval} "
            f"m_empty={me} m_m_v={mmv} clq={clq} wfo={wfo} eip={eip}")

    async def run_test(self, inputs, batch_size: int = 64):
        capture_task = cocotb.start_soon(self._capture_matrix_out())
        try:
            await self.reset()
            self.driver.load_driver(inputs)
            for _ in range(max(1, SIMTOP_TIMEOUT_US // 100)):
                await Timer(100, units="us")
                if len(self.captured_rows) >= batch_size:
                    break
        finally:
            capture_task.kill()


@cocotb.test()
async def test_correctness(dut):
    instr_file = Path(os.environ["INSTR_FILE"])
    inputs = []
    with open(instr_file) as f:
        for line in f:
            s = line.strip()
            if s and not s.startswith('@'):
                inputs.append(int(s, 16))

    tb = SimTopCorrectness(dut)
    tb.log.setLevel(logging.INFO)
    tb.log.info(f"Loaded {len(inputs)} instructions")
    await tb.run_test(inputs, batch_size=int(os.environ.get("BATCH_SIZE", "64")))

    tb.log.info(f"Captured {len(tb.captured_rows)} matrix-output rows")
    out_file = Path(os.environ["VECTOR_MEM_RESULT_FILE"]).parent / "rtl_output.json"
    with open(out_file, "w") as f:
        json.dump(tb.captured_rows, f)
    tb.log.info(f"Wrote RTL output to {out_file}")


# ---------------------------------------------------------------------------
# Pytest runner
# ---------------------------------------------------------------------------

@pytest.mark.dev
def SimTop_correctness_test():
    build_path = Path(__file__).parent / "build" / "SimTopCorrectness"
    init_mem(build_path)

    # ------------------------------------------------------------------
    # 1. Generate PLENAProgram ASM and compute golden
    # ------------------------------------------------------------------
    from aten.plena_compiler import PlenaCompiler
    from aten.ops.registry import OpRegistry, Backend
    import aten.ops as ops
    from plena_quant.mxfp import _mx_fp_quantize_hardware
    from assembler.assembly_to_binary import AssemblyToBinary

    registry = OpRegistry.load()
    registry.set_backend(Backend.PLENA)

    batch_size   = MLEN
    in_features  = MLEN
    out_features = MLEN
    real_data_ratio = (8 * 8 + 8) / (8 * 8)

    torch.manual_seed(42)
    X = torch.randn(batch_size, in_features)
    W = torch.randn(in_features, out_features)

    prog = PlenaCompiler(mlen=MLEN, blen=BLEN, real_data_ratio=real_data_ratio)
    x_input = prog.input("X", shape=(batch_size, in_features))
    w_input = prog.input("W", shape=(in_features, out_features))
    X_batch = prog.load_batch(x_input, name="X")
    Y = ops.linear(prog, X_batch, w_input)
    asm_code = prog.compile()
    asm_code = _lower_loop_pseudo_ops(asm_code)
    asm_code = _insert_pipeline_bubbles(asm_code)

    logger.info(f"Generated {len(asm_code.splitlines())} lines of ASM")

    # Assemble to binary
    asm_file   = build_path / "generated_asm_code.asm"
    instr_file = build_path / "generated_machine_code.mem"
    with open(asm_file, "w") as f:
        f.write(asm_code)
    isa_file    = SRC_PATH / "definitions" / "operation.svh"
    config_file = SRC_PATH / "definitions" / "configuration.svh"
    AssemblyToBinary(str(isa_file), str(config_file)).generate_binary(asm_file, instr_file)

    os.environ["INSTR_FILE"] = str(instr_file)
    os.environ["ASM_FILE"]   = str(asm_file)

    # ------------------------------------------------------------------
    # 2. Write HBM memory files
    # ------------------------------------------------------------------
    import toml as _toml
    import math as _math
    try:
        from memory_mapping.rand_gen import Random_MXFP_Tensor_Generator
    except ImportError:
        from memory_mapping.rand_gen import RandomMxfpTensorGenerator as Random_MXFP_Tensor_Generator

    precision = _load_precision_settings()
    with open(str(SRC_PATH / "definitions" / "plena_settings.toml")) as _f:
        _raw_cfg = _toml.load(_f)["CONFIG"]
        config_settings = {k: v["value"] if isinstance(v, dict) and "value" in v else v
                           for k, v in _raw_cfg.items()}

    quant_cfg_x = {
        "exp_width":      precision["ACT_MXFP_EXP_WIDTH"],
        "man_width":      precision["ACT_MXFP_MANT_WIDTH"],
        "exp_bias_width": precision["MX_SCALE_WIDTH"],
        "block_size":     [1, 8],
        "skip_first_dim": False,
    }
    quant_cfg_w = {
        "exp_width":      precision["KV_MX_EXP_WIDTH"],
        "man_width":      precision["KV_MX_MANT_WIDTH"],
        "exp_bias_width": precision["MX_SCALE_WIDTH"],
        "block_size":     [1, 8],
        "skip_first_dim": False,
    }

    rand_gen_x = Random_MXFP_Tensor_Generator(
        shape=X.shape, quant_config=quant_cfg_x, config_settings=config_settings,
        directory=str(build_path), filename="X.pt")
    x_blocks, x_bias = rand_gen_x.quantize_tensor(X)

    rand_gen_w = Random_MXFP_Tensor_Generator(
        shape=W.T.shape, quant_config=quant_cfg_w, config_settings=config_settings,
        directory=str(build_path), filename="W.pt")
    w_blocks, w_bias = rand_gen_w.quantize_tensor(W.T)

    # Recompute golden from actual HBM data
    _blk_size_x = quant_cfg_x["block_size"][1]
    _blk_size_w = quant_cfg_w["block_size"][1]
    X_hbm = _dequant_mx_blocks(
        x_blocks, x_bias,
        precision["ACT_MXFP_EXP_WIDTH"], precision["ACT_MXFP_MANT_WIDTH"],
        _blk_size_x, batch_size)
    W_hbm = _dequant_mx_blocks(
        w_blocks, w_bias,
        precision["KV_MX_EXP_WIDTH"], precision["KV_MX_MANT_WIDTH"],
        _blk_size_w, in_features)
    # SA computes result[r][c] = sum_k left[k][r]*top[k][c] = X.T @ W
    assert batch_size == in_features, (
        f"Golden formula X_hbm.T @ W_hbm requires batch_size == in_features, "
        f"got {batch_size} vs {in_features}")
    golden_Y = torch.mm(X_hbm.T, W_hbm)
    logger.info(f"Golden Y: shape={golden_Y.shape}, mean={golden_Y.mean():.4f}")

    # HBM geometry
    _HBM_ELE_RAW_BITS  = MLEN * 4
    _HBM_ELE_WIDTH_BITS = 1 << _math.ceil(_math.log2(_HBM_ELE_RAW_BITS * 2))
    _BRAM_ELE_WORD_BYTES = _HBM_ELE_WIDTH_BITS // 8
    _SCALE_BRAM_WORD_BYTES = 2
    _MX_SCALE_BITS = 8  # MX_SCALE_WIDTH from precision.svh
    _SCL_PER_WORD = (_SCALE_BRAM_WORD_BYTES * 8) // _MX_SCALE_BITS

    _v_scale_base, _w_hbm_base = _sim_asm_registers(asm_code)
    _w_ele_bram_word = _w_hbm_base // _BRAM_ELE_WORD_BYTES
    _v_scl_bram_word = _v_scale_base // _SCALE_BRAM_WORD_BYTES

    logger.info(f"HBM: W ele @{_w_ele_bram_word:X}, X scl @{_v_scl_bram_word:X}")

    # Reverse element order for LSB-first RTL encoding
    _blocks_per_row = MLEN // 8
    def _reverse_row_elements(blocks):
        result = []
        for r in range(0, len(blocks), _blocks_per_row):
            row_blocks = blocks[r:r + _blocks_per_row]
            for blk in reversed(row_blocks):
                result.append(list(reversed(blk)))
        return result

    x_blocks_rev = _reverse_row_elements(x_blocks)
    w_blocks_rev = _reverse_row_elements(w_blocks)

    # Write element BRAM: X at @0, W at @{w_addr}
    with open(build_path / "hbm_ele.mem", "w") as _f:
        _f.write("@0\n")
    map_data_to_fake_hbm_for_rtl_sim(
        blocks=x_blocks_rev, element_width=8, block_width=8,
        bias=x_bias, bias_width=8,
        combined_blk_dim=MLEN // 8, directory=str(build_path),
        append=True, hbm_row_width=MLEN)

    with open(build_path / "hbm_ele.mem", "a") as _f:
        _f.write(f"@{_w_ele_bram_word:X}\n")
    _w_elems_per_bram_word = _HBM_ELE_WIDTH_BITS // 4
    map_data_to_fake_hbm_for_rtl_sim(
        blocks=w_blocks_rev, element_width=4, block_width=8,
        bias=w_bias, bias_width=8,
        combined_blk_dim=MLEN // 8, directory=str(build_path),
        append=True, hbm_row_width=_w_elems_per_bram_word)

    # Write scale BRAM: W scales at @0, X scales at @{v_scl_addr}
    def _bias_to_scl_rows(bias):
        rows, row_hex = [], ""
        for b in bias:
            row_hex += f"{int(b) & 0xFF:02X}"
            if len(row_hex) == _SCL_PER_WORD * 2:
                rows.append(row_hex)
                row_hex = ""
        if row_hex:
            rows.append(row_hex.ljust(_SCL_PER_WORD * 2, "0"))
        return rows

    def _swap_scale_pairs(bias_list):
        result = list(bias_list)
        for i in range(0, len(result) - 1, 2):
            result[i], result[i + 1] = result[i + 1], result[i]
        return result

    scl_rows_x = _bias_to_scl_rows(_swap_scale_pairs(x_bias))
    scl_rows_w = _bias_to_scl_rows(_swap_scale_pairs(w_bias))

    with open(build_path / "hbm_scale.mem", "w") as _f:
        _f.write("@0\n")
        _f.write("\n".join(scl_rows_w) + "\n")
        _f.write(f"@{_v_scl_bram_word:X}\n")
        _f.write("\n".join(scl_rows_x) + "\n")

    logger.info(f"Wrote hbm_ele.mem and hbm_scale.mem")

    fp_mem  = build_path / "fp_mem.mem";  fp_mem.touch()
    int_mem = build_path / "int_mem.mem"; int_mem.touch()
    os.environ["FP_MEM_INIT_FILE"]  = str(fp_mem)
    os.environ["INT_MEM_INIT_FILE"] = str(int_mem)
    os.environ["FAKE_HBM_INIT_FILE"] = str(build_path / "hbm")
    os.environ["BATCH_SIZE"] = str(VALID_ROWS)

    # ------------------------------------------------------------------
    # 3. Run RTL simulation
    # ------------------------------------------------------------------
    _sim_binary = Path(__file__).parent / "build" / "SimTop" / "test_0" / "SimTop"
    _skip_build = os.getenv("SKIP_BUILD", "0") == "1" and _sim_binary.exists()
    if _skip_build:
        logger.info("Verilator binary found, skipping rebuild")

    veri_runner(
        group="system",
        module="SimTop",
        test_module="SimTop_correctness_tb",
        test_dir=Path(__file__).parent,
        additional_include_paths=[
            str(SRC_PATH / "basic_components/common"),
            str(SRC_PATH / "basic_components/mx_fp_operation"),
            str(SRC_PATH / "basic_components/fp_operation"),
            str(SRC_PATH / "basic_components/conversion"),
            str(SRC_PATH / "basic_components/buffer"),
            str(SRC_PATH / "basic_components/fixed_operation"),
            str(SRC_PATH / "basic_components/int_operation"),
            str(SRC_PATH / "basic_components/cast"),
            str(SRC_PATH / "basic_components/systolic_gemm_mx"),
            str(SRC_PATH / "basic_components/gemv"),
            str(SRC_PATH / "basic_components/synopsis/rtl"),
            str(SRC_PATH / "basic_components/synopsis"),
            str(SRC_PATH / "basic_components/synopsis_ip_inst"),
            str(SRC_PATH / "basic_components/hadamard_transform"),
            str(SRC_PATH / "frontend"),
            str(SRC_PATH / "control"),
            str(SRC_PATH / "matrix_machine"),
            str(SRC_PATH / "vector_machine"),
            str(SRC_PATH / "scalar_machine"),
            str(SRC_PATH / "memory/matrix_sram"),
            str(SRC_PATH / "memory/vector_sram"),
            str(SRC_PATH / "memory/scratch_sram"),
            str(SRC_PATH / "memory/scalar_sram"),
            str(SRC_PATH / "memory/HBM"),
            str(SRC_PATH / "core"),
        ],
        definitions_path=[
            str(SRC_PATH / "definitions"),
            str(SRC_PATH / "memory/HBM/TileLink_Lib"),
        ],
        module_param_list=[{
            "INSTRUCTION_LENGTH":               INSTRUCTION_LENGTH,
            "FAKE_HBM_INIT_FILE":               f'"{os.environ["FAKE_HBM_INIT_FILE"]}"',
            "FP_MEM_INIT_FILE":                 f'"{os.environ["FP_MEM_INIT_FILE"]}"',
            "INT_MEM_INIT_FILE":                f'"{os.environ["INT_MEM_INIT_FILE"]}"',
            "VECTOR_MEM_RESULT_FILE":           f'"{os.environ["VECTOR_MEM_RESULT_FILE"]}"',
        }],
        extra_build_args=["+define+SIMULATION"],
        trace=SIMTOP_TRACE,
        skip_build=_skip_build,
    )

    # ------------------------------------------------------------------
    # 4. Compare RTL output against golden
    # ------------------------------------------------------------------
    out_file = build_path / "rtl_output.json"
    if not out_file.exists() or out_file.stat().st_size == 0:
        raise AssertionError(
            f"RTL output file missing or empty: {out_file}\n"
            "The cocotb test did not capture any m_out_v_fp rows.")

    with open(out_file) as f:
        captured = json.load(f)

    logger.info(f"Loaded {len(captured)} captured RTL rows")
    expected_rows = VALID_ROWS
    if len(captured) < expected_rows:
        raise AssertionError(
            f"RTL captured only {len(captured)} rows, expected {expected_rows}. "
            "Simulation may have timed out or m_out_v_fp handshake failed.")

    rows = [_decode_row(r) for r in captured[:expected_rows]]
    Y_rtl = torch.tensor(rows, dtype=torch.float32)

    golden_slice = golden_Y[:expected_rows, :]
    abs_err = (Y_rtl - golden_slice).abs()

    for tol in [0.5, 1.0, 2.0, 5.0]:
        ac = (abs_err < tol).float().mean().item()
        logger.info(f"Allclose (±{tol}): {ac:.1%}")

    TIGHT_TOLERANCE = 1.0
    LOOSE_TOLERANCE = 5.0
    tight_frac = (abs_err < TIGHT_TOLERANCE).float().mean().item()
    loose_frac = (abs_err < LOOSE_TOLERANCE).float().mean().item()

    if tight_frac >= 0.80:
        allclose_frac, tolerance = tight_frac, TIGHT_TOLERANCE
        logger.info(f"[PASSED] {allclose_frac:.1%} within ±{tolerance}")
    elif loose_frac >= 0.80:
        allclose_frac, tolerance = loose_frac, LOOSE_TOLERANCE
        import warnings
        warnings.warn(
            f"[DEGRADED] Only {tight_frac:.1%} within ±{TIGHT_TOLERANCE}; "
            f"passed on loose tolerance ±{LOOSE_TOLERANCE} ({allclose_frac:.1%})",
            stacklevel=2)
    else:
        allclose_frac, tolerance = loose_frac, LOOSE_TOLERANCE

    logger.info(f"Y_rtl: mean={Y_rtl.mean():.4f}, golden: mean={golden_slice.mean():.4f}, "
                f"max_err={abs_err.max().item():.4f}")

    if allclose_frac < 0.80:
        raise AssertionError(
            f"RTL output does not match golden: {allclose_frac:.1%} within ±{tolerance}. "
            f"Max error: {abs_err.max().item():.4f}")

    logger.info(f"[CORRECTNESS TEST PASSED] {allclose_frac:.1%} within ±{tolerance}")


if __name__ == "__main__":
    SimTop_correctness_test()
