#!/usr/bin/env python3

import logging
import math
import pytest
import cocotb
from cocotb.triggers import Timer, RisingEdge
from cocotb.clock import Clock
from cfl_cocotb import veri_runner, FpGenerator, SRC_PATH

exp_width = 4
mant_width = 3
vect_dim = 4

level = math.ceil(math.log2(vect_dim))


generator = FpGenerator(exp_width, mant_width)

logger = logging.getLogger("testbench")
logger.setLevel(logging.INFO)

@cocotb.test()
async def random_fp_sum_test(dut):
    # Start clock generation
    TESTCASE_SIZE = 1
    
    cocotb.start_soon(Clock(dut.clk, 2, units="ns").start())  # 2ns period (1GHz clock)
    
    await Timer(5, units="ns")
    cocotb.log.info("Starting fp addition test")
    # Apply Reset
    dut.rst.value = 0
    await Timer(5, units="ns")  # Hold reset for 5ns
    dut.rst.value = 1
    await Timer(5, units="ns")  # Allow some settling time

    for i in range (TESTCASE_SIZE):
        # Generate random floating point values

        # fp_values, results = generator.generate_fp_input(vect_dim)
        fp_values, results = generator.generate_specified_value_fp_input([4.517, 1.18, 2.98, 10.00])
        # fp_values, results = generator.generate_specified_value_fp_input([40.517, 40.517, 40.517, 40.517, 30.231, 30.231, 30.231, 30.231])
        input_data_a = sum((results[n] << (exp_width + mant_width + 1) * n ) for n in range(vect_dim))
        dut.v_in.value = input_data_a

        # await RisingEdge(dut.clk)
        await Timer(2, units="ns")
        # cocotb.log.info("<-------  INPUT DATA  --------->")
        # for m in range(2*vect_dim):
        #     cocotb.log.info(f"Value at index {m} : {fp_values[m]}, Result : {generator.custom_fp_to_float(results[m])}, Binary: {bin(results[m])}")
        
        # cocotb.log.info(f"Input Binary data_a {dut.v_in_a.value}")
        # cocotb.log.info(f"Input Binary data_b {dut.v_in_b.value}")
        # generator.translate_packed_array_fp(vect_dim, exp_width, mant_width, dut.data_a_in.value)

        dut.v_in_valid.value = 1
        dut.v_out_ready.value = 1
        dut.operation = 0

        await Timer(4, units="ns")
        addition_result = 0
        for i in range(0, vect_dim):
            # Get the expected result
            addition_result += fp_values[i]
        cocotb.log.info("<-------  Addition Result DATA  --------->")
        cocotb.log.info(f"Internal Product Binary Results : {dut.v_out.value}")
        cocotb.log.info(f"Internal Converted Results : {generator.translate_packed_array_fp(vect_dim, exp_width, mant_width, dut.v_out.value)}")
        cocotb.log.info(f"Internal Product Ref : {addition_result}")


@cocotb.test()
async def random_fp_max_test(dut):
    TESTCASE_SIZE = 1
    cocotb.start_soon(Clock(dut.clk, 2, units="ns").start())

    await Timer(5, units="ns")
    cocotb.log.info("Starting fp max test")
    dut.rst.value = 0
    await Timer(5, units="ns")
    dut.rst.value = 1
    await Timer(5, units="ns")

    for i in range(TESTCASE_SIZE):
        fp_values, results = generator.generate_specified_value_fp_input([4.517, 1.18, 2.98, 10.00])
        input_data_a = sum((results[n] << (exp_width + mant_width + 1) * n) for n in range(vect_dim))
        dut.v_in.value = input_data_a
        await Timer(2, units="ns")

        dut.v_in_valid.value = 1
        dut.v_out_ready.value = 1
        dut.operation = 1

        await Timer(4, units="ns")
        max_result = max(fp_values[:vect_dim])
        cocotb.log.info(f"Max Results: {generator.translate_packed_array_fp(vect_dim, exp_width, mant_width, dut.v_out.value)}")
        cocotb.log.info(f"Max Ref: {max_result}")


@pytest.mark.dev
LATENCY_VLEN = 8
LATENCY_EXP_WIDTH = 4
LATENCY_MANT_WIDTH = 3
# VEC_DIM = VLEN + 1 (see RTL: localparam VEC_DIM = VLEN + 1)
LATENCY_VEC_DIM = LATENCY_VLEN + 1

VECTOR_SUM_CYCLES = 20
VECTOR_MAX_CYCLES = 4

latency_generator = FpGenerator(LATENCY_EXP_WIDTH, LATENCY_MANT_WIDTH)


async def _measure_reduction_latency(dut, operation_val):
    """
    Drive v_in with LATENCY_VEC_DIM packed FP values for the given operation,
    count clock cycles from v_in_valid=1 until s_out_valid=1, then return
    the cycle count.
    """
    # Pack LATENCY_VEC_DIM distinct FP values
    fp_input = [float(i + 1) for i in range(LATENCY_VEC_DIM)]
    _fp_values, results = latency_generator.generate_specified_value_fp_input(fp_input)

    fp_word = LATENCY_EXP_WIDTH + LATENCY_MANT_WIDTH + 1
    packed = sum(results[n] << (fp_word * n) for n in range(LATENCY_VEC_DIM))

    dut.v_in.value = packed
    dut.operation.value = operation_val
    dut.s_out_ready.value = 1
    dut.v_in_valid.value = 1

    cycles = 0
    for _ in range(200):
        await RisingEdge(dut.clk)
        cycles += 1
        if dut.s_out_valid.value == 1:
            break
    else:
        cocotb.log.warning("[LATENCY] s_out_valid never asserted within 200 cycles")

    # De-assert after capturing
    dut.v_in_valid.value = 0

    return cycles


@cocotb.test()
async def reduction_latency_test(dut):
    """Measure latency (cycles) for SUM and MAX reduction operations."""
    # Active-high reset: rst=1 asserts, rst=0 releases (see register_slice.sv: if (rst) ...)
    # Start clock (test1's background Clock task is cancelled on test failure, so restart here)
    cocotb.start_soon(Clock(dut.clk, 2, units="ns").start())

    dut.rst.value = 1        # assert reset
    dut.v_in_valid.value = 0
    dut.s_out_ready.value = 0
    dut.operation.value = 0
    await Timer(10, units="ns")
    dut.rst.value = 0        # release reset
    await Timer(10, units="ns")

    cocotb.log.info("[LATENCY] Starting reduction latency measurement (VLEN=8)")

    # --- SUM --- (SUM_V_REDUCT=1, MAX_V_REDUCT=2, STALL=0)
    sum_cycles = await _measure_reduction_latency(dut, operation_val=1)

    # Drain: wait a few cycles before next test
    for _ in range(4):
        await RisingEdge(dut.clk)

    # Reset between operations
    dut.rst.value = 1        # assert reset
    dut.v_in_valid.value = 0
    await Timer(10, units="ns")
    dut.rst.value = 0        # release reset
    await Timer(10, units="ns")

    # --- MAX ---
    max_cycles = await _measure_reduction_latency(dut, operation_val=2)

    # Report results
    sum_match = "MATCH" if sum_cycles == VECTOR_SUM_CYCLES else "DIFF"
    max_match = "MATCH" if max_cycles == VECTOR_MAX_CYCLES else "DIFF"

    cocotb.log.info(
        f"[LATENCY] V_RED_SUM: {sum_cycles} cycles "
        f"(sim VECTOR_SUM_CYCLES={VECTOR_SUM_CYCLES})  {sum_match}"
    )
    cocotb.log.info(
        f"[LATENCY] V_RED_MAX: {max_cycles} cycles "
        f"(sim VECTOR_MAX_CYCLES={VECTOR_MAX_CYCLES})   {max_match}"
    )


@pytest.mark.dev
def latency_test():
    veri_runner(
        group="vector_machine",
        module="fp_reduction_compute_unit",
        additional_include_paths=[
            str(SRC_PATH / "basic_components/buffer"),
            str(SRC_PATH / "basic_components/common"),
            str(SRC_PATH / "basic_components/fp_operation"),
            str(SRC_PATH / "basic_components/int_operation"),
            str(SRC_PATH / "basic_components/cast"),
        ],
        definitions_path=[str(SRC_PATH / "definitions")],
        module_param_list=[
            {"EXP_WIDTH": LATENCY_EXP_WIDTH, "MANT_WIDTH": LATENCY_MANT_WIDTH, "VLEN": LATENCY_VLEN},
        ],
        trace=True,
        test_module="reduction_compute_unit_tb",
    )


if __name__ == "__main__":
    latency_test()
