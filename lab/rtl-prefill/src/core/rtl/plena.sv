`timescale 1ns / 1ps

`include "global_define.vh"
`include "precision.svh"
`include "configuration.svh"
`include "operation.svh"
`include "tl_util.svh"


/*
Module      : PLENA Top Module
Status      : Under Development
Description : This module serves as the top level of the PLENA, 
              controlling the dataflow between the instruction decoder, computation units and memory units.
              It currently only supports single batch execution.
*/

module plena import configuration_pkg::*; import instruction_pkg::*; #(
        parameter int NUM_ATTENTION_HEADS = 64,
        parameter int COMPACT_STATS_REQUIRED_SEGMENTS =
            (NUM_ATTENTION_HEADS < (VLEN / HLEN))
                ? NUM_ATTENTION_HEADS
                : (VLEN / HLEN),
        parameter int COMPACT_STATS_LANES =
            (COMPACT_STATS_REQUIRED_SEGMENTS <= 4)  ? 4  :
            (COMPACT_STATS_REQUIRED_SEGMENTS <= 8)  ? 8  :
            (COMPACT_STATS_REQUIRED_SEGMENTS <= 16) ? 16 :
            (COMPACT_STATS_REQUIRED_SEGMENTS <= 32) ? 32 : 64,
        parameter int SOFTMAX_ROW_LANES = 1,
        parameter int SOFTMAX_STATE_HEADS = NUM_ATTENTION_HEADS,
        parameter int SOFTMAX_STATE_ENTRIES = SOFTMAX_STATE_HEADS * MLEN,
        parameter int INSTRUCTION_STORAGE_OFFSET =
            configuration_pkg::INSTRUCTION_STORAGE_OFFSET
    `ifdef SIMULATION
        , parameter string FP_MEM_INIT_FILE       = "",
        parameter string INT_MEM_INIT_FILE      = "",
        parameter string V_SRAM_RESULT_FILE     = "",
        parameter string FP_REG_RESULT_FILE     = ""
    `endif
)(
    input   logic clk,
    input   logic rst,
    output  logic system_break,

    // TileLink Interface for Instruction Memory
    `TL_DECLARE_HOST_PORT(INSTRUCTION_LENGTH, HBM_ADDR_WIDTH, SourceWidth, SinkWidth, instr_mem_tl),
    // HBM Interface 1 for Matrix
    `TL_DECLARE_HOST_PORT(HBM_ELE_WIDTH,    HBM_ADDR_WIDTH, SourceWidth, SinkWidth, m_out_element),
    `TL_DECLARE_HOST_PORT(HBM_SCALE_WIDTH,  HBM_ADDR_WIDTH, SourceWidth, SinkWidth, m_out_scale),
    // HBM Interface 2 for Vector
    `TL_DECLARE_HOST_PORT(HBM_ELE_WIDTH,    HBM_ADDR_WIDTH, SourceWidth, SinkWidth, v_out_element),
    `TL_DECLARE_HOST_PORT(HBM_SCALE_WIDTH,  HBM_ADDR_WIDTH, SourceWidth, SinkWidth, v_out_scale)
);
    // Import Packages
    import precision_pkg::*;

    // Parameter Def
    localparam MATRIX_COUNTER_WIDTH = $clog2(MLEN);
    localparam M_BLOCK_NUM = MLEN / BLOCK_DIM;
    localparam V_BLOCK_NUM = VLEN / BLOCK_DIM;
    localparam VECTOR_SEGMENT_LOG2_WIDTH = $clog2($clog2(VLEN) + 1);
    localparam SOFTMAX_ACTIVE_WIDTH = $clog2(SOFTMAX_ROW_LANES + 1);

    // MX-INT vs MXFP element width selection
    // When MX_INT_ENABLE is set, use integer width; otherwise use MXFP (sign + exp + mant)
    localparam WT_ELEMENT_WIDTH  = WT_MX_INT_ENABLE  ? WT_MX_INT_WIDTH  : (WT_MX_MANT_WIDTH + WT_MX_EXP_WIDTH + 1);
    localparam ACT_ELEMENT_WIDTH = ACT_MX_INT_ENABLE ? ACT_MX_INT_WIDTH : (ACT_MXFP_MANT_WIDTH + ACT_MXFP_EXP_WIDTH + 1);
    localparam KV_ELEMENT_WIDTH  = KV_MX_INT_ENABLE  ? KV_MX_INT_WIDTH  : (KV_MX_MANT_WIDTH + KV_MX_EXP_WIDTH + 1);
    
    // Execution Control
    OP_BUNDLE decode_stage_op, exe_stage_op, preview_stage_op;
    S_INT_OP  assigned_int_op;
    logic pipeline_stall;

`ifdef SIMULATION
    // Debug: expose struct fields for cocotb probing
    logic [$bits(exe_stage_op.m_op)-1:0] dbg_exe_m_op;
    logic [$bits(exe_stage_op.c_op)-1:0] dbg_exe_c_op;
    logic [$bits(decode_stage_op.m_op)-1:0] dbg_dec_m_op;
    assign dbg_exe_m_op = exe_stage_op.m_op;
    assign dbg_exe_c_op = exe_stage_op.c_op;
    assign dbg_dec_m_op = decode_stage_op.m_op;
    logic dbg_complete_v1_load, dbg_complete_v2_load, dbg_complete_loading_q;
    // C_BREAK detection signal for execution clock counting in testbench
    logic c_break_detected;
`endif
    MEM_WEN_INFO mem_write_control;

    // Status Tracking
    logic hbm_in_used;
    logic stall_req_from_fp, fp_sram_stall_req, received_v_reduct_result;
    logic [(1 << FP_OPERAND_WIDTH)-1:0] fp_pending_regs;
    logic fp_rob_full;
    logic [2:0] fp_rob_stall_reason;
    logic m_in_prep, m_mcu_active;
    logic [VECTOR_SEGMENT_LOG2_WIDTH-1:0] vector_reduct_segment_log2;
    logic [6:0] vector_compact_active_lanes;
    logic m_prefetch_data_not_ready, v_prefetch_data_not_ready;
    logic continuous_write_to_v_sram_port_b;

    assign vector_reduct_segment_log2 =
        exe_stage_op.gp_rstride[VECTOR_SEGMENT_LOG2_WIDTH-1:0];
    assign vector_compact_active_lanes =
        exe_stage_op.v_compact_count_log2
            ? (7'd1 << exe_stage_op.gp_rstride[2:0])
            : ({3'b000, exe_stage_op.gp_rstride[3:0]} + 7'd1);

    assign softmax_state_base_addr = exe_stage_op.v_softmax_state_en
        ? exe_stage_op.addr_1
        : (exe_stage_op.v_reduct_op != STALL_V_REDUCT ||
           exe_stage_op.v_softmax_stats_operand_en)
            ? exe_stage_op.addr_2 : exe_stage_op.addr_1;
    assign softmax_resource_ready = softmax_command_ready &&
        (exe_stage_op.v_softmax_state_en || softmax_group_read_ready);
    assign softmax_command_valid = exe_stage_op.v_softmax_rows_en &&
        softmax_resource_ready;
    assign softmax_group_read_req = softmax_command_valid &&
        !exe_stage_op.v_softmax_state_en;

    // Memory Control Signals Declaration
    MEM_WREQ_INFO mem_write_req;

    // Matrix SRAM
    logic [ON_CHIP_ADDR_WIDTH - 1 : 0] m_sram_raddr, m_sram_waddr;
    logic [ON_CHIP_ADDR_WIDTH - 1 : 0] m_waddr, v_waddr;
    logic m_m_valid;
    logic m_v_valid;
    logic m_out_valid;

    // Adds 1 cycle latency on matrix result signaling; pipeline stall logic
    // in pipeline_control absorbs this without functional impact.
    logic m_out_valid_r;
    logic [1:0] m_write_request_r;
    logic [ON_CHIP_ADDR_WIDTH - 1 : 0] m_waddr_r;
    logic [MLEN-1:0][S_FP_EXP_WIDTH + S_FP_MANT_WIDTH:0] m_out_v_fp_r;
    logic m_packed_acc_en, m_packed_accumulate;
    logic [15:0] m_packed_lane_offset;
    logic m_packed_acc_en_r, m_packed_accumulate_r;
    logic [15:0] m_packed_lane_offset_r;
    logic m_sram_wen, m_sram_req, m_sram_transposed_read;
    logic m_prefetch_en;
    logic m_prefetch_en_prev; // For one-shot edge detection

    // HBM Control
    logic hbm_m_prefetch_valid, hbm_m_prefetch_en;
    logic hbm_v_prefetch_valid, hbm_v_prefetch_en;
    logic [MLEN-1:0] [WT_ELEMENT_WIDTH-1:0]                                prefetch_m_element;
    logic [M_BLOCK_NUM-1:0] [MX_SCALE_WIDTH-1:0]                           prefetch_m_scale;
    logic hbm_ready_to_write;
    logic hbm_m_prefetch_in_progress, hbm_v_prefetch_in_progress;
    logic hbm_v_req_prefetch_data;  // hbm_m_req_prefetch_data removed - matrix uses simple pipeline

    // Vector SRAM
    logic [VLEN-1:0] [ACT_ELEMENT_WIDTH-1:0]                                v_high_precision_element_port_b_in;
    logic [VLEN-1:0] [KV_ELEMENT_WIDTH-1:0]                                 v_low_precision_element_port_b_in;
    logic [V_BLOCK_NUM-1:0] [MX_SCALE_WIDTH-1:0]                            v_scale_port_b_in;
    
    // Scalar Machine Control
    logic [IMM_WIDTH - 1 : 0] s_imm;
    logic [INT_OPERAND_WIDTH - 1 : 0] s_rs1,  s_rs2, s_rd;
    logic v_write_request;
    logic [VLEN-1:0] v_write_mask;
    logic [INT_DATA_WIDTH-1:0] vector_mask_reg;
    logic [1:0] m_write_request;

    // Matrix
    logic [MLEN-1:0] [WT_ELEMENT_WIDTH-1:0]                            fetched_m_element;
    logic [MLEN-1:0] [MX_SCALE_WIDTH-1:0]                              fetched_m_scale;
    logic [MLEN-1:0][S_FP_EXP_WIDTH + S_FP_MANT_WIDTH:0]                                        m_out_v_fp;

    // Vector
    logic v_v_a_valid;
    logic v_v_b_valid;
    logic v_s_in_valid;
    logic v_s_out_valid;
    logic v_reduction_complete;

    logic select_write_data_a;
    logic [1:0] select_write_data_b;
    logic v_sram_req_a, v_sram_req_b;
    logic [1:0] v_sram_mxfp_req_b;
    logic v_sram_wen_a, v_sram_wen_b;
    logic [INT_DATA_WIDTH - 1 : 0] v_sram_addr_a, v_sram_addr_b;
    logic [VLEN-1:0] v_sram_mask_a, v_sram_mask_b;

    logic [VLEN-1:0]                [ACT_ELEMENT_WIDTH-1:0]                                     v_high_element_port_b_out;
    logic [VLEN-1:0]                [KV_ELEMENT_WIDTH-1:0]                                      v_low_element_port_b_out;
    logic [V_BLOCK_NUM-1:0]         [MX_SCALE_WIDTH-1:0]                                        v_scale_port_b_out;
    logic [MLEN-1:0]                [ACT_ELEMENT_WIDTH-1:0]                                     v_element_port_a_out;
    logic [M_BLOCK_NUM-1:0]         [MX_SCALE_WIDTH-1:0]                                        v_scale_port_a_out;
    logic v_port_b_high_out_valid;
    logic v_port_b_low_out_valid;

    logic [VLEN-1:0][V_FP_EXP_WIDTH + V_FP_MANT_WIDTH:0]                                v_port_a_out_fp;
    logic [VLEN-1:0][V_FP_EXP_WIDTH + V_FP_MANT_WIDTH:0]                                v_port_b_out_fp;
    logic [VLEN-1:0][V_FP_EXP_WIDTH + V_FP_MANT_WIDTH:0]                                v_out_fp;

    // RTL-v6 row-group and packed-PV SRAM paths.
    logic softmax_command_valid, softmax_command_ready;
    logic softmax_group_read_req, softmax_group_read_ready;
    logic softmax_group_read_valid;
    logic [SOFTMAX_ROW_LANES-1:0][VLEN-1:0]
          [V_FP_EXP_WIDTH + V_FP_MANT_WIDTH:0] softmax_group_read_data;
    logic softmax_group_write_req, softmax_group_write_ready;
    logic [ON_CHIP_ADDR_WIDTH-1:0] softmax_group_write_addr;
    logic [SOFTMAX_ACTIVE_WIDTH-1:0] softmax_group_write_active_rows;
    logic [SOFTMAX_ROW_LANES-1:0][VLEN-1:0]
          [V_FP_EXP_WIDTH + V_FP_MANT_WIDTH:0] softmax_group_write_data;
    logic [SOFTMAX_ROW_LANES-1:0][VLEN-1:0] softmax_group_write_mask;
    logic softmax_busy, softmax_done, softmax_resource_ready;
    logic softmax_preview_ready, softmax_preview_resource_ready;
    logic [ON_CHIP_ADDR_WIDTH-1:0] softmax_state_base_addr;
    logic [ON_CHIP_ADDR_WIDTH-1:0] softmax_preview_state_base_addr;

    assign softmax_preview_state_base_addr =
        preview_stage_op.v_softmax_state_en
            ? preview_stage_op.addr_1
            : (preview_stage_op.v_reduct_op != STALL_V_REDUCT ||
               preview_stage_op.v_softmax_stats_operand_en)
                ? preview_stage_op.addr_2 : preview_stage_op.addr_1;
    assign softmax_preview_resource_ready = softmax_preview_ready &&
        (preview_stage_op.v_softmax_state_en || softmax_group_read_ready);

    logic packed_pv_start, packed_pv_busy, packed_pv_done;
    logic packed_pv_read_req, packed_pv_read_ready, packed_pv_read_valid;
    logic [ON_CHIP_ADDR_WIDTH-1:0] packed_pv_read_addr;
    logic [VLEN-1:0][V_FP_EXP_WIDTH + V_FP_MANT_WIDTH:0] packed_pv_read_data;
    logic packed_pv_write_req, packed_pv_write_ready;
    logic [ON_CHIP_ADDR_WIDTH-1:0] packed_pv_write_addr;
    logic [VLEN-1:0][V_FP_EXP_WIDTH + V_FP_MANT_WIDTH:0] packed_pv_write_data;
    logic [VLEN-1:0] packed_pv_write_mask;
    logic [VLEN-1:0][V_FP_EXP_WIDTH + V_FP_MANT_WIDTH:0] packed_matrix_row;
    logic auxiliary_sram_conflict;

    // Scalar
    logic [V_FP_EXP_WIDTH + V_FP_MANT_WIDTH  : 0] fp_s_in, fp_s_out;
    logic [VLEN-1:0][V_FP_EXP_WIDTH + V_FP_MANT_WIDTH:0]                                fp_s_vector_out;
    logic [INT_DATA_WIDTH - 1 : 0] gp_out_1, gp_out_2;
    logic [FP_OPERAND_WIDTH - 1 : 0] s_wtarget_from_v;
    logic s_map_v_valid;

    // Loop Control
    logic loop_counter_zero;
    logic agu_boundary_step;
    logic agu_boundary_exit;
    logic agu_config_valid;
    logic [INT_OPERAND_WIDTH-1:0] agu_config_reg;
    logic [IMM_WIDTH-1:0] agu_config_stride;
    logic agu_frame_start;
    logic [INT_OPERAND_WIDTH-1:0] agu_frame_counter_reg;

    // Instruction Memory Interface
    logic [PC_ADDR_WIDTH - 1 : 0] decoder_pc;
    logic [INSTRUCTION_LENGTH - 1 : 0] fetched_instruction;
    logic [PC_ADDR_WIDTH - 1 : 0] fetched_instruction_addr;
    logic fetched_instruction_valid;


    // -----------------------------
    // Dataflow & Execution Control
    // -----------------------------
    assign system_break = (exe_stage_op.c_op == BREAK);

    // C_SET_V_MASK_REG captures the GP value routed through addr_2 by
    // PASS_ADDR_2. VectorMachine snapshots this compact HLEN-segment mask with
    // every masked element operation, so a later CSR update cannot affect an
    // in-flight writeback.
    always_ff @(posedge clk) begin
        if (rst) begin
            vector_mask_reg <= '0;
        end else if (exe_stage_op.c_op == SET_V_MASK) begin
            vector_mask_reg <= exe_stage_op.addr_2;
        end
    end

    // TileLink for instruction memory
    `TL_DECLARE(INSTRUCTION_LENGTH, HBM_ADDR_WIDTH, SourceWidth, SinkWidth, instr_tl);
    `TL_BIND_HOST_PORT(instr_mem_tl, instr_tl);

    // Instruction Memory Module
    instr_mem #(
        .INSTRUCTION_WIDTH  (INSTRUCTION_LENGTH),
        .PC_WIDTH           (PC_ADDR_WIDTH),
        .BUFFER_DEPTH       (INST_BUFF_DEPTH),
        .HBM_ADDR_WIDTH     (HBM_ADDR_WIDTH),
        .SourceWidth        (SourceWidth),
        .SinkWidth          (SinkWidth),
        .InstrStorageOffset (INSTRUCTION_STORAGE_OFFSET)  // Use module parameter, not package constant
    ) instr_mem_inst (
        .clk                    (clk),
        .rst                    (rst),
        .pc                     (decoder_pc),
        .instruction_out        (fetched_instruction),
        .instruction_addr       (fetched_instruction_addr),
        .instruction_ready      (fetched_instruction_valid),
        `TL_CONNECT_HOST_PORT   (instr_tl, instr_tl)
    );

    // Frontend
    decoder #(
        .INSTRUCTION_LENGTH         (INSTRUCTION_LENGTH),
        .OPERAND_WIDTH              (OPERAND_WIDTH),
        .OPCODE_WIDTH               (OPCODE_WIDTH),
        .IMM_WIDTH                  (IMM_WIDTH),
        .PC_ADDR_WIDTH              (PC_ADDR_WIDTH)
    ) decoder_init (
        .clk(clk),
        .rst(rst),
        .system_stall_flag          (system_break),
        .pipeline_stall             (pipeline_stall),
        .pc                         (decoder_pc),
        .instruction_from_imem      (fetched_instruction),
        .instruction_addr_from_imem (fetched_instruction_addr),
        .instruction_ready          (fetched_instruction_valid),
        .decode_stage_op            (decode_stage_op),
        .assigned_int_op            (assigned_int_op),
        .rs1                        (s_rs1),
        .rs2                        (s_rs2),
        .rd                         (s_rd),
        .imm                        (s_imm),
        .agu_boundary_step          (agu_boundary_step),
        .agu_boundary_exit          (agu_boundary_exit),
        .agu_config_valid           (agu_config_valid),
        .agu_config_reg             (agu_config_reg),
        .agu_config_stride          (agu_config_stride),
        .agu_frame_start            (agu_frame_start),
        .agu_frame_counter_reg      (agu_frame_counter_reg),
        `ifdef SIMULATION
        .c_break_detected           (c_break_detected),
        `endif
        .loop_counter_zero          (loop_counter_zero)
    );

    pipeline_control #(
        .INT_OPERAND_WIDTH    (INT_OPERAND_WIDTH),
        .FP_OPERAND_WIDTH     (FP_OPERAND_WIDTH),
        .INT_DATA_WIDTH       (INT_DATA_WIDTH),
        .IMM_WIDTH            (IMM_WIDTH)
    ) pipeline_control_init (
        .clk(clk),
        .rst(rst),
        .decode_stage_op                (decode_stage_op),
        .gp_addr_1                      (gp_out_1),
        .gp_addr_2                      (gp_out_2),
        .v_sram_wen_a                   (v_sram_wen_a),
        .v_sram_addr_a                  (v_sram_addr_a),
        .v_sram_wen_b                   (v_sram_wen_b),
        .v_sram_addr_b                  (v_sram_addr_b),
        .hbm_m_prefetch_in_progress     (hbm_m_prefetch_in_progress),
        .hbm_v_prefetch_in_progress     (hbm_v_prefetch_in_progress),
        .continuous_write_to_v_sram     (continuous_write_to_v_sram_port_b),
        .mem_write_req                  (mem_write_req),
        .hbm_in_used                    (hbm_in_used),
        .fp_stall_req                   (stall_req_from_fp),
        .fp_sram_stall_req              (fp_sram_stall_req),
        .fp_pending_regs                (fp_pending_regs),
        .fp_rob_full                    (fp_rob_full),
        .m_load_in_process              (m_in_prep),
        .m_mcu_active                   (m_mcu_active),
        .s_received_v_reduct_result     (v_reduction_complete),
        .softmax_engine_busy            (softmax_busy),
        .softmax_execute_ready          (softmax_resource_ready),
        .softmax_preview_ready          (softmax_preview_resource_ready),
        .packed_pv_busy                 (packed_pv_busy),
        .pipeline_stall_req             (pipeline_stall),
        .exe_stage_op                   (exe_stage_op),
        .preview_stage_op               (preview_stage_op),
        .mem_write_control              (mem_write_control)
    );


    // =========================================================================
    // Boundary registers: matrix_machine → data_flow_control
    // Breaks cross-module routing paths (~9-11 ns) into register-to-register
    // segments. Adds 1 cycle latency on matrix result signaling; the existing
    // pipeline stall mechanism absorbs this without functional impact.
    // =========================================================================
    always_ff @(posedge clk) begin
        if (rst) begin
            m_out_valid_r     <= 1'b0;
            m_write_request_r <= 2'b0;
            m_waddr_r         <= '0;
            m_out_v_fp_r      <= '0;
            m_packed_acc_en_r <= 1'b0;
            m_packed_accumulate_r <= 1'b0;
            m_packed_lane_offset_r <= '0;
        end else begin
            m_out_valid_r     <= m_out_valid;
            m_write_request_r <= m_write_request;
            m_waddr_r         <= m_waddr;
            // Result data must take the same boundary register as its valid:
            // the write-burst FSM keys off m_out_valid_r, so unregistered data
            // skews one row early (first drain row lost, last row written twice).
            m_out_v_fp_r      <= m_out_v_fp;
            m_packed_acc_en_r <= m_packed_acc_en;
            m_packed_accumulate_r <= m_packed_accumulate;
            m_packed_lane_offset_r <= m_packed_lane_offset;
        end
    end

    assign packed_pv_start =
        (m_write_request_r == 2'b01) && m_packed_acc_en_r;

    data_flow_control #(
    ) data_flow_init(
        .clk(clk),
        .rst(rst),
        .exe_stage_op               (exe_stage_op),
        .mem_write_control          (mem_write_control),
        .write_req                  (mem_write_req),
        .m_m_valid                  (m_m_valid),
        .m_v_valid                  (m_v_valid),
        .m_out_valid                (m_out_valid_r),
        .m_load_in_process          (m_in_prep),
        .m_write_request            (packed_pv_start ? 2'b00 : m_write_request_r),
        .m_write_addr               (m_waddr_r),
        .packed_pv_start            (packed_pv_start),
        .packed_pv_done             (packed_pv_done),
        .m_sram_raddr               (m_sram_raddr),
        .m_sram_waddr               (m_sram_waddr),
        .m_sram_wen                 (m_sram_wen),
        .m_sram_req                 (m_sram_req),
        .m_sram_transposed_read     (m_sram_transposed_read),
        .m_prefetch_data_not_ready  (m_prefetch_data_not_ready),
        .v_v_a_valid                (v_v_a_valid),
        .v_v_b_valid                (v_v_b_valid),
        .v_s_in_valid               (v_s_in_valid),
        .v_write_request            (v_write_request),
        .v_write_addr               (v_waddr),
        .v_write_mask               (v_write_mask),
        .s_map_v_valid              (s_map_v_valid),
        .v_sram_req_a               (v_sram_req_a),
        .v_sram_wen_a               (v_sram_wen_a),
        .v_sram_addr_a              (v_sram_addr_a),
        .v_sram_mask_a              (v_sram_mask_a),
        .select_write_data_a        (select_write_data_a),
        .v_sram_mxfp_req_b          (v_sram_mxfp_req_b),
        .v_sram_req_b               (v_sram_req_b),
        .v_sram_wen_b               (v_sram_wen_b),
        .v_sram_addr_b              (v_sram_addr_b),
        .v_sram_mask_b              (v_sram_mask_b),
        .select_write_data_b        (select_write_data_b),
        .v_prefetch_data_not_ready  (v_prefetch_data_not_ready),
        .continuous_write_to_v_sram_port_b (continuous_write_to_v_sram_port_b),
        .prefetch_m_valid           (hbm_m_prefetch_valid),
        .prefetch_v_valid           (hbm_v_prefetch_valid),
        .hbm_ready_to_write         (hbm_ready_to_write),
        // hbm_m_req_prefetch_data removed - matrix uses simple pipeline
        .hbm_v_req_prefetch_data    (hbm_v_req_prefetch_data),
        .hbm_m_prefetch_in_progress (hbm_m_prefetch_in_progress),
        .hbm_v_prefetch_in_progress (hbm_v_prefetch_in_progress)
    );

    // -----------------------------
    // Computation Units
    // -----------------------------
 
    generate;
        // Matrix Compute Unit
        matrix_machine #(
        ) matrix_machine_init (
            .clk(clk),
            .rst(rst),
            .exe_stage_op           (exe_stage_op),
            .mcu_active             (m_mcu_active),
            .m_element              (fetched_m_element),
            .m_scale                (fetched_m_scale),
            .m_valid                (m_m_valid),
            .v_element              (v_element_port_a_out),
            .v_scale                (v_scale_port_a_out),
            .v_valid                (m_v_valid),
            .out_v_fp               (m_out_v_fp),
            .out_valid              (m_out_valid),
            .m_waddr                (m_waddr),
            .m_wreq                 (m_write_request),
            .m_packed_acc_en        (m_packed_acc_en),
            .m_packed_accumulate    (m_packed_accumulate),
            .m_packed_lane_offset   (m_packed_lane_offset)
`ifdef SIMULATION
            ,
            .dbg_complete_v1_load(dbg_complete_v1_load),
            .dbg_complete_v2_load(dbg_complete_v2_load),
            .dbg_complete_loading_q(dbg_complete_loading_q)
`endif
        );

        // Vector Compute Unit
        vector_machine #(
            .COMPACT_STATS_LANES(COMPACT_STATS_LANES),
            .SOFTMAX_ROW_LANES(SOFTMAX_ROW_LANES),
            .SOFTMAX_STATE_ENTRIES(SOFTMAX_STATE_ENTRIES)
        ) vector_machine_init (
            .clk(clk),
            .rst(rst),
            .broadcast_fp2          (exe_stage_op.v_broadcast_en),
            .element_v_control      (exe_stage_op.v_ele_op),
            .reduct_v_control       (exe_stage_op.v_reduct_op),
            .reduct_segment_log2    (vector_reduct_segment_log2),
            .compact_active_lanes   (vector_compact_active_lanes),
            .reduct_segment_index   (exe_stage_op.addr_2[$clog2(VLEN)-1:0]),
            .segment_broadcast_en   (exe_stage_op.v_segment_broadcast_en),
            .compact_stats_en       (exe_stage_op.v_compact_stats_en),
            .reduction_overwrite_en (exe_stage_op.v_reduction_overwrite_en),
            .lane_store_en          (exe_stage_op.v_lane_store_en),
            .vector_mask            (vector_mask_reg),
            .element_mask_enable    (exe_stage_op.v_element_mask_en),
            .softmax_command_valid  (softmax_command_valid),
            .softmax_command_ready  (softmax_command_ready),
            .softmax_state_en       (exe_stage_op.v_softmax_state_en),
            .softmax_stats_operand_en(exe_stage_op.v_softmax_stats_operand_en),
            .softmax_state_phase    (exe_stage_op.v_softmax_state_phase),
            .softmax_active_rows    (
                exe_stage_op.v_softmax_active_rows[SOFTMAX_ACTIVE_WIDTH-1:0]
            ),
            .softmax_vector_base_addr(exe_stage_op.addr_1),
            .softmax_state_base_addr(softmax_state_base_addr),
            .softmax_preview_valid  (preview_stage_op.v_softmax_rows_en),
            .softmax_preview_ready  (softmax_preview_ready),
            .softmax_preview_element_operation(preview_stage_op.v_ele_op),
            .softmax_preview_reduction_operation(preview_stage_op.v_reduct_op),
            .softmax_preview_state_en(preview_stage_op.v_softmax_state_en),
            .softmax_preview_stats_operand_en(
                preview_stage_op.v_softmax_stats_operand_en
            ),
            .softmax_preview_state_phase(
                preview_stage_op.v_softmax_state_phase
            ),
            .softmax_preview_active_rows(
                preview_stage_op.v_softmax_active_rows[SOFTMAX_ACTIVE_WIDTH-1:0]
            ),
            .softmax_preview_vector_base_addr(preview_stage_op.addr_1),
            .softmax_preview_state_base_addr(softmax_preview_state_base_addr),
            .softmax_group_read_valid(softmax_group_read_valid),
            .softmax_group_read_data(softmax_group_read_data),
            .softmax_group_write_req(softmax_group_write_req),
            .softmax_group_write_ready(softmax_group_write_ready),
            .softmax_group_write_addr(softmax_group_write_addr),
            .softmax_group_write_active_rows(softmax_group_write_active_rows),
            .softmax_group_write_data(softmax_group_write_data),
            .softmax_group_write_mask(softmax_group_write_mask),
            .softmax_busy           (softmax_busy),
            .softmax_done           (softmax_done),
            .v_a_in                 (v_port_a_out_fp),
            .v_a_valid              (v_v_a_valid),
            .v_b_in                 (v_port_b_out_fp),
            .v_b_valid              (v_v_b_valid),
            .s_in                   (fp_s_in),
            .s_in_valid             (v_s_in_valid),
            .s_wtarget              (exe_stage_op.fps2),
            .result_waddr           (exe_stage_op.v_lane_store_en ? exe_stage_op.addr_1 : exe_stage_op.addr_2),
            .result_waddr_update    (exe_stage_op.update_v_waddr),
            .v_out                  (v_out_fp),
            .v_waddr                (v_waddr),
            .v_wreq                 (v_write_request),
            .v_wmask                (v_write_mask),
            .s_out                  (fp_s_out),
            .s_out_valid            (v_s_out_valid),
            .s_out_rd               (s_wtarget_from_v),
            .reduction_complete      (v_reduction_complete)
        );

        // Scalar Compute Unit
        scalar_machine #(
            `ifdef SIMULATION
                .FP_MEM_INIT_FILE   (FP_MEM_INIT_FILE),
                .INT_MEM_INIT_FILE  (INT_MEM_INIT_FILE),
                .FP_REG_RESULT_FILE (FP_REG_RESULT_FILE)
            `endif
        ) scalar_machine_init (
            .clk(clk),
            .rst(rst),
            .exe_stage_op               (exe_stage_op),
            .assigned_int_op            (assigned_int_op),
            .rs1                        (s_rs1),
            .rs2                        (s_rs2),
            .rd                         (s_rd),
            .imm_in                     (s_imm),
            .agu_boundary_step           (agu_boundary_step),
            .agu_boundary_exit           (agu_boundary_exit),
            .agu_config_valid            (agu_config_valid),
            .agu_config_reg              (agu_config_reg),
            .agu_config_stride           (agu_config_stride),
            .agu_frame_start             (agu_frame_start),
            .agu_frame_counter_reg       (agu_frame_counter_reg),
            .gp_out_1                   (gp_out_1),
            .gp_out_2                   (gp_out_2),
            .external_fp_in             (fp_s_out),
            .external_fp_in_valid       (v_s_out_valid),
            .external_fp_wtarget        (s_wtarget_from_v),
            .fp_vector_out              (fp_s_vector_out),
            .fp_vector_out_valid        (s_map_v_valid),
            .fp_out                     (fp_s_in),
            .received_v_reduct_result   (received_v_reduct_result),
            .fp_stall_req               (stall_req_from_fp),
            .fp_sram_stall_req          (fp_sram_stall_req),
            .fp_pending_regs            (fp_pending_regs),
            .fp_rob_full                (fp_rob_full),
            .fp_rob_stall_reason        (fp_rob_stall_reason),
            .loop_counter_zero          (loop_counter_zero)
        );
    endgenerate

    always_comb begin
        packed_matrix_row = '0;
        packed_matrix_row[MLEN-1:0] = m_out_v_fp_r;
    end

    packed_pv_writeback #(
        .EXP_WIDTH(V_FP_EXP_WIDTH),
        .MANT_WIDTH(V_FP_MANT_WIDTH),
        .VLEN(VLEN),
        .BLEN(BLEN),
        .ADDR_WIDTH(ON_CHIP_ADDR_WIDTH)
    ) packed_pv_writeback_init (
        .clk(clk),
        .rst(rst),
        .start(packed_pv_start),
        .base_addr(m_waddr_r),
        .accumulate(m_packed_accumulate_r),
        .lane_offset(m_packed_lane_offset_r[$clog2(VLEN)-1:0]),
        .matrix_row_valid(m_out_valid_r && (packed_pv_busy || packed_pv_start)),
        .matrix_row(packed_matrix_row),
        .matrix_row_ready(),
        .sram_read_req(packed_pv_read_req),
        .sram_read_addr(packed_pv_read_addr),
        .sram_read_ready(packed_pv_read_ready),
        .sram_read_valid(packed_pv_read_valid),
        .sram_read_data(packed_pv_read_data),
        .sram_write_req(packed_pv_write_req),
        .sram_write_addr(packed_pv_write_addr),
        .sram_write_data(packed_pv_write_data),
        .sram_write_mask(packed_pv_write_mask),
        .sram_write_ready(packed_pv_write_ready),
        .busy(packed_pv_busy),
        .done(packed_pv_done),
        .accepted_rows(),
        .committed_rows()
    );


    // -----------------------------
    // Memory Units
    // -----------------------------

    // Matrix SRAM — rising-edge pulse for prefetch_en
    logic m_prefetch_en_comb;
    assign m_prefetch_en_comb = (exe_stage_op.h_op == PREFETCH_M_H || exe_stage_op.h_op == PREFETCH_M_L);
    always_ff @(posedge clk) begin
        if (rst) m_prefetch_en_prev <= 1'b0;
        else     m_prefetch_en_prev <= m_prefetch_en_comb;
    end
    assign m_prefetch_en = m_prefetch_en_comb && !m_prefetch_en_prev;
    
    matrix_sram_without_rounding #(
        .WT_MX_EXP_WIDTH    (WT_MX_EXP_WIDTH),
        .WT_MX_MANT_WIDTH   (WT_MX_MANT_WIDTH),
        .WT_MX_INT_ENABLE   (WT_MX_INT_ENABLE),
        .WT_MX_INT_WIDTH    (WT_MX_INT_WIDTH),
        .MX_SCALE_WIDTH     (MX_SCALE_WIDTH),
        .ON_CHIP_ADDR_WIDTH (ON_CHIP_ADDR_WIDTH),
        .MLEN               (MLEN),
        .BLOCK_DIM          (BLOCK_DIM),
        .SRAM_DEPTH         (MATRIX_SRAM_DEPTH),
        .PARALLEL_DIM       (1), // Only 1 is supported for now
        .PREFETCH_AMOUNT    (HBM_M_Prefetch_Amount)
    ) matrix_sram (
        .clk(clk),
        .rst(rst),
        .req                (m_sram_req),
        .transposed_read    (m_sram_transposed_read),
        .sram_raddr         (m_sram_raddr),
        .element_out        (fetched_m_element),
        .scale_out          (fetched_m_scale),
        .wen                (m_sram_wen),
        .sram_waddr         (m_sram_waddr),
        .element_in         (prefetch_m_element),
        .scale_in           (prefetch_m_scale),
        .prefetch_addr      (exe_stage_op.addr_2),
        .prefetch_en        (m_prefetch_en),                // For address Tag.
        .data_not_ready     (m_prefetch_data_not_ready)
    );

    // Vector SRAM
    fp_vector_sram #(
        .ACT_MXFP_EXP_WIDTH     (ACT_MXFP_EXP_WIDTH),
        .ACT_MXFP_MANT_WIDTH    (ACT_MXFP_MANT_WIDTH),
        .WT_MX_EXP_WIDTH        (WT_MX_EXP_WIDTH),
        .WT_MX_MANT_WIDTH       (WT_MX_MANT_WIDTH),
        .KV_MX_EXP_WIDTH        (KV_MX_EXP_WIDTH),
        .KV_MX_MANT_WIDTH       (KV_MX_MANT_WIDTH),
        .MX_SCALE_WIDTH         (MX_SCALE_WIDTH),
        .ACT_MX_INT_ENABLE      (ACT_MX_INT_ENABLE),
        .ACT_MX_INT_WIDTH       (ACT_MX_INT_WIDTH),
        .WT_MX_INT_ENABLE       (WT_MX_INT_ENABLE),
        .WT_MX_INT_WIDTH        (WT_MX_INT_WIDTH),
        .KV_MX_INT_ENABLE       (KV_MX_INT_ENABLE),
        .KV_MX_INT_WIDTH        (KV_MX_INT_WIDTH),
        .EXP_WIDTH              (V_FP_EXP_WIDTH),
        .MANT_WIDTH             (V_FP_MANT_WIDTH),
        .VLEN                   (VLEN),
        .MLEN                   (MLEN),
        .BLEN                   (BLEN),
        .BLOCK_DIM              (BLOCK_DIM),
        .SRAM_DEPTH             (VECTOR_SRAM_DEPTH),
        .ON_CHIP_ADDR_WIDTH     (ON_CHIP_ADDR_WIDTH),
        .PREFETCH_AMOUNT        (HBM_V_Prefetch_Amount),
        .SOFTMAX_ROW_LANES      (SOFTMAX_ROW_LANES)
        `ifdef SIMULATION
            ,
            .MEM_RESULT_FILE    (V_SRAM_RESULT_FILE)
        `endif
    ) vector_sram (
        .clk(clk),
        .rst(rst),
        .select_write_data_a                (select_write_data_a),
        .port_a_req                         (v_sram_req_a),
        .port_a_write_en                    (v_sram_wen_a),
        .port_a_addr                        (v_sram_addr_a),
        .port_a_m_fp_in                     (m_out_v_fp_r),
        .port_a_v_fp_in                     (v_out_fp),
        .port_a_mask_in                     (v_sram_mask_a),
        .port_a_v_fp_out                    (v_port_a_out_fp),
        .port_a_element_out                 (v_element_port_a_out),
        .port_a_scale_out                   (v_scale_port_a_out),
        .port_b_req                         (v_sram_req_b),
        .port_b_write_en                    (v_sram_wen_b),
        .port_b_addr                        (v_sram_addr_b),
        .select_write_data_b                (select_write_data_b),
        .port_b_fp_in                       (fp_s_vector_out),
        .port_b_fp_out                      (v_port_b_out_fp),
        .port_b_mask_in                     (v_sram_mask_b),
        .port_b_high_precision_element_in   (v_high_precision_element_port_b_in),
        .port_b_low_precision_element_in    (v_low_precision_element_port_b_in),
        .port_b_scale_in                    (v_scale_port_b_in),
        .port_b_mxfp_req                    (v_sram_mxfp_req_b),
        .port_b_mxfp_high_out_valid         (v_port_b_high_out_valid),
        .port_b_high_element_out            (v_high_element_port_b_out),
        .port_b_mxfp_low_out_valid          (v_port_b_low_out_valid),
        .port_b_low_element_out             (v_low_element_port_b_out),
        .port_b_scale_out                   (v_scale_port_b_out),
        .group_read_req                     (softmax_group_read_req),
        .group_read_addr                    (exe_stage_op.addr_1),
        .group_read_active_rows             (
            exe_stage_op.v_softmax_active_rows[SOFTMAX_ACTIVE_WIDTH-1:0]
        ),
        .group_read_ready                   (softmax_group_read_ready),
        .group_read_valid                   (softmax_group_read_valid),
        .group_read_data                    (softmax_group_read_data),
        .group_write_req                    (softmax_group_write_req),
        .group_write_addr                   (softmax_group_write_addr),
        .group_write_active_rows            (softmax_group_write_active_rows),
        .group_write_data                   (softmax_group_write_data),
        .group_write_mask                   (softmax_group_write_mask),
        .group_write_ready                  (softmax_group_write_ready),
        .packed_read_req                    (packed_pv_read_req),
        .packed_read_addr                   (packed_pv_read_addr),
        .packed_read_ready                  (packed_pv_read_ready),
        .packed_read_valid                  (packed_pv_read_valid),
        .packed_read_data                   (packed_pv_read_data),
        .packed_write_req                   (packed_pv_write_req),
        .packed_write_addr                  (packed_pv_write_addr),
        .packed_write_data                  (packed_pv_write_data),
        .packed_write_mask                  (packed_pv_write_mask),
        .packed_write_ready                 (packed_pv_write_ready),
        .auxiliary_access_conflict          (auxiliary_sram_conflict),
        .prefetch_en                        (exe_stage_op.h_op == PREFETCH_V_H),
        .prefetch_addr                      (exe_stage_op.addr_2),
        .data_not_ready                     (v_prefetch_data_not_ready)
    );

    // -----------------------------
    // HBM Control & Interface
    // -----------------------------
    
    // TL Declaration
    `TL_DECLARE(HBM_ELE_WIDTH, HBM_ADDR_WIDTH, SourceWidth, SinkWidth, m_element);
    `TL_BIND_HOST_PORT(m_out_element, m_element);
    `TL_DECLARE(HBM_SCALE_WIDTH, HBM_ADDR_WIDTH, SourceWidth, SinkWidth, m_scale);
    `TL_BIND_HOST_PORT(m_out_scale, m_scale);

    `TL_DECLARE(HBM_ELE_WIDTH, HBM_ADDR_WIDTH, SourceWidth, SinkWidth, v_element);
    `TL_BIND_HOST_PORT(v_out_element, v_element);
    `TL_DECLARE(HBM_SCALE_WIDTH, HBM_ADDR_WIDTH, SourceWidth, SinkWidth, v_scale);
    `TL_BIND_HOST_PORT(v_out_scale, v_scale);

    hbm_sys hbm_interface_init (
        .clk(clk),
        .rst(rst),
        .exe_stage_op                           (exe_stage_op),
        // prefetch_m_ready removed - matrix uses simple pipeline
        .prefetch_m_valid                       (hbm_m_prefetch_valid),
        .prefetch_m_element                     (prefetch_m_element),
        .prefetch_m_scale                       (prefetch_m_scale),
        .prefetch_v_ready                       (hbm_v_req_prefetch_data),
        .prefetch_v_valid                       (hbm_v_prefetch_valid),
        .prefetch_v_high_precision_element      (v_high_precision_element_port_b_in),
        .prefetch_v_low_precision_element       (v_low_precision_element_port_b_in),
        .prefetch_v_scale                       (v_scale_port_b_in),
        .hbm_write_high_valid                   (v_port_b_high_out_valid),
        .hbm_write_low_valid                    (v_port_b_low_out_valid),
        .hbm_write_ready                        (hbm_ready_to_write),
        .hbm_write_high_element                 (v_high_element_port_b_out),
        .hbm_write_low_element                  (v_low_element_port_b_out),
        .hbm_write_scale                        (v_scale_port_b_out),
        `TL_CONNECT_HOST_PORT                   (host_m_element, m_element),
        `TL_CONNECT_HOST_PORT                   (host_m_scale, m_scale),
        `TL_CONNECT_HOST_PORT                   (host_v_element, v_element),
        `TL_CONNECT_HOST_PORT                   (host_v_scale, v_scale)
    );

`ifdef SIMULATION
    always_ff @(posedge clk) begin
        if (!rst && softmax_command_valid &&
            (1 << exe_stage_op.v_softmax_row_log2) != SOFTMAX_ROW_LANES)
            $fatal(1, "row opcode tier does not match SOFTMAX_ROW_LANES");
        if (!rst && auxiliary_sram_conflict)
            $fatal(1, "unresolved Vector SRAM auxiliary-port conflict");
    end
`endif

endmodule
