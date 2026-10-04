`timescale 1ns / 1ps

`include "configuration.svh"
`include "operation.svh"

/*
Module      : Vector Reduction Computation Module
Timing      : Sequential, Takes log2(VLEN) + 1 cycles
Description : This module includes vector reduction computations
            : 1. SUM, 2. MAX
            : As we are targeting for high dim vector reduction, which need to be decomposed into a series of instructions, we maximally utilize the instruction and read port width of the sram by considering sources together.
            ：Note that, for reduction units, there's no need to support per clk level pipelining, as during the inference process, reduction is requried per MLEN vector.
Status      : Passed Simple Tests
*/


module fp_reduction_compute_unit #(
    // FP Data Format
    parameter EXP_WIDTH     = 4,
    parameter MANT_WIDTH    = 3,

    // Dimensions
    parameter  VLEN         = 8,
    localparam VEC_DIM      = VLEN + 1, // 2 FP vector read + 1 FP from scalar machine for loop
    localparam LEVELS       = $clog2(VEC_DIM),

    // Precision Control, for the vector core, currently focus solely on fixed data type width, left for future work.
    parameter ACC_EXT_EXP_WIDTH   = 0,
    parameter ACC_EXT_MANT_WIDTH  = 0,

    localparam OVERALL_MANT_EXT_BITS = LEVELS * ACC_EXT_MANT_WIDTH, 
    localparam OUT_MAN_WIDTH = OVERALL_MANT_EXT_BITS + MANT_WIDTH,    

    localparam OVERALL_EXP_EXT_BITS = LEVELS * ACC_EXT_EXP_WIDTH,
    localparam OUT_EXP_WIDTH  = OVERALL_EXP_EXT_BITS + EXP_WIDTH,

    localparam IN_WIDTH       = MANT_WIDTH + EXP_WIDTH + 1,
    localparam OUT_WIDTH      = OUT_MAN_WIDTH + OUT_EXP_WIDTH + 1,
    // Encodes log2(segment_width) in the inclusive range
    // [0, log2(VLEN)].
    localparam SEGMENT_LOG2_WIDTH = $clog2($clog2(VLEN) + 1)

) (
    input   logic clk,
    input   logic rst,

    // Input vector
    input   logic [VEC_DIM - 1 : 0] [IN_WIDTH - 1 : 0] v_in,
    input   logic v_in_valid,
    output  logic v_in_ready,

    // Control
    input   V_REDUCT_OP operation,
    input   logic overwrite,
    input   logic [SEGMENT_LOG2_WIDTH-1:0] segment_log2,
    input   logic [$clog2(VLEN)-1:0] segment_index,

    // Scalar output used by the legacy full/single-segment reductions.
    output  logic [OUT_WIDTH - 1 : 0] s_out,
    output  logic s_out_valid,

    // Compact vector output used by RTL-v3 multi-segment reductions.  If the
    // segment width is 2^segment_log2, lanes [0, VLEN/segment_width) contain
    // one tree root per segment and all remaining lanes are zero.
    output  logic [VLEN - 1 : 0] [OUT_WIDTH - 1 : 0] v_out,
    output  logic v_out_valid
);

// Ready signal always high (no backpressure)
assign v_in_ready = 1'b1;

logic [VEC_DIM - 1 : 0] [IN_WIDTH - 1 : 0] prepared_v_in;
logic [VEC_DIM - 1 : 0] [IN_WIDTH - 1 : 0] p1_v_in;
logic p1_v_in_valid;
logic recorded_segment_mode;
logic recorded_multi_segment_mode;
logic [$clog2(VLEN):0] recorded_target_level;
V_REDUCT_OP tree_operation;

// Native compiler constant-prefix slot 2 is initialized from -60000.0.  Encode
// the same value directly in the configured IEEE-like FP format so overwrite
// MAX is bit-equivalent to the former explicit S_LD_FP(slot 2) path without
// retaining a Scalar SRAM dependency. Narrow formats saturate to their largest
// finite magnitude, matching the compiler/emulator quantizer.
function automatic logic [IN_WIDTH-1:0] encode_softmax_negative_identity();
    integer exponent_bias;
    integer exponent_field;
    integer mantissa_field;
    integer mantissa_scale;
    begin
        exponent_bias = (1 << (EXP_WIDTH - 1)) - 1;
        exponent_field = exponent_bias + 15;
        mantissa_scale = 1 << MANT_WIDTH;
        // 60000 = 2^15 * (1 + 27232/32768).
        mantissa_field =
            (27232 * mantissa_scale + 16384) / 32768;
        if (mantissa_field >= mantissa_scale) begin
            exponent_field = exponent_field + 1;
            mantissa_field = 0;
        end
        if (exponent_field >= ((1 << EXP_WIDTH) - 1)) begin
            exponent_field = (1 << EXP_WIDTH) - 2;
            mantissa_field = mantissa_scale - 1;
        end
        encode_softmax_negative_identity = {
            1'b1,
            exponent_field[EXP_WIDTH-1:0],
            mantissa_field[MANT_WIDTH-1:0]
        };
    end
endfunction

localparam logic [IN_WIDTH-1:0] SOFTMAX_NEGATIVE_IDENTITY =
    encode_softmax_negative_identity();

always_comb begin
    int unsigned segment_width;
    int unsigned segment_base;
    logic [IN_WIDTH-1:0] neutral_value;

    segment_width = 1 << segment_log2;
    segment_base = segment_index << segment_log2;
    // Values beyond the selected segment never enter its tap.
    neutral_value = (operation == MAX_V_REDUCT ||
                     operation == MAX_SEG_V_REDUCT ||
                     operation == MAX_SEGS_V_REDUCT)
                  ? SOFTMAX_NEGATIVE_IDENTITY
                  : '0;
    prepared_v_in = v_in;
    if (operation == SUM_SEG_V_REDUCT || operation == MAX_SEG_V_REDUCT) begin
        prepared_v_in = {VEC_DIM{neutral_value}};
        prepared_v_in[0] = overwrite ? neutral_value : v_in[0];
        for (int lane = 0; lane < VLEN; lane++) begin
            if (lane < segment_width && segment_base + lane < VLEN) begin
                prepared_v_in[lane + 1] = v_in[segment_base + lane + 1];
            end
        end
    end else if (operation == SUM_SEGS_V_REDUCT ||
                 operation == MAX_SEGS_V_REDUCT) begin
        // The legacy tree has an extra scalar-accumulator leaf at index zero.
        // Multi-segment reduction does not use that accumulator, so shift the
        // VLEN vector lanes down by one and leave the final leaf neutral.  This
        // aligns every power-of-two segment with a subtree boundary.
        prepared_v_in = {VEC_DIM{neutral_value}};
        for (int lane = 0; lane < VLEN; lane++) begin
            prepared_v_in[lane] = v_in[lane + 1];
        end
    end else if (overwrite) begin
        // Full reductions normally accumulate the scalar destination in leaf
        // zero. Overwrite mode seeds that leaf with the operation identity,
        // avoiding the Scalar FP register read and its RAW dependency.
        prepared_v_in[0] = neutral_value;
    end
end

always_ff @(posedge clk) begin
    if (rst) begin
        recorded_segment_mode <= 1'b0;
        recorded_multi_segment_mode <= 1'b0;
        recorded_target_level <= LEVELS;
        tree_operation <= STALL_V_REDUCT;
    end else if (v_in_valid) begin
        recorded_segment_mode <= (operation == SUM_SEG_V_REDUCT ||
                                  operation == MAX_SEG_V_REDUCT);
        recorded_multi_segment_mode <= (operation == SUM_SEGS_V_REDUCT ||
                                        operation == MAX_SEGS_V_REDUCT);
        // A power-of-two segment plus the scalar accumulator needs one more
        // reduction level. Full reductions retain the legacy VLEN+1 depth.
        recorded_target_level <= (operation == SUM_SEG_V_REDUCT ||
                                  operation == MAX_SEG_V_REDUCT)
                               ? segment_log2 + 1'b1 :
                                 (operation == SUM_SEGS_V_REDUCT ||
                                  operation == MAX_SEGS_V_REDUCT)
                               ? segment_log2 : LEVELS;
        tree_operation <= (operation == SUM_SEG_V_REDUCT) ? SUM_V_REDUCT :
                          (operation == MAX_SEG_V_REDUCT) ? MAX_V_REDUCT :
                          (operation == SUM_SEGS_V_REDUCT) ? SUM_V_REDUCT :
                          (operation == MAX_SEGS_V_REDUCT) ? MAX_V_REDUCT :
                                                           operation;
    end
end

    register_slice_wo_hs #(
        .DATA_WIDTH(IN_WIDTH * VEC_DIM)
    ) input_regstore_inst (
        .clk(clk),
        .rst(rst),
        .data_in        (prepared_v_in),
        .data_in_valid  (v_in_valid),
        .data_out       (p1_v_in),
        .data_out_valid (p1_v_in_valid)
    );

  generate
      logic [OUT_WIDTH*VEC_DIM-1:0] data_storage [LEVELS:0];  // TODO: Need to be optimized, memory inefficient
      logic [OUT_WIDTH*VEC_DIM-1:0] sum  [LEVELS-1:0];
      logic [VEC_DIM-1:0] valid;
      logic [VEC_DIM-1:0] compute_valid;

      // Generate adder for each layer
      for (genvar i = 0; i < LEVELS; i++) begin : level

        localparam LEVEL_IN_DIM = (VEC_DIM + ((1 << i) - 1)) >> i;     // Ceiling(VEC_DIM / 2^i)
        localparam LEVEL_IN_MAN_WIDTH   = MANT_WIDTH + i * ACC_EXT_MANT_WIDTH;
        localparam LEVEL_IN_EXP_WIDTH   = EXP_WIDTH + i * ACC_EXT_EXP_WIDTH;

        localparam LEVEL_OUT_DIM = (LEVEL_IN_DIM + 1) / 2;
        localparam LEVEL_OUT_MAN_WIDTH  = MANT_WIDTH + (i + 1) * ACC_EXT_MANT_WIDTH;
        localparam LEVEL_OUT_EXP_WIDTH  = EXP_WIDTH + (i + 1) * ACC_EXT_EXP_WIDTH;
        localparam LEVEL_OUT_WIDTH = LEVEL_OUT_MAN_WIDTH + LEVEL_OUT_EXP_WIDTH + 1;

        fp_vector_reduce_layer #(
            .OVERALL_INPUT_WIDTH    (OUT_WIDTH*VEC_DIM),
            .LAYER_DIM              (LEVEL_IN_DIM),
            .IN_MAN_WIDTH           (LEVEL_IN_MAN_WIDTH),
            .IN_EXP_WIDTH           (LEVEL_IN_EXP_WIDTH),
            .EXT_MANT_WIDTH         (ACC_EXT_MANT_WIDTH),
            .EXT_EXP_WIDTH          (ACC_EXT_EXP_WIDTH)
        ) vector_layer (
            .clk(clk),
            .rst(rst),
	            .operation      (tree_operation),
	            .data_in_valid  (valid[i] &&
	                                  (!(recorded_segment_mode || recorded_multi_segment_mode) ||
	                                    i < recorded_target_level)),
            .data_in        (data_storage[i]),
            .data_out       (sum[i]),
            .data_out_valid (compute_valid[i])
        );

        register_slice_wo_hs #(
            .DATA_WIDTH(LEVEL_OUT_DIM * LEVEL_OUT_WIDTH)
        ) register_slice (
            .clk           (clk),
            .rst           (rst),
            .data_in       (sum[i][LEVEL_OUT_DIM * LEVEL_OUT_WIDTH - 1 : 0]),
            .data_in_valid (compute_valid[i]),
            .data_out      (data_storage[i+1][LEVEL_OUT_DIM * LEVEL_OUT_WIDTH - 1 : 0]),
            .data_out_valid(valid[i+1])
        );
      end

      assign data_storage[0]= p1_v_in;
      assign valid[0] = p1_v_in_valid;

	      assign s_out = recorded_segment_mode
	                       ? data_storage[recorded_target_level][OUT_WIDTH-1:0]
	                       : data_storage[LEVELS][OUT_WIDTH-1:0];
	      assign s_out_valid = !recorded_multi_segment_mode && (recorded_segment_mode
	                             ? valid[recorded_target_level]
	                             : valid[LEVELS]);

          // ACC extension is disabled in the VectorMachine configuration, so
          // every intermediate root has the same packed FP width as the final
          // result.  Keeping the extraction here makes that structural fact
          // explicit and prevents a second reduction tree from being inferred.
          always_comb begin
              int unsigned result_count;
              v_out = '0;
              result_count = VLEN >> recorded_target_level;
              if (recorded_multi_segment_mode) begin
                  for (int lane = 0; lane < VLEN; lane++) begin
                      if (lane < result_count) begin
                          v_out[lane] = data_storage[recorded_target_level]
                                      [lane * OUT_WIDTH +: OUT_WIDTH];
                      end
                  end
              end
          end
          assign v_out_valid = recorded_multi_segment_mode &&
                               valid[recorded_target_level];

	  endgenerate
endmodule
