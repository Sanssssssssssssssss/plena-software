#!/usr/bin/env python3
"""PLENA System Top-Level RTL Testbench.

This script provides the cocotb testbench for PLENA system simulation.
It uses pre-generated workload files from tools/testworkloads.

Usage:
    # Generate workload first
    python -m tools.testworkloads.linear --batch 8 --in-features 128 --out-features 256

    # Run simulation
    just test-linear 8 128 256
"""

import argparse
import json
import logging
import os
import sys
from pathlib import Path

import pytest
import cocotb
import torch
from cocotb.log import SimLog
from cocotb.triggers import Timer, RisingEdge, First

# Setup paths
_PROJECT_PATH = Path(__file__).resolve().parent.parent.parent.parent
_TOOLS_PATH = _PROJECT_PATH / "tools"
_SIMULATOR_PATH = _PROJECT_PATH / "PLENA_Simulator"
_SIMULATOR_TOOLS_PATH = _SIMULATOR_PATH / "tools"
_TEST_PATH = Path(__file__).resolve().parent

for p in [str(_SIMULATOR_TOOLS_PATH), str(_SIMULATOR_PATH), str(_TOOLS_PATH), str(_TEST_PATH)]:
    if p not in sys.path:
        sys.path.insert(0, p)

from cfl_cocotb.runner import veri_runner, SRC_PATH
from cfl_cocotb.testbench import Testbench

from cfl_tools.logger import get_logger
from cfl_tools.debugger import set_excepthook

from test_platform import PLENATestPlatform
from verification.view_vector_result import view_vector_result_as_fp

logger = get_logger("testbench")
logger.setLevel(logging.DEBUG)

INSTRUCTION_LENGTH = 32
set_excepthook()


class SimTOP(Testbench):
    """PLENA System Top-Level Testbench.

    Drives the PLENA system with instructions and monitors output.
    Uses pre-generated workload files from PLENATestPlatform.
    """

    def __init__(
        self,
        dut,
        hbm_file: str,
    ) -> None:
        """Initialize the testbench.

        Args:
            dut: cocotb DUT handle
            hbm_file: Path to combined HBM file (contains data and instructions)
        """
        super().__init__(dut, dut.clk, dut.rst)
        self.hbm_file = hbm_file

        if os.environ.get("SIMTOP_DEBUG_TRACE", "0") == "1":
            cocotb.start_soon(self.check_vector_sram())
            cocotb.start_soon(self.check_mcu_drain())
            cocotb.start_soon(self.check_mm_operands())
            cocotb.start_soon(self.watch_gp6())
            cocotb.start_soon(self.watch_acc_pulses())
            cocotb.start_soon(self.trace_dfc_vload())
            cocotb.start_soon(self.trace_dispatch())
            cocotb.start_soon(self.trace_fetch())
            cocotb.start_soon(self.trace_v_writes())
        if os.environ.get("SIMTOP_HBM_TRACE", "0") == "1":
            cocotb.start_soon(self.trace_hbm_prefetch())

        self.rtl_full_machine_manifest = {}
        workload_dir = os.environ.get("WORKLOAD_DIR")
        if workload_dir:
            manifest_path = Path(workload_dir) / "rtl_full_machine_manifest.json"
            if manifest_path.exists():
                self.rtl_full_machine_manifest = json.loads(manifest_path.read_text())
        self.row_commands_accepted = 0
        self.packed_pv_commands_started = 0
        self.packed_pv_rows_committed = 0
        if self.rtl_full_machine_manifest:
            cocotb.start_soon(self.monitor_rtl_v6_activity())

        # Execution clock counter state
        self.execution_clocks = 0
        self.c_break_detected = False

        if not hasattr(self, "log"):
            self.log = SimLog("%s" % (type(self).__qualname__))

    async def run_test(self):
        """Run the main test sequence.

        Instructions are loaded from hbm_file (HBM_INSTRUCTIONS section) at simulation start.
        """
        await self.reset()
        logger.info("Reset finished")
        logger.info(f"HBM data and instructions loaded from: {self.hbm_file}")

        # Count execution clocks until C_BREAK is detected
        exec_clocks = await self.count_execution_clocks(
            timeout_us=int(os.environ.get("SIMTOP_TIMEOUT_US", "10000"))
        )

        if exec_clocks < 0:
            raise RuntimeError("BUG: C_BREAK instruction was not loaded/decoded")

        # C_BREAK is detected at DECODE (the first pipeline stage), but vector /
        # matrix ops issued in the cycles just before C_BREAK are still draining
        # through the multi-stage compute pipelines and their write-backs to the
        # vector SRAM have not committed yet. Ending the test (and triggering the
        # $finish memory dump) immediately would capture a half-written VRAM
        # (e.g. the last normalization chunk of an RMS loop left un-normalized).
        # The PC keeps fetching past C_BREAK but post-C_BREAK words decode to
        # STALL/NOP, so these extra cycles cannot corrupt state — they only let
        # in-flight write-backs land before the VRAM is dumped.
        drain_cycles = 32
        logger.info(f"Draining pipeline for {drain_cycles} cycles after C_BREAK")
        for _ in range(drain_cycles):
            await RisingEdge(self.dut.clk)

        self.assert_rtl_v6_activity()

    async def monitor_rtl_v6_activity(self):
        """Count accepted production row-engine and packed-PV transactions."""
        core = self.dut.dut
        while True:
            await RisingEdge(self.dut.clk)
            if int(core.rst.value):
                continue
            if int(core.softmax_command_valid.value):
                self.row_commands_accepted += 1
            if int(core.packed_pv_start.value):
                self.packed_pv_commands_started += 1
            if (
                int(core.packed_pv_write_req.value)
                and int(core.packed_pv_write_ready.value)
            ):
                self.packed_pv_rows_committed += 1

    async def trace_hbm_prefetch(self):
        """Trace only TileLink handshakes for the first Vector prefetch."""
        vector_hbm = self.dut.dut.hbm_interface_init.vector_hbm_controller_init
        element = vector_hbm.high_precision_element_master
        scale = vector_hbm.scale_master
        for cycle in range(300):
            await RisingEdge(self.dut.clk)

            def value(instance, name):
                try:
                    return int(getattr(instance, name).value)
                except (AttributeError, ValueError, TypeError):
                    return None

            active = any(
                value(instance, signal)
                for instance, signal in (
                    (element, "host_a_valid"),
                    (element, "host_d_valid"),
                    (scale, "host_a_valid"),
                    (scale, "host_d_valid"),
                )
            )
            if active:
                logger.info(
                    "[HBM] c%s elem(a=%s/%s addr=%s d=%s/%s resp=%s) "
                    "scale(a=%s/%s addr=%s d=%s/%s resp=%s)",
                    cycle,
                    value(element, "host_a_valid"),
                    value(element, "host_a_ready"),
                    value(element, "host_a_address"),
                    value(element, "host_d_valid"),
                    value(element, "host_d_ready"),
                    value(element, "total_response_counter"),
                    value(scale, "host_a_valid"),
                    value(scale, "host_a_ready"),
                    value(scale, "host_a_address"),
                    value(scale, "host_d_valid"),
                    value(scale, "host_d_ready"),
                    value(scale, "total_response_counter"),
                )

    def assert_rtl_v6_activity(self):
        """Require the compiled v6 workload to traverse the production paths."""
        manifest = self.rtl_full_machine_manifest
        if not manifest:
            return

        observed = {
            "row_commands_accepted": self.row_commands_accepted,
            "packed_pv_commands_started": self.packed_pv_commands_started,
            "packed_pv_rows_committed": self.packed_pv_rows_committed,
        }
        expected = {
            "row_commands_accepted": int(manifest["expected_row_opcodes"]),
            "packed_pv_commands_started": int(
                manifest["expected_packed_pv_opcodes"]
            ),
            "packed_pv_rows_committed": int(manifest["expected_packed_pv_rows"]),
        }
        activity_path = Path(os.environ["WORKLOAD_DIR"]) / "rtl_full_machine_activity.json"
        activity_path.write_text(
            json.dumps(
                {"expected": expected, "observed": observed},
                indent=2,
                sort_keys=True,
            )
            + "\n"
        )
        if observed != expected:
            raise AssertionError(
                f"RTL-v6 production-path activity mismatch: "
                f"expected={expected}, observed={observed}"
            )

    async def check_vector_sram(self):
        """Monitor vector SRAM output."""
        while True:
            await RisingEdge(self.dut.clk)
            try:
                v_out_valid = self.dut.dut.vector_machine_init.element_v_out_valid.value
                v_out_ready = self.dut.dut.vector_machine_init.element_v_out_ready.value

                if v_out_valid == 1 and v_out_ready == 1:
                    data = self.dut.dut.vector_machine_init.element_v_out.value
                    list_ = []
                    for i in range(0, len(data), 16):
                        list_.append(data[i:i+15].integer)
                    self.log.debug(f"Vector Core fp_out: {list_}")
            except AttributeError:
                pass

    async def trace_dfc_vload(self):
        """Per-cycle trace of the v-for-matrix load FSM in data_flow_control
        around the M_MM iterations where one activation group goes missing."""
        try:
            dfc = self.dut.dut.data_flow_init
        except AttributeError:
            logger.warning("[DFCV] data_flow_init not found")
            return
        cyc = 0
        logged = 0
        while logged < 400:
            await RisingEdge(self.dut.clk)
            cyc += 1
            def g(name, default=-1):
                try:
                    return int(getattr(dfc, name).value)
                except Exception:
                    return default
            if not (g('continuous_load_v_for_matrix_en') == 1 or g('m_v_load') == 1 or g('m_v_valid') == 1
                    or g('continuous_load_m_en') == 1 or g('m_m_load') == 1 or g('m_m_valid') == 1):
                continue
            logged += 1
            logger.info(
                f"[DFCV] c{cyc}"
                f" en={g('continuous_load_v_for_matrix_en')}"
                f" cnt={g('v_sram_load_for_matrix_counter')}"
                f" eol={g('end_of_load_v_for_matrix')}"
                f" mvl={g('m_v_load')} mvlc={g('m_v_load_cond')}"
                f" p1={g('p1_vport_a_load_valid')} p2={g('p2_vport_a_load_valid')}"
                f" mvv={g('m_v_valid')}"
                f" perm={g('permit_load_for_m')} mrdy={g('matrix_related_data_ready')}"
                f" rec={g('recorded_v_load_for_matrix_addr')}"
                f" addrA={g('v_sram_addr_a')} reqA={g('v_sram_req_a')}"
                f" menl={g('continuous_load_m_en')} eolm={g('end_of_load_m')}"
                f" mcnt={g('m_sram_load_counter')}"
                f" mmv={g('m_m_valid')}"
            )

    async def trace_dispatch(self):
        """Per-cycle trace of decoder dispatch + scalar regfile writes around
        the stall-release window where MM#7's PASS_ADDR loses to the trailing
        S_ADDI write (cycles ~1570-1660, v-load #7 starts ~c1640)."""
        try:
            dec = self.dut.dut.decoder_init
            sm = self.dut.dut.scalar_machine_init
            pc = self.dut.dut.pipeline_control_init
        except AttributeError:
            logger.warning("[DISP] instances not found")
            return
        cyc = 0
        while cyc < 2450:
            await RisingEdge(self.dut.clk)
            cyc += 1
            if cyc < 2100:
                continue

            def g(inst, name, default=-1):
                try:
                    return int(getattr(inst, name).value)
                except Exception:
                    return default

            wen = g(sm, 'gp_reg_wen')
            wline = f" W:gp{g(sm,'gp_reg_waddr')}={g(sm,'gp_reg_wdata')}" if wen == 1 else ""
            logger.info(
                f"[DISP] c{cyc}"
                f" stall={g(dec,'pipeline_stall')}"
                f" pc={g(dec,'pc_reg')//4} pcd={g(dec,'pc_reg_d1')//4}"
                f" ri={g(dec,'read_instr')}"
                f" opc={g(dec,'loaded_opcode'):2d}"
                f" dvalid={g(dec,'decode_instr_valid')}"
                f" aint={g(dec,'assigned_int_op')}"
                f" eint={g(dec,'exe_int_op')}"
                f" pend={g(dec,'int_op_pending')}"
                f" dadv={g(dec,'decode_advanced_d')}"
                f" rs1={g(dec,'rs1')} rs2={g(dec,'rs2')}"
                f" egp={g(sm,'exe_gp_op')}"
                f" go1={g(sm,'gp_out_1')} go2={g(sm,'gp_out_2')}"
                f" rec1={g(pc,'recorded_gp_addr_1')}"
                f" p2rec={g(pc,'p2_recover_from_stall')}"
                f"{wline}"
            )

    async def trace_fetch(self):
        """Per-cycle trace of the imem->decoder fetch handshake around the
        startup buffer refills (cycles 2150-2300): tag/data/ready vs
        expected_decode_pc and the accept (fresh_fetch) decision."""
        try:
            dec = self.dut.dut.decoder_init
            imem = self.dut.dut.instr_mem_inst
        except AttributeError:
            logger.warning("[FET] instances not found")
            return
        cyc = 0
        while cyc < 2300:
            await RisingEdge(self.dut.clk)
            cyc += 1
            if cyc < 2150:
                continue

            def g(inst, name, default=-1):
                try:
                    return int(getattr(inst, name).value)
                except Exception:
                    return default

            logger.info(
                f"[FET] c{cyc}"
                f" pc={g(dec,'pc_reg')//4}"
                f" exp={g(dec,'expected_decode_pc')//4}"
                f" tag={g(dec,'instruction_addr_from_imem')//4}"
                f" rdy={g(dec,'load_instr_valid')}"
                f" ff={g(dec,'fresh_fetch')}"
                f" ri={g(dec,'read_instr')}"
                f" opc={g(dec,'loaded_opcode'):2d}"
                f" skip={g(dec,'fetch_skipped_ahead')}"
                f" | base={g(imem,'buffer_base_addr')//4}"
                f" bv={g(imem,'buffer_valid')}"
                f" idx={g(imem,'buffer_index')}"
                f" inrange={g(imem,'pc_in_range')}"
                f" st={g(imem,'state')}"
            )

    async def trace_v_writes(self):
        """Event log of every vector-path port-A write into VRAM plus the
        v_write_request/v_write_addr handshake and f2 (fp reg) updates -
        to catch the rms_norm row-0 corruption (a V op writing batch-7 data
        with a stale f2 to address 0)."""
        try:
            dfc = self.dut.dut.data_flow_init
            sm = self.dut.dut.scalar_machine_init
        except AttributeError:
            logger.warning("[VWR] instances not found")
            return

        def g(inst, name, default=-1):
            try:
                return int(getattr(inst, name).value)
            except Exception:
                return default

        def f12(bits):
            s = (bits >> 11) & 1
            e = (bits >> 5) & 63
            m = bits & 31
            v = (m / 32) * 2.0 ** (1 - 31) if e == 0 else (1 + m / 32) * 2.0 ** (e - 31)
            return -v if s else v

        cyc = 0
        logged = 0
        prev_f2 = None
        while logged < 300:
            await RisingEdge(self.dut.clk)
            cyc += 1
            try:
                f2raw = int(sm.fp_reg_file.mem[2].value)
            except Exception:
                f2raw = -1
            if f2raw != prev_f2 and f2raw >= 0:
                logger.info(f"[VWR] c{cyc} f2 -> {f12(f2raw):.4f} (raw={f2raw:#x})")
                prev_f2 = f2raw
                logged += 1
            vreq = g(dfc, 'v_write_request')
            wen = g(dfc, 'v_sram_wen_a')
            sel = g(dfc, 'select_write_data_a')
            if vreq == 1:
                logger.info(f"[VWR] c{cyc} v_write_request addr={g(dfc,'v_write_addr')}")
                logged += 1
            if wen == 1 and sel == 0:
                logger.info(
                    f"[VWR] c{cyc} VWRITE addrA={g(dfc,'v_sram_addr_a')}"
                    f" rec={g(dfc,'recorded_v_write_addr')}"
                    f" mask={g(dfc,'v_sram_mask_a'):#x}")
                logged += 1

    async def check_mm_operands(self):
        """Decode the MCU operands v1 (TOP=b/weight) and v2 (LEFT=a/act) on the
        first few MM_IC cycles, so we can check whether M_MM reads a row-major
        (K-vector per row) and b column-major (K-vector per column)."""
        try:
            mcu = self.dut.dut.matrix_machine_init.gen_mxint_systolic_mcu.matrix_compute_unit
        except AttributeError:
            logger.warning("[MM] matrix_compute_unit not found")
            return
        MLEN = 16

        def unpack_signed(handle, n):
            bv = handle.value
            try:
                raw = int(bv)
            except (ValueError, TypeError):
                return None
            w = len(bv) // n
            out = []
            for k in range(n):
                v = (raw >> (k * w)) & ((1 << w) - 1)
                if v >> (w - 1):
                    v -= 1 << w
                out.append(v)
            return out

        n1 = 0
        n2 = 0
        while n1 < 40 or n2 < 40:
            await RisingEdge(self.dut.clk)
            try:
                v1v = int(mcu.v1_in_valid.value)
                v2v = int(mcu.v2_in_valid.value)
            except (AttributeError, ValueError):
                continue
            if v1v and n1 < 40:
                v1 = unpack_signed(mcu.v1_element, MLEN)
                if v1 and not any(v1):
                    logger.info(f"[MM] v1#{n1} ZERO beat")
                    n1 += 1
                elif v1:
                    logger.info(f"[MM] v1#{n1} (TOP/b weight)  int={v1}")
                    try:
                        sraw = int(mcu.v1_scale.value)
                        scales = [(sraw >> (k * 8)) & 0xFF for k in range(MLEN)]
                        logger.info(f"[MM] v1#{n1} scales(biased)={scales}")
                    except (AttributeError, ValueError):
                        pass
                    n1 += 1
            if v2v and n2 < 40:
                v2 = unpack_signed(mcu.v2_element, MLEN)
                if v2 and not any(v2):
                    logger.info(f"[MM] v2#{n2} ZERO beat")
                    n2 += 1
                elif v2:
                    logger.info(f"[MM] v2#{n2} (LEFT/a act)    int={v2}")
                    try:
                        sraw = int(mcu.v2_scale.value)
                        scales = [(sraw >> (k * 8)) & 0xFF for k in range(4)]
                        logger.info(f"[MM] v2#{n2} scales(biased)={scales}")
                    except (AttributeError, ValueError):
                        pass
                    n2 += 1

    async def watch_acc_pulses(self):
        """Log gebm_result[0][0] (tile contribution to C[0][0]) at each
        accumulate pulse, to verify per-tile compute against theory."""
        try:
            mcu = self.dut.dut.matrix_machine_init.gen_mxint_systolic_mcu.matrix_compute_unit
        except AttributeError:
            return
        FP_EXP, FP_MAN = 6, 5

        def dfp(bits):
            sgn = (bits >> (FP_EXP + FP_MAN)) & 1
            e = (bits >> FP_MAN) & ((1 << FP_EXP) - 1)
            m = bits & ((1 << FP_MAN) - 1)
            bias = (1 << (FP_EXP - 1)) - 1
            v = (m / 2**FP_MAN) * 2.0 ** (1 - bias) if e == 0 else (1 + m / 2**FP_MAN) * 2.0 ** (e - bias)
            return -v if sgn else v

        n = 0
        prev = 0
        while n < 20:
            await RisingEdge(self.dut.clk)
            try:
                ap = int(mcu.accumulate_pulse.value)
            except (AttributeError, ValueError):
                continue
            if ap == 1 and prev == 0:
                try:
                    raw = int(mcu.gebm_result.value)
                    lane00 = raw & 0xFFF
                    logger.info(f"[ACC] pulse#{n} gebm[0][0]={dfp(lane00):.3f}")
                except (AttributeError, ValueError):
                    logger.info(f"[ACC] pulse#{n} gebm unreadable")
                n += 1
            prev = ap

    async def watch_gp6(self):
        """Log every change of gp6/gp4 (result base / MM_WO address regs)."""
        try:
            rf = self.dut.dut.scalar_machine_init.gp_reg_file
        except AttributeError:
            logger.warning("[GP] regfile not found")
            return
        prev6 = None
        prev4 = None
        n = 0
        cyc = 0
        while n < 120:
            await RisingEdge(self.dut.clk)
            cyc += 1
            try:
                v6 = int(rf.mem[6].value)
                v4 = int(rf.mem[4].value)
                v3 = int(rf.mem[3].value)
                v2 = int(rf.mem[2].value)
            except (AttributeError, ValueError, IndexError):
                continue
            if v6 != prev6:
                logger.info(f"[GP] @cyc{cyc} gp6 -> {v6}")
                prev6 = v6
                n += 1
            if v4 != prev4:
                logger.info(f"[GP] @cyc{cyc} gp4 -> {v4}")
                prev4 = v4
                n += 1
            if v3 != getattr(self, "_prev3", None):
                logger.info(f"[GP] @cyc{cyc} gp3 -> {v3}")
                self._prev3 = v3
                n += 1
            if v2 != getattr(self, "_prev2", None):
                logger.info(f"[GP] @cyc{cyc} gp2 -> {v2}")
                self._prev2 = v2
                n += 1

    async def check_mcu_drain(self):
        """Log each MCU result-drain row with its write address, to map the
        HW result layout against golden."""
        try:
            mcu = self.dut.dut.matrix_machine_init.gen_mxint_systolic_mcu.matrix_compute_unit
            mm = self.dut.dut.matrix_machine_init
        except AttributeError:
            logger.warning("[DRAIN] matrix_compute_unit not found")
            return

        FP_EXP, FP_MAN, BLEN = 6, 5, 4

        def dfp(bits):
            s = (bits >> (FP_EXP + FP_MAN)) & 1
            e = (bits >> FP_MAN) & ((1 << FP_EXP) - 1)
            m = bits & ((1 << FP_MAN) - 1)
            bias = (1 << (FP_EXP - 1)) - 1
            v = (m / 2**FP_MAN) * 2.0 ** (1 - bias) if e == 0 else (1 + m / 2**FP_MAN) * 2.0 ** (e - bias)
            return -v if s else v

        def unpack(handle, n):
            bv = handle.value
            try:
                raw = int(bv)
            except (ValueError, TypeError):
                return None
            w = len(bv) // n
            return [(raw >> (k * w)) & ((1 << w) - 1) for k in range(n)]

        logger.info("[DRAIN] probe attached")
        logged = 0
        while logged < 160:
            await RisingEdge(self.dut.clk)
            try:
                wr = int(mcu.v_result_write_req.value)
            except (AttributeError, ValueError):
                continue
            if wr != 1:
                continue
            vr = unpack(mcu.v_result, BLEN)
            if vr is None:
                continue
            row = [round(dfp(b), 2) for b in vr]
            try:
                waddr = int(mm.m_waddr.value)
            except (AttributeError, ValueError):
                waddr = -1
            logger.info(f"[DRAIN] waddr={waddr} row={row}")
            logged += 1

    async def count_execution_clocks(self, timeout_us=50):
        """Count execution clocks from reset release until C_BREAK is decoded.

        Args:
            timeout_us: Maximum time to wait for C_BREAK in microseconds

        Returns:
            Number of clock cycles if C_BREAK detected, -1 if timeout (bug)
        """
        self.execution_clocks = 0
        self.c_break_detected = False

        # Calculate timeout in clock cycles (assuming 20ns clock period from testbench.py)
        clock_period_ns = 20
        timeout_cycles = int(timeout_us * 1000 / clock_period_ns)

        logger.info(f"Starting execution clock counter (timeout: {timeout_us}us = {timeout_cycles} cycles)")

        while self.execution_clocks < timeout_cycles:
            await RisingEdge(self.dut.clk)
            self.execution_clocks += 1

            try:
                # Access c_break_detected signal from plena (exposed in SIMULATION mode)
                c_break = self.dut.dut.c_break_detected.value

                if int(c_break) == 1:
                    self.c_break_detected = True
                    logger.info(f"C_BREAK detected at clock cycle {self.execution_clocks}")
                    logger.info(f"=== EXECUTION CLOCKS: {self.execution_clocks} ===")
                    return self.execution_clocks
            except (AttributeError, ValueError) as e:
                # Signal might not be accessible yet, continue counting
                pass

        # Timeout reached without C_BREAK
        logger.error(f"BUG: C_BREAK not loaded within {timeout_us}us ({timeout_cycles} cycles)")
        logger.error(f"=== BUG: C_BREAK NOT DETECTED ===")
        self.log_stall_snapshot()
        return -1

    def log_stall_snapshot(self):
        """Log the control and HBM state needed to diagnose a full-core hang."""
        def value(instance, name):
            try:
                return int(getattr(instance, name).value)
            except (AttributeError, ValueError, TypeError):
                return None

        core = self.dut.dut
        decoder = core.decoder_init
        data_flow = core.data_flow_init
        hbm = core.hbm_interface_init
        vector_hbm = hbm.vector_hbm_controller_init
        element_master = vector_hbm.high_precision_element_master
        scale_master = vector_hbm.scale_master
        scalar = core.scalar_machine_init
        snapshot = {
            "pc_word": value(decoder, "pc_reg") // 4
            if value(decoder, "pc_reg") is not None
            else None,
            "loaded_opcode": value(decoder, "loaded_opcode"),
            "pipeline_stall": value(decoder, "pipeline_stall"),
            "int_op_pending": value(decoder, "int_op_pending"),
            "fp_pending_regs": value(scalar, "fp_pending_regs"),
            "hbm_v_prefetch_in_progress": value(
                core, "hbm_v_prefetch_in_progress"
            ),
            "hbm_v_req_prefetch_data": value(core, "hbm_v_req_prefetch_data"),
            "hbm_v_prefetch_valid": value(core, "hbm_v_prefetch_valid"),
            "continuous_v_prefetch_en": value(
                data_flow, "continuous_v_prefetch_en"
            ),
            "v_sram_prefetch_counter": value(
                data_flow, "v_sram_prefetch_counter"
            ),
            "v_hbm_prefetch_en": value(hbm, "v_hbm_prefetch_en"),
            "hbm_addr_out": value(hbm, "hbm_addr_out"),
            "vector_element_valid": value(
                vector_hbm, "prefetch_high_precision_data_valid"
            ),
            "vector_scale_valid": value(vector_hbm, "prefetch_scale_data_valid"),
            "element_master_state": value(element_master, "state"),
            "element_requests": value(
                element_master, "continuous_prefetch_counter"
            ),
            "element_responses": value(element_master, "total_response_counter"),
            "element_output_valid": value(element_master, "r_fetch_data_valid"),
            "scale_master_state": value(scale_master, "state"),
            "scale_requests": value(scale_master, "continuous_prefetch_counter"),
            "scale_responses": value(scale_master, "total_response_counter"),
            "scale_output_valid": value(scale_master, "r_fetch_data_valid"),
        }
        logger.error(f"SimTop stall snapshot: {snapshot}")


@cocotb.test()
async def test(dut):
    """Main cocotb test entry point."""
    tb = SimTOP(
        dut,
        os.environ["FAKE_HBM_INIT_FILE"],
    )
    tb.log.setLevel(logging.DEBUG)
    await tb.run_test()


def get_module_params() -> dict:
    """Get module parameters from environment variables."""
    return {
        "INSTRUCTION_LENGTH": INSTRUCTION_LENGTH,
        "FAKE_HBM_INIT_FILE": f"\"{os.environ['FAKE_HBM_INIT_FILE']}\"",  # Combined HBM init file (data + instructions)
        "FP_MEM_INIT_FILE": f"\"{os.environ['FP_MEM_INIT_FILE']}\"",
        "INT_MEM_INIT_FILE": f"\"{os.environ['INT_MEM_INIT_FILE']}\"",
        "VECTOR_MEM_RESULT_FILE": f"\"{os.environ['VECTOR_MEM_RESULT_FILE']}\"",
        "FP_REG_RESULT_FILE": f"\"{os.environ.get('FP_REG_RESULT_FILE', '')}\"",  # FP register-file dump for debug
        "HBM_RESULT_FILE": f"\"{os.environ.get('HBM_RESULT_FILE', '')}\"",  # HBM dump for verification
        "SOFTMAX_ROW_LANES": int(os.environ.get("SOFTMAX_ROW_LANES", "1")),
        "SOFTMAX_STATE_HEADS": int(os.environ.get("SOFTMAX_STATE_HEADS", "64")),
        "INSTRUCTION_STORAGE_OFFSET": int(
            os.environ.get("INSTRUCTION_STORAGE_OFFSET", "160")
        ),
    }


@pytest.mark.dev
def test_SimTop():
    """Run SimTop RTL test."""
    # Check if SKIP_BUILD environment variable is set
    skip_build = os.environ.get("SKIP_BUILD", "0") == "1"

    # Get workload directory for simulation artifacts (VCD, etc)
    workload_dir = os.environ.get("WORKLOAD_DIR")
    sim_build_dir = Path(workload_dir) if workload_dir else None

    veri_runner(
        group="system",
        module="SimTop",
        test_dir=Path(__file__).parent,  # Tell cocotb where to find SimTop_tb.py
        extra_build_args=["-DSIMULATION"],
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
            str(SRC_PATH / "basic_components/systolic_gemm_mxint"),
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
        module_param_list=[get_module_params()],
        trace=os.environ.get("SIMTOP_TRACE", "0") == "1",
        skip_build=skip_build,
        sim_build_dir=sim_build_dir,
    )


def run_with_workload(workload_dir: str):
    """Run simulation with a generated workload directory.

    Args:
        workload_dir: Path to workload build directory
    """
    os.environ["WORKLOAD_DIR"] = workload_dir

    # Load platform to set all env vars
    platform = PLENATestPlatform.from_workload(workload_dir)
    platform.prepare()

    test_SimTop()
    if os.environ.get("SIMTOP_SKIP_OUTPUT_VERIFY", "0") != "1":
        verify_rtl_full_machine_output(Path(workload_dir))


def verify_rtl_full_machine_output(workload_dir: Path) -> None:
    """Compare the production Vector SRAM dump with the compiler golden output."""
    manifest_path = workload_dir / "rtl_full_machine_manifest.json"
    if not manifest_path.exists():
        return

    manifest = json.loads(manifest_path.read_text())
    parsed = view_vector_result_as_fp(
        workload_dir / "vector_result.mem",
        vlen=int(manifest["output_row_dim"]),
        exp_width=int(manifest["v_fp_exp_width"]),
        man_width=int(manifest["v_fp_mant_width"]),
        start_row=int(manifest["output_start_row"]),
        num_rows=int(manifest["output_num_rows"]),
        verbose=False,
    )
    simulated = torch.tensor(parsed["flat_values"], dtype=torch.float32)
    golden = torch.load(
        workload_dir / "golden_output.pt", map_location="cpu", weights_only=True
    ).to(torch.float32).flatten()
    if simulated.numel() != golden.numel():
        raise AssertionError(
            f"RTL-v6 output length mismatch: simulated={simulated.numel()}, "
            f"golden={golden.numel()}"
        )

    absolute_error = torch.abs(simulated - golden)
    close = torch.isclose(
        simulated,
        golden,
        atol=float(manifest["atol"]),
        rtol=float(manifest["rtol"]),
        equal_nan=True,
    )
    match_rate = 100.0 * float(close.to(torch.float32).mean().item())
    result = {
        "fidelity": "production_full_machine_rtl",
        "elements_compared": simulated.numel(),
        "match_rate_pct": match_rate,
        "mean_absolute_error": float(absolute_error.mean().item()),
        "max_absolute_error": float(absolute_error.max().item()),
        "atol": float(manifest["atol"]),
        "rtol": float(manifest["rtol"]),
        "passed": match_rate >= float(manifest["min_allclose_match_rate"]),
    }
    (workload_dir / "rtl_full_machine_result.json").write_text(
        json.dumps(result, indent=2, sort_keys=True) + "\n"
    )
    if not result["passed"]:
        raise AssertionError(f"RTL-v6 numerical comparison failed: {result}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="PLENA SimTop RTL Testbench")
    parser.add_argument(
        "--workload-dir",
        type=str,
        required=True,
        help="Path to workload build directory (from testworkloads)"
    )
    args = parser.parse_args()

    run_with_workload(args.workload_dir)
