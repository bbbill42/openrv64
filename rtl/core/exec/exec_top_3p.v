`timescale 1ns/1ps
`include "core/backend/backend-defs.v"
`include "core/bus/bus-defs.v"
`include "core/isa/rv64-i.v"
`include "core/isa/rv64-a.v"
`include "core/isa/rv64-priv.v"
`include "core/decode/defs/alu-defs.v"
`include "core/decode/defs/br-defs.v"

// Four fixed-capability execution lanes:
//
//   lane 0 / EX0: base ALU and RV64M
//   lane 1 / EX1: base ALU, branch/jump, system/CSR, traps and fences
//   lane 2 / MEM0: ordinary loads only
//   lane 3 / MEM1: stores and all RV64A operations, including LR
//
// The issue payload already contains captured operand values.  Each lane holds
// its own completion; MEM0/MEM1 arbitrate onto the third backend completion
// port, while EX0 and EX1 retain dedicated ports.  Valid aligned conditional
// branches resolve as soon as
// their operands are ready.  They still complete into the in-order retirement
// queue, and dispatch normally prevents younger issue beside a resolving
// branch.  The strict path may waive that barrier for BEQ/BNE only after its
// own operand
// comparison proves the prediction correct, so a redirect still never has
// issued younger work to squash.  ordered_head_* continues to authorize every
// other hard-ordered EX1 instruction and is also matched inside MEM before any
// store or atomic side effect is emitted.  A legal aligned direct JAL is also
// safe before the head: its target is deterministic and its link write is
// buffered until retirement.
module openrv64_exec_top_3p #(
    parameter integer RETIRE_SLOT_WIDTH = 3,
    parameter integer ENABLE_RV64M = 1,
    parameter integer ENABLE_LOCAL_FORWARDING = 1,
    parameter integer ENABLE_POSTED_STORES = 1,
    parameter integer STORE_QUEUE_DEPTH = 4,
    parameter integer ENABLE_COHERENT_ATOMICS = 0,
    parameter [`RV64_XLEN-1:0] STORE_FORWARD_BASE = {`RV64_XLEN{1'b0}},
    parameter [`RV64_XLEN-1:0] STORE_FORWARD_SIZE = {`RV64_XLEN{1'b0}},
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

    input  wire [`OPENRV64_EXEC_PIPE_COUNT-1:0] issue_valid_i,
    output wire [`OPENRV64_EXEC_PIPE_COUNT-1:0] issue_ready_o,
    output wire [`OPENRV64_EXEC_PIPE_COUNT-1:0] issue_unsupported_o,
    input  wire [`OPENRV64_EXEC_PIPE_COUNT*
                 `OPENRV64_INSTR_ID_WIDTH-1:0] issue_id_i,
    input  wire [`OPENRV64_EXEC_PIPE_COUNT*RETIRE_SLOT_WIDTH-1:0]
                                        issue_slot_i,
    input  wire [`OPENRV64_EXEC_PIPE_COUNT*
                 `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0]
                                        issue_payload_i,
    input  wire                         branch_forward_valid_i,
    input  wire [`OPENRV64_INSTR_ID_WIDTH-1:0]
                                        branch_forward_id_i,
    input  wire [`RV64_REG_ADDR_WIDTH-1:0]
                                        branch_forward_rd_addr_i,
    input  wire [`RV64_XLEN-1:0]        branch_forward_data_i,
    input  wire [`OPENRV64_EXEC_PIPE_COUNT-1:0]
                                        issue_src1_producer_valid_i,
    input  wire [`OPENRV64_EXEC_PIPE_COUNT*
                 `OPENRV64_INSTR_ID_WIDTH-1:0]
                                        issue_src1_producer_id_i,
    input  wire [`OPENRV64_EXEC_PIPE_COUNT-1:0]
                                        issue_src2_producer_valid_i,
    input  wire [`OPENRV64_EXEC_PIPE_COUNT*
                 `OPENRV64_INSTR_ID_WIDTH-1:0]
                                        issue_src2_producer_id_i,

    input  wire                         ordered_head_valid_i,
    input  wire [`OPENRV64_INSTR_ID_WIDTH-1:0] ordered_head_id_i,
    input  wire [RETIRE_SLOT_WIDTH-1:0] ordered_head_slot_i,

    output wire [2:0]                   complete_valid_o,
    input  wire [2:0]                   complete_ready_i,
    output wire [3*`OPENRV64_INSTR_ID_WIDTH-1:0] complete_id_o,
    output wire [3*RETIRE_SLOT_WIDTH-1:0] complete_slot_o,
    output wire [3*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH-1:0] complete_payload_o,

    output wire                         async_store_fault_o,
    output wire                         async_store_page_fault_o,
    output wire [`RV64_XLEN-1:0]        async_store_fault_pc_o,
    output wire [`RV64_XLEN-1:0]        async_store_fault_addr_o,
    output wire [63:0]                  async_store_fault_trace_o,
    output wire [`RV64_INSTR_WIDTH-1:0] async_store_fault_instr_o,

    output wire                         redirect_valid_o,
    output wire [`OPENRV64_INSTR_ID_WIDTH-1:0] redirect_id_o,
    output wire [RETIRE_SLOT_WIDTH-1:0] redirect_slot_o,
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
    output wire [2:0]                   mem1_size_o
);

    // These low-order payload positions are fixed by backend-defs.v.  Keeping
    // capability decode here gives dispatch one unambiguous physical contract
    // and prevents a lane from silently accepting a misrouted instruction.
    wire [`RV64_ALU_EXT_WIDTH-1:0] ex0_alu_ext =
        issue_payload_i[0*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 32 +:
                        `RV64_ALU_EXT_WIDTH];
    wire [`RV64_ALU_OP_WIDTH-1:0] ex0_alu_op =
        issue_payload_i[0*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 27 +:
                        `RV64_ALU_OP_WIDTH];
    wire ex0_mem_read =
        issue_payload_i[0*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 16];
    wire ex0_mem_write =
        issue_payload_i[0*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 15];
    wire ex0_branch =
        issue_payload_i[0*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 14];
    wire ex0_jump =
        issue_payload_i[0*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 13];
    wire ex0_system =
        issue_payload_i[0*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 10];
    wire ex0_fence =
        issue_payload_i[0*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 9];
    wire ex0_illegal =
        issue_payload_i[0*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 8];
    wire ex0_ebreak =
        issue_payload_i[0*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 7];
    wire ex0_ecall =
        issue_payload_i[0*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 6];
    wire ex0_instr_access_fault =
        issue_payload_i[0*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 5];
    wire ex0_instr_page_fault =
        issue_payload_i[0*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 4];

    wire [`RV64_ALU_EXT_WIDTH-1:0] ex1_alu_ext =
        issue_payload_i[1*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 32 +:
                        `RV64_ALU_EXT_WIDTH];
    wire [`RV64_ALU_OP_WIDTH-1:0] ex1_alu_op =
        issue_payload_i[1*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 27 +:
                        `RV64_ALU_OP_WIDTH];
    wire ex1_mem_read =
        issue_payload_i[1*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 16];
    wire ex1_mem_write =
        issue_payload_i[1*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 15];
    wire ex1_branch =
        issue_payload_i[1*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 14];
    wire ex1_jump =
        issue_payload_i[1*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 13];
    wire ex1_system =
        issue_payload_i[1*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 10];
    wire ex1_fence =
        issue_payload_i[1*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 9];
    wire ex1_illegal =
        issue_payload_i[1*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 8];
    wire ex1_ebreak =
        issue_payload_i[1*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 7];
    wire ex1_ecall =
        issue_payload_i[1*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 6];
    wire ex1_instr_access_fault =
        issue_payload_i[1*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 5];
    wire ex1_instr_page_fault =
        issue_payload_i[1*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 4];

    wire mem0_mem_read =
        issue_payload_i[2*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 16];
    wire mem0_mem_write =
        issue_payload_i[2*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 15];
    wire mem0_branch =
        issue_payload_i[2*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 14];
    wire mem0_jump =
        issue_payload_i[2*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 13];
    wire mem0_system =
        issue_payload_i[2*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 10];
    wire mem0_fence =
        issue_payload_i[2*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 9];
    wire mem0_illegal =
        issue_payload_i[2*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 8];
    wire [`RV64_INSTR_WIDTH-1:0] mem0_instr =
        issue_payload_i[
            2*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 242 +:
            `RV64_INSTR_WIDTH];
    wire mem0_atomic =
        `RV64_OPCODE(mem0_instr) == `RV64_OPCODE_AMO;

    wire mem1_mem_read =
        issue_payload_i[3*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 16];
    wire mem1_mem_write =
        issue_payload_i[3*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 15];
    wire mem1_branch =
        issue_payload_i[3*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 14];
    wire mem1_jump =
        issue_payload_i[3*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 13];
    wire mem1_system =
        issue_payload_i[3*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 10];
    wire mem1_fence =
        issue_payload_i[3*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 9];
    wire mem1_illegal =
        issue_payload_i[3*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 8];
    wire [`RV64_INSTR_WIDTH-1:0] mem1_instr =
        issue_payload_i[
            3*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 242 +:
            `RV64_INSTR_WIDTH];
    wire mem1_atomic =
        `RV64_OPCODE(mem1_instr) == `RV64_OPCODE_AMO;

    wire ex0_alu = ((ex0_alu_ext == `RV64_ALU_EXT_BASE) ||
                    ((ex0_alu_ext == `RV64_ALU_EXT_M) && ENABLE_RV64M)) &&
                   (ex0_alu_op != `RV64_ALU_OP_INVALID);
    wire ex0_control = ex0_branch || ex0_jump || ex0_system || ex0_fence ||
                       ex0_illegal || ex0_ebreak || ex0_ecall ||
                       ex0_instr_access_fault || ex0_instr_page_fault;
    wire ex0_supported = ex0_alu && !ex0_mem_read && !ex0_mem_write &&
                         !ex0_control;

    wire ex1_base = (ex1_alu_ext == `RV64_ALU_EXT_BASE) &&
                    (ex1_alu_op != `RV64_ALU_OP_INVALID);
    wire ex1_control = ex1_branch || ex1_jump || ex1_system || ex1_fence ||
                       ex1_illegal || ex1_ebreak || ex1_ecall ||
                       ex1_instr_access_fault || ex1_instr_page_fault;
    wire ex1_supported = !ex1_mem_read && !ex1_mem_write &&
                         (ex1_base || ex1_control);
    // A direct conditional branch with an aligned target cannot create an
    // architectural side effect or synchronous exception at issue.  Resolve
    // it before retirement so the predictor can be corrected immediately.
    // Payload bit 41 is imm[1]; with 32-bit instruction alignment, zero proves
    // the direct target is aligned.  Faulting/illegal packets remain ordered.
    wire ex1_early_branch = ex1_branch && !ex1_illegal &&
                            !ex1_instr_access_fault &&
                            !ex1_instr_page_fault &&
                            !issue_payload_i[
                                1*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 41];
    wire [`RV64_BR_OP_WIDTH-1:0] ex1_br_op =
        issue_payload_i[1*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 18 +:
                        `RV64_BR_OP_WIDTH];
    wire ex1_early_jal = ex1_jump &&
                         (ex1_br_op == `RV64_BR_OP_JAL) &&
                         !ex1_illegal && !ex1_instr_access_fault &&
                         !ex1_instr_page_fault &&
                         !issue_payload_i[
                             1*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 41];
    wire ex1_requires_order = ex1_control && !ex1_early_branch &&
                              !ex1_early_jal;
    wire [`RV64_INSTR_WIDTH-1:0] ex1_instr =
        issue_payload_i[1*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 242 +:
                        `RV64_INSTR_WIDTH];
    wire ex1_satp_access = ex1_system &&
        (`RV64_FUNCT3(ex1_instr) != `RV64_FUNCT3_SYSTEM_PRIV) &&
        (`RV64_CSR(ex1_instr) == `RV64_CSR_SATP);
    wire ex1_translation_barrier =
        ex1_satp_access || `RV64_IS_SFENCE_VMA(ex1_instr);
    wire mem_posted_store_pending;
    wire ex1_order_match = ordered_head_valid_i &&
        (ordered_head_id_i == issue_id_i[
            1*`OPENRV64_INSTR_ID_WIDTH +:
            `OPENRV64_INSTR_ID_WIDTH]) &&
        (ordered_head_slot_i ==
         issue_slot_i[1*RETIRE_SLOT_WIDTH +: RETIRE_SLOT_WIDTH]);
    // SATP and SFENCE.VMA execute only at ordered head.  An unresolved store
    // remains the MEM ordering head until translation/PMP/L1D admission
    // completes, so it cannot be bypassed by either barrier.
    wire ex1_order_ready =
        (!ex1_requires_order || ex1_order_match) &&
        (!ex1_translation_barrier || !mem_posted_store_pending);
    wire mem0_supported = mem0_mem_read && !mem0_mem_write && !mem0_atomic &&
                          !mem0_branch && !mem0_jump && !mem0_system &&
                          !mem0_fence && !mem0_illegal;
    wire mem1_supported = (mem1_mem_write || mem1_atomic) &&
                          !mem1_branch && !mem1_jump && !mem1_system &&
                          !mem1_fence && !mem1_illegal;

    wire ex0_issue_valid = issue_valid_i[0] && ex0_supported;
    wire ex1_issue_valid = issue_valid_i[1] && ex1_supported &&
                           ex1_order_ready;
    wire mem0_issue_valid = issue_valid_i[2] && mem0_supported;
    wire mem1_issue_valid = issue_valid_i[3] && mem1_supported;
    wire ex0_issue_ready;
    wire ex1_issue_ready;
    wire mem0_issue_ready;
    wire mem1_issue_ready;

    assign issue_ready_o[0] = ex0_issue_ready && ex0_supported;
    assign issue_ready_o[1] = ex1_issue_ready && ex1_supported &&
                              ex1_order_ready;
    assign issue_ready_o[2] = mem0_issue_ready && mem0_supported;
    assign issue_ready_o[3] = mem1_issue_ready && mem1_supported;
    assign issue_unsupported_o = {
        issue_valid_i[3] && !mem1_supported,
        issue_valid_i[2] && !mem0_supported,
        issue_valid_i[1] && !ex1_supported,
        issue_valid_i[0] && !ex0_supported
    };

    openrv64_exec_pipe_ex0 #(
        .RETIRE_SLOT_WIDTH(RETIRE_SLOT_WIDTH),
        .ENABLE_RV64M(ENABLE_RV64M),
        .ENABLE_LOCAL_FORWARDING(ENABLE_LOCAL_FORWARDING)
    ) u_ex0 (
        .clk(clk),
        .rst_n(rst_n),
        .flush_i(flush_i),
        .issue_valid_i(ex0_issue_valid),
        .issue_ready_o(ex0_issue_ready),
        .issue_id_i(issue_id_i[
            0*`OPENRV64_INSTR_ID_WIDTH +:
            `OPENRV64_INSTR_ID_WIDTH]),
        .issue_slot_i(issue_slot_i[0*RETIRE_SLOT_WIDTH +:
                                   RETIRE_SLOT_WIDTH]),
        .issue_payload_i(issue_payload_i[
            0*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +:
            `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH]),
        .complete_valid_o(complete_valid_o[0]),
        .complete_ready_i(complete_ready_i[0]),
        .complete_id_o(complete_id_o[
            0*`OPENRV64_INSTR_ID_WIDTH +:
            `OPENRV64_INSTR_ID_WIDTH]),
        .complete_slot_o(complete_slot_o[0*RETIRE_SLOT_WIDTH +:
                                        RETIRE_SLOT_WIDTH]),
        .complete_payload_o(complete_payload_o[
            0*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +:
            `OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH])
    );

    openrv64_exec_pipe_ex1 #(
        .RETIRE_SLOT_WIDTH(RETIRE_SLOT_WIDTH),
        .ENABLE_LOCAL_FORWARDING(ENABLE_LOCAL_FORWARDING)
    ) u_ex1 (
        .clk(clk),
        .rst_n(rst_n),
        .flush_i(flush_i),
        .issue_valid_i(ex1_issue_valid),
        .issue_ready_o(ex1_issue_ready),
        .issue_id_i(issue_id_i[
            1*`OPENRV64_INSTR_ID_WIDTH +:
            `OPENRV64_INSTR_ID_WIDTH]),
        .issue_slot_i(issue_slot_i[1*RETIRE_SLOT_WIDTH +:
                                   RETIRE_SLOT_WIDTH]),
        .issue_payload_i(issue_payload_i[
            1*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +:
            `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH]),
        .branch_forward_valid_i(branch_forward_valid_i),
        .branch_forward_id_i(branch_forward_id_i),
        .branch_forward_rd_addr_i(branch_forward_rd_addr_i),
        .branch_forward_data_i(branch_forward_data_i),
        .src1_producer_valid_i(issue_src1_producer_valid_i[1]),
        .src1_producer_id_i(issue_src1_producer_id_i[
            1*`OPENRV64_INSTR_ID_WIDTH +:
            `OPENRV64_INSTR_ID_WIDTH]),
        .src2_producer_valid_i(issue_src2_producer_valid_i[1]),
        .src2_producer_id_i(issue_src2_producer_id_i[
            1*`OPENRV64_INSTR_ID_WIDTH +:
            `OPENRV64_INSTR_ID_WIDTH]),
        .complete_valid_o(complete_valid_o[1]),
        .complete_ready_i(complete_ready_i[1]),
        .complete_id_o(complete_id_o[
            1*`OPENRV64_INSTR_ID_WIDTH +:
            `OPENRV64_INSTR_ID_WIDTH]),
        .complete_slot_o(complete_slot_o[1*RETIRE_SLOT_WIDTH +:
                                        RETIRE_SLOT_WIDTH]),
        .complete_payload_o(complete_payload_o[
            1*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +:
            `OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH]),
        .csr_addr_o(csr_addr_o),
        .csr_rdata_i(csr_rdata_i),
        .csr_valid_i(csr_valid_i),
        .csr_writable_i(csr_writable_i),
        .branch_resolved_o(branch_resolved_o),
        .branch_conditional_o(branch_conditional_o),
        .branch_taken_o(branch_taken_o),
        .branch_pc_o(branch_pc_o),
        .branch_instr_o(branch_instr_o),
        .redirect_valid_o(redirect_valid_o),
        .redirect_id_o(redirect_id_o),
        .redirect_slot_o(redirect_slot_o),
        .redirect_target_o(redirect_target_o)
    );

    openrv64_exec_lsu #(
        .RETIRE_SLOT_WIDTH(RETIRE_SLOT_WIDTH),
        .LOAD_QUEUE_DEPTH(4),
        .STORE_QUEUE_DEPTH(STORE_QUEUE_DEPTH),
        .COHERENT_ATOMICS(ENABLE_COHERENT_ATOMICS),
        .CACHEABLE_BASE(CACHEABLE_BASE),
        .CACHEABLE_SIZE(CACHEABLE_SIZE)
    ) u_lsu (
        .clk(clk),
        .rst_n(rst_n),
        .flush_i(flush_i),
        .squash_younger_i(squash_younger_i),
        .squash_id_i(squash_id_i),
        .coherent_reservation_clear_i(
            coherent_reservation_clear_i),
        .translation_bypass_i(translation_bypass_i),
        .load_issue_valid_i(mem0_issue_valid),
        .load_issue_ready_o(mem0_issue_ready),
        .load_issue_id_i(issue_id_i[
            2*`OPENRV64_INSTR_ID_WIDTH +:
            `OPENRV64_INSTR_ID_WIDTH]),
        .load_issue_slot_i(issue_slot_i[
            2*RETIRE_SLOT_WIDTH +: RETIRE_SLOT_WIDTH]),
        .load_issue_payload_i(issue_payload_i[
            2*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +:
            `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH]),
        .store_issue_valid_i(mem1_issue_valid),
        .store_issue_ready_o(mem1_issue_ready),
        .store_issue_id_i(issue_id_i[
            3*`OPENRV64_INSTR_ID_WIDTH +:
            `OPENRV64_INSTR_ID_WIDTH]),
        .store_issue_slot_i(issue_slot_i[
            3*RETIRE_SLOT_WIDTH +: RETIRE_SLOT_WIDTH]),
        .store_issue_payload_i(issue_payload_i[
            3*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +:
            `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH]),
        .ordered_head_valid_i(ordered_head_valid_i),
        .ordered_head_id_i(ordered_head_id_i),
        .ordered_head_slot_i(ordered_head_slot_i),
        .complete_valid_o(complete_valid_o[2]),
        .complete_ready_i(complete_ready_i[2]),
        .complete_id_o(complete_id_o[
            2*`OPENRV64_INSTR_ID_WIDTH +:
            `OPENRV64_INSTR_ID_WIDTH]),
        .complete_slot_o(complete_slot_o[
            2*RETIRE_SLOT_WIDTH +: RETIRE_SLOT_WIDTH]),
        .complete_payload_o(complete_payload_o[
            2*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +:
            `OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH]),
        .mem_valid_o(mem_valid_o),
        .mem_ready_i(mem_ready_i),
        .mem_tag_o(mem_tag_o),
        .mem_xlate_only_o(mem_xlate_only_o),
        .mem_physical_o(mem_physical_o),
        .mem_lock_o(mem_lock_o),
        .mem_write_o(mem_write_o),
        .mem_addr_o(mem_addr_o),
        .mem_wdata_o(mem_wdata_o),
        .mem_wstrb_o(mem_wstrb_o),
        .mem_access_o(mem_access_o),
        .mem_effective_addr_o(mem_effective_addr_o),
        .mem_size_o(mem_size_o),
        .xlate_valid_o(mem_xlate_valid_o),
        .xlate_ready_i(mem_xlate_ready_i),
        .xlate_tag_o(mem_xlate_tag_o),
        .xlate_write_o(mem_xlate_write_o),
        .xlate_vaddr_o(mem_xlate_vaddr_o),
        .xlate_resp_valid_i(mem_xlate_resp_valid_i),
        .xlate_resp_ready_o(mem_xlate_resp_ready_o),
        .xlate_resp_tag_i(mem_xlate_resp_tag_i),
        .xlate_resp_paddr_i(mem_xlate_resp_paddr_i),
        .xlate_resp_access_fault_i(mem_xlate_resp_access_fault_i),
        .xlate_resp_page_fault_i(mem_xlate_resp_page_fault_i),
        .mem_resp_valid_i(mem_resp_valid_i),
        .mem_resp_ready_o(mem_resp_ready_o),
        .mem_resp_tag_i(mem_resp_tag_i),
        .mem_resp_paddr_i(mem_resp_paddr_i),
        .mem_rdata_i(mem_rdata_i),
        .mem_error_i(mem_error_i),
        .mem_page_fault_i(mem_page_fault_i),
        .mem_store_done_valid_i(mem_store_done_valid_i),
        .mem_store_done_ready_o(mem_store_done_ready_o),
        .mem_store_done_tag_i(mem_store_done_tag_i),
        .store_pending_o(mem_posted_store_pending)
    );

    // The unified LSQ has one translation/L1D launch port.  Keep the legacy
    // second external port tied off until the memory endpoint exposes a second
    // independent translation/PMP probe.
    assign mem1_valid_o = 1'b0;
    assign mem1_tag_o = {`OPENRV64_LSU_TAG_WIDTH{1'b0}};
    assign mem1_lock_o = 1'b0;
    assign mem1_write_o = 1'b0;
    assign mem1_addr_o = {`RV64_XLEN{1'b0}};
    assign mem1_wdata_o = {`RV64_XLEN{1'b0}};
    assign mem1_wstrb_o = 8'h00;
    assign mem1_access_o = 1'b0;
    assign mem1_effective_addr_o = {`RV64_XLEN{1'b0}};
    assign mem1_size_o = 3'd0;

    // Translation/PMP faults remain precise LSQ completions.  Failures after a
    // committed store has entered L1D require a separate machine-check path.
    assign async_store_fault_o = 1'b0;
    assign async_store_page_fault_o = 1'b0;
    assign async_store_fault_pc_o = {`RV64_XLEN{1'b0}};
    assign async_store_fault_addr_o = {`RV64_XLEN{1'b0}};
    assign async_store_fault_trace_o = 64'd0;
    assign async_store_fault_instr_o = {`RV64_INSTR_WIDTH{1'b0}};

`ifndef SYNTHESIS
    always @(posedge clk) begin
        if (rst_n && !flush_i && (|issue_unsupported_o)) begin
            $fatal(1, "three-pipe dispatch sent an instruction to an unsupported lane");
        end
    end
`endif

endmodule
