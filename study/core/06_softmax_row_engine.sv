// 学习注： 来源 lab/rtl-prefill/src/vector_machine/rtl/softmax_row_engine.sv，原始行 1–664。
// 学习注： 这是核心阅读副本；运行仍用原目录及其依赖。只新增注释，没有修改逻辑。
`timescale 1ns/1ps

`include "configuration.svh"
`include "operation.svh"

// Production rtl-v6 row-group controller. Row zero reuses the existing
// VectorMachine datapaths; rows 1..R-1 are implemented by auxiliary slices.
// Independent groups from one operation phase form a stream and may be
// accepted every cycle. A range scoreboard prevents dependent groups from
// entering the stream before their predecessors commit.
// 学习注：把多行 SRAM、状态 bank 与计算流水接起来；重点看接受条件和返回提交。
module softmax_row_engine import configuration_pkg::*; #(
    parameter int EXP_WIDTH = 5,
    parameter int MANT_WIDTH = 6,
    parameter int VLEN = 16,
    // 学习注：每次处理 R 行，每行 VLEN 个 key 元素；更长序列仍须多次迭代。
    parameter int ROW_LANES = 4,
    parameter int STATE_ENTRIES = 16384,
    parameter int ADDR_WIDTH = 32,
    parameter int CONTEXT_DEPTH = 64,
    localparam int FP_WIDTH = EXP_WIDTH + MANT_WIDTH + 1,
    localparam int STATE_ADDR_WIDTH =
        (STATE_ENTRIES <= 1) ? 1 : $clog2(STATE_ENTRIES),
    localparam int ACTIVE_WIDTH = $clog2(ROW_LANES + 1),
    localparam int SEGMENT_LOG2_WIDTH = $clog2($clog2(VLEN) + 1),
    localparam int COUNT_WIDTH = $clog2(CONTEXT_DEPTH + 1),
    localparam int PTR_WIDTH = (CONTEXT_DEPTH <= 1) ? 1 : $clog2(CONTEXT_DEPTH),
    localparam int ROW_DATA_WIDTH = ROW_LANES * VLEN * FP_WIDTH,
    localparam int STATE_DATA_WIDTH = ROW_LANES * FP_WIDTH,
    localparam int GROUP_CTX_WIDTH = ADDR_WIDTH + STATE_ADDR_WIDTH + ACTIVE_WIDTH,
    localparam int STATE_INPUT_WIDTH =
        4 * STATE_DATA_WIDTH + ROW_LANES + STATE_ADDR_WIDTH + ACTIVE_WIDTH + 2,
    localparam int STATE_CTX_WIDTH = STATE_ADDR_WIDTH + ACTIVE_WIDTH + 2,
    localparam int WRITE_FIFO_WIDTH = ROW_DATA_WIDTH + ADDR_WIDTH + ACTIVE_WIDTH
) (
    input logic clk,
    input logic rst,

    input logic command_valid,
    output logic command_ready,
    input V_ELEMENT_OP element_operation,
    input V_REDUCT_OP reduction_operation,
    input logic state_operation,
    input logic stats_operand,
    input logic [1:0] state_phase,
    input logic [ACTIVE_WIDTH-1:0] active_rows,
    input logic [ADDR_WIDTH-1:0] vector_base_addr,
    input logic [ADDR_WIDTH-1:0] state_base_addr,
    input logic [FP_WIDTH-1:0] scalar_in,
    input logic scalar_in_valid,

    // Determine-stage preview used by the frontend to avoid advancing a row
    // command that the execution-stage stream cannot accept next cycle.
    input logic preview_valid,
    output logic preview_ready,
    input V_ELEMENT_OP preview_element_operation,
    input V_REDUCT_OP preview_reduction_operation,
    input logic preview_state_operation,
    input logic preview_stats_operand,
    input logic [1:0] preview_state_phase,
    input logic [ACTIVE_WIDTH-1:0] preview_active_rows,
    input logic [ADDR_WIDTH-1:0] preview_vector_base_addr,
    input logic [ADDR_WIDTH-1:0] preview_state_base_addr,

    input logic group_read_valid,
    input logic [ROW_LANES-1:0][VLEN-1:0][FP_WIDTH-1:0]
        group_read_data,
    output logic group_write_req,
    input logic group_write_ready,
    output logic [ADDR_WIDTH-1:0] group_write_addr,
    output logic [ACTIVE_WIDTH-1:0] group_write_active_rows,
    output logic [ROW_LANES-1:0][VLEN-1:0][FP_WIDTH-1:0]
        group_write_data,
    output logic [ROW_LANES-1:0][VLEN-1:0] group_write_mask,

    // Shared production row-zero datapaths.
    output logic row0_element_launch,
    output V_ELEMENT_OP row0_element_operation,
    output logic [VLEN-1:0][FP_WIDTH-1:0] row0_element_a,
    output logic [VLEN-1:0][FP_WIDTH-1:0] row0_element_b,
    input logic [VLEN-1:0][FP_WIDTH-1:0] row0_element_out,
    input logic row0_element_out_valid,

    output logic row0_reduction_launch,
    output V_REDUCT_OP row0_reduction_operation,
    output logic [VLEN-1:0][FP_WIDTH-1:0] row0_reduction_in,
    input logic [FP_WIDTH-1:0] row0_reduction_out,
    input logic row0_reduction_out_valid,

    output logic busy,
    output logic done,
    output logic reduction_done
);
    // ------------------------------------------------------------------
    // Stream class and dependency scoreboard
    // ------------------------------------------------------------------
    V_ELEMENT_OP stream_element_operation;
    V_REDUCT_OP stream_reduction_operation;
    logic stream_state_operation, stream_stats_operand;
    logic [1:0] stream_state_phase;
    logic [COUNT_WIDTH-1:0] in_flight;
    logic [PTR_WIDTH-1:0] pending_write_ptr, pending_read_ptr;

    // 学习注：scoreboard 记住在途访问范围，防止同一状态/向量的读写依赖冲突。
    logic pending_valid [0:CONTEXT_DEPTH-1];
    logic pending_vector_access [0:CONTEXT_DEPTH-1];
    logic pending_state_access [0:CONTEXT_DEPTH-1];
    logic [ADDR_WIDTH-1:0] pending_vector_base [0:CONTEXT_DEPTH-1];
    logic [STATE_ADDR_WIDTH-1:0] pending_state_base [0:CONTEXT_DEPTH-1];
    logic [ACTIVE_WIDTH-1:0] pending_active_rows [0:CONTEXT_DEPTH-1];

    logic current_vector_access, current_state_access;
    logic class_compatible, address_conflict, scalar_ready;
    logic preview_class_compatible, preview_address_conflict;
    logic preview_vector_access, preview_state_access;
    logic accept;

    // 学习注：用半开区间判重叠；这是允许独立组连续发射的前提。
    function automatic logic ranges_overlap(
        input logic [ADDR_WIDTH-1:0] left_base,
        input logic [ADDR_WIDTH:0] left_size,
        input logic [ADDR_WIDTH-1:0] right_base,
        input logic [ADDR_WIDTH:0] right_size
    );
        logic [ADDR_WIDTH:0] left_end, right_end;
        begin
            left_end = {1'b0, left_base} + left_size;
            right_end = {1'b0, right_base} + right_size;
            return ({1'b0, left_base} < right_end) &&
                   ({1'b0, right_base} < left_end);
        end
    endfunction

    assign current_vector_access = !state_operation;
    assign current_state_access = state_operation || stats_operand ||
        reduction_operation != STALL_V_REDUCT;
    // 学习注：同时在途的组需要属于兼容操作阶段，不能把不同 phase 任意混发。
    assign class_compatible = in_flight == 0 ||
        (stream_element_operation == element_operation &&
         stream_reduction_operation == reduction_operation &&
         stream_state_operation == state_operation &&
         stream_stats_operand == stats_operand &&
         stream_state_phase == state_phase);
    // 学习注：需要标量的 MUL 必须等 scalar_valid，否则会用到旧标量。
    assign scalar_ready = !(element_operation == MUL_V_ELEMENT &&
                            !stats_operand && !state_operation) ||
                          scalar_in_valid;

    always_comb begin
        address_conflict = 1'b0;
        for (int index = 0; index < CONTEXT_DEPTH; index++) begin
            if (pending_valid[index]) begin
                if (current_vector_access && pending_vector_access[index] &&
                    ranges_overlap(
                        vector_base_addr,
                        ADDR_WIDTH'(active_rows) * VLEN,
                        pending_vector_base[index],
                        ADDR_WIDTH'(pending_active_rows[index]) * VLEN
                    ))
                    address_conflict = 1'b1;
                if (current_state_access && pending_state_access[index] &&
                    ranges_overlap(
                        state_base_addr,
                        ADDR_WIDTH'(active_rows),
                        {{(ADDR_WIDTH-STATE_ADDR_WIDTH){1'b0}},
                         pending_state_base[index]},
                        ADDR_WIDTH'(pending_active_rows[index])
                    ))
                    address_conflict = 1'b1;
            end
        end
    end

    // 学习注：ready 同时受操作类型、地址冲突、标量就绪和容量约束。
    assign command_ready = class_compatible && !address_conflict && scalar_ready &&
        in_flight < CONTEXT_DEPTH - 2;
    // 学习注：valid && ready 才是一次真实接收；性能计数应在这里记账。
    assign accept = command_valid && command_ready;
    assign busy = in_flight != 0;

    // 学习注：preview 让前端提前知道下一拍是否可接受，避免流水级推进后丢命令。
    assign preview_vector_access = !preview_state_operation;
    assign preview_state_access = preview_state_operation ||
        preview_stats_operand || preview_reduction_operation != STALL_V_REDUCT;
    assign preview_class_compatible =
        (in_flight == 0 && !accept) ||
        ((in_flight != 0 || accept) &&
         (in_flight != 0
              ? stream_element_operation : element_operation) ==
             preview_element_operation &&
         (in_flight != 0
              ? stream_reduction_operation : reduction_operation) ==
             preview_reduction_operation &&
         (in_flight != 0
              ? stream_state_operation : state_operation) ==
             preview_state_operation &&
         (in_flight != 0
              ? stream_stats_operand : stats_operand) ==
             preview_stats_operand &&
         (in_flight != 0
              ? stream_state_phase : state_phase) == preview_state_phase);

    always_comb begin
        preview_address_conflict = 1'b0;
        for (int index = 0; index < CONTEXT_DEPTH; index++) begin
            if (pending_valid[index]) begin
                if (preview_vector_access && pending_vector_access[index] &&
                    ranges_overlap(
                        preview_vector_base_addr,
                        ADDR_WIDTH'(preview_active_rows) * VLEN,
                        pending_vector_base[index],
                        ADDR_WIDTH'(pending_active_rows[index]) * VLEN
                    ))
                    preview_address_conflict = 1'b1;
                if (preview_state_access && pending_state_access[index] &&
                    ranges_overlap(
                        preview_state_base_addr,
                        ADDR_WIDTH'(preview_active_rows),
                        {{(ADDR_WIDTH-STATE_ADDR_WIDTH){1'b0}},
                         pending_state_base[index]},
                        ADDR_WIDTH'(pending_active_rows[index])
                    ))
                    preview_address_conflict = 1'b1;
            end
        end
        // Include an execution-stage command accepted in this cycle; it does
        // not enter pending_valid until the active clock edge.
        if (accept) begin
            if (preview_vector_access && current_vector_access &&
                ranges_overlap(
                    preview_vector_base_addr,
                    ADDR_WIDTH'(preview_active_rows) * VLEN,
                    vector_base_addr,
                    ADDR_WIDTH'(active_rows) * VLEN
                ))
                preview_address_conflict = 1'b1;
            if (preview_state_access && current_state_access &&
                ranges_overlap(
                    preview_state_base_addr,
                    ADDR_WIDTH'(preview_active_rows),
                    state_base_addr,
                    ADDR_WIDTH'(active_rows)
                ))
                preview_address_conflict = 1'b1;
        end
    end
    assign preview_ready = !preview_valid ||
        (preview_class_compatible && !preview_address_conflict &&
         in_flight < CONTEXT_DEPTH - 3);

    // Metadata is delayed with the one-cycle banked SRAM/state-bank reads.
    V_ELEMENT_OP command_element_q;
    V_REDUCT_OP command_reduction_q;
    logic command_state_q, command_stats_q;
    logic [1:0] command_phase_q;
    logic [ACTIVE_WIDTH-1:0] command_active_q;
    logic [ADDR_WIDTH-1:0] command_vector_base_q;
    logic [STATE_ADDR_WIDTH-1:0] command_state_base_q;
    logic [FP_WIDTH-1:0] command_scalar_q;

    always_ff @(posedge clk) begin
        if (rst) begin
            command_element_q <= STALL_V_ELEMENT;
            command_reduction_q <= STALL_V_REDUCT;
            command_state_q <= 1'b0;
            command_stats_q <= 1'b0;
            command_phase_q <= '0;
            command_active_q <= '0;
            command_vector_base_q <= '0;
            command_state_base_q <= '0;
            command_scalar_q <= '0;
        end else if (accept) begin
            command_element_q <= element_operation;
            command_reduction_q <=
                reduction_operation == SUM_SEGS_V_REDUCT
                    ? SUM_V_REDUCT
                    : reduction_operation == MAX_SEGS_V_REDUCT
                        ? MAX_V_REDUCT : reduction_operation;
            command_state_q <= state_operation;
            command_stats_q <= stats_operand;
            command_phase_q <= state_phase;
            command_active_q <= active_rows;
            command_vector_base_q <= vector_base_addr;
            command_state_base_q <= state_base_addr[STATE_ADDR_WIDTH-1:0];
            command_scalar_q <= scalar_in;
        end
    end

    // ------------------------------------------------------------------
    // Persistent and transient banks. Reads and writes have independent
    // addresses so group n+1 may read while group n commits.
    // ------------------------------------------------------------------
    logic state_read_en, state_write_en, state_read_valid;
    logic stat_read_en, stat_write_en, stat_read_valid;
    logic factor_read_en, factor_write_en, factor_read_valid;
    logic [STATE_ADDR_WIDTH-1:0] state_write_base, stat_write_base,
        factor_write_base;
    logic [ACTIVE_WIDTH-1:0] state_write_active, stat_write_active,
        factor_write_active;
    logic [ROW_LANES-1:0][FP_WIDTH-1:0] state_m_out, state_l_out;
    logic [ROW_LANES-1:0] state_valid_out, state_first_out;
    logic [ROW_LANES-1:0][FP_WIDTH-1:0] state_m_write, state_l_write;
    logic [ROW_LANES-1:0] state_valid_write;
    logic [ROW_LANES-1:0][FP_WIDTH-1:0] stat_out, stat_write_data;
    logic [ROW_LANES-1:0] stat_valid_out, stat_write_valid;
    logic [ROW_LANES-1:0][FP_WIDTH-1:0] factor_out, factor_write_data;
    logic [ROW_LANES-1:0] factor_valid_out, factor_write_valid;

    assign state_read_en = accept && (state_operation || stats_operand);
    assign stat_read_en = accept && state_operation;
    assign factor_read_en = accept && (state_operation || stats_operand);

    softmax_state_bank #(
        .FP_WIDTH(FP_WIDTH), .ROW_LANES(ROW_LANES), .ENTRIES(STATE_ENTRIES)
    ) state_bank (
        .clk(clk), .rst(rst), .read_en(state_read_en),
        .write_en(state_write_en),
        .read_group_base(state_base_addr[STATE_ADDR_WIDTH-1:0]),
        .read_active_rows(active_rows),
        .write_group_base(state_write_base),
        .write_active_rows(state_write_active),
        .m_in(state_m_write), .l_in(state_l_write),
        .valid_in(state_valid_write), .first_pending_in(~state_valid_write),
        .m_out(state_m_out), .l_out(state_l_out),
        .valid_out(state_valid_out), .first_pending_out(state_first_out),
        .read_valid(state_read_valid)
    );

    softmax_value_bank #(
        .FP_WIDTH(FP_WIDTH), .ROW_LANES(ROW_LANES), .ENTRIES(STATE_ENTRIES)
    ) statistic_bank (
        .clk(clk), .rst(rst), .read_en(stat_read_en),
        .write_en(stat_write_en),
        .read_group_base(state_base_addr[STATE_ADDR_WIDTH-1:0]),
        .read_active_rows(active_rows),
        .write_group_base(stat_write_base),
        .write_active_rows(stat_write_active),
        .data_in(stat_write_data), .valid_in(stat_write_valid),
        .data_out(stat_out), .valid_out(stat_valid_out),
        .read_valid(stat_read_valid)
    );

    softmax_value_bank #(
        .FP_WIDTH(FP_WIDTH), .ROW_LANES(ROW_LANES), .ENTRIES(STATE_ENTRIES)
    ) factor_bank (
        .clk(clk), .rst(rst), .read_en(factor_read_en),
        .write_en(factor_write_en),
        .read_group_base(state_base_addr[STATE_ADDR_WIDTH-1:0]),
        .read_active_rows(active_rows),
        .write_group_base(factor_write_base),
        .write_active_rows(factor_write_active),
        .data_in(factor_write_data), .valid_in(factor_write_valid),
        .data_out(factor_out), .valid_out(factor_valid_out),
        .read_valid(factor_read_valid)
    );

    // ------------------------------------------------------------------
    // State input buffering and pipelined m/l/factor update.
    // ------------------------------------------------------------------
    logic [STATE_INPUT_WIDTH-1:0] state_input_in, state_input_out;
    logic state_input_ready, state_input_valid, state_input_pop;
    logic [ROW_LANES-1:0][FP_WIDTH-1:0]
        input_m, input_l, input_stat, input_factor;
    logic [ROW_LANES-1:0] input_valid;
    logic [STATE_ADDR_WIDTH-1:0] input_state_base;
    logic [ACTIVE_WIDTH-1:0] input_active;
    logic [1:0] input_phase;
    assign state_input_in = {
        state_m_out, state_l_out, stat_out, factor_out, state_valid_out,
        command_state_base_q, command_active_q, command_phase_q
    };
    assign {input_m, input_l, input_stat, input_factor, input_valid,
            input_state_base, input_active, input_phase} = state_input_out;

    fifo #(.DATA_WIDTH(STATE_INPUT_WIDTH), .DEPTH(8)) state_input_fifo (
        .clk(clk), .rst(rst), .data_in(state_input_in),
        .data_in_valid(state_read_valid && command_state_q),
        .data_in_ready(state_input_ready), .data_out(state_input_out),
        .data_out_valid(state_input_valid), .data_out_ready(state_input_pop),
        .empty(), .full()
    );

    logic state_command_ready, state_done;
    logic [ROW_LANES-1:0][FP_WIDTH-1:0] simd_m_out, simd_l_out,
        simd_factor_out;
    logic [ROW_LANES-1:0] simd_valid_out;
    assign state_input_pop = state_input_valid && state_command_ready;

    softmax_state_simd #(
        .EXP_WIDTH(EXP_WIDTH), .MANT_WIDTH(MANT_WIDTH),
        .ROW_LANES(ROW_LANES), .CONTEXT_DEPTH(CONTEXT_DEPTH)
    ) state_simd (
        .clk(clk), .rst(rst), .command_valid(state_input_valid),
        .command_ready(state_command_ready), .phase(input_phase),
        .active_rows(input_active), .m_in(input_m), .l_in(input_l),
        .stat_in(input_stat), .factor_in(input_factor),
        .valid_in(input_valid), .m_out(simd_m_out), .l_out(simd_l_out),
        .factor_out(simd_factor_out), .valid_out(simd_valid_out),
        .done(state_done)
    );

    logic [STATE_CTX_WIDTH-1:0] state_ctx_in, state_ctx_out;
    logic state_ctx_ready, state_ctx_valid;
    logic [STATE_ADDR_WIDTH-1:0] result_state_base;
    logic [ACTIVE_WIDTH-1:0] result_state_active;
    logic [1:0] result_state_phase;
    // Queue the tag with the bank-read response, in parallel with the state
    // payload.  In particular, the first-block bypass can complete one cycle
    // after the SIMD accepts its input, while the generic FIFO has a
    // registered output.  Enqueuing only at state_input_pop would therefore
    // make the result overtake its tag.
    assign state_ctx_in = {
        command_state_base_q, command_active_q, command_phase_q
    };
    assign {result_state_base, result_state_active, result_state_phase} =
        state_ctx_out;
    fifo #(.DATA_WIDTH(STATE_CTX_WIDTH), .DEPTH(CONTEXT_DEPTH)) state_context_fifo (
        .clk(clk), .rst(rst), .data_in(state_ctx_in),
        .data_in_valid(state_read_valid && command_state_q),
        .data_in_ready(state_ctx_ready),
        .data_out(state_ctx_out), .data_out_valid(state_ctx_valid),
        .data_out_ready(state_done), .empty(), .full()
    );

    assign state_write_en = state_done && state_ctx_valid;
    assign state_write_base = result_state_base;
    assign state_write_active = result_state_active;
    assign state_m_write = simd_m_out;
    assign state_l_write = simd_l_out;
    assign state_valid_write = simd_valid_out;
    assign factor_write_en = state_done && state_ctx_valid &&
        (result_state_phase == 0 || result_state_phase == 2);
    assign factor_write_base = result_state_base;
    assign factor_write_active = result_state_active;
    assign factor_write_data = simd_factor_out;
    always_comb begin
        factor_write_valid = '0;
        for (int row = 0; row < ROW_LANES; row++)
            if (row < result_state_active)
                factor_write_valid[row] = 1'b1;
    end

    // ------------------------------------------------------------------
    // Vector group launch. SRAM, state and factor reads share one-cycle
    // latency, so their registered outputs align with command metadata.
    // ------------------------------------------------------------------
    logic group_element_launch, group_reduction_launch;
    logic aux_element_launch, aux_reduction_launch;
    logic [ROW_LANES-1:0][VLEN-1:0][FP_WIDTH-1:0] element_b;
    logic [ROW_LANES-1:0][VLEN-1:0][FP_WIDTH-1:0] aux_row_out;
    logic [ROW_LANES-1:0][FP_WIDTH-1:0] aux_reduction_out;
    logic [ROW_LANES-1:0] aux_row_valid, aux_reduction_valid;

    assign group_element_launch = group_read_valid &&
        command_element_q != STALL_V_ELEMENT;
    assign group_reduction_launch = group_read_valid &&
        command_reduction_q != STALL_V_REDUCT;
    assign row0_element_launch = group_element_launch;
    assign aux_element_launch = group_element_launch;
    assign row0_reduction_launch = group_reduction_launch;
    assign aux_reduction_launch = group_reduction_launch;
    assign row0_element_operation = command_element_q;
    assign row0_element_a = group_read_data[0];
    assign row0_element_b = element_b[0];
    assign row0_reduction_operation = command_reduction_q;
    assign row0_reduction_in = group_read_data[0];

    always_comb begin
        element_b = '0;
        for (int row = 0; row < ROW_LANES; row++) begin
            for (int lane = 0; lane < VLEN; lane++) begin
                if (command_element_q == SUB_V_ELEMENT)
                    element_b[row][lane] = state_m_out[row];
                else if (command_element_q == MUL_V_ELEMENT && command_stats_q)
                    element_b[row][lane] = factor_out[row];
                else if (command_element_q == MUL_V_ELEMENT)
                    element_b[row][lane] = command_scalar_q;
            end
        end
    end

    softmax_aux_row_slices #(
        .EXP_WIDTH(EXP_WIDTH), .MANT_WIDTH(MANT_WIDTH), .VLEN(VLEN),
        .ROW_LANES(ROW_LANES)
    ) aux_rows (
        .clk(clk), .rst(rst), .element_valid(aux_element_launch),
        .reduction_valid(aux_reduction_launch),
        .active_rows(command_active_q),
        .element_operation(command_element_q),
        .reduction_operation(command_reduction_q),
        .segment_log2(SEGMENT_LOG2_WIDTH'($clog2(VLEN))),
        .row_a(group_read_data), .row_b(element_b), .row_out(aux_row_out),
        .reduction_out(aux_reduction_out), .row_out_valid(aux_row_valid),
        .reduction_out_valid(aux_reduction_valid)
    );

    logic [GROUP_CTX_WIDTH-1:0] element_ctx_in, element_ctx_out;
    logic element_ctx_ready, element_ctx_valid;
    logic [ADDR_WIDTH-1:0] element_result_vector_base;
    logic [STATE_ADDR_WIDTH-1:0] element_result_state_base;
    logic [ACTIVE_WIDTH-1:0] element_result_active;
    assign element_ctx_in = {
        command_vector_base_q, command_state_base_q, command_active_q
    };
    assign {element_result_vector_base, element_result_state_base,
            element_result_active} = element_ctx_out;
    fifo #(.DATA_WIDTH(GROUP_CTX_WIDTH), .DEPTH(CONTEXT_DEPTH)) element_context_fifo (
        .clk(clk), .rst(rst), .data_in(element_ctx_in),
        .data_in_valid(group_element_launch), .data_in_ready(element_ctx_ready),
        .data_out(element_ctx_out), .data_out_valid(element_ctx_valid),
        .data_out_ready(row0_element_out_valid), .empty(), .full()
    );

    logic [GROUP_CTX_WIDTH-1:0] reduction_ctx_in, reduction_ctx_out;
    logic reduction_ctx_ready, reduction_ctx_valid;
    logic [ADDR_WIDTH-1:0] reduction_result_vector_base;
    logic [STATE_ADDR_WIDTH-1:0] reduction_result_state_base;
    logic [ACTIVE_WIDTH-1:0] reduction_result_active;
    assign reduction_ctx_in = {
        command_vector_base_q, command_state_base_q, command_active_q
    };
    assign {reduction_result_vector_base, reduction_result_state_base,
            reduction_result_active} = reduction_ctx_out;
    fifo #(.DATA_WIDTH(GROUP_CTX_WIDTH), .DEPTH(CONTEXT_DEPTH)) reduction_context_fifo (
        .clk(clk), .rst(rst), .data_in(reduction_ctx_in),
        .data_in_valid(group_reduction_launch), .data_in_ready(reduction_ctx_ready),
        .data_out(reduction_ctx_out), .data_out_valid(reduction_ctx_valid),
        .data_out_ready(row0_reduction_out_valid), .empty(), .full()
    );

    // Element results are buffered because the group-write B port can be
    // momentarily occupied by a Matrix/HBM write.
    logic [ROW_LANES-1:0][VLEN-1:0][FP_WIDTH-1:0] element_result_rows;
    logic [WRITE_FIFO_WIDTH-1:0] write_fifo_in, write_fifo_out;
    logic write_fifo_ready, write_fifo_valid, write_fifo_pop;
    assign element_result_rows[0] = row0_element_out;
    for (genvar row = 1; row < ROW_LANES; row++) begin : collect_aux_rows
        assign element_result_rows[row] = aux_row_out[row];
    end
    assign write_fifo_in = {
        element_result_rows, element_result_vector_base, element_result_active
    };
    fifo #(.DATA_WIDTH(WRITE_FIFO_WIDTH), .DEPTH(4)) group_write_fifo (
        .clk(clk), .rst(rst), .data_in(write_fifo_in),
        .data_in_valid(row0_element_out_valid && element_ctx_valid),
        .data_in_ready(write_fifo_ready), .data_out(write_fifo_out),
        .data_out_valid(write_fifo_valid), .data_out_ready(write_fifo_pop),
        .empty(), .full()
    );
    assign {group_write_data, group_write_addr, group_write_active_rows} =
        write_fifo_out;
    assign group_write_req = write_fifo_valid;
    assign write_fifo_pop = write_fifo_valid && group_write_ready;
    always_comb begin
        group_write_mask = '0;
        for (int row = 0; row < ROW_LANES; row++)
            if (row < group_write_active_rows)
                group_write_mask[row] = {VLEN{1'b1}};
    end

    // A reduction completion commits its scalar result to the statistic bank.
    assign stat_write_en = row0_reduction_out_valid && reduction_ctx_valid;
    assign stat_write_base = reduction_result_state_base;
    assign stat_write_active = reduction_result_active;
    always_comb begin
        stat_write_data = aux_reduction_out;
        stat_write_data[0] = row0_reduction_out;
        stat_write_valid = '0;
        for (int row = 0; row < ROW_LANES; row++)
            if (row < reduction_result_active)
                stat_write_valid[row] = 1'b1;
    end

    assign reduction_done = stat_write_en;
    assign done = write_fifo_pop || reduction_done || state_write_en;

    // ------------------------------------------------------------------
    // Stream and pending-range accounting.
    // ------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            stream_element_operation <= STALL_V_ELEMENT;
            stream_reduction_operation <= STALL_V_REDUCT;
            stream_state_operation <= 1'b0;
            stream_stats_operand <= 1'b0;
            stream_state_phase <= '0;
            in_flight <= '0;
            pending_write_ptr <= '0;
            pending_read_ptr <= '0;
            for (int index = 0; index < CONTEXT_DEPTH; index++) begin
                pending_valid[index] <= 1'b0;
                pending_vector_access[index] <= 1'b0;
                pending_state_access[index] <= 1'b0;
                pending_vector_base[index] <= '0;
                pending_state_base[index] <= '0;
                pending_active_rows[index] <= '0;
            end
        end else begin
            if (accept) begin
                if (in_flight == 0) begin
                    stream_element_operation <= element_operation;
                    stream_reduction_operation <= reduction_operation;
                    stream_state_operation <= state_operation;
                    stream_stats_operand <= stats_operand;
                    stream_state_phase <= state_phase;
                end
                pending_valid[pending_write_ptr] <= 1'b1;
                pending_vector_access[pending_write_ptr] <= current_vector_access;
                pending_state_access[pending_write_ptr] <= current_state_access;
                pending_vector_base[pending_write_ptr] <= vector_base_addr;
                pending_state_base[pending_write_ptr] <=
                    state_base_addr[STATE_ADDR_WIDTH-1:0];
                pending_active_rows[pending_write_ptr] <= active_rows;
                pending_write_ptr <= pending_write_ptr == CONTEXT_DEPTH - 1
                    ? '0 : pending_write_ptr + 1'b1;
            end
            if (done) begin
                pending_valid[pending_read_ptr] <= 1'b0;
                pending_read_ptr <= pending_read_ptr == CONTEXT_DEPTH - 1
                    ? '0 : pending_read_ptr + 1'b1;
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
            $fatal(1, "invalid multi-row active count");
        if (!rst && accept && current_vector_access &&
            vector_base_addr % (ROW_LANES * VLEN))
            $fatal(1, "multi-row vector base is not bank aligned");
        if (!rst && accept && current_state_access &&
            state_base_addr % ROW_LANES)
            $fatal(1, "multi-row state base is not bank aligned");
        if (!rst && state_read_valid && command_state_q && !state_input_ready)
            $fatal(1, "softmax state-input FIFO overflow");
        if (!rst && state_read_valid && command_state_q && !state_ctx_ready)
            $fatal(1, "softmax state-context FIFO overflow");
        // Row zero reuses the production Vector datapaths. Results from the
        // ordinary single-row path are not owned by this engine, so only a
        // result with a matching row-context entry may exercise the row
        // writeback checks below.
        if (!rst && row0_element_out_valid && element_ctx_valid &&
            !write_fifo_ready)
            $fatal(1, "softmax element result lost or write FIFO overflow");
        if (!rst && state_done && !state_ctx_valid)
            $fatal(1, "softmax state context underflow");
        if (!rst && done && in_flight == 0)
            $fatal(1, "softmax completion without an in-flight command");
        if (!rst && row0_element_out_valid && element_ctx_valid) begin
            for (int row = 1; row < ROW_LANES; row++)
                if (row < element_result_active && !aux_row_valid[row])
                    $fatal(1, "softmax row slices completed out of lockstep");
        end
        if (!rst && row0_reduction_out_valid && reduction_ctx_valid) begin
            for (int row = 1; row < ROW_LANES; row++)
                if (row < reduction_result_active && !aux_reduction_valid[row])
                    $fatal(1, "softmax reductions completed out of lockstep");
        end
        if (!rst && state_write_en && result_state_phase != 2) begin
            for (int row = 0; row < ROW_LANES; row++)
                if (row < result_state_active && !simd_valid_out[row])
                    $fatal(1, "softmax state update returned an invalid row");
        end
    end
`endif
endmodule
