`timescale 1ns / 1ps

`include "configuration.svh"
`include "operation.svh"

/*
Module      : Floating Point Reduction Tree
Timing      : Combinatorial Logic
Description : Binary Tree Reduction of Floating Point Numbers, supporting:
            1. SUM
            2. MAX
            We assume the Layer Dim is in power of 2.
Status      : Under Development
*/

module fp_vector_reduce_layer #(
    // Declared Input Width
    parameter OVERALL_INPUT_WIDTH = 16,

    parameter LAYER_DIM  = 2,
    parameter IN_MAN_WIDTH = 4,
    parameter IN_EXP_WIDTH  = 3, 
    
    // In the first version vector machine, we assume all the extension related bits are zero.
    parameter EXT_MANT_WIDTH = 0,
    parameter EXT_EXP_WIDTH = 0,   

    localparam OUT_DIM  = (LAYER_DIM + 1) / 2,
    localparam INPUT_DATA_WIDTH = IN_MAN_WIDTH + IN_EXP_WIDTH + 1,
    localparam OUTPUT_DATA_WIDTH = IN_MAN_WIDTH + EXT_MANT_WIDTH + IN_EXP_WIDTH + EXT_EXP_WIDTH + 1
) (
    input   logic clk,
    input   logic rst,
    input   V_REDUCT_OP operation, // 0: SUM, 1: MAX
    input   logic [OVERALL_INPUT_WIDTH -1 : 0] data_in,
    input   logic data_in_valid,
    output  logic data_in_ready,
    output  logic [OVERALL_INPUT_WIDTH -1 : 0] data_out,
    output  logic data_out_valid,
    input   logic data_out_ready
);

    // Ready signal always high (no backpressure)
    assign data_in_ready = 1'b1;

    logic [OUT_DIM * OUTPUT_DATA_WIDTH -1 : 0] layer_add_out, layer_max_out;
    logic [OUT_DIM * OUTPUT_DATA_WIDTH -1 : 0] layer_sum_result, layer_max_result;
    logic [INPUT_DATA_WIDTH-1:0] odd_carry;
    logic [OUTPUT_DATA_WIDTH-1:0] widened_odd_carry;

    logic [LAYER_DIM / 2 - 1: 0] adder_data_in_valid_array;
    logic [LAYER_DIM / 2 - 1: 0] adder_data_out_valid_array;
    logic [LAYER_DIM / 2 - 1: 0] max_data_in_valid_array;
    logic [LAYER_DIM / 2 - 1: 0] max_data_out_valid_array;

    logic sum_data_in_valid;
    logic sum_data_out_valid;
    logic max_data_in_valid;
    logic max_data_out_valid;

    // Each layer contains floor(LAYER_DIM/2) arithmetic units. For an odd
    // input count, retain the unpaired value until the paired operations
    // complete and append it to the next level. The old implementation sized
    // OUT_DIM with ceil() but never drove this final entry, dropping one lane
    // from VLEN+1 reductions.
    always_ff @(posedge clk) begin
        if (rst) begin
            odd_carry <= '0;
        end else if (data_in_valid && (LAYER_DIM % 2 != 0)) begin
            odd_carry <= data_in[(LAYER_DIM-1)*INPUT_DATA_WIDTH +: INPUT_DATA_WIDTH];
        end
    end

    assign widened_odd_carry = {
        odd_carry[INPUT_DATA_WIDTH-1],
        {EXT_EXP_WIDTH{1'b0}},
        odd_carry[IN_MAN_WIDTH +: IN_EXP_WIDTH],
        odd_carry[IN_MAN_WIDTH-1:0],
        {EXT_MANT_WIDTH{1'b0}}
    };

    always_comb begin
        layer_sum_result = layer_add_out;
        layer_max_result = layer_max_out;
        if (LAYER_DIM % 2 != 0) begin
            layer_sum_result[(OUT_DIM-1)*OUTPUT_DATA_WIDTH +: OUTPUT_DATA_WIDTH] = widened_odd_carry;
            layer_max_result[(OUT_DIM-1)*OUTPUT_DATA_WIDTH +: OUTPUT_DATA_WIDTH] = widened_odd_carry;
        end
    end

    always_comb begin
        // Default values
        sum_data_in_valid = 1'b0;
        max_data_in_valid = 1'b0;
        data_out_valid = 1'b0;
        data_out = {OVERALL_INPUT_WIDTH{1'b0}};

        case (operation)
            SUM_V_REDUCT: begin
                sum_data_in_valid   = data_in_valid;
                data_out_valid      = sum_data_out_valid;
                data_out = {{OVERALL_INPUT_WIDTH - OUT_DIM * OUTPUT_DATA_WIDTH{1'b0}} ,layer_sum_result};
            end

            MAX_V_REDUCT: begin
                max_data_in_valid   = data_in_valid;
                data_out_valid      = max_data_out_valid;
                data_out = {{OVERALL_INPUT_WIDTH - OUT_DIM * OUTPUT_DATA_WIDTH{1'b0}} ,layer_max_result};
            end

            default: begin
                // Already set by defaults
            end
        endcase
    end

    // Broadcast valid to all adders/max units
    assign adder_data_in_valid_array = {(LAYER_DIM/2){sum_data_in_valid}};
    assign max_data_in_valid_array = {(LAYER_DIM/2){max_data_in_valid}};



    generate;
        for (genvar i = 0; i < LAYER_DIM / 2; i++) begin : adder_pair
            fp_cp_adder #(
                .EXP_WIDTH(IN_EXP_WIDTH),
                .MANT_WIDTH(IN_MAN_WIDTH)
            )   layer_fp_add (
                .clk(clk),
                .rst(rst),
                .data_in_valid      (adder_data_in_valid_array[i]),
                .data_a             (data_in[2*i*INPUT_DATA_WIDTH +: INPUT_DATA_WIDTH]),
                .data_b             (data_in[(2*i + 1)*INPUT_DATA_WIDTH +: INPUT_DATA_WIDTH]),
                .data_out           (layer_add_out[i * OUTPUT_DATA_WIDTH +: OUTPUT_DATA_WIDTH]),
                .data_out_valid     (adder_data_out_valid_array[i])
            );

            fp_max #(
                .EXP_WIDTH(IN_EXP_WIDTH),
                .MANT_WIDTH(IN_MAN_WIDTH)
            )   layer_fp_max (
                .clk(clk),
                .rst(rst),
                .data_in_valid      (max_data_in_valid_array[i]),
                .data_a             (data_in[2*i*INPUT_DATA_WIDTH +: INPUT_DATA_WIDTH]),
                .data_b             (data_in[(2*i + 1)*INPUT_DATA_WIDTH +: INPUT_DATA_WIDTH]),
                .data_out           (layer_max_out[i * OUTPUT_DATA_WIDTH +: OUTPUT_DATA_WIDTH]),
                .data_out_valid     (max_data_out_valid_array[i])
            );

        end
    endgenerate

    // Combine all valid signals
    assign sum_data_out_valid = &adder_data_out_valid_array;
    assign max_data_out_valid = &max_data_out_valid_array;

endmodule
