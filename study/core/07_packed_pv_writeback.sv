// 学习注： 来源 lab/rtl-prefill/src/matrix_machine/rtl/packed_pv_writeback.sv，原始行 1–213。
// 学习注： 这是核心阅读副本；运行仍用原目录及其依赖。只新增注释，没有修改逻辑。
`timescale 1ns/1ps

// Production packed-PV writeback controller.  Matrix rows are accepted as a
// BLEN-row burst, paired with the corresponding old packed-O rows when an RMW
// is required, and committed through the Vector SRAM's dedicated B-port mux.
// 学习注：P@V 的窄结果直接写进 packed O 的目标 lane，省去后续 shift/add。
module packed_pv_writeback #(
    parameter int EXP_WIDTH = 5,
    parameter int MANT_WIDTH = 6,
    parameter int VLEN = 16,
    parameter int BLEN = 4,
    parameter int ADDR_WIDTH = 32,
    localparam int FP_WIDTH = EXP_WIDTH + MANT_WIDTH + 1,
    localparam int OFFSET_WIDTH = (VLEN <= 1) ? 1 : $clog2(VLEN),
    localparam int ROW_COUNT_WIDTH = (BLEN <= 1) ? 1 : $clog2(BLEN + 1),
    localparam int RESULT_WIDTH = ADDR_WIDTH + VLEN * FP_WIDTH + VLEN
) (
    input  logic clk,
    input  logic rst,

    input  logic start,
    input  logic [ADDR_WIDTH-1:0] base_addr,
    // 学习注：覆盖和累加是两条路径；累加需要读旧 O，再做 read-modify-write。
    input  logic accumulate,
    input  logic [OFFSET_WIDTH-1:0] lane_offset,

    input  logic matrix_row_valid,
    input  logic [VLEN-1:0][FP_WIDTH-1:0] matrix_row,
    output logic matrix_row_ready,

    output logic sram_read_req,
    output logic [ADDR_WIDTH-1:0] sram_read_addr,
    input  logic sram_read_ready,
    input  logic sram_read_valid,
    input  logic [VLEN-1:0][FP_WIDTH-1:0] sram_read_data,

    output logic sram_write_req,
    output logic [ADDR_WIDTH-1:0] sram_write_addr,
    output logic [VLEN-1:0][FP_WIDTH-1:0] sram_write_data,
    output logic [VLEN-1:0] sram_write_mask,
    input  logic sram_write_ready,

    output logic busy,
    output logic done,
    output logic [ROW_COUNT_WIDTH-1:0] accepted_rows,
    output logic [ROW_COUNT_WIDTH-1:0] committed_rows
);
    logic accumulate_q;
    logic [ADDR_WIDTH-1:0] base_addr_q;
    logic [OFFSET_WIDTH-1:0] lane_offset_q;
    logic input_accept;
    logic [ADDR_WIDTH-1:0] input_addr;

    logic pending_valid_q;
    logic [VLEN-1:0][FP_WIDTH-1:0] pending_matrix_row_q;
    logic [ADDR_WIDTH-1:0] pending_addr_q;

    logic accumulator_in_valid;
    logic [VLEN-1:0][FP_WIDTH-1:0] accumulator_old_row;
    logic [VLEN-1:0][FP_WIDTH-1:0] accumulator_out;
    logic [VLEN-1:0] accumulator_mask;
    logic accumulator_out_valid;

    logic [ADDR_WIDTH-1:0] address_context_out;
    logic address_context_valid, address_context_ready;
    logic [ADDR_WIDTH-1:0] overwrite_address_q;
    logic result_context_valid;
    logic [ADDR_WIDTH-1:0] result_context_address;
    logic result_fifo_ready, result_fifo_valid;
    logic [RESULT_WIDTH-1:0] result_fifo_in, result_fifo_out;

    // 学习注：接收不能超过 BLEN 行；RMW 还受 SRAM 读端口 ready 约束。
    assign matrix_row_ready =
        (busy || start) && (start || accepted_rows < BLEN) &&
        (!(start ? accumulate : accumulate_q) || sram_read_ready);
    // 学习注：只有握手成功才能推进地址/行计数。
    assign input_accept = matrix_row_valid && matrix_row_ready;
    // 学习注：地址按 VLEN 行跨度增加；lane_offset 决定行内哪几路被写。
    assign input_addr = (start ? base_addr : base_addr_q) +
        (start ? 0 : accepted_rows) * VLEN;

    // 学习注：仅 accumulate 需要读旧值；覆盖路径省去这次读取。
    assign sram_read_req = input_accept && (start ? accumulate : accumulate_q);
    assign sram_read_addr = input_addr;

    // SRAM reads and the overwrite bypass both take one registered staging
    // cycle, so the matrix row and its address remain aligned with old O.
    always_ff @(posedge clk) begin
        if (rst) begin
            pending_valid_q <= 1'b0;
            pending_matrix_row_q <= '0;
            pending_addr_q <= '0;
            overwrite_address_q <= '0;
        end else begin
            pending_valid_q <= input_accept &&
                !(start ? accumulate : accumulate_q);
            if (input_accept) begin
                pending_matrix_row_q <= matrix_row;
                pending_addr_q <= input_addr;
            end
            if (accumulator_in_valid && !accumulate_q)
                overwrite_address_q <= pending_addr_q;
        end
    end

    assign accumulator_in_valid = accumulate_q ? sram_read_valid : pending_valid_q;
    assign accumulator_old_row = accumulate_q ? sram_read_data : '0;

    packed_pv_accumulator #(
        .EXP_WIDTH(EXP_WIDTH),
        .MANT_WIDTH(MANT_WIDTH),
        .VLEN(VLEN),
        .WRITE_LANES(BLEN)
    ) accumulator (
        .clk(clk),
        .rst(rst),
        .data_in_valid(accumulator_in_valid),
        .accumulate(accumulate_q),
        .lane_offset(lane_offset_q),
        .old_packed_o(accumulator_old_row),
        .matrix_row(pending_matrix_row_q),
        .packed_o_out(accumulator_out),
        .packed_o_mask(accumulator_mask),
        .data_out_valid(accumulator_out_valid)
    );

    fifo #(
        .DATA_WIDTH(ADDR_WIDTH),
        .DEPTH(32)
    ) address_context_fifo (
        .clk(clk),
        .rst(rst),
        .data_in(pending_addr_q),
        .data_in_valid(accumulator_in_valid && accumulate_q),
        .data_in_ready(address_context_ready),
        .data_out(address_context_out),
        .data_out_valid(address_context_valid),
        .data_out_ready(accumulator_out_valid && accumulate_q && result_fifo_ready),
        .empty(),
        .full()
    );

    assign result_context_valid = accumulate_q
        ? address_context_valid : accumulator_out_valid;
    assign result_context_address = accumulate_q
        ? address_context_out : overwrite_address_q;
    assign result_fifo_in = {
        result_context_address, accumulator_out, accumulator_mask
    };
    fifo #(
        .DATA_WIDTH(RESULT_WIDTH),
        .DEPTH(32)
    ) result_fifo (
        .clk(clk),
        .rst(rst),
        .data_in(result_fifo_in),
        .data_in_valid(accumulator_out_valid && result_context_valid),
        .data_in_ready(result_fifo_ready),
        .data_out(result_fifo_out),
        .data_out_valid(result_fifo_valid),
        .data_out_ready(sram_write_ready),
        .empty(),
        .full()
    );

    assign {sram_write_addr, sram_write_data, sram_write_mask} = result_fifo_out;
    assign sram_write_req = result_fifo_valid;

    always_ff @(posedge clk) begin
        if (rst) begin
            busy <= 1'b0;
            done <= 1'b0;
            accumulate_q <= 1'b0;
            base_addr_q <= '0;
            lane_offset_q <= '0;
            accepted_rows <= '0;
            committed_rows <= '0;
        end else begin
            done <= 1'b0;
            if (start) begin
                busy <= 1'b1;
                accumulate_q <= accumulate;
                base_addr_q <= base_addr;
                lane_offset_q <= lane_offset;
                accepted_rows <= input_accept ? 1 : 0;
                committed_rows <= '0;
            end else if (input_accept) begin
                accepted_rows <= accepted_rows + 1'b1;
            end
            if (sram_write_req && sram_write_ready) begin
                committed_rows <= committed_rows + 1'b1;
                if (committed_rows == BLEN - 1) begin
                    busy <= 1'b0;
                    done <= 1'b1;
                end
            end
        end
    end

`ifdef SIMULATION
    always_ff @(posedge clk) begin
        if (!rst && start && busy)
            $fatal(1, "packed PV writeback restarted while busy");
        // A valid pulse may remain asserted through the edge that accepts the
        // final BLEN row.  Only an unaccepted row inside the active burst is a
        // real data-loss condition.
        if (!rst && matrix_row_valid && busy && accepted_rows < BLEN &&
            !matrix_row_ready)
            $fatal(1, "packed PV writeback dropped a Matrix row");
        if (!rst && accumulator_in_valid && accumulate_q && !address_context_ready)
            $fatal(1, "packed PV address context FIFO overflow");
        if (!rst && accumulator_out_valid &&
            (!result_context_valid || !result_fifo_ready))
            $fatal(1, "packed PV result could not be queued");
        if (!rst && start && lane_offset + BLEN > VLEN)
            $fatal(1, "packed PV lane range exceeds VLEN");
    end
`endif
endmodule
