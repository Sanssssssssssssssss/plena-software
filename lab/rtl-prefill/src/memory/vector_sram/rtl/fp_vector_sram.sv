`timescale 1ns/1ps

/*
Module      : Top Level SRAM design for scratchpad
Timing      : Sequential Logic, 3 cycle for MXFP read and 1 cycle for FP read
Description :
            : This module supports two port reading
            : The addressing mode is Little Endian.
            : Port A ->  R: Matrix Multiplicand Vector or Vector Operand (RS1)               W: Vector Result from either Matrix or Vector Machine, 
            : Port B ->  R: Matrix Offest Vector or Vector Operand (RS2) or HBM Write Data   W: Vector Prefetch
Status      :
*/

module fp_vector_sram #(

    // MX-FP Data Format
    parameter   ACT_MXFP_EXP_WIDTH      = 4,
    parameter   ACT_MXFP_MANT_WIDTH     = 3,
    parameter   WT_MX_EXP_WIDTH         = 4,
    parameter   WT_MX_MANT_WIDTH        = 3,
    parameter   KV_MX_EXP_WIDTH         = 4,
    parameter   KV_MX_MANT_WIDTH        = 3,
    parameter   MX_SCALE_WIDTH          = 8,
    // MX-INT Parameters
    parameter   ACT_MX_INT_ENABLE       = 0,
    parameter   ACT_MX_INT_WIDTH        = 7,
    parameter   WT_MX_INT_ENABLE        = 0,
    parameter   WT_MX_INT_WIDTH         = 7,
    parameter   KV_MX_INT_ENABLE        = 0,
    parameter   KV_MX_INT_WIDTH         = 7,

    // FP Data Format
    parameter   EXP_WIDTH               = 8,
    parameter   MANT_WIDTH              = 7,

    // Dimension
    parameter   VLEN                    = 8,
    parameter   MLEN                    = 8,
    parameter   BLEN                    = 4,
    parameter   BLOCK_DIM               = 4,
    localparam  M_BLOCK_NUM             = MLEN / BLOCK_DIM,
    localparam  V_BLOCK_NUM             = VLEN / BLOCK_DIM,
    // MX-INT vs MXFP element width selection
    localparam  ACT_ELEMENT_WIDTH       = ACT_MX_INT_ENABLE ? ACT_MX_INT_WIDTH : (ACT_MXFP_EXP_WIDTH + ACT_MXFP_MANT_WIDTH + 1),
    localparam  WT_ELEMENT_WIDTH        = WT_MX_INT_ENABLE  ? WT_MX_INT_WIDTH  : (WT_MX_EXP_WIDTH + WT_MX_MANT_WIDTH + 1),
    localparam  KV_ELEMENT_WIDTH        = KV_MX_INT_ENABLE  ? KV_MX_INT_WIDTH  : (KV_MX_EXP_WIDTH + KV_MX_MANT_WIDTH + 1),

    // SRAM
    parameter   SRAM_DEPTH              = 128,
    parameter   ON_CHIP_ADDR_WIDTH      = 32,
    parameter   PREFETCH_AMOUNT         = 4,
    parameter   SOFTMAX_ROW_LANES       = 1
    // For Debugging
    `ifdef SIMULATION
        ,parameter string MEM_RESULT_FILE = ""
    `endif

)(
    input   logic clk,
    input   logic rst,

    // Port A
    input   logic port_a_req,
    input   logic port_a_write_en,
    input   logic [ON_CHIP_ADDR_WIDTH - 1 : 0] port_a_addr,
    input   logic select_write_data_a, // 0 for Vector Machine, 1 for Matrix Machine
    // FP Data Connection
    input   logic [VLEN - 1 : 0]        [EXP_WIDTH + MANT_WIDTH : 0]                port_a_v_fp_in,
    input   logic [MLEN - 1 : 0]        [EXP_WIDTH + MANT_WIDTH : 0]                port_a_m_fp_in,
    input   logic [VLEN - 1 : 0]                                                    port_a_mask_in,
    output  logic [VLEN - 1 : 0]        [EXP_WIDTH + MANT_WIDTH : 0]                port_a_v_fp_out,

    output  logic [MLEN - 1 : 0]            [ACT_ELEMENT_WIDTH-1:0]                             port_a_element_out,
    output  logic [M_BLOCK_NUM - 1 : 0]     [MX_SCALE_WIDTH - 1 : 0]                            port_a_scale_out,

    // Port B
    input   logic port_b_req,
    input   logic port_b_write_en,
    input   logic [ON_CHIP_ADDR_WIDTH - 1 : 0] port_b_addr,
    input   logic [1:0] select_write_data_b, // 0 for high MXFP vector load, 1 for low MXFP vector load, 2 for FP vector load
    // FP Data Connection
    input   logic [MLEN - 1 : 0]         [EXP_WIDTH + MANT_WIDTH : 0]               port_b_fp_in,
    output  logic [VLEN - 1 : 0]         [EXP_WIDTH + MANT_WIDTH : 0]               port_b_fp_out,
    input   logic [VLEN - 1 : 0]                                                    port_b_mask_in,
    // MX Data Connection
    input   logic [VLEN - 1 : 0]            [ACT_ELEMENT_WIDTH-1:0]                             port_b_high_precision_element_in,
    input   logic [VLEN - 1 : 0]            [KV_ELEMENT_WIDTH-1:0]                              port_b_low_precision_element_in,
    input   logic [V_BLOCK_NUM - 1 : 0]     [MX_SCALE_WIDTH - 1 : 0]                            port_b_scale_in,

    input   logic [1:0] port_b_mxfp_req , // 0 for STALL, 1 for High Precision MXFP Load, 2 for Low Precision MXFP Load
    output  logic port_b_mxfp_high_out_valid,
    output  logic port_b_mxfp_low_out_valid,
    output  logic [VLEN - 1 : 0]            [ACT_ELEMENT_WIDTH-1:0]                             port_b_high_element_out,
    output  logic [VLEN - 1 : 0]            [KV_ELEMENT_WIDTH-1:0]                              port_b_low_element_out,
    output  logic [V_BLOCK_NUM - 1 : 0]     [MX_SCALE_WIDTH - 1 : 0]                            port_b_scale_out,

    // RTL-v6 aligned row-group access.  These ports are statically mapped
    // across SOFTMAX_ROW_LANES banks; they are not general multi-port SRAM
    // accesses and do not replicate the stored data.
    input   logic group_read_req,
    input   logic [ON_CHIP_ADDR_WIDTH - 1 : 0] group_read_addr,
    input   logic [$clog2(SOFTMAX_ROW_LANES + 1) - 1 : 0] group_read_active_rows,
    output  logic group_read_ready,
    output  logic group_read_valid,
    output  logic [SOFTMAX_ROW_LANES - 1 : 0][VLEN - 1 : 0]
                  [EXP_WIDTH + MANT_WIDTH : 0] group_read_data,

    input   logic group_write_req,
    input   logic [ON_CHIP_ADDR_WIDTH - 1 : 0] group_write_addr,
    input   logic [$clog2(SOFTMAX_ROW_LANES + 1) - 1 : 0] group_write_active_rows,
    input   logic [SOFTMAX_ROW_LANES - 1 : 0][VLEN - 1 : 0]
                  [EXP_WIDTH + MANT_WIDTH : 0] group_write_data,
    input   logic [SOFTMAX_ROW_LANES - 1 : 0][VLEN - 1 : 0] group_write_mask,
    output  logic group_write_ready,

    // Dedicated packed-PV RMW path.  It shares the physical A/B ports with
    // ordinary traffic, and therefore exposes explicit acceptance signals.
    input   logic packed_read_req,
    input   logic [ON_CHIP_ADDR_WIDTH - 1 : 0] packed_read_addr,
    output  logic packed_read_ready,
    output  logic packed_read_valid,
    output  logic [VLEN - 1 : 0][EXP_WIDTH + MANT_WIDTH : 0] packed_read_data,
    input   logic packed_write_req,
    input   logic [ON_CHIP_ADDR_WIDTH - 1 : 0] packed_write_addr,
    input   logic [VLEN - 1 : 0][EXP_WIDTH + MANT_WIDTH : 0] packed_write_data,
    input   logic [VLEN - 1 : 0] packed_write_mask,
    output  logic packed_write_ready,
    output  logic auxiliary_access_conflict,

    // Status Tracking for Prefetch
    input   logic prefetch_en,
    input   logic [ON_CHIP_ADDR_WIDTH - 1 : 0] prefetch_addr,
    output  logic data_not_ready
);

    localparam int INTERNAL_ADDR_LEN           = $clog2(SRAM_DEPTH);
    localparam int FP_WIDTH                    = EXP_WIDTH + MANT_WIDTH + 1;
    localparam int BANK_DEPTH                  =
        (SRAM_DEPTH + SOFTMAX_ROW_LANES - 1) / SOFTMAX_ROW_LANES;
    localparam int BANK_ADDR_LEN               =
        (BANK_DEPTH <= 1) ? 1 : $clog2(BANK_DEPTH);
    localparam int BANK_INDEX_WIDTH             =
        (SOFTMAX_ROW_LANES <= 1) ? 1 : $clog2(SOFTMAX_ROW_LANES);

    initial begin
        if (VLEN < MLEN) begin
            $error("VLEN must be greater than or equal to MLEN, but got VLEN = %0d, MLEN = %0d", VLEN, MLEN);
            $finish;
        end
        if (SOFTMAX_ROW_LANES < 1 || SOFTMAX_ROW_LANES > 8 ||
            (SOFTMAX_ROW_LANES & (SOFTMAX_ROW_LANES - 1))) begin
            $error("SOFTMAX_ROW_LANES must be a power-of-two tier in [1, 8]");
            $finish;
        end
    end

    logic [VLEN - 1 : 0]        [EXP_WIDTH + MANT_WIDTH : 0] port_a_fp_out_internal;
    logic [VLEN - 1 : 0]        [EXP_WIDTH + MANT_WIDTH : 0] port_a_fp_in_internal;
    logic [VLEN - 1 : 0]        [EXP_WIDTH + MANT_WIDTH : 0] port_b_fp_in_internal;
    logic [VLEN - 1 : 0]        [EXP_WIDTH + MANT_WIDTH : 0] port_b_fp_out_internal;
    logic [VLEN - 1 : 0]        [EXP_WIDTH + MANT_WIDTH : 0] converted_b_high_fp_in;
    logic [VLEN - 1 : 0]        [EXP_WIDTH + MANT_WIDTH : 0] converted_b_low_fp_in;
    logic [V_BLOCK_NUM - 1 : 0] [MX_SCALE_WIDTH - 1 : 0]   port_b_high_scale_out;
    logic [V_BLOCK_NUM - 1 : 0] [MX_SCALE_WIDTH - 1 : 0]   port_b_low_scale_out;
    logic port_a_write_en_internal;
    logic port_a_req_internal;

    assign port_b_scale_out =   (select_write_data_b == 2'b01) ? port_b_high_scale_out  :
                                (select_write_data_b == 2'b10) ? port_b_low_scale_out   : '0;
    
    // -----------------------------
    // Prefetch Tag Tracking
    // -----------------------------

    // Tag Matching, trackinng the prefetch status.
    logic [INTERNAL_ADDR_LEN - 1 : 0]     translated_port_b_addr, translated_port_a_addr, translated_prefetch_addr, translated_port_a_addr_internal;
    logic [SRAM_DEPTH - 1 : 0]            mem_data_tag;
    logic [INTERNAL_ADDR_LEN - 1 : 0]     translated_port_a_addr_for_tag_lookup, translated_port_b_addr_for_tag_lookup;
    logic port_a_req_for_tag_lookup, port_b_req_for_tag_lookup;
    
    localparam BITWIDTH_PER_ROW         = VLEN;
    assign translated_port_a_addr       = port_a_addr >> $clog2(BITWIDTH_PER_ROW);
    assign translated_port_b_addr       = port_b_addr >> $clog2(BITWIDTH_PER_ROW);
    assign translated_prefetch_addr     = prefetch_addr >> $clog2(BITWIDTH_PER_ROW);

    always_ff @(posedge clk) begin
        if (rst) begin
            mem_data_tag <= {{SRAM_DEPTH{1'b1}}};
        end else if (prefetch_en) begin
            for (int i = 0; i < PREFETCH_AMOUNT; i++) begin : gen_prefetch_tag_update
                mem_data_tag[translated_prefetch_addr + i] <= 1'b0;
            end
        end else if (group_write_req && group_write_ready) begin
            for (int lane = 0; lane < SOFTMAX_ROW_LANES; lane++) begin
                if (lane < group_write_active_rows)
                    mem_data_tag[(group_write_addr >> $clog2(VLEN)) + lane] <= 1'b1;
            end
        end else if (packed_write_req && packed_write_ready) begin
            mem_data_tag[packed_write_addr >> $clog2(VLEN)] <= 1'b1;
        end else if (port_b_write_en) begin
            mem_data_tag[translated_port_b_addr] <= 1'b1;
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            data_not_ready <= 1'b0;
            translated_port_a_addr_for_tag_lookup <= '0;
            translated_port_b_addr_for_tag_lookup <= '0;
            port_a_req_for_tag_lookup <= 1'b0;
            port_b_req_for_tag_lookup <= 1'b0;
        end else begin
            translated_port_a_addr_for_tag_lookup <= translated_port_a_addr;
            translated_port_b_addr_for_tag_lookup <= translated_port_b_addr;
            port_a_req_for_tag_lookup <= port_a_req;
            port_b_req_for_tag_lookup <= port_b_req;
            data_not_ready <=  (port_b_req_for_tag_lookup & !(&mem_data_tag[translated_port_b_addr_for_tag_lookup +: BLEN])) || 
                               (port_a_req_for_tag_lookup & !(&mem_data_tag[translated_port_a_addr_for_tag_lookup +: BLEN]));
        end
    end

    // -----------------------------
    // Port A Management
    // -----------------------------

    always_comb begin
        if (select_write_data_a == 1'b0) begin
            // Vector Machine Mode, output as FP Data
            port_a_fp_in_internal       = port_a_v_fp_in;
            port_a_v_fp_out             = port_a_fp_out_internal;
            port_a_write_en_internal    = port_a_write_en;
            translated_port_a_addr_internal  = translated_port_a_addr;
            port_a_req_internal         = port_a_req;
        end else begin
            // Matrix Machine Mode, output as MX-FP Data.
            // The matrix result tile sits in the LOW lanes of port_a_m_fp_in;
            // its element-column offset lives in the low address bits, which
            // the row-granular address translation discards. Shift the data
            // into the addressed columns (the caller provides the matching
            // shifted write mask).
            port_a_fp_in_internal       = port_a_m_fp_in
                << (port_a_addr[$clog2(VLEN)-1:0] * (EXP_WIDTH + MANT_WIDTH + 1));
            port_a_v_fp_out             = '0;
            port_a_write_en_internal    = port_a_write_en;
            translated_port_a_addr_internal  = translated_port_a_addr;
            port_a_req_internal         = port_a_req;
        end
    end

    // Convert FP Data to MX-FP Data for HBM write
    logic [V_BLOCK_NUM - 1 : 0] mxfp_fp_convert_port_a_in_valid;
    logic [V_BLOCK_NUM - 1 : 0] mxfp_fp_convert_port_a_out_valid;
    logic port_a_mxfp_out_valid;
    logic [VLEN - 1 : 0] [EXP_WIDTH + MANT_WIDTH : 0] port_a_fp_out_reg;
    logic [V_BLOCK_NUM - 1 : 0] mxfp_fp_convert_port_a_valid_reg;
    
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            mxfp_fp_convert_port_a_in_valid <= '0;
            port_a_fp_out_reg               <= '0;
            mxfp_fp_convert_port_a_valid_reg <= '0;
        end else begin
            mxfp_fp_convert_port_a_in_valid <= (select_write_data_a == 1'b0 && port_a_req) ? {V_BLOCK_NUM{1'b1}} : '0;
            port_a_fp_out_reg <= port_a_fp_out_internal;
            mxfp_fp_convert_port_a_valid_reg <= mxfp_fp_convert_port_a_in_valid;
        end
    end

    generate
        if (ACT_MX_INT_ENABLE) begin : gen_fp_2_mx_int_port_a
            for (genvar j = 0; j < M_BLOCK_NUM; j++) begin : gen_fp_2_mx_int_port_a_block
                fp_2_mx_int_block #(
                    .BLOCK_DIM          (BLOCK_DIM),
                    .FP_MANT_WIDTH      (MANT_WIDTH),
                    .FP_EXP_WIDTH       (EXP_WIDTH),
                    .MXINT_WIDTH        (ACT_MX_INT_WIDTH),
                    .MXINT_SCALE_WIDTH  (MX_SCALE_WIDTH)
                ) fp_2_mx_int_port_a_convert_init(
                    .clk(clk),
                    .rst(rst),
                    .data_in                (port_a_fp_out_reg[j * BLOCK_DIM +: BLOCK_DIM]),
                    .data_in_valid          (mxfp_fp_convert_port_a_valid_reg[j]),
                    .element_data_out       (port_a_element_out[j * BLOCK_DIM +: BLOCK_DIM]),
                    .scale_data_out         (port_a_scale_out[j]),
                    .mx_int_data_out_valid  (mxfp_fp_convert_port_a_out_valid[j])
                );
            end
        end else begin : gen_fp_2_mx_fp_port_a
            for (genvar j = 0; j < M_BLOCK_NUM; j++) begin : gen_fp_2_mx_fp_port_a_block
                fp_2_mx_fp_block #(
                    .BLOCK_DIM          (BLOCK_DIM),
                    .FP_MANT_WIDTH      (MANT_WIDTH),
                    .FP_EXP_WIDTH       (EXP_WIDTH),
                    .MXFP_MANT_WIDTH    (ACT_MXFP_MANT_WIDTH),
                    .MXFP_EXP_WIDTH     (ACT_MXFP_EXP_WIDTH),
                    .MXFP_SCALE_WIDTH   (MX_SCALE_WIDTH)
                ) fp_2_mx_port_a_convert_init(
                    .clk(clk),
                    .rst(rst),
                    .data_in                (port_a_fp_out_reg[j * BLOCK_DIM +: BLOCK_DIM]),
                    .data_in_valid          (mxfp_fp_convert_port_a_valid_reg[j]),
                    .element_data_out       (port_a_element_out[j * BLOCK_DIM +: BLOCK_DIM]),
                    .scale_data_out         (port_a_scale_out[j]),
                    .mx_fp_data_out_valid   (mxfp_fp_convert_port_a_out_valid[j])
                );
            end
        end
    endgenerate

    // All blocks are synchronized, use any one valid signal
    assign port_a_mxfp_out_valid = mxfp_fp_convert_port_a_out_valid[0];


    // -----------------------------
    // Port B Management
    // As the conversion from mxfp to fp require several cycles, we need to delay the write enable and address signal.
    // -----------------------------
    localparam MX_CONVERT_DELAY_CYCLES = ACT_MX_INT_ENABLE ? 1 : 2; // Number of cycles to delay for MX-FP to FP conversion
    logic   [MX_CONVERT_DELAY_CYCLES - 1 : 0] delayed_port_b_write_en_internal;
    logic   [MX_CONVERT_DELAY_CYCLES - 1 : 0][INTERNAL_ADDR_LEN - 1 : 0] delayed_port_b_addr_internal;
    logic   [MX_CONVERT_DELAY_CYCLES - 1 : 0][1:0] delayed_port_b_mxfp_req;
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            delayed_port_b_write_en_internal <= '0;
            delayed_port_b_addr_internal <= '0;
            delayed_port_b_mxfp_req <= '0;
        end else begin
            delayed_port_b_write_en_internal[0] <= port_b_write_en;
            delayed_port_b_addr_internal[0] <= translated_port_b_addr;
            delayed_port_b_mxfp_req <= port_b_mxfp_req;
            for (int i = 1; i < MX_CONVERT_DELAY_CYCLES; i++) begin : gen_delay_port_b_write_en_internal
                delayed_port_b_write_en_internal[i] <= delayed_port_b_write_en_internal[i - 1];
                delayed_port_b_addr_internal[i] <= delayed_port_b_addr_internal[i - 1];
            end
        end
    end



    assign  port_b_fp_out = port_b_fp_out_internal;

    always_comb begin
        if (select_write_data_b == 2'b01) begin
            port_b_fp_in_internal   = converted_b_high_fp_in;
        end else if (select_write_data_b == 2'b10) begin
            port_b_fp_in_internal   = converted_b_low_fp_in;
        end else if (select_write_data_b == 2'b11) begin
            port_b_fp_in_internal   = port_b_fp_in;
        end else begin
            port_b_fp_in_internal   = 'b0;
        end
    end


    // Convert MX Data to FP Data for HBM Prefetch

    generate
        // High precision MX to FP conversion (ACT)
        if (ACT_MX_INT_ENABLE) begin : gen_mx_int_2_fp_high
            for (genvar i = 0; i < V_BLOCK_NUM; i++) begin : gen_mx_int_2_fp_high_block
                mx_int_2_fp_block #(
                    .BLOCK_DIM          (BLOCK_DIM),
                    .MXINT_WIDTH        (ACT_MX_INT_WIDTH),
                    .MXINT_SCALE_WIDTH  (MX_SCALE_WIDTH),
                    .FP_MANT_WIDTH      (MANT_WIDTH),
                    .FP_EXP_WIDTH       (EXP_WIDTH)
                ) port_b_mx_int_2_fp_high_precision_convert (
                    .clk            (clk),
                    .rst            (rst),
                    .data_in_valid  (port_b_write_en),
                    .element_in     (port_b_high_precision_element_in[(i+1)*BLOCK_DIM-1 : i*BLOCK_DIM]),
                    .scale_in       (port_b_scale_in[i]),
                    .data_out_valid (),
                    .fp_out         (converted_b_high_fp_in[(i+1)*BLOCK_DIM-1 : i*BLOCK_DIM])
                );
            end
        end else begin : gen_mx_fp_2_fp_high
            for (genvar i = 0; i < V_BLOCK_NUM; i++) begin : gen_mx_fp_2_fp_high_block
                mx_fp_2_fp_block #(
                    .BLOCK_DIM          (BLOCK_DIM),
                    .MXFP_MANT_WIDTH    (ACT_MXFP_MANT_WIDTH),
                    .MXFP_EXP_WIDTH     (ACT_MXFP_EXP_WIDTH),
                    .MXFP_SCALE_WIDTH   (MX_SCALE_WIDTH),
                    .FP_MANT_WIDTH      (MANT_WIDTH),
                    .FP_EXP_WIDTH       (EXP_WIDTH)
                ) port_b_mx_fp_2_fp_high_precision_convert (
                    .clk            (clk),
                    .rst            (rst),
                    .data_in_valid  (port_b_write_en),
                    .element_in     (port_b_high_precision_element_in[(i+1)*BLOCK_DIM-1 : i*BLOCK_DIM]),
                    .scale_in       (port_b_scale_in[i]),
                    .data_out_valid (),
                    .fp_out         (converted_b_high_fp_in[(i+1)*BLOCK_DIM-1 : i*BLOCK_DIM])
                );
            end
        end

        // Low precision MX to FP conversion (KV)
        if (KV_MX_INT_ENABLE) begin : gen_mx_int_2_fp_low
            for (genvar i = 0; i < V_BLOCK_NUM; i++) begin : gen_mx_int_2_fp_low_block
                mx_int_2_fp_block #(
                    .BLOCK_DIM          (BLOCK_DIM),
                    .MXINT_WIDTH        (KV_MX_INT_WIDTH),
                    .MXINT_SCALE_WIDTH  (MX_SCALE_WIDTH),
                    .FP_MANT_WIDTH      (MANT_WIDTH),
                    .FP_EXP_WIDTH       (EXP_WIDTH)
                ) port_b_mx_int_2_fp_low_precision_convert (
                    .clk            (clk),
                    .rst            (rst),
                    .data_in_valid  (port_b_write_en),
                    .element_in     (port_b_low_precision_element_in[(i+1)*BLOCK_DIM-1 : i*BLOCK_DIM]),
                    .scale_in       (port_b_scale_in[i]),
                    .data_out_valid (),
                    .fp_out         (converted_b_low_fp_in[(i+1)*BLOCK_DIM-1 : i*BLOCK_DIM])
                );
            end
        end else begin : gen_mx_fp_2_fp_low
            for (genvar i = 0; i < V_BLOCK_NUM; i++) begin : gen_mx_fp_2_fp_low_block
                mx_fp_2_fp_block #(
                    .BLOCK_DIM          (BLOCK_DIM),
                    .MXFP_MANT_WIDTH    (KV_MX_MANT_WIDTH),
                    .MXFP_EXP_WIDTH     (KV_MX_EXP_WIDTH),
                    .MXFP_SCALE_WIDTH   (MX_SCALE_WIDTH),
                    .FP_MANT_WIDTH      (MANT_WIDTH),
                    .FP_EXP_WIDTH       (EXP_WIDTH)
                ) port_b_mx_fp_2_fp_low_precision_convert (
                    .clk            (clk),
                    .rst            (rst),
                    .data_in_valid  (port_b_write_en),
                    .element_in     (port_b_low_precision_element_in[(i+1)*BLOCK_DIM-1 : i*BLOCK_DIM]),
                    .scale_in       (port_b_scale_in[i]),
                    .data_out_valid (),
                    .fp_out         (converted_b_low_fp_in[(i+1)*BLOCK_DIM-1 : i*BLOCK_DIM])
                );
            end
        end
    endgenerate


    // Convert FP Data to MX-FP Data for HBM write
    logic [V_BLOCK_NUM - 1 : 0] high_mx_convert_port_b_in_valid;
    logic [V_BLOCK_NUM - 1 : 0] low_mx_convert_port_b_in_valid;
    logic [V_BLOCK_NUM - 1 : 0] high_mx_convert_port_b_out_valid;
    logic [V_BLOCK_NUM - 1 : 0] low_mx_convert_port_b_out_valid;
    logic [VLEN - 1 : 0] [EXP_WIDTH + MANT_WIDTH : 0] port_b_fp_out_reg;
    logic [V_BLOCK_NUM - 1 : 0] high_mx_valid_reg;
    logic [V_BLOCK_NUM - 1 : 0] low_mx_valid_reg;


    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            high_mx_convert_port_b_in_valid <= '0;
            low_mx_convert_port_b_in_valid  <= '0;
        end else begin
            high_mx_convert_port_b_in_valid <= (port_b_mxfp_req == 2'b01) ? {V_BLOCK_NUM{1'b1}} : '0;
            low_mx_convert_port_b_in_valid  <= (port_b_mxfp_req  == 2'b10) ? {V_BLOCK_NUM{1'b1}} : '0;
        end
    end

    generate
        if (ACT_MX_INT_ENABLE) begin : gen_fp_2_mx_int_high_port_b
            for (genvar j = 0; j < V_BLOCK_NUM; j++) begin : gen_fp_2_mx_int_high_port_b_block
                fp_2_mx_int_block #(
                    .BLOCK_DIM          (BLOCK_DIM),
                    .FP_MANT_WIDTH      (MANT_WIDTH),
                    .FP_EXP_WIDTH       (EXP_WIDTH),
                    .MXINT_WIDTH        (ACT_MX_INT_WIDTH),
                    .MXINT_SCALE_WIDTH  (MX_SCALE_WIDTH)
                ) fp_2_mx_int_high_port_b_convert_init(
                    .clk(clk),
                    .rst(rst),
                    .data_in                (port_b_fp_out_reg[(j+1) * BLOCK_DIM - 1 : j * BLOCK_DIM]),
                    .data_in_valid          (high_mx_valid_reg[j]),
                    .element_data_out       (port_b_high_element_out[(j+1) * BLOCK_DIM-1 : j * BLOCK_DIM]),
                    .scale_data_out         (port_b_high_scale_out[j]),
                    .mx_int_data_out_valid  (high_mx_convert_port_b_out_valid[j])
                );
            end
        end else begin : gen_fp_2_mx_fp_high_port_b
            for (genvar j = 0; j < V_BLOCK_NUM; j++) begin : gen_fp_2_mx_fp_high_port_b_block
                fp_2_mx_fp_block #(
                    .BLOCK_DIM          (BLOCK_DIM),
                    .FP_MANT_WIDTH      (MANT_WIDTH),
                    .FP_EXP_WIDTH       (EXP_WIDTH),
                    .MXFP_MANT_WIDTH    (ACT_MXFP_MANT_WIDTH),
                    .MXFP_EXP_WIDTH     (ACT_MXFP_EXP_WIDTH),
                    .MXFP_SCALE_WIDTH   (MX_SCALE_WIDTH)
                ) fp_2_mx_high_port_b_convert_init(
                    .clk(clk),
                    .rst(rst),
                    .data_in                (port_b_fp_out_reg[(j+1) * BLOCK_DIM - 1 : j * BLOCK_DIM]),
                    .data_in_valid          (high_mx_valid_reg[j]),
                    .element_data_out       (port_b_high_element_out[(j+1) * BLOCK_DIM-1 : j * BLOCK_DIM]),
                    .scale_data_out         (port_b_high_scale_out[j]),
                    .mx_fp_data_out_valid   (high_mx_convert_port_b_out_valid[j])
                );
            end
        end
    endgenerate

    // Pipeline register on BRAM port B read output before fp_2_mx conversion
    // (breaks -2.4 ns critical path: BRAM → exp_max comparator)
    // Both high and low valid registers are clocked together with data to ensure timing alignment
    always_ff @(posedge clk) begin
        if (rst) begin
            port_b_fp_out_reg   <= '0;
            high_mx_valid_reg <= '0;
            low_mx_valid_reg  <= '0;
        end else begin
            port_b_fp_out_reg   <= port_b_fp_out_internal;
            high_mx_valid_reg <= high_mx_convert_port_b_in_valid;
            low_mx_valid_reg  <= low_mx_convert_port_b_in_valid;
        end
    end

    generate
        if (KV_MX_INT_ENABLE) begin : gen_fp_2_mx_int_low_port_b
            for (genvar j = 0; j < V_BLOCK_NUM; j++) begin : gen_fp_2_mx_int_low_port_b_block
                fp_2_mx_int_block #(
                    .BLOCK_DIM          (BLOCK_DIM),
                    .FP_MANT_WIDTH      (MANT_WIDTH),
                    .FP_EXP_WIDTH       (EXP_WIDTH),
                    .MXINT_WIDTH        (KV_MX_INT_WIDTH),
                    .MXINT_SCALE_WIDTH  (MX_SCALE_WIDTH)
                ) fp_2_mx_int_low_port_b_convert_init(
                    .clk(clk),
                    .rst(rst),
                    .data_in                (port_b_fp_out_reg[(j+1) * BLOCK_DIM - 1 : j * BLOCK_DIM]),
                    .data_in_valid          (low_mx_valid_reg[j]),
                    .element_data_out       (port_b_low_element_out[(j+1) * BLOCK_DIM-1 : j * BLOCK_DIM]),
                    .scale_data_out         (port_b_low_scale_out[j]),
                    .mx_int_data_out_valid  (low_mx_convert_port_b_out_valid[j])
                );
            end
        end else begin : gen_fp_2_mx_fp_low_port_b
            for (genvar j = 0; j < V_BLOCK_NUM; j++) begin : gen_fp_2_mx_fp_low_port_b_block
                fp_2_mx_fp_block #(
                    .BLOCK_DIM          (BLOCK_DIM),
                    .FP_MANT_WIDTH      (MANT_WIDTH),
                    .FP_EXP_WIDTH       (EXP_WIDTH),
                    .MXFP_MANT_WIDTH    (KV_MX_MANT_WIDTH),
                    .MXFP_EXP_WIDTH     (KV_MX_EXP_WIDTH),
                    .MXFP_SCALE_WIDTH   (MX_SCALE_WIDTH)
                ) fp_2_mx_low_port_b_convert_init(
                    .clk(clk),
                    .rst(rst),
                    .data_in                (port_b_fp_out_reg[(j+1) * BLOCK_DIM - 1 : j * BLOCK_DIM]),
                    .data_in_valid          (low_mx_valid_reg[j]),
                    .element_data_out       (port_b_low_element_out[(j+1) * BLOCK_DIM-1 : j * BLOCK_DIM]),
                    .scale_data_out         (port_b_low_scale_out[j]),
                    .mx_fp_data_out_valid   (low_mx_convert_port_b_out_valid[j])
                );
            end
        end
    endgenerate

    // All blocks are synchronized, use any one valid signal
    assign port_b_mxfp_high_out_valid = high_mx_convert_port_b_out_valid[0];
    assign port_b_mxfp_low_out_valid = low_mx_convert_port_b_out_valid[0];

// -----------------------------
// Banked Storage
// -----------------------------

    // Port B address select.
    // The delayed address (delayed_port_b_addr_internal) only exists to align the
    // prefetch write (and the FP->MXFP HBM-store read) with the MX<->FP conversion
    // latency. A *plain read* (port_b_req with write_en=0) asserts its request in
    // the same cycle the address is presented, exactly like Port A, so it must use
    // the live address. Feeding it the delayed address makes Port B return data from
    // an address two cycles old, so a read of the same location on both ports (e.g.
    // V_MUL_VV with RS1==RS2) returns mismatched values once the address changes
    // between loop iterations.
    logic [INTERNAL_ADDR_LEN - 1 : 0] port_b_storage_addr;
    assign port_b_storage_addr = (delayed_port_b_write_en_internal[MX_CONVERT_DELAY_CYCLES - 1]
                                  || (|delayed_port_b_mxfp_req))
                                 ? delayed_port_b_addr_internal[MX_CONVERT_DELAY_CYCLES - 1]
                                 : translated_port_b_addr;

    logic [INTERNAL_ADDR_LEN-1:0] translated_group_read_addr;
    logic [INTERNAL_ADDR_LEN-1:0] translated_group_write_addr;
    logic [INTERNAL_ADDR_LEN-1:0] translated_packed_read_addr;
    logic [INTERNAL_ADDR_LEN-1:0] translated_packed_write_addr;
    logic normal_b_storage_req;
    logic accepted_group_read, accepted_group_write;
    logic accepted_packed_read, accepted_packed_write;

    logic [SOFTMAX_ROW_LANES-1:0] bank_a_req, bank_a_write;
    logic [SOFTMAX_ROW_LANES-1:0] bank_b_req, bank_b_write;
    logic [SOFTMAX_ROW_LANES-1:0][BANK_ADDR_LEN-1:0] bank_a_addr, bank_b_addr;
    logic [SOFTMAX_ROW_LANES-1:0][VLEN-1:0][FP_WIDTH-1:0]
        bank_a_wdata, bank_a_rdata, bank_b_wdata, bank_b_rdata;
    logic [SOFTMAX_ROW_LANES-1:0][VLEN-1:0] bank_a_wmask, bank_b_wmask;
    logic [BANK_INDEX_WIDTH-1:0] ordinary_a_bank_q, ordinary_b_bank_q;
    logic [BANK_INDEX_WIDTH-1:0] packed_read_bank_q;
    logic group_read_valid_q, packed_read_valid_q;
    logic [$clog2(SOFTMAX_ROW_LANES + 1)-1:0] group_read_active_rows_q;

    assign translated_group_read_addr = group_read_addr >> $clog2(VLEN);
    assign translated_group_write_addr = group_write_addr >> $clog2(VLEN);
    assign translated_packed_read_addr = packed_read_addr >> $clog2(VLEN);
    assign translated_packed_write_addr = packed_write_addr >> $clog2(VLEN);
    assign normal_b_storage_req = port_b_req ||
        (|delayed_port_b_mxfp_req) ||
        delayed_port_b_write_en_internal[MX_CONVERT_DELAY_CYCLES - 1];

    // Port A is the read side for row groups and packed RMW; port B is the
    // write side.  Group reads and previous-group writes can therefore overlap.
    assign group_read_ready = !port_a_req_internal && !packed_read_req;
    assign packed_read_ready = !port_a_req_internal && !group_read_req;
    assign group_write_ready = !normal_b_storage_req && !packed_write_req;
    assign packed_write_ready = !normal_b_storage_req && !group_write_req;
    assign accepted_group_read = group_read_req && group_read_ready;
    assign accepted_packed_read = packed_read_req && packed_read_ready;
    assign accepted_group_write = group_write_req && group_write_ready;
    assign accepted_packed_write = packed_write_req && packed_write_ready;
    assign auxiliary_access_conflict =
        (group_read_req && !group_read_ready) ||
        (packed_read_req && !packed_read_ready) ||
        (group_write_req && !group_write_ready) ||
        (packed_write_req && !packed_write_ready);

    always_comb begin
        bank_a_req = '0;
        bank_a_write = '0;
        bank_a_addr = '0;
        bank_a_wdata = '0;
        bank_a_wmask = '0;
        bank_b_req = '0;
        bank_b_write = '0;
        bank_b_addr = '0;
        bank_b_wdata = '0;
        bank_b_wmask = '0;

        for (int bank = 0; bank < SOFTMAX_ROW_LANES; bank++) begin
            if (accepted_group_read && bank < group_read_active_rows) begin
                bank_a_req[bank] = 1'b1;
                bank_a_addr[bank] =
                    translated_group_read_addr / SOFTMAX_ROW_LANES;
            end else if (accepted_packed_read &&
                         bank == translated_packed_read_addr % SOFTMAX_ROW_LANES) begin
                bank_a_req[bank] = 1'b1;
                bank_a_addr[bank] =
                    translated_packed_read_addr / SOFTMAX_ROW_LANES;
            end else if (port_a_req_internal &&
                         bank == translated_port_a_addr_internal % SOFTMAX_ROW_LANES) begin
                bank_a_req[bank] = 1'b1;
                bank_a_write[bank] = port_a_write_en_internal;
                bank_a_addr[bank] =
                    translated_port_a_addr_internal / SOFTMAX_ROW_LANES;
                bank_a_wdata[bank] = port_a_fp_in_internal;
                bank_a_wmask[bank] = port_a_mask_in;
            end

            if (accepted_group_write && bank < group_write_active_rows) begin
                bank_b_req[bank] = 1'b1;
                bank_b_write[bank] = 1'b1;
                bank_b_addr[bank] =
                    translated_group_write_addr / SOFTMAX_ROW_LANES;
                bank_b_wdata[bank] = group_write_data[bank];
                bank_b_wmask[bank] = group_write_mask[bank];
            end else if (accepted_packed_write &&
                         bank == translated_packed_write_addr % SOFTMAX_ROW_LANES) begin
                bank_b_req[bank] = 1'b1;
                bank_b_write[bank] = 1'b1;
                bank_b_addr[bank] =
                    translated_packed_write_addr / SOFTMAX_ROW_LANES;
                bank_b_wdata[bank] = packed_write_data;
                bank_b_wmask[bank] = packed_write_mask;
            end else if (normal_b_storage_req &&
                         bank == port_b_storage_addr % SOFTMAX_ROW_LANES) begin
                bank_b_req[bank] = 1'b1;
                bank_b_write[bank] =
                    delayed_port_b_write_en_internal[MX_CONVERT_DELAY_CYCLES - 1];
                bank_b_addr[bank] = port_b_storage_addr / SOFTMAX_ROW_LANES;
                bank_b_wdata[bank] = port_b_fp_in_internal;
                bank_b_wmask[bank] = port_b_mask_in;
            end
        end
    end

    for (genvar bank = 0; bank < SOFTMAX_ROW_LANES; bank++) begin : vector_sram_bank
        prim_generic_ram_2p #(
            .Width(FP_WIDTH * VLEN),
            .Depth(BANK_DEPTH),
            .DataBitsPerMask(FP_WIDTH)
            `ifdef SIMULATION
            , .ResultFile("")
            `endif
        ) storage (
            .clk_i(clk),
            .a_req_i(bank_a_req[bank]),
            .a_write_i(bank_a_write[bank]),
            .a_addr_i(bank_a_addr[bank]),
            .a_wdata_i(bank_a_wdata[bank]),
            .a_wmask_i(bank_a_wmask[bank]),
            .a_rdata_o(bank_a_rdata[bank]),
            .b_req_i(bank_b_req[bank]),
            .b_write_i(bank_b_write[bank]),
            .b_addr_i(bank_b_addr[bank]),
            .b_wdata_i(bank_b_wdata[bank]),
            .b_wmask_i(bank_b_wmask[bank]),
            .b_rdata_o(bank_b_rdata[bank]),
            .cfg_i('0),
            .cfg_rsp_o()
        );
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            ordinary_a_bank_q <= '0;
            ordinary_b_bank_q <= '0;
            packed_read_bank_q <= '0;
            group_read_valid_q <= 1'b0;
            packed_read_valid_q <= 1'b0;
            group_read_active_rows_q <= '0;
        end else begin
            group_read_valid_q <= accepted_group_read;
            packed_read_valid_q <= accepted_packed_read;
            if (accepted_group_read)
                group_read_active_rows_q <= group_read_active_rows;
            if (port_a_req_internal)
                ordinary_a_bank_q <=
                    translated_port_a_addr_internal % SOFTMAX_ROW_LANES;
            if (normal_b_storage_req)
                ordinary_b_bank_q <= port_b_storage_addr % SOFTMAX_ROW_LANES;
            if (accepted_packed_read)
                packed_read_bank_q <=
                    translated_packed_read_addr % SOFTMAX_ROW_LANES;
        end
    end

    assign port_a_fp_out_internal = bank_a_rdata[ordinary_a_bank_q];
    assign port_b_fp_out_internal = bank_b_rdata[ordinary_b_bank_q];
    assign packed_read_data = bank_a_rdata[packed_read_bank_q];
    assign packed_read_valid = packed_read_valid_q;
    assign group_read_valid = group_read_valid_q;
    always_comb begin
        group_read_data = '0;
        for (int lane = 0; lane < SOFTMAX_ROW_LANES; lane++) begin
            if (lane < group_read_active_rows_q)
                group_read_data[lane] = bank_a_rdata[lane];
        end
    end

`ifdef SIMULATION
    // Preserve the old flat dump contract even though the physical storage is
    // now banked.  This mirror is simulation-only and has no synthesis cost.
    logic [VLEN-1:0][FP_WIDTH-1:0] sim_mem_flat [0:SRAM_DEPTH-1];
    always_ff @(posedge clk) begin
        for (int bank = 0; bank < SOFTMAX_ROW_LANES; bank++) begin
            if (bank_a_req[bank] && bank_a_write[bank]) begin
                for (int lane = 0; lane < VLEN; lane++) begin
                    if (bank_a_wmask[bank][lane])
                        sim_mem_flat[bank_a_addr[bank] * SOFTMAX_ROW_LANES + bank][lane]
                            <= bank_a_wdata[bank][lane];
                end
            end
            if (bank_b_req[bank] && bank_b_write[bank]) begin
                for (int lane = 0; lane < VLEN; lane++) begin
                    if (bank_b_wmask[bank][lane])
                        sim_mem_flat[bank_b_addr[bank] * SOFTMAX_ROW_LANES + bank][lane]
                            <= bank_b_wdata[bank][lane];
                end
            end
        end
    end
    final begin
        if (MEM_RESULT_FILE != "")
            $writememh(MEM_RESULT_FILE, sim_mem_flat);
    end

    always_ff @(posedge clk) begin
        if (!rst && accepted_group_read &&
            translated_group_read_addr % SOFTMAX_ROW_LANES)
            $fatal(1, "row-group read base is not bank aligned");
        if (!rst && accepted_group_write &&
            translated_group_write_addr % SOFTMAX_ROW_LANES)
            $fatal(1, "row-group write base is not bank aligned");
        if (!rst && group_read_req &&
            (group_read_active_rows == 0 ||
             group_read_active_rows > SOFTMAX_ROW_LANES))
            $fatal(1, "invalid row-group read active count");
        if (!rst && group_write_req &&
            (group_write_active_rows == 0 ||
             group_write_active_rows > SOFTMAX_ROW_LANES))
            $fatal(1, "invalid row-group write active count");
    end
`endif


endmodule
