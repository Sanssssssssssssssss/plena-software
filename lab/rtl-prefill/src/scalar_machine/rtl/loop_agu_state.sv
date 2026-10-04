`timescale 1ns / 1ps

`include "configuration.svh"

// Affine address sidecar shared by the scalar GP read path and loop frontend.
// Architectural GP storage remains in the existing register file. This block
// only stores loop descriptors and offsets, so an ordinary GP write can reset
// an address stream without adding a second register-file write port.
module loop_agu_state import configuration_pkg::*; import instruction_pkg::*; #(
    parameter int DATA_WIDTH = INT_DATA_WIDTH,
    parameter int OPERAND_WIDTH = INT_OPERAND_WIDTH,
    parameter int IMMEDIATE_WIDTH = IMM_WIDTH,
    parameter int STREAM_COUNT = 6,
    parameter int LOOP_DEPTH = MAX_LOOP_DEPTH
) (
    input  logic clk,
    input  logic rst,

    input  logic config_valid,
    input  logic [OPERAND_WIDTH-1:0] config_reg,
    input  logic [IMMEDIATE_WIDTH-1:0] config_stride,
    input  logic frame_start,
    input  logic [OPERAND_WIDTH-1:0] frame_counter_reg,
    input  logic boundary_step,
    input  logic boundary_exit,

    input  logic gp_write_valid,
    input  logic [OPERAND_WIDTH-1:0] gp_write_addr,
    input  logic [OPERAND_WIDTH-1:0] gp_read_addr_1,
    input  logic [OPERAND_WIDTH-1:0] gp_read_addr_2,
    input  logic [DATA_WIDTH-1:0] gp_base_1,
    input  logic [DATA_WIDTH-1:0] gp_base_2,
    output logic [DATA_WIDTH-1:0] gp_resolved_1,
    output logic [DATA_WIDTH-1:0] gp_resolved_2
);

    localparam int GP_REG_COUNT = 1 << OPERAND_WIDTH;
    localparam int STREAM_COUNT_WIDTH = $clog2(STREAM_COUNT + 1);
    localparam int DEPTH_WIDTH = $clog2(LOOP_DEPTH + 1);

    logic [DATA_WIDTH-1:0] gp_affine_offset [GP_REG_COUNT-1:0];
    logic [OPERAND_WIDTH-1:0] pending_reg [STREAM_COUNT-1:0];
    logic signed [DATA_WIDTH-1:0] pending_stride [STREAM_COUNT-1:0];
    logic [STREAM_COUNT_WIDTH-1:0] pending_count;
    logic [OPERAND_WIDTH-1:0]
        frame_reg [LOOP_DEPTH-1:0][STREAM_COUNT-1:0];
    logic signed [DATA_WIDTH-1:0]
        frame_stride [LOOP_DEPTH-1:0][STREAM_COUNT-1:0];
    logic [STREAM_COUNT_WIDTH-1:0] frame_count [LOOP_DEPTH-1:0];
    logic [OPERAND_WIDTH-1:0] frame_counter [LOOP_DEPTH-1:0];
    logic [DEPTH_WIDTH-1:0] depth;

    function automatic logic signed [DATA_WIDTH-1:0] decode_stride(
        input logic [IMMEDIATE_WIDTH-1:0] encoded
    );
        logic signed [63:0] mantissa;
        logic signed [63:0] shifted;
        begin
            mantissa = $signed({{(64-17){encoded[16]}}, encoded[16:0]});
            shifted = mantissa <<< encoded[21:17];
            decode_stride = shifted[DATA_WIDTH-1:0];
        end
    endfunction

    assign gp_resolved_1 =
        gp_base_1 + gp_affine_offset[gp_read_addr_1];
    assign gp_resolved_2 =
        gp_base_2 + gp_affine_offset[gp_read_addr_2];

    always_ff @(posedge clk) begin
        if (rst) begin
            pending_count <= '0;
            depth <= '0;
            for (int i = 0; i < GP_REG_COUNT; i++) begin
                gp_affine_offset[i] <= '0;
            end
            for (int d = 0; d < LOOP_DEPTH; d++) begin
                frame_count[d] <= '0;
                frame_counter[d] <= '0;
                for (int s = 0; s < STREAM_COUNT; s++) begin
                    frame_reg[d][s] <= '0;
                    frame_stride[d][s] <= '0;
                end
            end
            for (int s = 0; s < STREAM_COUNT; s++) begin
                pending_reg[s] <= '0;
                pending_stride[s] <= '0;
            end
        end else begin
            if (config_valid) begin
                assert (config_reg != '0)
                    else $fatal(1, "gp0 cannot be bound to the loop AGU");
                assert (config_stride != '0)
                    else $fatal(1, "zero-stride AGU binding is invalid in AGU v1");
                if (config_stride != '0) begin
                    assert (pending_count < STREAM_COUNT)
                        else $fatal(1, "more than six AGU streams configured");
                    for (int s = 0; s < STREAM_COUNT; s++) begin
                        if (s < pending_count) begin
                            assert (pending_reg[s] != config_reg)
                                else $fatal(1, "duplicate pending AGU binding");
                        end
                    end
                    for (int d = 0; d < LOOP_DEPTH; d++) begin
                        if (d < depth) begin
                            for (int s = 0; s < STREAM_COUNT; s++) begin
                                if (s < frame_count[d]) begin
                                    assert (frame_reg[d][s] != config_reg)
                                        else $fatal(
                                            1,
                                            "nested AGU frames cannot bind the same GP"
                                        );
                                end
                            end
                        end
                    end
                    pending_reg[pending_count] <= config_reg;
                    pending_stride[pending_count] <= decode_stride(config_stride);
                    pending_count <= pending_count + 1'b1;
                end
            end

            if (frame_start) begin
                assert (depth < LOOP_DEPTH)
                    else $fatal(1, "AGU loop nesting exceeds MAX_LOOP_DEPTH");
                frame_count[depth] <= pending_count;
                frame_counter[depth] <= frame_counter_reg;
                for (int s = 0; s < STREAM_COUNT; s++) begin
                    frame_reg[depth][s] <= pending_reg[s];
                    frame_stride[depth][s] <= pending_stride[s];
                    if (s < pending_count) begin
                        assert (pending_reg[s] != frame_counter_reg)
                            else $fatal(
                                1,
                                "AGU loop counter cannot also be an address stream"
                            );
                    end
                end
                depth <= depth + 1'b1;
                pending_count <= '0;
            end

            if (boundary_step) begin
                assert (depth > 0)
                    else $fatal(
                        1,
                        "AGU boundary observed with empty descriptor stack"
                );
                for (int s = 0; s < STREAM_COUNT; s++) begin
                    if (s < frame_count[depth - 1'b1]) begin
                        gp_affine_offset[frame_reg[depth - 1'b1][s]]
                            <= gp_affine_offset[frame_reg[depth - 1'b1][s]]
                             + frame_stride[depth - 1'b1][s];
                    end
                end
                if (frame_counter[depth - 1'b1] != '0) begin
                    gp_affine_offset[frame_counter[depth - 1'b1]]
                        <= gp_affine_offset[frame_counter[depth - 1'b1]]
                         - 1'b1;
                end
                if (boundary_exit) begin
                    depth <= depth - 1'b1;
                end
            end

            // Preserve the original sidecar semantics: an architectural GP
            // write wins over an offset step targeting the same register.
            if (gp_write_valid) begin
                for (int d = 0; d < LOOP_DEPTH; d++) begin
                    if (d < depth) begin
                        for (int s = 0; s < STREAM_COUNT; s++) begin
                            if (s < frame_count[d]) begin
                                assert (gp_write_addr != frame_reg[d][s])
                                    else $fatal(
                                        1,
                                        "loop body writes an AGU-bound GP register"
                                    );
                            end
                        end
                    end
                end
                gp_affine_offset[gp_write_addr] <= '0;
            end
        end
    end

endmodule
