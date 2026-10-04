`timescale 1ns / 1ps

`include "precision.svh"
`include "configuration.svh"
`include "operation.svh"

/*
Module      : Testbench Wrapper for decoder
Description : Exposes OP_BUNDLE struct fields as flat output ports so
              cocotb/Verilator can probe them individually. Instantiates
              decoder and wires the structs through.
*/

module decoder_tb_wrapper import instruction_pkg::*; import configuration_pkg::*; (
    input  logic clk,
    input  logic rst,
    input  logic system_stall_flag,
    input  logic pipeline_stall,

    // Instruction input
    input  logic [INSTRUCTION_LENGTH - 1 : 0] instruction,
    input  logic instruction_valid,
    output logic instruction_ready,

    // Flat outputs for decode_stage_op fields
    output logic [3:0] dec_m_op,
    output logic [3:0] dec_v_ele_op,
    output logic [2:0] dec_v_reduct_op,
    output logic [3:0] dec_s_fp_op,
    output logic [3:0] dec_c_op,
    output logic [2:0] dec_h_op,
    output logic       dec_update_m_waddr,
    output logic       dec_update_v_waddr,
    output logic       dec_v_softmax_rows_en,
    output logic       dec_v_softmax_state_en,
    output logic [1:0] dec_v_softmax_state_phase,
    output logic [1:0] dec_v_softmax_row_log2,
    output logic [3:0] dec_v_softmax_active_rows,
    output logic       dec_m_packed_acc_en,
    output logic       dec_m_packed_accumulate,
    output logic [15:0] dec_m_packed_lane_offset,

    // Integer outputs
    output logic [3:0] out_assigned_int_op,
    output logic [INT_OPERAND_WIDTH-1:0] out_rd,
    output logic [INT_OPERAND_WIDTH-1:0] out_rs1,
    output logic [INT_OPERAND_WIDTH-1:0] out_rs2,
    output logic [IMM_WIDTH-1:0] out_imm
);

    OP_BUNDLE decode_stage_op;
    S_INT_OP  assigned_int_op;
    logic [INT_OPERAND_WIDTH-1:0] rd, rs1, rs2;
    logic [IMM_WIDTH-1:0] imm;
    logic agu_boundary_step;
    logic agu_boundary_exit;
    logic agu_config_valid;
    logic [INT_OPERAND_WIDTH-1:0] agu_config_reg;
    logic [IMM_WIDTH-1:0] agu_config_stride;
    logic agu_frame_start;
    logic [INT_OPERAND_WIDTH-1:0] agu_frame_counter_reg;
    localparam int TEST_IMEM_DEPTH = 1024;
    logic [INSTRUCTION_LENGTH-1:0] test_imem [0:TEST_IMEM_DEPTH-1];
    logic [$clog2(TEST_IMEM_DEPTH):0] test_imem_count;
    logic [PC_ADDR_WIDTH-1:0] decoder_pc;
    logic [INSTRUCTION_LENGTH-1:0] fetched_instruction;
    logic fetched_instruction_valid;

    // Adapt the legacy streaming cocotb input to the current PC-driven decoder
    // interface. This is simulation-only storage; production uses instr_mem.
    assign instruction_ready = test_imem_count < TEST_IMEM_DEPTH;
    assign fetched_instruction_valid = (decoder_pc >> 2) < test_imem_count;
    assign fetched_instruction = fetched_instruction_valid
                               ? test_imem[decoder_pc >> 2] : '0;
    always_ff @(posedge clk) begin
        if (rst) begin
            test_imem_count <= '0;
        end else if (instruction_valid && instruction_ready) begin
            test_imem[test_imem_count] <= instruction;
            test_imem_count <= test_imem_count + 1'b1;
        end
    end

    decoder dut_i (
        .clk(clk),
        .rst(rst),
        .system_stall_flag(system_stall_flag),
        .pipeline_stall(pipeline_stall),
        .pc(decoder_pc),
        .instruction_from_imem(fetched_instruction),
        .instruction_addr_from_imem(decoder_pc),
        .instruction_ready(fetched_instruction_valid),
        .decode_stage_op(decode_stage_op),
        .assigned_int_op(assigned_int_op),
        .rd(rd), .rs1(rs1), .rs2(rs2), .imm(imm),
        .agu_boundary_step(agu_boundary_step),
        .agu_boundary_exit(agu_boundary_exit),
        .agu_config_valid(agu_config_valid),
        .agu_config_reg(agu_config_reg),
        .agu_config_stride(agu_config_stride),
        .agu_frame_start(agu_frame_start),
        .agu_frame_counter_reg(agu_frame_counter_reg),
        .c_break_detected(),
        .loop_counter_zero(1'b0)
    );

    // Flatten struct for cocotb
    assign dec_m_op           = decode_stage_op.m_op;
    assign dec_v_ele_op       = decode_stage_op.v_ele_op;
    assign dec_v_reduct_op    = decode_stage_op.v_reduct_op;
    assign dec_s_fp_op        = decode_stage_op.s_fp_op;
    assign dec_c_op           = decode_stage_op.c_op;
    assign dec_h_op           = decode_stage_op.h_op;
    assign dec_update_m_waddr = decode_stage_op.update_m_waddr;
    assign dec_update_v_waddr = decode_stage_op.update_v_waddr;
    assign dec_v_softmax_rows_en = decode_stage_op.v_softmax_rows_en;
    assign dec_v_softmax_state_en = decode_stage_op.v_softmax_state_en;
    assign dec_v_softmax_state_phase = decode_stage_op.v_softmax_state_phase;
    assign dec_v_softmax_row_log2 = decode_stage_op.v_softmax_row_log2;
    assign dec_v_softmax_active_rows = decode_stage_op.v_softmax_active_rows;
    assign dec_m_packed_acc_en = decode_stage_op.m_packed_acc_en;
    assign dec_m_packed_accumulate = decode_stage_op.m_packed_accumulate;
    assign dec_m_packed_lane_offset = decode_stage_op.m_packed_lane_offset;
    assign out_assigned_int_op = assigned_int_op;
    assign out_rd  = rd;
    assign out_rs1 = rs1;
    assign out_rs2 = rs2;
    assign out_imm = imm;

endmodule
