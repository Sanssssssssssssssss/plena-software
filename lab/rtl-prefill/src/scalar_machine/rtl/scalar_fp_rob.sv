`timescale 1ns / 1ps

`include "configuration.svh"
`include "operation.svh"

// In-order scalar-FP issue queue and reorder buffer.
//
// Instructions enter in program order, issue in program order once their
// operands are ready, and retire in program order through one architectural
// register-file write port.  The individual arithmetic pipelines remain
// independent, so unrelated ADD/MUL/SFU chains can overlap.  A completed ROB
// result can be forwarded to a younger instruction before retirement.
module scalar_fp_rob import precision_pkg::*; import instruction_pkg::*; #(
    parameter int EXP_WIDTH = 5,
    parameter int MANT_WIDTH = 10,
    parameter int ROB_DEPTH = 8,
    parameter int REG_COUNT = 16,
`ifdef SIMULATION
    parameter string RESULT_FILE = "",
`endif
    localparam int FP_WIDTH = EXP_WIDTH + MANT_WIDTH + 1,
    localparam int ROB_TAG_WIDTH = $clog2(ROB_DEPTH),
    localparam int ROB_COUNT_WIDTH = $clog2(ROB_DEPTH + 1)
) (
    input  logic clk,
    input  logic rst,

    input  logic issue_valid,
    input  S_FP_OP issue_op,
    input  logic [FP_OPERAND_WIDTH-1:0] issue_rs1,
    input  logic [FP_OPERAND_WIDTH-1:0] issue_rs2,
    input  logic [FP_OPERAND_WIDTH-1:0] issue_rd,

    // Loads and VectorMachine scalar results reserve a ROB destination when
    // their instruction executes, then complete asynchronously here.
    input  logic reserve_sram_valid,
    input  logic [FP_OPERAND_WIDTH-1:0] reserve_sram_rd,
    input  logic sram_result_valid,
    input  logic [FP_OPERAND_WIDTH-1:0] sram_result_rd,
    input  logic [FP_WIDTH-1:0] sram_result_data,
    input  logic reserve_external_valid,
    input  logic [FP_OPERAND_WIDTH-1:0] reserve_external_rd,
    input  logic external_result_valid,
    input  logic [FP_OPERAND_WIDTH-1:0] external_result_rd,
    input  logic [FP_WIDTH-1:0] external_result_data,

    input  logic [FP_OPERAND_WIDTH-1:0] read_addr_1,
    input  logic [FP_OPERAND_WIDTH-1:0] read_addr_2,
    output logic [FP_WIDTH-1:0] read_data_1,
    output logic [FP_WIDTH-1:0] read_data_2,
    output logic read_ready_1,
    output logic read_ready_2,

    output logic rob_full,
    output logic [REG_COUNT-1:0] pending_regs,
    output logic [2:0] stall_reason,
    output logic retire_valid,
    output logic [FP_OPERAND_WIDTH-1:0] retire_rd,
    output logic [FP_WIDTH-1:0] retire_data
);

    localparam logic [2:0] STALL_NONE       = 3'd0;
    localparam logic [2:0] STALL_ROB_FULL   = 3'd1;
    localparam logic [2:0] STALL_DEPENDENCY = 3'd2;
    localparam logic [2:0] STALL_UNIT       = 3'd3;
    localparam logic [2:0] STALL_WAW        = 3'd4;

    typedef enum logic [1:0] {
        ROB_COMPUTE,
        ROB_WAIT_SRAM,
        ROB_WAIT_EXTERNAL
    } ROB_KIND;

    logic [FP_WIDTH-1:0] fp_regs [0:REG_COUNT-1];
    logic rob_valid [0:ROB_DEPTH-1];
    logic rob_issued [0:ROB_DEPTH-1];
    logic rob_ready [0:ROB_DEPTH-1];
    ROB_KIND rob_kind [0:ROB_DEPTH-1];
    S_FP_OP rob_op [0:ROB_DEPTH-1];
    logic [FP_OPERAND_WIDTH-1:0] rob_dst [0:ROB_DEPTH-1];
    logic [FP_OPERAND_WIDTH-1:0] rob_src1 [0:ROB_DEPTH-1];
    logic [FP_OPERAND_WIDTH-1:0] rob_src2 [0:ROB_DEPTH-1];
    logic rob_src1_dep_valid [0:ROB_DEPTH-1];
    logic rob_src2_dep_valid [0:ROB_DEPTH-1];
    logic [ROB_TAG_WIDTH-1:0] rob_src1_dep [0:ROB_DEPTH-1];
    logic [ROB_TAG_WIDTH-1:0] rob_src2_dep [0:ROB_DEPTH-1];
    logic [FP_WIDTH-1:0] rob_result [0:ROB_DEPTH-1];

    logic producer_valid [0:REG_COUNT-1];
    logic [ROB_TAG_WIDTH-1:0] producer_tag [0:REG_COUNT-1];

    logic [ROB_TAG_WIDTH-1:0] rob_head, rob_tail, issue_head;
    logic [ROB_COUNT_WIDTH-1:0] rob_count;

    // Each fully-pipelined arithmetic unit has a tag FIFO.  Data-valid from
    // the leaf pipeline pops the oldest tag and completes that ROB entry.
    logic [ROB_TAG_WIDTH-1:0] add_tags [0:ROB_DEPTH-1];
    logic [ROB_TAG_WIDTH-1:0] mul_tags [0:ROB_DEPTH-1];
    logic [ROB_TAG_WIDTH-1:0] max_tags [0:ROB_DEPTH-1];
    logic [ROB_TAG_WIDTH-1:0] sqrt_tags [0:ROB_DEPTH-1];
    logic sqrt_is_rsqrt [0:ROB_DEPTH-1];
    logic [ROB_TAG_WIDTH-1:0] recip_tags [0:ROB_DEPTH-1];
    logic [ROB_TAG_WIDTH-1:0] exp_tags [0:ROB_DEPTH-1];
    logic [ROB_TAG_WIDTH-1:0] add_q_head, add_q_tail;
    logic [ROB_TAG_WIDTH-1:0] mul_q_head, mul_q_tail;
    logic [ROB_TAG_WIDTH-1:0] max_q_head, max_q_tail;
    logic [ROB_TAG_WIDTH-1:0] sqrt_q_head, sqrt_q_tail;
    logic [ROB_TAG_WIDTH-1:0] recip_q_head, recip_q_tail;
    logic [ROB_TAG_WIDTH-1:0] exp_q_head, exp_q_tail;
    logic [ROB_COUNT_WIDTH-1:0] add_q_count, mul_q_count, max_q_count;
    logic [ROB_COUNT_WIDTH-1:0] sqrt_q_count, recip_q_count, exp_q_count;

    logic [FP_WIDTH-1:0] issue_data_a, issue_data_b;
    logic issue_operands_ready;
    logic issue_unit_ready;
    logic launch_compute;
    logic add_in_valid, mul_in_valid, max_in_valid;
    logic sqrt_in_valid, recip_in_valid, exp_in_valid;
    logic [FP_WIDTH-1:0] add_data_b;
    logic [FP_WIDTH-1:0] add_out, mul_out, max_out;
    logic [FP_WIDTH-1:0] sqrt_out, recip_out, exp_out;
    logic add_out_valid, mul_out_valid, max_out_valid;
    logic sqrt_out_valid, recip_out_valid, exp_out_valid;
    logic rsqrt_handoff;

    function automatic logic [FP_WIDTH-1:0] architectural_value(
        input logic [FP_OPERAND_WIDTH-1:0] addr
    );
        logic [ROB_TAG_WIDTH-1:0] tag;
        begin
            if (addr == '0) begin
                architectural_value = '0;
            end else if (producer_valid[addr]) begin
                tag = producer_tag[addr];
                architectural_value = (rob_valid[tag] && rob_ready[tag])
                                      ? rob_result[tag] : fp_regs[addr];
            end else begin
                architectural_value = fp_regs[addr];
            end
        end
    endfunction

    function automatic logic architectural_ready(
        input logic [FP_OPERAND_WIDTH-1:0] addr
    );
        logic [ROB_TAG_WIDTH-1:0] tag;
        begin
            if (addr == '0 || !producer_valid[addr]) begin
                architectural_ready = 1'b1;
            end else begin
                tag = producer_tag[addr];
                architectural_ready = rob_valid[tag] && rob_ready[tag];
            end
        end
    endfunction

    function automatic logic dependency_ready(
        input logic dep_valid,
        input logic [ROB_TAG_WIDTH-1:0] dep_tag
    );
        dependency_ready = !dep_valid || !rob_valid[dep_tag] || rob_ready[dep_tag];
    endfunction

    function automatic logic [FP_WIDTH-1:0] dependency_value(
        input logic dep_valid,
        input logic [ROB_TAG_WIDTH-1:0] dep_tag,
        input logic [FP_OPERAND_WIDTH-1:0] source
    );
        if (source == '0) begin
            dependency_value = '0;
        end else if (dep_valid && rob_valid[dep_tag]) begin
            dependency_value = rob_result[dep_tag];
        end else begin
            dependency_value = fp_regs[source];
        end
    endfunction

    always_comb begin
        read_data_1 = architectural_value(read_addr_1);
        read_data_2 = architectural_value(read_addr_2);
        read_ready_1 = architectural_ready(read_addr_1);
        read_ready_2 = architectural_ready(read_addr_2);
        for (int reg_idx = 0; reg_idx < REG_COUNT; reg_idx++) begin
            pending_regs[reg_idx] = producer_valid[reg_idx];
        end
    end

    assign rob_full = (rob_count == ROB_DEPTH);

    always_comb begin
        issue_data_a = dependency_value(
            rob_src1_dep_valid[issue_head], rob_src1_dep[issue_head], rob_src1[issue_head]
        );
        issue_data_b = dependency_value(
            rob_src2_dep_valid[issue_head], rob_src2_dep[issue_head], rob_src2[issue_head]
        );
        issue_operands_ready = dependency_ready(
                                   rob_src1_dep_valid[issue_head], rob_src1_dep[issue_head]
                               ) && dependency_ready(
                                   rob_src2_dep_valid[issue_head], rob_src2_dep[issue_head]
                               );

        rsqrt_handoff = sqrt_out_valid && (sqrt_q_count != 0) &&
                        sqrt_is_rsqrt[sqrt_q_head];
        unique case (rob_op[issue_head])
            ADD_FP, SUB_FP: issue_unit_ready = (add_q_count < ROB_DEPTH);
            MUL_FP:         issue_unit_ready = (mul_q_count < ROB_DEPTH);
            MAX_FP:         issue_unit_ready = (max_q_count < ROB_DEPTH);
            SQRT_FP,
            RSQRT_FP:       issue_unit_ready = (sqrt_q_count < ROB_DEPTH);
            RECI_FP:        issue_unit_ready = (recip_q_count < ROB_DEPTH) && !rsqrt_handoff;
            EXP_FP:         issue_unit_ready = (exp_q_count < ROB_DEPTH);
            MV_FP:          issue_unit_ready = 1'b1;
            default:        issue_unit_ready = 1'b0;
        endcase

        launch_compute = rob_valid[issue_head] && !rob_issued[issue_head] &&
                         rob_kind[issue_head] == ROB_COMPUTE &&
                         issue_operands_ready && issue_unit_ready;
        add_in_valid = launch_compute &&
                       (rob_op[issue_head] == ADD_FP || rob_op[issue_head] == SUB_FP);
        mul_in_valid = launch_compute && rob_op[issue_head] == MUL_FP;
        max_in_valid = launch_compute && rob_op[issue_head] == MAX_FP;
        sqrt_in_valid = launch_compute &&
                        (rob_op[issue_head] == SQRT_FP || rob_op[issue_head] == RSQRT_FP);
        recip_in_valid = rsqrt_handoff ||
                         (launch_compute && rob_op[issue_head] == RECI_FP);
        exp_in_valid = launch_compute && rob_op[issue_head] == EXP_FP;
        add_data_b = (rob_op[issue_head] == SUB_FP)
                     ? {~issue_data_b[FP_WIDTH-1], issue_data_b[FP_WIDTH-2:0]}
                     : issue_data_b;

        if (rob_full) begin
            stall_reason = STALL_ROB_FULL;
        end else if (rob_valid[issue_head] && !rob_issued[issue_head] &&
                     !issue_operands_ready) begin
            stall_reason = STALL_DEPENDENCY;
        end else if (rob_valid[issue_head] && !rob_issued[issue_head] &&
                     !issue_unit_ready) begin
            stall_reason = STALL_UNIT;
        end else if (issue_valid && issue_rd != '0 && producer_valid[issue_rd]) begin
            stall_reason = STALL_WAW;
        end else begin
            stall_reason = STALL_NONE;
        end
    end

    fp_fix_adder #(.EXP_WIDTH(EXP_WIDTH), .MANT_WIDTH(MANT_WIDTH)) rob_adder (
        .clk(clk), .rst(rst), .data_in_valid(add_in_valid),
        .data_a(issue_data_a), .data_b(add_data_b),
        .data_out(add_out), .data_out_valid(add_out_valid)
    );
    fp_fix_mult #(.EXP_WIDTH(EXP_WIDTH), .MANT_WIDTH(MANT_WIDTH)) rob_multiplier (
        .clk(clk), .rst(rst), .data_in_valid(mul_in_valid),
        .data_a(issue_data_a), .data_b(issue_data_b),
        .data_out(mul_out), .data_out_valid(mul_out_valid)
    );
    fp_max #(.EXP_WIDTH(EXP_WIDTH), .MANT_WIDTH(MANT_WIDTH)) rob_maximum (
        .clk(clk), .rst(rst), .data_in_valid(max_in_valid),
        .data_a(issue_data_a), .data_b(issue_data_b),
        .data_out(max_out), .data_out_valid(max_out_valid)
    );
    fp_fix_sqrt #(.EXP_WIDTH(EXP_WIDTH), .MANT_WIDTH(MANT_WIDTH)) rob_sqrt (
        .clk(clk), .rst(rst), .data_in_valid(sqrt_in_valid),
        .data_in(issue_data_a), .data_out(sqrt_out), .data_out_valid(sqrt_out_valid)
    );
    fp_fix_reciprocal #(.EXP_WIDTH(EXP_WIDTH), .MANT_WIDTH(MANT_WIDTH)) rob_reciprocal (
        .clk(clk), .rst(rst), .data_in_valid(recip_in_valid),
        .data_in(rsqrt_handoff ? sqrt_out : issue_data_a),
        .data_out(recip_out), .data_out_valid(recip_out_valid)
    );
    fp_fix_exp #(.EXP_WIDTH(EXP_WIDTH), .MANT_WIDTH(MANT_WIDTH)) rob_exponential (
        .clk(clk), .rst(rst), .data_in_valid(exp_in_valid),
        .data_in(issue_data_a), .data_out(exp_out), .data_out_valid(exp_out_valid)
    );

    always_ff @(posedge clk) begin
        if (rst) begin
            rob_head <= '0;
            rob_tail <= '0;
            issue_head <= '0;
            rob_count <= '0;
            add_q_head <= '0; add_q_tail <= '0; add_q_count <= '0;
            mul_q_head <= '0; mul_q_tail <= '0; mul_q_count <= '0;
            max_q_head <= '0; max_q_tail <= '0; max_q_count <= '0;
            sqrt_q_head <= '0; sqrt_q_tail <= '0; sqrt_q_count <= '0;
            recip_q_head <= '0; recip_q_tail <= '0; recip_q_count <= '0;
            exp_q_head <= '0; exp_q_tail <= '0; exp_q_count <= '0;
            retire_valid <= 1'b0;
            retire_rd <= '0;
            retire_data <= '0;
            for (int reg_idx = 0; reg_idx < REG_COUNT; reg_idx++) begin
                fp_regs[reg_idx] <= '0;
                producer_valid[reg_idx] <= 1'b0;
                producer_tag[reg_idx] <= '0;
            end
            for (int rob_idx = 0; rob_idx < ROB_DEPTH; rob_idx++) begin
                rob_valid[rob_idx] <= 1'b0;
                rob_issued[rob_idx] <= 1'b0;
                rob_ready[rob_idx] <= 1'b0;
                rob_kind[rob_idx] <= ROB_COMPUTE;
                rob_op[rob_idx] <= STALL_S_FP;
                rob_dst[rob_idx] <= '0;
                rob_src1[rob_idx] <= '0;
                rob_src2[rob_idx] <= '0;
                rob_src1_dep_valid[rob_idx] <= 1'b0;
                rob_src2_dep_valid[rob_idx] <= 1'b0;
                rob_src1_dep[rob_idx] <= '0;
                rob_src2_dep[rob_idx] <= '0;
                rob_result[rob_idx] <= '0;
                sqrt_is_rsqrt[rob_idx] <= 1'b0;
            end
        end else begin
            logic enqueue;
            logic enqueue_accept;
            logic retire;
            logic [FP_OPERAND_WIDTH-1:0] enqueue_rd;
            ROB_KIND enqueue_kind;
            S_FP_OP enqueue_op;
            logic [FP_OPERAND_WIDTH-1:0] enqueue_rs1, enqueue_rs2;

            retire_valid <= 1'b0;
            retire_rd <= '0;
            retire_data <= '0;
            fp_regs[0] <= '0;

            enqueue = issue_valid || reserve_sram_valid || reserve_external_valid;
            enqueue_kind = issue_valid ? ROB_COMPUTE :
                           reserve_sram_valid ? ROB_WAIT_SRAM : ROB_WAIT_EXTERNAL;
            enqueue_op = issue_valid ? issue_op : STALL_S_FP;
            enqueue_rd = issue_valid ? issue_rd :
                         reserve_sram_valid ? reserve_sram_rd : reserve_external_rd;
            enqueue_rs1 = issue_valid ? issue_rs1 : '0;
            enqueue_rs2 = issue_valid ? issue_rs2 : '0;
            enqueue_accept = enqueue && !rob_full && enqueue_rd != '0 &&
                             !producer_valid[enqueue_rd];
            retire = rob_valid[rob_head] && rob_ready[rob_head];

            if (enqueue_accept) begin
                rob_valid[rob_tail] <= 1'b1;
                rob_issued[rob_tail] <= (enqueue_kind != ROB_COMPUTE);
                rob_ready[rob_tail] <= 1'b0;
                rob_kind[rob_tail] <= enqueue_kind;
                rob_op[rob_tail] <= enqueue_op;
                rob_dst[rob_tail] <= enqueue_rd;
                rob_src1[rob_tail] <= enqueue_rs1;
                rob_src2[rob_tail] <= enqueue_rs2;
                rob_src1_dep_valid[rob_tail] <= (enqueue_rs1 != '0) && producer_valid[enqueue_rs1];
                rob_src2_dep_valid[rob_tail] <= (enqueue_rs2 != '0) && producer_valid[enqueue_rs2];
                rob_src1_dep[rob_tail] <= producer_tag[enqueue_rs1];
                rob_src2_dep[rob_tail] <= producer_tag[enqueue_rs2];
                rob_result[rob_tail] <= '0;
                producer_valid[enqueue_rd] <= 1'b1;
                producer_tag[enqueue_rd] <= rob_tail;
                rob_tail <= rob_tail + 1'b1;
            end

            if (rob_valid[issue_head] && rob_issued[issue_head]) begin
                issue_head <= issue_head + 1'b1;
            end else if (launch_compute) begin
                rob_issued[issue_head] <= 1'b1;
                issue_head <= issue_head + 1'b1;
                unique case (rob_op[issue_head])
                    ADD_FP, SUB_FP: begin
                        add_tags[add_q_tail] <= issue_head;
                        add_q_tail <= add_q_tail + 1'b1;
                    end
                    MUL_FP: begin
                        mul_tags[mul_q_tail] <= issue_head;
                        mul_q_tail <= mul_q_tail + 1'b1;
                    end
                    MAX_FP: begin
                        max_tags[max_q_tail] <= issue_head;
                        max_q_tail <= max_q_tail + 1'b1;
                    end
                    SQRT_FP, RSQRT_FP: begin
                        sqrt_tags[sqrt_q_tail] <= issue_head;
                        sqrt_is_rsqrt[sqrt_q_tail] <= (rob_op[issue_head] == RSQRT_FP);
                        sqrt_q_tail <= sqrt_q_tail + 1'b1;
                    end
                    RECI_FP: begin
                        recip_tags[recip_q_tail] <= issue_head;
                        recip_q_tail <= recip_q_tail + 1'b1;
                    end
                    EXP_FP: begin
                        exp_tags[exp_q_tail] <= issue_head;
                        exp_q_tail <= exp_q_tail + 1'b1;
                    end
                    MV_FP: begin
                        rob_result[issue_head] <= issue_data_a;
                        rob_ready[issue_head] <= 1'b1;
                    end
                    default: begin end
                endcase
            end

            // Push the RSQRT tag into the reciprocal completion queue when
            // sqrt finishes.  This push has priority over a new direct RECI.
            if (rsqrt_handoff) begin
                recip_tags[recip_q_tail] <= sqrt_tags[sqrt_q_head];
                recip_q_tail <= recip_q_tail + 1'b1;
            end

            if (add_out_valid && add_q_count != 0) begin
                rob_result[add_tags[add_q_head]] <= add_out;
                rob_ready[add_tags[add_q_head]] <= 1'b1;
                add_q_head <= add_q_head + 1'b1;
            end
            if (mul_out_valid && mul_q_count != 0) begin
                rob_result[mul_tags[mul_q_head]] <= mul_out;
                rob_ready[mul_tags[mul_q_head]] <= 1'b1;
                mul_q_head <= mul_q_head + 1'b1;
            end
            if (max_out_valid && max_q_count != 0) begin
                rob_result[max_tags[max_q_head]] <= max_out;
                rob_ready[max_tags[max_q_head]] <= 1'b1;
                max_q_head <= max_q_head + 1'b1;
            end
            if (sqrt_out_valid && sqrt_q_count != 0) begin
                if (!sqrt_is_rsqrt[sqrt_q_head]) begin
                    rob_result[sqrt_tags[sqrt_q_head]] <= sqrt_out;
                    rob_ready[sqrt_tags[sqrt_q_head]] <= 1'b1;
                end
                sqrt_q_head <= sqrt_q_head + 1'b1;
            end
            if (recip_out_valid && recip_q_count != 0) begin
                rob_result[recip_tags[recip_q_head]] <= recip_out;
                rob_ready[recip_tags[recip_q_head]] <= 1'b1;
                recip_q_head <= recip_q_head + 1'b1;
            end
            if (exp_out_valid && exp_q_count != 0) begin
                rob_result[exp_tags[exp_q_head]] <= exp_out;
                rob_ready[exp_tags[exp_q_head]] <= 1'b1;
                exp_q_head <= exp_q_head + 1'b1;
            end

            if (sram_result_valid && sram_result_rd != '0 && producer_valid[sram_result_rd]) begin
                rob_result[producer_tag[sram_result_rd]] <= sram_result_data;
                rob_ready[producer_tag[sram_result_rd]] <= 1'b1;
            end
            if (external_result_valid && external_result_rd != '0 &&
                producer_valid[external_result_rd]) begin
                rob_result[producer_tag[external_result_rd]] <= external_result_data;
                rob_ready[producer_tag[external_result_rd]] <= 1'b1;
            end else if (external_result_valid && external_result_rd != '0) begin
                // Preserve the pre-ROB ScalarMachine contract for externally
                // injected values.  Production reductions normally reserve a
                // destination before completion; direct writes are still used
                // by reset/calibration loaders and legacy integration tests.
                fp_regs[external_result_rd] <= external_result_data;
            end

            if (retire) begin
                retire_valid <= 1'b1;
                retire_rd <= rob_dst[rob_head];
                retire_data <= rob_result[rob_head];
                if (rob_dst[rob_head] != '0) begin
                    fp_regs[rob_dst[rob_head]] <= rob_result[rob_head];
                    if (producer_valid[rob_dst[rob_head]] &&
                        producer_tag[rob_dst[rob_head]] == rob_head) begin
                        producer_valid[rob_dst[rob_head]] <= 1'b0;
                    end
                end
                rob_valid[rob_head] <= 1'b0;
                rob_issued[rob_head] <= 1'b0;
                rob_ready[rob_head] <= 1'b0;
                rob_head <= rob_head + 1'b1;
            end

            unique case ({enqueue_accept, retire})
                2'b10: rob_count <= rob_count + 1'b1;
                2'b01: rob_count <= rob_count - 1'b1;
                default: rob_count <= rob_count;
            endcase

            unique case ({add_in_valid, add_out_valid && add_q_count != 0})
                2'b10: add_q_count <= add_q_count + 1'b1;
                2'b01: add_q_count <= add_q_count - 1'b1;
                default: add_q_count <= add_q_count;
            endcase
            unique case ({mul_in_valid, mul_out_valid && mul_q_count != 0})
                2'b10: mul_q_count <= mul_q_count + 1'b1;
                2'b01: mul_q_count <= mul_q_count - 1'b1;
                default: mul_q_count <= mul_q_count;
            endcase
            unique case ({max_in_valid, max_out_valid && max_q_count != 0})
                2'b10: max_q_count <= max_q_count + 1'b1;
                2'b01: max_q_count <= max_q_count - 1'b1;
                default: max_q_count <= max_q_count;
            endcase
            unique case ({sqrt_in_valid, sqrt_out_valid && sqrt_q_count != 0})
                2'b10: sqrt_q_count <= sqrt_q_count + 1'b1;
                2'b01: sqrt_q_count <= sqrt_q_count - 1'b1;
                default: sqrt_q_count <= sqrt_q_count;
            endcase
            unique case ({recip_in_valid, recip_out_valid && recip_q_count != 0})
                2'b10: recip_q_count <= recip_q_count + 1'b1;
                2'b01: recip_q_count <= recip_q_count - 1'b1;
                default: recip_q_count <= recip_q_count;
            endcase
            unique case ({exp_in_valid, exp_out_valid && exp_q_count != 0})
                2'b10: exp_q_count <= exp_q_count + 1'b1;
                2'b01: exp_q_count <= exp_q_count - 1'b1;
                default: exp_q_count <= exp_q_count;
            endcase

`ifdef SIMULATION
            if (enqueue && (rob_full || (enqueue_rd != '0 && producer_valid[enqueue_rd]))) begin
                $fatal(1, "Scalar ROB accepted an un-stalled full/WAW instruction");
            end
            if ((add_out_valid && add_q_count == 0) ||
                (mul_out_valid && mul_q_count == 0) ||
                (max_out_valid && max_q_count == 0) ||
                (sqrt_out_valid && sqrt_q_count == 0) ||
                (recip_out_valid && recip_q_count == 0) ||
                (exp_out_valid && exp_q_count == 0)) begin
                $fatal(1, "Scalar ROB arithmetic result has no matching tag");
            end
`endif
        end
    end

`ifdef SIMULATION
    final begin
        if (RESULT_FILE != "")
            $writememh(RESULT_FILE, fp_regs);
    end
`endif

endmodule
