`ifndef CONFIGURATION_SVH
`define CONFIGURATION_SVH
`include "global_define.vh"
`include "precision.svh"

import precision_pkg::*;

package configuration_pkg;
    // Compute Unit Related
    localparam   BLEN = 4; // 4
    localparam   HLEN = 8;
    localparam   MLEN = 16; // 64
    localparam   VLEN = 16; // 64
    localparam   INST_BUFF_DEPTH = 32;
    localparam   ON_CHIP_ADDR_WIDTH = precision_pkg::INT_DATA_WIDTH;

    // Precision-derived element widths. Keep these in configuration_pkg so
    // top-level bus widths reflect MXINT/MXFP software profiles.
    localparam   WT_ELEMENT_WIDTH  = precision_pkg::WT_MX_INT_ENABLE
                                    ? precision_pkg::WT_MX_INT_WIDTH
                                    : (precision_pkg::WT_MX_MANT_WIDTH + precision_pkg::WT_MX_EXP_WIDTH + 1);
    localparam   ACT_ELEMENT_WIDTH = precision_pkg::ACT_MX_INT_ENABLE
                                    ? precision_pkg::ACT_MX_INT_WIDTH
                                    : (precision_pkg::ACT_MXFP_MANT_WIDTH + precision_pkg::ACT_MXFP_EXP_WIDTH + 1);
    localparam   KV_ELEMENT_WIDTH  = precision_pkg::KV_MX_INT_ENABLE
                                    ? precision_pkg::KV_MX_INT_WIDTH
                                    : (precision_pkg::KV_MX_MANT_WIDTH + precision_pkg::KV_MX_EXP_WIDTH + 1);
    localparam   V_FP_ELEMENT_WIDTH = precision_pkg::V_FP_MANT_WIDTH + precision_pkg::V_FP_EXP_WIDTH + 1;
    localparam   MX_ELEMENT_LANE_WIDTH = (WT_ELEMENT_WIDTH > ACT_ELEMENT_WIDTH)
                                           ? ((WT_ELEMENT_WIDTH > KV_ELEMENT_WIDTH) ? WT_ELEMENT_WIDTH : KV_ELEMENT_WIDTH)
                                           : ((ACT_ELEMENT_WIDTH > KV_ELEMENT_WIDTH) ? ACT_ELEMENT_WIDTH : KV_ELEMENT_WIDTH);
    localparam   HBM_ELEMENT_LANE_WIDTH = (MX_ELEMENT_LANE_WIDTH > V_FP_ELEMENT_WIDTH)
                                           ? MX_ELEMENT_LANE_WIDTH
                                           : V_FP_ELEMENT_WIDTH;

    // SourceWidth must satisfy: SourceWidth + SubbeatBits <= DeviceSourceWidth
    // where SubbeatBits = $clog2(HBM_WIDTH/32) for 32-bit host bus
    // Formula: base (2) + $clog2(HBM_WIDTH/32) + margin (2)
    localparam   SourceWidth = 4 + $clog2(HBM_ELEMENT_LANE_WIDTH * MLEN / 16);  // [original: 5, tested: 6]
    localparam   SinkWidth = 1;
    // Memory Related
    localparam   MATRIX_SRAM_WIDTH = (WT_ELEMENT_WIDTH + precision_pkg::WT_MX_SCALE_WIDTH) * MLEN;
    localparam   MATRIX_SRAM_DEPTH = 1024; // must be > 2x MLEN
    localparam   VECTOR_SRAM_WIDTH = (precision_pkg::V_FP_MANT_WIDTH + precision_pkg::V_FP_EXP_WIDTH + 1) * VLEN;
    localparam   VECTOR_SRAM_DEPTH = 1024; // must be > HEAD_DIM + HIDDEN_DIM/VLEN
    localparam   VECTOR_RESET_AMOUNT = 8;            // Need to be the same as Head_Dim for assembly code.
    localparam   INT_SRAM_WIDTH      = precision_pkg::INT_DATA_WIDTH;
    localparam   INT_SRAM_DEPTH      = 32;
    localparam   FP_SRAM_WIDTH       = (precision_pkg::S_FP_MANT_WIDTH + precision_pkg::S_FP_EXP_WIDTH + 1);
    localparam   FP_SRAM_DEPTH       = 512;
    localparam   HBM_ADDR_WIDTH      = 128;
    localparam   PC_ADDR_WIDTH       = 16;

    // Loop Control Related
    localparam   MAX_LOOP_DEPTH      = 4;  // Maximum nesting depth for hardware loops

    // HBM Related (calculated from precision parameters)
    localparam   HBM_M_Prefetch_Amount   = MLEN;
    localparam   HBM_V_Prefetch_Amount   = 4;
    localparam   HBM_V_Writeback_Amount  = 4;
    // Element width follows the widest HBM-facing MX lane selected by the
    // current software precision profile.
    localparam   HBM_ELE_WIDTH_RAW       = HBM_ELEMENT_LANE_WIDTH * MLEN;
    localparam   HBM_ELE_WIDTH           = (1 << $clog2(HBM_ELE_WIDTH_RAW * 2));
    localparam   HBM_SCALE_WIDTH         = precision_pkg::MX_SCALE_WIDTH * (MLEN / precision_pkg::BLOCK_DIM);
    localparam   HBM_WIDTH               = HBM_ELE_WIDTH;
    localparam   INSTRUCTION_STORAGE_OFFSET = 32'hA0;  // Byte offset computed by workload generator = 160
endpackage

package instruction_pkg;
    localparam INT_OPERAND_WIDTH     = 4;
    // RTL-v3 scalar pipeline exposes f0-f15.  The generic instruction operand
    // field is already four bits wide, so this does not change the 32-bit ISA
    // layout; it only stops truncating the high FP-register bit in decode.
    localparam FP_OPERAND_WIDTH      = 4;
    localparam HBM_ADR_OPERAND_WIDTH = 3;
    localparam STRIDE_OPERAND_WIDTH  = 3;
    localparam OPERAND_WIDTH         = 4;
    localparam FUNCT_WIDTH           = 4;
    localparam OPCODE_WIDTH          = 6;
    localparam IMM_WIDTH             = 22;
    localparam IMM_2_WIDTH           = 18;
    localparam INSTRUCTION_LENGTH    = 32;
endpackage

package simulation_pkg;
    localparam   FAKE_HBM_ADDR_WIDTH             = 16;
endpackage

`ifdef DC_LIB_EN // Define for DC Library Enabled, the pipeline stage lib changed accordingly.

    package pipeline_pkg;
        localparam   MAX_PIPELINE_STAGE             = 10;
        localparam   SYSTOLIC_PROCESSING_OVERHEAD   = 8;
        localparam   VECTOR_LONGEST_OPERATE_CYCLES  = 10;
    endpackage

`else

    package pipeline_pkg;
        localparam   MAX_PIPELINE_STAGE             = 10;
        localparam   SYSTOLIC_PROCESSING_OVERHEAD   = 8;
        localparam   VECTOR_LONGEST_OPERATE_CYCLES  = 30;
    endpackage

`endif

`endif
