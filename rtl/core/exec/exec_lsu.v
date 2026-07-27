`timescale 1ns/1ps
`include "core/backend/backend-defs.v"
`include "core/bus/bus-defs.v"
`include "core/isa/rv64-i.v"
`include "core/isa/rv64-a.v"
`include "core/isa/rv64-priv.v"
`include "core/decode/defs/lsu-defs.v"
`include "core/except/except-defs.v"

// Backend-facing LSU containing the unified LSQ.
//
// The LSQ owns ordering and transaction state.  This wrapper owns address
// generation, memory/result arbitration, exception construction, and conversion
// between opaque backend packets and completion packets.  RV64A sequencing lives
// in lsu/atomics.v.
module openrv64_exec_lsu #(
    parameter integer RETIRE_SLOT_WIDTH = 3,
    parameter integer LOAD_QUEUE_DEPTH = 4,
    parameter integer STORE_QUEUE_DEPTH = 4,
    parameter integer LSU_TAG_WIDTH = `OPENRV64_LSU_TAG_WIDTH,
    parameter integer COHERENT_ATOMICS = 0,
    parameter [`RV64_XLEN-1:0] CACHEABLE_BASE = {`RV64_XLEN{1'b0}},
    parameter [`RV64_XLEN-1:0] CACHEABLE_SIZE = {`RV64_XLEN{1'b0}}
) (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire                         flush_i,
    input  wire                         squash_younger_i,
    input  wire [`OPENRV64_INSTR_ID_WIDTH-1:0] squash_id_i,
    input  wire                         coherent_reservation_clear_i,
    input  wire                         translation_bypass_i,

    input  wire                         load_issue_valid_i,
    output wire                         load_issue_ready_o,
    input  wire [`OPENRV64_INSTR_ID_WIDTH-1:0] load_issue_id_i,
    input  wire [RETIRE_SLOT_WIDTH-1:0] load_issue_slot_i,
    input  wire [`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0]
                                        load_issue_payload_i,

    input  wire                         store_issue_valid_i,
    output wire                         store_issue_ready_o,
    input  wire [`OPENRV64_INSTR_ID_WIDTH-1:0] store_issue_id_i,
    input  wire [RETIRE_SLOT_WIDTH-1:0] store_issue_slot_i,
    input  wire [`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0]
                                        store_issue_payload_i,

    input  wire                         ordered_head_valid_i,
    input  wire [`OPENRV64_INSTR_ID_WIDTH-1:0] ordered_head_id_i,
    input  wire [RETIRE_SLOT_WIDTH-1:0] ordered_head_slot_i,

    output wire                         complete_valid_o,
    input  wire                         complete_ready_i,
    output wire [`OPENRV64_INSTR_ID_WIDTH-1:0] complete_id_o,
    output wire [RETIRE_SLOT_WIDTH-1:0] complete_slot_o,
    output wire [`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH-1:0]
                                        complete_payload_o,

    output wire                         mem_valid_o,
    input  wire                         mem_ready_i,
    output wire [LSU_TAG_WIDTH-1:0]     mem_tag_o,
    output wire                         mem_xlate_only_o,
    output wire                         mem_physical_o,
    output wire                         mem_lock_o,
    output wire                         mem_write_o,
    output wire [`RV64_XLEN-1:0]        mem_addr_o,
    output wire [`RV64_XLEN-1:0]        mem_wdata_o,
    output wire [7:0]                   mem_wstrb_o,
    output wire                         mem_access_o,
    output wire [`RV64_XLEN-1:0]        mem_effective_addr_o,
    output wire [2:0]                   mem_size_o,

    output wire                         xlate_valid_o,
    input  wire                         xlate_ready_i,
    output wire [LSU_TAG_WIDTH-1:0]     xlate_tag_o,
    output wire                         xlate_write_o,
    output wire [`RV64_XLEN-1:0]        xlate_vaddr_o,
    input  wire                         xlate_resp_valid_i,
    output wire                         xlate_resp_ready_o,
    input  wire [LSU_TAG_WIDTH-1:0]     xlate_resp_tag_i,
    input  wire [`RV64_XLEN-1:0]        xlate_resp_paddr_i,
    input  wire                         xlate_resp_access_fault_i,
    input  wire                         xlate_resp_page_fault_i,

    input  wire                         mem_resp_valid_i,
    output wire                         mem_resp_ready_o,
    input  wire [LSU_TAG_WIDTH-1:0]     mem_resp_tag_i,
    input  wire [`RV64_XLEN-1:0]        mem_resp_paddr_i,
    input  wire [`RV64_XLEN-1:0]        mem_rdata_i,
    input  wire                         mem_error_i,
    input  wire                         mem_page_fault_i,
    input  wire                         mem_store_done_valid_i,
    output wire                         mem_store_done_ready_o,
    input  wire [LSU_TAG_WIDTH-1:0]     mem_store_done_tag_i,

    output wire                         store_pending_o
);

    localparam integer I_PRIV = 2;
    localparam integer I_INSTR_PAGE_FAULT = 4;
    localparam integer I_INSTR_ACCESS_FAULT = 5;
    localparam integer I_ECALL = 6;
    localparam integer I_EBREAK = 7;
    localparam integer I_ILLEGAL = 8;
    localparam integer I_MEM_WRITE = 15;
    localparam integer I_MEM_READ = 16;
    localparam integer I_REG_WRITE = 17;
    localparam integer I_LSU_OP = 22;
    localparam integer I_RD = 35;
    localparam integer I_IMM = 40;
    localparam integer I_RS2_DATA = 104;
    localparam integer I_RS1_DATA = 168;
    localparam integer I_RS2 = 232;
    localparam integer I_RS1 = 237;
    localparam integer I_INSTR = 242;
    localparam integer I_PC = 274;
    localparam integer I_TRACE = 338;

    function automatic payload_is_atomic;
        input [`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0] payload;
        reg [`RV64_INSTR_WIDTH-1:0] instr;
        begin
            instr = payload[I_INSTR +: `RV64_INSTR_WIDTH];
            payload_is_atomic =
                (`RV64_OPCODE(instr) == `RV64_OPCODE_AMO);
        end
    endfunction

    wire [`RV64_INSTR_WIDTH-1:0] load_instr =
        load_issue_payload_i[I_INSTR +: `RV64_INSTR_WIDTH];
    wire [`RV64_LSU_OP_WIDTH-1:0] load_lsu_op =
        load_issue_payload_i[I_LSU_OP +: `RV64_LSU_OP_WIDTH];
    wire [`RV64_XLEN-1:0] load_rs1_data =
        load_issue_payload_i[I_RS1_DATA +: `RV64_XLEN];
    wire [`RV64_XLEN-1:0] load_rs2_data =
        load_issue_payload_i[I_RS2_DATA +: `RV64_XLEN];
    wire [`RV64_XLEN-1:0] load_imm =
        load_issue_payload_i[I_IMM +: `RV64_XLEN];
    wire load_lsu_valid;
    wire load_lsu_illegal;
    wire load_lsu_misaligned;
    wire [`RV64_XLEN-1:0] unused_load_data;
    wire load_bus_valid;
    wire load_bus_write;
    wire [`RV64_XLEN-1:0] load_bus_addr;
    wire [`RV64_XLEN-1:0] unused_load_wdata;
    wire [7:0] unused_load_wstrb;
    openrv64_exec_lsu_rv64i u_load_address (
        .op_sel_i(load_lsu_op),
        .base_i(load_rs1_data),
        .offset_i(load_imm),
        .store_data_i(load_rs2_data),
        .mem_rdata_i({`RV64_XLEN{1'b0}}),
        .valid_o(load_lsu_valid),
        .illegal_o(load_lsu_illegal),
        .misaligned_o(load_lsu_misaligned),
        .load_data_o(unused_load_data),
        .mem_valid_o(load_bus_valid),
        .mem_write_o(load_bus_write),
        .mem_addr_o(load_bus_addr),
        .mem_wdata_o(unused_load_wdata),
        .mem_wstrb_o(unused_load_wstrb)
    );

    wire [`RV64_INSTR_WIDTH-1:0] store_instr =
        store_issue_payload_i[I_INSTR +: `RV64_INSTR_WIDTH];
    wire [`RV64_LSU_OP_WIDTH-1:0] store_lsu_op =
        store_issue_payload_i[I_LSU_OP +: `RV64_LSU_OP_WIDTH];
    wire [`RV64_XLEN-1:0] store_rs1_data =
        store_issue_payload_i[I_RS1_DATA +: `RV64_XLEN];
    wire [`RV64_XLEN-1:0] store_rs2_data =
        store_issue_payload_i[I_RS2_DATA +: `RV64_XLEN];
    wire [`RV64_XLEN-1:0] store_imm =
        store_issue_payload_i[I_IMM +: `RV64_XLEN];
    wire store_is_atomic = payload_is_atomic(store_issue_payload_i);
    wire store_lsu_valid;
    wire store_lsu_illegal;
    wire store_lsu_misaligned;
    wire [`RV64_XLEN-1:0] unused_store_load_data;
    wire store_bus_valid;
    wire store_bus_write;
    wire [`RV64_XLEN-1:0] store_bus_addr;
    wire [`RV64_XLEN-1:0] store_bus_wdata;
    wire [7:0] store_bus_wstrb;
    openrv64_exec_lsu_rv64i u_store_address (
        .op_sel_i(store_lsu_op),
        .base_i(store_rs1_data),
        .offset_i(store_imm),
        .store_data_i(store_rs2_data),
        .mem_rdata_i({`RV64_XLEN{1'b0}}),
        .valid_o(store_lsu_valid),
        .illegal_o(store_lsu_illegal),
        .misaligned_o(store_lsu_misaligned),
        .load_data_o(unused_store_load_data),
        .mem_valid_o(store_bus_valid),
        .mem_write_o(store_bus_write),
        .mem_addr_o(store_bus_addr),
        .mem_wdata_o(store_bus_wdata),
        .mem_wstrb_o(store_bus_wstrb)
    );

    wire load_immediate =
        load_issue_payload_i[I_ILLEGAL] ||
        load_issue_payload_i[I_INSTR_ACCESS_FAULT] ||
        load_issue_payload_i[I_INSTR_PAGE_FAULT] ||
        !load_issue_payload_i[I_MEM_READ] ||
        load_issue_payload_i[I_MEM_WRITE] ||
        !load_lsu_valid || load_lsu_illegal || load_lsu_misaligned ||
        !load_bus_valid || load_bus_write;
    wire store_immediate =
        store_issue_payload_i[I_ILLEGAL] ||
        store_issue_payload_i[I_INSTR_ACCESS_FAULT] ||
        store_issue_payload_i[I_INSTR_PAGE_FAULT] ||
        !(store_issue_payload_i[I_MEM_WRITE] || store_is_atomic) ||
        (!store_is_atomic &&
         (!store_lsu_valid || store_lsu_illegal ||
          store_lsu_misaligned || !store_bus_valid || !store_bus_write));
    wire [`RV64_XLEN-1:0] store_effective_addr =
        store_rs1_data + store_imm;

    wire lsq_req_valid;
    wire lsq_req_ready;
    wire [LSU_TAG_WIDTH-1:0] lsq_req_tag;
    wire lsq_req_write;
    wire [`RV64_XLEN-1:0] lsq_req_addr;
    wire [`RV64_XLEN-1:0] lsq_req_vaddr;
    wire [2:0] lsq_req_size;
    wire [`RV64_XLEN-1:0] lsq_req_wdata;
    wire [7:0] lsq_req_wstrb;
    wire lsq_resp_valid;
    wire lsq_resp_ready;
    wire lsq_result_valid;
    wire lsq_result_ready;
    wire [`OPENRV64_INSTR_ID_WIDTH-1:0] lsq_result_id;
    wire [RETIRE_SLOT_WIDTH-1:0] lsq_result_slot;
    wire [`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0] lsq_result_meta;
    wire [`RV64_XLEN-1:0] lsq_result_rdata;
    wire lsq_result_access_fault;
    wire lsq_result_page_fault;
    wire lsq_result_store;

    wire atomic_start_valid;
    wire [LSU_TAG_WIDTH-1:0] atomic_start_tag;
    wire [`OPENRV64_INSTR_ID_WIDTH-1:0] atomic_start_id;
    wire [RETIRE_SLOT_WIDTH-1:0] atomic_start_slot;
    wire [`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0] atomic_start_meta;
    wire atomic_start_access_allowed;
    wire atomic_start_ready;
    wire atomic_active;
    wire atomic_irrevocable;
    wire [LSU_TAG_WIDTH-1:0] atomic_tag;
    wire atomic_done;

    wire atomic_mem_valid;
    wire [LSU_TAG_WIDTH-1:0] atomic_mem_tag;
    wire atomic_mem_lock;
    wire atomic_mem_write;
    wire [`RV64_XLEN-1:0] atomic_mem_addr;
    wire [`RV64_XLEN-1:0] atomic_mem_wdata;
    wire [7:0] atomic_mem_wstrb;
    wire [`RV64_XLEN-1:0] atomic_effective_addr;
    wire [2:0] atomic_access_size;
    wire atomic_resp_claim;
    wire atomic_resp_ready;

    wire atomic_result_valid;
    wire atomic_result_ready;
    wire [`OPENRV64_INSTR_ID_WIDTH-1:0] atomic_result_id;
    wire [RETIRE_SLOT_WIDTH-1:0] atomic_result_slot;
    wire [`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0] atomic_result_meta;
    wire [`RV64_XLEN-1:0] atomic_result;
    wire atomic_illegal;
    wire atomic_misaligned;
    wire atomic_access_fault;
    wire atomic_page_fault;

    openrv64_lsq #(
        .RETIRE_SLOT_WIDTH(RETIRE_SLOT_WIDTH),
        .META_WIDTH(`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH),
        .LOAD_QUEUE_DEPTH(LOAD_QUEUE_DEPTH),
        .STORE_QUEUE_DEPTH(STORE_QUEUE_DEPTH),
        .TAG_WIDTH(LSU_TAG_WIDTH),
        .CACHEABLE_BASE(CACHEABLE_BASE),
        .CACHEABLE_SIZE(CACHEABLE_SIZE)
    ) u_lsq (
        .clk(clk),
        .rst_n(rst_n),
        .flush_i(flush_i),
        .squash_younger_i(squash_younger_i),
        .squash_id_i(squash_id_i),
        .translation_bypass_i(translation_bypass_i),
        .load_alloc_valid_i(load_issue_valid_i),
        .load_alloc_ready_o(load_issue_ready_o),
        .load_alloc_id_i(load_issue_id_i),
        .load_alloc_slot_i(load_issue_slot_i),
        .load_alloc_meta_i(load_issue_payload_i),
        .load_alloc_immediate_i(load_immediate),
        // Translation and PMP status belongs to the tagged response.  There
        // is no valid access verdict at LSQ allocation time.
        .load_alloc_access_fault_i(1'b0),
        .load_alloc_vaddr_i(load_bus_addr),
        .load_alloc_size_i({1'b0, load_instr[13:12]}),
        .store_alloc_valid_i(store_issue_valid_i),
        .store_alloc_ready_o(store_issue_ready_o),
        .store_alloc_id_i(store_issue_id_i),
        .store_alloc_slot_i(store_issue_slot_i),
        .store_alloc_meta_i(store_issue_payload_i),
        .store_alloc_immediate_i(store_immediate),
        .store_alloc_access_fault_i(1'b0),
        .store_alloc_atomic_i(store_is_atomic),
        .store_alloc_vaddr_i(store_is_atomic ?
                             store_effective_addr : store_bus_addr),
        .store_alloc_size_i({1'b0, store_instr[13:12]}),
        .store_alloc_wdata_i(store_bus_wdata),
        .store_alloc_wstrb_i(store_bus_wstrb),
        .ordered_head_valid_i(ordered_head_valid_i),
        .ordered_head_id_i(ordered_head_id_i),
        .ordered_head_slot_i(ordered_head_slot_i),
        .atomic_start_valid_o(atomic_start_valid),
        .atomic_start_tag_o(atomic_start_tag),
        .atomic_start_id_o(atomic_start_id),
        .atomic_start_slot_o(atomic_start_slot),
        .atomic_start_meta_o(atomic_start_meta),
        .atomic_start_access_allowed_o(atomic_start_access_allowed),
        .atomic_active_i(atomic_active),
        .atomic_tag_i(atomic_tag),
        .atomic_irrevocable_i(atomic_irrevocable),
        .atomic_done_i(atomic_done),
        .xlate_req_valid_o(xlate_valid_o),
        .xlate_req_ready_i(xlate_ready_i),
        .xlate_req_tag_o(xlate_tag_o),
        .xlate_req_write_o(xlate_write_o),
        .xlate_req_vaddr_o(xlate_vaddr_o),
        .xlate_resp_valid_i(xlate_resp_valid_i),
        .xlate_resp_ready_o(xlate_resp_ready_o),
        .xlate_resp_tag_i(xlate_resp_tag_i),
        .xlate_resp_paddr_i(xlate_resp_paddr_i),
        .xlate_resp_access_fault_i(xlate_resp_access_fault_i),
        .xlate_resp_page_fault_i(xlate_resp_page_fault_i),
        .req_valid_o(lsq_req_valid),
        .req_ready_i(lsq_req_ready),
        .req_tag_o(lsq_req_tag),
        .req_write_o(lsq_req_write),
        .req_addr_o(lsq_req_addr),
        .req_vaddr_o(lsq_req_vaddr),
        .req_size_o(lsq_req_size),
        .req_wdata_o(lsq_req_wdata),
        .req_wstrb_o(lsq_req_wstrb),
        .resp_valid_i(lsq_resp_valid),
        .resp_ready_o(lsq_resp_ready),
        .resp_tag_i(mem_resp_tag_i),
        .resp_paddr_i(mem_resp_paddr_i),
        .resp_rdata_i(mem_rdata_i),
        .resp_access_fault_i(mem_error_i),
        .resp_page_fault_i(mem_page_fault_i),
        .store_done_valid_i(mem_store_done_valid_i),
        .store_done_ready_o(mem_store_done_ready_o),
        .store_done_tag_i(mem_store_done_tag_i),
        .result_valid_o(lsq_result_valid),
        .result_ready_i(lsq_result_ready),
        .result_id_o(lsq_result_id),
        .result_slot_o(lsq_result_slot),
        .result_meta_o(lsq_result_meta),
        .result_rdata_o(lsq_result_rdata),
        .result_access_fault_o(lsq_result_access_fault),
        .result_page_fault_o(lsq_result_page_fault),
        .result_store_o(lsq_result_store),
        .store_pending_o(store_pending_o)
    );

    wire clear_atomic_reservation =
        (lsq_result_valid && lsq_result_ready && lsq_result_store) ||
        ((COHERENT_ATOMICS != 0) &&
         coherent_reservation_clear_i);

    openrv64_lsu_atomics #(
        .RETIRE_SLOT_WIDTH(RETIRE_SLOT_WIDTH),
        .LSU_TAG_WIDTH(LSU_TAG_WIDTH),
        .META_WIDTH(`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH),
        .COHERENT_ATOMICS(COHERENT_ATOMICS)
    ) u_atomics (
        .clk(clk),
        .rst_n(rst_n),
        .flush_i(flush_i),
        .start_valid_i(atomic_start_valid),
        .start_ready_o(atomic_start_ready),
        .start_tag_i(atomic_start_tag),
        .start_id_i(atomic_start_id),
        .start_slot_i(atomic_start_slot),
        .start_meta_i(atomic_start_meta),
        .start_access_allowed_i(atomic_start_access_allowed),
        .clear_reservation_i(clear_atomic_reservation),
        .active_o(atomic_active),
        .irrevocable_o(atomic_irrevocable),
        .active_tag_o(atomic_tag),
        .mem_valid_o(atomic_mem_valid),
        .mem_ready_i(mem_ready_i),
        .mem_tag_o(atomic_mem_tag),
        .mem_lock_o(atomic_mem_lock),
        .mem_write_o(atomic_mem_write),
        .mem_addr_o(atomic_mem_addr),
        .mem_wdata_o(atomic_mem_wdata),
        .mem_wstrb_o(atomic_mem_wstrb),
        .mem_effective_addr_o(atomic_effective_addr),
        .mem_size_o(atomic_access_size),
        .mem_resp_valid_i(mem_resp_valid_i),
        .mem_resp_claim_o(atomic_resp_claim),
        .mem_resp_ready_o(atomic_resp_ready),
        .mem_resp_tag_i(mem_resp_tag_i),
        .mem_rdata_i(mem_rdata_i),
        .mem_error_i(mem_error_i),
        .mem_page_fault_i(mem_page_fault_i),
        .result_valid_o(atomic_result_valid),
        .result_ready_i(atomic_result_ready),
        .result_id_o(atomic_result_id),
        .result_slot_o(atomic_result_slot),
        .result_meta_o(atomic_result_meta),
        .result_data_o(atomic_result),
        .result_illegal_o(atomic_illegal),
        .result_misaligned_o(atomic_misaligned),
        .result_access_fault_o(atomic_access_fault),
        .result_page_fault_o(atomic_page_fault),
        .done_o(atomic_done)
    );

    assign lsq_resp_valid = mem_resp_valid_i && !atomic_resp_claim;
    assign mem_resp_ready_o = atomic_resp_claim ? atomic_resp_ready :
                              lsq_resp_ready;

    assign mem_valid_o = atomic_active ? atomic_mem_valid : lsq_req_valid;
    assign mem_tag_o = atomic_active ? atomic_mem_tag : lsq_req_tag;
    assign mem_xlate_only_o = 1'b0;
    assign mem_physical_o = !atomic_active;
    assign mem_lock_o = atomic_active ? atomic_mem_lock : 1'b0;
    assign mem_write_o = atomic_active ? atomic_mem_write :
                         lsq_req_write;
    assign mem_addr_o = atomic_active ? atomic_mem_addr : lsq_req_addr;
    assign mem_wdata_o = atomic_active ? atomic_mem_wdata :
                         lsq_req_wdata;
    assign mem_wstrb_o = atomic_active ? atomic_mem_wstrb :
                         lsq_req_wstrb;
    assign mem_access_o = mem_valid_o;
    assign mem_effective_addr_o = atomic_active ?
                                  atomic_effective_addr : lsq_req_vaddr;
    assign mem_size_o = atomic_active ? atomic_access_size : lsq_req_size;
    assign lsq_req_ready = !atomic_active && mem_ready_i;

    reg complete_valid_q;
    reg complete_store_q;
    reg [`OPENRV64_INSTR_ID_WIDTH-1:0] complete_id_q;
    reg [RETIRE_SLOT_WIDTH-1:0] complete_slot_q;
    reg [`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH-1:0] complete_payload_q;
    wire output_available = !complete_valid_q || complete_ready_i;
    assign atomic_result_ready = output_available;
    wire atomic_result_fire = atomic_result_valid && atomic_result_ready;
    assign lsq_result_ready = output_available && !atomic_result_valid;
    wire lsq_result_fire = lsq_result_valid && lsq_result_ready;

    wire [`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0] completion_source =
        atomic_result_valid ? atomic_result_meta : lsq_result_meta;
    wire completion_is_atomic = atomic_result_valid;
    wire [`RV64_INSTR_WIDTH-1:0] completion_instr =
        completion_source[I_INSTR +: `RV64_INSTR_WIDTH];
    wire [`RV64_XLEN-1:0] completion_pc =
        completion_source[I_PC +: `RV64_XLEN];
    wire [63:0] completion_trace =
        completion_source[I_TRACE +: 64];
    wire [`RV64_REG_ADDR_WIDTH-1:0] completion_rs1 =
        completion_source[I_RS1 +: `RV64_REG_ADDR_WIDTH];
    wire [`RV64_REG_ADDR_WIDTH-1:0] completion_rs2 =
        completion_source[I_RS2 +: `RV64_REG_ADDR_WIDTH];
    wire [`RV64_XLEN-1:0] completion_rs1_data =
        completion_source[I_RS1_DATA +: `RV64_XLEN];
    wire [`RV64_XLEN-1:0] completion_rs2_data =
        completion_source[I_RS2_DATA +: `RV64_XLEN];
    wire [`RV64_XLEN-1:0] completion_imm =
        completion_source[I_IMM +: `RV64_XLEN];
    wire [`RV64_REG_ADDR_WIDTH-1:0] completion_rd =
        completion_source[I_RD +: `RV64_REG_ADDR_WIDTH];
    wire [`RV64_LSU_OP_WIDTH-1:0] completion_lsu_op =
        completion_source[I_LSU_OP +: `RV64_LSU_OP_WIDTH];
    wire completion_mem_read = completion_source[I_MEM_READ];
    wire completion_mem_write = completion_source[I_MEM_WRITE];
    wire completion_reg_write_intent = completion_source[I_REG_WRITE];
    wire completion_illegal_input = completion_source[I_ILLEGAL];
    wire completion_ebreak = completion_source[I_EBREAK];
    wire completion_ecall = completion_source[I_ECALL];
    wire completion_instr_access_fault =
        completion_source[I_INSTR_ACCESS_FAULT];
    wire completion_instr_page_fault =
        completion_source[I_INSTR_PAGE_FAULT];
    wire [`RV64_PRIV_WIDTH-1:0] completion_priv =
        completion_source[I_PRIV +: `RV64_PRIV_WIDTH];
    wire [`RV64_XLEN-1:0] completion_effective_addr =
        completion_rs1_data + completion_imm;

    wire completion_lsu_valid;
    wire completion_lsu_illegal;
    wire completion_lsu_misaligned;
    wire [`RV64_XLEN-1:0] completion_load_data;
    wire unused_completion_mem_valid;
    wire unused_completion_mem_write;
    wire [`RV64_XLEN-1:0] unused_completion_mem_addr;
    wire [`RV64_XLEN-1:0] unused_completion_mem_wdata;
    wire [7:0] unused_completion_mem_wstrb;
    openrv64_exec_lsu_rv64i u_completion_lsu (
        .op_sel_i(completion_lsu_op),
        .base_i(completion_rs1_data),
        .offset_i(completion_imm),
        .store_data_i(completion_rs2_data),
        .mem_rdata_i(lsq_result_rdata),
        .valid_o(completion_lsu_valid),
        .illegal_o(completion_lsu_illegal),
        .misaligned_o(completion_lsu_misaligned),
        .load_data_o(completion_load_data),
        .mem_valid_o(unused_completion_mem_valid),
        .mem_write_o(unused_completion_mem_write),
        .mem_addr_o(unused_completion_mem_addr),
        .mem_wdata_o(unused_completion_mem_wdata),
        .mem_wstrb_o(unused_completion_mem_wstrb)
    );

    wire load_misaligned = completion_mem_read &&
        (completion_is_atomic ? atomic_misaligned :
                                completion_lsu_misaligned);
    wire store_misaligned = completion_mem_write &&
        (completion_is_atomic ? atomic_misaligned :
                                completion_lsu_misaligned);
    wire load_access_fault = completion_mem_read &&
        (completion_is_atomic ? atomic_access_fault :
                                lsq_result_access_fault);
    wire store_access_fault = completion_mem_write &&
        (completion_is_atomic ? atomic_access_fault :
                                lsq_result_access_fault);
    wire load_page_fault = completion_mem_read &&
        (completion_is_atomic ? atomic_page_fault :
                                lsq_result_page_fault);
    wire store_page_fault = completion_mem_write &&
        (completion_is_atomic ? atomic_page_fault :
                                lsq_result_page_fault);
    wire result_illegal = completion_illegal_input ||
        (completion_is_atomic ? atomic_illegal :
         (!completion_lsu_valid || completion_lsu_illegal));

    wire exception;
    wire halt;
    wire [`RV64_EXCEPT_CAUSE_WIDTH-1:0] cause;
    wire [`RV64_XLEN-1:0] tval;
    openrv64_except u_except (
        .illegal_instr_i(result_illegal),
        .instr_misaligned_i(|completion_pc[1:0]),
        .instr_access_fault_i(completion_instr_access_fault),
        .instr_page_fault_i(completion_instr_page_fault),
        .load_misaligned_i(load_misaligned),
        .load_access_fault_i(load_access_fault),
        .load_page_fault_i(load_page_fault),
        .store_misaligned_i(store_misaligned),
        .store_access_fault_i(store_access_fault),
        .store_page_fault_i(store_page_fault),
        .ecall_i(completion_ecall),
        .ebreak_i(completion_ebreak),
        .priv_mode_i(completion_priv),
        .pc_i(completion_pc),
        .instr_i(completion_instr),
        .badaddr_i(completion_effective_addr),
        .exception_o(exception),
        .halt_o(halt),
        .cause_o(cause),
        .tval_o(tval)
    );

    wire [`RV64_XLEN-1:0] result_data =
        completion_is_atomic ? atomic_result :
        completion_mem_read ? completion_load_data :
        {`RV64_XLEN{1'b0}};
    wire completion_reg_write = completion_reg_write_intent &&
        (!completion_mem_write || completion_is_atomic);
    wire [`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH-1:0] completion_data = {
        completion_trace,
        completion_pc,
        completion_pc + 64'd4,
        completion_instr,
        result_data,
        completion_rs1,
        completion_rs2,
        completion_rd,
        completion_reg_write,
        result_illegal,
        completion_ebreak,
        completion_ecall,
        exception,
        halt,
        cause,
        tval,
        1'b0,
        1'b0,
        1'b0,
        {`RV64_FUNCT12_WIDTH{1'b0}},
        {`RV64_XLEN{1'b0}}
    };

    assign complete_valid_o = complete_valid_q;
    assign complete_id_o = complete_id_q;
    assign complete_slot_o = complete_slot_q;
    assign complete_payload_o = complete_payload_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            complete_valid_q <= 1'b0;
            complete_store_q <= 1'b0;
            complete_id_q <= {`OPENRV64_INSTR_ID_WIDTH{1'b0}};
            complete_slot_q <= {RETIRE_SLOT_WIDTH{1'b0}};
            complete_payload_q <=
                {`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH{1'b0}};
        end else if (flush_i) begin
            // An accepted ordinary store (or completed atomic) is
            // irrevocable. Keep an already-buffered completion across a
            // younger redirect until the backend consumes it.
            complete_valid_q <= complete_valid_q && complete_store_q &&
                                !complete_ready_i;
            complete_store_q <= complete_valid_q && complete_store_q &&
                                !complete_ready_i;
            if (lsq_result_fire && lsq_result_store) begin
                complete_valid_q <= 1'b1;
                complete_id_q <= lsq_result_id;
                complete_slot_q <= lsq_result_slot;
                complete_payload_q <= completion_data;
                complete_store_q <= 1'b1;
            end else if (atomic_result_fire) begin
                complete_valid_q <= 1'b1;
                complete_id_q <= atomic_result_id;
                complete_slot_q <= atomic_result_slot;
                complete_payload_q <= completion_data;
                complete_store_q <= 1'b1;
            end
        end else begin
            if (complete_valid_q && complete_ready_i) begin
                complete_valid_q <= 1'b0;
                complete_store_q <= 1'b0;
            end

            if (atomic_result_fire) begin
                complete_valid_q <= 1'b1;
                complete_id_q <= atomic_result_id;
                complete_slot_q <= atomic_result_slot;
                complete_payload_q <= completion_data;
                complete_store_q <= 1'b1;
            end else if (lsq_result_fire) begin
                complete_valid_q <= 1'b1;
                complete_id_q <= lsq_result_id;
                complete_slot_q <= lsq_result_slot;
                complete_payload_q <= completion_data;
                complete_store_q <= lsq_result_store;
            end
        end
    end

endmodule
