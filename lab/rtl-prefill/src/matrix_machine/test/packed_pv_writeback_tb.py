#!/usr/bin/env python3
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).parents[3] / "tools"))

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer
from cfl_cocotb import veri_runner
from cfl_cocotb.fp_generation import FpGenerator
from cfl_cocotb.runner import SRC_PATH


EXP = 5
MANT = 6
FP_WIDTH = EXP + MANT + 1
VLEN = 8
BLEN = 4


def pack(values):
    result = 0
    mask = (1 << FP_WIDTH) - 1
    for lane, value in enumerate(values):
        result |= (int(value) & mask) << (lane * FP_WIDTH)
    return result


def unpack(value):
    mask = (1 << FP_WIDTH) - 1
    return [(int(value) >> (lane * FP_WIDTH)) & mask for lane in range(VLEN)]


async def reset(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    dut.rst.value = 1
    dut.start.value = 0
    dut.matrix_row_valid.value = 0
    dut.sram_read_ready.value = 1
    dut.sram_read_valid.value = 0
    dut.sram_write_ready.value = 1
    for _ in range(4):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)


async def run_burst(dut, base_addr, lane_offset, matrix_rows, old_rows=None):
    accumulate = old_rows is not None
    read_queue = []
    writes = []
    row_index = 0

    dut.base_addr.value = base_addr
    dut.lane_offset.value = lane_offset
    dut.accumulate.value = int(accumulate)
    dut.start.value = 1

    for cycle in range(200):
        # A synchronous SRAM returns the accepted row one cycle later.
        if read_queue:
            address = read_queue.pop(0)
            row = (address - base_addr) // VLEN
            dut.sram_read_valid.value = 1
            dut.sram_read_data.value = pack(old_rows[row])
        else:
            dut.sram_read_valid.value = 0
            dut.sram_read_data.value = 0

        if row_index < BLEN and int(dut.matrix_row_ready.value):
            dut.matrix_row_valid.value = 1
            dut.matrix_row.value = pack(matrix_rows[row_index])
        else:
            dut.matrix_row_valid.value = 0
        await Timer(1, units="ns")

        accepted_row = (
            row_index
            if int(dut.matrix_row_valid.value) and int(dut.matrix_row_ready.value)
            else None
        )
        accepted_read = int(dut.sram_read_req.value) and int(dut.sram_read_ready.value)
        read_addr = int(dut.sram_read_addr.value)
        write_valid = int(dut.sram_write_req.value) and int(dut.sram_write_ready.value)
        if write_valid:
            writes.append((
                int(dut.sram_write_addr.value),
                unpack(dut.sram_write_data.value),
                int(dut.sram_write_mask.value),
            ))

        await RisingEdge(dut.clk)
        dut.start.value = 0

        if accepted_row is not None:
            row_index += 1
        if accepted_read:
            read_queue.append(read_addr)
        if int(dut.done.value):
            # The final write was sampled immediately before this edge.
            break
    else:
        raise AssertionError("packed-PV burst did not complete")

    dut.matrix_row_valid.value = 0
    dut.sram_read_valid.value = 0
    assert row_index == BLEN
    assert len(writes) == BLEN
    assert int(dut.accepted_rows.value) == BLEN
    assert int(dut.committed_rows.value) == BLEN
    return writes


@cocotb.test()
async def consecutive_overwrite_and_accumulate_rows_preserve_context(dut):
    await reset(dut)
    fp = FpGenerator(EXP, MANT)

    def enc(values):
        return fp.generate_specified_value_fp_input(values)[1]

    matrix_values = [[float(row + lane + 1) for lane in range(BLEN)] + [0.0] * 4
                     for row in range(BLEN)]
    matrix_rows = [enc(values) for values in matrix_values]

    overwrite = await run_burst(dut, 64, 2, matrix_rows)
    expected_mask = ((1 << BLEN) - 1) << 2
    for row, (address, data, mask) in enumerate(overwrite):
        assert address == 64 + row * VLEN
        assert mask == expected_mask
        assert data[2:2 + BLEN] == matrix_rows[row][:BLEN]

    old_values = [[float(16 + row * 2 + lane) for lane in range(VLEN)]
                  for row in range(BLEN)]
    old_rows = [enc(values) for values in old_values]
    accumulated = await run_burst(dut, 256, 2, matrix_rows, old_rows)
    for row, (address, data, mask) in enumerate(accumulated):
        assert address == 256 + row * VLEN
        assert mask == expected_mask
        expected = enc([
            old_values[row][lane + 2] + matrix_values[row][lane]
            for lane in range(BLEN)
        ])
        assert data[2:2 + BLEN] == expected
        assert data[:2] == old_rows[row][:2]
        assert data[6:] == old_rows[row][6:]


def test_packed_pv_writeback():
    veri_runner(
        group="matrix_machine",
        module="packed_pv_writeback",
        module_param_list=[{
            "EXP_WIDTH": EXP,
            "MANT_WIDTH": MANT,
            "VLEN": VLEN,
            "BLEN": BLEN,
        }],
        additional_include_paths=[
            str(SRC_PATH / "basic_components" / "buffer"),
            str(SRC_PATH / "basic_components" / "common"),
            str(SRC_PATH / "basic_components" / "fp_operation"),
            str(SRC_PATH / "basic_components" / "int_operation"),
            str(SRC_PATH / "basic_components" / "synopsis_ip_inst"),
        ],
        definitions_path=[str(SRC_PATH / "definitions")],
        trace=False,
    )


if __name__ == "__main__":
    test_packed_pv_writeback()
