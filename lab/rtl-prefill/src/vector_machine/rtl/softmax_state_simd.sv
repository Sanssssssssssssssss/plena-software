`timescale 1ns / 1ps

// Pipelined row-parallel m/l state datapath. Commands from one phase may be
// accepted every cycle; a phase change waits until the current stream drains.
// This preserves the original unfused max/sub/exp and mul/add rounding order.
module softmax_state_simd #(
    parameter int EXP_WIDTH = 5,
    parameter int MANT_WIDTH = 6,
    parameter int ROW_LANES = 4,
    parameter int CONTEXT_DEPTH = 64,
    localparam int FP_WIDTH = EXP_WIDTH + MANT_WIDTH + 1,
    localparam int ACTIVE_WIDTH = $clog2(ROW_LANES + 1),
    localparam int COUNT_WIDTH = $clog2(CONTEXT_DEPTH + 1),
    localparam int ROW_DATA_WIDTH = ROW_LANES * FP_WIDTH
) (
    input  logic clk,
    input  logic rst,
    input  logic command_valid,
    output logic command_ready,
    input  logic [1:0] phase, // 0=max/m_res, 1=l update, 2=final reciprocal
    input  logic [ACTIVE_WIDTH-1:0] active_rows,
    input  logic [ROW_LANES-1:0][FP_WIDTH-1:0] m_in,
    input  logic [ROW_LANES-1:0][FP_WIDTH-1:0] l_in,
    input  logic [ROW_LANES-1:0][FP_WIDTH-1:0] stat_in,
    input  logic [ROW_LANES-1:0][FP_WIDTH-1:0] factor_in,
    input  logic [ROW_LANES-1:0] valid_in,
    output logic [ROW_LANES-1:0][FP_WIDTH-1:0] m_out,
    output logic [ROW_LANES-1:0][FP_WIDTH-1:0] l_out,
    output logic [ROW_LANES-1:0][FP_WIDTH-1:0] factor_out,
    output logic [ROW_LANES-1:0] valid_out,
    output logic done
);
    localparam logic [EXP_WIDTH-1:0] FP_BIAS =
        (1 << (EXP_WIDTH - 1)) - 1;
    localparam logic [FP_WIDTH-1:0] FP_ONE =
        {1'b0, FP_BIAS, {MANT_WIDTH{1'b0}}};

    localparam int P0_MAX_CTX_WIDTH = 2 * ROW_DATA_WIDTH + ACTIVE_WIDTH;
    localparam int P0_SUB_CTX_WIDTH = 2 * ROW_DATA_WIDTH + ACTIVE_WIDTH;
    localparam int P0_EXP_CTX_WIDTH = 2 * ROW_DATA_WIDTH + ACTIVE_WIDTH;
    localparam int P1_MUL_CTX_WIDTH = 2 * ROW_DATA_WIDTH + ACTIVE_WIDTH;
    localparam int P1_ADD_CTX_WIDTH = ROW_DATA_WIDTH + ACTIVE_WIDTH;
    localparam int P2_CTX_WIDTH = 2 * ROW_DATA_WIDTH + ACTIVE_WIDTH;

    logic [1:0] active_phase;
    logic active_first_mode;
    logic [COUNT_WIDTH-1:0] in_flight;
    logic accept;
    logic first_command;

    logic p0_max_ready, p0_sub_ready, p0_exp_ready;
    logic p1_mul_ready, p1_add_ready, p2_ready;
    logic input_context_ready;

    assign first_command = !valid_in[0];
    always_comb begin
        unique case (phase)
            2'd0: input_context_ready = first_command || p0_max_ready;
            2'd1: input_context_ready = p1_mul_ready;
            2'd2: input_context_ready = p2_ready;
            default: input_context_ready = 1'b0;
        endcase
    end
    assign command_ready = input_context_ready &&
        (in_flight == 0 ||
         (phase == active_phase &&
          (phase != 0 || first_command == active_first_mode)));
    assign accept = command_valid && command_ready;

    // First-block phase-0 bypass has a one-cycle streaming pipeline.
    logic first_valid_q;
    logic [ROW_LANES-1:0][FP_WIDTH-1:0] first_m_q, first_l_q;
    logic [ROW_LANES-1:0] first_state_valid_q;
    logic [ACTIVE_WIDTH-1:0] first_active_q;
    always_ff @(posedge clk) begin
        if (rst) begin
            first_valid_q <= 1'b0;
            first_m_q <= '0;
            first_l_q <= '0;
            first_state_valid_q <= '0;
            first_active_q <= '0;
        end else begin
            first_valid_q <= accept && phase == 0 && first_command;
            if (accept && phase == 0 && first_command) begin
                first_m_q <= stat_in;
                first_l_q <= '0;
                first_active_q <= active_rows;
                first_state_valid_q <= '0;
                for (int lane = 0; lane < ROW_LANES; lane++) begin
                    if (lane < active_rows)
                        first_state_valid_q[lane] <= 1'b1;
                end
            end
        end
    end

    logic [ROW_LANES-1:0][FP_WIDTH-1:0]
        max_data, sub_data, exp_data, mul_data, add_data, recip_data;
    logic [ROW_LANES-1:0]
        max_valid, sub_valid, exp_valid, mul_valid, add_valid, recip_valid;

    logic [P0_MAX_CTX_WIDTH-1:0] p0_max_ctx_in, p0_max_ctx_out;
    logic p0_max_ctx_valid;
    logic [ROW_LANES-1:0][FP_WIDTH-1:0] p0_old_m, p0_old_l;
    logic [ACTIVE_WIDTH-1:0] p0_max_active;
    assign p0_max_ctx_in = {m_in, l_in, active_rows};
    assign {p0_old_m, p0_old_l, p0_max_active} = p0_max_ctx_out;
    // fp_max has a fixed one-cycle pipeline and cannot backpressure.  Its
    // context must use the same one-cycle delay; the generic RAM-backed FIFO
    // has a registered output and would let max_data overtake the tag.
    register_slice_wo_hs #(.DATA_WIDTH(P0_MAX_CTX_WIDTH)) p0_max_context (
        .clk(clk), .rst(rst),
        .data_in(p0_max_ctx_in),
        .data_in_valid(accept && phase == 0 && !first_command),
        .data_out(p0_max_ctx_out), .data_out_valid(p0_max_ctx_valid)
    );
    assign p0_max_ready = 1'b1;

    logic [P0_SUB_CTX_WIDTH-1:0] p0_sub_ctx_in, p0_sub_ctx_out;
    logic p0_sub_ctx_valid;
    logic [ROW_LANES-1:0][FP_WIDTH-1:0] p0_new_m_sub, p0_old_l_sub;
    logic [ACTIVE_WIDTH-1:0] p0_sub_active;
    assign p0_sub_ctx_in = {max_data, p0_old_l, p0_max_active};
    assign {p0_new_m_sub, p0_old_l_sub, p0_sub_active} = p0_sub_ctx_out;
    fifo #(.DATA_WIDTH(P0_SUB_CTX_WIDTH), .DEPTH(CONTEXT_DEPTH)) p0_sub_context (
        .clk(clk), .rst(rst),
        .data_in(p0_sub_ctx_in),
        .data_in_valid(max_valid[0] && p0_max_ctx_valid),
        .data_in_ready(p0_sub_ready),
        .data_out(p0_sub_ctx_out), .data_out_valid(p0_sub_ctx_valid),
        .data_out_ready(sub_valid[0]), .empty(), .full()
    );

    logic [P0_EXP_CTX_WIDTH-1:0] p0_exp_ctx_in, p0_exp_ctx_out;
    logic p0_exp_ctx_valid;
    logic [ROW_LANES-1:0][FP_WIDTH-1:0] p0_new_m_exp, p0_old_l_exp;
    logic [ACTIVE_WIDTH-1:0] p0_exp_active;
    assign p0_exp_ctx_in = {p0_new_m_sub, p0_old_l_sub, p0_sub_active};
    assign {p0_new_m_exp, p0_old_l_exp, p0_exp_active} = p0_exp_ctx_out;
    fifo #(.DATA_WIDTH(P0_EXP_CTX_WIDTH), .DEPTH(CONTEXT_DEPTH)) p0_exp_context (
        .clk(clk), .rst(rst),
        .data_in(p0_exp_ctx_in),
        .data_in_valid(sub_valid[0] && p0_sub_ctx_valid),
        .data_in_ready(p0_exp_ready),
        .data_out(p0_exp_ctx_out), .data_out_valid(p0_exp_ctx_valid),
        .data_out_ready(exp_valid[0]), .empty(), .full()
    );

    logic [P1_MUL_CTX_WIDTH-1:0] p1_mul_ctx_in, p1_mul_ctx_out;
    logic p1_mul_ctx_valid;
    logic [ROW_LANES-1:0][FP_WIDTH-1:0] p1_m_mul, p1_stat_mul;
    logic [ACTIVE_WIDTH-1:0] p1_mul_active;
    assign p1_mul_ctx_in = {m_in, stat_in, active_rows};
    assign {p1_m_mul, p1_stat_mul, p1_mul_active} = p1_mul_ctx_out;
    fifo #(.DATA_WIDTH(P1_MUL_CTX_WIDTH), .DEPTH(CONTEXT_DEPTH)) p1_mul_context (
        .clk(clk), .rst(rst),
        .data_in(p1_mul_ctx_in), .data_in_valid(accept && phase == 1),
        .data_in_ready(p1_mul_ready),
        .data_out(p1_mul_ctx_out), .data_out_valid(p1_mul_ctx_valid),
        .data_out_ready(mul_valid[0]), .empty(), .full()
    );

    logic [P1_ADD_CTX_WIDTH-1:0] p1_add_ctx_in, p1_add_ctx_out;
    logic p1_add_ctx_valid;
    logic [ROW_LANES-1:0][FP_WIDTH-1:0] p1_m_add;
    logic [ACTIVE_WIDTH-1:0] p1_add_active;
    assign p1_add_ctx_in = {p1_m_mul, p1_mul_active};
    assign {p1_m_add, p1_add_active} = p1_add_ctx_out;
    fifo #(.DATA_WIDTH(P1_ADD_CTX_WIDTH), .DEPTH(CONTEXT_DEPTH)) p1_add_context (
        .clk(clk), .rst(rst),
        .data_in(p1_add_ctx_in),
        .data_in_valid(mul_valid[0] && p1_mul_ctx_valid),
        .data_in_ready(p1_add_ready),
        .data_out(p1_add_ctx_out), .data_out_valid(p1_add_ctx_valid),
        .data_out_ready(add_valid[0]), .empty(), .full()
    );

    logic [P2_CTX_WIDTH-1:0] p2_ctx_in, p2_ctx_out;
    logic p2_ctx_valid;
    logic [ROW_LANES-1:0][FP_WIDTH-1:0] p2_m, p2_l;
    logic [ACTIVE_WIDTH-1:0] p2_active;
    assign p2_ctx_in = {m_in, l_in, active_rows};
    assign {p2_m, p2_l, p2_active} = p2_ctx_out;
    fifo #(.DATA_WIDTH(P2_CTX_WIDTH), .DEPTH(CONTEXT_DEPTH)) p2_context (
        .clk(clk), .rst(rst),
        .data_in(p2_ctx_in), .data_in_valid(accept && phase == 2),
        .data_in_ready(p2_ready),
        .data_out(p2_ctx_out), .data_out_valid(p2_ctx_valid),
        .data_out_ready(recip_valid[0]), .empty(), .full()
    );

    for (genvar lane = 0; lane < ROW_LANES; lane++) begin : state_lane
        fp_max #(.EXP_WIDTH(EXP_WIDTH), .MANT_WIDTH(MANT_WIDTH)) maximum (
            .clk(clk), .rst(rst),
            .data_in_valid(accept && phase == 0 && !first_command &&
                           lane < active_rows),
            .data_a(m_in[lane]), .data_b(stat_in[lane]),
            .data_out(max_data[lane]), .data_out_valid(max_valid[lane])
        );
        fp_fix_adder #(.EXP_WIDTH(EXP_WIDTH), .MANT_WIDTH(MANT_WIDTH)) subtract (
            .clk(clk), .rst(rst),
            .data_in_valid(max_valid[0] && p0_max_ctx_valid &&
                           lane < p0_max_active),
            .data_a(p0_old_m[lane]),
            .data_b({~max_data[lane][FP_WIDTH-1], max_data[lane][FP_WIDTH-2:0]}),
            .data_out(sub_data[lane]), .data_out_valid(sub_valid[lane])
        );
        fp_fix_exp #(.EXP_WIDTH(EXP_WIDTH), .MANT_WIDTH(MANT_WIDTH)) exponential (
            .clk(clk), .rst(rst),
            .data_in_valid(sub_valid[0] && p0_sub_ctx_valid &&
                           lane < p0_sub_active),
            .data_in(sub_data[lane]), .data_out(exp_data[lane]),
            .data_out_valid(exp_valid[lane])
        );
        fp_fix_mult #(.EXP_WIDTH(EXP_WIDTH), .MANT_WIDTH(MANT_WIDTH)) multiplier (
            .clk(clk), .rst(rst),
            .data_in_valid(accept && phase == 1 && lane < active_rows),
            .data_a(l_in[lane]), .data_b(factor_in[lane]),
            .data_out(mul_data[lane]), .data_out_valid(mul_valid[lane])
        );
        fp_fix_adder #(.EXP_WIDTH(EXP_WIDTH), .MANT_WIDTH(MANT_WIDTH)) accumulator (
            .clk(clk), .rst(rst),
            .data_in_valid(mul_valid[0] && p1_mul_ctx_valid &&
                           lane < p1_mul_active),
            .data_a(mul_data[lane]), .data_b(p1_stat_mul[lane]),
            .data_out(add_data[lane]), .data_out_valid(add_valid[lane])
        );
        fp_fix_reciprocal #(.EXP_WIDTH(EXP_WIDTH), .MANT_WIDTH(MANT_WIDTH)) reciprocal (
            .clk(clk), .rst(rst),
            .data_in_valid(accept && phase == 2 && lane < active_rows),
            .data_in(l_in[lane]), .data_out(recip_data[lane]),
            .data_out_valid(recip_valid[lane])
        );
    end

    logic first_done, p0_done, p1_done, p2_done;
    assign first_done = first_valid_q;
    assign p0_done = exp_valid[0] && p0_exp_ctx_valid;
    assign p1_done = add_valid[0] && p1_add_ctx_valid;
    assign p2_done = recip_valid[0] && p2_ctx_valid;
    assign done = first_done || p0_done || p1_done || p2_done;

    always_comb begin
        m_out = '0;
        l_out = '0;
        factor_out = '0;
        valid_out = '0;
        if (first_done) begin
            m_out = first_m_q;
            l_out = first_l_q;
            for (int lane = 0; lane < ROW_LANES; lane++) begin
                if (lane < first_active_q)
                    factor_out[lane] = FP_ONE;
            end
            valid_out = first_state_valid_q;
        end else if (p0_done) begin
            m_out = p0_new_m_exp;
            l_out = p0_old_l_exp;
            factor_out = exp_data;
            for (int lane = 0; lane < ROW_LANES; lane++) begin
                if (lane < p0_exp_active)
                    valid_out[lane] = 1'b1;
            end
        end else if (p1_done) begin
            m_out = p1_m_add;
            l_out = add_data;
            for (int lane = 0; lane < ROW_LANES; lane++) begin
                if (lane < p1_add_active)
                    valid_out[lane] = 1'b1;
            end
        end else if (p2_done) begin
            m_out = p2_m;
            l_out = p2_l;
            factor_out = recip_data;
            valid_out = '0;
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            active_phase <= '0;
            active_first_mode <= 1'b0;
            in_flight <= '0;
        end else begin
            if (accept && in_flight == 0) begin
                active_phase <= phase;
                active_first_mode <= first_command;
            end
            unique case ({accept, done})
                2'b10: in_flight <= in_flight + 1'b1;
                2'b01: in_flight <= in_flight - 1'b1;
                default: in_flight <= in_flight;
            endcase
        end
    end

`ifdef SIMULATION
    always_ff @(posedge clk) begin
        if (!rst && command_valid && command_ready &&
            (active_rows == 0 || active_rows > ROW_LANES))
            $fatal(1, "invalid softmax state active-row count");
        if (!rst && command_valid && command_ready && phase == 0) begin
            for (int lane = 1; lane < ROW_LANES; lane++) begin
                if (lane < active_rows && valid_in[lane] != valid_in[0])
                    $fatal(1, "mixed first/recurrent rows in one state command");
            end
        end
        if (!rst && (first_done + p0_done + p1_done + p2_done) > 1)
            $fatal(1, "softmax state pipelines completed out of phase");
        if (!rst && max_valid[0] && (!p0_max_ctx_valid || !p0_sub_ready))
            $fatal(1, "softmax max context underflow or overflow");
        if (!rst && sub_valid[0] && (!p0_sub_ctx_valid || !p0_exp_ready))
            $fatal(1, "softmax subtract context underflow or overflow");
        if (!rst && mul_valid[0] && (!p1_mul_ctx_valid || !p1_add_ready))
            $fatal(1, "softmax multiply context underflow or overflow");
        if (!rst && done && in_flight == 0)
            $fatal(1, "softmax state completion without an in-flight command");
    end
`endif
endmodule
