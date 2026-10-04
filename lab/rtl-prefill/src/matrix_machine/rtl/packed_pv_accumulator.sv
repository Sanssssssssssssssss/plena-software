`timescale 1ns / 1ps

// Masked Matrix-to-packed-O writeback helper. Matrix values occupy the low
// WRITE_LANES lanes and are placed at lane_offset. Accumulate mode uses the same
// configured fp_fix_adder primitive as VectorMachine V_ADD_VV.
module packed_pv_accumulator #(
    parameter int EXP_WIDTH = 5,
    parameter int MANT_WIDTH = 6,
    parameter int VLEN = 16,
    parameter int WRITE_LANES = 4,
    localparam int FP_WIDTH = EXP_WIDTH + MANT_WIDTH + 1
) (
    input logic clk,
    input logic rst,
    input logic data_in_valid,
    input logic accumulate,
    input logic [$clog2(VLEN)-1:0] lane_offset,
    input logic [VLEN-1:0][FP_WIDTH-1:0] old_packed_o,
    input logic [VLEN-1:0][FP_WIDTH-1:0] matrix_row,
    output logic [VLEN-1:0][FP_WIDTH-1:0] packed_o_out,
    output logic [VLEN-1:0] packed_o_mask,
    output logic data_out_valid
);
    localparam int OFFSET_WIDTH = (VLEN <= 1) ? 1 : $clog2(VLEN);
    localparam int CONTEXT_WIDTH = VLEN * FP_WIDTH + OFFSET_WIDTH;
    localparam int CONTEXT_DEPTH = 32;

    logic [WRITE_LANES-1:0][FP_WIDTH-1:0] add_out;
    logic [WRITE_LANES-1:0] add_valid;
    logic overwrite_valid;
    logic [VLEN-1:0][FP_WIDTH-1:0] overwrite_row;
    logic [OFFSET_WIDTH-1:0] overwrite_offset;
    logic [CONTEXT_WIDTH-1:0] context_in, context_out;
    logic context_valid, context_pop;
    logic [VLEN-1:0][FP_WIDTH-1:0] context_old_row;
    logic [OFFSET_WIDTH-1:0] context_offset;

    assign context_in = {old_packed_o, lane_offset};
    assign {context_old_row, context_offset} = context_out;
    assign context_pop = context_valid && add_valid[0];

    // The FP adder is pipelined and may accept a new row every cycle.  Keep
    // each row's old payload and lane offset until the matching result returns;
    // using the live inputs here silently corrupts back-to-back writebacks.
    fifo #(
        .DATA_WIDTH(CONTEXT_WIDTH),
        .DEPTH(CONTEXT_DEPTH)
    ) context_fifo (
        .clk(clk),
        .rst(rst),
        .data_in(context_in),
        .data_in_valid(data_in_valid && accumulate),
        .data_in_ready(),
        .data_out(context_out),
        .data_out_valid(context_valid),
        .data_out_ready(context_pop),
        .empty(),
        .full()
    );

    for (genvar lane = 0; lane < WRITE_LANES; lane++) begin : pv_lane
        fp_fix_adder #(
            .EXP_WIDTH(EXP_WIDTH),
            .MANT_WIDTH(MANT_WIDTH)
        ) add_unit (
            .clk(clk),
            .rst(rst),
            .data_in_valid(data_in_valid && accumulate),
            .data_a(old_packed_o[lane_offset + lane]),
            .data_b(matrix_row[lane]),
            .data_out(add_out[lane]),
            .data_out_valid(add_valid[lane])
        );
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            overwrite_valid <= 1'b0;
            overwrite_row <= '0;
            overwrite_offset <= '0;
        end else begin
            overwrite_valid <= data_in_valid && !accumulate;
            overwrite_row <= old_packed_o;
            overwrite_offset <= lane_offset;
            if (data_in_valid && !accumulate) begin
                for (int lane = 0; lane < WRITE_LANES; lane++)
                    overwrite_row[lane_offset + lane] <= matrix_row[lane];
            end
        end
    end

    always_comb begin
        packed_o_mask = '0;
        if (overwrite_valid) begin
            for (int lane = 0; lane < WRITE_LANES; lane++)
                packed_o_mask[overwrite_offset + lane] = 1'b1;
        end else if (context_pop) begin
            for (int lane = 0; lane < WRITE_LANES; lane++)
                packed_o_mask[context_offset + lane] = 1'b1;
        end
        packed_o_out = overwrite_row;
        data_out_valid = overwrite_valid;
        if (context_pop) begin
            packed_o_out = context_old_row;
            for (int lane = 0; lane < WRITE_LANES; lane++)
                packed_o_out[context_offset + lane] = add_out[lane];
            data_out_valid = 1'b1;
        end
    end

`ifdef SIMULATION
    always_ff @(posedge clk) begin
        if (!rst && data_in_valid && lane_offset + WRITE_LANES > VLEN)
            $fatal(1, "packed PV lane range exceeds VLEN");
        if (!rst && add_valid != '0 && add_valid != {WRITE_LANES{1'b1}})
            $fatal(1, "packed PV adder lanes completed out of lockstep");
    end
`endif
endmodule
