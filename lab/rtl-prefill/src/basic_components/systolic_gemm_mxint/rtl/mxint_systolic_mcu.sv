`timescale 1ns / 1ps
/*
Module      : MXINT Systolic Matrix Compute Unit (MCU)
Timing      : Sequential
Description : GEMM compute unit for MXINT operands. C[BLEN][BLEN] = A[BLEN][MLEN] · B[MLEN][BLEN].

              GEMM-only for now (GEMV deferred): `control` accepts MM_IC (load
              operands + compute one tile) and MM_WO (write the accumulated result
              out + clear). The MLEN reduction is split across ROW_BLOCK_NUM = MLEN/KLEN
              parallel mini systolic arrays (spatial-K split); each mini array
              accumulates KLEN deep.

              Output path: each mini array produces a partial BLEN×BLEN tile in
              INTEGER (lossless accumulator + biased scale); mxint_sum_across reduces
              the partials in the INTEGER domain; BLEN×BLEN INT→FP converters produce
              one storage-FP tile. That tile is then accumulated in an FP accumulator
              bank (one fp_fix_accumulator per output position) — so successive MM_IC
              tiles sum together. MM_WO drains the bank to v_result (row by row) and
              clears it.

Operand mapping:
   v1 = TOP   (multiplicand) — per-block scale
   v2 = LEFT  (multiplier)   — per-block scale
*/

module mxint_systolic_mcu #(
    // Storage (output) FP format
    parameter FP_EXP_WIDTH        = 8,
    parameter FP_MANT_WIDTH       = 7,
    // MXINT data format
    parameter MX_T_INT_WIDTH      = 4,   // v1 (TOP)  element width
    parameter MX_L_INT_WIDTH      = 4,   // v2 (LEFT) element width
    parameter MXINT_SCALE_WIDTH   = 8,
    parameter KLEN                = 4,   // MXINT scale block size (= mini-array depth)
    // Dimensions  (C[BLEN][BLEN] = A[BLEN][MLEN] · B[MLEN][BLEN])
    parameter BLEN                = 4,   // output tile edge (M = N)
    parameter MLEN                = 8,   // reduction depth per instruction
    // Cross-K reduction headroom (max alignment shift in the integer adder tree)
    parameter MAX_SHIFT           = 16,
    // FP accumulator sizing (fixed-point internal width of fp_fix_accumulator)
    parameter FP_ACC_INT_WIDTH    = 16,
    parameter FP_ACC_FRAC_WIDTH   = 16,
    localparam ROW_BLOCK_NUM      = MLEN / KLEN
)(
    input  logic clk,
    input  logic rst,
    input  logic [3:0] control,                             // M_OP: MM_IC (load) / MM_WO (write)

    // Multiplicand Matrix 1 TOP
    input  logic [MLEN-1:0][MX_T_INT_WIDTH-1:0]            v1_element,
    input  logic [MLEN-1:0][MXINT_SCALE_WIDTH-1:0]        v1_scale,    // per-element (block scale broadcast across the KLEN elements)
    input  logic                                          v1_in_valid,

    // Multiplier Matrix 2 LEFT
    input  logic [MLEN-1:0][MX_L_INT_WIDTH-1:0]            v2_element,
    input  logic [ROW_BLOCK_NUM-1:0][MXINT_SCALE_WIDTH-1:0] v2_scale,   // per-block
    input  logic                                          v2_in_valid,

    // Result output: one BLEN-wide row per cycle for BLEN cycles
    output logic [BLEN-1:0][FP_EXP_WIDTH+FP_MANT_WIDTH:0]  v_result,
    output logic v_result_write_req,
    output logic mcu_active              // Systolic array in use (computing or draining)
);

    initial begin
        if (MLEN % KLEN != 0) begin
            $error("MLEN (%0d) must be a multiple of KLEN (%0d)", MLEN, KLEN);
            $finish;
        end
    end

    // M_OP encodings (from operation.svh; inlined to avoid header include dependency)
    localparam [3:0] OP_STALL_M = 4'h0;
    localparam [3:0] OP_MM_IC   = 4'h5;   // load operands
    localparam [3:0] OP_MM_WO   = 4'h7;   // write result out

    localparam FP_W = FP_EXP_WIDTH + FP_MANT_WIDTH;          // storage element (msb index)
    localparam ROW_W = $clog2(BLEN + 1);                      // drain row counter width

    // Derived MXINT datapath widths
    localparam ACC_EXPAND_WIDTH    = $clog2(KLEN);
    localparam MINI_INT_WIDTH      = MX_T_INT_WIDTH + MX_L_INT_WIDTH + ACC_EXPAND_WIDTH;
    localparam MINI_SCALE_WIDTH    = MXINT_SCALE_WIDTH + 1;
    localparam SUM_EXTRA           = $clog2(ROW_BLOCK_NUM + 1);
    localparam SUM_INT_WIDTH       = MINI_INT_WIDTH + MAX_SHIFT + SUM_EXTRA;
    localparam MX_ACC_FRAC_WIDTH   = MX_T_INT_WIDTH + MX_L_INT_WIDTH - 2;

    // Forward declarations for drain FSM (used in control logic)
    logic [ROW_W-1:0] drain_row;
    logic draining;

    // ==============================================================================================
    // Control: FSM tracking the currently executing operation.
    // - mcu_active (compute_busy || draining) indicates systolic array is in use
    // - MM_WO arriving while draining is held (mm_wo_pending) until drain completes
    // - MM_WO arriving while computing goes to control_exe (drain starts after compute)
    // ==============================================================================================
    logic [3:0] control_exe;
    logic mm_wo_pending;

    always_ff @(posedge clk) begin
        if (rst) begin
            control_exe    <= OP_STALL_M;
            mm_wo_pending  <= 1'b0;
        end else begin
            // MM_WO during draining: capture for later
            if (control == OP_MM_WO && draining) begin
                mm_wo_pending <= 1'b1;
            end

            // Drain finished
            if (draining && drain_row == ROW_W'(BLEN-1)) begin
                if (mm_wo_pending) begin
                    control_exe   <= OP_MM_WO;  // Pass pending MM_WO
                    mm_wo_pending <= 1'b0;
                end else begin
                    control_exe <= OP_STALL_M;
                end
            // Accept new instruction when not draining
            end else if (!draining && control != OP_STALL_M) begin
                control_exe <= control;
            end
        end
    end

    // Per-tile soft reset for the mini arrays (driven below). The PE accumulators /
    // load counters are one-tile-per-reset, so each new tile gets a clean array.
    logic mini_clear;

    // ==============================================================================================
    // Input path: directly feed mini arrays. The mini array's internal roller buffers
    // handle the systolic timing/buffering. No external streamers needed.
    // Data is accepted when BOTH v1 and v2 are valid to ensure synchronization.
    // ==============================================================================================
    logic load_active;
    assign load_active = v1_in_valid && v2_in_valid;

    // ==============================================================================================
    // ROW_BLOCK_NUM parallel mini systolic arrays (one per K-segment) — INT partials.
    //   v1 (TOP)  -> mini load_b_col ;  v2 (LEFT) -> mini load_a_row
    // ==============================================================================================
    logic [ROW_BLOCK_NUM-1:0][BLEN-1:0][BLEN-1:0][MINI_INT_WIDTH-1:0]   partial_int;
    logic [ROW_BLOCK_NUM-1:0][BLEN-1:0][BLEN-1:0][MINI_SCALE_WIDTH-1:0] partial_scale;
    logic [ROW_BLOCK_NUM-1:0] mini_out_valid;

    generate
        for (genvar p = 0; p < ROW_BLOCK_NUM; p++) begin : g_mini
            mxint_mini_systolic_array #(
                .MX_T_INT_WIDTH    (MX_T_INT_WIDTH),
                .MX_L_INT_WIDTH    (MX_L_INT_WIDTH),
                .MXINT_SCALE_WIDTH (MXINT_SCALE_WIDTH),
                .BLOCK_DIM         (BLEN),
                .ACC_DEPTH         (KLEN)
            ) mini (
                .clk          (clk),
                .rst          (rst || mini_clear),
                .load_a_row   (v2_element[p*KLEN +: KLEN]),   // LEFT
                .load_b_col   (v1_element[p*KLEN +: KLEN]),   // TOP
                .load_a_scale (v2_scale[p]),                  // per-block
                .load_b_scale (v1_scale[p*KLEN]),             // per-element bus, same scale across the block — take the first
                .load_valid   (load_active),
                .out_int      (partial_int[p]),
                .out_scale    (partial_scale[p]),
                .out_valid    (mini_out_valid[p])
            );
        end
    endgenerate

    // ==============================================================================================
    // Cross-K reduction in the INTEGER domain (align scales, integer add).
    // ==============================================================================================
    logic [BLEN-1:0][BLEN-1:0][SUM_INT_WIDTH-1:0]    reduced_int;
    logic [BLEN-1:0][BLEN-1:0][MINI_SCALE_WIDTH-1:0] reduced_scale;
    logic reduced_valid;

    mxint_sum_across #(
        .INT_WIDTH        (MINI_INT_WIDTH),
        .SCALE_WIDTH      (MINI_SCALE_WIDTH),
        .COMPUTE_DIM      (BLEN),
        .SYS_ARRAY_AMOUNT (ROW_BLOCK_NUM),
        .MAX_SHIFT        (MAX_SHIFT)
    ) cross_k_reduce (
        .clk         (clk),
        .rst         (rst),
        .m_in_int    (partial_int),
        .m_in_scale  (partial_scale),
        .in_valid    (&mini_out_valid),
        .m_out_int   (reduced_int),
        .m_out_scale (reduced_scale),
        .out_valid   (reduced_valid)
    );

    // INT accumulator -> storage FP directly (a single conversion, no intermediate
    // accumulator-FP precision).
    logic [BLEN-1:0][BLEN-1:0][FP_W:0] gebm_result;

    generate
        for (genvar i = 0; i < BLEN; i++) begin : g_fp_row
            for (genvar j = 0; j < BLEN; j++) begin : g_fp_col
                mxint_acc_2_fp #(
                    .ACC_WIDTH         (SUM_INT_WIDTH),
                    .ACC_FRAC_WIDTH    (MX_ACC_FRAC_WIDTH),
                    .IN_SCALE_WIDTH    (MINI_SCALE_WIDTH),
                    .MXINT_SCALE_WIDTH (MXINT_SCALE_WIDTH),
                    .FP_EXP_WIDTH      (FP_EXP_WIDTH),
                    .FP_MANT_WIDTH     (FP_MANT_WIDTH)
                ) acc_to_fp (
                    .acc_in   (reduced_int[i][j]),
                    .scale_in (reduced_scale[i][j]),
                    .fp_out   (gebm_result[i][j])
                );
            end
        end
    endgenerate

    // ==============================================================================================
    // One accumulate pulse per computed tile. reduced_valid HOLDS high once the tile
    // is ready (PE out_valid latches, sum_across registers hold), so we edge-detect its
    // rise to add the tile into the FP accumulator exactly once.
    // ==============================================================================================
    logic reduced_valid_q;
    logic accumulate_pulse;
    always_ff @(posedge clk) begin
        if (rst) reduced_valid_q <= 1'b0;
        else     reduced_valid_q <= reduced_valid;
    end
    assign accumulate_pulse = reduced_valid && !reduced_valid_q;

    // compute_busy: high from the start of an MM_IC load until that tile's result has
    // been captured into the FP accumulator (accumulate_pulse). Combined with draining
    // to form mcu_active — "the systolic array is in use".
    logic compute_busy;
    always_ff @(posedge clk) begin
        if (rst)                   compute_busy <= 1'b0;
        else if (load_active)      compute_busy <= 1'b1;
        else if (accumulate_pulse) compute_busy <= 1'b0;
    end

    // Soft-reset the mini arrays once a tile's result has been captured into the FP
    // accumulator, held through the idle gap, dropped the instant the next load begins
    // (`!load_active` keeps the clear from wiping the fresh load).
    logic mini_clear_pending;
    assign mini_clear = mini_clear_pending && !load_active;
    always_ff @(posedge clk) begin
        if (rst)                   mini_clear_pending <= 1'b0;
        else if (load_active)      mini_clear_pending <= 1'b0;
        else if (accumulate_pulse) mini_clear_pending <= 1'b1;
    end

    // ==============================================================================================
    // FP accumulator bank — each MM_IC tile is FP-added; MM_WO drains it out + clears.
    // ==============================================================================================
    logic clear_acc;
    logic [BLEN-1:0][BLEN-1:0][FP_W:0] acc_fp;

    generate
        for (genvar i = 0; i < BLEN; i++) begin : g_acc_row
            for (genvar j = 0; j < BLEN; j++) begin : g_acc_col
                fp_fix_accumulator #(
                    .EXP_WIDTH      (FP_EXP_WIDTH),
                    .MANT_WIDTH     (FP_MANT_WIDTH),
                    .ACC_INT_WIDTH  (FP_ACC_INT_WIDTH),
                    .ACC_FRAC_WIDTH (FP_ACC_FRAC_WIDTH)
                ) acc (
                    .clk               (clk),
                    .rst               (rst),
                    .clear_accumulator (clear_acc),
                    .data_in_valid     (accumulate_pulse),
                    .data_in           (gebm_result[i][j]),
                    .data_out          (acc_fp[i][j]),
                    .data_out_valid    ()
                );
            end
        end
    endgenerate

    // ==============================================================================================
    // Drain FSM: on MM_WO, stream the BLEN accumulator rows to v_result, then clear.
    //
    // Start draining when control_exe == MM_WO and compute is done. control_exe holds
    // MM_WO until drain completes, naturally blocking new instructions.
    // ==============================================================================================
    logic start_drain;

    // Start when control_exe is MM_WO, compute finished, and not already draining
    assign start_drain = (control_exe == OP_MM_WO) && !compute_busy && !accumulate_pulse && !draining;

    always_ff @(posedge clk) begin
        if (rst) begin
            draining  <= 1'b0;
            drain_row <= '0;
            clear_acc <= 1'b0;
        end else begin
            clear_acc <= 1'b0;
            if (start_drain) begin
                draining  <= 1'b1;
                drain_row <= '0;
            end else if (draining) begin
                if (drain_row == ROW_W'(BLEN-1)) begin
                    draining  <= 1'b0;
                    clear_acc <= 1'b1;          // clear AFTER the last row has been read
                end else begin
                    drain_row <= drain_row + 1'b1;
                end
            end
        end
    end

    // v_result_write_req: one pulse per drained output row (BLEN cycles).
    // mcu_active: high when systolic array is in use (computing or draining).
    //             Only goes low after drain completes.
    assign v_result          = acc_fp[drain_row];
    assign v_result_write_req = draining;
    assign mcu_active         = compute_busy || draining;

endmodule
