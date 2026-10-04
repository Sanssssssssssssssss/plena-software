`timescale 1ns/1ps

`include "configuration.svh"
`include "operation.svh"

// Module-level integration harness for the production rtl-v6 VectorMachine.
// It connects the real row engine to the real banked Vector SRAM while keeping
// the unrelated Scalar/HBM/Matrix top-level out of the validation boundary.
module vector_machine_rtl_v6_integration_wrapper
    import precision_pkg::*;
    import configuration_pkg::*;
    import instruction_pkg::*;
#(
    parameter int ROW_LANES = 4,
    parameter int STATE_ENTRIES = 64,
    parameter int SRAM_DEPTH = 64,
    localparam int FP_WIDTH = V_FP_EXP_WIDTH + V_FP_MANT_WIDTH + 1,
    localparam int ACTIVE_WIDTH = $clog2(ROW_LANES + 1),
    localparam int SEGMENT_LOG2_WIDTH = $clog2($clog2(VLEN) + 1)
) (
    input logic clk,
    input logic rst,

    // Ordinary SRAM access used to initialize and inspect physical rows.
    input logic ordinary_write_valid,
    input logic ordinary_read_valid,
    input logic [ON_CHIP_ADDR_WIDTH-1:0] ordinary_addr,
    input logic [VLEN-1:0][FP_WIDTH-1:0] ordinary_write_data,
    input logic [VLEN-1:0] ordinary_write_mask,
    output logic ordinary_read_data_valid,
    output logic [VLEN-1:0][FP_WIDTH-1:0] ordinary_read_data,

    // Existing single-row VectorMachine path.
    input logic normal_valid,
    input V_ELEMENT_OP normal_element_operation,
    input logic [VLEN-1:0][FP_WIDTH-1:0] normal_a,
    input logic [VLEN-1:0][FP_WIDTH-1:0] normal_b,
    input logic [ON_CHIP_ADDR_WIDTH-1:0] normal_result_addr,
    output logic normal_write_valid,
    output logic [ON_CHIP_ADDR_WIDTH-1:0] normal_write_addr,
    output logic [VLEN-1:0][FP_WIDTH-1:0] normal_write_data,

    // rtl-v6 row command.
    input logic row_command_valid,
    output logic row_command_ready,
    input V_ELEMENT_OP row_element_operation,
    input V_REDUCT_OP row_reduction_operation,
    input logic row_state_operation,
    input logic row_stats_operand,
    input logic [1:0] row_state_phase,
    input logic [ACTIVE_WIDTH-1:0] row_active_rows,
    input logic [ON_CHIP_ADDR_WIDTH-1:0] row_vector_base_addr,
    input logic [ON_CHIP_ADDR_WIDTH-1:0] row_state_base_addr,
    input logic [FP_WIDTH-1:0] row_scalar,
    input logic row_scalar_valid,
    output logic row_busy,
    output logic row_done,
    output logic row_reduction_done,

    output logic [31:0] accepted_command_count,
    output logic [31:0] accepted_group_read_count,
    output logic [31:0] committed_group_write_count,
    output logic auxiliary_access_conflict,
    output logic [3:0] configured_row_lanes
);
    logic vm_command_ready;
    logic vm_command_valid;
    logic group_read_req, group_read_ready, group_read_valid;
    logic [ROW_LANES-1:0][VLEN-1:0][FP_WIDTH-1:0]
        group_read_data;
    logic group_write_req, group_write_ready;
    logic [ON_CHIP_ADDR_WIDTH-1:0] group_write_addr;
    logic [ACTIVE_WIDTH-1:0] group_write_active_rows;
    logic [ROW_LANES-1:0][VLEN-1:0][FP_WIDTH-1:0]
        group_write_data;
    logic [ROW_LANES-1:0][VLEN-1:0] group_write_mask;

    logic [VLEN-1:0][FP_WIDTH-1:0] vm_v_out;
    logic [ON_CHIP_ADDR_WIDTH-1:0] vm_v_waddr;
    logic vm_v_wreq;
    logic [VLEN-1:0] vm_v_wmask;
    logic [FP_WIDTH-1:0] unused_scalar_out;
    logic unused_scalar_valid, unused_reduction_complete;
    logic [FP_OPERAND_WIDTH-1:0] unused_scalar_rd;

    logic sram_port_a_req, sram_port_a_write;
    logic [ON_CHIP_ADDR_WIDTH-1:0] sram_port_a_addr;
    logic [VLEN-1:0][FP_WIDTH-1:0] sram_port_a_write_data;
    logic [VLEN-1:0] sram_port_a_write_mask;
    logic [VLEN-1:0][FP_WIDTH-1:0] sram_port_a_read_data;
    logic ordinary_read_q;

    // The frontend only advances a row command when both the row engine and
    // its physical SRAM resource can accept it in this cycle.
    assign row_command_ready = vm_command_ready &&
        (row_state_operation || group_read_ready);
    assign vm_command_valid = row_command_valid && row_command_ready;
    assign group_read_req = vm_command_valid && !row_state_operation;

    // Ordinary accesses are only used while the row engine is idle in this
    // harness. The production SRAM still arbitrates row-group traffic itself.
    assign sram_port_a_req = ordinary_write_valid || vm_v_wreq ||
        ordinary_read_valid;
    assign sram_port_a_write = ordinary_write_valid || vm_v_wreq;
    assign sram_port_a_addr = ordinary_write_valid ? ordinary_addr :
        vm_v_wreq ? vm_v_waddr : ordinary_addr;
    assign sram_port_a_write_data = ordinary_write_valid
        ? ordinary_write_data : vm_v_out;
    assign sram_port_a_write_mask = ordinary_write_valid
        ? ordinary_write_mask : vm_v_wmask;
    assign ordinary_read_data = sram_port_a_read_data;
    assign ordinary_read_data_valid = ordinary_read_q;

    assign normal_write_valid = vm_v_wreq;
    assign normal_write_addr = vm_v_waddr;
    assign normal_write_data = vm_v_out;
    assign row_reduction_done = unused_reduction_complete;
    assign configured_row_lanes = ROW_LANES;

    always_ff @(posedge clk) begin
        if (rst) begin
            ordinary_read_q <= 1'b0;
            accepted_command_count <= '0;
            accepted_group_read_count <= '0;
            committed_group_write_count <= '0;
        end else begin
            ordinary_read_q <= ordinary_read_valid;
            if (vm_command_valid)
                accepted_command_count <= accepted_command_count + 1'b1;
            if (group_read_req && group_read_ready)
                accepted_group_read_count <= accepted_group_read_count + 1'b1;
            if (group_write_req && group_write_ready)
                committed_group_write_count <= committed_group_write_count + 1'b1;
        end
    end

    vector_machine #(
        .COMPACT_STATS_IMPLEMENTED(1'b1),
        .COMPACT_STATS_LANES(4),
        .SOFTMAX_ROW_LANES(ROW_LANES),
        .SOFTMAX_STATE_ENTRIES(STATE_ENTRIES)
    ) production_vector_machine (
        .clk(clk),
        .rst(rst),
        .broadcast_fp2(1'b0),
        .element_v_control(row_command_valid
            ? row_element_operation : normal_element_operation),
        .reduct_v_control(row_reduction_operation),
        .reduct_segment_log2(SEGMENT_LOG2_WIDTH'($clog2(VLEN))),
        .compact_active_lanes('0),
        .reduct_segment_index('0),
        .segment_broadcast_en(1'b0),
        .compact_stats_en(1'b0),
        .reduction_overwrite_en(1'b1),
        .lane_store_en(1'b0),
        .vector_mask('0),
        .element_mask_enable(1'b0),
        .softmax_command_valid(vm_command_valid),
        .softmax_command_ready(vm_command_ready),
        .softmax_state_en(row_state_operation),
        .softmax_stats_operand_en(row_stats_operand),
        .softmax_state_phase(row_state_phase),
        .softmax_active_rows(row_active_rows),
        .softmax_vector_base_addr(row_vector_base_addr),
        .softmax_state_base_addr(row_state_base_addr),
        .softmax_preview_valid(1'b0),
        .softmax_preview_ready(),
        .softmax_preview_element_operation(STALL_V_ELEMENT),
        .softmax_preview_reduction_operation(STALL_V_REDUCT),
        .softmax_preview_state_en(1'b0),
        .softmax_preview_stats_operand_en(1'b0),
        .softmax_preview_state_phase('0),
        .softmax_preview_active_rows('0),
        .softmax_preview_vector_base_addr('0),
        .softmax_preview_state_base_addr('0),
        .softmax_group_read_valid(group_read_valid),
        .softmax_group_read_data(group_read_data),
        .softmax_group_write_req(group_write_req),
        .softmax_group_write_ready(group_write_ready),
        .softmax_group_write_addr(group_write_addr),
        .softmax_group_write_active_rows(group_write_active_rows),
        .softmax_group_write_data(group_write_data),
        .softmax_group_write_mask(group_write_mask),
        .softmax_busy(row_busy),
        .softmax_done(row_done),
        .v_a_in(normal_a),
        .v_a_valid(normal_valid),
        .v_b_in(normal_b),
        .v_b_valid(normal_valid),
        .s_in(row_scalar),
        .s_in_valid(row_scalar_valid),
        .s_wtarget('0),
        .result_waddr(normal_result_addr),
        .result_waddr_update(normal_valid),
        .v_out(vm_v_out),
        .v_waddr(vm_v_waddr),
        .v_wreq(vm_v_wreq),
        .v_wmask(vm_v_wmask),
        .s_out(unused_scalar_out),
        .s_out_valid(unused_scalar_valid),
        .s_out_rd(unused_scalar_rd),
        .reduction_complete(unused_reduction_complete)
    );

    fp_vector_sram #(
        .ACT_MXFP_EXP_WIDTH(ACT_MXFP_EXP_WIDTH),
        .ACT_MXFP_MANT_WIDTH(ACT_MXFP_MANT_WIDTH),
        .WT_MX_EXP_WIDTH(WT_MX_EXP_WIDTH),
        .WT_MX_MANT_WIDTH(WT_MX_MANT_WIDTH),
        .KV_MX_EXP_WIDTH(KV_MX_EXP_WIDTH),
        .KV_MX_MANT_WIDTH(KV_MX_MANT_WIDTH),
        .MX_SCALE_WIDTH(MX_SCALE_WIDTH),
        .ACT_MX_INT_ENABLE(ACT_MX_INT_ENABLE),
        .ACT_MX_INT_WIDTH(ACT_MX_INT_WIDTH),
        .WT_MX_INT_ENABLE(WT_MX_INT_ENABLE),
        .WT_MX_INT_WIDTH(WT_MX_INT_WIDTH),
        .KV_MX_INT_ENABLE(KV_MX_INT_ENABLE),
        .KV_MX_INT_WIDTH(KV_MX_INT_WIDTH),
        .EXP_WIDTH(V_FP_EXP_WIDTH),
        .MANT_WIDTH(V_FP_MANT_WIDTH),
        .VLEN(VLEN),
        .MLEN(MLEN),
        .BLEN(BLEN),
        .BLOCK_DIM(BLOCK_DIM),
        .SRAM_DEPTH(SRAM_DEPTH),
        .ON_CHIP_ADDR_WIDTH(ON_CHIP_ADDR_WIDTH),
        .PREFETCH_AMOUNT(4),
        .SOFTMAX_ROW_LANES(ROW_LANES)
    ) production_vector_sram (
        .clk(clk),
        .rst(rst),
        .port_a_req(sram_port_a_req),
        .port_a_write_en(sram_port_a_write),
        .port_a_addr(sram_port_a_addr),
        .select_write_data_a(1'b0),
        .port_a_v_fp_in(sram_port_a_write_data),
        .port_a_m_fp_in('0),
        .port_a_mask_in(sram_port_a_write_mask),
        .port_a_v_fp_out(sram_port_a_read_data),
        .port_a_element_out(),
        .port_a_scale_out(),
        .port_b_req(1'b0),
        .port_b_write_en(1'b0),
        .port_b_addr('0),
        .select_write_data_b('0),
        .port_b_fp_in('0),
        .port_b_fp_out(),
        .port_b_mask_in('0),
        .port_b_high_precision_element_in('0),
        .port_b_low_precision_element_in('0),
        .port_b_scale_in('0),
        .port_b_mxfp_req('0),
        .port_b_mxfp_high_out_valid(),
        .port_b_mxfp_low_out_valid(),
        .port_b_high_element_out(),
        .port_b_low_element_out(),
        .port_b_scale_out(),
        .group_read_req(group_read_req),
        .group_read_addr(row_vector_base_addr),
        .group_read_active_rows(row_active_rows),
        .group_read_ready(group_read_ready),
        .group_read_valid(group_read_valid),
        .group_read_data(group_read_data),
        .group_write_req(group_write_req),
        .group_write_addr(group_write_addr),
        .group_write_active_rows(group_write_active_rows),
        .group_write_data(group_write_data),
        .group_write_mask(group_write_mask),
        .group_write_ready(group_write_ready),
        .packed_read_req(1'b0),
        .packed_read_addr('0),
        .packed_read_ready(),
        .packed_read_valid(),
        .packed_read_data(),
        .packed_write_req(1'b0),
        .packed_write_addr('0),
        .packed_write_data('0),
        .packed_write_mask('0),
        .packed_write_ready(),
        .auxiliary_access_conflict(auxiliary_access_conflict),
        .prefetch_en(1'b0),
        .prefetch_addr('0),
        .data_not_ready()
    );

`ifdef SIMULATION
    always_ff @(posedge clk) begin
        if (!rst && row_command_valid && row_command_ready &&
            row_active_rows == 0)
            $fatal(1, "zero-row softmax command accepted");
        if (!rst && row_busy && (ordinary_write_valid || ordinary_read_valid ||
                                 normal_valid))
            $fatal(1, "ordinary Vector access overlapped a row wavefront");
    end
`endif
endmodule
