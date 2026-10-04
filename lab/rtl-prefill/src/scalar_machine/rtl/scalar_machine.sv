`timescale 1ns / 1ps

`include "precision.svh"
`include "configuration.svh"
`include "operation.svh"

/*
Module      : Scalar Machine Module
Timing      : Sequential, all the operations completed in 1 cycle
Description : This module contains two modules:
            : FP ALU for all the fp computation related operations
            : Fixed ALU, only have addition and subtraction operations for address manipulation
Status      : Under Testing
*/

module scalar_machine import precision_pkg::*; import configuration_pkg::*; import instruction_pkg::*; #(
    `ifdef SIMULATION
        // Simulation Purpose
        parameter string FP_MEM_INIT_FILE = "",
        parameter string INT_MEM_INIT_FILE = "",
        parameter string FP_REG_RESULT_FILE = ""
    `endif
) (
    input   logic clk,
    input   logic rst,

    // Control
    input   OP_BUNDLE   exe_stage_op,
    input   S_INT_OP    assigned_int_op,

    // GP Register Control
    input   logic [INT_OPERAND_WIDTH - 1 : 0] rs1,
    input   logic [INT_OPERAND_WIDTH - 1 : 0] rs2,
    input   logic [INT_OPERAND_WIDTH - 1 : 0] rd,

    // Loaded GP Register Value
    input   logic [IMM_WIDTH - 1 : 0]           imm_in,
    output  logic [INT_DATA_WIDTH - 1 : 0]      gp_out_1,
    output  logic [INT_DATA_WIDTH - 1 : 0]      gp_out_2,

    // FP Value input
    input   logic [S_FP_EXP_WIDTH + S_FP_MANT_WIDTH : 0]                external_fp_in,
    input   logic                                                       external_fp_in_valid,
    input   logic [FP_OPERAND_WIDTH - 1 : 0]                            external_fp_wtarget,
    output  logic [S_FP_EXP_WIDTH + S_FP_MANT_WIDTH : 0]                fp_out,
    output  logic [VLEN - 1 : 0] [S_FP_EXP_WIDTH + S_FP_MANT_WIDTH : 0] fp_vector_out,
    output  logic                                                       fp_vector_out_valid,

    // Stall Detection
    output  logic received_v_reduct_result,
    output  logic fp_stall_req,
    output  logic fp_sram_stall_req,
    output  logic [(1 << FP_OPERAND_WIDTH)-1:0] fp_pending_regs,
    output  logic fp_rob_full,
    output  logic [2:0] fp_rob_stall_reason,

    // Loop Control
    input   logic agu_boundary_step,
    input   logic agu_boundary_exit,
    input   logic agu_config_valid,
    input   logic [INT_OPERAND_WIDTH-1:0] agu_config_reg,
    input   logic [IMM_WIDTH-1:0] agu_config_stride,
    input   logic agu_frame_start,
    input   logic [INT_OPERAND_WIDTH-1:0] agu_frame_counter_reg,
    output  logic loop_counter_zero  // From int_alu: loop counter reached 0
);

    import pipeline_pkg::*;
    import configuration_pkg::*;
    localparam FP_SRAM_ADDR_WIDTH       = $clog2(FP_SRAM_DEPTH);
    localparam INT_SRAM_ADDR_WIDTH      = $clog2(INT_SRAM_DEPTH);
    localparam VLEN_COUNTER_WIDTH       = $clog2(VLEN);

    //----------------------------//
    // FP Unit
    //----------------------------//

    S_FP_OP fp_control, exe_fp_control;
    logic [FP_OPERAND_WIDTH - 1 : 0] fp_rs1;
    logic [FP_OPERAND_WIDTH - 1 : 0] fp_rs2;
    logic [FP_OPERAND_WIDTH - 1 : 0] fp_rd, p1_fp_rd, p1_fp_rs2;
    logic [FP_OPERAND_WIDTH - 1 : 0] fp_reg_addr_1, fp_reg_addr_2;
    logic [S_FP_EXP_WIDTH + S_FP_MANT_WIDTH : 0] fp_reg_1, fp_reg_2, fp_ld_from_sram;
    logic [FP_OPERAND_WIDTH - 1 : 0] recorded_fp_waddr_sram;
    logic load_fp_sram_valid, fp_sram_req, fp_sram_wen;
    logic [VLEN_COUNTER_WIDTH : 0] acc_vec_counter;
    logic continuous_load_fp_sram;
    logic [FP_SRAM_ADDR_WIDTH - 1 : 0] fp_sram_addr, recorded_fp_sram_addr;
    logic [MLEN - 1 : 0] [S_FP_EXP_WIDTH + S_FP_MANT_WIDTH : 0] fp_vector_buffer;
    logic fp_read_ready_1, fp_read_ready_2;
    logic fp_retire_valid;
    logic [FP_OPERAND_WIDTH-1:0] fp_retire_rd;
    logic [S_FP_EXP_WIDTH + S_FP_MANT_WIDTH : 0] fp_retire_data;
    logic reserve_external_fp_result;
    logic scalar_compute_issue;

    assign  fp_control = exe_stage_op.s_fp_op;

    assign fp_vector_out = fp_vector_buffer;

    assign scalar_compute_issue = fp_control == ADD_FP || fp_control == SUB_FP ||
                                  fp_control == MAX_FP || fp_control == MUL_FP ||
                                  fp_control == MV_FP || fp_control == SQRT_FP ||
                                  fp_control == RECI_FP || fp_control == EXP_FP ||
                                  fp_control == RSQRT_FP;
    assign reserve_external_fp_result =
        exe_stage_op.v_reduct_op == SUM_V_REDUCT ||
        exe_stage_op.v_reduct_op == MAX_V_REDUCT ||
        exe_stage_op.v_reduct_op == SUM_SEG_V_REDUCT ||
        exe_stage_op.v_reduct_op == MAX_SEG_V_REDUCT ||
        exe_stage_op.v_reduct_op == LOAD_LANE_FP_V_REDUCT;
    // The frontend stalls before a full ROB or a WAW producer reaches execute.
    // Keeping this request asserted while full protects non-FP instructions
    // followed immediately by a scalar producer.
    assign fp_stall_req = fp_rob_full ||
                          (scalar_compute_issue && fp_rd != '0 && fp_pending_regs[fp_rd]);

    always_ff @(posedge clk) begin
        if (rst) begin
            exe_fp_control          <= STALL_S_FP;
            load_fp_sram_valid      <= 1'b0;
            recorded_fp_waddr_sram  <= 'b0;
            p1_fp_rd                <= 'b0;
            p1_fp_rs2               <= 'b0;
            fp_sram_stall_req       <= 1'b0;
            fp_vector_buffer        <= 'b0;
            continuous_load_fp_sram <= 1'b0;
            acc_vec_counter         <= 'b0;
            fp_out                  <= 'b0;
            fp_sram_addr            <= 'b0;
            fp_sram_req             <= 1'b0;
            fp_sram_wen             <= 1'b0;

        end else begin

            p1_fp_rd                <= fp_rd;
            p1_fp_rs2               <= fp_rs2;
            exe_fp_control          <= fp_control;
            load_fp_sram_valid      <= (exe_fp_control == LD_REG_FP) ? 1'b1 : 1'b0;
            recorded_fp_waddr_sram  <= p1_fp_rd;

            if (fp_control == MAP_V_FP) begin
                continuous_load_fp_sram <= 1'b1;
                recorded_fp_sram_addr   <= exe_stage_op.addr_1[FP_SRAM_ADDR_WIDTH - 1 : 0];
                fp_sram_addr            <= exe_stage_op.addr_1[FP_SRAM_ADDR_WIDTH - 1 : 0];
                acc_vec_counter         <= 'b1;
                fp_sram_req             <= 1'b1;
                fp_sram_stall_req       <= 1'b1;
                fp_vector_out_valid     <= 1'b0;  
            end else if (acc_vec_counter == VLEN + 1) begin
                acc_vec_counter         <=  'b0;
                continuous_load_fp_sram <= 1'b0;
                fp_sram_req             <= 1'b0;
                fp_vector_buffer[acc_vec_counter - 2]   <= fp_ld_from_sram;
                fp_vector_out_valid     <= 1'b1;
            end else if (continuous_load_fp_sram) begin
                acc_vec_counter <= acc_vec_counter + 1'b1;
                fp_sram_addr    <= recorded_fp_sram_addr + acc_vec_counter;
                if (acc_vec_counter > 'b1) begin
                    fp_vector_buffer[acc_vec_counter - 2]   <= fp_ld_from_sram;
                end
                fp_sram_req                                 <= 1'b1;
            end else if (fp_vector_out_valid) begin
                fp_sram_stall_req           <= 1'b0;
                fp_vector_buffer            <= 'b0;
                fp_vector_out_valid         <= 1'b0;
            end else begin
                fp_sram_addr <= exe_stage_op.addr_1[FP_SRAM_ADDR_WIDTH - 1 : 0];
                fp_sram_req  <= (fp_control == LD_REG_FP) || (fp_control == ST_REG_FP);
            end

            fp_sram_wen <= (fp_control == ST_REG_FP);

            // Loading fp reg data out.
            if (exe_fp_control == LD_OUT_FP) begin
                fp_out <= fp_reg_2;
            end else begin
                fp_out <= 'b0;
            end
        end
    end

    assign fp_rs1 = exe_stage_op.fps1;
    assign fp_rs2 = exe_stage_op.fps2;
    assign fp_rd  = exe_stage_op.fpd;
    assign fp_reg_addr_1 = (fp_control == ST_REG_FP) ? fp_rd : fp_rs1;
    assign fp_reg_addr_2 = p1_fp_rs2;
    assign received_v_reduct_result = external_fp_in_valid;

    scalar_fp_rob #(
        .EXP_WIDTH(S_FP_EXP_WIDTH),
        .MANT_WIDTH(S_FP_MANT_WIDTH),
        .ROB_DEPTH(8),
        .REG_COUNT(1 << FP_OPERAND_WIDTH)
`ifdef SIMULATION
        , .RESULT_FILE(FP_REG_RESULT_FILE)
`endif
    ) fp_rob (
        .clk(clk),
        .rst(rst),
        .issue_valid(scalar_compute_issue),
        .issue_op(fp_control),
        .issue_rs1(fp_rs1),
        .issue_rs2(fp_rs2),
        .issue_rd(fp_rd),
        .reserve_sram_valid(fp_control == LD_REG_FP),
        .reserve_sram_rd(fp_rd),
        .sram_result_valid(load_fp_sram_valid),
        .sram_result_rd(recorded_fp_waddr_sram),
        .sram_result_data(fp_ld_from_sram),
        .reserve_external_valid(reserve_external_fp_result),
        .reserve_external_rd(exe_stage_op.fps2),
        .external_result_valid(external_fp_in_valid),
        .external_result_rd(external_fp_wtarget),
        .external_result_data(external_fp_in),
        .read_addr_1(fp_reg_addr_1),
        .read_addr_2(fp_reg_addr_2),
        .read_data_1(fp_reg_1),
        .read_data_2(fp_reg_2),
        .read_ready_1(fp_read_ready_1),
        .read_ready_2(fp_read_ready_2),
        .rob_full(fp_rob_full),
        .pending_regs(fp_pending_regs),
        .stall_reason(fp_rob_stall_reason),
        .retire_valid(fp_retire_valid),
        .retire_rd(fp_retire_rd),
        .retire_data(fp_retire_data)
    );
    

    // SRAM for FP
    scalar_sram #(
        .DATA_WIDTH(FP_SRAM_WIDTH),
        .DEPTH(FP_SRAM_DEPTH)
        `ifdef SIMULATION
        , .MemInitFile(FP_MEM_INIT_FILE)
        `endif
    ) fp_scalar_sram (
        .clk            (clk),
        .rst            (rst),
        .req            (fp_sram_req),
        .write_en       (fp_sram_wen),
        .sram_addr      (fp_sram_addr),
        .sram_data_in   (fp_reg_1),
        .sram_data_out  (fp_ld_from_sram)
    );

    //----------------------------//
    // INT Unit
    //----------------------------//

    logic [INT_DATA_WIDTH - 1 : 0] gp_reg_1, gp_reg_2, gp_alu_out, gp_reg_wdata, gp_ld_from_sram, recorded_alu_out, computed_address;
    logic [INT_DATA_WIDTH - 1 : 0] gp_loaded_reg_1, gp_loaded_reg_2;
    logic [INT_DATA_WIDTH - 1 : 0] gp_resolved_reg_1, gp_resolved_reg_2;
    logic gp_reg_wen, gp_write_from_sram_req, p1_gp_write_from_sram_req, gp_alu_valid;
    logic [INT_OPERAND_WIDTH - 1 : 0] gp_reg_waddr, recorded_gp_reg_exe_waddr, p1_recorded_gp_reg_exe_waddr;
    S_INT_OP exe_gp_op;
    logic [INT_OPERAND_WIDTH - 1 : 0] p1_rd, p1_rs1, p1_rs2, p2_rd;
    logic [IMM_WIDTH - 1 : 0] recorded_imm_in;
    logic [INT_DATA_WIDTH - 1 : 0] int_alu_imm_value;
    logic [INT_OPERAND_WIDTH - 1 : 0] gp_reg_addr_1, gp_reg_addr_2;

    generate
        if (INT_DATA_WIDTH > IMM_WIDTH) begin : gen_extend_int_alu_imm
            assign int_alu_imm_value = {{(INT_DATA_WIDTH - IMM_WIDTH){1'b0}}, recorded_imm_in};
        end else if (INT_DATA_WIDTH == IMM_WIDTH) begin : gen_passthrough_int_alu_imm
            assign int_alu_imm_value = recorded_imm_in;
        end else begin : gen_truncate_int_alu_imm
            assign int_alu_imm_value = recorded_imm_in[INT_DATA_WIDTH - 1 : 0];
        end
    endgenerate
    
    always_comb begin
        if (p1_gp_write_from_sram_req) begin
            gp_reg_waddr = p1_recorded_gp_reg_exe_waddr;
            gp_reg_wdata = gp_ld_from_sram;
            gp_reg_wen   = 1'b1;
        end  else begin
            gp_reg_waddr = p2_rd;
            gp_reg_wdata = gp_alu_out;
            gp_reg_wen   = gp_alu_valid;
        end
        gp_reg_1 = ((p1_rs1 == p2_rd) & gp_reg_wen) ? gp_reg_wdata : gp_resolved_reg_1;
        gp_reg_2 = ((p1_rs2 == p2_rd) & gp_reg_wen) ? gp_reg_wdata : gp_resolved_reg_2;

    end

    always_ff @(posedge clk) begin
        if (rst) begin
            recorded_gp_reg_exe_waddr       <= 'b0;
            gp_write_from_sram_req          <= 1'b0;
            p1_gp_write_from_sram_req       <= 1'b0;
            p1_recorded_gp_reg_exe_waddr    <= 'b0;
            exe_gp_op                       <= STALL_S_INT;
            p1_rd                           <= 'b0;
            p2_rd                           <= 'b0;
            p1_rs1                          <= 'b0;
            p1_rs2                          <= 'b0;
            recorded_alu_out                <= 'b0;
            gp_out_1                        <= 'b0;
            gp_out_2                        <= 'b0;
            recorded_imm_in                 <= 'b0;
        end else begin
            exe_gp_op                    <= assigned_int_op;
            recorded_imm_in              <= imm_in;
            // Always capture rd - the write enable (gp_alu_valid) will gate actual writes
            // Conditional capture caused pipeline misalignment with LOOP_DEC operations
            p1_rd                        <= rd;
            p2_rd                        <= p1_rd;
            p1_rs1                       <= rs1;
            p1_rs2                       <= rs2;
            p1_gp_write_from_sram_req    <= gp_write_from_sram_req;
            p1_recorded_gp_reg_exe_waddr <= recorded_gp_reg_exe_waddr;

            if (assigned_int_op == LD_INT) begin
                recorded_gp_reg_exe_waddr    <= rd;
                gp_write_from_sram_req       <= 1'b1;
            end else begin
                gp_write_from_sram_req       <= 1'b0;
            end

            if (exe_gp_op == PASS_ADDR) begin
                if ((gp_reg_waddr == p1_rs1 || gp_reg_waddr == p1_rs2) & gp_reg_wen) begin
                    gp_out_1 <= (gp_reg_waddr == p1_rs1) ? gp_reg_wdata : gp_reg_1;
                    gp_out_2 <= (gp_reg_waddr == p1_rs2) ? gp_reg_wdata : gp_reg_2;
                end else begin
                    gp_out_1 <= gp_reg_1;
                    gp_out_2 <= gp_reg_2;
                end
            end else if (exe_gp_op == PASS_ADDR_2) begin
                if ((gp_reg_waddr == p1_rd || gp_reg_waddr == p1_rs1) & gp_reg_wen) begin
                    gp_out_1 <= (gp_reg_waddr == p1_rs1)  ? gp_reg_wdata : gp_reg_1;
                    gp_out_2 <= (gp_reg_waddr == p1_rd)   ? gp_reg_wdata : gp_reg_2;
                end else begin
                    gp_out_1 <= gp_reg_1;
                    gp_out_2 <= gp_reg_2;
                end
            end else if (exe_gp_op == COMP_ADDR) begin
                gp_out_1                 <= computed_address;
                gp_out_2                 <= 'b0;
            end else if (exe_gp_op == COMP_ADDR_2) begin
                gp_out_1                 <= computed_address;
                gp_out_2                 <= gp_reg_2;
            end else begin
                // Hold the last PASS/COMP result instead of zeroing: the
                // downstream addr merge may sample one cycle late around
                // stall boundaries and must still see the captured value.
                gp_out_1                 <= gp_out_1;
                gp_out_2                 <= gp_out_2;
            end
        end
    end

    assign gp_reg_addr_1 = rs1;
    assign gp_reg_addr_2 = ((assigned_int_op == PASS_ADDR_2) || (assigned_int_op == ST_INT) || (assigned_int_op == MAP_V_FP)) ? rd : rs2;

    loop_agu_state #(
        .DATA_WIDTH(INT_DATA_WIDTH),
        .OPERAND_WIDTH(INT_OPERAND_WIDTH),
        .IMMEDIATE_WIDTH(IMM_WIDTH),
        .STREAM_COUNT(6),
        .LOOP_DEPTH(MAX_LOOP_DEPTH)
    ) loop_agu_state_init (
        .clk(clk),
        .rst(rst),
        .config_valid(agu_config_valid),
        .config_reg(agu_config_reg),
        .config_stride(agu_config_stride),
        .frame_start(agu_frame_start),
        .frame_counter_reg(agu_frame_counter_reg),
        .boundary_step(agu_boundary_step),
        .boundary_exit(agu_boundary_exit),
        .gp_write_valid(gp_reg_wen),
        .gp_write_addr(gp_reg_waddr),
        .gp_read_addr_1(gp_reg_addr_1),
        .gp_read_addr_2(gp_reg_addr_2),
        .gp_base_1(gp_loaded_reg_1),
        .gp_base_2(gp_loaded_reg_2),
        .gp_resolved_1(gp_resolved_reg_1),
        .gp_resolved_2(gp_resolved_reg_2)
    );

    int_alu #(
        .BITWIDTH(INT_DATA_WIDTH)
    ) int_alu_init (
        .clk                (clk),
        .rst                (rst),
        .operand_a          (gp_reg_1),
        .operand_b          (gp_reg_2),
        .imm_value          (int_alu_imm_value),
        .operation          (exe_gp_op),
        .result_valid       (gp_alu_valid),
        .computed_address   (computed_address),
        .result             (gp_alu_out),
        .loop_counter_zero  (loop_counter_zero)
    );

    regfile_2p1w #(
        .BITWIDTH(INT_DATA_WIDTH),
        .DEPTH(1 << INT_OPERAND_WIDTH)
    ) gp_reg_file (
        .clk        (clk),
        .we         (gp_reg_wen),
        .waddr      (gp_reg_waddr),
        .wdata      (gp_reg_wdata),
        .raddr1     (gp_reg_addr_1),
        .raddr2     (gp_reg_addr_2),
        .rdata1     (gp_loaded_reg_1),
        .rdata2     (gp_loaded_reg_2)
    );

    scalar_sram #(
        .DATA_WIDTH     (INT_SRAM_WIDTH),
        .DEPTH          (INT_SRAM_DEPTH)
        `ifdef SIMULATION
            ,
            .MemInitFile(INT_MEM_INIT_FILE)
        `endif
    ) int_scalar_sram (
        .clk(clk),
        .rst(rst),
        .req            ((exe_gp_op == LD_INT) || (exe_gp_op == ST_INT)),
        .write_en       ((exe_gp_op == ST_INT)),
        .sram_addr      (computed_address[INT_SRAM_ADDR_WIDTH - 1 : 0]),
        .sram_data_in   (gp_loaded_reg_2),
        .sram_data_out  (gp_ld_from_sram)
    );

endmodule
