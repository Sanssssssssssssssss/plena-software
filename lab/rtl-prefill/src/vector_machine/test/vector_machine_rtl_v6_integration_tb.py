#!/usr/bin/env python3
from pathlib import Path
import os
import sys

sys.path.insert(0, str(Path(__file__).parents[3] / "tools"))

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer
from cfl_cocotb import veri_runner
from cfl_cocotb.fp_generation import FpGenerator
from cfl_cocotb.runner import SRC_PATH


EXP = 6
MANT = 5
FP_WIDTH = EXP + MANT + 1
VLEN = 16
ROW_LANE_TIERS = (1, 2, 4, 8)
STATE_ENTRIES = 64
STALL_ELEMENT = 0
ADD_ELEMENT = 1
SUB_ELEMENT = 2
STALL_REDUCTION = 0
MAX_REDUCTION = 2


def pack_vector(values):
    result = 0
    mask = (1 << FP_WIDTH) - 1
    for lane, value in enumerate(values):
        result |= (int(value) & mask) << (lane * FP_WIDTH)
    return result


def unpack_vector(value):
    mask = (1 << FP_WIDTH) - 1
    return [
        (int(value) >> (lane * FP_WIDTH)) & mask
        for lane in range(VLEN)
    ]


async def reset(dut):
    row_lanes = int(dut.configured_row_lanes.value)
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    dut.rst.value = 1
    dut.ordinary_write_valid.value = 0
    dut.ordinary_read_valid.value = 0
    dut.normal_valid.value = 0
    dut.normal_element_operation.value = STALL_ELEMENT
    dut.normal_a.value = 0
    dut.normal_b.value = 0
    dut.normal_result_addr.value = 0
    dut.row_command_valid.value = 0
    dut.row_element_operation.value = STALL_ELEMENT
    dut.row_reduction_operation.value = STALL_REDUCTION
    dut.row_state_operation.value = 0
    dut.row_stats_operand.value = 0
    dut.row_state_phase.value = 0
    dut.row_active_rows.value = row_lanes
    dut.row_vector_base_addr.value = 0
    dut.row_state_base_addr.value = 0
    dut.row_scalar.value = 0
    dut.row_scalar_valid.value = 0
    for _ in range(5):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)
    await Timer(1, units="ns")


async def write_row(dut, row, values):
    dut.ordinary_addr.value = row * VLEN
    dut.ordinary_write_data.value = pack_vector(values)
    dut.ordinary_write_mask.value = (1 << VLEN) - 1
    dut.ordinary_write_valid.value = 1
    await RisingEdge(dut.clk)
    dut.ordinary_write_valid.value = 0
    await Timer(1, units="ns")


async def read_row(dut, row):
    dut.ordinary_addr.value = row * VLEN
    dut.ordinary_read_valid.value = 1
    await RisingEdge(dut.clk)
    dut.ordinary_read_valid.value = 0
    await Timer(1, units="ns")
    assert int(dut.ordinary_read_data_valid.value)
    return unpack_vector(dut.ordinary_read_data.value)


async def issue_row_command(
    dut,
    *,
    element=STALL_ELEMENT,
    reduction=STALL_REDUCTION,
    state=False,
    stats=False,
    phase=0,
    active_rows=None,
    vector_base=0,
    state_base=0,
):
    if active_rows is None:
        active_rows = int(dut.configured_row_lanes.value)
    dut.row_element_operation.value = element
    dut.row_reduction_operation.value = reduction
    dut.row_state_operation.value = int(state)
    dut.row_stats_operand.value = int(stats)
    dut.row_state_phase.value = phase
    dut.row_active_rows.value = active_rows
    dut.row_vector_base_addr.value = vector_base
    dut.row_state_base_addr.value = state_base
    dut.row_command_valid.value = 1

    for _ in range(100):
        await Timer(1, units="ns")
        if int(dut.row_command_ready.value):
            await RisingEdge(dut.clk)
            break
        await RisingEdge(dut.clk)
    else:
        raise AssertionError("row command was not accepted")

    dut.row_command_valid.value = 0
    await Timer(1, units="ns")
    for _ in range(400):
        if int(dut.row_done.value):
            # done is the commit pulse; busy/in-flight retire on the following
            # active edge.  Do not launch an ordinary SRAM access in the
            # middle of that retirement cycle.
            await RisingEdge(dut.clk)
            await Timer(1, units="ns")
            return
        await RisingEdge(dut.clk)
        await Timer(1, units="ns")
    raise AssertionError("row command did not complete")


@cocotb.test()
async def production_vector_machine_preserves_normal_vector_path(dut):
    await reset(dut)
    fp = FpGenerator(EXP, MANT)
    encoded_a = fp.generate_specified_value_fp_input([1.0] * VLEN)[1]
    encoded_b = fp.generate_specified_value_fp_input([2.0] * VLEN)[1]
    encoded_expected = fp.generate_specified_value_fp_input([3.0] * VLEN)[1]

    dut.normal_element_operation.value = ADD_ELEMENT
    dut.normal_a.value = pack_vector(encoded_a)
    dut.normal_b.value = pack_vector(encoded_b)
    dut.normal_result_addr.value = 8 * VLEN
    dut.normal_valid.value = 1
    await RisingEdge(dut.clk)
    dut.normal_valid.value = 0

    observed = None
    for _ in range(100):
        await RisingEdge(dut.clk)
        await Timer(1, units="ns")
        if int(dut.normal_write_valid.value):
            observed = unpack_vector(dut.normal_write_data.value)
            assert int(dut.normal_write_addr.value) == 8 * VLEN
            break

    assert observed == encoded_expected
    await RisingEdge(dut.clk)
    stored = await read_row(dut, 8)
    assert stored == encoded_expected
    assert int(dut.auxiliary_access_conflict.value) == 0


@cocotb.test()
async def production_vector_machine_and_banked_sram_execute_tail_row_group(dut):
    await reset(dut)
    row_lanes = int(dut.configured_row_lanes.value)
    active_rows = min(3, row_lanes)
    fp = FpGenerator(EXP, MANT)
    score_values = [
        [float((row + 1) * lane + 1) for lane in range(VLEN)]
        for row in range(row_lanes)
    ]
    encoded_rows = [
        fp.generate_specified_value_fp_input(values)[1]
        for values in score_values
    ]
    encoded_zero = fp.generate_specified_value_fp_input([0.0])[1][0]
    decoded_zero = fp.custom_fp_to_float(encoded_zero)
    for row, values in enumerate(encoded_rows):
        await write_row(dut, row, values)

    # MAX -> first-block state update -> in-place SUB. For R4/R8, only three
    # physical banks are active; lower tiers exercise their full group.
    await issue_row_command(
        dut,
        reduction=MAX_REDUCTION,
        active_rows=active_rows,
        vector_base=0,
        state_base=0,
    )
    await issue_row_command(
        dut,
        state=True,
        phase=0,
        active_rows=active_rows,
        state_base=0,
    )
    await issue_row_command(
        dut,
        element=SUB_ELEMENT,
        stats=True,
        active_rows=active_rows,
        vector_base=0,
        state_base=0,
    )

    for row in range(active_rows):
        encoded = await read_row(dut, row)
        decoded = [fp.custom_fp_to_float(value) for value in encoded]
        # FpGenerator's diagnostic decoder maps the all-zero encoding to the
        # minimum exponent value rather than Python 0.0.  Check the hardware
        # encoding exactly and use that decoded value as the comparison bound.
        assert encoded[-1] == encoded_zero
        assert max(decoded) <= decoded_zero

    for row in range(active_rows, row_lanes):
        assert await read_row(dut, row) == encoded_rows[row]
    assert int(dut.accepted_command_count.value) == 3
    assert int(dut.accepted_group_read_count.value) == 2
    assert int(dut.committed_group_write_count.value) == 1
    assert int(dut.auxiliary_access_conflict.value) == 0


@cocotb.test()
async def production_reduction_path_accepts_independent_groups_at_ii_one(dut):
    await reset(dut)
    row_lanes = int(dut.configured_row_lanes.value)
    fp = FpGenerator(EXP, MANT)
    encoded = fp.generate_specified_value_fp_input([1.0] * VLEN)[1]
    for row in range(2 * row_lanes):
        await write_row(dut, row, encoded)

    dut.row_element_operation.value = STALL_ELEMENT
    dut.row_reduction_operation.value = MAX_REDUCTION
    dut.row_state_operation.value = 0
    dut.row_stats_operand.value = 0
    dut.row_state_phase.value = 0
    dut.row_active_rows.value = row_lanes
    dut.row_vector_base_addr.value = 0
    dut.row_state_base_addr.value = 0
    dut.row_command_valid.value = 1
    await Timer(1, units="ns")
    assert int(dut.row_command_ready.value)
    await RisingEdge(dut.clk)

    dut.row_vector_base_addr.value = row_lanes * VLEN
    dut.row_state_base_addr.value = row_lanes
    await Timer(1, units="ns")
    assert int(dut.row_command_ready.value)
    await RisingEdge(dut.clk)
    dut.row_command_valid.value = 0

    completions = 0
    for _ in range(200):
        await Timer(1, units="ns")
        if int(dut.row_reduction_done.value):
            completions += 1
        if completions == 2:
            break
        await RisingEdge(dut.clk)

    assert completions == 2
    assert int(dut.accepted_command_count.value) == 2
    assert int(dut.accepted_group_read_count.value) == 2
    assert int(dut.auxiliary_access_conflict.value) == 0


def test_vector_machine_rtl_v6_integration():
    # cocotb invokes make separately from Verilator, so Verilator's
    # -build-jobs option alone does not parallelize the generated C++ build.
    os.environ.setdefault("MAKEFLAGS", "-j32")
    veri_runner(
        group="vector_machine",
        module="vector_machine_rtl_v6_integration_wrapper",
        module_param_list=[
            {
                "ROW_LANES": row_lanes,
                "STATE_ENTRIES": STATE_ENTRIES,
                "SRAM_DEPTH": 64,
            }
            for row_lanes in ROW_LANE_TIERS
        ],
        additional_include_paths=[
            str(SRC_PATH / "memory" / "vector_sram"),
            str(SRC_PATH / "basic_components" / "buffer"),
            str(SRC_PATH / "basic_components" / "cast"),
            str(SRC_PATH / "basic_components" / "common"),
            str(SRC_PATH / "basic_components" / "conversion"),
            str(SRC_PATH / "basic_components" / "fixed_operation"),
            str(SRC_PATH / "basic_components" / "fp_operation"),
            str(SRC_PATH / "basic_components" / "int_operation"),
            str(SRC_PATH / "basic_components" / "synopsis"),
            str(SRC_PATH / "basic_components" / "synopsis_ip_inst"),
        ],
        definitions_path=[str(SRC_PATH / "definitions")],
        test_module="vector_machine_rtl_v6_integration_tb",
        # The production FP datapath elaborates into many helper functions.
        # Coarser split thresholds keep this module-level regression parallel
        # without generating more than a thousand tiny translation units.
        extra_build_args=[
            # This regression validates wiring and protocol behavior, not C++
            # simulator performance.  The generated production FP datapath is
            # large enough that host -O2 spends minutes optimizing each split
            # translation unit without changing the RTL result.
            "-CFLAGS",
            "-O0",
            "--output-split",
            "200000",
            "--output-split-cfuncs",
            "20000",
        ],
        trace=False,
    )


if __name__ == "__main__":
    test_vector_machine_rtl_v6_integration()
