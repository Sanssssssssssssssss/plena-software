`timescale 1ns / 1ps

`include "configuration.svh"
`include "operation.svh"

// Small synthesis target used for paired rtl-v5/rtl-v6 delta calibration.
module softmax_rtl_v6_area_wrapper #(
    parameter int EXP_WIDTH = 5,
    parameter int MANT_WIDTH = 6,
    parameter int VLEN = 16,
    parameter int WRITE_LANES = 4,
    parameter int ROW_LANES = 4,
    parameter int STATE_ENTRIES = 64,
    localparam int FP_WIDTH = EXP_WIDTH + MANT_WIDTH + 1,
    localparam int SEGMENT_LOG2_WIDTH = $clog2($clog2(VLEN) + 1),
    localparam logic [SEGMENT_LOG2_WIDTH-1:0] FULL_ROW_SEGMENT_LOG2 = $clog2(VLEN)
) (
    input logic clk,
    input logic rst,
    input logic valid,
    input logic accumulate,
    input logic [1:0] state_phase,
    input logic [$clog2(VLEN)-1:0] lane_offset,
    input logic [$clog2(STATE_ENTRIES)-1:0] state_base,
    input logic [$clog2(ROW_LANES + 1)-1:0] active_rows,
    input logic [ROW_LANES-1:0][VLEN-1:0][FP_WIDTH-1:0] row_a,
    input logic [ROW_LANES-1:0][VLEN-1:0][FP_WIDTH-1:0] row_b,
    output logic [VLEN-1:0][FP_WIDTH-1:0] packed_o,
    output logic done
);
    logic [ROW_LANES-1:0][VLEN-1:0][FP_WIDTH-1:0] row_out;
    logic [ROW_LANES-1:0][FP_WIDTH-1:0] reduction_out;
    logic [ROW_LANES-1:0] row_valid, reduction_valid;
    logic [ROW_LANES-1:0][FP_WIDTH-1:0] state_m, state_l;
    logic [ROW_LANES-1:0] state_valid, state_first;
    logic state_read_valid;
    logic state_command_ready, state_done;
    logic [ROW_LANES-1:0][FP_WIDTH-1:0] next_m, next_l, next_factor;
    logic [ROW_LANES-1:0] next_valid;
    logic [VLEN-1:0] packed_mask;

    softmax_aux_row_slices #(
        .EXP_WIDTH(EXP_WIDTH), .MANT_WIDTH(MANT_WIDTH), .VLEN(VLEN),
        .ROW_LANES(ROW_LANES)
    ) rows (
        .clk(clk), .rst(rst), .element_valid(valid), .reduction_valid(valid),
        .active_rows(active_rows), .element_operation(SUB_V_ELEMENT),
        .reduction_operation(SUM_V_REDUCT),
        .segment_log2(FULL_ROW_SEGMENT_LOG2),
        .row_a(row_a), .row_b(row_b), .row_out(row_out),
        .reduction_out(reduction_out), .row_out_valid(row_valid),
        .reduction_out_valid(reduction_valid)
    );

    softmax_state_bank #(
        .FP_WIDTH(FP_WIDTH), .ROW_LANES(ROW_LANES), .ENTRIES(STATE_ENTRIES)
    ) state (
        .clk(clk), .rst(rst), .read_en(valid), .write_en(state_done),
        .read_group_base(state_base), .read_active_rows(active_rows),
        .write_group_base(state_base), .write_active_rows(active_rows),
        .m_in(next_m), .l_in(next_l),
        .valid_in(next_valid), .first_pending_in('0),
        .m_out(state_m), .l_out(state_l), .valid_out(state_valid),
        .first_pending_out(state_first), .read_valid(state_read_valid)
    );

    softmax_state_simd #(
        .EXP_WIDTH(EXP_WIDTH), .MANT_WIDTH(MANT_WIDTH),
        .ROW_LANES(ROW_LANES)
    ) state_math (
        .clk(clk), .rst(rst),
        .command_valid(state_read_valid), .command_ready(state_command_ready),
        .phase(state_phase), .active_rows(active_rows),
        .m_in(state_m), .l_in(state_l), .stat_in(reduction_out),
        .factor_in(state_m), .valid_in(state_valid),
        .m_out(next_m), .l_out(next_l), .factor_out(next_factor),
        .valid_out(next_valid), .done(state_done)
    );

    packed_pv_accumulator #(
        .EXP_WIDTH(EXP_WIDTH), .MANT_WIDTH(MANT_WIDTH), .VLEN(VLEN),
        .WRITE_LANES(WRITE_LANES)
    ) pv (
        .clk(clk), .rst(rst), .data_in_valid(valid), .accumulate(accumulate),
        .lane_offset(lane_offset), .old_packed_o(row_b[0]),
        .matrix_row(row_a[0]), .packed_o_out(packed_o),
        .packed_o_mask(packed_mask), .data_out_valid(done)
    );
endmodule
