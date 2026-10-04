`timescale 1ns / 1ps

`include "configuration.svh"
`include "operation.svh"

// Synthesis-only leaf boundary used to calibrate the incremental compact-stat
// datapath without paying for an entire production VectorMachine.
module compact_stats_simd_area_wrapper
    import configuration_pkg::*;
    import instruction_pkg::*;
    #(
        parameter int COMPACT_STATS_LANES = VLEN
    )
(
    input  logic clk,
    input  logic rst,
    input  logic [3:0] operation,
    input  logic data_in_valid,
    input  logic [6:0] active_lanes,
    input  logic [VLEN-1:0][V_FP_EXP_WIDTH + V_FP_MANT_WIDTH:0] data_in,
    input  logic [V_FP_EXP_WIDTH + V_FP_MANT_WIDTH:0] scalar_in,
    output logic [VLEN-1:0][V_FP_EXP_WIDTH + V_FP_MANT_WIDTH:0] data_out,
    output logic data_out_valid
);
    compact_stats_simd #(
        .EXP_WIDTH(V_FP_EXP_WIDTH),
        .MANT_WIDTH(V_FP_MANT_WIDTH),
        .VLEN(VLEN),
        .COMPACT_STATS_LANES(COMPACT_STATS_LANES)
    ) compact_stats (
        .clk(clk),
        .rst(rst),
        .operation(V_ELEMENT_OP'(operation)),
        .data_in_valid(data_in_valid),
        .active_lanes(active_lanes[$clog2(COMPACT_STATS_LANES + 1)-1:0]),
        .data_in(data_in),
        .scalar_in(scalar_in),
        .data_out(data_out),
        .data_out_valid(data_out_valid)
    );
endmodule
