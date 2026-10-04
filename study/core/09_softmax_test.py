# 学习注： 来源 lab/rtl-prefill/src/vector_machine/test/softmax_row_engine_tb.py，原始行 1–283。
# 学习注： 这是核心阅读副本；运行仍用原目录及其依赖。只新增注释，没有修改逻辑。
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
ROW_LANES = 4
# 学习注：故意只用四路中的三路，验证尾行 mask，而非只测整齐满载。
ACTIVE_ROWS = 3
STALL = 0
MUL = 3
RED_SUM = 1
RED_MAX = 2


def pack_rows(rows):
    result = 0
    mask = (1 << FP_WIDTH) - 1
    for row_index, row in enumerate(rows):
        for lane, value in enumerate(row):
            result |= (int(value) & mask) << (
                (row_index * VLEN + lane) * FP_WIDTH
            )
    return result


def unpack_rows(value):
    mask = (1 << FP_WIDTH) - 1
    return [[
        (int(value) >> ((row * VLEN + lane) * FP_WIDTH)) & mask
        for lane in range(VLEN)
    ] for row in range(ROW_LANES)]


async def reset(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    dut.rst.value = 1
    dut.command_valid.value = 0
    dut.group_read_valid.value = 0
    dut.group_write_ready.value = 1
    dut.scalar_in_valid.value = 0
    for _ in range(4):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)


# 学习注：驱动 valid/ready、提供 SRAM 返回数据、等 done，并给超时边界。
async def issue_command(
    dut,
    *,
    element=STALL,
    reduction=STALL,
    state=False,
    stats_operand=False,
    phase=0,
    rows=None,
    vector_base=0,
    state_base=0,
):
    while not int(dut.command_ready.value):
        await RisingEdge(dut.clk)

    dut.element_operation.value = element
    dut.reduction_operation.value = reduction
    dut.state_operation.value = int(state)
    dut.stats_operand.value = int(stats_operand)
    dut.state_phase.value = phase
    dut.active_rows.value = ACTIVE_ROWS
    dut.vector_base_addr.value = vector_base
    dut.state_base_addr.value = state_base
    dut.scalar_in.value = 0
    dut.scalar_in_valid.value = 0
    dut.command_valid.value = 1
    await RisingEdge(dut.clk)
    dut.command_valid.value = 0

    if rows is not None:
        dut.group_read_data.value = pack_rows(rows)
        dut.group_read_valid.value = 1
        await RisingEdge(dut.clk)
        dut.group_read_valid.value = 0

    writeback = None
    # 学习注：超时可发现死锁；测试通过必须含功能检查，不能只是等到 finish。
    for _ in range(300):
        await RisingEdge(dut.clk)
        await Timer(1, units="ns")
        if int(dut.group_write_req.value):
            writeback = (
                int(dut.group_write_addr.value),
                int(dut.group_write_active_rows.value),
                unpack_rows(dut.group_write_data.value),
                int(dut.group_write_mask.value),
            )

        if int(dut.done.value):
            return writeback

    raise AssertionError("softmax row command did not complete")


@cocotb.test()
# 学习注：覆盖首块、递推块、final reciprocal 与最终输出缩放。
async def first_block_state_tail_and_final_factor_flow_through_row_engine(dut):
    await reset(dut)
    fp = FpGenerator(EXP, MANT)

    def enc(values):
        return fp.generate_specified_value_fp_input(values)[1]

    score_values = [
        [1.0] * VLEN,
        [2.0] * VLEN,
        [4.0] * VLEN,
        [64.0] * VLEN,
    ]
    scores = [enc(row) for row in score_values]
    state_base = 8

    await issue_command(
        dut, reduction=RED_MAX, rows=scores, vector_base=0,
        state_base=state_base,
    )
    await issue_command(dut, state=True, phase=0, state_base=state_base)
    await issue_command(
        dut, reduction=RED_SUM, rows=scores, vector_base=0,
        state_base=state_base,
    )
    await issue_command(dut, state=True, phase=1, state_base=state_base)
    # A second block with the same maxima exercises the recurrent
    # m_new/m_res/l_new path. m_res is exactly one and l doubles.
    await issue_command(
        dut, reduction=RED_MAX, rows=scores, vector_base=0,
        state_base=state_base,
    )
    await issue_command(dut, state=True, phase=0, state_base=state_base)
    await issue_command(
        dut, reduction=RED_SUM, rows=scores, vector_base=0,
        state_base=state_base,
    )
    await issue_command(dut, state=True, phase=1, state_base=state_base)
    await issue_command(dut, state=True, phase=2, state_base=state_base)

    output_values = [
        [16.0] * VLEN,
        [32.0] * VLEN,
        [64.0] * VLEN,
        [128.0] * VLEN,
    ]
    outputs = [enc(row) for row in output_values]
    writeback = await issue_command(
        dut,
        element=MUL,
        stats_operand=True,
        rows=outputs,
        vector_base=4 * VLEN,
        state_base=state_base,
    )

    assert writeback is not None
    address, active_rows, data, mask = writeback
    assert address == 4 * VLEN
    assert active_rows == ACTIVE_ROWS
    assert mask == (1 << (ACTIVE_ROWS * VLEN)) - 1
    # The production reciprocal is an approximation rather than correctly
    # rounded division. Exact equivalence is therefore checked against the
    # one-row RTL oracle instantiated in the wrapper, not against real 1.0.
    # 学习注：对照单行 RTL oracle，核对相同低精度路径的 bit-exact 行为。
    assert int(dut.state_reference_mismatch.value) == 0
    for row in range(ACTIVE_ROWS):
        values = [fp.custom_fp_to_float(value) for value in data[row]]
        assert len(set(data[row])) == 1
        assert all(0.85 < value <= 1.0 for value in values), values
    assert data[3] == [0] * VLEN


@cocotb.test()
async def independent_reduction_groups_issue_on_consecutive_cycles(dut):
    await reset(dut)
    fp = FpGenerator(EXP, MANT)
    encoded = fp.generate_specified_value_fp_input([1.0] * VLEN)[1]
    rows = [encoded for _ in range(ROW_LANES)]

    dut.element_operation.value = STALL
    dut.reduction_operation.value = RED_MAX
    dut.state_operation.value = 0
    dut.stats_operand.value = 0
    dut.state_phase.value = 0
    dut.active_rows.value = ACTIVE_ROWS
    dut.scalar_in.value = 0
    dut.scalar_in_valid.value = 0

    # Command 0.
    dut.vector_base_addr.value = 0
    dut.state_base_addr.value = 8
    dut.command_valid.value = 1
    await RisingEdge(dut.clk)
    await Timer(1, units="ns")
    launches = []
    completions = 0
    if int(dut.row0_reduction_launch.value):
        launches.append(0)
    if int(dut.reduction_done.value):
        completions += 1

    # Command 1 is accepted while command 0's SRAM result returns.  Update
    # the address before sampling ready: leaving command 0 on the bus would
    # correctly trip the row-range RAW/WAW scoreboard.
    dut.vector_base_addr.value = ROW_LANES * VLEN
    dut.state_base_addr.value = 12
    dut.group_read_data.value = pack_rows(rows)
    dut.group_read_valid.value = 1
    await Timer(1, units="ns")
    assert int(dut.command_ready.value)
    await RisingEdge(dut.clk)
    await Timer(1, units="ns")
    if int(dut.row0_reduction_launch.value):
        launches.append(1)
    if int(dut.reduction_done.value):
        completions += 1

    dut.command_valid.value = 0
    dut.group_read_data.value = pack_rows(rows)
    dut.group_read_valid.value = 1
    await RisingEdge(dut.clk)
    await Timer(1, units="ns")
    if int(dut.row0_reduction_launch.value):
        launches.append(2)
    if int(dut.reduction_done.value):
        completions += 1
    dut.group_read_valid.value = 0

    for cycle in range(3, 103):
        await RisingEdge(dut.clk)
        await Timer(1, units="ns")
        if int(dut.row0_reduction_launch.value):
            launches.append(cycle)
        if int(dut.reduction_done.value):
            completions += 1
        if completions == 2:
            break

    # The two SRAM returns launch the shared reduction tree with II=1.
    assert len(launches) == 2
    # 学习注：II=1 指独立组每拍可发射；不是所有依赖操作一拍完成。
    assert launches[1] - launches[0] == 1
    assert completions == 2


def test_softmax_row_engine():
    veri_runner(
        group="vector_machine",
        module="softmax_row_engine_test_wrapper",
        module_param_list=[{
            "EXP_WIDTH": EXP,
            "MANT_WIDTH": MANT,
            "VLEN": VLEN,
            "ROW_LANES": ROW_LANES,
            "STATE_ENTRIES": 32,
        }],
        additional_include_paths=[
            str(SRC_PATH / "basic_components" / "buffer"),
            str(SRC_PATH / "basic_components" / "cast"),
            str(SRC_PATH / "basic_components" / "common"),
            str(SRC_PATH / "basic_components" / "fp_operation"),
            str(SRC_PATH / "basic_components" / "int_operation"),
            str(SRC_PATH / "basic_components" / "synopsis_ip_inst"),
        ],
        definitions_path=[str(SRC_PATH / "definitions")],
        test_module="softmax_row_engine_tb",
        trace=False,
    )


if __name__ == "__main__":
    test_softmax_row_engine()
