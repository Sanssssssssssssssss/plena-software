#!/usr/bin/env python3
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).parents[4] / "tools"))

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge
from cfl_cocotb import veri_runner
from cfl_cocotb.runner import SRC_PATH


VLEN = 8
FP_WIDTH = 12
ROW_LANES = 4


def pack_row(values):
    packed = 0
    mask = (1 << FP_WIDTH) - 1
    for lane, value in enumerate(values):
        packed |= (int(value) & mask) << (lane * FP_WIDTH)
    return packed


def unpack_row(value):
    mask = (1 << FP_WIDTH) - 1
    return [(int(value) >> (lane * FP_WIDTH)) & mask for lane in range(VLEN)]


async def reset(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    dut.rst.value = 1
    for name in (
        "port_a_req", "port_a_write_en", "port_b_req", "port_b_write_en",
        "group_read_req", "group_write_req", "packed_read_req",
        "packed_write_req", "prefetch_en",
    ):
        getattr(dut, name).value = 0
    dut.port_b_mxfp_req.value = 0
    dut.select_write_data_a.value = 0
    dut.select_write_data_b.value = 3
    dut.port_a_mask_in.value = 0
    dut.port_b_mask_in.value = 0
    dut.group_read_active_rows.value = 0
    dut.group_write_active_rows.value = 0
    dut.group_write_mask.value = 0
    dut.packed_write_mask.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)


async def ordinary_write_b(dut, row, values):
    dut.port_b_addr.value = row * VLEN
    dut.port_b_fp_in.value = pack_row(values)
    dut.port_b_mask_in.value = (1 << VLEN) - 1
    dut.select_write_data_b.value = 3
    dut.port_b_write_en.value = 1
    dut.port_b_req.value = 1
    # Port-B FP writes traverse the existing conversion-alignment pipeline.
    await RisingEdge(dut.clk)
    dut.port_b_write_en.value = 0
    dut.port_b_req.value = 0
    for _ in range(4):
        await RisingEdge(dut.clk)


async def ordinary_read_a(dut, row):
    dut.port_a_addr.value = row * VLEN
    dut.port_a_req.value = 1
    await RisingEdge(dut.clk)
    dut.port_a_req.value = 0
    await RisingEdge(dut.clk)
    return unpack_row(dut.port_a_v_fp_out.value)


@cocotb.test()
async def banked_group_and_ordinary_access_are_consistent(dut):
    await reset(dut)

    expected = []
    for row in range(8):
        values = [row * 32 + lane + 1 for lane in range(VLEN)]
        expected.append(values)
        await ordinary_write_b(dut, row, values)

    # Ordinary reads preserve the legacy flat address contract across banks.
    for row in range(8):
        assert await ordinary_read_a(dut, row) == expected[row]

    dut.group_read_addr.value = 4 * VLEN
    dut.group_read_active_rows.value = ROW_LANES
    dut.group_read_req.value = 1
    assert int(dut.group_read_ready.value) == 1
    await RisingEdge(dut.clk)
    dut.group_read_req.value = 0
    await RisingEdge(dut.clk)
    assert int(dut.group_read_valid.value) == 1
    packed = int(dut.group_read_data.value)
    row_bits = VLEN * FP_WIDTH
    for lane in range(ROW_LANES):
        row = (packed >> (lane * row_bits)) & ((1 << row_bits) - 1)
        assert unpack_row(row) == expected[4 + lane]

    # Tail write updates only active banks and selected element lanes.
    tail_rows = [
        [0x300 + lane for lane in range(VLEN)],
        [0x340 + lane for lane in range(VLEN)],
    ]
    group_data = pack_row(tail_rows[0]) | (pack_row(tail_rows[1]) << row_bits)
    lane_mask = 0b00001111
    group_mask = lane_mask | (lane_mask << VLEN)
    dut.group_write_addr.value = 0
    dut.group_write_active_rows.value = 2
    dut.group_write_data.value = group_data
    dut.group_write_mask.value = group_mask
    dut.group_write_req.value = 1
    assert int(dut.group_write_ready.value) == 1
    await RisingEdge(dut.clk)
    dut.group_write_req.value = 0
    await RisingEdge(dut.clk)

    for row in range(2):
        got = await ordinary_read_a(dut, row)
        assert got[:4] == tail_rows[row][:4]
        assert got[4:] == expected[row][4:]
    for row in range(2, 4):
        assert await ordinary_read_a(dut, row) == expected[row]


def test_fp_vector_sram_banked():
    veri_runner(
        group="memory/vector_sram",
        module="fp_vector_sram",
        module_param_list=[{
            "EXP_WIDTH": 5,
            "MANT_WIDTH": 6,
            "VLEN": VLEN,
            "MLEN": VLEN,
            "BLEN": 4,
            "BLOCK_DIM": 4,
            "SRAM_DEPTH": 32,
            "SOFTMAX_ROW_LANES": ROW_LANES,
        }],
        additional_include_paths=[
            str(SRC_PATH / "basic_components" / "common"),
            str(SRC_PATH / "basic_components" / "conversion"),
            str(SRC_PATH / "basic_components" / "fp_operation"),
            str(SRC_PATH / "basic_components" / "fixed_operation"),
            str(SRC_PATH / "basic_components" / "int_operation"),
            str(SRC_PATH / "basic_components" / "synopsis_ip_inst"),
        ],
        definitions_path=[str(SRC_PATH / "definitions")],
        test_module="fp_vector_sram_banked_tb",
        trace=False,
    )


if __name__ == "__main__":
    test_fp_vector_sram_banked()
