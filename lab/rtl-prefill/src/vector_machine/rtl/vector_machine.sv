`timescale 1ns / 1ps

`include "precision.svh"
`include "configuration.svh"
`include "operation.svh"


/*
Module      : Vector Machine Module
Timing      : Sequential
Description : This module is the second version of the vector machine based on FP data type.
            : It takes FP of different precision as input, output MX-FP data type.
Status      : Passed Simple Tests
*/

module vector_machine import precision_pkg::*; import configuration_pkg::*; import instruction_pkg::*; #(
    parameter bit COMPACT_STATS_IMPLEMENTED = 1'b1,
    parameter int COMPACT_STATS_LANES = 16,
    parameter bit REDUCTION_OVERWRITE_IMPLEMENTED = 1'b1,
    parameter int SOFTMAX_ROW_LANES = 1,
    parameter int SOFTMAX_STATE_ENTRIES = 16384,
    localparam   ADDR_WIDTH     = ON_CHIP_ADDR_WIDTH,   // Vector write address
    // The signal carries log2(segment_width), not a lane index.  It therefore
    // needs enough bits to encode [0, log2(VLEN)].
    localparam   SEGMENT_LOG2_WIDTH = $clog2($clog2(VLEN) + 1)
) (
    input   logic clk,
    input   logic rst,

    // Control
    input   logic           broadcast_fp2,
    input   V_ELEMENT_OP    element_v_control,
    input   V_REDUCT_OP     reduct_v_control,
    input   logic [SEGMENT_LOG2_WIDTH-1:0] reduct_segment_log2,
    input   logic [6:0] compact_active_lanes,
    input   logic [$clog2(VLEN)-1:0] reduct_segment_index,
    input   logic segment_broadcast_en,
    input   logic compact_stats_en,
    input   logic reduction_overwrite_en,
    input   logic lane_store_en,
    input   logic [INT_DATA_WIDTH-1:0] vector_mask,
    input   logic element_mask_enable,

    // RTL-v6 row-group command and banked-SRAM interface.
    input   logic softmax_command_valid,
    output  logic softmax_command_ready,
    input   logic softmax_state_en,
    input   logic softmax_stats_operand_en,
    input   logic [1:0] softmax_state_phase,
    input   logic [$clog2(SOFTMAX_ROW_LANES + 1)-1:0] softmax_active_rows,
    input   logic [ADDR_WIDTH-1:0] softmax_vector_base_addr,
    input   logic [ADDR_WIDTH-1:0] softmax_state_base_addr,
    input   logic softmax_preview_valid,
    output  logic softmax_preview_ready,
    input   V_ELEMENT_OP softmax_preview_element_operation,
    input   V_REDUCT_OP softmax_preview_reduction_operation,
    input   logic softmax_preview_state_en,
    input   logic softmax_preview_stats_operand_en,
    input   logic [1:0] softmax_preview_state_phase,
    input   logic [$clog2(SOFTMAX_ROW_LANES + 1)-1:0]
                  softmax_preview_active_rows,
    input   logic [ADDR_WIDTH-1:0] softmax_preview_vector_base_addr,
    input   logic [ADDR_WIDTH-1:0] softmax_preview_state_base_addr,
    input   logic softmax_group_read_valid,
    input   logic [SOFTMAX_ROW_LANES-1:0][VLEN-1:0]
                  [(V_FP_MANT_WIDTH + V_FP_EXP_WIDTH):0]
                  softmax_group_read_data,
    output  logic softmax_group_write_req,
    input   logic softmax_group_write_ready,
    output  logic [ADDR_WIDTH-1:0] softmax_group_write_addr,
    output  logic [$clog2(SOFTMAX_ROW_LANES + 1)-1:0]
                  softmax_group_write_active_rows,
    output  logic [SOFTMAX_ROW_LANES-1:0][VLEN-1:0]
                  [(V_FP_MANT_WIDTH + V_FP_EXP_WIDTH):0]
                  softmax_group_write_data,
    output  logic [SOFTMAX_ROW_LANES-1:0][VLEN-1:0]
                  softmax_group_write_mask,
    output  logic softmax_busy,
    output  logic softmax_done,

    // Vector a
    input   logic [VLEN-1:0] [(V_FP_MANT_WIDTH + V_FP_EXP_WIDTH):0]    v_a_in,
    input   logic                   v_a_valid,

    // Vector b
    input   logic [VLEN-1:0] [(V_FP_MANT_WIDTH + V_FP_EXP_WIDTH):0]    v_b_in,
    input   logic                   v_b_valid,

    // Scalar Value
    input   logic [V_FP_EXP_WIDTH + V_FP_MANT_WIDTH : 0] s_in,
    input   logic                                   s_in_valid,
    input   logic [FP_OPERAND_WIDTH - 1 : 0]        s_wtarget,


    // Output
    input   logic [ADDR_WIDTH - 1 : 0] result_waddr,
    input   logic result_waddr_update,

    output  logic [VLEN-1:0] [(V_FP_MANT_WIDTH + V_FP_EXP_WIDTH):0]                 v_out,

    output  logic [ADDR_WIDTH - 1: 0]                                               v_waddr,   
    output  logic                                                                   v_wreq,
    output  logic [VLEN-1:0]                                                        v_wmask,

    output  logic [V_FP_EXP_WIDTH + V_FP_MANT_WIDTH : 0]                            s_out,
    output  logic                                                                   s_out_valid,
    output  logic  [FP_OPERAND_WIDTH - 1 : 0]                                       s_out_rd,
    output  logic                                                                   reduction_complete
);

    import pipeline_pkg::*;

    typedef struct packed {
        logic [ADDR_WIDTH-1:0]             waddr;
        V_ELEMENT_OP                       ele_op;
        V_REDUCT_OP                        red_op;
        logic                              masked;
        logic [INT_DATA_WIDTH-1:0]         mask_bits;
        logic [$clog2(VLEN)-1:0]           lane_index;
    } RECORDED_INFO_TYPE;

    // =====================================================================
    // In-flight op-tracking FIFOs (replace the fixed-latency shift-register taps)
    //
    // Every launched vector op is pushed into a streaming FIFO carrying its
    // {waddr, op}. It is popped (data_out_ready) when that op's result-valid
    // fires, and the popped head supplies the write address / scalar target.
    // This removes the need to size a shift register to
    // VECTOR_LONGEST_OPERATE_CYCLES and tap it at each op's individual latency.
    //
    // Correctness conditions:
    //  1. Results must return in issue order. We pop only on the *head op's own*
    //     result-valid, so an out-of-order completion stalls (visible) rather
    //     than mis-routing a write address (silent). Same-path ops are naturally
    //     in order (the element ALU carries one recorded_operation per type; the
    //     reduction unit is a single in-order pipeline), so the issue side must
    //     not interleave element ops of different latency.
    //  2. fifo.sv presents a freshly-pushed head after a few cycles of fill
    //     latency, so an op's compute latency must exceed that. All ops in use
    //     here are >= 4 cycles (MUL=7, ADD=9, EXP/RECI/SUM/MAX/PREFIX_SCAN >= 4);
    //     the 1-cycle SHIFT_V_LANES path would need separate handling.
    // =====================================================================
    localparam int VM_TRACK_DEPTH = VECTOR_LONGEST_OPERATE_CYCLES;
    localparam int VM_TRACK_W     = $bits(RECORDED_INFO_TYPE);

    // Element-path FIFO
    RECORDED_INFO_TYPE          elem_din, elem_head;
    logic                       elem_push, elem_pop, elem_head_valid, elem_src_valid;

    // Reduction-path FIFO
    RECORDED_INFO_TYPE          red_din, red_head;
    logic                       red_push, red_pop, red_head_valid;

    // Vector Machine Control
    logic recorded_broadcast_en;
    V_ELEMENT_OP recorded_element_v_control;
    V_REDUCT_OP  recorded_reduct_v_control;
    logic [FP_OPERAND_WIDTH - 1:0] recorded_s_wtarget;
    logic [ADDR_WIDTH - 1:0] recorded_result_waddr;
    logic [SEGMENT_LOG2_WIDTH-1:0] recorded_reduct_segment_log2;
    logic [$clog2(VLEN)-1:0] recorded_reduct_segment_index;
    logic recorded_element_mask_enable;
    logic recorded_segment_broadcast_en;
    logic recorded_compact_stats_en;
    logic recorded_reduction_overwrite_en;
    logic effective_reduction_overwrite_en;
    logic [6:0] recorded_compact_active_lanes;
    logic recorded_lane_store_en;
    logic [INT_DATA_WIDTH-1:0] recorded_vector_mask;

    // Loaded Vector Control Flow
    logic v_port_a_valid;
    logic v_port_b_valid;

    // Data Preparation Stage
    logic complete_element_prepare, complete_reduct_prepare;

    logic [VLEN-1:0] [(V_FP_EXP_WIDTH + V_FP_MANT_WIDTH) : 0] prepared_v_a;
    logic [VLEN-1:0] [(V_FP_EXP_WIDTH + V_FP_MANT_WIDTH) : 0] prepared_v_b;
    logic [VLEN-1:0] [(V_FP_EXP_WIDTH + V_FP_MANT_WIDTH) : 0] unpacked_v_s;

    logic s_acc_in_valid;
    logic red_v_in_valid;
    logic [V_FP_EXP_WIDTH + V_FP_MANT_WIDTH : 0] s_acc_in;

    logic element_v_in_a_valid;
    logic element_v_in_b_valid;
    logic element_v_out_valid;
    logic reduction_s_out_valid;
    logic [V_FP_EXP_WIDTH + V_FP_MANT_WIDTH : 0] reduction_s_out;
    logic reduction_v_out_valid;
    logic [VLEN-1:0] [V_FP_EXP_WIDTH + V_FP_MANT_WIDTH : 0] reduction_v_out;
    logic compact_stats_in_valid, compact_stats_out_valid;
    logic [VLEN-1:0] [V_FP_EXP_WIDTH + V_FP_MANT_WIDTH : 0]
        compact_stats_out;
    logic lane_load_out_valid;
    logic [V_FP_EXP_WIDTH + V_FP_MANT_WIDTH : 0] lane_load_out;
    logic lane_load_valid_p1, lane_load_valid_p2;
    logic [V_FP_EXP_WIDTH + V_FP_MANT_WIDTH : 0] lane_load_data_p1, lane_load_data_p2;

    // Ready signals always high (no backpressure)
    logic [VLEN-1:0] [(V_FP_EXP_WIDTH + V_FP_MANT_WIDTH) : 0] element_v_out;
    logic [VLEN-1:0] [(V_FP_MANT_WIDTH + V_FP_EXP_WIDTH):0]   result_v_out;
    logic [VLEN-1:0] [(V_FP_MANT_WIDTH + V_FP_EXP_WIDTH):0]
        p1_result_v_out, p2_result_v_out;
    logic p1_result_valid, p2_result_valid;
    logic [ADDR_WIDTH-1:0] p1_result_waddr, p2_result_waddr;
    logic [VLEN-1:0] result_v_mask, p1_result_v_mask,
                     p2_result_v_mask;
    logic [ADDR_WIDTH-1:0] stored_result_waddr;
    logic compute_result_valid;
    // Assuming the recorded_reduct_v_control and recorded_element_v_control can not have operation at the same time.
    logic [VLEN-1:0] [(V_FP_EXP_WIDTH + V_FP_MANT_WIDTH) : 0] element_in_v_a;
    logic [VLEN-1:0] [(V_FP_EXP_WIDTH + V_FP_MANT_WIDTH) : 0] element_in_v_b;
    logic [VLEN-1:0] [(V_FP_EXP_WIDTH + V_FP_MANT_WIDTH) : 0] reduct_in_v;
    logic [V_FP_EXP_WIDTH + V_FP_MANT_WIDTH : 0] reduct_in_s;

    logic row0_element_launch;
    V_ELEMENT_OP row0_element_operation;
    logic [VLEN-1:0][V_FP_EXP_WIDTH + V_FP_MANT_WIDTH:0]
        row0_element_a, row0_element_b;
    logic row0_reduction_launch;
    V_REDUCT_OP row0_reduction_operation;
    logic [VLEN-1:0][V_FP_EXP_WIDTH + V_FP_MANT_WIDTH:0]
        row0_reduction_in;
    logic [VLEN-1:0][V_FP_EXP_WIDTH + V_FP_MANT_WIDTH:0]
        element_unit_a, element_unit_b;
    logic element_unit_a_valid, element_unit_b_valid;
    V_ELEMENT_OP element_unit_operation;
    logic [VLEN:0][V_FP_EXP_WIDTH + V_FP_MANT_WIDTH:0]
        reduction_unit_input;
    logic reduction_unit_valid;
    V_REDUCT_OP reduction_unit_operation;
    logic softmax_reduction_done;

    assign effective_reduction_overwrite_en =
        REDUCTION_OVERWRITE_IMPLEMENTED && recorded_reduction_overwrite_en;


// Special Extension Definitions
`ifdef HADAMARD_EN
    logic hadamard_transform_in_valid, hadamard_transform_out_valid;
    logic [VLEN-1:0] [(V_FP_EXP_WIDTH + V_FP_MANT_WIDTH) : 0] hadamard_transform_v_in;
    logic [VLEN-1:0] [(V_FP_EXP_WIDTH + V_FP_MANT_WIDTH) : 0] hadamard_transform_v_out;
`endif

`ifdef MAMBA_EXTENSION_EN
    logic prefix_scan_in_valid, prefix_scan_out_valid;
    logic [VLEN-1:0] [(V_FP_EXP_WIDTH + V_FP_MANT_WIDTH) : 0] prefix_scan_v_in;
    logic [VLEN-1:0] [(V_FP_EXP_WIDTH + V_FP_MANT_WIDTH) : 0] prefix_scan_v_out;
`endif

    // V_SHIFT_V is part of the base PLENA ISA and is used by packed-head
    // lowering. Prefix scan remains a Mamba-only extension, but the shift
    // datapath must be present in the default build.
    logic shift_in_valid, shift_out_valid;
    logic [$clog2(VLEN)-1:0] shift_amount;
    logic [VLEN-1:0] [(V_FP_EXP_WIDTH + V_FP_MANT_WIDTH) : 0] shift_v_in;
    logic [VLEN-1:0] [(V_FP_EXP_WIDTH + V_FP_MANT_WIDTH) : 0] shift_v_out;

    always_ff @(posedge clk) begin
        if (rst) begin
            recorded_element_v_control <= STALL_V_ELEMENT;
            recorded_reduct_v_control <= STALL_V_REDUCT;
            recorded_broadcast_en <= 1'b0;
            recorded_s_wtarget <= 'b0;
            recorded_result_waddr <= 'b0;
            recorded_reduct_segment_log2 <= '0;
            recorded_reduct_segment_index <= '0;
            recorded_element_mask_enable <= 1'b0;
            recorded_segment_broadcast_en <= 1'b0;
            recorded_compact_stats_en <= 1'b0;
            recorded_reduction_overwrite_en <= 1'b0;
            recorded_compact_active_lanes <= '0;
            recorded_lane_store_en <= 1'b0;
            recorded_vector_mask <= '0;
        end else begin
            // Set result waddr
            if (result_waddr_update) begin
                recorded_result_waddr <= result_waddr;
            end

            if (element_v_control != STALL_V_ELEMENT) begin
                recorded_element_v_control  <= element_v_control;
                recorded_broadcast_en       <= broadcast_fp2;
                recorded_element_mask_enable <= element_mask_enable;
                recorded_segment_broadcast_en <= segment_broadcast_en;
                recorded_compact_stats_en <= compact_stats_en;
                recorded_compact_active_lanes <= compact_active_lanes;
                recorded_lane_store_en <= lane_store_en;
                recorded_vector_mask         <= vector_mask;
                recorded_reduct_segment_log2 <= reduct_segment_log2;
                recorded_reduct_segment_index <= reduct_segment_index;
            end

            if (reduct_v_control != STALL_V_REDUCT) begin
                recorded_reduct_v_control   <= reduct_v_control;
                recorded_s_wtarget          <= s_wtarget;
                recorded_reduct_segment_log2 <= reduct_segment_log2;
                recorded_reduct_segment_index <= reduct_segment_index;
                recorded_reduction_overwrite_en <= reduction_overwrite_en;
            end
        end
    end

    // =====================================================================
    // Tracking-FIFO push / pop wiring
    // =====================================================================
    // Push on the same condition that used to write pipeline_compute_track[0]
    // (the cycle an op is launched into its datapath). The element/reduction
    // prepare flags are mutually exclusive, so at most one FIFO pushes per cycle.
    assign elem_push = (recorded_element_v_control != STALL_V_ELEMENT) & complete_element_prepare;
    assign red_push  = (recorded_reduct_v_control  != STALL_V_REDUCT)  & complete_reduct_prepare;

    assign elem_din = '{
        waddr  : recorded_result_waddr,
        ele_op : recorded_element_v_control,
        red_op : recorded_reduct_v_control,
        masked : recorded_element_mask_enable,
        mask_bits : recorded_vector_mask,
        lane_index : recorded_reduct_segment_index
    };
    assign red_din = '{
        waddr  : (recorded_reduct_v_control == SUM_SEGS_V_REDUCT ||
                  recorded_reduct_v_control == MAX_SEGS_V_REDUCT)
               ? recorded_result_waddr
               : {{(ADDR_WIDTH - FP_OPERAND_WIDTH){1'b0}}, recorded_s_wtarget},
        ele_op : recorded_element_v_control,
        red_op : recorded_reduct_v_control,
        masked : 1'b0,
        mask_bits : '0,
        lane_index : recorded_reduct_segment_index
    };

    // Pop the head op when its own result-valid fires. elem_src_valid is decoded
    // from the head op type in the output-selection always_comb below.
    assign elem_pop = elem_head_valid & elem_src_valid;
    assign red_pop  = red_head_valid &
                      ((red_head.red_op == SUM_SEGS_V_REDUCT ||
                        red_head.red_op == MAX_SEGS_V_REDUCT)
                       ? reduction_v_out_valid : s_out_valid);
    assign reduction_complete = red_pop || softmax_reduction_done;

    fifo #(
        .DATA_WIDTH (VM_TRACK_W),
        .DEPTH      (VM_TRACK_DEPTH)
    ) elem_track_fifo (
        .clk            (clk),
        .rst            (rst),
        .data_in        (elem_din),
        .data_in_valid  (elem_push),
        .data_in_ready  (),               // depth sized to max in-flight; never full
        .data_out       (elem_head),
        .data_out_valid (elem_head_valid),
        .data_out_ready (elem_pop),
        .empty          (),
        .full           ()
    );

    fifo #(
        .DATA_WIDTH (VM_TRACK_W),
        .DEPTH      (VM_TRACK_DEPTH)
    ) red_track_fifo (
        .clk            (clk),
        .rst            (rst),
        .data_in        (red_din),
        .data_in_valid  (red_push),
        .data_in_ready  (),               // depth sized to max in-flight; never full
        .data_out       (red_head),
        .data_out_valid (red_head_valid),
        .data_out_ready (red_pop),
        .empty          (),
        .full           ()
    );

    always_comb begin
        if (rst) begin
            complete_element_prepare = 1'b0;
            complete_reduct_prepare = 1'b0;
        end else begin

            // FIX: prefix-scan needs only port A
            if ((recorded_element_v_control == PREFIX_SCAN_V_ELEMENT) && v_port_a_valid) begin
                complete_element_prepare    = 1'b1;
                complete_reduct_prepare     = 1'b0;
            end else if ((recorded_element_v_control == SHIFT_V_LANES_ELEMENT) && v_port_a_valid) begin
                complete_element_prepare    = 1'b1;
                complete_reduct_prepare     = 1'b0;
            // Original element ops: need A & B unless broadcasting B from scalar
            end else 
            
            if (((recorded_element_v_control != STALL_V_ELEMENT) & !recorded_broadcast_en & v_port_a_valid & v_port_b_valid) ||
                         ((recorded_element_v_control != STALL_V_ELEMENT) &  recorded_broadcast_en & v_port_a_valid)) begin
                complete_element_prepare    = 1'b1;
                complete_reduct_prepare     = 1'b0;
            end else if ((recorded_reduct_v_control == SUM_SEGS_V_REDUCT ||
                          recorded_reduct_v_control == MAX_SEGS_V_REDUCT ||
                          recorded_reduct_v_control == LOAD_LANE_FP_V_REDUCT) &
                         v_port_a_valid) begin
                complete_element_prepare    = 1'b0;
                complete_reduct_prepare     = 1'b1;
            end else if ((recorded_reduct_v_control != STALL_V_REDUCT) &
                         v_port_a_valid &
                         (s_acc_in_valid || effective_reduction_overwrite_en)) begin
                complete_element_prepare    = 1'b0;
                complete_reduct_prepare     = 1'b1;
            end 
        `ifdef HADAMARD_EN
            else if ((recorded_element_v_control == INNER_HADAMARD_TRANSFORM) & v_port_a_valid) begin
                complete_element_prepare    = 1'b1;
                complete_reduct_prepare     = 1'b0;
            end
        `endif

            else begin
                complete_element_prepare    = 1'b0;
                complete_reduct_prepare     = 1'b0;
            end
        end
    end

    broadcast #(
        .DATA_WIDTH(V_FP_EXP_WIDTH + V_FP_MANT_WIDTH + 1),
        .BROADCAST_DIM(VLEN)
    ) broadcaset_scalar (
        .in_data(s_in),
        .out_data(unpacked_v_s)
    );
    // v_in_valid was being de asserted one clock cycle early so it meant that prepared_v_a couldn't latch onto the
    // v_a_in so it the element wise compute unit would receive an input vector of just 0s. this is for the testing of prefix scan
    // it may be necessary for the other element wise operations? could confirm later with more testing but there may be a more robust
    // workaround.
    // One-cycle delayed valid for prefix-scan only
    logic v_a_valid_d1;
    always_ff @(posedge clk) begin
        if (rst) v_a_valid_d1 <= 1'b0;
        else     v_a_valid_d1 <= v_a_valid;
    end

    wire ps_mode_now = (recorded_element_v_control == PREFIX_SCAN_V_ELEMENT);
    wire shift_mode_now = (recorded_element_v_control == SHIFT_V_LANES_ELEMENT);
// Effective valid into A buffer: PS delayed, otherwise pass-through
    wire v_a_valid_eff = (ps_mode_now|shift_mode_now) ? v_a_valid_d1 : v_a_valid;

    // Vector Port A Storage
    register_slice_wo_hs #(
        .DATA_WIDTH(VLEN * (V_FP_EXP_WIDTH + V_FP_MANT_WIDTH + 1))
    ) v_a_buffer (
        .clk(clk),
        .rst(rst),
        .data_in        (v_a_in),
        .data_in_valid  (v_a_valid),
        .data_out       (prepared_v_a),
        .data_out_valid (v_port_a_valid)
    );

    // Vector Port B Storage
    register_slice_wo_hs #(
        .DATA_WIDTH(VLEN * (V_FP_EXP_WIDTH + V_FP_MANT_WIDTH + 1))
    ) v_b_buffer (
        .clk(clk),
        .rst(rst),
        .data_in        (recorded_broadcast_en ? unpacked_v_s : v_b_in ),
        .data_in_valid  (recorded_broadcast_en ? s_in_valid : v_b_valid),
        .data_out       (prepared_v_b),
        .data_out_valid (v_port_b_valid)
    );

    // Scalar Port Storage (Solely used for Reduction Operation)
    register_slice_wo_hs #(
        .DATA_WIDTH(V_FP_EXP_WIDTH + V_FP_MANT_WIDTH + 1)
    ) s_in_buffer (
        .clk(clk),
        .rst(rst),
        .data_in        (s_in),
        .data_in_valid  ((recorded_reduct_v_control != STALL_V_REDUCT) ? s_in_valid : 1'b0),
        .data_out       (s_acc_in),
        .data_out_valid (s_acc_in_valid)
    );

    always_ff @(posedge clk) begin
        `ifdef HADAMARD_EN
            hadamard_transform_in_valid <= v_port_a_valid & (recorded_element_v_control == INNER_HADAMARD_TRANSFORM);
            hadamard_transform_v_in     <= prepared_v_a;
        `endif

        `ifdef MAMBA_EXTENSION_EN
            prefix_scan_in_valid <= v_port_a_valid & (recorded_element_v_control == PREFIX_SCAN_V_ELEMENT);
            prefix_scan_v_in     <= prepared_v_a;
        `endif
            shift_in_valid       <= v_port_a_valid & (recorded_element_v_control == SHIFT_V_LANES_ELEMENT);
            shift_v_in           <= prepared_v_a;
            // Decoder resolves the integer GP rs2 value into addr_2, which is
            // carried to this input as reduct_segment_index.  s_acc_in is the
            // scalar-FP/reduction port and is not valid for V_SHIFT_V.
            shift_amount         <= recorded_reduct_segment_index;

         // FIX: prefix-scan only needs A
        compact_stats_in_valid <= complete_element_prepare &&
                                  recorded_compact_stats_en;
        if (((recorded_element_v_control != STALL_V_ELEMENT) &&
             (recorded_element_v_control != INNER_HADAMARD_TRANSFORM) &&
             (recorded_element_v_control != PREFIX_SCAN_V_ELEMENT) &&
             (recorded_element_v_control != SHIFT_V_LANES_ELEMENT) &&
             !recorded_compact_stats_en)) begin
            element_v_in_a_valid            <= v_port_a_valid;
            element_v_in_b_valid            <= v_port_b_valid;
            element_in_v_a                  <= prepared_v_a;
            for (int lane = 0; lane < VLEN; lane++) begin
                if (recorded_segment_broadcast_en) begin
                    element_in_v_b[lane] <= prepared_v_b[lane >> recorded_reduct_segment_log2];
                end else begin
                    element_in_v_b[lane] <= prepared_v_b[lane];
                end
            end
        end else begin
            element_v_in_a_valid <= 1'b0;
            element_v_in_b_valid <= 1'b0;
            element_in_v_a       <= 'b0;
            element_in_v_b       <= 'b0;
            reduct_in_v          <= 'b0;
        end

        if (complete_reduct_prepare) begin
            reduct_in_v          <= prepared_v_a;
            red_v_in_valid       <= (recorded_reduct_v_control != LOAD_LANE_FP_V_REDUCT);
        end else begin
            reduct_in_v          <= 'b0;
            red_v_in_valid       <= 1'b0;
        end
        
        reduct_in_s              <= s_acc_in;

    end

    //----------------------------//
    // Elementwise Compute Unit
    //----------------------------//

    assign element_unit_a = row0_element_launch ? row0_element_a : element_in_v_a;
    assign element_unit_b = row0_element_launch ? row0_element_b : element_in_v_b;
    assign element_unit_a_valid = row0_element_launch || element_v_in_a_valid;
    assign element_unit_b_valid = row0_element_launch || element_v_in_b_valid;
    assign element_unit_operation =
        row0_element_launch ? row0_element_operation : recorded_element_v_control;

    fp_elementwise_compute_unit #(
        .EXP_WIDTH(V_FP_EXP_WIDTH),
        .MANT_WIDTH(V_FP_MANT_WIDTH),
        .VLEN(VLEN)
    ) element_unit (
        .clk(clk),
        .rst(rst),
        .v_in_a         (element_unit_a),
        .v_in_a_valid   (element_unit_a_valid),
        .v_in_b         (element_unit_b),
        .v_in_b_valid   (element_unit_b_valid),
        .operation      (element_unit_operation),
        .v_out          (element_v_out),
        .v_out_valid    (element_v_out_valid)
    );


    /*  Elementwise Vector Out Result Selection
        Note: Different vector operations can end and trigger write to the memory at different cycles,
        Here we assume all the vector operations on flight does not have data dependency and can be directly write to memory once it is completed.
        The pipeline control unit will in charge of removing possible data dependency by inserting stall cycles.
        It does not require to wait for the vector operations assigned before it to finish.
        TODO: add other non linear function result selection here.
    */

    always_comb begin
        result_v_out         = 'b0;
        elem_src_valid       = 1'b0;
        stored_result_waddr  = 'b0;

        if (elem_head_valid) begin
            case (elem_head.ele_op)
                ADD_V_ELEMENT, SUB_V_ELEMENT, MUL_V_ELEMENT,
                EXP_V_ELEMENT, RECI_V_ELEMENT, STORE_LANE_FP_V_ELEMENT: begin
                    result_v_out        = element_v_out;
                    elem_src_valid      = element_v_out_valid && !softmax_busy;
                    stored_result_waddr = elem_head.waddr;
                end
                COMPACT_STAT_MUL_V_ELEMENT, COMPACT_STAT_ADD_V_ELEMENT,
                COMPACT_STAT_RSQRT_V_ELEMENT: begin
                    result_v_out        = compact_stats_out;
                    elem_src_valid      = compact_stats_out_valid;
                    stored_result_waddr = elem_head.waddr;
                end
            `ifdef MAMBA_EXTENSION_EN
                PREFIX_SCAN_V_ELEMENT: begin
                    result_v_out        = prefix_scan_v_out;
                    elem_src_valid      = prefix_scan_out_valid;
                    stored_result_waddr = elem_head.waddr;
                end
            `endif
                SHIFT_V_LANES_ELEMENT: begin
                    result_v_out        = shift_v_out;
                    elem_src_valid      = shift_out_valid;
                    stored_result_waddr = elem_head.waddr;
                end
            `ifdef HADAMARD_EN
                INNER_HADAMARD_TRANSFORM: begin
                    result_v_out        = hadamard_transform_v_out;
                    elem_src_valid      = hadamard_transform_out_valid;
                    stored_result_waddr = elem_head.waddr;
                end
            `endif
                default: begin
                    result_v_out        = 'b0;
                    elem_src_valid      = 1'b0;
                    stored_result_waddr = 'b0;
                end
            endcase
        end

        // A result is committed (and the head popped) only when the head op's
        // own datapath raises its valid this cycle.
        compute_result_valid = elem_src_valid;
    end

    always_comb begin
        result_v_mask = {VLEN{1'b1}};
        if (compute_result_valid && elem_head.ele_op == STORE_LANE_FP_V_ELEMENT) begin
            result_v_mask = '0;
            result_v_mask[elem_head.lane_index] = 1'b1;
        end else if (compute_result_valid && elem_head.masked) begin
            for (int lane = 0; lane < VLEN; lane++) begin
                if ((lane / HLEN) < INT_DATA_WIDTH) begin
                    result_v_mask[lane] = elem_head.mask_bits[lane / HLEN];
                end else begin
                    result_v_mask[lane] = 1'b0;
                end
            end
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            p1_result_v_out <= 'b0;
            p2_result_v_out <= 'b0;
            v_out           <= 'b0;
            p1_result_valid <= 1'b0;
            p2_result_valid <= 1'b0;
            p1_result_waddr <= '0;
            p2_result_waddr <= '0;
            p1_result_v_mask <= '0;
            p2_result_v_mask <= '0;
            v_wreq <= 1'b0;
            v_waddr <= '0;
            v_wmask <= '0;
        end else begin
            if (compute_result_valid || reduction_v_out_valid) begin
                p1_result_v_out <= compute_result_valid ? result_v_out : reduction_v_out;
            end else begin
                p1_result_v_out <= 'b0;
            end
            p1_result_valid <= compute_result_valid || reduction_v_out_valid;
            p1_result_waddr <= compute_result_valid
                ? stored_result_waddr : red_head.waddr;
            p1_result_v_mask <= compute_result_valid
                ? result_v_mask : {VLEN{1'b1}};

            p2_result_v_out <= p1_result_v_out;
            p2_result_valid <= p1_result_valid;
            p2_result_waddr <= p1_result_waddr;
            p2_result_v_mask <= p1_result_v_mask;

            v_out           <= p2_result_v_out;
            v_wreq           <= p2_result_valid;
            v_waddr          <= p2_result_waddr;
            v_wmask          <= p2_result_v_mask;
        end
    end

    //----------------------------//
    // Reduction Compute Unit
    //----------------------------//

    assign reduction_unit_input = row0_reduction_launch
        ? {row0_reduction_in, {(V_FP_EXP_WIDTH + V_FP_MANT_WIDTH + 1){1'b0}}}
        : {reduct_in_v, reduct_in_s};
    assign reduction_unit_valid = row0_reduction_launch || red_v_in_valid;
    assign reduction_unit_operation = row0_reduction_launch
        ? row0_reduction_operation : recorded_reduct_v_control;

    fp_reduction_compute_unit #(
        .EXP_WIDTH  (V_FP_EXP_WIDTH),
        .MANT_WIDTH (V_FP_MANT_WIDTH),
        .VLEN       (VLEN)
    ) reduction_unit (
        .clk(clk),
        .rst(rst),
        .v_in           (reduction_unit_input),
        .v_in_valid     (reduction_unit_valid),
        .operation      (reduction_unit_operation),
        .overwrite      (row0_reduction_launch ? 1'b1 : effective_reduction_overwrite_en),
        .segment_log2   (recorded_reduct_segment_log2),
        .segment_index  (recorded_reduct_segment_index),
        .s_out          (reduction_s_out),
        .s_out_valid    (reduction_s_out_valid),
        .v_out          (reduction_v_out),
        .v_out_valid    (reduction_v_out_valid)
    );

    softmax_row_engine #(
        .EXP_WIDTH(V_FP_EXP_WIDTH),
        .MANT_WIDTH(V_FP_MANT_WIDTH),
        .VLEN(VLEN),
        .ROW_LANES(SOFTMAX_ROW_LANES),
        .STATE_ENTRIES(SOFTMAX_STATE_ENTRIES),
        .ADDR_WIDTH(ADDR_WIDTH)
    ) softmax_rows (
        .clk(clk),
        .rst(rst),
        .command_valid(softmax_command_valid),
        .command_ready(softmax_command_ready),
        .element_operation(element_v_control),
        .reduction_operation(reduct_v_control),
        .state_operation(softmax_state_en),
        .stats_operand(softmax_stats_operand_en),
        .state_phase(softmax_state_phase),
        .active_rows(softmax_active_rows),
        .vector_base_addr(softmax_vector_base_addr),
        .state_base_addr(softmax_state_base_addr),
        .scalar_in(s_in),
        .scalar_in_valid(s_in_valid),
        .preview_valid(softmax_preview_valid),
        .preview_ready(softmax_preview_ready),
        .preview_element_operation(softmax_preview_element_operation),
        .preview_reduction_operation(softmax_preview_reduction_operation),
        .preview_state_operation(softmax_preview_state_en),
        .preview_stats_operand(softmax_preview_stats_operand_en),
        .preview_state_phase(softmax_preview_state_phase),
        .preview_active_rows(softmax_preview_active_rows),
        .preview_vector_base_addr(softmax_preview_vector_base_addr),
        .preview_state_base_addr(softmax_preview_state_base_addr),
        .group_read_valid(softmax_group_read_valid),
        .group_read_data(softmax_group_read_data),
        .group_write_req(softmax_group_write_req),
        .group_write_ready(softmax_group_write_ready),
        .group_write_addr(softmax_group_write_addr),
        .group_write_active_rows(softmax_group_write_active_rows),
        .group_write_data(softmax_group_write_data),
        .group_write_mask(softmax_group_write_mask),
        .row0_element_launch(row0_element_launch),
        .row0_element_operation(row0_element_operation),
        .row0_element_a(row0_element_a),
        .row0_element_b(row0_element_b),
        .row0_element_out(element_v_out),
        .row0_element_out_valid(element_v_out_valid),
        .row0_reduction_launch(row0_reduction_launch),
        .row0_reduction_operation(row0_reduction_operation),
        .row0_reduction_in(row0_reduction_in),
        .row0_reduction_out(reduction_s_out),
        .row0_reduction_out_valid(reduction_s_out_valid),
        .busy(softmax_busy),
        .done(softmax_done),
        .reduction_done(softmax_reduction_done)
    );

    generate
        if (COMPACT_STATS_IMPLEMENTED) begin : compact_stats_implemented
            compact_stats_simd #(
                .EXP_WIDTH  (V_FP_EXP_WIDTH),
                .MANT_WIDTH (V_FP_MANT_WIDTH),
                .VLEN       (VLEN),
                .COMPACT_STATS_LANES(COMPACT_STATS_LANES)
            ) compact_stats_unit (
                .clk           (clk),
                .rst           (rst),
                .operation     (recorded_element_v_control),
                .data_in_valid (compact_stats_in_valid),
                .active_lanes  (
                    recorded_compact_active_lanes[
                        $clog2(COMPACT_STATS_LANES + 1)-1:0
                    ]
                ),
                .data_in       (prepared_v_a),
                .scalar_in     (prepared_v_b[0]),
                .data_out      (compact_stats_out),
                .data_out_valid(compact_stats_out_valid)
            );
        end else begin : compact_stats_not_implemented
            always_comb begin
                compact_stats_out = '0;
                compact_stats_out_valid = 1'b0;
            end
        end
    endgenerate

    // Vector-lane reads share the reduction source port but bypass the tree.
    // Three registered stages keep the result safely behind the tracking FIFO's
    // head visibility while still permitting a lane load every cycle.
    always_ff @(posedge clk) begin
        if (rst) begin
            lane_load_valid_p1 <= 1'b0;
            lane_load_valid_p2 <= 1'b0;
            lane_load_out_valid <= 1'b0;
            lane_load_data_p1 <= '0;
            lane_load_data_p2 <= '0;
            lane_load_out <= '0;
        end else begin
            lane_load_valid_p1 <= complete_reduct_prepare &&
                                  recorded_reduct_v_control == LOAD_LANE_FP_V_REDUCT;
            if (complete_reduct_prepare &&
                recorded_reduct_v_control == LOAD_LANE_FP_V_REDUCT) begin
                lane_load_data_p1 <= prepared_v_a[recorded_reduct_segment_index];
            end
            lane_load_valid_p2 <= lane_load_valid_p1;
            lane_load_data_p2 <= lane_load_data_p1;
            lane_load_out_valid <= lane_load_valid_p2;
            lane_load_out <= lane_load_data_p2;
        end
    end

    always_comb begin
        if (red_head_valid && red_head.red_op == LOAD_LANE_FP_V_REDUCT) begin
            s_out = lane_load_out;
            s_out_valid = lane_load_out_valid;
        end else if (softmax_busy) begin
            s_out = '0;
            s_out_valid = 1'b0;
        end else begin
            s_out = reduction_s_out;
            s_out_valid = reduction_s_out_valid;
        end
    end

    // Reduction scalar write target: taken from the head of the reduction FIFO,
    // valid in the same cycle s_out_valid pops it (red_pop).
    assign s_out_rd = (red_head_valid &&
                       (red_head.red_op == SUM_V_REDUCT || red_head.red_op == MAX_V_REDUCT ||
                        red_head.red_op == SUM_SEG_V_REDUCT || red_head.red_op == MAX_SEG_V_REDUCT ||
                        red_head.red_op == LOAD_LANE_FP_V_REDUCT))
                    ? red_head.waddr[FP_OPERAND_WIDTH-1:0] : 'b0;

`ifdef SIMULATION
    always_ff @(posedge clk) begin
        if (!rst && compute_result_valid && reduction_v_out_valid) begin
            $fatal(1, "VectorMachine write-port collision: element and multi-reduction completed together");
        end
    end
`endif


    //----------------------------//
    // Hadamard Transform Unit
    //----------------------------//
    `ifdef HADAMARD_EN
        per_tile_hadamard_transform #(
            .TILESIZE   (VLEN),
            .EXP_WIDTH  (V_FP_EXP_WIDTH),
            .MANT_WIDTH (V_FP_MANT_WIDTH)
        ) hadamard_transform_unit (
            .clk(clk),
            .rst(rst),
            .data_in_valid      (hadamard_transform_in_valid),
            .data_in            (prepared_v_a),
            .data_out_valid     (hadamard_transform_out_valid),
            .data_out           (hadamard_transform_v_out)
        );
    `endif

    //----------------------------//
    // Base vector shift and optional Mamba prefix scan
    //----------------------------//

    fp_vec_shift #(
        .VLEN       (VLEN),
        .BITWIDTH   (V_FP_EXP_WIDTH + V_FP_MANT_WIDTH + 1),
        .RIGHT_SHIFT(1'b0)
    ) vec_shift_unit (
        .clk            (clk),
        .rst            (rst),
        .v_in_valid     (shift_in_valid),
        .v_in           (shift_v_in),
        .shift_amount   (shift_amount),
        .v_out_valid    (shift_out_valid),
        .v_out          (shift_v_out)
    );

    `ifdef MAMBA_EXTENSION_EN
        fp_prefix_scan_syn #(
            .VLEN(VLEN),
            .EXP_WIDTH(V_FP_EXP_WIDTH),
            .MANT_WIDTH(V_FP_MANT_WIDTH)
        ) prefix_scan_unit (
            .clk        (clk),
            .rst        (rst),
            .vin        (prefix_scan_v_in),
            .vout       (prefix_scan_v_out),
            .in_valid   (prefix_scan_in_valid),
            .out_valid  (prefix_scan_out_valid)
        );

    `endif

endmodule
