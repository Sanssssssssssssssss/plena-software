`timescale 1ns / 1ps

`include "configuration.svh"
`include "operation.svh"

// Tiered datapath for the compact roots emitted by V_RED_*_SEGS.
// Only the first COMPACT_STATS_LANES lanes are physically instantiated; all other
// output lanes are driven to zero so a full Vector SRAM word write preserves
// the compact-stat scratch invariant.
module compact_stats_simd import instruction_pkg::*; #(
    parameter int EXP_WIDTH = 5,
    parameter int MANT_WIDTH = 10,
    parameter int VLEN = 16,
    parameter int COMPACT_STATS_LANES = 16,
    localparam int FP_WIDTH = EXP_WIDTH + MANT_WIDTH + 1
) (
    input  logic clk,
    input  logic rst,
    input  V_ELEMENT_OP operation,
    input  logic data_in_valid,
    input  logic [$clog2(COMPACT_STATS_LANES + 1)-1:0] active_lanes,
    input  logic [VLEN-1:0][FP_WIDTH-1:0] data_in,
    input  logic [FP_WIDTH-1:0] scalar_in,
    output logic [VLEN-1:0][FP_WIDTH-1:0] data_out,
    output logic data_out_valid
);

    logic [COMPACT_STATS_LANES-1:0][FP_WIDTH-1:0] add_out, mul_out;
    logic [COMPACT_STATS_LANES-1:0][FP_WIDTH-1:0] sqrt_out, rsqrt_out;
    logic [COMPACT_STATS_LANES-1:0] add_valid, mul_valid;
    logic [COMPACT_STATS_LANES-1:0] sqrt_valid, rsqrt_valid;

    for (genvar lane = 0; lane < COMPACT_STATS_LANES; lane++) begin : compact_lane
        logic lane_valid;
        assign lane_valid = data_in_valid && lane < active_lanes;

        fp_cp_adder #(
            .EXP_WIDTH(EXP_WIDTH),
            .MANT_WIDTH(MANT_WIDTH)
        ) add_unit (
            .clk(clk),
            .rst(rst),
            .data_in_valid(lane_valid && operation == COMPACT_STAT_ADD_V_ELEMENT),
            .data_a(data_in[lane]),
            .data_b(scalar_in),
            .data_out(add_out[lane]),
            .data_out_valid(add_valid[lane])
        );

        fp_cp_mult #(
            .EXP_WIDTH(EXP_WIDTH),
            .MANT_WIDTH(MANT_WIDTH)
        ) mul_unit (
            .clk(clk),
            .rst(rst),
            .data_in_valid(lane_valid && operation == COMPACT_STAT_MUL_V_ELEMENT),
            .data_a(data_in[lane]),
            .data_b(scalar_in),
            .data_out(mul_out[lane]),
            .data_out_valid(mul_valid[lane])
        );

        fp_fix_sqrt #(
            .EXP_WIDTH(EXP_WIDTH),
            .MANT_WIDTH(MANT_WIDTH)
        ) sqrt_unit (
            .clk(clk),
            .rst(rst),
            .data_in_valid(lane_valid && operation == COMPACT_STAT_RSQRT_V_ELEMENT),
            .data_in(data_in[lane]),
            .data_out(sqrt_out[lane]),
            .data_out_valid(sqrt_valid[lane])
        );

        fp_fix_reciprocal #(
            .EXP_WIDTH(EXP_WIDTH),
            .MANT_WIDTH(MANT_WIDTH)
        ) reciprocal_unit (
            .clk(clk),
            .rst(rst),
            .data_in_valid(sqrt_valid[lane]),
            .data_in(sqrt_out[lane]),
            .data_out(rsqrt_out[lane]),
            .data_out_valid(rsqrt_valid[lane])
        );
    end

    always_comb begin
        data_out = '0;
        data_out_valid = add_valid[0] || mul_valid[0] || rsqrt_valid[0];
        for (int lane = 0; lane < COMPACT_STATS_LANES; lane++) begin
            if (add_valid[lane]) begin
                data_out[lane] = add_out[lane];
            end else if (mul_valid[lane]) begin
                data_out[lane] = mul_out[lane];
            end else if (rsqrt_valid[lane]) begin
                data_out[lane] = rsqrt_out[lane];
            end
        end
    end

`ifdef SIMULATION
    always_ff @(posedge clk) begin
        if (!rst && data_in_valid &&
            (active_lanes == 0 || active_lanes > COMPACT_STATS_LANES)) begin
            $fatal(1, "compact-stat active_lanes out of range: %0d", active_lanes);
        end
        if (!rst && ((add_valid[0] && mul_valid[0]) ||
                     (add_valid[0] && rsqrt_valid[0]) ||
                     (mul_valid[0] && rsqrt_valid[0]))) begin
            $fatal(1, "compact-stat mixed-latency write-port collision");
        end
    end
`endif

endmodule
