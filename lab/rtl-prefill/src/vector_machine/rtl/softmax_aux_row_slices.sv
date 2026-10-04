`timescale 1ns / 1ps

`include "configuration.svh"
`include "operation.svh"

// Parameterized attention-only row slices. The production Vector datapath
// remains row zero; this module represents the extra R-1 SUB/EXP/MUL and
// reduction paths required by multi-row softmax.
module softmax_aux_row_slices #(
    parameter int EXP_WIDTH = 5,
    parameter int MANT_WIDTH = 6,
    parameter int VLEN = 16,
    parameter int ROW_LANES = 4,
    localparam int FP_WIDTH = EXP_WIDTH + MANT_WIDTH + 1,
    localparam int SEGMENT_LOG2_WIDTH = $clog2($clog2(VLEN) + 1)
) (
    input logic clk,
    input logic rst,
    input logic element_valid,
    input logic reduction_valid,
    input logic [$clog2(ROW_LANES + 1)-1:0] active_rows,
    input V_ELEMENT_OP element_operation,
    input V_REDUCT_OP reduction_operation,
    input logic [SEGMENT_LOG2_WIDTH-1:0] segment_log2,
    input logic [ROW_LANES-1:0][VLEN-1:0][FP_WIDTH-1:0] row_a,
    input logic [ROW_LANES-1:0][VLEN-1:0][FP_WIDTH-1:0] row_b,
    output logic [ROW_LANES-1:0][VLEN-1:0][FP_WIDTH-1:0] row_out,
    output logic [ROW_LANES-1:0][FP_WIDTH-1:0] reduction_out,
    output logic [ROW_LANES-1:0] row_out_valid,
    output logic [ROW_LANES-1:0] reduction_out_valid
);
    // Row zero is executed by the production Vector datapath.  This block is
    // strictly the incremental R-1 hardware, so paired synthesis does not
    // count the existing lane twice.
    assign row_out[0] = '0;
    assign reduction_out[0] = '0;
    assign row_out_valid[0] = 1'b0;
    assign reduction_out_valid[0] = 1'b0;

    for (genvar lane = 1; lane < ROW_LANES; lane++) begin : row_slice
        logic unused_a_ready, unused_b_ready;
        logic [VLEN:0][FP_WIDTH-1:0] reduction_input;
        logic [VLEN-1:0][FP_WIDTH-1:0] unused_vector_reduction;
        logic unused_vector_reduction_valid;

        assign reduction_input = {row_a[lane], {FP_WIDTH{1'b0}}};

        fp_elementwise_compute_unit #(
            .EXP_WIDTH(EXP_WIDTH),
            .MANT_WIDTH(MANT_WIDTH),
            .VLEN(VLEN)
        ) element_unit (
            .clk(clk),
            .rst(rst),
            .v_in_a(row_a[lane]),
            .v_in_a_valid(element_valid && lane < active_rows),
            .v_in_a_ready(unused_a_ready),
            .v_in_b(row_b[lane]),
            .v_in_b_valid(element_valid && lane < active_rows),
            .v_in_b_ready(unused_b_ready),
            .operation(element_operation),
            .v_out(row_out[lane]),
            .v_out_valid(row_out_valid[lane]),
            .v_out_ready(1'b1)
        );

        fp_reduction_compute_unit #(
            .EXP_WIDTH(EXP_WIDTH),
            .MANT_WIDTH(MANT_WIDTH),
            .VLEN(VLEN)
        ) reduction_unit (
            .clk(clk),
            .rst(rst),
            .v_in(reduction_input),
            .v_in_valid(reduction_valid && lane < active_rows),
            .v_in_ready(),
            .operation(reduction_operation),
            .overwrite(1'b1),
            .segment_log2(segment_log2),
            .segment_index('0),
            .s_out(reduction_out[lane]),
            .s_out_valid(reduction_out_valid[lane]),
            .v_out(unused_vector_reduction),
            .v_out_valid(unused_vector_reduction_valid)
        );
    end
endmodule
