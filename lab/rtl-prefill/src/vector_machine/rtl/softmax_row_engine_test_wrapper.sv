`timescale 1ns/1ps

`include "configuration.svh"
`include "operation.svh"

// Test-only integration wrapper. It supplies the production row-zero element
// and reduction datapaths around softmax_row_engine, so cocotb observes the
// same ready/done timing as VectorMachine rather than emulating valid pulses.
module softmax_row_engine_test_wrapper import configuration_pkg::*; #(
    parameter int EXP_WIDTH = 5,
    parameter int MANT_WIDTH = 6,
    parameter int VLEN = 8,
    parameter int ROW_LANES = 4,
    parameter int STATE_ENTRIES = 32,
    parameter int ADDR_WIDTH = 32,
    localparam int FP_WIDTH = EXP_WIDTH + MANT_WIDTH + 1,
    localparam int ACTIVE_WIDTH = $clog2(ROW_LANES + 1)
) (
    input logic clk,
    input logic rst,
    input logic command_valid,
    output logic command_ready,
    input V_ELEMENT_OP element_operation,
    input V_REDUCT_OP reduction_operation,
    input logic state_operation,
    input logic stats_operand,
    input logic [1:0] state_phase,
    input logic [ACTIVE_WIDTH-1:0] active_rows,
    input logic [ADDR_WIDTH-1:0] vector_base_addr,
    input logic [ADDR_WIDTH-1:0] state_base_addr,
    input logic [FP_WIDTH-1:0] scalar_in,
    input logic scalar_in_valid,
    input logic group_read_valid,
    input logic [ROW_LANES-1:0][VLEN-1:0][FP_WIDTH-1:0]
        group_read_data,
    output logic group_write_req,
    input logic group_write_ready,
    output logic [ADDR_WIDTH-1:0] group_write_addr,
    output logic [ACTIVE_WIDTH-1:0] group_write_active_rows,
    output logic [ROW_LANES-1:0][VLEN-1:0][FP_WIDTH-1:0]
        group_write_data,
    output logic [ROW_LANES-1:0][VLEN-1:0] group_write_mask,
    output logic busy,
    output logic done,
    output logic reduction_done,
    output logic row0_element_launch,
    output logic row0_reduction_launch,
    output logic state_reference_mismatch
);
    V_ELEMENT_OP row0_element_operation;
    logic [VLEN-1:0][FP_WIDTH-1:0] row0_element_a, row0_element_b,
        row0_element_out;
    logic row0_element_out_valid;
    V_REDUCT_OP row0_reduction_operation;
    logic [VLEN-1:0][FP_WIDTH-1:0] row0_reduction_in;
    logic [VLEN:0][FP_WIDTH-1:0] row0_reduction_input;
    logic [FP_WIDTH-1:0] row0_reduction_out;
    logic row0_reduction_out_valid;
    logic [VLEN-1:0][FP_WIDTH-1:0] unused_reduction_vector;
    logic unused_reduction_vector_valid;

    fp_elementwise_compute_unit #(
        .EXP_WIDTH(EXP_WIDTH), .MANT_WIDTH(MANT_WIDTH), .VLEN(VLEN)
    ) row0_element (
        .clk(clk), .rst(rst), .v_in_a(row0_element_a),
        .v_in_a_valid(row0_element_launch), .v_in_a_ready(),
        .v_in_b(row0_element_b), .v_in_b_valid(row0_element_launch),
        .v_in_b_ready(), .operation(row0_element_operation),
        .v_out(row0_element_out), .v_out_valid(row0_element_out_valid),
        .v_out_ready(1'b1)
    );

    assign row0_reduction_input = {row0_reduction_in, {FP_WIDTH{1'b0}}};
    fp_reduction_compute_unit #(
        .EXP_WIDTH(EXP_WIDTH), .MANT_WIDTH(MANT_WIDTH), .VLEN(VLEN)
    ) row0_reduction (
        .clk(clk), .rst(rst), .v_in(row0_reduction_input),
        .v_in_valid(row0_reduction_launch), .v_in_ready(),
        .operation(row0_reduction_operation), .overwrite(1'b1),
        .segment_log2($clog2(VLEN)), .segment_index('0),
        .s_out(row0_reduction_out),
        .s_out_valid(row0_reduction_out_valid),
        .v_out(unused_reduction_vector),
        .v_out_valid(unused_reduction_vector_valid)
    );

    softmax_row_engine #(
        .EXP_WIDTH(EXP_WIDTH), .MANT_WIDTH(MANT_WIDTH), .VLEN(VLEN),
        .ROW_LANES(ROW_LANES), .STATE_ENTRIES(STATE_ENTRIES),
        .ADDR_WIDTH(ADDR_WIDTH)
    ) engine (
        .clk(clk), .rst(rst), .command_valid(command_valid),
        .command_ready(command_ready), .element_operation(element_operation),
        .reduction_operation(reduction_operation),
        .state_operation(state_operation), .stats_operand(stats_operand),
        .state_phase(state_phase), .active_rows(active_rows),
        .vector_base_addr(vector_base_addr), .state_base_addr(state_base_addr),
        .scalar_in(scalar_in), .scalar_in_valid(scalar_in_valid),
        .preview_valid(1'b0), .preview_ready(),
        .preview_element_operation(STALL_V_ELEMENT),
        .preview_reduction_operation(STALL_V_REDUCT),
        .preview_state_operation(1'b0), .preview_stats_operand(1'b0),
        .preview_state_phase('0), .preview_active_rows('0),
        .preview_vector_base_addr('0), .preview_state_base_addr('0),
        .group_read_valid(group_read_valid), .group_read_data(group_read_data),
        .group_write_req(group_write_req),
        .group_write_ready(group_write_ready),
        .group_write_addr(group_write_addr),
        .group_write_active_rows(group_write_active_rows),
        .group_write_data(group_write_data), .group_write_mask(group_write_mask),
        .row0_element_launch(row0_element_launch),
        .row0_element_operation(row0_element_operation),
        .row0_element_a(row0_element_a), .row0_element_b(row0_element_b),
        .row0_element_out(row0_element_out),
        .row0_element_out_valid(row0_element_out_valid),
        .row0_reduction_launch(row0_reduction_launch),
        .row0_reduction_operation(row0_reduction_operation),
        .row0_reduction_in(row0_reduction_in),
        .row0_reduction_out(row0_reduction_out),
        .row0_reduction_out_valid(row0_reduction_out_valid),
        .busy(busy), .done(done), .reduction_done(reduction_done)
    );

    // Test-only serial oracle. Each active row consumes the exact state-bank
    // payload accepted by the production R-way engine, but executes through a
    // one-lane instance. This proves that spatial row replication preserves
    // the existing per-row floating-point operation and rounding order.
    logic [ROW_LANES-1:0] reference_ready, reference_done;
    logic [ROW_LANES-1:0][FP_WIDTH-1:0] reference_m,
        reference_l, reference_factor;
    logic [ROW_LANES-1:0] reference_valid;
    logic [ROW_LANES-1:0] reference_active_q;

    for (genvar row = 0; row < ROW_LANES; row++) begin : serial_state_reference
        softmax_state_simd #(
            .EXP_WIDTH(EXP_WIDTH), .MANT_WIDTH(MANT_WIDTH),
            .ROW_LANES(1), .CONTEXT_DEPTH(64)
        ) reference (
            .clk(clk), .rst(rst),
            .command_valid(engine.state_input_pop && row < engine.input_active),
            .command_ready(reference_ready[row]),
            .phase(engine.input_phase), .active_rows(1'b1),
            .m_in(engine.input_m[row]), .l_in(engine.input_l[row]),
            .stat_in(engine.input_stat[row]),
            .factor_in(engine.input_factor[row]),
            .valid_in(engine.input_valid[row]),
            .m_out(reference_m[row]), .l_out(reference_l[row]),
            .factor_out(reference_factor[row]),
            .valid_out(reference_valid[row]), .done(reference_done[row])
        );
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            state_reference_mismatch <= 1'b0;
            reference_active_q <= '0;
        end else begin
            if (engine.state_input_pop) begin
                for (int row = 0; row < ROW_LANES; row++) begin
                    reference_active_q[row] <= row < engine.input_active;
                    if (row < engine.input_active && !reference_ready[row])
                        state_reference_mismatch <= 1'b1;
                end
            end
            if (engine.state_done) begin
                for (int row = 0; row < ROW_LANES; row++) begin
                    if (reference_active_q[row] &&
                        (!reference_done[row] ||
                         reference_m[row] !== engine.simd_m_out[row] ||
                         reference_l[row] !== engine.simd_l_out[row] ||
                         reference_factor[row] !== engine.simd_factor_out[row] ||
                         reference_valid[row] !== engine.simd_valid_out[row]))
                        state_reference_mismatch <= 1'b1;
                end
            end
        end
    end
endmodule
