`timescale 1ns/1ps
`include "core/isa/rv64-i.v"
`include "core/decode/defs/lsu-defs.v"

// Deliberately small, blocking RV64A implementation for one hart and a
// one-request-at-a-time memory path.  AMOs perform a read followed by a write
// while EX/MEM is stalled.  The compatibility mode owns reservations locally;
// coherent mode marks LR/SC traffic for a home-owned reservation while still
// performing AMO arithmetic here.
module openrv64_exec_lsu_rv64a #(
    // A coherent L1D returns a failed home SC as bit zero of the marked
    // write response. Ordinary single-hart paths retain their original
    // always-successful local RMW behavior.
    parameter integer SC_STATUS_IN_RDATA = 0,
    // A coherent LR must establish its reservation at the home.  The coherent
    // L1D may then satisfy the architectural read from a retained clean line.
    // The compatibility default retains the original local-LR behavior for
    // non-coherent single-hart systems.
    parameter integer COHERENT_RESERVATIONS = 0
) (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire                         flush_i,
    input  wire                         valid_i,
    input  wire                         consume_i,
    input  wire                         clear_reservation_i,
    input  wire [`RV64_LSU_OP_WIDTH-1:0] op_sel_i,
    input  wire [`RV64_LSU_SIZE_WIDTH-1:0] size_sel_i,
    input  wire [`RV64_XLEN-1:0]        addr_i,
    input  wire [`RV64_XLEN-1:0]        store_data_i,

    input  wire                         mem_ready_i,
    input  wire                         mem_error_i,
    input  wire                         mem_page_fault_i,
    input  wire                         mem_access_allowed_i,
    input  wire [`RV64_XLEN-1:0]        mem_rdata_i,

    output wire                         complete_o,
    output wire                         illegal_o,
    output wire                         misaligned_o,
    output wire                         access_fault_o,
    output wire                         page_fault_o,
    output wire [`RV64_XLEN-1:0]        result_o,
    output wire                         mem_valid_o,
    output wire                         mem_lock_o,
    output wire                         mem_write_o,
    output wire [`RV64_XLEN-1:0]        mem_addr_o,
    output wire [`RV64_XLEN-1:0]        mem_wdata_o,
    output wire [7:0]                   mem_wstrb_o
);

    localparam [2:0] STATE_IDLE  = 3'd0;
    localparam [2:0] STATE_READ  = 3'd1;
    localparam [2:0] STATE_WRITE = 3'd2;
    localparam [2:0] STATE_DONE  = 3'd3;

    reg [2:0] state_q;
    reg [`RV64_LSU_OP_WIDTH-1:0] op_q;
    reg [`RV64_LSU_SIZE_WIDTH-1:0] size_q;
    reg [`RV64_XLEN-1:0] addr_q;
    reg [`RV64_XLEN-1:0] operand_q;
    reg [`RV64_XLEN-1:0] write_data_q;
    reg [`RV64_XLEN-1:0] result_q;
    reg illegal_q;
    reg misaligned_q;
    reg access_fault_q;
    reg page_fault_q;

    reg reservation_valid_q;
    reg [`RV64_XLEN-1:0] reservation_addr_q;
    reg [`RV64_LSU_SIZE_WIDTH-1:0] reservation_size_q;

    wire word_access_q = (size_q == `RV64_LSU_SIZE_WORD);
    wire [5:0] read_shift = word_access_q ? {addr_q[2], 5'b00000} :
                                           6'd0;
    wire [`RV64_XLEN-1:0] shifted_rdata = mem_rdata_i >> read_shift;
    wire [`RV64_XLEN-1:0] read_value = word_access_q ?
        {{32{1'b0}}, shifted_rdata[31:0]} : mem_rdata_i;
    wire [`RV64_XLEN-1:0] read_result = word_access_q ?
        {{32{read_value[31]}}, read_value[31:0]} : read_value;
    wire [5:0] write_shift = word_access_q ? {addr_q[2], 5'b00000} :
                                            6'd0;
    wire [`RV64_XLEN-1:0] word_write_data =
        {{32{1'b0}}, write_data_q[31:0]} << write_shift;

    function op_valid;
        input [`RV64_LSU_OP_WIDTH-1:0] op;
        begin
            case (op)
                `RV64_LSU_OP_LR,
                `RV64_LSU_OP_SC,
                `RV64_LSU_OP_AMOSWAP,
                `RV64_LSU_OP_AMOADD,
                `RV64_LSU_OP_AMOXOR,
                `RV64_LSU_OP_AMOAND,
                `RV64_LSU_OP_AMOOR,
                `RV64_LSU_OP_AMOMIN,
                `RV64_LSU_OP_AMOMAX,
                `RV64_LSU_OP_AMOMINU,
                `RV64_LSU_OP_AMOMAXU: op_valid = 1'b1;
                default: op_valid = 1'b0;
            endcase
        end
    endfunction

    function op_is_amo;
        input [`RV64_LSU_OP_WIDTH-1:0] op;
        begin
            case (op)
                `RV64_LSU_OP_AMOSWAP,
                `RV64_LSU_OP_AMOADD,
                `RV64_LSU_OP_AMOXOR,
                `RV64_LSU_OP_AMOAND,
                `RV64_LSU_OP_AMOOR,
                `RV64_LSU_OP_AMOMIN,
                `RV64_LSU_OP_AMOMAX,
                `RV64_LSU_OP_AMOMINU,
                `RV64_LSU_OP_AMOMAXU: op_is_amo = 1'b1;
                default: op_is_amo = 1'b0;
            endcase
        end
    endfunction

    function [`RV64_XLEN-1:0] amo_value;
        input [`RV64_LSU_OP_WIDTH-1:0] op;
        input [`RV64_XLEN-1:0] old_value;
        input [`RV64_XLEN-1:0] operand;
        input word_op;
        reg [31:0] old_w;
        reg [31:0] operand_w;
        reg [31:0] result_w;
        begin
            old_w = old_value[31:0];
            operand_w = operand[31:0];
            result_w = 32'd0;

            if (word_op) begin
                case (op)
                    `RV64_LSU_OP_AMOSWAP: result_w = operand_w;
                    `RV64_LSU_OP_AMOADD:  result_w = old_w + operand_w;
                    `RV64_LSU_OP_AMOXOR:  result_w = old_w ^ operand_w;
                    `RV64_LSU_OP_AMOAND:  result_w = old_w & operand_w;
                    `RV64_LSU_OP_AMOOR:   result_w = old_w | operand_w;
                    `RV64_LSU_OP_AMOMIN:  result_w =
                        ($signed(old_w) < $signed(operand_w)) ? old_w : operand_w;
                    `RV64_LSU_OP_AMOMAX:  result_w =
                        ($signed(old_w) > $signed(operand_w)) ? old_w : operand_w;
                    `RV64_LSU_OP_AMOMINU: result_w =
                        (old_w < operand_w) ? old_w : operand_w;
                    `RV64_LSU_OP_AMOMAXU: result_w =
                        (old_w > operand_w) ? old_w : operand_w;
                    default: result_w = 32'd0;
                endcase
                amo_value = {{32{1'b0}}, result_w};
            end else begin
                case (op)
                    `RV64_LSU_OP_AMOSWAP: amo_value = operand;
                    `RV64_LSU_OP_AMOADD:  amo_value = old_value + operand;
                    `RV64_LSU_OP_AMOXOR:  amo_value = old_value ^ operand;
                    `RV64_LSU_OP_AMOAND:  amo_value = old_value & operand;
                    `RV64_LSU_OP_AMOOR:   amo_value = old_value | operand;
                    `RV64_LSU_OP_AMOMIN:  amo_value =
                        ($signed(old_value) < $signed(operand)) ?
                            old_value : operand;
                    `RV64_LSU_OP_AMOMAX:  amo_value =
                        ($signed(old_value) > $signed(operand)) ?
                            old_value : operand;
                    `RV64_LSU_OP_AMOMINU: amo_value =
                        (old_value < operand) ? old_value : operand;
                    `RV64_LSU_OP_AMOMAXU: amo_value =
                        (old_value > operand) ? old_value : operand;
                    default: amo_value = {`RV64_XLEN{1'b0}};
                endcase
            end
        end
    endfunction

    assign complete_o = valid_i && (state_q == STATE_DONE);
    assign illegal_o = illegal_q;
    assign misaligned_o = misaligned_q;
    assign access_fault_o = access_fault_q;
    assign page_fault_o = page_fault_q;
    assign result_o = result_q;

    assign mem_valid_o = valid_i &&
                         ((state_q == STATE_READ) ||
                          (state_q == STATE_WRITE));
    // Mark both halves of the local AMO read/modify/write sequence, every SC,
    // and an LR when coherent reservations are enabled.  The marker drains
    // and bypasses local L1D data; it is deliberately not forwarded as a
    // CCX/L2 lock.  SC waits for the real home response rather than being
    // acknowledged as a posted ordinary store.
    assign mem_lock_o = mem_valid_o &&
                        (op_is_amo(op_q) ||
                         (op_q == `RV64_LSU_OP_SC) ||
                         ((COHERENT_RESERVATIONS != 0) &&
                          (op_q == `RV64_LSU_OP_LR)));
    assign mem_write_o = valid_i && (state_q == STATE_WRITE);
    assign mem_addr_o = addr_q;
    assign mem_wdata_o = word_access_q ? word_write_data : write_data_q;
    assign mem_wstrb_o = (state_q == STATE_WRITE) ?
        (word_access_q ? (addr_q[2] ? 8'hf0 : 8'h0f) : 8'hff) : 8'h00;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q <= STATE_IDLE;
            op_q <= `RV64_LSU_OP_INVALID;
            size_q <= `RV64_LSU_SIZE_WORD;
            addr_q <= {`RV64_XLEN{1'b0}};
            operand_q <= {`RV64_XLEN{1'b0}};
            write_data_q <= {`RV64_XLEN{1'b0}};
            result_q <= {`RV64_XLEN{1'b0}};
            illegal_q <= 1'b0;
            misaligned_q <= 1'b0;
            access_fault_q <= 1'b0;
            page_fault_q <= 1'b0;
            reservation_valid_q <= 1'b0;
            reservation_addr_q <= {`RV64_XLEN{1'b0}};
            reservation_size_q <= `RV64_LSU_SIZE_WORD;
        end else if (flush_i) begin
            state_q <= STATE_IDLE;
            reservation_valid_q <= 1'b0;
        end else begin
            if (clear_reservation_i) begin
                reservation_valid_q <= 1'b0;
            end

            case (state_q)
                STATE_IDLE: begin
                    if (valid_i) begin
                        op_q <= op_sel_i;
                        size_q <= size_sel_i;
                        addr_q <= addr_i;
                        operand_q <= store_data_i;
                        write_data_q <= store_data_i;
                        result_q <= {`RV64_XLEN{1'b0}};
                        illegal_q <= 1'b0;
                        misaligned_q <= 1'b0;
                        access_fault_q <= 1'b0;
                        page_fault_q <= 1'b0;
                        reservation_valid_q <= 1'b0;

                        if (!op_valid(op_sel_i) ||
                            ((size_sel_i != `RV64_LSU_SIZE_WORD) &&
                             (size_sel_i != `RV64_LSU_SIZE_DWORD))) begin
                            illegal_q <= 1'b1;
                            state_q <= STATE_DONE;
                        end else if (((size_sel_i == `RV64_LSU_SIZE_WORD) &&
                                      (|addr_i[1:0])) ||
                                     ((size_sel_i == `RV64_LSU_SIZE_DWORD) &&
                                      (|addr_i[2:0]))) begin
                            misaligned_q <= 1'b1;
                            state_q <= STATE_DONE;
                        end else if (!mem_access_allowed_i) begin
                            access_fault_q <= 1'b1;
                            state_q <= STATE_DONE;
                        end else if (op_sel_i == `RV64_LSU_OP_SC) begin
                            if (reservation_valid_q &&
                                (reservation_addr_q == addr_i) &&
                                (reservation_size_q == size_sel_i)) begin
                                state_q <= STATE_WRITE;
                            end else begin
                                result_q <= 64'd1;
                                state_q <= STATE_DONE;
                            end
                        end else begin
                            state_q <= STATE_READ;
                        end
                    end
                end

                STATE_READ: begin
                    if (mem_ready_i) begin
                        if (mem_error_i) begin
                            access_fault_q <= 1'b1;
                            state_q <= STATE_DONE;
                        end else if (mem_page_fault_i) begin
                            page_fault_q <= 1'b1;
                            state_q <= STATE_DONE;
                        end else if (op_q == `RV64_LSU_OP_LR) begin
                            result_q <= read_result;
                            // A same-cycle coherence probe orders the LR
                            // before the conflicting write but must leave no
                            // surviving local reservation.
                            reservation_valid_q <=
                                !clear_reservation_i;
                            reservation_addr_q <= addr_q;
                            reservation_size_q <= size_q;
                            state_q <= STATE_DONE;
                        end else begin
                            result_q <= read_result;
                            write_data_q <= amo_value(op_q, read_value,
                                                      operand_q,
                                                      word_access_q);
                            state_q <= STATE_WRITE;
                        end
                    end
                end

                STATE_WRITE: begin
                    if (mem_ready_i) begin
                        if (mem_error_i) begin
                            access_fault_q <= 1'b1;
                        end else if (mem_page_fault_i) begin
                            page_fault_q <= 1'b1;
                        end else if ((SC_STATUS_IN_RDATA != 0) &&
                                     mem_rdata_i[0] &&
                                     op_is_amo(op_q)) begin
                            // A coherence write broke the home reservation.
                            // Re-read and recompute; the stale write value
                            // must never be submitted as a fresh SC.
                            reservation_valid_q <= 1'b0;
                            state_q <= STATE_READ;
                        end else if (op_q == `RV64_LSU_OP_SC) begin
                            result_q <=
                                ((SC_STATUS_IN_RDATA != 0) &&
                                 mem_rdata_i[0]) ? 64'd1 : 64'd0;
                        end
                        if (!((SC_STATUS_IN_RDATA != 0) &&
                              mem_rdata_i[0] &&
                              op_is_amo(op_q))) begin
                            reservation_valid_q <= 1'b0;
                            state_q <= STATE_DONE;
                        end
                    end
                end

                STATE_DONE: begin
                    if (consume_i || !valid_i) begin
                        state_q <= STATE_IDLE;
                    end
                end

                default: begin
                    state_q <= STATE_IDLE;
                    reservation_valid_q <= 1'b0;
                end
            endcase
        end
    end

endmodule
