`timescale 1ns/1ps
`include "core/backend/backend-defs.v"
`include "core/bus/bus-defs.v"
`include "core/isa/rv64-i.v"
`include "core/isa/rv64-priv.v"
`include "core/decode/defs/alu-defs.v"
`include "core/decode/defs/lsu-defs.v"
`include "core/decode/defs/br-defs.v"
`include "core/except/except-defs.v"

// Complete three-pipe backend.  Decode supplies up to three static packets per
// cycle; the dispatch queue may burst three old packets to EX0, EX1, and MEM.
// Operands are captured at issue, results may complete out of order, and the
// retirement queue exposes only the maximal contiguous in-order prefix.
module openrv64_backend_3p #(
    parameter integer RETIRE_DEPTH = 16,
    parameter integer DISPATCH_DEPTH = 6,
    parameter integer PHYS_REG_COUNT = `OPENRV64_PHYS_REG_COUNT,
    parameter integer PHYS_REG_ADDR_WIDTH =
        (PHYS_REG_COUNT < 1) ? 1 : $clog2(PHYS_REG_COUNT + 1),
    parameter integer MAX_READS_PER_REG = 2,
    parameter integer ENABLE_RV64M = 1,
    parameter integer ENABLE_TRACE = 1,
    parameter [2:0] COMPLETION_FORWARD_MASK = 3'b000,
    parameter [2:0] BRANCH_COMPLETION_FORWARD_MASK = 3'b001,
    parameter integer ENABLE_FULL_FORWARDING = 0,
    parameter integer RELAX_WAW = 1,
    parameter integer RELAX_HAZARDS = 0,
    parameter integer FREE_BRANCHES = 0,
    parameter integer ENABLE_EQ_BRANCH_PAIRING = 1,
    parameter integer ENABLE_ISSUE_WINDOW = 0,
    parameter integer ENABLE_SPECULATION_WINDOW = 0,
    parameter integer ISSUE_WINDOW_DEPTH = 16,
    parameter integer ENABLE_POSTED_STORES = 1,
    parameter integer STORE_QUEUE_DEPTH = 4,
    parameter integer ENABLE_COHERENT_ATOMICS = 0,
    parameter [`RV64_XLEN-1:0] STORE_FORWARD_BASE = {`RV64_XLEN{1'b0}},
    parameter [`RV64_XLEN-1:0] STORE_FORWARD_SIZE = {`RV64_XLEN{1'b0}},
    parameter [`RV64_XLEN-1:0] CACHEABLE_BASE = {`RV64_XLEN{1'b0}},
    parameter [`RV64_XLEN-1:0] CACHEABLE_SIZE = {`RV64_XLEN{1'b0}},
    parameter [`RV64_XLEN-1:0] SPEC_LOAD_BASE = {`RV64_XLEN{1'b0}},
    parameter [`RV64_XLEN-1:0] SPEC_LOAD_SIZE = {`RV64_XLEN{1'b0}},
    parameter integer SLOT_WIDTH = $clog2(RETIRE_DEPTH),
    parameter integer RETIRE_COUNT_WIDTH = $clog2(RETIRE_DEPTH + 1),
    parameter integer DISPATCH_COUNT_WIDTH = $clog2(
        ((ENABLE_ISSUE_WINDOW != 0) ? ISSUE_WINDOW_DEPTH : DISPATCH_DEPTH) + 1)
) (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire                         flush_i,
    input  wire                         squash_frontend_i,
    input  wire                         coherent_reservation_clear_i,
    input  wire                         translation_bypass_i,

    input  wire [2:0]                   decode_valid_i,
    output wire [2:0]                   decode_ready_o,
    input  wire [3*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0]
                                        decode_payload_i,
    input  wire [2:0]                   decode_uses_rs1_i,
    input  wire [2:0]                   decode_uses_rs2_i,
    output wire [3*`OPENRV64_INSTR_ID_WIDTH-1:0]
                                        decode_allocation_id_o,
    output wire [3*SLOT_WIDTH-1:0]      decode_allocation_slot_o,

    output wire [`RV64_FUNCT12_WIDTH-1:0] csr_addr_o,
    input  wire [`RV64_XLEN-1:0]        csr_rdata_i,
    input  wire                         csr_valid_i,
    input  wire                         csr_writable_i,
    output wire                         csr_write_o,
    output wire [`RV64_FUNCT12_WIDTH-1:0] csr_write_addr_o,
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

    input  wire                         irq_pending_i,
    input  wire [`RV64_EXCEPT_CAUSE_WIDTH-1:0] irq_cause_i,

    output wire                         redirect_valid_o,
    output wire [`OPENRV64_INSTR_ID_WIDTH-1:0] redirect_id_o,
    output wire [`RV64_XLEN-1:0]        redirect_target_o,
    output wire                         branch_resolved_o,
    output wire                         branch_conditional_o,
    output wire                         branch_taken_o,
    output wire [`RV64_XLEN-1:0]        branch_pc_o,
    output wire [`RV64_INSTR_WIDTH-1:0] branch_instr_o,
    output wire [`OPENRV64_INSTR_ID_WIDTH-1:0] branch_id_o,
    output wire [SLOT_WIDTH-1:0]        branch_slot_o,
    output wire [2:0]                   branch_train_valid_o,
    output wire [2:0]                   branch_train_conditional_o,
    output wire [2:0]                   branch_train_taken_o,
    output wire [3*`RV64_XLEN-1:0]      branch_train_pc_o,
    output wire [2:0]                   branch_retire_age_valid_o,
    output wire [3*`RV64_XLEN-1:0]      branch_retire_age_addr_o,

    output wire [2:0]                   retire_arch_o,
    output wire [1:0]                   retire_count_o,
    output wire                         exception_o,
    output wire                         halt_o,
    output wire                         irq_o,
    output wire                         mret_o,
    output wire                         sret_o,
    output wire                         fence_i_o,
    output wire                         sfence_vma_o,
    output wire [`RV64_EXCEPT_CAUSE_WIDTH-1:0] cause_o,
    output wire [`RV64_XLEN-1:0]        retire_pc_o,
    output wire [`RV64_XLEN-1:0]        retire_next_pc_o,
    output wire [`RV64_XLEN-1:0]        retire_tval_o,
    output wire [63:0]                  retire_trace_id_o,
    output wire [`RV64_INSTR_WIDTH-1:0] retire_instr_o,
    output wire [`RV64_REG_ADDR_WIDTH-1:0] retire_rd_o,
    output wire [`RV64_XLEN-1:0]        retire_wdata_o,

    output wire [`OPENRV64_EXEC_PIPE_COUNT-1:0] issue_valid_o,
    output wire [2:0]                   complete_valid_o,
    output wire [31:0]                  write_busy_o,
    output wire                         barrier_active_o,
    output wire [RETIRE_COUNT_WIDTH-1:0] retire_occupancy_o,
    output wire [DISPATCH_COUNT_WIDTH-1:0] dispatch_occupancy_o
);

    localparam integer RETIRE_META_WIDTH =
        `OPENRV64_DISPATCH_META_WIDTH + 2*PHYS_REG_ADDR_WIDTH;
    localparam integer RETIRE_RECORD_WIDTH =
        `OPENRV64_RETIRE_ALLOC_FIXED_WIDTH + 2*PHYS_REG_ADDR_WIDTH;
    localparam integer RETIRE_RESULT_WIDTH =
        `OPENRV64_RETIRE_RESULT_WIDTH;

    wire [6*PHYS_REG_ADDR_WIDTH-1:0] gpr_read_addr;
    wire [6*`RV64_XLEN-1:0] gpr_read_data;
    wire [2:0] gpr_write;
    wire [3*PHYS_REG_ADDR_WIDTH-1:0] gpr_write_addr;
    wire [3*`RV64_XLEN-1:0] gpr_write_data;

    wire allocation_ready;
    wire queue_allocation_ready;
    wire [2:0] allocation_valid;
    wire [3*`OPENRV64_INSTR_ID_WIDTH-1:0] allocation_id;
    wire [3*SLOT_WIDTH-1:0] allocation_slot;
    wire [3*RETIRE_META_WIDTH-1:0] allocation_meta;
    wire [3*RETIRE_RECORD_WIDTH-1:0] allocation_record;
    wire [2:0] allocation_complete;
    wire [2:0] allocation_mispredict;
    wire [3*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH-1:0]
        allocation_result;
    wire [3*RETIRE_RESULT_WIDTH-1:0] allocation_retire_result;
    wire [3*64-1:0] allocation_trace;

    assign decode_allocation_id_o = allocation_id;
    assign decode_allocation_slot_o = allocation_slot;

    wire [`OPENRV64_EXEC_PIPE_COUNT-1:0] pipe_ready;
    wire [`OPENRV64_EXEC_PIPE_COUNT-1:0] pipe_valid;
    wire [`OPENRV64_EXEC_PIPE_COUNT*
          `OPENRV64_INSTR_ID_WIDTH-1:0] pipe_id;
    wire [`OPENRV64_EXEC_PIPE_COUNT*SLOT_WIDTH-1:0] pipe_slot;
    wire [`OPENRV64_EXEC_PIPE_COUNT*
          `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0] pipe_payload;
    wire [`OPENRV64_EXEC_PIPE_COUNT-1:0] pipe_src1_producer_valid;
    wire [`OPENRV64_EXEC_PIPE_COUNT*
          `OPENRV64_INSTR_ID_WIDTH-1:0] pipe_src1_producer_id;
    wire [`OPENRV64_EXEC_PIPE_COUNT-1:0] pipe_src2_producer_valid;
    wire [`OPENRV64_EXEC_PIPE_COUNT*
          `OPENRV64_INSTR_ID_WIDTH-1:0] pipe_src2_producer_id;
    wire [`OPENRV64_EXEC_PIPE_COUNT-1:0] pipe_unsupported;

    wire [2:0] complete_valid;
    wire [3*`OPENRV64_INSTR_ID_WIDTH-1:0] complete_id;
    wire [3*SLOT_WIDTH-1:0] complete_slot;
    wire [3*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH-1:0]
        complete_payload;
    wire [3*RETIRE_RESULT_WIDTH-1:0] complete_retire_result;
    wire exec_redirect_valid;
    wire [`OPENRV64_INSTR_ID_WIDTH-1:0] exec_redirect_id;
    wire [SLOT_WIDTH-1:0] exec_redirect_slot;
    wire [`RV64_XLEN-1:0] exec_redirect_target;
    wire exec_branch_resolved;
    wire exec_branch_conditional;
    wire exec_branch_taken;
    wire [`RV64_XLEN-1:0] exec_branch_pc;
    wire [`RV64_INSTR_WIDTH-1:0] exec_branch_instr;
    wire async_store_fault;
    wire async_store_page_fault;
    wire [`RV64_XLEN-1:0] async_store_fault_pc;
    wire [`RV64_XLEN-1:0] async_store_fault_addr;
    wire [63:0] async_store_fault_trace;
    wire [`RV64_INSTR_WIDTH-1:0] async_store_fault_instr;
    reg async_store_fault_pending_q;
    reg [`RV64_EXCEPT_CAUSE_WIDTH-1:0] async_store_fault_cause_q;
    reg [`RV64_XLEN-1:0] async_store_fault_addr_q;
    reg [`RV64_XLEN-1:0] async_store_fault_pc_q;
    reg [63:0] async_store_fault_trace_q;
    reg [`RV64_INSTR_WIDTH-1:0] async_store_fault_instr_q;
    reg [`RV64_XLEN-1:0] last_arch_next_pc_q;

    function automatic free_branch_taken;
        input [`RV64_BR_OP_WIDTH-1:0] branch_op;
        input [`RV64_XLEN-1:0] src1;
        input [`RV64_XLEN-1:0] src2;
        begin
            case (branch_op)
                `RV64_BR_OP_BEQ:  free_branch_taken = (src1 == src2);
                `RV64_BR_OP_BNE:  free_branch_taken = (src1 != src2);
                `RV64_BR_OP_BLT:  free_branch_taken =
                    ($signed(src1) < $signed(src2));
                `RV64_BR_OP_BGE:  free_branch_taken =
                    ($signed(src1) >= $signed(src2));
                `RV64_BR_OP_BLTU: free_branch_taken = (src1 < src2);
                `RV64_BR_OP_BGEU: free_branch_taken = (src1 >= src2);
                default:          free_branch_taken = 1'b0;
            endcase
        end
    endfunction

    // Free conditional branches retain their real operands and prediction,
    // but become completed retirement entries without occupying EX0.
    // JAL/JALR remain on the normal path so this experiment isolates branches.
    genvar free_lane;
    generate
        for (free_lane = 0; free_lane < 3;
             free_lane = free_lane + 1) begin : g_free_branch
            wire [`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0] alloc_payload =
                allocation_meta[
                    free_lane*RETIRE_META_WIDTH +:
                    `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH];
            wire alloc_branch = alloc_payload[14];
            wire alloc_fault = alloc_payload[8] || alloc_payload[5] ||
                               alloc_payload[4];
            wire [`RV64_XLEN-1:0] alloc_pc = alloc_payload[274 +: 64];
            wire [`RV64_INSTR_WIDTH-1:0] alloc_instr =
                alloc_payload[242 +: 32];
            wire [`RV64_XLEN-1:0] alloc_rs1_data =
                alloc_payload[168 +: 64];
            wire [`RV64_XLEN-1:0] alloc_rs2_data =
                alloc_payload[104 +: 64];
            wire [`RV64_XLEN-1:0] alloc_imm = alloc_payload[40 +: 64];
            wire [`RV64_BR_OP_WIDTH-1:0] alloc_br_op =
                alloc_payload[18 +: `RV64_BR_OP_WIDTH];
            wire alloc_taken = free_branch_taken(
                alloc_br_op, alloc_rs1_data, alloc_rs2_data);
            wire [`RV64_XLEN-1:0] alloc_target = alloc_pc + alloc_imm;
            wire [`RV64_XLEN-1:0] alloc_next_pc = alloc_taken ?
                alloc_target : (alloc_pc + 64'd4);

            assign allocation_complete[free_lane] =
                (FREE_BRANCHES != 0) &&
                (ENABLE_ISSUE_WINDOW == 0) &&
                allocation_valid[free_lane] && alloc_branch && !alloc_fault;
            assign allocation_mispredict[free_lane] =
                allocation_complete[free_lane] &&
                (alloc_payload[12] != alloc_taken);
            assign allocation_result[
                free_lane*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +:
                `OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH] = {
                alloc_payload[338 +: 64], // trace ID
                alloc_pc,
                alloc_next_pc,
                alloc_instr,
                64'd0,
                alloc_payload[237 +: 5], // rs1
                alloc_payload[232 +: 5], // rs2
                alloc_payload[35 +: 5],  // rd
                alloc_payload[17],       // architectural register write
                1'b0,                    // illegal
                1'b0,                    // ebreak
                1'b0,                    // ecall
                1'b0,                    // exception
                1'b0,                    // halt
                5'd0,                    // cause
                64'd0,                   // tval
                1'b0,                    // mret
                1'b0,                    // sret
                1'b0,                    // csr write
                12'd0,                   // csr address
                64'd0                    // csr data
            };
        end
    endgenerate

    // Retirement stores one canonical compact record per slot.  Fields that
    // already exist at allocation are not echoed through completion.  Trace
    // state is a separate allocation-only debug bank and is absent when trace
    // support is disabled.
    genvar retire_record_lane;
    generate
        for (retire_record_lane = 0; retire_record_lane < 3;
             retire_record_lane = retire_record_lane + 1) begin :
                g_retire_record
            wire [`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0] issue_record =
                allocation_meta[
                    retire_record_lane*RETIRE_META_WIDTH +:
                    `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH];
            wire [`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH-1:0]
                alloc_complete_record = allocation_result[
                    retire_record_lane*
                    `OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +:
                    `OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH];
            wire [`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH-1:0]
                live_complete_record = complete_payload[
                    retire_record_lane*
                    `OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +:
                    `OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH];

            assign allocation_record[
                retire_record_lane*RETIRE_RECORD_WIDTH +:
                RETIRE_RECORD_WIDTH] = {
                allocation_meta[
                    retire_record_lane*RETIRE_META_WIDTH +
                    `OPENRV64_DISPATCH_META_WIDTH +
                    PHYS_REG_ADDR_WIDTH +: PHYS_REG_ADDR_WIDTH],
                allocation_meta[
                    retire_record_lane*RETIRE_META_WIDTH +
                    `OPENRV64_DISPATCH_META_WIDTH +:
                    PHYS_REG_ADDR_WIDTH],
                issue_record[12], // predicted taken
                issue_record[13], // jump
                issue_record[14], // branch
                issue_record[15], // memory write
                issue_record[16], // memory read
                allocation_meta[
                    retire_record_lane*RETIRE_META_WIDTH +
                    `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 2], // hard
                allocation_meta[
                    retire_record_lane*RETIRE_META_WIDTH +
                    `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 1], // uses rs2
                allocation_meta[
                    retire_record_lane*RETIRE_META_WIDTH +
                    `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH],     // uses rs1
                issue_record[17],                           // register write
                issue_record[35 +: `RV64_REG_ADDR_WIDTH],
                issue_record[232 +: `RV64_REG_ADDR_WIDTH],
                issue_record[237 +: `RV64_REG_ADDR_WIDTH],
                issue_record[242 +: `RV64_INSTR_WIDTH],
                issue_record[274 +: `RV64_XLEN]
            };
            assign allocation_trace[
                retire_record_lane*64 +: 64] =
                (ENABLE_TRACE != 0) ? issue_record[338 +: 64] : 64'd0;
            assign allocation_retire_result[
                retire_record_lane*RETIRE_RESULT_WIDTH +:
                RETIRE_RESULT_WIDTH] = {
                alloc_complete_record[265 +: `RV64_XLEN],
                alloc_complete_record[
                    `OPENRV64_COMPLETE_DATA_LSB +: `RV64_XLEN],
                alloc_complete_record[0 +: 153]
            };
            assign complete_retire_result[
                retire_record_lane*RETIRE_RESULT_WIDTH +:
                RETIRE_RESULT_WIDTH] = {
                live_complete_record[265 +: `RV64_XLEN],
                live_complete_record[
                    `OPENRV64_COMPLETE_DATA_LSB +: `RV64_XLEN],
                live_complete_record[0 +: 153]
            };
        end
    endgenerate

    wire [2:0] queue_retire_valid;
    wire [2:0] queue_retire_accept;
    wire [3*`OPENRV64_INSTR_ID_WIDTH-1:0] queue_retire_id;
    wire [3*RETIRE_RECORD_WIDTH-1:0] queue_retire_record;
    wire [3*RETIRE_RESULT_WIDTH-1:0] queue_retire_commit;
    wire [3*64-1:0] queue_retire_trace;
    wire [3*SLOT_WIDTH-1:0] queue_retire_slot;
    wire [2:0] queue_alloc_accept;
    wire [2:0] queue_complete_accept;
    wire [`OPENRV64_INSTR_ID_WIDTH-1:0] next_retire_id;
    wire [SLOT_WIDTH-1:0] next_retire_slot;
    wire queue_post_retire_valid;
    wire [`OPENRV64_INSTR_ID_WIDTH-1:0] queue_post_retire_id;
    wire [SLOT_WIDTH-1:0] queue_post_retire_slot;
    wire [3*SLOT_WIDTH-1:0] window_retire_slot = queue_retire_slot;

    wire retire_exception;
    wire retire_halt;
    wire retire_irq;
    wire retire_mret;
    wire retire_sret;
    wire retire_fence_i;
    wire retire_sfence_vma;
    wire [`RV64_EXCEPT_CAUSE_WIDTH-1:0] retire_cause;
    wire [`RV64_XLEN-1:0] retire_pc;
    wire [`RV64_XLEN-1:0] retire_next_pc;
    wire [`RV64_XLEN-1:0] retire_tval;
    wire [63:0] retire_trace_id;
    wire [`RV64_INSTR_WIDTH-1:0] retire_instr;

    wire [2:0] release_valid;
    wire [2:0] release_uses_rs1;
    wire [2:0] release_uses_rs2;
    wire [3*`RV64_REG_ADDR_WIDTH-1:0] release_rs1_addr;
    wire [3*`RV64_REG_ADDR_WIDTH-1:0] release_rs2_addr;
    wire [2:0] release_reg_write;
    wire [3*`RV64_REG_ADDR_WIDTH-1:0] release_rd_addr;
    wire [2:0] retire_hard;
    wire [2:0] raw_hazard;
    wire [2:0] waw_hazard;
    wire [2:0] read_port_hazard;

    // The non-speculative issue window may execute conditional branches before
    // the retirement head, but publishes resolution only when the branch
    // retires.  The speculation-window path instead consumes EX0 resolution
    // immediately and selectively discards younger IDs below.  This retire-time
    // resolver remains the recovery path for the non-speculative window.
    localparam integer WINDOW_META_BRANCH =
        `OPENRV64_RETIRE_ALLOC_BRANCH_BIT;
    localparam integer WINDOW_META_JUMP =
        `OPENRV64_RETIRE_ALLOC_JUMP_BIT;
    localparam integer WINDOW_META_PREDICTED_TAKEN =
        `OPENRV64_RETIRE_ALLOC_PREDICTED_TAKEN_BIT;
    localparam integer WINDOW_RESULT_EXCEPTION =
        `OPENRV64_RETIRE_RESULT_EXCEPTION_BIT;
    localparam integer WINDOW_RESULT_NEXT_PC =
        `OPENRV64_RETIRE_RESULT_NEXT_PC_LSB;
    localparam integer COMPLETE_RESULT_INSTR = 233;
    localparam integer COMPLETE_RESULT_NEXT_PC = 265;
    localparam integer COMPLETE_RESULT_PC = 329;
    wire window_resolve0 = release_valid[0] &&
        !queue_retire_commit[
            0*RETIRE_RESULT_WIDTH +
            WINDOW_RESULT_EXCEPTION] &&
        (queue_retire_record[
             0*RETIRE_RECORD_WIDTH + WINDOW_META_BRANCH] ||
         queue_retire_record[
             0*RETIRE_RECORD_WIDTH + WINDOW_META_JUMP]);
    wire window_resolve1 = release_valid[1] &&
        !queue_retire_commit[
            1*RETIRE_RESULT_WIDTH +
            WINDOW_RESULT_EXCEPTION] &&
        (queue_retire_record[
             1*RETIRE_RECORD_WIDTH + WINDOW_META_BRANCH] ||
         queue_retire_record[
             1*RETIRE_RECORD_WIDTH + WINDOW_META_JUMP]);
    wire window_resolve2 = release_valid[2] &&
        !queue_retire_commit[
            2*RETIRE_RESULT_WIDTH +
            WINDOW_RESULT_EXCEPTION] &&
        (queue_retire_record[
             2*RETIRE_RECORD_WIDTH + WINDOW_META_BRANCH] ||
         queue_retire_record[
             2*RETIRE_RECORD_WIDTH + WINDOW_META_JUMP]);
    wire window_branch_resolved = window_resolve0 || window_resolve1 ||
                                  window_resolve2;
    wire [1:0] window_resolve_lane = window_resolve0 ? 2'd0 :
                                     window_resolve1 ? 2'd1 : 2'd2;
    wire [RETIRE_RECORD_WIDTH-1:0] window_resolve_meta =
        queue_retire_record[
            window_resolve_lane*RETIRE_RECORD_WIDTH +:
            RETIRE_RECORD_WIDTH];
    wire [RETIRE_RESULT_WIDTH-1:0]
        window_resolve_result = queue_retire_commit[
            window_resolve_lane*RETIRE_RESULT_WIDTH +:
            RETIRE_RESULT_WIDTH];
    wire [`RV64_XLEN-1:0] window_branch_pc = window_resolve_meta[
        `OPENRV64_RETIRE_ALLOC_PC_LSB +: `RV64_XLEN];
    wire [`RV64_XLEN-1:0] window_branch_next_pc = window_resolve_result[
        WINDOW_RESULT_NEXT_PC +: `RV64_XLEN];
    wire window_branch_taken =
        window_branch_next_pc != (window_branch_pc + 64'd4);
    wire window_branch_predicted_taken =
        window_resolve_meta[WINDOW_META_PREDICTED_TAKEN];
    wire window_direction_mispredict = window_branch_resolved &&
        (window_branch_predicted_taken != window_branch_taken);

    // The losing side of a conditional branch becomes cold only when that
    // branch retires.  Resolution can happen much earlier, so this sideband
    // is derived directly from the retirement prefix rather than from the
    // predictor-training or redirect paths.
    genvar retire_age_lane;
    generate
        for (retire_age_lane = 0; retire_age_lane < 3;
             retire_age_lane = retire_age_lane + 1) begin : g_retire_age
            wire [RETIRE_RECORD_WIDTH-1:0] age_meta =
                queue_retire_record[
                    retire_age_lane*RETIRE_RECORD_WIDTH +:
                    RETIRE_RECORD_WIDTH];
            wire [RETIRE_RESULT_WIDTH-1:0] age_result =
                queue_retire_commit[
                    retire_age_lane*RETIRE_RESULT_WIDTH +:
                    RETIRE_RESULT_WIDTH];
            wire [`RV64_XLEN-1:0] age_pc =
                age_meta[
                    `OPENRV64_RETIRE_ALLOC_PC_LSB +: `RV64_XLEN];
            wire [`RV64_XLEN-1:0] age_next_pc =
                age_result[WINDOW_RESULT_NEXT_PC +: `RV64_XLEN];
            wire [`RV64_INSTR_WIDTH-1:0] age_instr =
                age_meta[
                    `OPENRV64_RETIRE_ALLOC_INSTR_LSB +:
                    `RV64_INSTR_WIDTH];
            wire [`RV64_XLEN-1:0] age_fallthrough = age_pc + 64'd4;
            wire [`RV64_XLEN-1:0] age_target =
                age_pc + `RV64_IMM_B(age_instr);
            wire age_taken = age_next_pc != age_fallthrough;
            wire [`RV64_XLEN-1:0] age_loser =
                age_taken ? age_fallthrough : age_target;

            assign branch_retire_age_valid_o[retire_age_lane] =
                release_valid[retire_age_lane] &&
                age_meta[WINDOW_META_BRANCH] &&
                !age_result[WINDOW_RESULT_EXCEPTION] &&
                (age_target[`RV64_XLEN-1:6] !=
                 age_fallthrough[`RV64_XLEN-1:6]);
            assign branch_retire_age_addr_o[
                retire_age_lane*`RV64_XLEN +: `RV64_XLEN] = age_loser;
        end
    endgenerate

    wire free_branch_resolved = |allocation_complete;
    // Architectural completions may be multi-wide.  The existing predictor
    // update port observes the oldest branch; BTFNT itself is stateless.
    wire [1:0] free_branch_lane = allocation_complete[0] ? 2'd0 :
                                  allocation_complete[1] ? 2'd1 : 2'd2;
    wire [RETIRE_META_WIDTH-1:0] free_branch_meta =
        allocation_meta[
            free_branch_lane*RETIRE_META_WIDTH +:
            RETIRE_META_WIDTH];
    wire [`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH-1:0] free_branch_result =
        allocation_result[
            free_branch_lane*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +:
            `OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH];
    wire [`RV64_XLEN-1:0] free_branch_pc =
        free_branch_result[COMPLETE_RESULT_PC +: `RV64_XLEN];
    wire [`RV64_XLEN-1:0] free_branch_next_pc =
        free_branch_result[COMPLETE_RESULT_NEXT_PC +: `RV64_XLEN];
    wire free_branch_mispredict = |allocation_mispredict;
    wire [1:0] free_mispredict_lane = allocation_mispredict[0] ? 2'd0 :
                                      allocation_mispredict[1] ? 2'd1 : 2'd2;
    wire [`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH-1:0]
        free_mispredict_result = allocation_result[
            free_mispredict_lane*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +:
            `OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH];

    wire speculative_window = (ENABLE_ISSUE_WINDOW != 0) &&
                              (ENABLE_SPECULATION_WINDOW != 0);
    assign redirect_valid_o = free_branch_mispredict ? 1'b1 :
        speculative_window ? exec_redirect_valid :
        (ENABLE_ISSUE_WINDOW != 0) ? window_direction_mispredict :
                                     exec_redirect_valid;
    assign redirect_id_o = free_branch_mispredict ?
        allocation_id[
            free_mispredict_lane*`OPENRV64_INSTR_ID_WIDTH +:
            `OPENRV64_INSTR_ID_WIDTH] :
        speculative_window ? exec_redirect_id :
        (ENABLE_ISSUE_WINDOW != 0) ?
            queue_retire_id[
                window_resolve_lane*`OPENRV64_INSTR_ID_WIDTH +:
                `OPENRV64_INSTR_ID_WIDTH] : exec_redirect_id;
    assign redirect_target_o = free_branch_mispredict ?
        free_mispredict_result[COMPLETE_RESULT_NEXT_PC +: `RV64_XLEN] :
        speculative_window ? exec_redirect_target :
        (ENABLE_ISSUE_WINDOW != 0) ? window_branch_next_pc :
                                     exec_redirect_target;
    assign branch_resolved_o = free_branch_resolved ? 1'b1 :
        speculative_window ? exec_branch_resolved :
        (ENABLE_ISSUE_WINDOW != 0) ? window_branch_resolved :
                                     exec_branch_resolved;
    assign branch_conditional_o = free_branch_resolved ?
        free_branch_meta[WINDOW_META_BRANCH] :
        speculative_window ? exec_branch_conditional :
        (ENABLE_ISSUE_WINDOW != 0) ?
            window_resolve_meta[WINDOW_META_BRANCH] : exec_branch_conditional;
    assign branch_taken_o = free_branch_resolved ?
        (free_branch_next_pc != (free_branch_pc + 64'd4)) :
        speculative_window ? exec_branch_taken :
        (ENABLE_ISSUE_WINDOW != 0) ? window_branch_taken : exec_branch_taken;
    assign branch_pc_o = free_branch_resolved ? free_branch_pc :
        speculative_window ? exec_branch_pc :
        (ENABLE_ISSUE_WINDOW != 0) ? window_branch_pc : exec_branch_pc;
    assign branch_instr_o = free_branch_resolved ?
        free_branch_result[COMPLETE_RESULT_INSTR +: `RV64_INSTR_WIDTH] :
        speculative_window ? exec_branch_instr :
        (ENABLE_ISSUE_WINDOW != 0) ?
            window_resolve_meta[`OPENRV64_RETIRE_ALLOC_INSTR_LSB +:
                                  `RV64_INSTR_WIDTH] : exec_branch_instr;
    assign branch_id_o = free_branch_resolved ?
        allocation_id[
            free_branch_lane*`OPENRV64_INSTR_ID_WIDTH +:
            `OPENRV64_INSTR_ID_WIDTH] :
        speculative_window ? exec_redirect_id :
        (ENABLE_ISSUE_WINDOW != 0) ?
            queue_retire_id[
                window_resolve_lane*`OPENRV64_INSTR_ID_WIDTH +:
                `OPENRV64_INSTR_ID_WIDTH] : exec_redirect_id;
    assign branch_slot_o = free_branch_resolved ?
        allocation_slot[free_branch_lane*SLOT_WIDTH +: SLOT_WIDTH] :
        speculative_window ? exec_redirect_slot :
        (ENABLE_ISSUE_WINDOW != 0) ?
            window_retire_slot[window_resolve_lane*SLOT_WIDTH +: SLOT_WIDTH] :
            exec_redirect_slot;

    // Predictor training is independent of the scalar redirect/diagnostic
    // resolution above.  Free branches and retirement-window controls can
    // resolve three-wide; the selected policy serializes these updates before
    // writing its direction table.
    wire [2:0] window_train_valid = {
        window_resolve2, window_resolve1, window_resolve0};
    genvar train_lane;
    generate
        for (train_lane = 0; train_lane < 3;
             train_lane = train_lane + 1) begin : g_branch_train
            wire [RETIRE_META_WIDTH-1:0] train_alloc_meta =
                allocation_meta[
                    train_lane*RETIRE_META_WIDTH +:
                    RETIRE_META_WIDTH];
            wire [`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH-1:0]
                train_alloc_result = allocation_result[
                    train_lane*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +:
                    `OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH];
            wire [RETIRE_RECORD_WIDTH-1:0] train_window_meta =
                queue_retire_record[
                    train_lane*RETIRE_RECORD_WIDTH +:
                    RETIRE_RECORD_WIDTH];
            wire [RETIRE_RESULT_WIDTH-1:0]
                train_window_result = queue_retire_commit[
                    train_lane*RETIRE_RESULT_WIDTH +:
                    RETIRE_RESULT_WIDTH];
            wire [`RV64_XLEN-1:0] train_alloc_pc = train_alloc_result[
                COMPLETE_RESULT_PC +: `RV64_XLEN];
            wire [`RV64_XLEN-1:0] train_alloc_next_pc =
                train_alloc_result[COMPLETE_RESULT_NEXT_PC +: `RV64_XLEN];
            wire [`RV64_XLEN-1:0] train_window_pc = train_window_meta[
                `OPENRV64_RETIRE_ALLOC_PC_LSB +: `RV64_XLEN];
            wire [`RV64_XLEN-1:0] train_window_next_pc =
                train_window_result[WINDOW_RESULT_NEXT_PC +: `RV64_XLEN];

            assign branch_train_valid_o[train_lane] = free_branch_resolved ?
                allocation_complete[train_lane] :
                speculative_window ?
                    ((train_lane == 0) ? exec_branch_resolved : 1'b0) :
                (ENABLE_ISSUE_WINDOW != 0) ?
                    window_train_valid[train_lane] :
                    ((train_lane == 0) ? exec_branch_resolved : 1'b0);
            assign branch_train_conditional_o[train_lane] =
                free_branch_resolved ?
                    train_alloc_meta[WINDOW_META_BRANCH] :
                speculative_window ?
                    ((train_lane == 0) ? exec_branch_conditional : 1'b0) :
                (ENABLE_ISSUE_WINDOW != 0) ?
                    train_window_meta[WINDOW_META_BRANCH] :
                    ((train_lane == 0) ? exec_branch_conditional : 1'b0);
            assign branch_train_taken_o[train_lane] = free_branch_resolved ?
                (train_alloc_next_pc != (train_alloc_pc + 64'd4)) :
                speculative_window ?
                    ((train_lane == 0) ? exec_branch_taken : 1'b0) :
                (ENABLE_ISSUE_WINDOW != 0) ?
                    (train_window_next_pc != (train_window_pc + 64'd4)) :
                    ((train_lane == 0) ? exec_branch_taken : 1'b0);
            assign branch_train_pc_o[train_lane*`RV64_XLEN +: `RV64_XLEN] =
                free_branch_resolved ? train_alloc_pc :
                speculative_window ?
                    ((train_lane == 0) ? exec_branch_pc :
                                         {`RV64_XLEN{1'b0}}) :
                (ENABLE_ISSUE_WINDOW != 0) ? train_window_pc :
                    ((train_lane == 0) ? exec_branch_pc :
                                         {`RV64_XLEN{1'b0}});
        end
    endgenerate

    wire [RETIRE_DEPTH-1:0] completed_entry_valid;

    // Remember the youngest allocated producer of each architectural
    // register.  The compact retirement-slot tag qualifies the branch-only
    // live bypass.  RELAX_HAZARDS additionally uses the instruction ID,
    // ready bit, and retained data as its broad producer-result table.  This
    // is deliberately not a physical-register rename file: retirement is
    // still in order and the architectural GPR remains committed state.
    reg [31:0] youngest_owner_valid_q;
    reg [31:0] youngest_owner_ready_q;
    reg [32*`OPENRV64_INSTR_ID_WIDTH-1:0] youngest_owner_id_q;
    reg [32*SLOT_WIDTH-1:0] youngest_owner_slot_q;
    reg [32*`RV64_XLEN-1:0] youngest_owner_data_q;
    integer youngest_owner_lane;
    reg [`RV64_REG_ADDR_WIDTH-1:0] youngest_owner_rd;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            youngest_owner_valid_q <= 32'd0;
            youngest_owner_ready_q <= 32'd0;
        end else if (flush_i ||
                     ((ENABLE_ISSUE_WINDOW != 0) && squash_frontend_i)) begin
            youngest_owner_valid_q <= 32'd0;
            youngest_owner_ready_q <= 32'd0;
        end else begin
            // Retirement clears ownership only when the retiring instruction's
            // live queue slot is still the youngest writer.  An older WAW
            // retirement leaves a younger live producer untouched.
            for (youngest_owner_lane = 0; youngest_owner_lane < 3;
                 youngest_owner_lane = youngest_owner_lane + 1) begin
                youngest_owner_rd = release_rd_addr[
                    youngest_owner_lane*`RV64_REG_ADDR_WIDTH +:
                    `RV64_REG_ADDR_WIDTH];
                if (release_valid[youngest_owner_lane] &&
                    release_reg_write[youngest_owner_lane] &&
                    (youngest_owner_rd != `RV64_REG_X0) &&
                    youngest_owner_valid_q[youngest_owner_rd] &&
                    (youngest_owner_slot_q[
                         youngest_owner_rd*SLOT_WIDTH +: SLOT_WIDTH] ==
                     window_retire_slot[
                         youngest_owner_lane*SLOT_WIDTH +: SLOT_WIDTH])) begin
                    youngest_owner_valid_q[youngest_owner_rd] <= 1'b0;
                    youngest_owner_ready_q[youngest_owner_rd] <= 1'b0;
                end
            end

            // A completion publishes only if it belongs to the youngest live
            // producer.  Stale completions from older WAW writers are ignored.
            for (youngest_owner_lane = 0; youngest_owner_lane < 3;
                 youngest_owner_lane = youngest_owner_lane + 1) begin
                youngest_owner_rd = complete_payload[
                    youngest_owner_lane*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +
                    `OPENRV64_COMPLETE_RD_LSB +: `RV64_REG_ADDR_WIDTH];
                if (complete_valid[youngest_owner_lane] &&
                    complete_payload[
                        youngest_owner_lane*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +
                        `OPENRV64_COMPLETE_REG_WRITE_BIT] &&
                    !complete_payload[
                        youngest_owner_lane*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +
                        `OPENRV64_COMPLETE_ILLEGAL_BIT] &&
                    !complete_payload[
                        youngest_owner_lane*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +
                        `OPENRV64_COMPLETE_EXCEPTION_BIT] &&
                    (youngest_owner_rd != `RV64_REG_X0) &&
                    youngest_owner_valid_q[youngest_owner_rd] &&
                    (youngest_owner_id_q[
                         youngest_owner_rd*`OPENRV64_INSTR_ID_WIDTH +:
                         `OPENRV64_INSTR_ID_WIDTH] ==
                     complete_id[
                         youngest_owner_lane*`OPENRV64_INSTR_ID_WIDTH +:
                         `OPENRV64_INSTR_ID_WIDTH])) begin
                    youngest_owner_ready_q[youngest_owner_rd] <= 1'b1;
                    youngest_owner_data_q[
                        youngest_owner_rd*`RV64_XLEN +: `RV64_XLEN] <=
                        complete_payload[
                            youngest_owner_lane*
                            `OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +
                            `OPENRV64_COMPLETE_DATA_LSB +: `RV64_XLEN];
                end
            end

            // Allocation is ordered youngest-last, so later lanes naturally
            // win if several instructions in one issue group write the same rd.
            for (youngest_owner_lane = 0; youngest_owner_lane < 3;
                 youngest_owner_lane = youngest_owner_lane + 1) begin
                youngest_owner_rd = allocation_meta[
                    youngest_owner_lane*RETIRE_META_WIDTH +
                    35 +: `RV64_REG_ADDR_WIDTH];
                if (allocation_valid[youngest_owner_lane] &&
                    allocation_meta[
                        youngest_owner_lane*RETIRE_META_WIDTH + 17] &&
                    (youngest_owner_rd != `RV64_REG_X0)) begin
                    youngest_owner_valid_q[youngest_owner_rd] <= 1'b1;
                    youngest_owner_ready_q[youngest_owner_rd] <= 1'b0;
                    youngest_owner_id_q[
                        youngest_owner_rd*`OPENRV64_INSTR_ID_WIDTH +:
                        `OPENRV64_INSTR_ID_WIDTH] <= allocation_id[
                            youngest_owner_lane*
                            `OPENRV64_INSTR_ID_WIDTH +:
                            `OPENRV64_INSTR_ID_WIDTH];
                    youngest_owner_slot_q[
                        youngest_owner_rd*SLOT_WIDTH +: SLOT_WIDTH] <=
                        allocation_slot[
                            youngest_owner_lane*SLOT_WIDTH +: SLOT_WIDTH];
                end
            end

            youngest_owner_valid_q[`RV64_REG_X0] <= 1'b0;
            youngest_owner_ready_q[`RV64_REG_X0] <= 1'b0;
        end
    end

    // Dispatch receives only enough metadata to route a dependent instruction
    // back to the completing ALU pipe.  The 64-bit values stay local to EX0 and
    // EX1 and feed their operand muxes directly.
    wire [1:0] local_forward_valid;
    wire [2*`RV64_REG_ADDR_WIDTH-1:0] local_forward_rd_addr;
    assign local_forward_valid[0] = complete_valid[0] &&
        complete_payload[0*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +
                         `OPENRV64_COMPLETE_REG_WRITE_BIT] &&
        !complete_payload[0*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +
                          `OPENRV64_COMPLETE_ILLEGAL_BIT] &&
        !complete_payload[0*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +
                          `OPENRV64_COMPLETE_EXCEPTION_BIT] &&
        (complete_payload[0*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +
                          `OPENRV64_COMPLETE_RD_LSB +:
                          `RV64_REG_ADDR_WIDTH] != `RV64_REG_X0);
    assign local_forward_valid[1] = complete_valid[1] &&
        complete_payload[1*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +
                         `OPENRV64_COMPLETE_REG_WRITE_BIT] &&
        !complete_payload[1*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +
                          `OPENRV64_COMPLETE_ILLEGAL_BIT] &&
        !complete_payload[1*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +
                          `OPENRV64_COMPLETE_EXCEPTION_BIT] &&
        (complete_payload[1*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +
                          `OPENRV64_COMPLETE_RD_LSB +:
                          `RV64_REG_ADDR_WIDTH] != `RV64_REG_X0);
    assign local_forward_rd_addr[0*`RV64_REG_ADDR_WIDTH +:
                                 `RV64_REG_ADDR_WIDTH] =
        complete_payload[0*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +
                         `OPENRV64_COMPLETE_RD_LSB +:
                         `RV64_REG_ADDR_WIDTH];
    assign local_forward_rd_addr[1*`RV64_REG_ADDR_WIDTH +:
                                 `RV64_REG_ADDR_WIDTH] =
        complete_payload[1*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +
                         `OPENRV64_COMPLETE_RD_LSB +:
                         `RV64_REG_ADDR_WIDTH];

    // Limited forwarding option: only values physically present on this
    // cycle's registered completion ports may bypass.  The source mask makes
    // MEM-only (3'b100), ALU-only (3'b011), and all-live-port (3'b111)
    // experiments possible without retaining any retirement-queue result.
    // This is three tagged 64-bit sources, not the 32-register completion map
    // used by the full-forwarding upper bound below.
    wire [2:0] completion_forward_valid_raw;
    wire [3*`RV64_REG_ADDR_WIDTH-1:0] completion_forward_rd_addr;
    wire [3*`RV64_XLEN-1:0] completion_forward_data;
    genvar completion_forward_lane;
    generate
        for (completion_forward_lane = 0; completion_forward_lane < 3;
             completion_forward_lane = completion_forward_lane + 1) begin :
                g_completion_forward
            assign completion_forward_valid_raw[completion_forward_lane] =
                complete_valid[completion_forward_lane] &&
                complete_payload[
                    completion_forward_lane*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +
                    `OPENRV64_COMPLETE_REG_WRITE_BIT] &&
                !complete_payload[
                    completion_forward_lane*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +
                    `OPENRV64_COMPLETE_ILLEGAL_BIT] &&
                !complete_payload[
                    completion_forward_lane*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +
                    `OPENRV64_COMPLETE_EXCEPTION_BIT] &&
                (complete_payload[
                    completion_forward_lane*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +
                    `OPENRV64_COMPLETE_RD_LSB +: `RV64_REG_ADDR_WIDTH] !=
                 `RV64_REG_X0);
            assign completion_forward_rd_addr[
                completion_forward_lane*`RV64_REG_ADDR_WIDTH +:
                `RV64_REG_ADDR_WIDTH] = complete_payload[
                    completion_forward_lane*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +
                    `OPENRV64_COMPLETE_RD_LSB +: `RV64_REG_ADDR_WIDTH];
            assign completion_forward_data[
                completion_forward_lane*`RV64_XLEN +: `RV64_XLEN] =
                complete_payload[
                    completion_forward_lane*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +
                    `OPENRV64_COMPLETE_DATA_LSB +: `RV64_XLEN];
        end
    endgenerate
    wire [2:0] completion_forward_valid = !flush_i ?
        (completion_forward_valid_raw & COMPLETION_FORWARD_MASK) : 3'b000;

    // Cheap branch-only bypass.  Retain the youngest-owner check as the
    // qualification used by strict dispatch, whose same-cycle forwarding is
    // still architectural-register based.  The issue-window path additionally
    // carries the exact source-producer ID to EX1; that identity check rejects
    // a younger WAW completion even when this coarse owner check accepts it.
    wire [2:0] branch_completion_forward_valid;
    genvar branch_forward_lane;
    generate
        for (branch_forward_lane = 0; branch_forward_lane < 3;
             branch_forward_lane = branch_forward_lane + 1) begin :
                g_branch_completion_forward
            wire [`RV64_REG_ADDR_WIDTH-1:0] branch_forward_rd =
                completion_forward_rd_addr[
                    branch_forward_lane*`RV64_REG_ADDR_WIDTH +:
                    `RV64_REG_ADDR_WIDTH];
            assign branch_completion_forward_valid[branch_forward_lane] =
                !flush_i &&
                BRANCH_COMPLETION_FORWARD_MASK[branch_forward_lane] &&
                completion_forward_valid_raw[branch_forward_lane] &&
                youngest_owner_valid_q[branch_forward_rd] &&
                (youngest_owner_slot_q[
                     branch_forward_rd*SLOT_WIDTH +: SLOT_WIDTH] ==
                 complete_slot[
                     branch_forward_lane*SLOT_WIDTH +: SLOT_WIDTH]);
        end
    endgenerate

    // The producer-tagged table is the canonical forwarding store.  Retaining
    // one value per architectural destination avoids the old depth-wide scan
    // of every 457-bit retirement result.  The live completion overlay removes
    // the state-update cycle and exact instruction IDs reject stale WAW data.
    reg [31:0] youngest_forward_valid_raw;
    reg [32*`RV64_XLEN-1:0] youngest_forward_data_raw;
    reg [`RV64_REG_ADDR_WIDTH-1:0] youngest_forward_rd;
    integer youngest_forward_port;
    always @* begin
        youngest_forward_valid_raw =
            youngest_owner_valid_q & youngest_owner_ready_q;
        youngest_forward_data_raw = youngest_owner_data_q;
        youngest_forward_rd = `RV64_REG_X0;

        for (youngest_forward_port = 0; youngest_forward_port < 3;
             youngest_forward_port = youngest_forward_port + 1) begin
            youngest_forward_rd = complete_payload[
                youngest_forward_port*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +
                `OPENRV64_COMPLETE_RD_LSB +: `RV64_REG_ADDR_WIDTH];
            if (complete_valid[youngest_forward_port] &&
                complete_payload[
                    youngest_forward_port*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +
                    `OPENRV64_COMPLETE_REG_WRITE_BIT] &&
                !complete_payload[
                    youngest_forward_port*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +
                    `OPENRV64_COMPLETE_ILLEGAL_BIT] &&
                !complete_payload[
                    youngest_forward_port*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +
                    `OPENRV64_COMPLETE_EXCEPTION_BIT] &&
                (youngest_forward_rd != `RV64_REG_X0) &&
                youngest_owner_valid_q[youngest_forward_rd] &&
                (youngest_owner_id_q[
                     youngest_forward_rd*`OPENRV64_INSTR_ID_WIDTH +:
                     `OPENRV64_INSTR_ID_WIDTH] ==
                 complete_id[
                     youngest_forward_port*`OPENRV64_INSTR_ID_WIDTH +:
                     `OPENRV64_INSTR_ID_WIDTH])) begin
                youngest_forward_valid_raw[youngest_forward_rd] = 1'b1;
                youngest_forward_data_raw[
                    youngest_forward_rd*`RV64_XLEN +: `RV64_XLEN] =
                    complete_payload[
                        youngest_forward_port*
                        `OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +
                        `OPENRV64_COMPLETE_DATA_LSB +: `RV64_XLEN];
            end
        end
        youngest_forward_valid_raw[`RV64_REG_X0] = 1'b0;
    end

    wire [31:0] full_forward_valid =
        (ENABLE_FULL_FORWARDING != 0) && !flush_i ?
        youngest_forward_valid_raw : 32'd0;
    wire [32*`RV64_XLEN-1:0] full_forward_data =
        (ENABLE_FULL_FORWARDING != 0) && !flush_i ?
        youngest_forward_data_raw :
        {32*`RV64_XLEN{1'b0}};

    // Deliberately conservative capacity gate: issue resumes with room for a
    // complete three-entry group.  This breaks the alloc-valid/ready loop and
    // leaves exact-width admission as a later timing optimization.
    // Occupancy <= DEPTH-3 proves room for the largest possible group, so
    // consulting the queue's alloc-count-dependent ready here is redundant
    // and would recreate an alloc_valid <-> alloc_ready combinational loop.
    assign allocation_ready = (retire_occupancy_o <= RETIRE_DEPTH - 3);

    openrv64_dispatch #(
        .BACKEND_CONFIG(`OPENRV64_BACKEND_3P),
        .QUEUE_DEPTH_3P(DISPATCH_DEPTH),
        .RETIRE_SLOT_WIDTH_3P(SLOT_WIDTH),
        .MAX_READS_PER_REG_3P(MAX_READS_PER_REG),
        .RELAX_WAW_3P(RELAX_WAW),
        .RELAX_HAZARDS_3P(RELAX_HAZARDS),
        .FREE_BRANCHES_3P(FREE_BRANCHES),
        .ENABLE_EQ_BRANCH_PAIRING_3P(ENABLE_EQ_BRANCH_PAIRING),
        .ENABLE_ISSUE_WINDOW_3P(ENABLE_ISSUE_WINDOW),
        .ENABLE_SPECULATION_WINDOW_3P(ENABLE_SPECULATION_WINDOW),
        .ISSUE_WINDOW_DEPTH_3P(ISSUE_WINDOW_DEPTH),
        .SPEC_LOAD_BASE_3P(SPEC_LOAD_BASE),
        .SPEC_LOAD_SIZE_3P(SPEC_LOAD_SIZE),
        .PHYS_REG_COUNT_3P(PHYS_REG_COUNT),
        .PHYS_REG_ADDR_WIDTH_3P(PHYS_REG_ADDR_WIDTH),
        .RETIRE_META_WIDTH_3P(RETIRE_META_WIDTH),
        .COUNT_WIDTH_3P(DISPATCH_COUNT_WIDTH)
    ) u_dispatch (
        .clk(clk), .rst_n(rst_n), .flush_i(flush_i),
        .decode_valid_i(1'b0), .decode_pc_i(64'd0),
        .decode_instr_i(32'd0), .decode_imm_i(64'd0),
        .decode_uses_rs1_i(1'b0), .decode_uses_rs2_i(1'b0),
        .decode_rs1_addr_i(5'd0), .decode_rs2_addr_i(5'd0),
        .decode_rd_addr_i(5'd0),
        .decode_alu_ext_i({`RV64_ALU_EXT_WIDTH{1'b0}}),
        .decode_alu_op_i({`RV64_ALU_OP_WIDTH{1'b0}}),
        .decode_lsu_op_i({`RV64_LSU_OP_WIDTH{1'b0}}),
        .decode_br_op_i({`RV64_BR_OP_WIDTH{1'b0}}),
        .decode_reg_write_i(1'b0), .decode_mem_read_i(1'b0),
        .decode_mem_write_i(1'b0), .decode_branch_i(1'b0),
        .decode_jump_i(1'b0), .decode_predicted_taken_i(1'b0),
        .decode_word_op_i(1'b0), .decode_system_i(1'b0),
        .decode_fence_i(1'b0), .decode_illegal_i(1'b0),
        .decode_ebreak_i(1'b0), .decode_ecall_i(1'b0),
        .decode_instr_fault_i(1'b0),
        .decode_instr_page_fault_i(1'b0),
        .exec_clear_i(1'b0), .exec_alu_ready_i(1'b0),
        .exec_lsu_ready_i(1'b0), .exec_br_ready_i(1'b0),
        .exec_system_ready_i(1'b0), .forward_ex_valid_i(1'b0),
        .forward_ex_rd_addr_i(5'd0), .forward_mem_valid_i(1'b0),
        .forward_mem_rd_addr_i(5'd0),
        .retire_valid_i(1'b0), .retire_csr_i(1'b0),
        .retire_fence_i(1'b0), .retire_uses_rs1_i(1'b0),
        .retire_uses_rs2_i(1'b0), .retire_rs1_addr_i(5'd0),
        .retire_rs2_addr_i(5'd0), .retire_reg_write_i(1'b0),
        .retire_rd_addr_i(5'd0), .decode_trace_id_i(64'd0),
        .squash_frontend_3p_i(squash_frontend_i),
        .squash_id_3p_i(exec_redirect_id),
        .decode_valid_3p_i(decode_valid_i),
        .decode_ready_3p_o(decode_ready_o),
        .decode_payload_3p_i(decode_payload_i),
        .decode_uses_rs1_3p_i(decode_uses_rs1_i),
        .decode_uses_rs2_3p_i(decode_uses_rs2_i),
        .gpr_read_addr_3p_o(gpr_read_addr),
        .gpr_read_data_3p_i(gpr_read_data),
        .allocation_ready_3p_i(allocation_ready),
        .allocation_id_3p_i(allocation_id),
        .allocation_slot_3p_i(allocation_slot),
        .allocation_valid_3p_o(allocation_valid),
        .allocation_meta_3p_o(allocation_meta),
        .pipe_ready_3p_i(pipe_ready),
        .forward_valid_3p_i(local_forward_valid),
        .forward_rd_addr_3p_i(local_forward_rd_addr),
        .completion_forward_valid_3p_i(completion_forward_valid),
        .completion_forward_rd_addr_3p_i(completion_forward_rd_addr),
        .completion_forward_data_3p_i(completion_forward_data),
        .branch_completion_forward_valid_3p_i(
            branch_completion_forward_valid),
        .forward_map_valid_3p_i(full_forward_valid),
        .forward_map_data_3p_i(full_forward_data),
        .completion_valid_3p_i(complete_valid),
        .completion_id_3p_i(complete_id),
        .completion_payload_3p_i(complete_payload),
        .pipe_valid_3p_o(pipe_valid),
        .pipe_id_3p_o(pipe_id), .pipe_slot_3p_o(pipe_slot),
        .pipe_payload_3p_o(pipe_payload),
        .pipe_src1_producer_valid_3p_o(pipe_src1_producer_valid),
        .pipe_src1_producer_id_3p_o(pipe_src1_producer_id),
        .pipe_src2_producer_valid_3p_o(pipe_src2_producer_valid),
        .pipe_src2_producer_id_3p_o(pipe_src2_producer_id),
        .retire_valid_3p_i(release_valid),
        .retire_id_3p_i(queue_retire_id),
        .retire_slot_3p_i(window_retire_slot),
        .retire_uses_rs1_3p_i(release_uses_rs1),
        .retire_uses_rs2_3p_i(release_uses_rs2),
        .retire_rs1_addr_3p_i(release_rs1_addr),
        .retire_rs2_addr_3p_i(release_rs2_addr),
        .retire_reg_write_3p_i(release_reg_write),
        .retire_rd_addr_3p_i(release_rd_addr),
        .retire_hard_3p_i(retire_hard),
        .next_retire_id_3p_i(next_retire_id),
        .next_retire_slot_3p_i(next_retire_slot),
        .barrier_active_3p_o(barrier_active_o),
        .raw_hazard_3p_o(raw_hazard), .waw_hazard_3p_o(waw_hazard),
        .read_port_hazard_3p_o(read_port_hazard),
        .write_busy_3p_o(write_busy_o),
        .queue_count_3p_o(dispatch_occupancy_o)
    );

    openrv64_rv64i_gpr_3p #(
        .ALLOW_DUPLICATE_WRITES(RELAX_WAW),
        .NUM_REGS(PHYS_REG_COUNT),
        .REG_ADDR_WIDTH(PHYS_REG_ADDR_WIDTH)
    ) u_gpr (
        .clk(clk), .rst_n(rst_n),
        .read_addr_i(gpr_read_addr), .read_data_o(gpr_read_data),
        .write_valid_i(gpr_write), .write_addr_i(gpr_write_addr),
        .write_data_i(gpr_write_data)
    );

    // The queue supplies the three contiguous head selectors directly.  The
    // GPR bank has same-edge retirement bypass, so dependent work may still
    // issue beside the older retiring prefix.
    wire ordered_head_valid = !flush_i &&
        (queue_post_retire_valid || (dispatch_occupancy_o != 0));
    wire [`OPENRV64_INSTR_ID_WIDTH-1:0] ordered_head_id =
        queue_post_retire_valid ? queue_post_retire_id :
        allocation_id[0 +: `OPENRV64_INSTR_ID_WIDTH];
    wire [SLOT_WIDTH-1:0] ordered_head_slot = queue_post_retire_valid ?
        queue_post_retire_slot : allocation_slot[0 +: SLOT_WIDTH];

    openrv64_exec_top #(
        .BACKEND_CONFIG(`OPENRV64_BACKEND_3P),
        .RETIRE_SLOT_WIDTH_3P(SLOT_WIDTH), .ENABLE_RV64M(ENABLE_RV64M),
        .ENABLE_LOCAL_FORWARDING_3P(ENABLE_ISSUE_WINDOW == 0),
        .ENABLE_POSTED_STORES(ENABLE_POSTED_STORES),
        .STORE_QUEUE_DEPTH_3P(STORE_QUEUE_DEPTH),
        .ENABLE_COHERENT_ATOMICS_3P(ENABLE_COHERENT_ATOMICS),
        .STORE_FORWARD_BASE(STORE_FORWARD_BASE),
        .STORE_FORWARD_SIZE(STORE_FORWARD_SIZE),
        .CACHEABLE_BASE_3P(CACHEABLE_BASE),
        .CACHEABLE_SIZE_3P(CACHEABLE_SIZE)
    ) u_exec (
        .clk(clk), .rst_n(rst_n),
        // Selective speculation recovery leaves already-issued operations in
        // flight.  Their bounded-lifetime modular IDs cannot match reallocated
        // retirement entries, while the resolving EX1 branch must still
        // publish its own completion on the following cycle.
        .flush_3p_i(flush_i ||
                    ((ENABLE_ISSUE_WINDOW != 0) &&
                     (ENABLE_SPECULATION_WINDOW == 0) &&
                     squash_frontend_i)),
        .squash_younger_3p_i(speculative_window && squash_frontend_i),
        .squash_id_3p_i(exec_redirect_id),
        .coherent_reservation_clear_3p_i(
            coherent_reservation_clear_i),
        .translation_bypass_3p_i(translation_bypass_i),
        .valid_i(1'b0), .flush_ex_mem_i(1'b0),
        .flush_mem_wb_i(1'b0), .pc_i(64'd0), .instr_i(32'd0),
        .rs1_addr_i(5'd0), .rs2_addr_i(5'd0), .rs1_data_i(64'd0),
        .rs2_data_i(64'd0), .imm_i(64'd0), .rd_addr_i(5'd0),
        .alu_ext_i({`RV64_ALU_EXT_WIDTH{1'b0}}),
        .alu_op_i({`RV64_ALU_OP_WIDTH{1'b0}}),
        .lsu_op_i({`RV64_LSU_OP_WIDTH{1'b0}}),
        .br_op_i({`RV64_BR_OP_WIDTH{1'b0}}),
        .reg_write_i(1'b0), .mem_read_i(1'b0), .mem_write_i(1'b0),
        .branch_i(1'b0), .jump_i(1'b0), .predicted_taken_i(1'b0),
        .word_op_i(1'b0), .system_i(1'b0), .fence_i(1'b0),
        .illegal_i(1'b0), .ebreak_i(1'b0), .ecall_i(1'b0),
        .instr_access_fault_i(1'b0), .instr_page_fault_i(1'b0),
        .priv_mode_i({`RV64_PRIV_WIDTH{1'b0}}),
        .sret_allowed_i(1'b0), .sfence_vma_allowed_i(1'b0),
        .wb_clear_i(1'b0), .trace_id_i(64'd0),
        .issue_valid_3p_i(pipe_valid), .issue_ready_3p_o(pipe_ready),
        .issue_unsupported_3p_o(pipe_unsupported),
        .issue_id_3p_i(pipe_id), .issue_slot_3p_i(pipe_slot),
        .issue_payload_3p_i(pipe_payload),
        .branch_forward_valid_3p_i(
            branch_completion_forward_valid[0]),
        .branch_forward_id_3p_i(
            complete_id[0 +: `OPENRV64_INSTR_ID_WIDTH]),
        .branch_forward_rd_addr_3p_i(
            completion_forward_rd_addr[0 +: `RV64_REG_ADDR_WIDTH]),
        .branch_forward_data_3p_i(
            completion_forward_data[0 +: `RV64_XLEN]),
        .issue_src1_producer_valid_3p_i(pipe_src1_producer_valid),
        .issue_src1_producer_id_3p_i(pipe_src1_producer_id),
        .issue_src2_producer_valid_3p_i(pipe_src2_producer_valid),
        .issue_src2_producer_id_3p_i(pipe_src2_producer_id),
        .ordered_head_valid_3p_i(ordered_head_valid),
        .ordered_head_id_3p_i(ordered_head_id),
        .ordered_head_slot_3p_i(ordered_head_slot),
        .complete_valid_3p_o(complete_valid),
        .complete_ready_3p_i(3'b111),
        .complete_id_3p_o(complete_id),
        .complete_slot_3p_o(complete_slot),
        .complete_payload_3p_o(complete_payload),
        .async_store_fault_3p_o(async_store_fault),
        .async_store_page_fault_3p_o(async_store_page_fault),
        .async_store_fault_pc_3p_o(async_store_fault_pc),
        .async_store_fault_addr_3p_o(async_store_fault_addr),
        .async_store_fault_trace_3p_o(async_store_fault_trace),
        .async_store_fault_instr_3p_o(async_store_fault_instr),
        .redirect_valid_o(exec_redirect_valid),
        .redirect_id_3p_o(exec_redirect_id),
        .redirect_slot_3p_o(exec_redirect_slot),
        .redirect_target_o(exec_redirect_target),
        .branch_resolved_o(exec_branch_resolved),
        .branch_conditional_o(exec_branch_conditional),
        .branch_taken_o(exec_branch_taken),
        .branch_pc_o(exec_branch_pc),
        .branch_instr_o(exec_branch_instr),
        .csr_addr_o(csr_addr_o), .csr_rdata_i(csr_rdata_i),
        .csr_valid_i(csr_valid_i), .csr_writable_i(csr_writable_i),
        .mem_valid_o(mem_valid_o), .mem_ready_i(mem_ready_i),
        .mem_tag_o(mem_tag_o), .mem_resp_valid_i(mem_resp_valid_i),
        .mem_xlate_only_o(mem_xlate_only_o),
        .mem_physical_o(mem_physical_o),
        .mem_resp_ready_o(mem_resp_ready_o),
        .mem_resp_tag_i(mem_resp_tag_i),
        .mem_store_done_valid_i(mem_store_done_valid_i),
        .mem_store_done_ready_o(mem_store_done_ready_o),
        .mem_store_done_tag_i(mem_store_done_tag_i),
        .mem_resp_paddr_i(mem_resp_paddr_i),
        .mem_error_i(mem_error_i), .mem_page_fault_i(mem_page_fault_i),
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
        .mem_xlate_resp_access_fault_i(mem_xlate_resp_access_fault_i),
        .mem_xlate_resp_page_fault_i(mem_xlate_resp_page_fault_i),
        .mem_rdata_i(mem_rdata_i),
        .mem1_valid_o(mem1_valid_o), .mem1_ready_i(mem1_ready_i),
        .mem1_tag_o(mem1_tag_o), .mem1_lock_o(mem1_lock_o),
        .mem1_write_o(mem1_write_o), .mem1_addr_o(mem1_addr_o),
        .mem1_wdata_o(mem1_wdata_o), .mem1_wstrb_o(mem1_wstrb_o),
        .mem1_access_o(mem1_access_o),
        .mem1_effective_addr_o(mem1_effective_addr_o),
        .mem1_size_o(mem1_size_o)
    );

    openrv64_retire_queue_3p #(
        .DEPTH(RETIRE_DEPTH),
        .ID_WIDTH(`OPENRV64_INSTR_ID_WIDTH),
        .INDEX_WIDTH(SLOT_WIDTH)
    ) u_retire_queue (
        .clk(clk), .rst_n(rst_n),
        .flush_i(flush_i ||
                 ((ENABLE_ISSUE_WINDOW != 0) &&
                  (ENABLE_SPECULATION_WINDOW == 0) &&
                  squash_frontend_i)),
        .squash_younger_i(speculative_window && squash_frontend_i),
        .squash_id_i(exec_redirect_id),
        .squash_slot_i(exec_redirect_slot),
        .alloc_valid_i(allocation_valid),
        .alloc_ready_o(queue_allocation_ready),
        .alloc_accept_o(queue_alloc_accept),
        .alloc_complete_i(allocation_complete),
        .alloc_id_o(allocation_id),
        .alloc_slot_o(allocation_slot),
        .complete_valid_i(complete_valid), .complete_id_i(complete_id),
        .complete_slot_i(complete_slot),
        .complete_accept_o(queue_complete_accept),
        .retire_valid_o(queue_retire_valid),
        .retire_accept_i(queue_retire_accept),
        .retire_id_o(queue_retire_id),
        .retire_slot_o(queue_retire_slot),
        .completed_entry_valid_o(completed_entry_valid),
        .occupancy_o(retire_occupancy_o),
        .next_retire_id_o(next_retire_id),
        .next_retire_slot_o(next_retire_slot),
        .post_retire_valid_o(queue_post_retire_valid),
        .post_retire_id_o(queue_post_retire_id),
        .post_retire_slot_o(queue_post_retire_slot)
    );

    openrv64_retire_records_3p #(
        .DEPTH(RETIRE_DEPTH),
        .SLOT_WIDTH(SLOT_WIDTH),
        .ALLOC_WIDTH(RETIRE_RECORD_WIDTH),
        .RESULT_WIDTH(RETIRE_RESULT_WIDTH),
        .ENABLE_TRACE(ENABLE_TRACE)
    ) u_retire_records (
        .clk(clk),
        .alloc_valid_i(queue_alloc_accept),
        .alloc_slot_i(allocation_slot),
        .alloc_record_i(allocation_record),
        .alloc_complete_i(allocation_complete),
        .alloc_result_i(allocation_retire_result),
        .alloc_trace_i(allocation_trace),
        .complete_valid_i(queue_complete_accept),
        .complete_slot_i(complete_slot),
        .complete_result_i(complete_retire_result),
        .read_slot_i(queue_retire_slot),
        .read_record_o(queue_retire_record),
        .read_result_o(queue_retire_commit),
        .read_trace_o(queue_retire_trace)
    );

`ifndef SYNTHESIS
    // Simulation-only compatibility view for system benches and trace tools
    // that inspect the historical completion packet.  This is reconstructed
    // from the canonical record selected for each retire lane; no copy of this
    // 457-bit packet exists in synthesized retirement storage.
    wire [3*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH-1:0]
        queue_retire_result;
    genvar debug_retire_lane;
    generate
        for (debug_retire_lane = 0; debug_retire_lane < 3;
             debug_retire_lane = debug_retire_lane + 1) begin :
                g_debug_retire_result
            reg [`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH-1:0]
                debug_result;
            always @* begin
                debug_result =
                    {`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH{1'b0}};
                debug_result[0 +: 153] = queue_retire_commit[
                    debug_retire_lane*RETIRE_RESULT_WIDTH +: 153];
                debug_result[153] = queue_retire_record[
                    debug_retire_lane*RETIRE_RECORD_WIDTH +
                    `OPENRV64_RETIRE_ALLOC_REG_WRITE_BIT];
                debug_result[154 +: `RV64_REG_ADDR_WIDTH] =
                    queue_retire_record[
                        debug_retire_lane*RETIRE_RECORD_WIDTH +
                        `OPENRV64_RETIRE_ALLOC_RD_LSB +:
                        `RV64_REG_ADDR_WIDTH];
                debug_result[159 +: `RV64_REG_ADDR_WIDTH] =
                    queue_retire_record[
                        debug_retire_lane*RETIRE_RECORD_WIDTH +
                        `OPENRV64_RETIRE_ALLOC_RS2_LSB +:
                        `RV64_REG_ADDR_WIDTH];
                debug_result[164 +: `RV64_REG_ADDR_WIDTH] =
                    queue_retire_record[
                        debug_retire_lane*RETIRE_RECORD_WIDTH +
                        `OPENRV64_RETIRE_ALLOC_RS1_LSB +:
                        `RV64_REG_ADDR_WIDTH];
                debug_result[169 +: `RV64_XLEN] = queue_retire_commit[
                    debug_retire_lane*RETIRE_RESULT_WIDTH +
                    `OPENRV64_RETIRE_RESULT_DATA_LSB +: `RV64_XLEN];
                debug_result[233 +: `RV64_INSTR_WIDTH] =
                    queue_retire_record[
                        debug_retire_lane*RETIRE_RECORD_WIDTH +
                        `OPENRV64_RETIRE_ALLOC_INSTR_LSB +:
                        `RV64_INSTR_WIDTH];
                debug_result[265 +: `RV64_XLEN] = queue_retire_commit[
                    debug_retire_lane*RETIRE_RESULT_WIDTH +
                    `OPENRV64_RETIRE_RESULT_NEXT_PC_LSB +: `RV64_XLEN];
                debug_result[329 +: `RV64_XLEN] = queue_retire_record[
                    debug_retire_lane*RETIRE_RECORD_WIDTH +
                    `OPENRV64_RETIRE_ALLOC_PC_LSB +: `RV64_XLEN];
                debug_result[393 +: 64] = queue_retire_trace[
                    debug_retire_lane*64 +: 64];
            end
            assign queue_retire_result[
                debug_retire_lane*
                `OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +:
                `OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH] = debug_result;
        end
    endgenerate
`endif

    // A delayed store failure is delivered alone at an architectural
    // boundary.  Holding the normal retirement inputs for this cycle avoids
    // consuming a precise exception or hard-order operation underneath the
    // imprecise abort.
    wire [2:0] retire_queue_valid = async_store_fault_pending_q ?
                                    3'b000 : queue_retire_valid;
    openrv64_retire_3p #(
        .PHYS_REG_COUNT(PHYS_REG_COUNT),
        .PHYS_REG_ADDR_WIDTH(PHYS_REG_ADDR_WIDTH),
        .META_WIDTH(RETIRE_RECORD_WIDTH),
        .RESULT_WIDTH(RETIRE_RESULT_WIDTH)
    ) u_retire (
        .queue_valid_i(retire_queue_valid),
        .queue_meta_i(queue_retire_record),
        .queue_result_i(queue_retire_commit),
        .queue_trace_id_i(queue_retire_trace),
        .queue_accept_o(queue_retire_accept),
        .irq_pending_i(irq_pending_i), .irq_cause_i(irq_cause_i),
        .retire_arch_o(retire_arch_o), .retire_count_o(retire_count_o),
        .retire_hard_o(retire_hard),
        .release_valid_o(release_valid),
        .release_uses_rs1_o(release_uses_rs1),
        .release_uses_rs2_o(release_uses_rs2),
        .release_rs1_addr_o(release_rs1_addr),
        .release_rs2_addr_o(release_rs2_addr),
        .release_reg_write_o(release_reg_write),
        .release_rd_addr_o(release_rd_addr),
        .gpr_write_o(gpr_write), .gpr_rd_addr_o(gpr_write_addr),
        .gpr_rd_data_o(gpr_write_data),
        .csr_write_o(csr_write_o), .csr_addr_o(csr_write_addr_o),
        .csr_wdata_o(csr_wdata_o),
        .exception_o(retire_exception), .halt_o(retire_halt),
        .irq_o(retire_irq), .mret_o(retire_mret), .sret_o(retire_sret),
        .fence_i_o(retire_fence_i), .sfence_vma_o(retire_sfence_vma),
        .cause_o(retire_cause), .pc_o(retire_pc),
        .next_pc_o(retire_next_pc), .tval_o(retire_tval),
        .trace_id_o(retire_trace_id), .instr_o(retire_instr),
        .trace_rd_o(retire_rd_o),
        .trace_wdata_o(retire_wdata_o)
    );

    // The store has already retired, so this is deliberately not a precise
    // replay point.  Trap at the next unretired architectural PC, retain the
    // original store address in tval, and retain its trace metadata for
    // diagnostics.
    wire [`RV64_XLEN-1:0] async_abort_pc =
        (last_arch_next_pc_q != {`RV64_XLEN{1'b0}}) ?
        last_arch_next_pc_q : (async_store_fault_pc_q + 64'd4);
    assign exception_o = async_store_fault_pending_q || retire_exception;
    assign halt_o = !async_store_fault_pending_q && retire_halt;
    assign irq_o = !async_store_fault_pending_q && retire_irq;
    assign mret_o = !async_store_fault_pending_q && retire_mret;
    assign sret_o = !async_store_fault_pending_q && retire_sret;
    assign fence_i_o = !async_store_fault_pending_q && retire_fence_i;
    assign sfence_vma_o = !async_store_fault_pending_q && retire_sfence_vma;
    assign cause_o = async_store_fault_pending_q ?
                     async_store_fault_cause_q : retire_cause;
    assign retire_pc_o = async_store_fault_pending_q ?
                         async_abort_pc : retire_pc;
    assign retire_next_pc_o = async_store_fault_pending_q ?
                              async_abort_pc : retire_next_pc;
    assign retire_tval_o = async_store_fault_pending_q ?
                           async_store_fault_addr_q : retire_tval;
    assign retire_trace_id_o = async_store_fault_pending_q ?
                               async_store_fault_trace_q : retire_trace_id;
    assign retire_instr_o = async_store_fault_pending_q ?
                            async_store_fault_instr_q : retire_instr;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            async_store_fault_pending_q <= 1'b0;
            async_store_fault_cause_q <=
                `RV64_EXCEPT_CAUSE_STORE_ACCESS_FAULT;
            async_store_fault_addr_q <= {`RV64_XLEN{1'b0}};
            async_store_fault_pc_q <= {`RV64_XLEN{1'b0}};
            async_store_fault_trace_q <= 64'd0;
            async_store_fault_instr_q <= {`RV64_INSTR_WIDTH{1'b0}};
            last_arch_next_pc_q <= {`RV64_XLEN{1'b0}};
        end else begin
            if (|retire_arch_o)
                last_arch_next_pc_q <= retire_next_pc;

            // Capture wins over a simultaneous flush: the bus response is a
            // one-cycle event and must not disappear behind another redirect.
            if (async_store_fault) begin
                async_store_fault_pending_q <= 1'b1;
                async_store_fault_cause_q <= async_store_page_fault ?
                    `RV64_EXCEPT_CAUSE_STORE_PAGE_FAULT :
                    `RV64_EXCEPT_CAUSE_STORE_ACCESS_FAULT;
                async_store_fault_addr_q <= async_store_fault_addr;
                async_store_fault_pc_q <= async_store_fault_pc;
                async_store_fault_trace_q <= async_store_fault_trace;
                async_store_fault_instr_q <= async_store_fault_instr;
            end else if (flush_i || async_store_fault_pending_q) begin
                async_store_fault_pending_q <= 1'b0;
            end
        end
    end

    assign issue_valid_o = pipe_valid;
    assign complete_valid_o = complete_valid;

    wire unused_diagnostics = |{
        queue_retire_id, pipe_unsupported, raw_hazard, waw_hazard,
        read_port_hazard
    };

`ifndef SYNTHESIS
    initial begin
        if ((FREE_BRANCHES != 0) &&
            (ENABLE_ISSUE_WINDOW != 0))
            $fatal(1, "free branches require strict dispatch path");
        if ((ENABLE_ISSUE_WINDOW != 0) &&
            (ISSUE_WINDOW_DEPTH != RETIRE_DEPTH))
            $fatal(1, "issue-window depth must equal retirement depth");
        if ((ENABLE_SPECULATION_WINDOW != 0) &&
            (ENABLE_ISSUE_WINDOW == 0))
            $fatal(1, "speculation window requires issue window");
    end

    always @(posedge clk) begin
        if (rst_n && !flush_i && free_branch_resolved &&
            exec_branch_resolved)
            $fatal(1, "free and EX1 branch resolutions collided");
    end
`endif

endmodule
