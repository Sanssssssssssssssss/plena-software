// 学习注： 来源 lab/rtl-prefill/src/vector_machine/rtl/softmax_state_bank.sv，原始行 1–106。
// 学习注： 这是核心阅读副本；运行仍用原目录及其依赖。只新增注释，没有修改逻辑。
`timescale 1ns / 1ps

// Banked m/l state storage for the rtl-v6 multi-row softmax candidate.
// Consecutive logical rows map to different banks, allowing one aligned row
// group to be read or written in a cycle without replicating the state bits.
// 学习注：online softmax 的 m/l 存在行状态 bank；减少通过通用标量 SRAM 反复搬运。
module softmax_state_bank #(
    parameter int FP_WIDTH = 12,
    // 学习注：R 个 query 行并行；不是把整条序列的 softmax 一次全部展开。
    parameter int ROW_LANES = 4,
    parameter int ENTRIES = 16384,
    localparam int BANK_DEPTH = (ENTRIES + ROW_LANES - 1) / ROW_LANES,
    localparam int ADDR_WIDTH = $clog2(ENTRIES),
    localparam int BANK_ADDR_WIDTH = (BANK_DEPTH <= 1) ? 1 : $clog2(BANK_DEPTH),
    localparam int DATA_WIDTH = 2 * FP_WIDTH
) (
    input  logic clk,
    input  logic rst,
    input  logic read_en,
    input  logic write_en,
    input  logic [ADDR_WIDTH-1:0] read_group_base,
    input  logic [$clog2(ROW_LANES + 1)-1:0] read_active_rows,
    input  logic [ADDR_WIDTH-1:0] write_group_base,
    input  logic [$clog2(ROW_LANES + 1)-1:0] write_active_rows,
    input  logic [ROW_LANES-1:0][FP_WIDTH-1:0] m_in,
    input  logic [ROW_LANES-1:0][FP_WIDTH-1:0] l_in,
    input  logic [ROW_LANES-1:0] valid_in,
    input  logic [ROW_LANES-1:0] first_pending_in,
    output logic [ROW_LANES-1:0][FP_WIDTH-1:0] m_out,
    output logic [ROW_LANES-1:0][FP_WIDTH-1:0] l_out,
    output logic [ROW_LANES-1:0] valid_out,
    output logic [ROW_LANES-1:0] first_pending_out,
    output logic read_valid
);
    // Keep the wide m/l payload free of reset logic so synthesis can map it
    // to SRAM.  Only the narrow validity bitmap is reset; first-pending is
    // exactly the inverse of valid and therefore needs no second bit.
    // 学习注：每 bank 持有不同 query 行状态；有效位用于区分首块和后续块。
    logic [DATA_WIDTH-1:0] data_storage [0:ROW_LANES-1][0:BANK_DEPTH-1];
    logic valid_storage [0:ROW_LANES-1][0:BANK_DEPTH-1];
    logic [BANK_ADDR_WIDTH-1:0] read_bank_row, write_bank_row;

    // 学习注：连续 R 行组成一组，地址除以 R 得到 bank 内行号。
    assign read_bank_row = read_group_base / ROW_LANES;
    assign write_bank_row = write_group_base / ROW_LANES;

    always_ff @(posedge clk) begin
        if (rst) begin
            read_valid <= 1'b0;
            m_out <= '0;
            l_out <= '0;
            valid_out <= '0;
            first_pending_out <= '0;
            for (int bank = 0; bank < ROW_LANES; bank++)
                for (int row = 0; row < BANK_DEPTH; row++)
                    valid_storage[bank][row] <= 1'b0;
        end else begin
            read_valid <= read_en;
            if (read_en) begin
                for (int lane = 0; lane < ROW_LANES; lane++) begin
                    if (lane < read_active_rows) begin
                        {m_out[lane], l_out[lane]} <=
                            data_storage[lane][read_bank_row];
                        valid_out[lane] <= valid_storage[lane][read_bank_row];
                        first_pending_out[lane] <=
                            !valid_storage[lane][read_bank_row];
                    end else begin
                        m_out[lane] <= '0;
                        l_out[lane] <= '0;
                        valid_out[lane] <= 1'b0;
                        first_pending_out[lane] <= 1'b0;
                    end
                end
            end
            if (write_en) begin
                for (int lane = 0; lane < ROW_LANES; lane++) begin
                    if (lane < write_active_rows) begin
                        data_storage[lane][write_bank_row] <= {m_in[lane], l_in[lane]};
                        valid_storage[lane][write_bank_row] <= valid_in[lane];
                    end
                end
            end
        end
    end

`ifdef SIMULATION
    initial begin
        // 学习注：当前实现只接受 R1/2/4/8；R16 研究结果不可直接称为已验证 RTL。
        if (ROW_LANES < 1 || ROW_LANES > 8 || (ROW_LANES & (ROW_LANES - 1)))
            $fatal(1, "ROW_LANES must be a power-of-two tier in [1, 8]");
    end
    always_ff @(posedge clk) begin
        if (!rst && read_en) begin
            if (read_group_base % ROW_LANES)
                $fatal(1, "softmax state group base is not bank aligned");
            if (read_active_rows == 0 || read_active_rows > ROW_LANES)
                $fatal(1, "softmax active row count is invalid");
            if (read_group_base + read_active_rows > ENTRIES)
                $fatal(1, "softmax state access exceeds configured entries");
        end
        if (!rst && write_en) begin
            if (write_group_base % ROW_LANES)
                $fatal(1, "softmax state write base is not bank aligned");
            if (write_active_rows == 0 || write_active_rows > ROW_LANES)
                $fatal(1, "softmax state write active-row count is invalid");
            if (write_group_base + write_active_rows > ENTRIES)
                $fatal(1, "softmax state write exceeds configured entries");
        end
    end
`endif
endmodule
