`timescale 1ns / 1ps

`include "configuration.svh"
`include "operation.svh"

/*
Module      : Pipeline Control
Timing      : Combinatorial
Description : This module monitors the execution stages of each module and decide whether the pipeline is stalled or not. 
            : This module will also control the overall execution of the coprocessor.
            ：Note: The pipeline stages are listed as follows:
            Control Flow Decode - > INT Register Read -> Check Address Dependencies -> Determine Stall -> Data Preparation -> Execute -> Write Back
            For Vect/Matrix/FP  | Decode | Register Rd | Check      | Determine Stall | Data Prep | Execute | Write Back |
            For INT  Scalar     | Decode | Register Rd | Execute    | Write Back |
*/

module pipeline_control import configuration_pkg::*; import instruction_pkg::*; #(
    parameter   INT_OPERAND_WIDTH       = 5,
    parameter   FP_OPERAND_WIDTH        = 5,
    parameter   INT_DATA_WIDTH          = 32,
    parameter   IMM_WIDTH               = 12
) (
    input       logic clk,
    input       logic rst,

    // Decoded Instruction
    input       OP_BUNDLE       decode_stage_op,

    // Address
    input       logic [INT_DATA_WIDTH - 1 : 0] gp_addr_1,
    input       logic [INT_DATA_WIDTH - 1 : 0] gp_addr_2,

    // Memory Monitor
    input       logic v_sram_wen_a,
    input       logic [INT_DATA_WIDTH - 1 : 0]    v_sram_addr_a,
    input       logic v_sram_wen_b,
    input       logic [INT_DATA_WIDTH - 1 : 0]    v_sram_addr_b,
    input       logic hbm_m_prefetch_in_progress,
    input       logic hbm_v_prefetch_in_progress,
    input       logic continuous_write_to_v_sram,

    // Execution Monitor
    input       MEM_WREQ_INFO   mem_write_req,
    input       logic           hbm_in_used,            
    input       logic           fp_stall_req,
    input       logic           fp_sram_stall_req,
    input       logic [(1 << FP_OPERAND_WIDTH)-1:0] fp_pending_regs,
    input       logic           fp_rob_full,
    input       logic           m_load_in_process,
    input       logic           m_mcu_active,
    input       logic           s_received_v_reduct_result,
    input       logic           softmax_engine_busy,
    input       logic           softmax_execute_ready,
    input       logic           softmax_preview_ready,
    input       logic           packed_pv_busy,

    // Current control operation
    output      logic           pipeline_stall_req,
    output      OP_BUNDLE       exe_stage_op,
    output      OP_BUNDLE       preview_stage_op,
    output      MEM_WEN_INFO    mem_write_control
);

    // Operation Control Decalration
    OP_BUNDLE   reg_rd_stage_op, check_stage_op, determine_stage_op, delayed_reg_rd_stage_op, invalid_op_bubble, recorded_check_stage_op;
    assign invalid_op_bubble = '{
        m_op                : STALL_M,
        v_ele_op            : STALL_V_ELEMENT,
        v_reduct_op         : STALL_V_REDUCT,
        s_fp_op             : STALL_S_FP,
        c_op                : STALL_C,
        h_op                : STALL_H,
        m_transposed_read   : 1'b0,
        v_broadcast_en      : 1'b0,
        fps1                : '0,
        fps2                : '0,
        fpd                 : '0,
        gp_reg1             : '0,
        gp_reg2             : '0,
        gp_rstride          : '0,
        gp_rd               : '0,
        addr_1              : '0,
        addr_2              : '0,
        update_m_waddr      : 1'b0,
        update_v_waddr      : 1'b0,
        v_segment_broadcast_en : 1'b0,
        v_lane_store_en     : 1'b0,
        v_multi_reduction_en : 1'b0,
        v_element_mask_en   : 1'b0,
        v_compact_stats_en  : 1'b0,
        v_compact_count_log2 : 1'b0,
        v_reduction_overwrite_en : 1'b0,
        v_softmax_rows_en    : 1'b0,
        v_softmax_state_en   : 1'b0,
        v_softmax_stats_operand_en : 1'b0,
        v_softmax_state_phase : '0,
        v_softmax_row_log2   : '0,
        v_softmax_active_rows : '0,
        m_packed_acc_en      : 1'b0,
        m_packed_accumulate  : 1'b0,
        m_packed_lane_offset : '0,
        pc_tag              : '0
    };

    import pipeline_pkg::*;
    logic   pipeline_stall;
    logic   stall_for_prefetch;
    logic   mem_vwrite_stall_req;
    logic   b1_pipeline_stall, b2_pipeline_stall, recover_from_stall, p1_recover_from_stall, p2_recover_from_stall, start_of_stall;
    logic   vector_reduct_in_process, tracking_vector_reduct_in_process;
    logic   [INT_DATA_WIDTH - 1 : 0] recorded_gp_addr_1, recorded_gp_addr_2;

    logic   fp_compute_in_exe, fp_compute_in_determine;
    logic   fp_external_producer_in_exe;
    logic   fp_external_producer_in_determine;
    logic   fp_producer_in_determine;
    logic   fp_determine_waw;
    logic   fp_broadcast_raw;
    logic   fp_store_raw;
    logic [FP_OPERAND_WIDTH-1:0] fp_determine_dst;
    logic   softmax_shared_resource_op;
    assign  fp_compute_in_exe       = (exe_stage_op.s_fp_op == ADD_FP)   || (exe_stage_op.s_fp_op == SUB_FP)  ||
                                      (exe_stage_op.s_fp_op == MAX_FP)   || (exe_stage_op.s_fp_op == MUL_FP)  ||
                                      (exe_stage_op.s_fp_op == MV_FP)    || (exe_stage_op.s_fp_op == SQRT_FP) ||
                                      (exe_stage_op.s_fp_op == RECI_FP)  || (exe_stage_op.s_fp_op == EXP_FP)  ||
                                      (exe_stage_op.s_fp_op == RSQRT_FP);
    assign  fp_compute_in_determine = (determine_stage_op.s_fp_op == ADD_FP)   || (determine_stage_op.s_fp_op == SUB_FP)  ||
                                      (determine_stage_op.s_fp_op == MAX_FP)   || (determine_stage_op.s_fp_op == MUL_FP)  ||
                                      (determine_stage_op.s_fp_op == MV_FP)    || (determine_stage_op.s_fp_op == SQRT_FP) ||
                                      (determine_stage_op.s_fp_op == RECI_FP)  || (determine_stage_op.s_fp_op == EXP_FP)  ||
                                      (determine_stage_op.s_fp_op == RSQRT_FP);
    assign fp_external_producer_in_exe =
        (exe_stage_op.v_reduct_op == SUM_V_REDUCT) ||
        (exe_stage_op.v_reduct_op == MAX_V_REDUCT) ||
        (exe_stage_op.v_reduct_op == SUM_SEG_V_REDUCT) ||
        (exe_stage_op.v_reduct_op == MAX_SEG_V_REDUCT) ||
        (exe_stage_op.v_reduct_op == LOAD_LANE_FP_V_REDUCT);
    assign fp_external_producer_in_determine =
        (determine_stage_op.v_reduct_op == SUM_V_REDUCT) ||
        (determine_stage_op.v_reduct_op == MAX_V_REDUCT) ||
        (determine_stage_op.v_reduct_op == SUM_SEG_V_REDUCT) ||
        (determine_stage_op.v_reduct_op == MAX_SEG_V_REDUCT) ||
        (determine_stage_op.v_reduct_op == LOAD_LANE_FP_V_REDUCT);
    assign fp_producer_in_determine = fp_compute_in_determine ||
                                      determine_stage_op.s_fp_op == LD_REG_FP ||
                                      fp_external_producer_in_determine;
    assign fp_determine_dst = fp_external_producer_in_determine
                              ? determine_stage_op.fps2 : determine_stage_op.fpd;
    assign fp_determine_waw = fp_producer_in_determine && fp_determine_dst != '0 &&
        (fp_pending_regs[fp_determine_dst] ||
         (fp_compute_in_exe && exe_stage_op.fpd == fp_determine_dst) ||
         (fp_external_producer_in_exe && exe_stage_op.fps2 == fp_determine_dst));
    assign fp_broadcast_raw = determine_stage_op.s_fp_op == LD_OUT_FP &&
        determine_stage_op.fps2 != '0 &&
        (fp_pending_regs[determine_stage_op.fps2] ||
         (fp_compute_in_exe && exe_stage_op.fpd == determine_stage_op.fps2) ||
         (fp_external_producer_in_exe && exe_stage_op.fps2 == determine_stage_op.fps2));
    assign fp_store_raw = determine_stage_op.s_fp_op == ST_REG_FP &&
        determine_stage_op.fpd != '0 &&
        (fp_pending_regs[determine_stage_op.fpd] ||
         (fp_compute_in_exe && exe_stage_op.fpd == determine_stage_op.fpd) ||
         (fp_external_producer_in_exe && exe_stage_op.fps2 == determine_stage_op.fpd));
    // Integer address updates and control-flow instructions are independent of
    // the row engine and must remain issueable while an AGU wavefront drains.
    // Vector, Matrix, HBM, and Scalar-FP operations share datapaths or SRAM
    // ports and therefore wait for the active row phase.
    assign softmax_shared_resource_op =
        determine_stage_op.m_op != STALL_M ||
        determine_stage_op.v_ele_op != STALL_V_ELEMENT ||
        determine_stage_op.v_reduct_op != STALL_V_REDUCT ||
        determine_stage_op.s_fp_op != STALL_S_FP ||
        determine_stage_op.h_op != STALL_H;

    // Decision for pipeline stall
    always_comb begin
        if (exe_stage_op.v_softmax_rows_en && !softmax_execute_ready) begin
            // Hold the execution-stage instruction until the row engine and
            // the selected SRAM read port accept it.
            pipeline_stall  = 1'b1;
        end else if (determine_stage_op.v_softmax_rows_en &&
                     !softmax_preview_ready) begin
            // Do not advance a dependency, phase change, or bank conflict into
            // execute. Independent groups from one wavefront remain issueable.
            pipeline_stall  = 1'b1;
        end else if (softmax_engine_busy && softmax_shared_resource_op &&
                     !determine_stage_op.v_softmax_rows_en) begin
            // Ordinary Vector/Matrix/HBM operations wait until all row-group
            // writes from the active wavefront have committed.
            pipeline_stall  = 1'b1;
        end else if (packed_pv_busy) begin
            // Packed Matrix writeback owns one read and one write SRAM port.
            pipeline_stall  = 1'b1;
        end else if (hbm_m_prefetch_in_progress & ( determine_stage_op.h_op == PREFETCH_M_H || determine_stage_op.h_op == PREFETCH_M_L)) begin
            // Condition 0: When prefetching instruction is in processed, another prefetching instruction is not allowed.
            pipeline_stall  = 1'b1;            
        end else if (hbm_v_prefetch_in_progress & (determine_stage_op.h_op == PREFETCH_V_H || determine_stage_op.c_op == C_BREAK)) begin
            // Condition 1: When prefetching instruction is in processed, another prefetching instruction is not allowed.
            pipeline_stall  = 1'b1;            
        end else if ((exe_stage_op.m_op == MM_IC) & (determine_stage_op.m_op != STALL_M)) begin
            // Condition 2a-pre: 1-cycle gap before m_load_in_process asserts.
            pipeline_stall  = 1'b1;
        end else if (m_load_in_process & (determine_stage_op.m_op != STALL_M)) begin
            // Condition 2a: M data loading — stall all matrix ops.
            pipeline_stall  = 1'b1;
        end else if (m_mcu_active & ((determine_stage_op.m_op != STALL_M) && (determine_stage_op.m_op != MM_WO))) begin
            // Condition 2b: Systolic draining — allow MM_WO through, stall rest.
            pipeline_stall  = 1'b1;
        end else if ((hbm_v_prefetch_in_progress || continuous_write_to_v_sram) & ( determine_stage_op.v_ele_op != STALL_V_ELEMENT || determine_stage_op.v_reduct_op != STALL_V_REDUCT || (determine_stage_op.m_op != STALL_M && determine_stage_op.m_op != MM_WO && determine_stage_op.m_op != MV_WO))) begin
            // Condition 3: V prefetch/write in progress — stall V and M compute ops, allow MM_WO/MV_WO.
            pipeline_stall  = 1'b1;
        end else if ((mem_write_req.wreq_s_sram_port_a) & (determine_stage_op.v_ele_op != STALL_V_ELEMENT || determine_stage_op.v_reduct_op != STALL_V_REDUCT || determine_stage_op.m_op != STALL_M)) begin
            // Condition 4: Trying to access the vector sram port A while it is being written to.
            pipeline_stall  = 1'b1;            
        end else if ((mem_write_req.wreq_s_sram_port_b) & ( determine_stage_op.v_ele_op != STALL_V_ELEMENT || (determine_stage_op.m_op != STALL_M & determine_stage_op.m_op != MM_WO & determine_stage_op.m_op != MV_WO))) begin
            // Condition 5: Trying to access the vector sram port B while it is being written to.
            pipeline_stall  = 1'b1;            
        end else if ((fp_rob_full && fp_producer_in_determine) || fp_determine_waw ||
                     fp_broadcast_raw || fp_store_raw ||
                     (fp_stall_req && fp_producer_in_determine)) begin
            // Condition 6: the rtl-v3 scalar frontend accepts independent FP
            // operations until its ROB fills. WAW producers are held before
            // execute; ordinary RAW dependencies are captured by the ROB and
            // resolved by completion forwarding. LD_OUT is not a ROB operation,
            // so vector broadcasts/lane stores wait for architectural readiness.
            pipeline_stall  = 1'b1;
        end else if (fp_sram_stall_req & ((determine_stage_op.s_fp_op == LD_REG_FP) || (determine_stage_op.s_fp_op == ST_REG_FP) || (determine_stage_op.s_fp_op == MAP_V_FP))) begin
            // Condition 7: FP SRAM is in continuously load for MAP_V_FP. Hence the current operation cannot access the FP SRAM.
            pipeline_stall  = 1'b1;
        end else if (mem_vwrite_stall_req) begin
            // Unconditionally stall the overall pipeline due to the request from the memory monitor.
            pipeline_stall  = 1'b1;                
        end else begin
            pipeline_stall  = 1'b0;
        end
    end

    assign pipeline_stall_req = pipeline_stall || b1_pipeline_stall; // Extra stall cycle in order to execute the previously unexecuted operation.
    assign preview_stage_op = determine_stage_op;

    // Memory Monitor
    addr_monitor #(
        .ADDR_WIDTH(INT_DATA_WIDTH),
        .PIPELINE_STAGES(MAX_PIPELINE_STAGE)
    ) addr_monitor_inst (
        .clk(clk),
        .rst(rst),
        .determine_stage_op     (check_stage_op),
        .v_sram_addr_a          (v_sram_addr_a),
        .v_sram_addr_b          (v_sram_addr_b),
        .v_sram_wen_a           (v_sram_wen_a),
        .v_sram_wen_b           (v_sram_wen_b),
        .stall_req              (mem_vwrite_stall_req),
        .sys_pipe_stall         (b1_pipeline_stall)
    );

    // Merge the decoded op with the register read outcome.
    always_comb begin
        check_stage_op.m_op            = delayed_reg_rd_stage_op.m_op;
        check_stage_op.v_ele_op        = delayed_reg_rd_stage_op.v_ele_op;
        check_stage_op.v_reduct_op     = delayed_reg_rd_stage_op.v_reduct_op;
        check_stage_op.s_fp_op         = delayed_reg_rd_stage_op.s_fp_op;
        check_stage_op.c_op            = delayed_reg_rd_stage_op.c_op;
        check_stage_op.h_op            = delayed_reg_rd_stage_op.h_op;
        check_stage_op.m_transposed_read = delayed_reg_rd_stage_op.m_transposed_read;
        check_stage_op.v_broadcast_en  = delayed_reg_rd_stage_op.v_broadcast_en;
        check_stage_op.fps1            = delayed_reg_rd_stage_op.fps1;
        check_stage_op.fps2            = delayed_reg_rd_stage_op.fps2;
        check_stage_op.fpd             = delayed_reg_rd_stage_op.fpd;
        check_stage_op.gp_rd           = delayed_reg_rd_stage_op.gp_rd;
        check_stage_op.gp_reg1         = delayed_reg_rd_stage_op.gp_reg1;
        check_stage_op.gp_reg2         = delayed_reg_rd_stage_op.gp_reg2;
        check_stage_op.gp_rstride      = delayed_reg_rd_stage_op.gp_rstride;
        check_stage_op.addr_1          = p2_recover_from_stall ? recorded_gp_addr_1 : gp_addr_1;
        check_stage_op.addr_2          = p2_recover_from_stall ? recorded_gp_addr_2 : gp_addr_2; 
        check_stage_op.update_m_waddr  = delayed_reg_rd_stage_op.update_m_waddr;
        check_stage_op.update_v_waddr  = delayed_reg_rd_stage_op.update_v_waddr;
        check_stage_op.v_segment_broadcast_en = delayed_reg_rd_stage_op.v_segment_broadcast_en;
        check_stage_op.v_lane_store_en = delayed_reg_rd_stage_op.v_lane_store_en;
        check_stage_op.v_multi_reduction_en = delayed_reg_rd_stage_op.v_multi_reduction_en;
        check_stage_op.v_element_mask_en = delayed_reg_rd_stage_op.v_element_mask_en;
        check_stage_op.v_compact_stats_en = delayed_reg_rd_stage_op.v_compact_stats_en;
        check_stage_op.v_compact_count_log2 = delayed_reg_rd_stage_op.v_compact_count_log2;
        check_stage_op.v_reduction_overwrite_en =
            delayed_reg_rd_stage_op.v_reduction_overwrite_en;
        check_stage_op.v_softmax_rows_en =
            delayed_reg_rd_stage_op.v_softmax_rows_en;
        check_stage_op.v_softmax_state_en =
            delayed_reg_rd_stage_op.v_softmax_state_en;
        check_stage_op.v_softmax_stats_operand_en =
            delayed_reg_rd_stage_op.v_softmax_stats_operand_en;
        check_stage_op.v_softmax_state_phase =
            delayed_reg_rd_stage_op.v_softmax_state_phase;
        check_stage_op.v_softmax_row_log2 =
            delayed_reg_rd_stage_op.v_softmax_row_log2;
        check_stage_op.v_softmax_active_rows =
            delayed_reg_rd_stage_op.v_softmax_active_rows;
        check_stage_op.m_packed_acc_en =
            delayed_reg_rd_stage_op.m_packed_acc_en;
        check_stage_op.m_packed_accumulate =
            delayed_reg_rd_stage_op.m_packed_accumulate;
        check_stage_op.m_packed_lane_offset =
            delayed_reg_rd_stage_op.m_packed_lane_offset;
        check_stage_op.pc_tag          = delayed_reg_rd_stage_op.pc_tag;
    end

    assign recover_from_stall = (!pipeline_stall) && b1_pipeline_stall;
    assign start_of_stall = pipeline_stall && !b1_pipeline_stall;
    assign vector_reduct_in_process = tracking_vector_reduct_in_process || (exe_stage_op.v_reduct_op != STALL_V_REDUCT);


    always_ff @(posedge clk) begin
        if (rst) begin
            mem_write_control <= '{
                w_m_sram_en         : 1'b0,
                w_s_sram_port_a_en  : 1'b0,
                w_s_sram_port_b_en  : 1'b0,
                w_from_m            : 1'b0
            };
            b1_pipeline_stall                       <= 1'b0;
            b2_pipeline_stall                       <= 1'b0;
            tracking_vector_reduct_in_process       <= 1'b0;
            recorded_gp_addr_1                      <= 'b0;
            recorded_gp_addr_2                      <= 'b0;
            p1_recover_from_stall                   <= 1'b0;
            p2_recover_from_stall                   <= 1'b0;

        end else begin
            // TODO: temporary solution for the checking dependecy among vector reduction operation and the scalar fp operation.
            if (exe_stage_op.v_reduct_op != STALL_V_REDUCT) begin
                tracking_vector_reduct_in_process <= 1'b1;
            end else if (s_received_v_reduct_result) begin
                tracking_vector_reduct_in_process <= 1'b0;
            end
            
            mem_write_control <= '{
                w_m_sram_en           : mem_write_req.wreq_m_sram,
                w_s_sram_port_a_en    : mem_write_req.wreq_s_sram_port_a,
                w_s_sram_port_b_en    : mem_write_req.wreq_s_sram_port_b,
                w_from_m              : mem_write_req.wreq_from_m
            };

            b1_pipeline_stall <= pipeline_stall;
            b2_pipeline_stall <= b1_pipeline_stall;
            p1_recover_from_stall <= recover_from_stall;
            p2_recover_from_stall <= p1_recover_from_stall;


            if (!b2_pipeline_stall & b1_pipeline_stall) begin
                recorded_gp_addr_1 <= gp_addr_1;
                recorded_gp_addr_2 <= gp_addr_2;
            end

            if (recover_from_stall) begin
                determine_stage_op          <= recorded_check_stage_op;
                exe_stage_op                <= determine_stage_op;
            end else if (start_of_stall) begin
                recorded_check_stage_op     <= check_stage_op;
                delayed_reg_rd_stage_op     <= invalid_op_bubble;
            end else if (!pipeline_stall) begin
                reg_rd_stage_op             <= decode_stage_op;
                delayed_reg_rd_stage_op     <= reg_rd_stage_op;
                determine_stage_op          <= check_stage_op;
                exe_stage_op                <= determine_stage_op;
            end else begin
                exe_stage_op                <= invalid_op_bubble;
            end
            
        end
    end

endmodule
