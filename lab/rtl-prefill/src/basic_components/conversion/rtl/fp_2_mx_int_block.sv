`timescale 1ns / 1ps

/*
Module      : fp_2_mx_int_block
Timing      : Sequential Logic, Takes 2 cycles to convert a block
Description : Convert a block of IEEE FP numbers to MXINT format
The mxint format will be composed with block of signed mantissas and a shared scale (max_exp)
Note: MXINT_WIDTH includes the sign bit (e.g., 7-bit MXINT = 1 sign + 6 mantissa bits)
*/

module fp_2_mx_int_block #(
    parameter BLOCK_DIM = 8,
    parameter FP_MANT_WIDTH = 3,
    parameter FP_EXP_WIDTH = 4,
    parameter MXINT_WIDTH = 8,  // Total width including sign bit
    parameter MXINT_SCALE_WIDTH = FP_EXP_WIDTH
)(
    input  logic clk,
    input  logic rst,
    input  logic [BLOCK_DIM-1:0][FP_MANT_WIDTH + FP_EXP_WIDTH : 0] data_in,
    input  logic data_in_valid,
    output logic [BLOCK_DIM-1:0][MXINT_WIDTH - 1 : 0] element_data_out,
    output logic [MXINT_SCALE_WIDTH-1:0] scale_data_out,
    output logic mx_int_data_out_valid
);
    localparam SIGNED_MANT_WIDTH = FP_MANT_WIDTH + 2;  // Output from fp_ieee_partition

    // Step 1: Partition all FP numbers into signed exp and mant
    logic signed [FP_EXP_WIDTH:0] signed_exp [BLOCK_DIM-1:0];
    logic signed [SIGNED_MANT_WIDTH-1:0] signed_mant [BLOCK_DIM-1:0];

    for (genvar i = 0; i < BLOCK_DIM; i++) begin : gen_partition
        fp_ieee_partition #(
            .EXP_WIDTH(FP_EXP_WIDTH),
            .MANT_WIDTH(FP_MANT_WIDTH)
        ) partition_inst (
            .data_in        (data_in[i]),
            .signed_exp     (signed_exp[i]),
            .signed_mant    (signed_mant[i])
        );
    end

    // Step 2: Find max exponent
    logic signed [FP_EXP_WIDTH:0] signed_exp_max;

    // Simple combinational max finder (tree structure)
    always_comb begin
        signed_exp_max = signed_exp[0];
        for (int i = 1; i < BLOCK_DIM; i++) begin
            if ($signed(signed_exp[i]) > $signed(signed_exp_max)) begin
                signed_exp_max = signed_exp[i];
            end
        end
    end

    // Detect if all mantissas are zero (for zero block handling)
    // When all inputs are zero, Python quantizer outputs exponent=0, so scale should be SCALE_BIAS
    logic all_mant_zero;
    always_comb begin
        all_mant_zero = 1'b1;
        for (int i = 0; i < BLOCK_DIM; i++) begin
            if (signed_mant[i] != '0) begin
                all_mant_zero = 1'b0;
            end
        end
    end

    // Pipeline stage 1: Register intermediate values
    // Use the larger of FP_EXP_WIDTH+1 and MXINT_SCALE_WIDTH for internal representation
    localparam INTERNAL_EXP_WIDTH = (FP_EXP_WIDTH + 1 > MXINT_SCALE_WIDTH) ? (FP_EXP_WIDTH + 1) : MXINT_SCALE_WIDTH;
    logic signed [INTERNAL_EXP_WIDTH-1:0] p1_signed_exp_max;
    logic signed [FP_EXP_WIDTH:0] p1_signed_exp [BLOCK_DIM-1:0];
    logic signed [SIGNED_MANT_WIDTH-1:0] p1_signed_mant [BLOCK_DIM-1:0];
    logic p1_data_valid;
    logic p1_all_mant_zero;

    always_ff @(posedge clk) begin
        if (rst) begin
            p1_signed_exp_max <= '0;
            p1_data_valid <= 1'b0;
            p1_all_mant_zero <= 1'b0;
            for (int i = 0; i < BLOCK_DIM; i++) begin
                p1_signed_exp[i] <= '0;
                p1_signed_mant[i] <= '0;
            end
        end else begin
            // Sign-extend signed_exp_max to INTERNAL_EXP_WIDTH
            p1_signed_exp_max <= INTERNAL_EXP_WIDTH'(signed'(signed_exp_max));
            p1_data_valid <= data_in_valid;
            p1_all_mant_zero <= all_mant_zero;
            for (int i = 0; i < BLOCK_DIM; i++) begin
                p1_signed_exp[i] <= signed_exp[i];
                p1_signed_mant[i] <= signed_mant[i];
            end
        end
    end

    // Step 3: Compute shift amounts and shift mantissas
    logic signed [FP_EXP_WIDTH:0] shift_amount [BLOCK_DIM-1:0];
    logic [MXINT_WIDTH-1:0] shifted_result [BLOCK_DIM-1:0];

    for (genvar i = 0; i < BLOCK_DIM; i++) begin : gen_shift
        assign shift_amount[i] = p1_signed_exp[i] - p1_signed_exp_max;

        bit_width_aware_signed_left_shift #(
            .IN_WIDTH(SIGNED_MANT_WIDTH),
            .OUT_WIDTH(MXINT_WIDTH),
            .SHIFT_WIDTH(FP_EXP_WIDTH + 1)
        ) shift_inst (
            .clk(clk),
            .rst(rst),
            .in_data(p1_signed_mant[i]),
            .shift_amt(shift_amount[i]),
            .out_data(shifted_result[i])
        );
    end

    // Pipeline stage 2: Register outputs
    // MXINT scale uses biased format (like IEEE FP exponent)
    // Scale bias = 2^(MXINT_SCALE_WIDTH-1) - 1 = 127 for 8-bit scale
    localparam signed [INTERNAL_EXP_WIDTH-1:0] SCALE_BIAS = 2**(MXINT_SCALE_WIDTH - 1) - 1;

    logic [MXINT_SCALE_WIDTH-1:0] p2_scale;
    logic p2_data_valid;

    always_ff @(posedge clk) begin
        if (rst) begin
            p2_scale <= '0;
            p2_data_valid <= 1'b0;
            for (int i = 0; i < BLOCK_DIM; i++) begin
                element_data_out[i] <= '0;
            end
        end else begin
            // When all mantissas are zero, output scale = SCALE_BIAS (exponent=0)
            // This matches Python quantizer behavior: per_block_max=1 for zero blocks
            if (p1_all_mant_zero) begin
                p2_scale <= MXINT_SCALE_WIDTH'(SCALE_BIAS);
            end else begin
                // Add bias to convert signed exponent to biased scale format
                p2_scale <= MXINT_SCALE_WIDTH'(p1_signed_exp_max + SCALE_BIAS);
            end
            p2_data_valid <= p1_data_valid;
            for (int i = 0; i < BLOCK_DIM; i++) begin
                element_data_out[i] <= shifted_result[i];
            end
        end
    end

    assign scale_data_out = p2_scale;
    assign mx_int_data_out_valid = p2_data_valid;

endmodule
