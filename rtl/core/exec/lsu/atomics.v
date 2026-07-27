`timescale 1ns/1ps
`include "core/backend/backend-defs.v"
`include "core/bus/bus-defs.v"
`include "core/isa/rv64-i.v"
`include "core/decode/defs/lsu-defs.v"

// Ordered RV64A sequencer for the core LSU.
//
// The LSQ decides when an atomic instruction reaches the ordered head.  This
// module owns everything sticky after that point: the captured instruction,
// reservation/RMW engine, irrevocable request state, memory-response identity,
// and result handshake.  Acquire/release ordering belongs at this boundary;
// the current implementation preserves the existing fully serialized policy.
module openrv64_lsu_atomics #(
    parameter integer RETIRE_SLOT_WIDTH = 3,
    parameter integer LSU_TAG_WIDTH = `OPENRV64_LSU_TAG_WIDTH,
    parameter integer META_WIDTH = `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH,
    parameter integer COHERENT_ATOMICS = 0
) (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire                         flush_i,

    input  wire                         start_valid_i,
    output wire                         start_ready_o,
    input  wire [LSU_TAG_WIDTH-1:0]     start_tag_i,
    input  wire [`OPENRV64_INSTR_ID_WIDTH-1:0] start_id_i,
    input  wire [RETIRE_SLOT_WIDTH-1:0] start_slot_i,
    input  wire [META_WIDTH-1:0]        start_meta_i,
    input  wire                         start_access_allowed_i,
    input  wire                         clear_reservation_i,

    output wire                         active_o,
    output wire                         irrevocable_o,
    output wire [LSU_TAG_WIDTH-1:0]     active_tag_o,

    output wire                         mem_valid_o,
    input  wire                         mem_ready_i,
    output wire [LSU_TAG_WIDTH-1:0]     mem_tag_o,
    output wire                         mem_lock_o,
    output wire                         mem_write_o,
    output wire [`RV64_XLEN-1:0]        mem_addr_o,
    output wire [`RV64_XLEN-1:0]        mem_wdata_o,
    output wire [7:0]                   mem_wstrb_o,
    output wire [`RV64_XLEN-1:0]        mem_effective_addr_o,
    output wire [2:0]                   mem_size_o,

    input  wire                         mem_resp_valid_i,
    output wire                         mem_resp_claim_o,
    output wire                         mem_resp_ready_o,
    input  wire [LSU_TAG_WIDTH-1:0]     mem_resp_tag_i,
    input  wire [`RV64_XLEN-1:0]        mem_rdata_i,
    input  wire                         mem_error_i,
    input  wire                         mem_page_fault_i,

    output wire                         result_valid_o,
    input  wire                         result_ready_i,
    output wire [`OPENRV64_INSTR_ID_WIDTH-1:0] result_id_o,
    output wire [RETIRE_SLOT_WIDTH-1:0] result_slot_o,
    output wire [META_WIDTH-1:0]        result_meta_o,
    output wire [`RV64_XLEN-1:0]        result_data_o,
    output wire                         result_illegal_o,
    output wire                         result_misaligned_o,
    output wire                         result_access_fault_o,
    output wire                         result_page_fault_o,
    output wire                         done_o
);

    localparam integer I_LSU_OP = 22;
    localparam integer I_IMM = 40;
    localparam integer I_RS2_DATA = 104;
    localparam integer I_RS1_DATA = 168;
    localparam integer I_INSTR = 242;

    reg active_q;
    reg irrevocable_q;
    reg req_inflight_q;
    reg [LSU_TAG_WIDTH-1:0] tag_q;
    reg [`OPENRV64_INSTR_ID_WIDTH-1:0] id_q;
    reg [RETIRE_SLOT_WIDTH-1:0] slot_q;
    reg [META_WIDTH-1:0] meta_q;
    reg access_allowed_q;

    wire [`RV64_LSU_OP_WIDTH-1:0] lsu_op =
        meta_q[I_LSU_OP +: `RV64_LSU_OP_WIDTH];
    wire [`RV64_XLEN-1:0] rs1_data =
        meta_q[I_RS1_DATA +: `RV64_XLEN];
    wire [`RV64_XLEN-1:0] rs2_data =
        meta_q[I_RS2_DATA +: `RV64_XLEN];
    wire [`RV64_XLEN-1:0] imm =
        meta_q[I_IMM +: `RV64_XLEN];
    wire [`RV64_XLEN-1:0] effective_addr = rs1_data + imm;
    wire [2:0] access_size = {
        1'b0,
        meta_q[I_INSTR + 12 +: `RV64_LSU_SIZE_WIDTH]
    };

    wire engine_complete;
    wire engine_illegal;
    wire engine_misaligned;
    wire engine_access_fault;
    wire engine_page_fault;
    wire [`RV64_XLEN-1:0] engine_result;
    wire engine_mem_valid;
    wire engine_mem_lock;
    wire engine_mem_write;
    wire [`RV64_XLEN-1:0] engine_mem_addr;
    wire [`RV64_XLEN-1:0] engine_mem_wdata;
    wire [7:0] engine_mem_wstrb;

    assign start_ready_o = !active_q && !flush_i;
    wire start_fire = start_valid_i && start_ready_o;

    assign mem_resp_claim_o = active_q && req_inflight_q &&
                              (mem_resp_tag_i == tag_q);
    assign mem_resp_ready_o = mem_resp_claim_o;
    wire mem_resp_fire = mem_resp_valid_i && mem_resp_ready_o;

    assign result_valid_o = active_q && engine_complete;
    wire result_fire = result_valid_o && result_ready_i;
    assign done_o = result_fire;

    openrv64_exec_lsu_rv64a #(
        .SC_STATUS_IN_RDATA(COHERENT_ATOMICS),
        .COHERENT_RESERVATIONS(COHERENT_ATOMICS)
    ) u_engine (
        .clk(clk),
        .rst_n(rst_n),
        .flush_i(flush_i && !irrevocable_q),
        .valid_i(active_q),
        .consume_i(result_fire),
        .clear_reservation_i(clear_reservation_i),
        .op_sel_i(lsu_op),
        .size_sel_i(access_size[`RV64_LSU_SIZE_WIDTH-1:0]),
        .addr_i(effective_addr),
        .store_data_i(rs2_data),
        .mem_ready_i(mem_resp_fire),
        .mem_error_i(mem_error_i),
        .mem_page_fault_i(mem_page_fault_i),
        .mem_access_allowed_i(access_allowed_q),
        .mem_rdata_i(mem_rdata_i),
        .complete_o(engine_complete),
        .illegal_o(engine_illegal),
        .misaligned_o(engine_misaligned),
        .access_fault_o(engine_access_fault),
        .page_fault_o(engine_page_fault),
        .result_o(engine_result),
        .mem_valid_o(engine_mem_valid),
        .mem_lock_o(engine_mem_lock),
        .mem_write_o(engine_mem_write),
        .mem_addr_o(engine_mem_addr),
        .mem_wdata_o(engine_mem_wdata),
        .mem_wstrb_o(engine_mem_wstrb)
    );

    // A redirect may cancel an atomic only before its first request is
    // accepted.  Suppress that request in the redirect cycle; once
    // irrevocable, later read/modify/write phases continue through redirects.
    assign mem_valid_o = active_q && engine_mem_valid &&
                         !req_inflight_q &&
                         (!flush_i || irrevocable_q);
    assign mem_tag_o = tag_q;
    assign mem_lock_o = engine_mem_lock;
    assign mem_write_o = engine_mem_write;
    assign mem_addr_o = engine_mem_addr;
    assign mem_wdata_o = engine_mem_wdata;
    assign mem_wstrb_o = engine_mem_wstrb;
    assign mem_effective_addr_o = effective_addr;
    assign mem_size_o = access_size;
    wire mem_request_fire = mem_valid_o && mem_ready_i;

    assign active_o = active_q;
    assign irrevocable_o = irrevocable_q;
    assign active_tag_o = tag_q;
    assign result_id_o = id_q;
    assign result_slot_o = slot_q;
    assign result_meta_o = meta_q;
    assign result_data_o = engine_result;
    assign result_illegal_o = engine_illegal;
    assign result_misaligned_o = engine_misaligned;
    assign result_access_fault_o = engine_access_fault;
    assign result_page_fault_o = engine_page_fault;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active_q <= 1'b0;
            irrevocable_q <= 1'b0;
            req_inflight_q <= 1'b0;
            tag_q <= {LSU_TAG_WIDTH{1'b0}};
            id_q <= {`OPENRV64_INSTR_ID_WIDTH{1'b0}};
            slot_q <= {RETIRE_SLOT_WIDTH{1'b0}};
            meta_q <= {META_WIDTH{1'b0}};
            access_allowed_q <= 1'b1;
        end else if (flush_i) begin
            if (!irrevocable_q) begin
                active_q <= 1'b0;
                irrevocable_q <= 1'b0;
                req_inflight_q <= 1'b0;
            end else begin
                // Redirects do not stop an accepted atomic.  Continue tracking
                // its response and any later RMW request while the younger
                // machine state is being flushed.
                if (mem_request_fire)
                    req_inflight_q <= 1'b1;
                if (mem_resp_fire)
                    req_inflight_q <= 1'b0;
                if (result_fire) begin
                    active_q <= 1'b0;
                    irrevocable_q <= 1'b0;
                    req_inflight_q <= 1'b0;
                end
            end
        end else begin
            if (start_fire) begin
                active_q <= 1'b1;
                irrevocable_q <= 1'b0;
                req_inflight_q <= 1'b0;
                tag_q <= start_tag_i;
                id_q <= start_id_i;
                slot_q <= start_slot_i;
                meta_q <= start_meta_i;
                access_allowed_q <= start_access_allowed_i;
            end
            if (mem_request_fire) begin
                req_inflight_q <= 1'b1;
                irrevocable_q <= 1'b1;
            end
            if (mem_resp_fire)
                req_inflight_q <= 1'b0;
            if (result_fire) begin
                active_q <= 1'b0;
                irrevocable_q <= 1'b0;
                req_inflight_q <= 1'b0;
            end
        end
    end

endmodule
