`timescale 1ns / 1ps

`include "configuration.svh"
`include "operation.svh"

/*
Module      : Decoder
Timing      : Sequential, taking 2 cycles to decode the instruction.
Description :
    Assuming the Instruction Format is as follows:
    [FUNC2] [FUNC1] [RS2]  [RS1] [RD] [OPCODE_WID]   
    [IMM_SHORT]     [RS1]  [RD]  [OPCODE_WID]
    [IMM_LONG]      [RD] [OPCODE_WID]
*/

module decoder import instruction_pkg::*; import configuration_pkg::*; #(
    parameter INSTRUCTION_LENGTH = 32,
    parameter OPERAND_WIDTH      = 4,
    parameter OPCODE_WIDTH       = 6,
    parameter IMM_WIDTH          = 22,
    parameter PC_ADDR_WIDTH      = 16
)(
    input   logic clk,
    input   logic rst,
    input   logic system_stall_flag,
    
    // Pipeline Stall Control
    input   logic pipeline_stall,

    // Instruction Fetching (from instr_mem)
    output  logic [PC_ADDR_WIDTH - 1 : 0] pc,
    input   logic [INSTRUCTION_LENGTH - 1 : 0] instruction_from_imem,
    input   logic [PC_ADDR_WIDTH - 1 : 0] instruction_addr_from_imem, // fetch address of instruction_from_imem
    input   logic instruction_ready,  // Instruction memory has valid data for current PC

    // Decoded Instruction
    output      OP_BUNDLE       decode_stage_op,
    output      S_INT_OP        assigned_int_op,

    output      logic [INT_OPERAND_WIDTH - 1 : 0] rd,
    output      logic [INT_OPERAND_WIDTH - 1 : 0] rs1,
    output      logic [INT_OPERAND_WIDTH - 1 : 0] rs2,
    output      logic [IMM_WIDTH - 1 : 0] imm,
    output      logic agu_boundary_step,
    output      logic agu_boundary_exit,
    output      logic agu_config_valid,
    output      logic [INT_OPERAND_WIDTH-1:0] agu_config_reg,
    output      logic [IMM_WIDTH-1:0] agu_config_stride,
    output      logic agu_frame_start,
    output      logic [INT_OPERAND_WIDTH-1:0] agu_frame_counter_reg,

    `ifdef SIMULATION
    // C_BREAK detection (for simulation clock counting)
    output      logic c_break_detected,
    `endif

    // Loop Control Interface (from ALU)
    input       logic loop_counter_zero

);

// PC Register (byte-addressed, increments by 4)
logic [31:0] pc_reg;
logic [31:0] pc_reg_d1;        // pc_reg delayed 1 cycle = fetch address of loaded_instr
logic [31:0] loop_continue_pc; // address right after C_LOOP_END (robust loop-exit target)
logic [31:0] loop_body_pc;     // address right after C_LOOP_START (robust loop jump-back target)

// Loop Controller Signals
logic loop_start_valid;
logic loop_end_valid;
logic loop_jump_back;
logic [31:0] loop_target_pc;
logic loop_end_stall;
logic loop_exit;
logic [31:0] loop_exit_pc;
logic agu_loop_start_valid;
logic agu_top_active;
logic [31:0] agu_top_marker_pc;
logic agu_boundary_seen;
logic agu_marker_seen;
logic [IMM_WIDTH-1:0] agu_pending_body_len;

logic           system_stall;
logic           stall_for_read_rd;
logic           [INSTRUCTION_LENGTH - 1 : 0] loaded_instr;
logic           read_instr, load_instr_valid;
logic           decode_instr_valid;
logic           p1_pipeline_stall, recover_from_stall, start_from_stall;
logic           early_loop_end_stall, early_loop_end_stall_d1;
logic           loop_end_stall_d1;
logic           effective_pipeline_stall;
logic           fixed_op_stall_flag;
logic           decode_advanced_d;
logic           int_op_pending;
OP_BUNDLE       recorded_op_bundle;
S_INT_OP        exe_int_op;
S_INT_OP        recorded_assigned_int_op;
CUSTOM_ISA_TYPE decode_instruction_type, active_decode_instruction_type;
INSTR_INFO decode_instr_info;

// PC next value calculation with loop support
logic [31:0] pc_next;

always_comb begin
    if (loop_jump_back)
        pc_next = loop_target_pc;  // Jump back to loop start
    else if (loop_exit)
        pc_next = loop_exit_pc;    // Continue from instruction after loop_end
    else
        pc_next = pc_reg + 4;      // Normal increment
end

// In-order exactly-once fetch acceptance.
// expected_decode_pc is the address of the next instruction the decoder may
// consume. A bus word is accepted only when its tagged fetch address matches
// (see fresh_fetch below), which makes duplicate presentations (stall-release
// re-presents, PC rewinds onto consumed slots, stale words across instr_mem
// buffer refills) harmless by construction. fetch_skipped_ahead detects the
// bus running PAST the expected slot (an instruction was dropped, e.g. by a
// rewind shortfall) and pulls the PC back so the missing word is re-served -
// without this, a skipped scalar op silently corrupts every later address.
logic [31:0] expected_decode_pc;
logic fetch_skipped_ahead;
assign fetch_skipped_ahead = load_instr_valid
    && (instruction_addr_from_imem > expected_decode_pc[PC_ADDR_WIDTH - 1 : 0]);

always_ff @(posedge clk) begin
    if (rst)
        pc_reg <= 32'h0;
    else if (loop_jump_back)
        pc_reg <= pc_next;         // Allow jump even during stall
    else if (loop_exit)
        pc_reg <= pc_next;         // Set PC to continuation address when loop exits
    else if (loop_end_stall || early_loop_end_stall)
        pc_reg <= pc_reg;          // Stall PC while waiting for loop counter check
    else if (read_instr & load_instr_valid & !pipeline_stall)
        pc_reg <= fetch_skipped_ahead ? expected_decode_pc : pc_next;
    else if (!p1_pipeline_stall & pipeline_stall & !early_loop_end_stall_d1 & !loop_end_stall_d1)
        pc_reg <= pc_reg - 4;      // Exclude the loop end instruciton stalls (incl. the cycle after a jump-back hold).
end

assign pc = pc_reg;

// Loop Controller Instance
loop_controller #(
    .PC_WIDTH(32)
) u_loop_controller (
    .clk                (clk),
    .rst                (rst),
    .loop_start_valid   (loop_start_valid),
    .agu_loop_start_valid (agu_loop_start_valid),
    .loop_end_valid     (loop_end_valid),
    .agu_boundary_valid (agu_boundary_seen),
    .loop_counter_reg   (decode_instr_info.rd[INT_OPERAND_WIDTH-1:0]),
    .agu_iteration_count(decode_instr_info.imm),
    .agu_marker_pc      (
        loop_body_pc
        + ({{(32-IMM_WIDTH){1'b0}}, agu_pending_body_len} << 2)
    ),
    .current_pc         (pc_reg),
    .loop_continue_pc   (loop_continue_pc),
    .loop_start_target  (loop_body_pc),
    .loop_counter_zero  (loop_counter_zero),
    .loop_jump_back     (loop_jump_back),
    .loop_target_pc     (loop_target_pc),
    .loop_end_stall     (loop_end_stall),
    .loop_exit          (loop_exit),
    .loop_exit_pc       (loop_exit_pc),
    .agu_top_active     (agu_top_active),
    .agu_top_marker_pc  (agu_top_marker_pc),
    .agu_boundary_step  (agu_boundary_step),
    .agu_boundary_exit  (agu_boundary_exit)
);

// Generate loop control signals when instruction is valid and decoded.
// NOTE: loop_start_valid must NOT be gated by !pipeline_stall. decode_instr_valid is a
// single fresh-fetch pulse per instruction; if a C_LOOP_START's only fresh-fetch cycle
// reduction RAW), gating it here drops the loop-stack PUSH entirely -- the PC then
// rewinds onto the same address (pc_reg == pc_reg_d1, fresh_fetch = 0) and the
// instruction is never re-presented, so the matching C_LOOP_END later finds an empty
// stack and the loop hangs forever. The loop_controller de-dups the push via
// reg_already_on_stack, so firing during a stall is safe and pushes exactly once.
// (loop_end_valid stays gated: its counter decrement must not repeat across a stall.)
assign loop_start_valid = decode_instr_valid && (decode_instr_info.opcode == C_LOOP_START);
assign agu_loop_start_valid = decode_instr_valid
    && (decode_instr_info.opcode == C_LOOP_START_AGU);
assign agu_config_valid = decode_instr_valid
    && (decode_instr_info.opcode == C_AGU_CONFIG)
    && (decode_instr_info.rd != '0);
assign agu_config_reg = decode_instr_info.rd[INT_OPERAND_WIDTH-1:0];
assign agu_config_stride = decode_instr_info.imm;
assign agu_frame_start = agu_loop_start_valid;
assign agu_frame_counter_reg =
    decode_instr_info.rd[INT_OPERAND_WIDTH-1:0];
assign loop_end_valid   = decode_instr_valid && (decode_instr_info.opcode == C_LOOP_END) && !pipeline_stall;
// The marker may arrive while the preceding body instruction is held by a
// pipeline or operand-helper stall.  Merely seeing its fetch address is not a
// valid loop boundary: offsets must advance only after that body instruction
// has been accepted.  Keep the marker unconsumed until all frontend gates are
// open, then redirect before it enters decode.
assign agu_marker_seen = load_instr_valid && agu_top_active
    && (instruction_addr_from_imem == agu_top_marker_pc[PC_ADDR_WIDTH-1:0]);
assign agu_boundary_seen = agu_marker_seen
    && !effective_pipeline_stall
    && !stall_for_read_rd
    && !fixed_op_stall_flag
    && (system_stall == 1'b0)
    && !loop_end_stall;

logic rd_operand_ready; // The stall is for loading the third operand from the register files.
logic m_update_waddr, v_update_waddr;
logic recorded_m_update_waddr, recorded_v_update_waddr;
logic pass_m_update_waddr, pass_v_update_waddr;
logic [INT_OPERAND_WIDTH - 1 : 0] rd_to_load;
logic [INT_OPERAND_WIDTH - 1 : 0] recorded_rd_to_load;
logic [INT_OPERAND_WIDTH - 1 : 0] pass_rd_to_load;
logic stall_for_read_rd_flag;
logic decode_advanced;
logic recorded_stall_for_read_rd_flag;

// Skid buffer for the 3-operand vector operand-load helper.
// When stall_for_read_rd inserts the helper cycle it forces read_instr low,
// which drops whatever fresh instruction is sitting on loaded_instr that cycle
// (the op two slots behind the vector op - e.g. the S_ADDI stride bump right
// before C_LOOP_END). Capture it here and replay it the cycle after the helper,
// in program order. This leaves the PC / fresh_fetch / loop look-ahead timing
// untouched, so paths with no V_*_VV op (e.g. the preload loop) are unchanged.
INSTR_INFO skid_instr_info;
logic      skid_valid;       // a rescued instruction is buffered
logic      skid_injected;    // decode_instr_info currently holds the replayed op

assign  read_instr = !effective_pipeline_stall & !stall_for_read_rd & !fixed_op_stall_flag
    & (system_stall == 1'b0) & !loop_end_stall & !agu_boundary_seen;

// Fresh-fetch detection, address-tagged.
// The instruction bus now carries the fetch address it was served for
// (instruction_addr_from_imem). A bus word is fresh exactly when it is the
// next instruction in program order (expected_decode_pc). This subsumes the
// old PC-movement heuristic (pc_reg != pc_reg_d1) and the early_loop_end_stall
// exception, and is immune to the cases the heuristic missed: stall-release
// re-presents, multiple PC rewinds with no fetch in between, and stale bus
// words held across instr_mem buffer refills - each of which previously let
// one already-consumed instruction latch (and execute) a second time.
logic fresh_fetch;
assign fresh_fetch = (instruction_addr_from_imem == expected_decode_pc[PC_ADDR_WIDTH - 1 : 0]);

// expected_decode_pc advances exactly when a bus word is consumed: latched
// into decode_instr_info (normal path) or rescued into the skid buffer (the
// stall_for_read_rd helper cycle). Loop control re-aims it the same way it
// re-aims the PC.
always_ff @(posedge clk) begin
    if (rst) begin
        expected_decode_pc <= 32'h0;
    end else if (loop_jump_back) begin
        expected_decode_pc <= loop_target_pc;
    end else if (loop_exit) begin
        expected_decode_pc <= loop_exit_pc;
    end else if (!pipeline_stall && load_instr_valid && fresh_fetch
                 && !agu_marker_seen
                 && (   (stall_for_read_rd && !skid_valid)
                     || (!stall_for_read_rd && !skid_valid && read_instr))) begin
        expected_decode_pc <= expected_decode_pc + 4;
    end
end

// Direct connection to instruction memory
assign loaded_instr     = instruction_from_imem;
assign load_instr_valid = instruction_ready;

// Operand Assignments
logic [OPCODE_WIDTH - 1 : 0]    loaded_opcode;
logic [OPERAND_WIDTH:0]         loaded_rs1;
logic [OPERAND_WIDTH:0]         loaded_rs2;
logic [OPERAND_WIDTH:0]         loaded_rstride;
logic [OPERAND_WIDTH:0]         loaded_rd;
logic [IMM_WIDTH - 1 : 0]       loaded_imm;
logic [FUNCT_WIDTH - 1 : 0]     loaded_funct1;

assign loaded_imm       = ((loaded_opcode == S_ADDI_INT) || (loaded_opcode == S_LD_FP)  || (loaded_opcode == S_ST_FP)
                                                         || (loaded_opcode == S_LD_INT) || (loaded_opcode == S_ST_INT) ) ? 
                                                         {{(IMM_WIDTH - IMM_2_WIDTH){1'b0}} , loaded_instr[INSTRUCTION_LENGTH - 1 -: IMM_2_WIDTH]} :
                          (loaded_opcode == M_MM_WO) ?
                                                         {{(IMM_WIDTH - IMM_2_WIDTH){1'b0}} , loaded_instr[INSTRUCTION_LENGTH - 1 -: IMM_2_WIDTH]} :
                                                         loaded_instr[INSTRUCTION_LENGTH - 1 -: IMM_WIDTH];

assign loaded_rd        = loaded_instr[OPERAND_WIDTH + OPCODE_WIDTH - 1 -: OPERAND_WIDTH];
assign loaded_rs1       = loaded_instr[2 * OPERAND_WIDTH + OPCODE_WIDTH - 1 -: OPERAND_WIDTH];
assign loaded_rs2       = loaded_instr[3 * OPERAND_WIDTH + OPCODE_WIDTH - 1 -: OPERAND_WIDTH];

assign loaded_opcode    = loaded_instr[OPCODE_WIDTH - 1 : 0];
assign loaded_funct1    = loaded_instr[INSTRUCTION_LENGTH - 1 -: FUNCT_WIDTH];
assign loaded_rstride   = loaded_instr[4 * OPERAND_WIDTH + OPCODE_WIDTH - 1 -: OPERAND_WIDTH];

// Early detection of C_LOOP_END from instruction memory output (look-ahead)
// This stalls the PC one cycle earlier than loop_end_stall, preventing the PC
// from advancing past the C_LOOP_END instruction during decode latency.
// Without this, nested loops fail because the decoder skips inner loop's
// C_LOOP_END and processes the outer loop's C_LOOP_END instead.
assign early_loop_end_stall = load_instr_valid && (loaded_opcode == C_LOOP_END)
    && !agu_top_active && !loop_end_stall;

// Delayed version of early_loop_end_stall for the decode output stage.
// When early_loop_end_stall first goes HIGH, the instruction BEFORE C_LOOP_END
// (e.g., S_ADDI_INT gp2, gp2, 512) has just been registered into decode_instr_info
// but not yet processed. We need one more cycle to output that instruction.
// Using a delayed signal allows the decode output stage to process the instruction
// in decode_instr_info before stalling.
always_ff @(posedge clk) begin
    if (rst)
        early_loop_end_stall_d1 <= 1'b0;
    else
        early_loop_end_stall_d1 <= early_loop_end_stall;
end

// Delayed version of loop_jump_back for the decode output stage.
// When loop_jump_back occurs, PC jumps to the loop target on the next cycle,
// but loop_end_stall is still HIGH. We need to allow decoding on that cycle
// so the instruction at the jump target gets processed.
logic loop_jump_back_d1;
always_ff @(posedge clk) begin
    if (rst)
        loop_jump_back_d1 <= 1'b0;
    else
        loop_jump_back_d1 <= loop_jump_back;
end

// Delayed version of loop_end_stall, used to gate the pipeline-stall PC rewind.
// While loop_end_stall is high the PC is HELD (not advanced), so on the cycle
// immediately after it drops the PC is still pointing at the instruction to
// fetch - not one past it. The rewind (pc_reg <= pc_reg - 4) assumes the PC
// advanced past a stalled instruction, which is false here. Without this guard,
// a pipeline_stall on the first loop-body instruction right after a jump-back
// rewinds the PC onto C_LOOP_START and re-initializes the loop counter.
always_ff @(posedge clk) begin
    if (rst)
        loop_end_stall_d1 <= 1'b0;
    else
        loop_end_stall_d1 <= loop_end_stall;
end

// Robust loop-exit continuation PC.
// Instruction memory has 1-cycle latency, so the instruction currently in
// loaded_instr was fetched from pc_reg one cycle earlier (pc_reg_d1). When the
// C_LOOP_END look-ahead (early_loop_end_stall) fires, loaded_instr IS C_LOOP_END,
// so its address is pc_reg_d1 and the instruction after the loop is pc_reg_d1 + 4.
// Capturing this here (instead of snapshotting the fetch PC inside loop_controller)
// is immune to stalls that hold pc_reg on the C_LOOP_END slot - e.g. a
// stall_for_read_rd from a preceding 3-operand vector op, which otherwise makes
// the captured continuation point at C_LOOP_END itself and loops forever.
always_ff @(posedge clk) begin
    if (rst) begin
        pc_reg_d1        <= 32'h0;
        loop_continue_pc <= 32'h0;
        loop_body_pc     <= 32'h0;
    end else begin
        pc_reg_d1 <= pc_reg;
        if (early_loop_end_stall)
            loop_continue_pc <= pc_reg_d1 + 4;
        // Robust loop jump-back target. By the same reasoning as loop_continue_pc:
        // when loaded_instr IS C_LOOP_START its fetch address is pc_reg_d1, so the
        // first loop-body instruction is pc_reg_d1 + 4. Capturing it here (instead of
        // snapshotting current_pc - 4 inside loop_controller) is immune to a stall on
        // the instruction before C_LOOP_START - e.g. a preceding S_RECI_FP/SFU stall -
        // which otherwise leaves the captured target on C_LOOP_START itself, so every
        // jump-back re-initialises the counter and the loop never exits.
        if (load_instr_valid
                && ((loaded_opcode == C_LOOP_START)
                    || (loaded_opcode == C_LOOP_START_AGU)))
            loop_body_pc <= pc_reg_d1 + 4;
    end
end

always_ff @(posedge clk) begin
    if (rst) begin
        agu_pending_body_len <= '0;
    end else if (decode_instr_valid
            && (decode_instr_info.opcode == C_AGU_CONFIG)
            && (decode_instr_info.rd == '0)) begin
        agu_pending_body_len <= decode_instr_info.imm;
    end
end

// Loop processing has priority over external pipeline stalls (e.g., from addr_monitor)
// The loop controller timing is critical (6-cycle sequence) and cannot be interrupted.
// External stalls (memory hazards, FP stalls) can safely wait until loop completes
// because C_LOOP_END only performs scalar integer operations (LOOP_DEC).
logic loop_in_progress;
assign loop_in_progress = early_loop_end_stall || loop_end_stall;

// Effective pipeline stall: masked during loop processing
// This allows C_LOOP_END to be decoded even if addr_monitor triggers a stall
assign effective_pipeline_stall = pipeline_stall && !loop_in_progress;
assign active_decode_instruction_type = decode_instr_valid ? decode_instr_info.instruction_type : INVALID_TYPE;

always_comb begin
    case (loaded_opcode)
        // Matrix Operations
        M_MM, M_TMM, M_MM_WO, M_MV, M_TMV, M_MV_WO: begin
            decode_instruction_type = M;
        end

        // Vector Operations
        V_ADD_VV, V_ADD_VF, V_SUB_VV, V_SUB_VF, V_MUL_VV, V_MUL_VF, V_EXP_V, V_RECI_V,
        V_RED_SUM, V_RED_MAX, V_RED_SUM_SEG, V_RED_MAX_SEG,
        V_RED_SUM_SEGS, V_RED_MAX_SEGS, V_ALU_VSEG,
        S_LD_VLANE_FP, S_ST_VLANE_FP,
        C_HADAMARD_TRANSFORM, V_PS_V, V_SHFT_V : begin
            decode_instruction_type = V;
        end

        // Scalar INT Operations
        S_ADD_INT, S_ADDI_INT, S_SUB_INT, S_MUL_INT, S_LUI_INT, S_LD_INT, S_ST_INT: begin
            decode_instruction_type = S_INT;
        end

        // Scalar FP Operations
        S_ADD_FP, S_SUB_FP, S_MAX_FP, S_MUL_FP, S_EXP_FP, S_RECI_FP,
        S_SQRT_FP, S_MV_FP, S_RSQRT_FP, S_LD_FP, S_ST_FP, S_MAP_V_FP: begin
            decode_instruction_type = S_FP;
        end

        // Memory Operations
        H_PREFETCH_M, H_PREFETCH_V, H_STORE_V: begin
            decode_instruction_type = H;
        end

        // CSR Setting and Loop Control
        C_SET_ADDR_REG, C_SET_SCALE_REG, C_SET_STRIDE_REG, C_SET_V_MASK_REG,
        C_BREAK, C_LOOP_START, C_LOOP_END, C_AGU_CONFIG, C_LOOP_START_AGU: begin
            decode_instruction_type = C;
        end

        default: begin
            decode_instruction_type = INVALID_TYPE;
        end

    endcase
end

// Decoding
always_ff @(posedge clk) begin
    if (rst) begin
        recorded_stall_for_read_rd_flag <= 1'b0;
        recorded_m_update_waddr         <= 1'b0;
        recorded_v_update_waddr         <= 1'b0;
        recorded_rd_to_load             <= {INT_OPERAND_WIDTH{1'b0}};
        p1_pipeline_stall               <= 1'b0;
        exe_int_op                      <= STALL_S_INT;
        decode_advanced_d               <= 1'b0;
        int_op_pending                  <= 1'b0;
        system_stall                    <= 1'b0;
        decode_instr_valid              <= 1'b0;
        decode_instr_info               <= '{opcode: '0, rs1: '0, rs2: '0, rstride: '0, rd: '0, imm: '0, funct1: '0, instruction_type: INVALID_TYPE};
        skid_instr_info                 <= '{opcode: '0, rs1: '0, rs2: '0, rstride: '0, rd: '0, imm: '0, funct1: '0, instruction_type: INVALID_TYPE};
        skid_valid                      <= 1'b0;
        skid_injected                   <= 1'b0;
    end else begin
        if (system_stall_flag) begin
            system_stall <= 1'b1;
        end
        if (!pipeline_stall) begin
            // During stall_for_read_rd the PC is held and read_instr is forced low to
            // insert the third-operand load. decode_instr_info already holds the pending
            // instruction (its update is gated on read_instr), so decode_instr_valid must
            // be held too - otherwise the held instruction's valid bit is cleared and the
            // instruction is dropped (active_decode_instruction_type -> INVALID_TYPE) when
            // the stall releases on the next cycle.
            // Only accept a fetch that presents a NEW instruction (fresh_fetch); a stale
            // repeat on stall release (pc_reg == pc_reg_d1) is ignored so each instruction
            // is latched exactly once.
            if (stall_for_read_rd) begin
                decode_instr_valid <= decode_instr_valid;  // hold during operand-load helper
                skid_injected      <= 1'b0;
                // Rescue the fresh instruction the helper is about to drop.
                if (load_instr_valid & fresh_fetch & !skid_valid
                        & !agu_marker_seen) begin
                    skid_instr_info <= '{opcode: loaded_opcode, rs1: loaded_rs1, rs2: loaded_rs2, rstride: loaded_rstride, rd: loaded_rd, imm: loaded_imm, funct1: loaded_funct1, instruction_type: decode_instruction_type};
                    skid_valid      <= 1'b1;
                end
            end else if (skid_valid) begin
                // Replay the buffered instruction before consuming new fetches.
                // The next real fetch is re-presented naturally (pc_reg_d1 lag /
                // held PC), so nothing is lost and program order is preserved.
                decode_instr_valid <= 1'b1;
                decode_instr_info  <= skid_instr_info;
                skid_valid         <= 1'b0;
                skid_injected      <= 1'b1;
            end else if (read_instr & load_instr_valid & fresh_fetch) begin
                decode_instr_valid <= 1'b1;
                decode_instr_info  <= '{opcode: loaded_opcode, rs1: loaded_rs1, rs2: loaded_rs2, rstride: loaded_rstride, rd: loaded_rd, imm: loaded_imm, funct1: loaded_funct1, instruction_type: decode_instruction_type};
                skid_injected      <= 1'b0;
            end else begin
                decode_instr_valid <= 1'b0;
                skid_injected      <= 1'b0;
            end
        end else if (load_instr_valid & fresh_fetch & !skid_valid
                & ((loaded_opcode == C_LOOP_START)
                    || (loaded_opcode == C_LOOP_START_AGU))) begin
            // General pipeline stall: an instruction freshly fetched this cycle is not
            // latched (decode_instr_valid/info update only when !pipeline_stall), and after
            // the stall the PC rewind lands pc == pc_reg_d1 (fresh_fetch = 0) so it is never
            // re-presented -> its decode is lost. For a C_LOOP_START that drops the loop-stack
            // push, so the matching C_LOOP_END finds an empty stack and the loop hangs forever.
            // Rescue ONLY C_LOOP_START into the skid buffer to be replayed when the stall
            // clears (same mechanism the stall_for_read_rd helper uses above). Scoping it to
            // C_LOOP_START avoids double-decoding data ops (which the PC rewind re-presents
            // naturally); a doubly-seen C_LOOP_START is harmless -- it writes no data and the
            // loop_controller de-dups the push via reg_already_on_stack.
            skid_instr_info <= '{opcode: loaded_opcode, rs1: loaded_rs1, rs2: loaded_rs2, rstride: loaded_rstride, rd: loaded_rd, imm: loaded_imm, funct1: loaded_funct1, instruction_type: decode_instruction_type};
            skid_valid      <= 1'b1;
        end
        recorded_stall_for_read_rd_flag <= stall_for_read_rd_flag;
        recorded_m_update_waddr         <= m_update_waddr;
        recorded_v_update_waddr         <= v_update_waddr;
        recorded_rd_to_load             <= rd_to_load;
        p1_pipeline_stall               <= pipeline_stall;
        if (start_from_stall) begin
            recorded_assigned_int_op    <= assigned_int_op;
        end
        // The scalar unit must respect pipeline stalls: letting it run ahead
        // during a stall lets later S_ADDIs clobber the register state an
        // in-flight M op's PASS_ADDR read depends on, and the held PASS
        // re-reads the modified registers (operand addresses come out zeroed
        // or post-incremented). Freeze the scalar op during stalls; the
        // recover path replays the recorded op against unmodified registers.
        // Exactly-once scalar dispatch: fire assigned_int_op only when it was
        // freshly written last cycle (decode_advanced_d) or was pended by a
        // stall that hit at the fire moment. A stale assigned held through a
        // stall never re-fires; a not-yet-fired op is never lost.
        decode_advanced_d               <= decode_advanced;
        if (!pipeline_stall && (decode_advanced_d || int_op_pending)) begin
            exe_int_op                  <= assigned_int_op;
            int_op_pending              <= 1'b0;
        end else begin
            exe_int_op                  <= STALL_S_INT;
            if (decode_advanced_d && pipeline_stall) begin
                int_op_pending          <= 1'b1;
            end
        end
    end
end

assign recover_from_stall   = !pipeline_stall & p1_pipeline_stall;
assign start_from_stall     = pipeline_stall & !p1_pipeline_stall;

always_comb begin
    // Instructions that requires three operands. Insert additionally operation to load the third operand, the insertion takes place only when the pipeline is not stalled.
    if (!start_from_stall & pipeline_stall & recorded_stall_for_read_rd_flag) begin
        stall_for_read_rd   = 1'b1;
    end else if (rd_operand_ready == 1'b0 & (decode_stage_op.v_ele_op != STALL_V_ELEMENT)) begin
        m_update_waddr          = 1'b0;
        v_update_waddr          = 1'b1;
        if (decode_stage_op.v_broadcast_en == 1'b0) begin
            stall_for_read_rd_flag  = 1'b1;
        end else begin
            stall_for_read_rd_flag  = 1'b0;
        end
        rd_to_load              = rd;
    end else begin
        m_update_waddr          = 1'b0;
        v_update_waddr          = 1'b0;
        stall_for_read_rd_flag  = 1'b0;
        rd_to_load              = {INT_OPERAND_WIDTH{1'b0}};
    end

    if (!pipeline_stall & !recorded_stall_for_read_rd_flag) begin
        stall_for_read_rd   = stall_for_read_rd_flag;
        pass_m_update_waddr = m_update_waddr;
        pass_v_update_waddr = v_update_waddr;
        pass_rd_to_load     = rd_to_load;
    end else if (recover_from_stall & recorded_stall_for_read_rd_flag) begin
        // Release until the pipeline stall is released.
        stall_for_read_rd   = 1'b1;
        pass_m_update_waddr = recorded_m_update_waddr;
        pass_v_update_waddr = recorded_v_update_waddr;
        pass_rd_to_load     = recorded_rd_to_load;
    end else begin
        stall_for_read_rd   = 1'b0;
        pass_m_update_waddr = 1'b0;
        pass_v_update_waddr = 1'b0;
        pass_rd_to_load     = {INT_OPERAND_WIDTH{1'b0}};
    end
end


// Exactly-once scalar dispatch bookkeeping: decode_advanced mirrors the
// condition under which the case block below writes decode_stage_op /
// assigned_int_op. The scalar op may only fire when assigned was freshly
// written (or was pended by a stall hitting at the fire moment); a stale
// assigned held through a stall must never re-fire (double-executing e.g.
// an S_ADDI rd==rs1 skews every later PASS_ADDR address read).
assign decode_advanced = stall_for_read_rd
    || (!effective_pipeline_stall && ((!early_loop_end_stall_d1 && !loop_end_stall) || loop_end_valid || loop_jump_back_d1 || skid_injected));

always_ff @(posedge clk) begin
    if (stall_for_read_rd) begin
        // Stall Condition 1: When the three oprands both pointer for addresses, need 2 cycles to obtain the address for the two port regfile.
        rd_operand_ready <= 1'b1;
        decode_stage_op.m_op            <= STALL_M;
        decode_stage_op.v_ele_op        <= STALL_V_ELEMENT;
        decode_stage_op.v_reduct_op     <= STALL_V_REDUCT;
        decode_stage_op.s_fp_op         <= STALL_S_FP;
        assigned_int_op                 <= PASS_ADDR_2;
        decode_stage_op.c_op            <= STALL_C;
        decode_stage_op.h_op            <= STALL_H;
        decode_stage_op.m_transposed_read   <= 1'b0;
        decode_stage_op.v_broadcast_en  <= 1'b0;
        decode_stage_op.v_segment_broadcast_en <= 1'b0;
        decode_stage_op.v_lane_store_en <= 1'b0;
        decode_stage_op.v_multi_reduction_en <= 1'b0;
        decode_stage_op.v_element_mask_en <= 1'b0;
        decode_stage_op.v_compact_stats_en <= 1'b0;
        decode_stage_op.v_compact_count_log2 <= 1'b0;
        decode_stage_op.v_reduction_overwrite_en <= 1'b0;
        decode_stage_op.v_softmax_rows_en <= 1'b0;
        decode_stage_op.v_softmax_state_en <= 1'b0;
        decode_stage_op.v_softmax_stats_operand_en <= 1'b0;
        decode_stage_op.v_softmax_state_phase <= '0;
        decode_stage_op.v_softmax_row_log2 <= '0;
        decode_stage_op.v_softmax_active_rows <= '0;
        decode_stage_op.m_packed_acc_en <= 1'b0;
        decode_stage_op.m_packed_accumulate <= 1'b0;
        decode_stage_op.m_packed_lane_offset <= '0;
        decode_stage_op.fps1            <= 'b0;
        decode_stage_op.fps2            <= 'b0;
        decode_stage_op.fpd             <= 'b0;
        decode_stage_op.gp_reg1         <= 'b0;
        decode_stage_op.gp_reg2         <= 'b0;
        decode_stage_op.gp_rd           <= 'b0;
        decode_stage_op.pc_tag          <= '0;
        decode_stage_op.update_m_waddr  <= pass_m_update_waddr;
        decode_stage_op.update_v_waddr  <= pass_v_update_waddr;
        fixed_op_stall_flag             <= 1'b0;
        rs1                             <= 'b0;
        rs2                             <= 'b0;
        rd                              <= pass_rd_to_load;
        imm                             <= 'b0;
    end else if (!effective_pipeline_stall && ((!early_loop_end_stall_d1 && !loop_end_stall) || loop_end_valid || loop_jump_back_d1 || skid_injected)) begin
        // Normal decode - process when:
        // 1. Not pipeline stalled (using effective_pipeline_stall which is masked during loop)
        // 2. Either: (a) not stalling (!early_loop_end_stall_d1 && !loop_end_stall), OR
        //            (b) C_LOOP_END is being decoded (loop_end_valid = 1), OR
        //            (c) just jumped back (loop_jump_back_d1 = 1) - decode instruction at jump target
        // The delayed signals ensure proper timing for instruction processing.
        rd_operand_ready <= 1'b0;
        decode_stage_op.m_transposed_read       <= (decode_instr_info.opcode == M_TMM) ? 1'b1 : 1'b0;
        decode_stage_op.v_broadcast_en          <=
            (decode_instr_info.opcode == V_ADD_VF) ||
            (decode_instr_info.opcode == V_SUB_VF && !decode_instr_info.funct1[3]) ||
            (decode_instr_info.opcode == V_MUL_VF &&
             (!decode_instr_info.funct1[3] || decode_instr_info.funct1[2])) ||
            (decode_instr_info.opcode == S_ST_VLANE_FP) ||
            (decode_instr_info.opcode == V_ALU_VSEG &&
             decode_instr_info.funct1[3] && decode_instr_info.funct1 != 4'hB);
        decode_stage_op.v_segment_broadcast_en  <= (decode_instr_info.opcode == V_ALU_VSEG && !decode_instr_info.funct1[3]);
        decode_stage_op.v_lane_store_en         <= (decode_instr_info.opcode == S_ST_VLANE_FP);
        decode_stage_op.v_multi_reduction_en    <=
            (decode_instr_info.opcode == V_RED_SUM_SEGS ||
             decode_instr_info.opcode == V_RED_MAX_SEGS) &&
            !decode_instr_info.funct1[3];
        decode_stage_op.v_element_mask_en       <=
            (decode_instr_info.opcode == V_ALU_VSEG &&
             decode_instr_info.funct1[3])
                ? 1'b0
                : (decode_instr_info.opcode == V_ALU_VSEG)
                    ? decode_instr_info.funct1[2]
                    : (((decode_instr_info.opcode == V_SUB_VF ||
                         decode_instr_info.opcode == V_MUL_VF ||
                         decode_instr_info.opcode == V_EXP_V) &&
                        decode_instr_info.funct1[3])
                        ? 1'b0
                        : (decode_instr_info.rstride != '0));
        decode_stage_op.v_compact_stats_en      <= (decode_instr_info.opcode == V_ALU_VSEG &&
                                                     decode_instr_info.funct1[3] &&
                                                     decode_instr_info.funct1 != 4'hB);
        decode_stage_op.v_compact_count_log2    <= (decode_instr_info.opcode == V_ALU_VSEG &&
                                                     decode_instr_info.funct1[3] &&
                                                     decode_instr_info.funct1[2] &&
                                                     decode_instr_info.funct1 != 4'hB);
        decode_stage_op.v_reduction_overwrite_en <=
            (decode_instr_info.opcode == V_RED_SUM ||
             decode_instr_info.opcode == V_RED_MAX ||
             decode_instr_info.opcode == V_RED_SUM_SEG ||
             decode_instr_info.opcode == V_RED_MAX_SEG) &&
            decode_instr_info.funct1[0];
        decode_stage_op.v_softmax_rows_en <=
            ((decode_instr_info.opcode == V_RED_SUM_SEGS ||
              decode_instr_info.opcode == V_RED_MAX_SEGS) &&
             decode_instr_info.funct1[3]) ||
            ((decode_instr_info.opcode == V_SUB_VF ||
              decode_instr_info.opcode == V_MUL_VF ||
              decode_instr_info.opcode == V_EXP_V) &&
             decode_instr_info.funct1[3]) ||
            (decode_instr_info.opcode == V_ALU_VSEG &&
             decode_instr_info.funct1 == 4'hB);
        decode_stage_op.v_softmax_state_en <=
            decode_instr_info.opcode == V_ALU_VSEG &&
            decode_instr_info.funct1 == 4'hB;
        decode_stage_op.v_softmax_stats_operand_en <=
            (decode_instr_info.opcode == V_SUB_VF && decode_instr_info.funct1[3]) ||
            (decode_instr_info.opcode == V_MUL_VF &&
             decode_instr_info.funct1[3] && !decode_instr_info.funct1[2]);
        decode_stage_op.v_softmax_state_phase <=
            decode_instr_info.rstride[3:2];
        decode_stage_op.v_softmax_row_log2 <=
            ((decode_instr_info.opcode == V_SUB_VF ||
              decode_instr_info.opcode == V_MUL_VF ||
              decode_instr_info.opcode == V_EXP_V) &&
             decode_instr_info.funct1[3])
                ? decode_instr_info.funct1[1:0]
                : decode_instr_info.rstride[1:0];
        decode_stage_op.v_softmax_active_rows <=
            (((decode_instr_info.opcode == V_RED_SUM_SEGS ||
               decode_instr_info.opcode == V_RED_MAX_SEGS) &&
              decode_instr_info.funct1[3]) ||
             (decode_instr_info.opcode == V_ALU_VSEG &&
              decode_instr_info.funct1 == 4'hB))
                ? decode_instr_info.rs2[3:0] + 4'd1
                : (((decode_instr_info.opcode == V_SUB_VF ||
                     decode_instr_info.opcode == V_MUL_VF ||
                     decode_instr_info.opcode == V_EXP_V) &&
                    decode_instr_info.funct1[3])
                    ? decode_instr_info.rstride[3:0] + 4'd1
                    : 4'd0);
        decode_stage_op.m_packed_acc_en <=
            decode_instr_info.opcode == M_MM_WO && decode_instr_info.imm[17];
        decode_stage_op.m_packed_accumulate <=
            decode_instr_info.opcode == M_MM_WO &&
            decode_instr_info.imm[17] && decode_instr_info.imm[16];
        decode_stage_op.m_packed_lane_offset <= decode_instr_info.imm[15:0];
        decode_stage_op.update_m_waddr          <= 1'b0;
        decode_stage_op.update_v_waddr          <=
            (decode_instr_info.opcode == V_ADD_VF) ||
            (decode_instr_info.opcode == V_SUB_VF) ||
            (decode_instr_info.opcode == V_MUL_VF) ||
            (decode_instr_info.opcode == V_EXP_V && decode_instr_info.funct1[3]) ||
            (decode_instr_info.opcode == V_ALU_VSEG &&
             decode_instr_info.funct1 != 4'hB) ||
            ((decode_instr_info.opcode == V_RED_SUM_SEGS ||
              decode_instr_info.opcode == V_RED_MAX_SEGS) &&
             !decode_instr_info.funct1[3]) ||
            (decode_instr_info.opcode == S_ST_VLANE_FP);
        decode_stage_op.gp_reg1                 <= decode_instr_info.rs1[INT_OPERAND_WIDTH - 1 : 0];
        decode_stage_op.gp_reg2                 <= decode_instr_info.rs2[INT_OPERAND_WIDTH - 1 : 0];
        decode_stage_op.gp_rstride              <= decode_instr_info.rstride[INT_OPERAND_WIDTH - 1 : 0];
        decode_stage_op.gp_rd                   <= decode_instr_info.rd [INT_OPERAND_WIDTH - 1 : 0];
        // Tag the op with the low bits of its fetch PC (loaded_instr was fetched from
        // pc_reg_d1). Stable across a PC-rewind replay (same address re-fetched), so the
        // addr_monitor can identify an op's own pending write and skip the self-collision.
        decode_stage_op.pc_tag                  <= pc_reg_d1[9:2];

        case(active_decode_instruction_type)
            M: begin   
                decode_stage_op.m_op            <=      (decode_instr_info.opcode == M_MM)                                              ? MM_IC  :
                                                        (decode_instr_info.opcode == M_MM_WO)                                           ? MM_WO  :       
                                                        (decode_instr_info.opcode == M_MV)                                              ? MV_IC  :
                                                        (decode_instr_info.opcode == M_MV_WO)                                           ? MV_WO  :  STALL_M;
                decode_stage_op.update_m_waddr  <= (decode_instr_info.opcode == M_MM_WO) ? 1'b1 : 1'b0;
                decode_stage_op.v_ele_op      <= STALL_V_ELEMENT;
                decode_stage_op.v_reduct_op   <= STALL_V_REDUCT;
                decode_stage_op.s_fp_op       <= STALL_S_FP;
                assigned_int_op               <= (decode_instr_info.opcode == M_MM_WO) ? PASS_ADDR_2 : PASS_ADDR;
                decode_stage_op.c_op          <= STALL_C;
                decode_stage_op.h_op          <= STALL_H;
                decode_stage_op.fps1          <= 'b0;
                decode_stage_op.fps2          <= 'b0;
                decode_stage_op.fpd           <= 'b0;
                rs1                           <= decode_instr_info.rs1  [INT_OPERAND_WIDTH - 1 : 0];
                rs2                           <= decode_instr_info.rs2  [INT_OPERAND_WIDTH - 1 : 0];
                rd                            <= decode_instr_info.rd   [INT_OPERAND_WIDTH - 1 : 0];
                imm     <= 'b0;
            end

            V: begin
                decode_stage_op.m_op     <= STALL_M;
                decode_stage_op.v_ele_op <=
                    (decode_instr_info.opcode == V_ADD_VV || decode_instr_info.opcode == V_ADD_VF) ? ADD_V_ELEMENT  :
                    (decode_instr_info.opcode == V_SUB_VV || decode_instr_info.opcode == V_SUB_VF) ? SUB_V_ELEMENT  :
                    (decode_instr_info.opcode == V_MUL_VV || decode_instr_info.opcode == V_MUL_VF) ? MUL_V_ELEMENT  :
                    (decode_instr_info.opcode == V_EXP_V)                                          ? EXP_V_ELEMENT  :
                    (decode_instr_info.opcode == V_RECI_V)                                         ? RECI_V_ELEMENT :
                    (decode_instr_info.opcode == V_ALU_VSEG && decode_instr_info.funct1[3] && decode_instr_info.funct1[1:0] == 2'b00) ? COMPACT_STAT_MUL_V_ELEMENT :
                    (decode_instr_info.opcode == V_ALU_VSEG && decode_instr_info.funct1[3] && decode_instr_info.funct1[1:0] == 2'b01) ? COMPACT_STAT_ADD_V_ELEMENT :
                    (decode_instr_info.opcode == V_ALU_VSEG && decode_instr_info.funct1[3] && decode_instr_info.funct1[1:0] == 2'b10) ? COMPACT_STAT_RSQRT_V_ELEMENT :
                    (decode_instr_info.opcode == V_ALU_VSEG && decode_instr_info.funct1[1:0] == 2'b00) ? ADD_V_ELEMENT :
                    (decode_instr_info.opcode == V_ALU_VSEG && decode_instr_info.funct1[1:0] == 2'b01) ? SUB_V_ELEMENT :
                    (decode_instr_info.opcode == V_ALU_VSEG && decode_instr_info.funct1[1:0] == 2'b10) ? MUL_V_ELEMENT :
                    (decode_instr_info.opcode == S_ST_VLANE_FP)                                     ? STORE_LANE_FP_V_ELEMENT :
                    (decode_instr_info.opcode == C_HADAMARD_TRANSFORM)                             ? INNER_HADAMARD_TRANSFORM :
                    (decode_instr_info.opcode == V_PS_V)                                           ? PREFIX_SCAN_V_ELEMENT :
                    (decode_instr_info.opcode == V_SHFT_V)                                         ? SHIFT_V_LANES_ELEMENT : STALL_V_ELEMENT;

                decode_stage_op.v_reduct_op <=
                    (decode_instr_info.opcode == V_RED_SUM)     ? SUM_V_REDUCT :
                    (decode_instr_info.opcode == V_RED_MAX)     ? MAX_V_REDUCT :
                    (decode_instr_info.opcode == V_RED_SUM_SEG) ? SUM_SEG_V_REDUCT :
                    (decode_instr_info.opcode == V_RED_MAX_SEG) ? MAX_SEG_V_REDUCT :
                    (decode_instr_info.opcode == V_RED_SUM_SEGS) ? SUM_SEGS_V_REDUCT :
                    (decode_instr_info.opcode == V_RED_MAX_SEGS) ? MAX_SEGS_V_REDUCT :
                    (decode_instr_info.opcode == S_LD_VLANE_FP)  ? LOAD_LANE_FP_V_REDUCT :
                                                                  STALL_V_REDUCT;
                
                assigned_int_op                         <= PASS_ADDR;
                decode_stage_op.c_op                    <= STALL_C;
                decode_stage_op.h_op                    <= STALL_H;
                if (decode_instr_info.opcode == V_ADD_VF ||
                    (decode_instr_info.opcode == V_SUB_VF && !decode_instr_info.funct1[3]) ||
                    (decode_instr_info.opcode == V_MUL_VF &&
                     (!decode_instr_info.funct1[3] || decode_instr_info.funct1[2])) ||
                    (decode_instr_info.opcode == V_ALU_VSEG &&
                     decode_instr_info.funct1[3] && decode_instr_info.funct1 != 4'hB)) begin
                    decode_stage_op.s_fp_op <= LD_OUT_FP;
                    decode_stage_op.fps1    <= 'b0;
                    decode_stage_op.fps2    <= decode_instr_info.rs2[FP_OPERAND_WIDTH - 1 : 0];
                    decode_stage_op.fpd     <= 'b0;
                    rs1                     <= decode_instr_info.rs1[INT_OPERAND_WIDTH - 1 : 0];
                    // V_*_VF is in-place: the write-back address (addr_2 <- gp_reg_addr_2
                    // <- rs2 under PASS_ADDR) must be the destination register rd, not 0.
                    // The rs2 instruction field holds the fp index (-> fps2), so route rd
                    // into the int rs2 so the vector result is written to gp[rd], not gp0.
                    rs2                     <= decode_instr_info.rd[INT_OPERAND_WIDTH - 1 : 0];
                    rd                      <= decode_instr_info.rd[INT_OPERAND_WIDTH - 1 : 0];
                    imm                     <= {IMM_WIDTH{1'b0}};
                end else if (decode_instr_info.opcode == S_ST_VLANE_FP) begin
                    // Encoding: rd=source FP, rs1=vector-address GP,
                    // rs2=lane-index GP. Port A/result address use addr_1;
                    // addr_2 carries the runtime lane index.
                    decode_stage_op.s_fp_op <= LD_OUT_FP;
                    decode_stage_op.fps1    <= '0;
                    decode_stage_op.fps2    <= decode_instr_info.rd[FP_OPERAND_WIDTH-1:0];
                    decode_stage_op.fpd     <= '0;
                    rs1                     <= decode_instr_info.rs1[INT_OPERAND_WIDTH-1:0];
                    rs2                     <= decode_instr_info.rs2[INT_OPERAND_WIDTH-1:0];
                    rd                      <= '0;
                    imm                     <= '0;
                end else if (decode_instr_info.opcode == S_LD_VLANE_FP) begin
                    // Encoding: rd=destination FP, rs1=vector-address GP,
                    // rs2=lane-index GP.
                    decode_stage_op.s_fp_op <= STALL_S_FP;
                    decode_stage_op.fps1    <= '0;
                    decode_stage_op.fps2    <= decode_instr_info.rd[FP_OPERAND_WIDTH-1:0];
                    decode_stage_op.fpd     <= '0;
                    rs1                     <= decode_instr_info.rs1[INT_OPERAND_WIDTH-1:0];
                    rs2                     <= decode_instr_info.rs2[INT_OPERAND_WIDTH-1:0];
                    rd                      <= '0;
                    imm                     <= '0;
                end else if (decode_instr_info.opcode == V_RED_SUM_SEGS ||
                             decode_instr_info.opcode == V_RED_MAX_SEGS) begin
                    decode_stage_op.s_fp_op <= STALL_S_FP;
                    decode_stage_op.fps1    <= '0;
                    decode_stage_op.fps2    <= '0;
                    decode_stage_op.fpd     <= '0;
                    rs1                     <= decode_instr_info.rs1[INT_OPERAND_WIDTH-1:0];
                    rs2                     <= decode_instr_info.rd[INT_OPERAND_WIDTH-1:0];
                    rd                      <= decode_instr_info.rd[INT_OPERAND_WIDTH-1:0];
                    imm                     <= '0;
                end else if (decode_instr_info.opcode == V_SHFT_V) begin
                    // V_SHIFT_V rd, rs1, rs2 uses a runtime integer GP shift
                    // amount. The normal three-GP helper reads rd in its extra
                    // cycle for writeback while this cycle reads rs1/rs2 as
                    // source address and lane offset respectively.
                    decode_stage_op.s_fp_op <= STALL_S_FP;
                    decode_stage_op.fps1    <= 'b0;
                    decode_stage_op.fps2    <= 'b0;
                    decode_stage_op.fpd     <= 'b0;
                    rs1                     <= decode_instr_info.rs1[INT_OPERAND_WIDTH - 1 : 0];
                    rs2                     <= decode_instr_info.rs2[INT_OPERAND_WIDTH - 1 : 0];
                    rd                      <= decode_instr_info.rd[INT_OPERAND_WIDTH - 1 : 0];
                    imm                     <= {IMM_WIDTH{1'b0}};
                end else if (decode_instr_info.opcode == V_RED_SUM ||
                             decode_instr_info.opcode == V_RED_MAX ||
                             decode_instr_info.opcode == V_RED_SUM_SEG ||
                             decode_instr_info.opcode == V_RED_MAX_SEG) begin
                    decode_stage_op.s_fp_op             <= decode_instr_info.funct1[0]
                                                          ? STALL_S_FP : LD_OUT_FP;
                    decode_stage_op.fps1                <= 'b0;
                    decode_stage_op.fps2                <= decode_instr_info.rd[FP_OPERAND_WIDTH - 1 : 0];
                    decode_stage_op.fpd                 <= 'b0;
                    rs1                                 <= decode_instr_info.rs1[INT_OPERAND_WIDTH - 1 : 0];
                    rs2                                 <= decode_instr_info.rs2[INT_OPERAND_WIDTH - 1 : 0];
                    rd                                  <= {FP_OPERAND_WIDTH{1'b0}};
                    imm                                 <= {IMM_WIDTH{1'b0}};
                end else begin
                    decode_stage_op.s_fp_op             <= STALL_S_FP;
                    decode_stage_op.fps1                <= 'b0;
                    decode_stage_op.fps2                <= 'b0;
                    decode_stage_op.fpd                 <= 'b0;
                    rs1                                 <= decode_instr_info.rs1[INT_OPERAND_WIDTH - 1 : 0];
                    rs2                                 <= decode_instr_info.rs2[INT_OPERAND_WIDTH - 1 : 0];
                    rd                                  <= decode_instr_info.rd[INT_OPERAND_WIDTH - 1 : 0];
                    imm                                 <= {IMM_WIDTH{1'b0}};
                end
            end

            S_INT: begin
                decode_stage_op.m_op                <= STALL_M;
                decode_stage_op.v_ele_op            <= STALL_V_ELEMENT;
                decode_stage_op.v_reduct_op         <= STALL_V_REDUCT;
                decode_stage_op.s_fp_op             <= STALL_S_FP;
                assigned_int_op                   <=    (decode_instr_info.opcode == S_ADD_INT)   ? ADD_INT   :
                                                        (decode_instr_info.opcode == S_ADDI_INT)  ? ADDI_INT  :
                                                        (decode_instr_info.opcode == S_SUB_INT)   ? SUB_INT   : 
                                                        (decode_instr_info.opcode == S_MUL_INT)   ? MUL_INT   : 
                                                        (decode_instr_info.opcode == S_LUI_INT)   ? LUI_INT   :
                                                        (decode_instr_info.opcode == S_LD_INT)    ? LD_INT    :
                                                        (decode_instr_info.opcode == S_ST_INT)    ? ST_INT    :  STALL_S_INT;
                decode_stage_op.c_op                <= STALL_C;
                decode_stage_op.h_op                <= STALL_H;
                if (decode_instr_info.opcode == S_ADDI_INT) begin
                    // S_ADDI_INT
                    decode_stage_op.fps1            <= 'b0;
                    decode_stage_op.fps2            <= 'b0;
                    decode_stage_op.fpd             <= 'b0;
                    rs1             <= decode_instr_info.rs1[INT_OPERAND_WIDTH - 1 : 0];
                    rs2             <= {INT_OPERAND_WIDTH{1'b0}};
                    rd              <= decode_instr_info.rd[INT_OPERAND_WIDTH - 1 : 0];
                    imm             <= {{IMM_WIDTH - IMM_2_WIDTH {1'b0}}, decode_instr_info.imm[IMM_2_WIDTH:0]}; 
                end else begin
                    // Other INT Instructions
                    decode_stage_op.fps1            <= 'b0;
                    decode_stage_op.fps2            <= 'b0;
                    decode_stage_op.fpd             <= 'b0;
                    rs1             <= decode_instr_info.rs1[INT_OPERAND_WIDTH - 1 : 0];
                    rs2             <= decode_instr_info.rs2[INT_OPERAND_WIDTH - 1 : 0];
                    rd              <= decode_instr_info.rd[INT_OPERAND_WIDTH - 1 : 0];
                    imm             <= decode_instr_info.imm; // Might require shifting
                end
            end

            S_FP: begin
                decode_stage_op.m_op            <= STALL_M;
                decode_stage_op.v_ele_op        <= STALL_V_ELEMENT;
                decode_stage_op.v_reduct_op     <= STALL_V_REDUCT;
                decode_stage_op.s_fp_op         <=      (decode_instr_info.opcode == S_ADD_FP )   ? ADD_FP    :
                                                        (decode_instr_info.opcode == S_SUB_FP )   ? SUB_FP    :
                                                        (decode_instr_info.opcode == S_MAX_FP )   ? MAX_FP    :
                                                        (decode_instr_info.opcode == S_MUL_FP )   ? MUL_FP    :
                                                        (decode_instr_info.opcode == S_EXP_FP )   ? EXP_FP    :
                                                        (decode_instr_info.opcode == S_RECI_FP)   ? RECI_FP   :
                                                        (decode_instr_info.opcode == S_SQRT_FP)   ? SQRT_FP   :
                                                        (decode_instr_info.opcode == S_MV_FP)     ? MV_FP     :
                                                        (decode_instr_info.opcode == S_RSQRT_FP)  ? RSQRT_FP  :
                                                        (decode_instr_info.opcode == S_LD_FP)     ? LD_REG_FP :
                                                        (decode_instr_info.opcode == S_ST_FP)     ? ST_REG_FP : 
                                                        (decode_instr_info.opcode == S_MAP_V_FP)  ? MAP_V_FP  : STALL_S_FP;
                
                decode_stage_op.c_op              <= STALL_C;
                decode_stage_op.h_op              <= STALL_H;
                if (decode_instr_info.opcode == S_ADD_FP || decode_instr_info.opcode == S_SUB_FP || decode_instr_info.opcode == S_MAX_FP || decode_instr_info.opcode == S_MUL_FP) begin
                    // Two FP source operands and one FP destination operand
                    assigned_int_op               <= STALL_S_INT;
                    decode_stage_op.fps1            <= decode_instr_info.rs1[FP_OPERAND_WIDTH - 1 : 0];
                    decode_stage_op.fps2            <= decode_instr_info.rs2[FP_OPERAND_WIDTH - 1 : 0];
                    decode_stage_op.fpd             <= decode_instr_info.rd[FP_OPERAND_WIDTH - 1 : 0];
                    rs1                             <= {INT_OPERAND_WIDTH{1'b0}};
                    rs2                             <= {INT_OPERAND_WIDTH{1'b0}};
                    rd                              <= {INT_OPERAND_WIDTH{1'b0}};
                    imm                             <= {IMM_WIDTH{1'b0}};
                end else if (decode_instr_info.opcode == S_EXP_FP || decode_instr_info.opcode == S_RECI_FP ||
                             decode_instr_info.opcode == S_SQRT_FP || decode_instr_info.opcode == S_MV_FP ||
                             decode_instr_info.opcode == S_RSQRT_FP) begin
                    // Single FP source operand and single FP destination operand
                    assigned_int_op               <= STALL_S_INT;
                    decode_stage_op.fps1            <= decode_instr_info.rs1[FP_OPERAND_WIDTH - 1 : 0];
                    decode_stage_op.fps2            <= {FP_OPERAND_WIDTH{1'b0}};
                    decode_stage_op.fpd             <= decode_instr_info.rd[FP_OPERAND_WIDTH - 1 : 0];
                    rs1                             <= {INT_OPERAND_WIDTH{1'b0}};
                    rs2                             <= {INT_OPERAND_WIDTH{1'b0}};
                    rd                              <= {INT_OPERAND_WIDTH{1'b0}};
                    imm                             <= {IMM_WIDTH{1'b0}};
                end else if (decode_instr_info.opcode == S_LD_FP || decode_instr_info.opcode == S_ST_FP) begin
                    // Single INT Source operand (Storing Addr) and one IMM and one FP destination operand
                    assigned_int_op               <= COMP_ADDR;
                    decode_stage_op.fps1            <= {FP_OPERAND_WIDTH{1'b0}};
                    decode_stage_op.fps2            <= {FP_OPERAND_WIDTH{1'b0}};
                    decode_stage_op.fpd             <= decode_instr_info.rd[FP_OPERAND_WIDTH - 1 : 0];
                    rs1                             <= decode_instr_info.rs1[INT_OPERAND_WIDTH - 1 : 0];
                    rs2                             <= {INT_OPERAND_WIDTH{1'b0}};
                    rd                              <= {INT_OPERAND_WIDTH{1'b0}};
                    imm                             <= decode_instr_info.imm; // Might require shifting
                end else if (decode_instr_info.opcode == S_MAP_V_FP) begin
                    assigned_int_op               <= COMP_ADDR_2;
                    decode_stage_op.fps1            <= {FP_OPERAND_WIDTH{1'b0}};
                    decode_stage_op.fps2            <= {FP_OPERAND_WIDTH{1'b0}};
                    decode_stage_op.fpd             <= {FP_OPERAND_WIDTH{1'b0}};
                    rs1                             <= decode_instr_info.rs1[INT_OPERAND_WIDTH - 1 : 0];
                    rs2                             <= {INT_OPERAND_WIDTH{1'b0}};
                    rd                              <= decode_instr_info.rd[FP_OPERAND_WIDTH - 1 : 0];
                    imm                             <= decode_instr_info.imm; // Might require shifting
                end else begin
                    // Not Defined 
                    assigned_int_op               <= STALL_S_INT;
                    decode_stage_op.fps1            <= {FP_OPERAND_WIDTH{1'b0}};
                    decode_stage_op.fps2            <= {FP_OPERAND_WIDTH{1'b0}};
                    decode_stage_op.fpd             <= decode_instr_info.rd[FP_OPERAND_WIDTH - 1 : 0];
                    rs1                             <= {INT_OPERAND_WIDTH{1'b0}};
                    rs2                             <= {INT_OPERAND_WIDTH{1'b0}};
                    rd                              <= {INT_OPERAND_WIDTH{1'b0}};
                    imm                             <= {IMM_WIDTH{1'b0}};
                end
            end

            C : begin
                decode_stage_op.m_op            <= STALL_M;
                decode_stage_op.v_ele_op        <= STALL_V_ELEMENT;
                decode_stage_op.v_reduct_op     <= STALL_V_REDUCT;
                decode_stage_op.s_fp_op         <= STALL_S_FP;
                decode_stage_op.h_op            <= STALL_H;

                if(decode_instr_info.opcode == C_SET_ADDR_REG) begin
                    assigned_int_op                   <= PASS_ADDR;
                    decode_stage_op.c_op              <= SET_ADDR_REG;
                end else if (decode_instr_info.opcode == C_SET_SCALE_REG) begin
                    assigned_int_op                   <= PASS_ADDR_2;
                    decode_stage_op.c_op              <= SET_SCALE_REG;
                end else if (decode_instr_info.opcode == C_SET_STRIDE_REG) begin
                    assigned_int_op                   <= PASS_ADDR_2;
                    decode_stage_op.c_op              <= SET_STRIDE_SIZE;
                end else if (decode_instr_info.opcode == C_SET_V_MASK_REG) begin
                    assigned_int_op                   <= PASS_ADDR_2;
                    decode_stage_op.c_op              <= SET_V_MASK;
                end else if (decode_instr_info.opcode == C_BREAK) begin
                    assigned_int_op                     <= STALL_S_INT;
                    decode_stage_op.c_op                <= BREAK;
                end else if (decode_instr_info.opcode == C_LOOP_START) begin
                    // C_LOOP_START rd, imm: Set gp[rd] = imm (loop counter initialization)
                    assigned_int_op                     <= LOOP_INIT;
                    decode_stage_op.c_op                <= LOOP_START;
                end else if (decode_instr_info.opcode == C_LOOP_END) begin
                    // C_LOOP_END rs1: Decrement gp[rs1], jump back if > 0
                    assigned_int_op                     <= LOOP_DEC;
                    decode_stage_op.c_op                <= LOOP_END;
                end else if (decode_instr_info.opcode == C_AGU_CONFIG) begin
                    assigned_int_op                     <= STALL_S_INT;
                    decode_stage_op.c_op                <= AGU_CONFIG;
                end else if (decode_instr_info.opcode == C_LOOP_START_AGU) begin
                    // gp0 denotes an AGU-internal loop counter for refolded
                    // microkernels and must remain architectural zero.
                    assigned_int_op                     <=
                        (decode_instr_info.rd == '0)
                        ? STALL_S_INT : AGU_LOOP_INIT;
                    decode_stage_op.c_op                <= AGU_LOOP_START;
                end else begin
                    assigned_int_op                     <= STALL_S_INT;
                    decode_stage_op.c_op                <= STALL_C;
                end
                decode_stage_op.fps1              <= 'b0;
                decode_stage_op.fps2              <= 'b0;
                decode_stage_op.fpd               <= 'b0;

                // Handle register/immediate assignments for loop instructions
                if ((decode_instr_info.opcode == C_LOOP_START)
                        || (decode_instr_info.opcode == C_LOOP_START_AGU)) begin
                    // C_LOOP_START rd, imm: rd is the counter register, imm is the count
                    rs1             <= {INT_OPERAND_WIDTH{1'b0}};
                    rs2             <= {INT_OPERAND_WIDTH{1'b0}};
                    rd              <= decode_instr_info.rd[INT_OPERAND_WIDTH - 1 : 0];
                    imm             <= decode_instr_info.imm;  // Pass immediate for counter init
                end else if (decode_instr_info.opcode == C_LOOP_END) begin
                    // C_LOOP_END rd: rd is the counter register (read, decrement, write back)
                    // Note: Assembler encodes the register in the rd field, not rs1
                    rs1             <= decode_instr_info.rd[INT_OPERAND_WIDTH - 1 : 0];  // Read from counter register
                    rs2             <= {INT_OPERAND_WIDTH{1'b0}};
                    rd              <= decode_instr_info.rd[INT_OPERAND_WIDTH - 1 : 0];  // Write back to same register
                    imm             <= {IMM_WIDTH{1'b0}};
                end else if (decode_instr_info.opcode == C_AGU_CONFIG) begin
                    rs1             <= '0;
                    rs2             <= '0;
                    rd              <= decode_instr_info.rd[INT_OPERAND_WIDTH - 1 : 0];
                    imm             <= decode_instr_info.imm;
                end else begin
                    rs1             <= decode_instr_info.rs1[INT_OPERAND_WIDTH - 1 : 0];
                    rs2             <= decode_instr_info.rs2[INT_OPERAND_WIDTH - 1 : 0];
                    rd              <= decode_instr_info.rd [INT_OPERAND_WIDTH - 1 : 0];
                    imm             <= {IMM_WIDTH{1'b0}};
                end
            end

            H : begin
                decode_stage_op.m_op            <= STALL_M;
                decode_stage_op.v_ele_op        <= STALL_V_ELEMENT;
                decode_stage_op.v_reduct_op     <= STALL_V_REDUCT;
                decode_stage_op.s_fp_op         <= STALL_S_FP;
                assigned_int_op                 <= PASS_ADDR_2;
                decode_stage_op.c_op            <= STALL_C;
                if (decode_instr_info.opcode == H_PREFETCH_M) begin
                    if (decode_instr_info.funct1 == 4'h0) begin
                        decode_stage_op.h_op <= PREFETCH_M_H;
                    end else if (decode_instr_info.funct1 == 4'h1) begin
                        decode_stage_op.h_op <= PREFETCH_M_L;
                    end else begin
                        decode_stage_op.h_op <= STALL_H;
                    end
                end else if (decode_instr_info.opcode == H_PREFETCH_V) begin
                    if (decode_instr_info.funct1 == 4'h0) begin
                        decode_stage_op.h_op <= PREFETCH_V_H;
                    end else if (decode_instr_info.funct1 == 4'h1) begin
                        decode_stage_op.h_op <= PREFETCH_V_L;
                    end else begin
                        decode_stage_op.h_op <= STALL_H;
                    end
                end else if (decode_instr_info.opcode == H_STORE_V) begin
                    if (decode_instr_info.funct1 == 4'h0) begin
                        decode_stage_op.h_op <= STORE_V_H;
                    end else if (decode_instr_info.funct1 == 4'h1) begin
                        decode_stage_op.h_op <= STORE_V_L;
                    end else begin
                        decode_stage_op.h_op <= STALL_H;
                    end 
                end else begin // Not Defined 
                    decode_stage_op.h_op          <= STALL_H;
                end
                decode_stage_op.fps1              <= 'b0;
                decode_stage_op.fps2              <= 'b0;
                decode_stage_op.fpd               <= 'b0;
                rs1             <= decode_instr_info.rs1[INT_OPERAND_WIDTH - 1 : 0];
                rs2             <= decode_instr_info.rs2[INT_OPERAND_WIDTH - 1 : 0];
                rd              <= decode_instr_info.rd [INT_OPERAND_WIDTH - 1 : 0];
                imm             <= {IMM_WIDTH{1'b0}};
            end

            default: begin
                decode_stage_op.m_op              <= STALL_M;
                decode_stage_op.v_ele_op          <= STALL_V_ELEMENT;
                decode_stage_op.v_reduct_op       <= STALL_V_REDUCT;
                decode_stage_op.s_fp_op           <= STALL_S_FP;
                assigned_int_op                   <= STALL_S_INT;
                decode_stage_op.c_op              <= STALL_C;
                decode_stage_op.h_op              <= STALL_H;
                decode_stage_op.fps1              <= 'b0;
                decode_stage_op.fps2              <= 'b0;
                decode_stage_op.fpd               <= 'b0;
                rs1             <= 'b0;
                rs2             <= 'b0;
                rd              <= 'b0;
                imm             <= {IMM_WIDTH{1'b0}};
            end
        endcase
    end else begin
        // Stall condition: pipeline_stall, early_loop_end_stall_d1, or loop_end_stall (except first cycle)
        // Hold all outputs to preserve in-flight instruction operands during stalls.
        // Note: Using early_loop_end_stall_d1 (delayed by 1 cycle) allows the instruction
        // immediately before C_LOOP_END to be decoded before stalling.
        assigned_int_op     <= STALL_S_INT;
        decode_stage_op     <= decode_stage_op;
        rs1                 <= rs1;
        rs2                 <= rs2;
        rd                  <= rd;
        imm                 <= imm;
    end
end

`ifdef SIMULATION
// C_BREAK detection for simulation - goes high when C_BREAK opcode is decoded
assign c_break_detected = decode_instr_valid && (decode_instr_info.opcode == C_BREAK);
`endif

endmodule
