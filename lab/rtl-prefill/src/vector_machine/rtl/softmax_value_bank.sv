`timescale 1ns/1ps

// Banked transient storage used for row maxima/sums and m_res/reciprocal
// factors.  Consecutive logical entries occupy different banks, so one aligned
// row group is read or written without data replication.
module softmax_value_bank #(
    parameter int FP_WIDTH = 12,
    parameter int ROW_LANES = 4,
    parameter int ENTRIES = 16384,
    localparam int BANK_DEPTH = (ENTRIES + ROW_LANES - 1) / ROW_LANES,
    localparam int ADDR_WIDTH = (ENTRIES <= 1) ? 1 : $clog2(ENTRIES),
    localparam int BANK_ADDR_WIDTH = (BANK_DEPTH <= 1) ? 1 : $clog2(BANK_DEPTH)
) (
    input  logic clk,
    input  logic rst,
    input  logic read_en,
    input  logic write_en,
    input  logic [ADDR_WIDTH-1:0] read_group_base,
    input  logic [$clog2(ROW_LANES + 1)-1:0] read_active_rows,
    input  logic [ADDR_WIDTH-1:0] write_group_base,
    input  logic [$clog2(ROW_LANES + 1)-1:0] write_active_rows,
    input  logic [ROW_LANES-1:0][FP_WIDTH-1:0] data_in,
    input  logic [ROW_LANES-1:0] valid_in,
    output logic [ROW_LANES-1:0][FP_WIDTH-1:0] data_out,
    output logic [ROW_LANES-1:0] valid_out,
    output logic read_valid
);
    logic [FP_WIDTH-1:0] storage [0:ROW_LANES-1][0:BANK_DEPTH-1];
    logic valid_storage [0:ROW_LANES-1][0:BANK_DEPTH-1];
    logic [BANK_ADDR_WIDTH-1:0] read_bank_row, write_bank_row;

    assign read_bank_row = read_group_base / ROW_LANES;
    assign write_bank_row = write_group_base / ROW_LANES;

    always_ff @(posedge clk) begin
        if (rst) begin
            read_valid <= 1'b0;
            data_out <= '0;
            valid_out <= '0;
            for (int bank = 0; bank < ROW_LANES; bank++)
                for (int row = 0; row < BANK_DEPTH; row++)
                    valid_storage[bank][row] <= 1'b0;
        end else begin
            read_valid <= read_en;
            if (read_en) begin
                for (int lane = 0; lane < ROW_LANES; lane++) begin
                    if (lane < read_active_rows) begin
                        data_out[lane] <= storage[lane][read_bank_row];
                        valid_out[lane] <= valid_storage[lane][read_bank_row];
                    end else begin
                        data_out[lane] <= '0;
                        valid_out[lane] <= 1'b0;
                    end
                end
            end
            if (write_en) begin
                for (int lane = 0; lane < ROW_LANES; lane++) begin
                    if (lane < write_active_rows) begin
                        storage[lane][write_bank_row] <= data_in[lane];
                        valid_storage[lane][write_bank_row] <= valid_in[lane];
                    end
                end
            end
        end
    end

`ifdef SIMULATION
    always_ff @(posedge clk) begin
        if (!rst && read_en) begin
            if (read_group_base % ROW_LANES)
                $fatal(1, "softmax transient group base is not bank aligned");
            if (read_active_rows == 0 || read_active_rows > ROW_LANES)
                $fatal(1, "invalid softmax transient active-row count");
            if (read_group_base + read_active_rows > ENTRIES)
                $fatal(1, "softmax transient access exceeds configured entries");
        end
        if (!rst && write_en) begin
            if (write_group_base % ROW_LANES)
                $fatal(1, "softmax transient write base is not bank aligned");
            if (write_active_rows == 0 || write_active_rows > ROW_LANES)
                $fatal(1, "invalid softmax transient write active-row count");
            if (write_group_base + write_active_rows > ENTRIES)
                $fatal(1, "softmax transient write exceeds configured entries");
        end
    end
`endif
endmodule
