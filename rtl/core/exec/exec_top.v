`timescale 1ns/1ps
`include "core/backend/backend-defs.v"
`include "core/bus/bus-defs.v"
`include "core/isa/rv64-i.v"
`include "core/isa/rv64-priv.v"
`include "core/decode/defs/alu-defs.v"
`include "core/decode/defs/lsu-defs.v"
`include "core/decode/defs/br-defs.v"
`include "core/except/except-defs.v"

module openrv64_exec_top #(
    parameter [`OPENRV64_BACKEND_CONFIG_WIDTH-1:0] BACKEND_CONFIG =
        `OPENRV64_BACKEND_1P,
    parameter PIPE_EX_MEM = 1,
    parameter PIPE_MEM_WB = 1,
    parameter ENABLE_RV64M = 0,
    parameter ENABLE_FORWARDING = 0,
    parameter ENABLE_LOAD_FORWARDING = 0,
    parameter integer ENABLE_LOCAL_FORWARDING_3P = 1,
    parameter integer ENABLE_POSTED_STORES = 1,
    parameter integer STORE_QUEUE_DEPTH_3P = 4,
    parameter integer ENABLE_COHERENT_ATOMICS_3P = 0,
    parameter [`RV64_XLEN-1:0] STORE_FORWARD_BASE = {`RV64_XLEN{1'b0}},
    parameter [`RV64_XLEN-1:0] STORE_FORWARD_SIZE = {`RV64_XLEN{1'b0}},
    parameter [`RV64_XLEN-1:0] CACHEABLE_BASE_3P =
        {`RV64_XLEN{1'b0}},
    parameter [`RV64_XLEN-1:0] CACHEABLE_SIZE_3P =
        {`RV64_XLEN{1'b0}},
    parameter integer RETIRE_SLOT_WIDTH_3P = 3
) (
    input  wire                         clk,
    input  wire                         rst_n,

    input  wire                         valid_i,
    output wire                         clear_o,
    output wire                         alu_ready_o,
    output wire                         lsu_ready_o,
    output wire                         br_ready_o,
    output wire                         system_ready_o,
    input  wire                         flush_ex_mem_i,
    input  wire                         flush_mem_wb_i,
    input  wire [`RV64_XLEN-1:0]        pc_i,
    input  wire [`RV64_INSTR_WIDTH-1:0] instr_i,
    input  wire [`RV64_REG_ADDR_WIDTH-1:0] rs1_addr_i,
    input  wire [`RV64_REG_ADDR_WIDTH-1:0] rs2_addr_i,
    input  wire [`RV64_XLEN-1:0]        rs1_data_i,
    input  wire [`RV64_XLEN-1:0]        rs2_data_i,
    input  wire [`RV64_XLEN-1:0]        imm_i,
    input  wire [`RV64_REG_ADDR_WIDTH-1:0] rd_addr_i,
    input  wire [`RV64_ALU_EXT_WIDTH-1:0] alu_ext_i,
    input  wire [`RV64_ALU_OP_WIDTH-1:0] alu_op_i,
    input  wire [`RV64_LSU_OP_WIDTH-1:0] lsu_op_i,
    input  wire [`RV64_BR_OP_WIDTH-1:0] br_op_i,
    input  wire                         reg_write_i,
    input  wire                         mem_read_i,
    input  wire                         mem_write_i,
    input  wire                         branch_i,
    input  wire                         jump_i,
    input  wire                         predicted_taken_i,
    input  wire                         word_op_i,
    input  wire                         system_i,
    input  wire                         fence_i,
    input  wire                         illegal_i,
    input  wire                         ebreak_i,
    input  wire                         ecall_i,
    input  wire                         instr_access_fault_i,
    input  wire                         instr_page_fault_i,
    input  wire [`RV64_PRIV_WIDTH-1:0] priv_mode_i,
    input  wire                         sret_allowed_i,
    input  wire                         sfence_vma_allowed_i,

    output wire                         redirect_valid_o,
    output wire [`RV64_XLEN-1:0]        redirect_target_o,
    output wire                         branch_resolved_o,
    output wire                         branch_conditional_o,
    output wire                         branch_taken_o,
    output wire [`RV64_XLEN-1:0]        branch_pc_o,
    output wire [`RV64_INSTR_WIDTH-1:0] branch_instr_o,

    output wire [`RV64_FUNCT12_WIDTH-1:0] csr_addr_o,
    input  wire [`RV64_XLEN-1:0]        csr_rdata_i,
    input  wire                         csr_valid_i,
    input  wire                         csr_writable_i,
    output wire                         csr_write_o,
    output wire [`RV64_XLEN-1:0]        csr_wdata_o,

    output wire                         mem_valid_o,
    input  wire                         mem_ready_i,
    output wire [`OPENRV64_LSU_TAG_WIDTH-1:0] mem_tag_o,
    output wire                         mem_xlate_only_o,
    output wire                         mem_physical_o,
    input  wire                         mem_resp_valid_i,
    output wire                         mem_resp_ready_o,
    input  wire [`OPENRV64_LSU_TAG_WIDTH-1:0] mem_resp_tag_i,
    input  wire [`RV64_XLEN-1:0]        mem_resp_paddr_i,
    input  wire                         mem_error_i,
    input  wire                         mem_page_fault_i,
    input  wire                         mem_store_done_valid_i,
    output wire                         mem_store_done_ready_o,
    input  wire [`OPENRV64_LSU_TAG_WIDTH-1:0]
                                        mem_store_done_tag_i,
    input  wire                         mem_access_allowed_i,
    output wire                         mem_lock_o,
    output wire                         mem_write_o,
    output wire [`RV64_XLEN-1:0]        mem_addr_o,
    output wire [`RV64_XLEN-1:0]        mem_wdata_o,
    output wire [7:0]                   mem_wstrb_o,
    output wire                         mem_access_o,
    output wire [`RV64_XLEN-1:0]        mem_effective_addr_o,
    output wire [2:0]                   mem_size_o,
    input  wire [`RV64_XLEN-1:0]        mem_rdata_i,
    output wire                         mem_xlate_valid_o,
    input  wire                         mem_xlate_ready_i,
    output wire [`OPENRV64_LSU_TAG_WIDTH-1:0] mem_xlate_tag_o,
    output wire                         mem_xlate_write_o,
    output wire [`RV64_XLEN-1:0]        mem_xlate_vaddr_o,
    input  wire                         mem_xlate_resp_valid_i,
    output wire                         mem_xlate_resp_ready_o,
    input  wire [`OPENRV64_LSU_TAG_WIDTH-1:0] mem_xlate_resp_tag_i,
    input  wire [`RV64_XLEN-1:0]        mem_xlate_resp_paddr_i,
    input  wire                         mem_xlate_resp_access_fault_i,
    input  wire                         mem_xlate_resp_page_fault_i,
    output wire                         mem1_valid_o,
    input  wire                         mem1_ready_i,
    output wire [`OPENRV64_LSU_TAG_WIDTH-1:0] mem1_tag_o,
    output wire                         mem1_lock_o,
    output wire                         mem1_write_o,
    output wire [`RV64_XLEN-1:0]        mem1_addr_o,
    output wire [`RV64_XLEN-1:0]        mem1_wdata_o,
    output wire [7:0]                   mem1_wstrb_o,
    output wire                         mem1_access_o,
    output wire [`RV64_XLEN-1:0]        mem1_effective_addr_o,
    output wire [2:0]                   mem1_size_o,

    output wire                         wb_valid_o,
    input  wire                         wb_clear_i,
    output wire [`RV64_XLEN-1:0]        wb_pc_o,
    output wire [`RV64_XLEN-1:0]        wb_next_pc_o,
    output wire [`RV64_INSTR_WIDTH-1:0] wb_instr_o,
    output wire [`RV64_XLEN-1:0]        wb_data_o,
    output wire [`RV64_REG_ADDR_WIDTH-1:0] wb_rs1_addr_o,
    output wire [`RV64_REG_ADDR_WIDTH-1:0] wb_rs2_addr_o,
    output wire [`RV64_REG_ADDR_WIDTH-1:0] wb_rd_addr_o,
    output wire                         wb_reg_write_o,
    output wire                         wb_illegal_o,
    output wire                         wb_ebreak_o,
    output wire                         wb_ecall_o,
    output wire                         wb_exception_o,
    output wire                         wb_halt_o,
    output wire [`RV64_EXCEPT_CAUSE_WIDTH-1:0] wb_cause_o,
    output wire [`RV64_XLEN-1:0]        wb_tval_o,
    output wire                         wb_mret_o,
    output wire                         wb_sret_o,

    output wire                         forward_ex_valid_o,
    output wire [`RV64_REG_ADDR_WIDTH-1:0] forward_ex_rd_addr_o,
    output wire                         forward_mem_valid_o,
    output wire [`RV64_REG_ADDR_WIDTH-1:0] forward_mem_rd_addr_o,

    input  wire [63:0]                  trace_id_i,
    output wire                         trace_ex_advance_o,
    output wire                         trace_mem_valid_o,
    output wire                         trace_mem_clear_o,
    output wire [63:0]                  trace_mem_id_o,
    output wire [`RV64_XLEN-1:0]        trace_mem_pc_o,
    output wire [`RV64_INSTR_WIDTH-1:0] trace_mem_instr_o,
    output wire [63:0]                  trace_wb_id_o,
    output wire                         trace_serializing_o,

    input  wire                         flush_3p_i,
    input  wire                         squash_younger_3p_i,
    input  wire [`OPENRV64_INSTR_ID_WIDTH-1:0] squash_id_3p_i,
    input  wire                         coherent_reservation_clear_3p_i,
    input  wire                         translation_bypass_3p_i,
    input  wire [`OPENRV64_EXEC_PIPE_COUNT-1:0] issue_valid_3p_i,
    output wire [`OPENRV64_EXEC_PIPE_COUNT-1:0] issue_ready_3p_o,
    output wire [`OPENRV64_EXEC_PIPE_COUNT-1:0] issue_unsupported_3p_o,
    input  wire [`OPENRV64_EXEC_PIPE_COUNT*
                 `OPENRV64_INSTR_ID_WIDTH-1:0] issue_id_3p_i,
    input  wire [`OPENRV64_EXEC_PIPE_COUNT*RETIRE_SLOT_WIDTH_3P-1:0]
                                        issue_slot_3p_i,
    input  wire [`OPENRV64_EXEC_PIPE_COUNT*
                 `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0]
                                        issue_payload_3p_i,
    input  wire                         branch_forward_valid_3p_i,
    input  wire [`OPENRV64_INSTR_ID_WIDTH-1:0]
                                        branch_forward_id_3p_i,
    input  wire [`RV64_REG_ADDR_WIDTH-1:0]
                                        branch_forward_rd_addr_3p_i,
    input  wire [`RV64_XLEN-1:0]        branch_forward_data_3p_i,
    input  wire [`OPENRV64_EXEC_PIPE_COUNT-1:0]
                                        issue_src1_producer_valid_3p_i,
    input  wire [`OPENRV64_EXEC_PIPE_COUNT*
                 `OPENRV64_INSTR_ID_WIDTH-1:0]
                                        issue_src1_producer_id_3p_i,
    input  wire [`OPENRV64_EXEC_PIPE_COUNT-1:0]
                                        issue_src2_producer_valid_3p_i,
    input  wire [`OPENRV64_EXEC_PIPE_COUNT*
                 `OPENRV64_INSTR_ID_WIDTH-1:0]
                                        issue_src2_producer_id_3p_i,
    input  wire                         ordered_head_valid_3p_i,
    input  wire [`OPENRV64_INSTR_ID_WIDTH-1:0] ordered_head_id_3p_i,
    input  wire [RETIRE_SLOT_WIDTH_3P-1:0] ordered_head_slot_3p_i,
    output wire [2:0]                   complete_valid_3p_o,
    input  wire [2:0]                   complete_ready_3p_i,
    output wire [3*`OPENRV64_INSTR_ID_WIDTH-1:0] complete_id_3p_o,
    output wire [3*RETIRE_SLOT_WIDTH_3P-1:0] complete_slot_3p_o,
    output wire [3*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH-1:0]
                                        complete_payload_3p_o,
    output wire                         async_store_fault_3p_o,
    output wire                         async_store_page_fault_3p_o,
    output wire [`RV64_XLEN-1:0]        async_store_fault_pc_3p_o,
    output wire [`RV64_XLEN-1:0]        async_store_fault_addr_3p_o,
    output wire [63:0]                  async_store_fault_trace_3p_o,
    output wire [`RV64_INSTR_WIDTH-1:0] async_store_fault_instr_3p_o,
    output wire [`OPENRV64_INSTR_ID_WIDTH-1:0] redirect_id_3p_o,
    output wire [RETIRE_SLOT_WIDTH_3P-1:0] redirect_slot_3p_o
);

    generate
        if (BACKEND_CONFIG == `OPENRV64_BACKEND_1P) begin : g_1p
            openrv64_exec_top_1p #(
                .PIPE_EX_MEM(PIPE_EX_MEM),
                .PIPE_MEM_WB(PIPE_MEM_WB),
                .ENABLE_RV64M(ENABLE_RV64M),
                .ENABLE_FORWARDING(ENABLE_FORWARDING),
                .ENABLE_LOAD_FORWARDING(ENABLE_LOAD_FORWARDING)
            ) u_exec (.*);
            assign issue_ready_3p_o =
                {`OPENRV64_EXEC_PIPE_COUNT{1'b0}};
            assign issue_unsupported_3p_o =
                {`OPENRV64_EXEC_PIPE_COUNT{1'b0}};
            assign complete_valid_3p_o = 3'b000;
            assign complete_id_3p_o =
                {3*`OPENRV64_INSTR_ID_WIDTH{1'b0}};
            assign complete_slot_3p_o = {3*RETIRE_SLOT_WIDTH_3P{1'b0}};
            assign complete_payload_3p_o =
                {3*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH{1'b0}};
            assign redirect_id_3p_o =
                {`OPENRV64_INSTR_ID_WIDTH{1'b0}};
            assign redirect_slot_3p_o = {RETIRE_SLOT_WIDTH_3P{1'b0}};
            assign branch_conditional_o = 1'b0;
            assign branch_pc_o = pc_i;
            assign branch_instr_o = instr_i;
            assign mem_tag_o = {`OPENRV64_LSU_TAG_WIDTH{1'b0}};
            assign mem_xlate_only_o = 1'b0;
            assign mem_physical_o = 1'b0;
            assign mem_resp_ready_o = 1'b0;
            assign mem_store_done_ready_o = 1'b0;
            assign mem_xlate_valid_o = 1'b0;
            assign mem_xlate_tag_o =
                {`OPENRV64_LSU_TAG_WIDTH{1'b0}};
            assign mem_xlate_write_o = 1'b0;
            assign mem_xlate_vaddr_o = {`RV64_XLEN{1'b0}};
            assign mem_xlate_resp_ready_o = 1'b0;
            assign mem1_valid_o = 1'b0;
            assign mem1_tag_o = {`OPENRV64_LSU_TAG_WIDTH{1'b0}};
            assign mem1_lock_o = 1'b0;
            assign mem1_write_o = 1'b0;
            assign mem1_addr_o = {`RV64_XLEN{1'b0}};
            assign mem1_wdata_o = {`RV64_XLEN{1'b0}};
            assign mem1_wstrb_o = 8'd0;
            assign mem1_access_o = 1'b0;
            assign mem1_effective_addr_o = {`RV64_XLEN{1'b0}};
            assign mem1_size_o = 3'd0;
            assign async_store_fault_3p_o = 1'b0;
            assign async_store_page_fault_3p_o = 1'b0;
            assign async_store_fault_pc_3p_o = {`RV64_XLEN{1'b0}};
            assign async_store_fault_addr_3p_o = {`RV64_XLEN{1'b0}};
            assign async_store_fault_trace_3p_o = 64'd0;
            assign async_store_fault_instr_3p_o =
                {`RV64_INSTR_WIDTH{1'b0}};
        end else if (BACKEND_CONFIG == `OPENRV64_BACKEND_3P) begin : g_3p
            openrv64_exec_top_3p #(
                .RETIRE_SLOT_WIDTH(RETIRE_SLOT_WIDTH_3P),
                .ENABLE_RV64M(ENABLE_RV64M),
                .ENABLE_LOCAL_FORWARDING(ENABLE_LOCAL_FORWARDING_3P),
                .ENABLE_POSTED_STORES(ENABLE_POSTED_STORES),
                .STORE_QUEUE_DEPTH(STORE_QUEUE_DEPTH_3P),
                .ENABLE_COHERENT_ATOMICS(
                    ENABLE_COHERENT_ATOMICS_3P),
                .STORE_FORWARD_BASE(STORE_FORWARD_BASE),
                .STORE_FORWARD_SIZE(STORE_FORWARD_SIZE),
                .CACHEABLE_BASE(CACHEABLE_BASE_3P),
                .CACHEABLE_SIZE(CACHEABLE_SIZE_3P)
            ) u_exec (
                .clk(clk), .rst_n(rst_n), .flush_i(flush_3p_i),
                .squash_younger_i(squash_younger_3p_i),
                .squash_id_i(squash_id_3p_i),
                .coherent_reservation_clear_i(
                    coherent_reservation_clear_3p_i),
                .translation_bypass_i(translation_bypass_3p_i),
                .issue_valid_i(issue_valid_3p_i),
                .issue_ready_o(issue_ready_3p_o),
                .issue_unsupported_o(issue_unsupported_3p_o),
                .issue_id_i(issue_id_3p_i),
                .issue_slot_i(issue_slot_3p_i),
                .issue_payload_i(issue_payload_3p_i),
                .branch_forward_valid_i(branch_forward_valid_3p_i),
                .branch_forward_id_i(branch_forward_id_3p_i),
                .branch_forward_rd_addr_i(
                    branch_forward_rd_addr_3p_i),
                .branch_forward_data_i(branch_forward_data_3p_i),
                .issue_src1_producer_valid_i(
                    issue_src1_producer_valid_3p_i),
                .issue_src1_producer_id_i(issue_src1_producer_id_3p_i),
                .issue_src2_producer_valid_i(
                    issue_src2_producer_valid_3p_i),
                .issue_src2_producer_id_i(issue_src2_producer_id_3p_i),
                .ordered_head_valid_i(ordered_head_valid_3p_i),
                .ordered_head_id_i(ordered_head_id_3p_i),
                .ordered_head_slot_i(ordered_head_slot_3p_i),
                .complete_valid_o(complete_valid_3p_o),
                .complete_ready_i(complete_ready_3p_i),
                .complete_id_o(complete_id_3p_o),
                .complete_slot_o(complete_slot_3p_o),
                .complete_payload_o(complete_payload_3p_o),
                .async_store_fault_o(async_store_fault_3p_o),
                .async_store_page_fault_o(async_store_page_fault_3p_o),
                .async_store_fault_pc_o(async_store_fault_pc_3p_o),
                .async_store_fault_addr_o(async_store_fault_addr_3p_o),
                .async_store_fault_trace_o(async_store_fault_trace_3p_o),
                .async_store_fault_instr_o(async_store_fault_instr_3p_o),
                .redirect_valid_o(redirect_valid_o),
                .redirect_id_o(redirect_id_3p_o),
                .redirect_slot_o(redirect_slot_3p_o),
                .redirect_target_o(redirect_target_o),
                .branch_resolved_o(branch_resolved_o),
                .branch_conditional_o(branch_conditional_o),
                .branch_taken_o(branch_taken_o),
                .branch_pc_o(branch_pc_o),
                .branch_instr_o(branch_instr_o),
                .csr_addr_o(csr_addr_o), .csr_rdata_i(csr_rdata_i),
                .csr_valid_i(csr_valid_i), .csr_writable_i(csr_writable_i),
                .mem_valid_o(mem_valid_o), .mem_ready_i(mem_ready_i),
                .mem_tag_o(mem_tag_o),
                .mem_xlate_only_o(mem_xlate_only_o),
                .mem_physical_o(mem_physical_o),
                .mem_resp_valid_i(mem_resp_valid_i),
                .mem_resp_ready_o(mem_resp_ready_o),
                .mem_resp_tag_i(mem_resp_tag_i),
                .mem_resp_paddr_i(mem_resp_paddr_i),
                .mem_error_i(mem_error_i),
                .mem_page_fault_i(mem_page_fault_i),
                .mem_store_done_valid_i(mem_store_done_valid_i),
                .mem_store_done_ready_o(mem_store_done_ready_o),
                .mem_store_done_tag_i(mem_store_done_tag_i),
                .mem_access_allowed_i(mem_access_allowed_i),
                .mem_lock_o(mem_lock_o),
                .mem_write_o(mem_write_o), .mem_addr_o(mem_addr_o),
                .mem_wdata_o(mem_wdata_o), .mem_wstrb_o(mem_wstrb_o),
                .mem_access_o(mem_access_o),
                .mem_effective_addr_o(mem_effective_addr_o),
                .mem_size_o(mem_size_o),
                .mem_xlate_valid_o(mem_xlate_valid_o),
                .mem_xlate_ready_i(mem_xlate_ready_i),
                .mem_xlate_tag_o(mem_xlate_tag_o),
                .mem_xlate_write_o(mem_xlate_write_o),
                .mem_xlate_vaddr_o(mem_xlate_vaddr_o),
                .mem_xlate_resp_valid_i(mem_xlate_resp_valid_i),
                .mem_xlate_resp_ready_o(mem_xlate_resp_ready_o),
                .mem_xlate_resp_tag_i(mem_xlate_resp_tag_i),
                .mem_xlate_resp_paddr_i(mem_xlate_resp_paddr_i),
                .mem_xlate_resp_access_fault_i(
                    mem_xlate_resp_access_fault_i),
                .mem_xlate_resp_page_fault_i(
                    mem_xlate_resp_page_fault_i),
                .mem_rdata_i(mem_rdata_i),
                .mem1_valid_o(mem1_valid_o),
                .mem1_ready_i(mem1_ready_i),
                .mem1_tag_o(mem1_tag_o),
                .mem1_lock_o(mem1_lock_o),
                .mem1_write_o(mem1_write_o),
                .mem1_addr_o(mem1_addr_o),
                .mem1_wdata_o(mem1_wdata_o),
                .mem1_wstrb_o(mem1_wstrb_o),
                .mem1_access_o(mem1_access_o),
                .mem1_effective_addr_o(mem1_effective_addr_o),
                .mem1_size_o(mem1_size_o)
            );

            assign clear_o = 1'b0;
            assign alu_ready_o = 1'b0;
            assign lsu_ready_o = 1'b0;
            assign br_ready_o = 1'b0;
            assign system_ready_o = 1'b0;
            assign csr_write_o = 1'b0;
            assign csr_wdata_o = {`RV64_XLEN{1'b0}};
            assign wb_valid_o = 1'b0;
            assign wb_pc_o = {`RV64_XLEN{1'b0}};
            assign wb_next_pc_o = {`RV64_XLEN{1'b0}};
            assign wb_instr_o = {`RV64_INSTR_WIDTH{1'b0}};
            assign wb_data_o = {`RV64_XLEN{1'b0}};
            assign wb_rs1_addr_o = {`RV64_REG_ADDR_WIDTH{1'b0}};
            assign wb_rs2_addr_o = {`RV64_REG_ADDR_WIDTH{1'b0}};
            assign wb_rd_addr_o = {`RV64_REG_ADDR_WIDTH{1'b0}};
            assign wb_reg_write_o = 1'b0;
            assign wb_illegal_o = 1'b0;
            assign wb_ebreak_o = 1'b0;
            assign wb_ecall_o = 1'b0;
            assign wb_exception_o = 1'b0;
            assign wb_halt_o = 1'b0;
            assign wb_cause_o = {`RV64_EXCEPT_CAUSE_WIDTH{1'b0}};
            assign wb_tval_o = {`RV64_XLEN{1'b0}};
            assign wb_mret_o = 1'b0;
            assign wb_sret_o = 1'b0;
            assign forward_ex_valid_o = 1'b0;
            assign forward_ex_rd_addr_o = {`RV64_REG_ADDR_WIDTH{1'b0}};
            assign forward_mem_valid_o = 1'b0;
            assign forward_mem_rd_addr_o = {`RV64_REG_ADDR_WIDTH{1'b0}};
            assign trace_ex_advance_o = 1'b0;
            assign trace_mem_valid_o = 1'b0;
            assign trace_mem_clear_o = 1'b0;
            assign trace_mem_id_o = 64'd0;
            assign trace_mem_pc_o = {`RV64_XLEN{1'b0}};
            assign trace_mem_instr_o = {`RV64_INSTR_WIDTH{1'b0}};
            assign trace_wb_id_o = 64'd0;
            assign trace_serializing_o = 1'b0;
        end else begin : g_unsupported
            initial begin
                $error("openrv64_exec_top: backend configuration is not implemented");
            end

            assign clear_o = 1'b0;
            assign alu_ready_o = 1'b0;
            assign lsu_ready_o = 1'b0;
            assign br_ready_o = 1'b0;
            assign system_ready_o = 1'b0;
            assign redirect_valid_o = 1'b0;
            assign redirect_target_o = {`RV64_XLEN{1'b0}};
            assign branch_resolved_o = 1'b0;
            assign branch_conditional_o = 1'b0;
            assign branch_taken_o = 1'b0;
            assign branch_pc_o = {`RV64_XLEN{1'b0}};
            assign branch_instr_o = {`RV64_INSTR_WIDTH{1'b0}};
            assign csr_addr_o = {`RV64_FUNCT12_WIDTH{1'b0}};
            assign csr_write_o = 1'b0;
            assign csr_wdata_o = {`RV64_XLEN{1'b0}};
            assign mem_valid_o = 1'b0;
            assign mem_tag_o = {`OPENRV64_LSU_TAG_WIDTH{1'b0}};
            assign mem_xlate_only_o = 1'b0;
            assign mem_physical_o = 1'b0;
            assign mem_resp_ready_o = 1'b0;
            assign mem_store_done_ready_o = 1'b0;
            assign mem_xlate_valid_o = 1'b0;
            assign mem_xlate_tag_o =
                {`OPENRV64_LSU_TAG_WIDTH{1'b0}};
            assign mem_xlate_write_o = 1'b0;
            assign mem_xlate_vaddr_o = {`RV64_XLEN{1'b0}};
            assign mem_xlate_resp_ready_o = 1'b0;
            assign mem_write_o = 1'b0;
            assign mem_addr_o = {`RV64_XLEN{1'b0}};
            assign mem_wdata_o = {`RV64_XLEN{1'b0}};
            assign mem_wstrb_o = 8'h00;
            assign mem_access_o = 1'b0;
            assign mem_effective_addr_o = {`RV64_XLEN{1'b0}};
            assign mem_size_o = 3'd0;
            assign wb_valid_o = 1'b0;
            assign wb_pc_o = {`RV64_XLEN{1'b0}};
            assign wb_next_pc_o = {`RV64_XLEN{1'b0}};
            assign wb_instr_o = {`RV64_INSTR_WIDTH{1'b0}};
            assign wb_data_o = {`RV64_XLEN{1'b0}};
            assign wb_rs1_addr_o = {`RV64_REG_ADDR_WIDTH{1'b0}};
            assign wb_rs2_addr_o = {`RV64_REG_ADDR_WIDTH{1'b0}};
            assign wb_rd_addr_o = {`RV64_REG_ADDR_WIDTH{1'b0}};
            assign wb_reg_write_o = 1'b0;
            assign wb_illegal_o = 1'b0;
            assign wb_ebreak_o = 1'b0;
            assign wb_ecall_o = 1'b0;
            assign wb_exception_o = 1'b0;
            assign wb_halt_o = 1'b0;
            assign wb_cause_o = {`RV64_EXCEPT_CAUSE_WIDTH{1'b0}};
            assign wb_tval_o = {`RV64_XLEN{1'b0}};
            assign wb_mret_o = 1'b0;
            assign wb_sret_o = 1'b0;
            assign forward_ex_valid_o = 1'b0;
            assign forward_ex_rd_addr_o = {`RV64_REG_ADDR_WIDTH{1'b0}};
            assign forward_mem_valid_o = 1'b0;
            assign forward_mem_rd_addr_o = {`RV64_REG_ADDR_WIDTH{1'b0}};
            assign trace_ex_advance_o = 1'b0;
            assign trace_mem_valid_o = 1'b0;
            assign trace_mem_clear_o = 1'b0;
            assign trace_mem_id_o = 64'd0;
            assign trace_mem_pc_o = {`RV64_XLEN{1'b0}};
            assign trace_mem_instr_o = {`RV64_INSTR_WIDTH{1'b0}};
            assign trace_wb_id_o = 64'd0;
            assign trace_serializing_o = 1'b0;
        end
    endgenerate

endmodule
