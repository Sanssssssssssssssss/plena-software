`timescale 1ns / 1ps
`include "tl_util.svh"
`include "configuration.svh"
`include "tl_pkg.svh"

/*
Module      : Sim Top Module
*/

module SimTop import instruction_pkg::*; #(
    parameter           INSTRUCTION_LENGTH = 32,
    parameter int       SOFTMAX_ROW_LANES = 1,
    parameter int       SOFTMAX_STATE_HEADS = 64,
    parameter int       INSTRUCTION_STORAGE_OFFSET =
        configuration_pkg::INSTRUCTION_STORAGE_OFFSET,
    parameter string    FAKE_HBM_INIT_FILE            = "",  // Combined HBM init file (.mem) with data and instructions
    parameter string    FP_MEM_INIT_FILE              = "",
    parameter string    INT_MEM_INIT_FILE             = "",
    parameter string    VECTOR_MEM_RESULT_FILE        = "",
    parameter string    FP_REG_RESULT_FILE            = "",  // FP scalar register-file dump
    parameter string    HBM_RESULT_FILE               = ""   // HBM dump file for verification
) (
    input logic clk,
    input logic rst
);

import simulation_pkg::*;
import configuration_pkg::*;


// TileLink declarations for instruction memory
`TL_DECLARE(INSTRUCTION_LENGTH, HBM_ADDR_WIDTH, SourceWidth, SinkWidth, instr_link);

// TileLink declarations for data memory (HBM)
`TL_DECLARE(HBM_ELE_WIDTH,  HBM_ADDR_WIDTH, SourceWidth, SinkWidth, m_element_link);
`TL_DECLARE(HBM_SCALE_WIDTH, HBM_ADDR_WIDTH, SourceWidth, SinkWidth, m_scale_link);
`TL_DECLARE(HBM_ELE_WIDTH,  HBM_ADDR_WIDTH, SourceWidth, SinkWidth, v_element_link);
`TL_DECLARE(HBM_SCALE_WIDTH, HBM_ADDR_WIDTH, SourceWidth, SinkWidth, v_scale_link);

// Processor
plena #(
    .SOFTMAX_ROW_LANES(SOFTMAX_ROW_LANES),
    .SOFTMAX_STATE_HEADS(SOFTMAX_STATE_HEADS),
    .INSTRUCTION_STORAGE_OFFSET(INSTRUCTION_STORAGE_OFFSET),
    .FP_MEM_INIT_FILE(FP_MEM_INIT_FILE),
    .INT_MEM_INIT_FILE(INT_MEM_INIT_FILE),
    .V_SRAM_RESULT_FILE(VECTOR_MEM_RESULT_FILE),
    .FP_REG_RESULT_FILE(FP_REG_RESULT_FILE)
) dut (
    .clk(clk),
    .rst(rst),
    `TL_CONNECT_HOST_PORT   (instr_mem_tl,   instr_link),
    `TL_CONNECT_HOST_PORT   (m_out_element,  m_element_link),
    `TL_CONNECT_HOST_PORT   (m_out_scale,    m_scale_link),
    `TL_CONNECT_HOST_PORT   (v_out_element,  v_element_link),
    `TL_CONNECT_HOST_PORT   (v_out_scale,    v_scale_link)
);

// Combined 5-port fake HBM module (data + instructions)
fake_hbm_5port #(
    .ADDR_WIDTH         (HBM_ADDR_WIDTH),
    .ELE_DATA_WIDTH     (HBM_ELE_WIDTH),
    .SCALE_DATA_WIDTH   (HBM_SCALE_WIDTH),
    .INSTR_DATA_WIDTH   (INSTRUCTION_LENGTH),
    .BRAM_ADDR_WIDTH    (FAKE_HBM_ADDR_WIDTH),
    .SourceWidth        (SourceWidth),
    .SinkWidth          (SinkWidth),
    .MemInitFile        (FAKE_HBM_INIT_FILE),
    .ResultFile         (HBM_RESULT_FILE)
) fake_hbm_inst (
    .clk(clk),
    .rst(rst),
    // Matrix machine ports
    `TL_CONNECT_DEVICE_PORT(m_element, m_element_link),
    `TL_CONNECT_DEVICE_PORT(m_scale, m_scale_link),
    // Vector machine ports
    `TL_CONNECT_DEVICE_PORT(v_element, v_element_link),
    `TL_CONNECT_DEVICE_PORT(v_scale, v_scale_link),
    // Instruction port
    `TL_CONNECT_DEVICE_PORT(instr, instr_link)
);

endmodule
