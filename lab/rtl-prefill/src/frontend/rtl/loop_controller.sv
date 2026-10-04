`timescale 1ns / 1ps

`include "configuration.svh"
`include "operation.svh"

/*
Module      : Loop Controller
Description :
    Manages hardware loop control with support for nested loops.
    - Maintains a stack of loop start PCs for nested loop support
    - Tracks which GP register holds the counter for each loop level
    - Generates PC jump signals for loop iteration

    Instruction Format:
    - C_LOOP_START rd, imm : Set gp[rd] = imm, push loop_target = PC+4
    - C_LOOP_END rs1       : Decrement gp[rs1], if > 0 jump back, else pop
*/

module loop_controller import instruction_pkg::*; import configuration_pkg::*; #(
    parameter PC_WIDTH = 32
)(
    input   logic clk,
    input   logic rst,

    // From Decoder: Loop instruction signals
    input   logic                               loop_start_valid,   // C_LOOP_START detected
    input   logic                               agu_loop_start_valid,
    input   logic                               loop_end_valid,     // C_LOOP_END detected
    input   logic                               agu_boundary_valid,
    input   logic [INT_OPERAND_WIDTH-1:0]       loop_counter_reg,   // GP register index for counter
    input   logic [21:0]                        agu_iteration_count,
    input   logic [PC_WIDTH-1:0]                agu_marker_pc,
    input   logic [PC_WIDTH-1:0]                current_pc,         // Current PC value
    input   logic [PC_WIDTH-1:0]                loop_continue_pc,   // Address after C_LOOP_END (stall-robust exit target)
    input   logic [PC_WIDTH-1:0]                loop_start_target,  // Address after C_LOOP_START (stall-robust jump-back target)

    // From ALU: Loop counter status after decrement
    input   logic                               loop_counter_zero,  // Counter reached 0 after decrement

    // To Decoder: PC control
    output  logic                               loop_jump_back,     // Signal to jump back to loop start
    output  logic [PC_WIDTH-1:0]                loop_target_pc,     // Target PC for jump back
    output  logic                               loop_end_stall,     // Stall PC while waiting for counter check
    output  logic                               loop_exit,          // Signal that loop is exiting (counter reached 0)
    output  logic [PC_WIDTH-1:0]                loop_exit_pc,       // PC to continue from after loop exit
    output  logic                               agu_top_active,
    output  logic [PC_WIDTH-1:0]                agu_top_marker_pc,
    output  logic                               agu_boundary_step,
    output  logic                               agu_boundary_exit
);

    // =========================================================================
    // Loop Stack Registers
    // =========================================================================

    // Stack of loop start PCs (one for each nesting level)
    logic [PC_WIDTH-1:0] loop_start_pc_stack [MAX_LOOP_DEPTH-1:0];

    // Stack of GP register indices (which register holds counter for each level)
    logic [INT_OPERAND_WIDTH-1:0] loop_counter_reg_stack [MAX_LOOP_DEPTH-1:0];
    logic                         loop_is_agu_stack [MAX_LOOP_DEPTH-1:0];
    logic [21:0]                  agu_remaining_stack [MAX_LOOP_DEPTH-1:0];
    logic [PC_WIDTH-1:0]          agu_marker_pc_stack [MAX_LOOP_DEPTH-1:0];

    // Stack pointer: 0 = empty, MAX_LOOP_DEPTH = full
    logic [$clog2(MAX_LOOP_DEPTH):0] stack_ptr;

    // =========================================================================
    // Check if counter register is already on the stack
    // =========================================================================
    // Prevents re-pushing inner loops when outer loops jump back.
    logic reg_already_on_stack;

    always_comb begin
        reg_already_on_stack = 1'b0;
        for (int i = 0; i < MAX_LOOP_DEPTH; i++) begin
            if (i < stack_ptr && loop_counter_reg_stack[i] == loop_counter_reg) begin
                reg_already_on_stack = 1'b1;
            end
        end
    end

    // =========================================================================
    // Pipeline Delay for loop_end_valid (3 cycles to match loop_counter_zero)
    // =========================================================================
    // loop_counter_zero from ALU is delayed 3 cycles after loop_end_valid
    logic loop_end_valid_d1, loop_end_valid_d2, loop_end_valid_d3;
    logic loop_jump_back_d1, loop_exit_d1;
    logic [PC_WIDTH-1:0] saved_continue_pc;

    always_ff @(posedge clk) begin
        if (rst) begin
            loop_end_valid_d1 <= 1'b0;
            loop_end_valid_d2 <= 1'b0;
            loop_end_valid_d3 <= 1'b0;
            loop_jump_back_d1 <= 1'b0;
            loop_exit_d1 <= 1'b0;
            saved_continue_pc <= '0;
        end else begin
            loop_end_valid_d1 <= loop_end_valid;
            loop_end_valid_d2 <= loop_end_valid_d1;
            loop_end_valid_d3 <= loop_end_valid_d2;
            loop_jump_back_d1 <= loop_jump_back;
            loop_exit_d1 <= loop_exit;

            // Capture continuation PC when loop_end_valid goes high.
            // Use loop_continue_pc (= C_LOOP_END address + 4, computed in the decoder
            // from the delayed fetch PC) instead of current_pc. current_pc is the fetch
            // PC, which only equals C_LOOP_END+4 when it advanced freely; a stall holding
            // it on the C_LOOP_END slot would otherwise make the exit jump back onto
            // C_LOOP_END and loop forever.
            if (loop_end_valid) begin
                saved_continue_pc <= loop_continue_pc;
            end
        end
    end

    // =========================================================================
    // Stack Management Logic
    // =========================================================================

    always_ff @(posedge clk) begin
        if (rst) begin
            stack_ptr <= '0;
            for (int i = 0; i < MAX_LOOP_DEPTH; i++) begin
                loop_start_pc_stack[i] <= '0;
                loop_counter_reg_stack[i] <= '0;
                loop_is_agu_stack[i] <= 1'b0;
                agu_remaining_stack[i] <= '0;
                agu_marker_pc_stack[i] <= '0;
            end
        end else begin
            // Push on C_LOOP_START (if stack not full AND register not already on stack).
            // Jump back to the FIRST LOOP-BODY instruction (right after C_LOOP_START) so
            // the counter is not re-initialised every iteration. loop_start_target is the
            // decoder's stall-robust capture of C_LOOP_START+4 (pc_reg_d1 + 4); using the
            // raw current_pc - 4 here is fragile to a stall on the instruction before
            // C_LOOP_START, which lands the target back on C_LOOP_START and loops forever.
            if ((loop_start_valid || agu_loop_start_valid)
                    && stack_ptr < MAX_LOOP_DEPTH
                    && (!reg_already_on_stack || agu_loop_start_valid)) begin
                loop_start_pc_stack[stack_ptr] <= loop_start_target;
                loop_counter_reg_stack[stack_ptr] <= loop_counter_reg;
                loop_is_agu_stack[stack_ptr] <= agu_loop_start_valid;
                agu_remaining_stack[stack_ptr] <= agu_iteration_count;
                agu_marker_pc_stack[stack_ptr] <= agu_marker_pc;
                stack_ptr <= stack_ptr + 1;
            end
            else if (agu_boundary_valid && stack_ptr > 0) begin
                if (agu_remaining_stack[stack_ptr - 1] > 1) begin
                    agu_remaining_stack[stack_ptr - 1]
                        <= agu_remaining_stack[stack_ptr - 1] - 1'b1;
                end else begin
                    stack_ptr <= stack_ptr - 1'b1;
                end
            end
            // Pop on C_LOOP_END when counter reaches 0
            else if (loop_end_valid_d3 && loop_counter_zero && stack_ptr > 0) begin
                stack_ptr <= stack_ptr - 1;
            end
        end
    end

    // =========================================================================
    // Output Logic
    // =========================================================================

    // Jump back when counter is not zero
    assign agu_top_active = (stack_ptr > 0) && loop_is_agu_stack[stack_ptr - 1];
    assign agu_top_marker_pc = agu_top_active
        ? agu_marker_pc_stack[stack_ptr - 1] : '0;
    assign agu_boundary_step = agu_boundary_valid && agu_top_active;
    assign agu_boundary_exit = agu_boundary_step
        && (agu_remaining_stack[stack_ptr - 1] == 1);

    assign loop_jump_back =
        (loop_end_valid_d3 && !loop_counter_zero && (stack_ptr > 0))
        || (agu_boundary_step && !agu_boundary_exit);

    // Target PC is top of stack
    assign loop_target_pc = (stack_ptr > 0) ? loop_start_pc_stack[stack_ptr - 1] : '0;

    // Loop exit when counter reaches zero
    assign loop_exit =
        (loop_end_valid_d3 && loop_counter_zero && (stack_ptr > 0))
        || agu_boundary_exit;
    assign loop_exit_pc = agu_boundary_exit
        ? (agu_marker_pc_stack[stack_ptr - 1] + 4)
        : saved_continue_pc;

    // Stall during counter check and one extra cycle for instruction memory latency
    assign loop_end_stall = loop_end_valid || loop_end_valid_d1 || loop_end_valid_d2 ||
                            loop_end_valid_d3 || loop_jump_back_d1 || loop_exit_d1;

endmodule
