`timescale 1ns/1ps
`include "core/backend/backend-defs.v"
`include "core/isa/rv64-i.v"
`include "core/isa/rv64-a.v"
`include "core/decode/defs/alu-defs.v"
`include "core/decode/defs/br-defs.v"

// Optional producer-tagged three-pipe issue window.
//
// Unlike dispatch_3p, retirement identity is allocated when decode admits an
// instruction.  The assigned retirement slot is also the physical window
// index.  Entries remain resident through issue and are released only at
// retirement, which keeps program age, completion identity, and issue state
// in one bounded structure without adding a second reorder map.
//
// Decode writes registered entries; no newly admitted instruction can issue
// until the following cycle.  Source values are captured either from the
// architectural GPR, the youngest completed producer, or a matching tagged
// completion.  Up to one instruction per physical pipe is then selected from
// the ready entries.  Memory issue remains program ordered, but the oldest two
// unissued memory operations may enter MEM0 and MEM1 together when they target
// opposite lanes and both lanes accept the complete pair.  The optional
// speculation mode lets replayable work pass an older conditional branch that
// is still waiting for operands, and lets ordinary loads begin translation
// past unresolved control.  The physically addressed LSQ admits the later
// cache access only when translation classifies the result as cacheable RAM;
// device/non-RAM loads wait for ordered retirement.  Stores and atomics remain
// protected.  Legal aligned direct JALs are deterministic controls, so they do
// not form an issue barrier even before reaching the retirement head.
// Conditional branches themselves resolve in program order so a younger
// wrong-path branch cannot redirect or train before an older branch resolves.
module openrv64_dispatch_window_3p #(
    parameter integer ENABLE = 1,
    parameter integer ENABLE_SPECULATION = 0,
    parameter integer DEPTH = 16,
    parameter [`RV64_XLEN-1:0] SPEC_LOAD_BASE = {`RV64_XLEN{1'b0}},
    parameter [`RV64_XLEN-1:0] SPEC_LOAD_SIZE = {`RV64_XLEN{1'b0}},
    parameter integer RETIRE_SLOT_WIDTH = $clog2(DEPTH),
    parameter integer COUNT_WIDTH = $clog2(DEPTH + 1)
) (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire                         flush_i,
    input  wire                         squash_frontend_i,
    input  wire [`OPENRV64_INSTR_ID_WIDTH-1:0] squash_id_i,

    input  wire [2:0]                   decode_valid_i,
    output wire [2:0]                   decode_ready_o,
    input  wire [3*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0]
                                        decode_payload_i,
    input  wire [2:0]                   decode_uses_rs1_i,
    input  wire [2:0]                   decode_uses_rs2_i,

    output wire [6*`RV64_REG_ADDR_WIDTH-1:0] gpr_read_addr_o,
    input  wire [6*`RV64_XLEN-1:0]      gpr_read_data_i,

    input  wire                         allocation_ready_i,
    input  wire [3*`OPENRV64_INSTR_ID_WIDTH-1:0] allocation_id_i,
    input  wire [3*RETIRE_SLOT_WIDTH-1:0] allocation_slot_i,
    output wire [2:0]                   allocation_valid_o,
    output wire [3*`OPENRV64_DISPATCH_META_WIDTH-1:0] allocation_meta_o,

    input  wire [`OPENRV64_EXEC_PIPE_COUNT-1:0] pipe_ready_i,
    output reg  [`OPENRV64_EXEC_PIPE_COUNT-1:0] pipe_valid_o,
    output reg  [`OPENRV64_EXEC_PIPE_COUNT*
                 `OPENRV64_INSTR_ID_WIDTH-1:0] pipe_id_o,
    output reg  [`OPENRV64_EXEC_PIPE_COUNT*RETIRE_SLOT_WIDTH-1:0]
                                        pipe_slot_o,
    output reg  [`OPENRV64_EXEC_PIPE_COUNT*
                 `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0]
                                        pipe_payload_o,
    output reg  [`OPENRV64_EXEC_PIPE_COUNT-1:0]
                                        pipe_src1_producer_valid_o,
    output reg  [`OPENRV64_EXEC_PIPE_COUNT*
                 `OPENRV64_INSTR_ID_WIDTH-1:0]
                                        pipe_src1_producer_id_o,
    output reg  [`OPENRV64_EXEC_PIPE_COUNT-1:0]
                                        pipe_src2_producer_valid_o,
    output reg  [`OPENRV64_EXEC_PIPE_COUNT*
                 `OPENRV64_INSTR_ID_WIDTH-1:0]
                                        pipe_src2_producer_id_o,

    input  wire [2:0]                   completion_valid_i,
    input  wire [3*`OPENRV64_INSTR_ID_WIDTH-1:0] completion_id_i,
    input  wire [3*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH-1:0]
                                        completion_payload_i,

    input  wire [2:0]                   retire_valid_i,
    input  wire [3*`OPENRV64_INSTR_ID_WIDTH-1:0] retire_id_i,
    input  wire [3*RETIRE_SLOT_WIDTH-1:0] retire_slot_i,
    input  wire [2:0]                   retire_hard_i,
    input  wire [`OPENRV64_INSTR_ID_WIDTH-1:0] next_retire_id_i,
    input  wire [RETIRE_SLOT_WIDTH-1:0] next_retire_slot_i,

    output reg                          barrier_active_o,
    output reg  [2:0]                   raw_hazard_o,
    output wire [2:0]                   waw_hazard_o,
    output wire [2:0]                   read_port_hazard_o,
    output wire [31:0]                  write_busy_o,
    output wire [COUNT_WIDTH-1:0]       queue_count_o
);

    localparam integer PAYLOAD_RS1_ADDR = 237;
    localparam integer PAYLOAD_RS2_ADDR = 232;
    localparam integer PAYLOAD_RS1_DATA = 168;
    localparam integer PAYLOAD_RS2_DATA = 104;
    localparam integer PAYLOAD_INSTR = 242;
    localparam integer PAYLOAD_IMM = 40;
    localparam integer PAYLOAD_RD = 35;
    localparam integer PAYLOAD_ALU_EXT = 32;
    localparam integer PAYLOAD_REG_WRITE = 17;
    localparam integer PAYLOAD_BR_OP = 18;
    localparam integer PAYLOAD_MEM_READ = 16;
    localparam integer PAYLOAD_MEM_WRITE = 15;
    localparam integer PAYLOAD_BRANCH = 14;
    localparam integer PAYLOAD_JUMP = 13;
    localparam integer PAYLOAD_SYSTEM = 10;
    localparam integer PAYLOAD_FENCE = 9;
    localparam integer PAYLOAD_ILLEGAL = 8;
    localparam integer PAYLOAD_EBREAK = 7;
    localparam integer PAYLOAD_ECALL = 6;
    localparam integer PAYLOAD_INSTR_FAULT = 5;
    localparam integer PAYLOAD_INSTR_PAGE_FAULT = 4;

    reg                                 valid_q [0:DEPTH-1];
    reg                                 issued_q [0:DEPTH-1];
    reg [`OPENRV64_INSTR_ID_WIDTH-1:0] id_q [0:DEPTH-1];
    reg [`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0]
                                        payload_q [0:DEPTH-1];
    reg                                 uses_rs1_q [0:DEPTH-1];
    reg                                 uses_rs2_q [0:DEPTH-1];
    reg                                 src1_ready_q [0:DEPTH-1];
    reg                                 src2_ready_q [0:DEPTH-1];
    reg                                 src1_producer_valid_q [0:DEPTH-1];
    reg                                 src2_producer_valid_q [0:DEPTH-1];
    reg [`OPENRV64_INSTR_ID_WIDTH-1:0] src1_tag_q [0:DEPTH-1];
    reg [`OPENRV64_INSTR_ID_WIDTH-1:0] src2_tag_q [0:DEPTH-1];
    reg                                 result_ready_q [0:DEPTH-1];
    reg [`RV64_XLEN-1:0]                result_data_q [0:DEPTH-1];
    reg [COUNT_WIDTH-1:0]               count_q;

    // Youngest architectural producer at decode admission.  Values are
    // retained after completion so a later decode does not wait for retire.
    reg [31:0]                          owner_valid_q;
    reg [31:0]                          owner_ready_q;
    reg [`OPENRV64_INSTR_ID_WIDTH-1:0] owner_id_q [0:31];
    reg [`RV64_XLEN-1:0]                owner_data_q [0:31];

    function automatic is_hard;
        input [`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0] payload;
        begin
            is_hard = payload[PAYLOAD_BRANCH] ||
                      payload[PAYLOAD_JUMP] ||
                      payload[PAYLOAD_SYSTEM] ||
                      payload[PAYLOAD_FENCE] ||
                      payload[PAYLOAD_ILLEGAL] ||
                      payload[PAYLOAD_EBREAK] ||
                      payload[PAYLOAD_ECALL] ||
                      payload[PAYLOAD_INSTR_FAULT] ||
                      payload[PAYLOAD_INSTR_PAGE_FAULT];
        end
    endfunction

    function automatic is_replayable_direct_jal;
        input [`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0] payload;
        begin
            // PC is 32-bit aligned and JAL's immediate is PC-relative, so
            // imm[1]==0 proves the target cannot raise an alignment exception.
            // Its target is known at decode and its link write remains in the
            // retirement queue, making younger side-effect-free work safe.
            is_replayable_direct_jal = payload[PAYLOAD_JUMP] &&
                (payload[PAYLOAD_BR_OP +: `RV64_BR_OP_WIDTH] ==
                 `RV64_BR_OP_JAL) &&
                !payload[PAYLOAD_ILLEGAL] &&
                !payload[PAYLOAD_INSTR_FAULT] &&
                !payload[PAYLOAD_INSTR_PAGE_FAULT] &&
                !payload[PAYLOAD_IMM + 1];
        end
    endfunction

    function automatic is_early_conditional_branch;
        input [`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0] payload;
        begin
            is_early_conditional_branch = payload[PAYLOAD_BRANCH] &&
                !payload[PAYLOAD_ILLEGAL] &&
                !payload[PAYLOAD_INSTR_FAULT] &&
                !payload[PAYLOAD_INSTR_PAGE_FAULT] &&
                !payload[PAYLOAD_IMM + 1];
        end
    endfunction

    function automatic may_speculate_past_unissued_control;
        input [`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0] payload;
        begin
            // Direct JAL is deterministic.  Conditional branches require the
            // selective recovery machinery because their compare operands may
            // arrive after younger replayable instructions have executed.
            may_speculate_past_unissued_control =
                is_replayable_direct_jal(payload) ||
                ((ENABLE_SPECULATION != 0) &&
                 is_early_conditional_branch(payload));
        end
    endfunction

    function automatic is_persistent_hard;
        input [`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0] payload;
        begin
            // Aligned decoded conditional branches and deterministic direct
            // JALs may execute before the retirement head.  The optional
            // speculation window handles conditional redirect recovery; JAL
            // has no direction or target uncertainty once decoded.
            is_persistent_hard = is_hard(payload) &&
                !is_early_conditional_branch(payload) &&
                !is_replayable_direct_jal(payload);
        end
    endfunction

    function automatic is_mem;
        input [`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0] payload;
        begin
            is_mem = payload[PAYLOAD_MEM_READ] ||
                     payload[PAYLOAD_MEM_WRITE];
        end
    endfunction

    function automatic is_mem1_op;
        input [`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0] payload;
        reg [`RV64_INSTR_WIDTH-1:0] payload_instr;
        begin
            payload_instr = payload[PAYLOAD_INSTR +: `RV64_INSTR_WIDTH];
            is_mem1_op = payload[PAYLOAD_MEM_WRITE] ||
                (`RV64_OPCODE(payload_instr) == `RV64_OPCODE_AMO);
        end
    endfunction

    function automatic is_speculative_load_candidate;
        input [`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0] payload;
        begin
            // A virtual address cannot establish PMA/cacheability.  Permit an
            // ordinary load to reach translation; the LSQ waits for the
            // translated physical address and suppresses device/non-RAM
            // access until the instruction is the ordered retirement head.
            // AMOs assert MEM_WRITE as well as MEM_READ and remain excluded.
            is_speculative_load_candidate =
                (ENABLE_SPECULATION != 0) && payload[PAYLOAD_MEM_READ] &&
                !payload[PAYLOAD_MEM_WRITE];
        end
    endfunction

    function automatic is_fixed_ex0;
        input [`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0] payload;
        begin
            is_fixed_ex0 = !is_hard(payload) && !is_mem(payload) &&
                (payload[PAYLOAD_ALU_EXT +: `RV64_ALU_EXT_WIDTH] ==
                 `RV64_ALU_EXT_M);
        end
    endfunction

    function automatic is_fixed_ex1;
        input [`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0] payload;
        begin
            is_fixed_ex1 = is_hard(payload);
        end
    endfunction

    function automatic is_flexible_alu;
        input [`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0] payload;
        begin
            is_flexible_alu = !is_hard(payload) && !is_mem(payload) &&
                (payload[PAYLOAD_ALU_EXT +: `RV64_ALU_EXT_WIDTH] ==
                 `RV64_ALU_EXT_BASE);
        end
    endfunction

    function automatic completion_safe;
        input [`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH-1:0] payload;
        begin
            completion_safe = payload[`OPENRV64_COMPLETE_REG_WRITE_BIT] &&
                !payload[`OPENRV64_COMPLETE_ILLEGAL_BIT] &&
                !payload[`OPENRV64_COMPLETE_EXCEPTION_BIT];
        end
    endfunction

    function automatic id_is_younger;
        input [`OPENRV64_INSTR_ID_WIDTH-1:0] candidate;
        input [`OPENRV64_INSTR_ID_WIDTH-1:0] reference;
        reg [`OPENRV64_INSTR_ID_WIDTH-1:0] distance;
        begin
            distance = candidate - reference;
            id_is_younger =
                (distance != {`OPENRV64_INSTR_ID_WIDTH{1'b0}}) &&
                !distance[`OPENRV64_INSTR_ID_WIDTH-1];
        end
    endfunction

    // GPR values are sampled at decode admission.  Three same-cycle decode
    // lanes still see one another through the temporary owner view below.
    genvar read_lane;
    generate
        for (read_lane = 0; read_lane < 3; read_lane = read_lane + 1) begin : g_read
            assign gpr_read_addr_o[
                (read_lane*2+0)*`RV64_REG_ADDR_WIDTH +:
                `RV64_REG_ADDR_WIDTH] = decode_payload_i[
                read_lane*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +
                PAYLOAD_RS1_ADDR +: `RV64_REG_ADDR_WIDTH];
            assign gpr_read_addr_o[
                (read_lane*2+1)*`RV64_REG_ADDR_WIDTH +:
                `RV64_REG_ADDR_WIDTH] = decode_payload_i[
                read_lane*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +
                PAYLOAD_RS2_ADDR +: `RV64_REG_ADDR_WIDTH];
        end
    endgenerate

    wire [COUNT_WIDTH:0] free_count = DEPTH - count_q;
    assign decode_ready_o[0] = !flush_i && !squash_frontend_i &&
                               allocation_ready_i && (free_count >= 1);
    assign decode_ready_o[1] = decode_ready_o[0] && (free_count >= 2);
    assign decode_ready_o[2] = decode_ready_o[1] && (free_count >= 3);
    wire decode_fire0 = decode_valid_i[0] && decode_ready_o[0];
    wire decode_fire1 = decode_valid_i[1] && decode_ready_o[1] && decode_fire0;
    wire decode_fire2 = decode_valid_i[2] && decode_ready_o[2] && decode_fire1;
    wire [2:0] decode_fire = {decode_fire2, decode_fire1, decode_fire0};
    wire [1:0] decode_count = {1'b0, decode_fire0} +
                              {1'b0, decode_fire1} +
                              {1'b0, decode_fire2};
    assign allocation_valid_o = decode_fire;

    wire [1:0] retire_count = {1'b0, retire_valid_i[0]} +
                              {1'b0, retire_valid_i[1]} +
                              {1'b0, retire_valid_i[2]};

    reg [31:0] owner_valid_view;
    reg [31:0] owner_ready_view;
    reg [`OPENRV64_INSTR_ID_WIDTH-1:0] owner_id_view [0:31];
    reg [`RV64_XLEN-1:0] owner_data_view [0:31];
    reg [`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0]
        admit_payload [0:2];
    reg [`OPENRV64_INSTR_ID_WIDTH-1:0] admit_src1_tag [0:2];
    reg [`OPENRV64_INSTR_ID_WIDTH-1:0] admit_src2_tag [0:2];
    reg admit_src1_producer_valid [0:2];
    reg admit_src2_producer_valid [0:2];
    reg admit_src1_ready [0:2];
    reg admit_src2_ready [0:2];
    reg [`RV64_XLEN-1:0] admit_src1_data [0:2];
    reg [`RV64_XLEN-1:0] admit_src2_data [0:2];
    integer owner_idx;
    integer view_lane;
    integer view_port;
    reg [`RV64_REG_ADDR_WIDTH-1:0] view_rs1;
    reg [`RV64_REG_ADDR_WIDTH-1:0] view_rs2;
    reg [`RV64_REG_ADDR_WIDTH-1:0] view_rd;
    reg [`OPENRV64_INSTR_ID_WIDTH-1:0] view_id;
    reg [`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH-1:0] view_completion;

    always_comb begin
        owner_valid_view = owner_valid_q;
        owner_ready_view = owner_ready_q;
        for (owner_idx = 0; owner_idx < 32; owner_idx = owner_idx + 1) begin
            owner_id_view[owner_idx] = owner_id_q[owner_idx];
            owner_data_view[owner_idx] = owner_data_q[owner_idx];
        end

        // Completion precedes retirement in the architectural age order.
        for (view_port = 0; view_port < 3; view_port = view_port + 1) begin
            view_id = completion_id_i[
                view_port*`OPENRV64_INSTR_ID_WIDTH +:
                `OPENRV64_INSTR_ID_WIDTH];
            view_completion = completion_payload_i[
                view_port*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +:
                `OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH];
            view_rd = view_completion[
                `OPENRV64_COMPLETE_RD_LSB +: `RV64_REG_ADDR_WIDTH];
            if (completion_valid_i[view_port] &&
                completion_safe(view_completion) &&
                (view_rd != `RV64_REG_X0) && owner_valid_view[view_rd] &&
                (owner_id_view[view_rd] == view_id)) begin
                owner_ready_view[view_rd] = 1'b1;
                owner_data_view[view_rd] = view_completion[
                    `OPENRV64_COMPLETE_DATA_LSB +: `RV64_XLEN];
            end
        end

        for (view_lane = 0; view_lane < 3; view_lane = view_lane + 1) begin
            view_id = retire_id_i[
                view_lane*`OPENRV64_INSTR_ID_WIDTH +:
                `OPENRV64_INSTR_ID_WIDTH];
            for (owner_idx = 1; owner_idx < 32;
                 owner_idx = owner_idx + 1) begin
                if (retire_valid_i[view_lane] &&
                    owner_valid_view[owner_idx] &&
                    (owner_id_view[owner_idx] == view_id)) begin
                    owner_valid_view[owner_idx] = 1'b0;
                    owner_ready_view[owner_idx] = 1'b0;
                end
            end
        end

        for (view_lane = 0; view_lane < 3; view_lane = view_lane + 1) begin
            admit_payload[view_lane] = decode_payload_i[
                view_lane*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +:
                `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH];
            view_rs1 = admit_payload[view_lane][
                PAYLOAD_RS1_ADDR +: `RV64_REG_ADDR_WIDTH];
            view_rs2 = admit_payload[view_lane][
                PAYLOAD_RS2_ADDR +: `RV64_REG_ADDR_WIDTH];
            view_rd = admit_payload[view_lane][
                PAYLOAD_RD +: `RV64_REG_ADDR_WIDTH];

            admit_src1_tag[view_lane] =
                {`OPENRV64_INSTR_ID_WIDTH{1'b0}};
            admit_src2_tag[view_lane] =
                {`OPENRV64_INSTR_ID_WIDTH{1'b0}};
            admit_src1_producer_valid[view_lane] = 1'b0;
            admit_src2_producer_valid[view_lane] = 1'b0;
            admit_src1_ready[view_lane] = 1'b1;
            admit_src2_ready[view_lane] = 1'b1;
            admit_src1_data[view_lane] = {`RV64_XLEN{1'b0}};
            admit_src2_data[view_lane] = {`RV64_XLEN{1'b0}};

            if (decode_uses_rs1_i[view_lane] &&
                (view_rs1 != `RV64_REG_X0)) begin
                if (owner_valid_view[view_rs1]) begin
                    admit_src1_producer_valid[view_lane] = 1'b1;
                    admit_src1_tag[view_lane] = owner_id_view[view_rs1];
                    admit_src1_ready[view_lane] = owner_ready_view[view_rs1];
                    admit_src1_data[view_lane] = owner_data_view[view_rs1];
                end else begin
                    admit_src1_data[view_lane] = gpr_read_data_i[
                        (view_lane*2+0)*`RV64_XLEN +: `RV64_XLEN];
                end
            end
            if (decode_uses_rs2_i[view_lane] &&
                (view_rs2 != `RV64_REG_X0)) begin
                if (owner_valid_view[view_rs2]) begin
                    admit_src2_producer_valid[view_lane] = 1'b1;
                    admit_src2_tag[view_lane] = owner_id_view[view_rs2];
                    admit_src2_ready[view_lane] = owner_ready_view[view_rs2];
                    admit_src2_data[view_lane] = owner_data_view[view_rs2];
                end else begin
                    admit_src2_data[view_lane] = gpr_read_data_i[
                        (view_lane*2+1)*`RV64_XLEN +: `RV64_XLEN];
                end
            end

            admit_payload[view_lane][PAYLOAD_RS1_DATA +: `RV64_XLEN] =
                admit_src1_data[view_lane];
            admit_payload[view_lane][PAYLOAD_RS2_DATA +: `RV64_XLEN] =
                admit_src2_data[view_lane];

            // Allocation is program ordered, so later lanes observe writers
            // allocated by earlier lanes in this same decode bundle.
            if (decode_fire[view_lane] &&
                admit_payload[view_lane][PAYLOAD_REG_WRITE] &&
                (view_rd != `RV64_REG_X0)) begin
                owner_valid_view[view_rd] = 1'b1;
                owner_ready_view[view_rd] = 1'b0;
                owner_id_view[view_rd] = allocation_id_i[
                    view_lane*`OPENRV64_INSTR_ID_WIDTH +:
                    `OPENRV64_INSTR_ID_WIDTH];
                owner_data_view[view_rd] = {`RV64_XLEN{1'b0}};
            end
        end
        owner_valid_view[`RV64_REG_X0] = 1'b0;
        owner_ready_view[`RV64_REG_X0] = 1'b0;
    end

    generate
        for (read_lane = 0; read_lane < 3; read_lane = read_lane + 1) begin : g_meta
            assign allocation_meta_o[
                read_lane*`OPENRV64_DISPATCH_META_WIDTH +:
                `OPENRV64_DISPATCH_META_WIDTH] = {
                is_hard(admit_payload[read_lane]),
                decode_uses_rs2_i[read_lane],
                decode_uses_rs1_i[read_lane],
                admit_payload[read_lane]
            };
        end
    endgenerate

    reg src1_ready_now [0:DEPTH-1];
    reg src2_ready_now [0:DEPTH-1];
    reg [`RV64_XLEN-1:0] src1_data_now [0:DEPTH-1];
    reg [`RV64_XLEN-1:0] src2_data_now [0:DEPTH-1];
    integer ready_idx;
    integer ready_port;
    reg [`OPENRV64_INSTR_ID_WIDTH-1:0] ready_id;
    reg [`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH-1:0] ready_completion;

    always_comb begin
        for (ready_idx = 0; ready_idx < DEPTH; ready_idx = ready_idx + 1) begin
            src1_ready_now[ready_idx] = src1_ready_q[ready_idx];
            src2_ready_now[ready_idx] = src2_ready_q[ready_idx];
            src1_data_now[ready_idx] = payload_q[ready_idx][
                PAYLOAD_RS1_DATA +: `RV64_XLEN];
            src2_data_now[ready_idx] = payload_q[ready_idx][
                PAYLOAD_RS2_DATA +: `RV64_XLEN];
            for (ready_port = 0; ready_port < 3;
                 ready_port = ready_port + 1) begin
                ready_id = completion_id_i[
                    ready_port*`OPENRV64_INSTR_ID_WIDTH +:
                    `OPENRV64_INSTR_ID_WIDTH];
                ready_completion = completion_payload_i[
                    ready_port*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +:
                    `OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH];
                if (completion_valid_i[ready_port] &&
                    completion_safe(ready_completion) &&
                    !src1_ready_now[ready_idx] &&
                    (src1_tag_q[ready_idx] == ready_id)) begin
                    src1_ready_now[ready_idx] = 1'b1;
                    src1_data_now[ready_idx] = ready_completion[
                        `OPENRV64_COMPLETE_DATA_LSB +: `RV64_XLEN];
                end
                if (completion_valid_i[ready_port] &&
                    completion_safe(ready_completion) &&
                    !src2_ready_now[ready_idx] &&
                    (src2_tag_q[ready_idx] == ready_id)) begin
                    src2_ready_now[ready_idx] = 1'b1;
                    src2_data_now[ready_idx] = ready_completion[
                        `OPENRV64_COMPLETE_DATA_LSB +: `RV64_XLEN];
                end
            end
        end
    end

    reg eligible [0:DEPTH-1];
    reg mem_pair_eligible [0:DEPTH-1];
    // Simulation-visible aggregate state.  These are deliberately kept as
    // named internal signals instead of architectural ports; the cycle trace
    // uses them to distinguish an empty window from RAW, ordering, and
    // capability pressure when the selectable window path is active.
    reg [COUNT_WIDTH-1:0] trace_unissued_count;
    reg [COUNT_WIDTH-1:0] trace_operand_ready_count;
    reg [COUNT_WIDTH-1:0] trace_eligible_count;
    reg [COUNT_WIDTH-1:0] trace_raw_block_count;
    reg [COUNT_WIDTH-1:0] trace_hard_block_count;
    reg [COUNT_WIDTH-1:0] trace_mem_order_block_count;
    integer eligible_idx;
    integer older_idx;
    reg older_unissued_hard;
    reg older_persistent_hard;
    reg older_unissued_mem;
    reg older_live_control;
    reg older_unresolved_conditional;

    always_comb begin
        barrier_active_o = 1'b0;
        raw_hazard_o = 3'b000;
        trace_unissued_count = {COUNT_WIDTH{1'b0}};
        trace_operand_ready_count = {COUNT_WIDTH{1'b0}};
        trace_eligible_count = {COUNT_WIDTH{1'b0}};
        trace_raw_block_count = {COUNT_WIDTH{1'b0}};
        trace_hard_block_count = {COUNT_WIDTH{1'b0}};
        trace_mem_order_block_count = {COUNT_WIDTH{1'b0}};
        for (eligible_idx = 0; eligible_idx < DEPTH;
             eligible_idx = eligible_idx + 1) begin
            older_unissued_hard = 1'b0;
            older_persistent_hard = 1'b0;
            older_unissued_mem = 1'b0;
            older_live_control = 1'b0;
            older_unresolved_conditional = 1'b0;
            for (older_idx = 0; older_idx < DEPTH;
                 older_idx = older_idx + 1) begin
                if (valid_q[older_idx] &&
                    id_is_younger(id_q[eligible_idx],
                                  id_q[older_idx])) begin
                    if (!issued_q[older_idx] &&
                        is_hard(payload_q[older_idx]) &&
                        !may_speculate_past_unissued_control(
                            payload_q[older_idx]))
                        older_unissued_hard = 1'b1;
                    if (is_persistent_hard(payload_q[older_idx]))
                        older_persistent_hard = 1'b1;
                    if (!issued_q[older_idx] && is_mem(payload_q[older_idx]))
                        older_unissued_mem = 1'b1;
                    if (!issued_q[older_idx] &&
                        is_early_conditional_branch(payload_q[older_idx]))
                        older_unresolved_conditional = 1'b1;
                    if (payload_q[older_idx][PAYLOAD_BRANCH] ||
                        is_replayable_direct_jal(payload_q[older_idx]))
                        older_live_control = 1'b1;
                end
            end

            if (valid_q[eligible_idx] &&
                is_persistent_hard(payload_q[eligible_idx]))
                barrier_active_o = 1'b1;

            eligible[eligible_idx] = valid_q[eligible_idx] &&
                !issued_q[eligible_idx] && src1_ready_now[eligible_idx] &&
                src2_ready_now[eligible_idx] && !older_unissued_hard &&
                !older_persistent_hard;
            if (is_persistent_hard(payload_q[eligible_idx]) &&
                (id_q[eligible_idx] != next_retire_id_i))
                eligible[eligible_idx] = 1'b0;
            // Data work may cross several predicted branches, but conditional
            // branches themselves resolve in program order.  This prevents a
            // younger wrong-path branch from redirecting or training the
            // predictor before an older unresolved branch is known correct.
            if ((ENABLE_SPECULATION != 0) &&
                is_early_conditional_branch(payload_q[eligible_idx]) &&
                older_unresolved_conditional)
                eligible[eligible_idx] = 1'b0;
            // Preserve all non-memory ordering and control checks separately
            // from the older-memory check.  The selector may use this view
            // only for the memory operation immediately following the oldest
            // selected memory operation in the same coupled issue bundle.
            mem_pair_eligible[eligible_idx] =
                eligible[eligible_idx] &&
                is_mem(payload_q[eligible_idx]);
            if (is_mem(payload_q[eligible_idx]) &&
                older_live_control &&
                !is_speculative_load_candidate(
                    payload_q[eligible_idx])) begin
                eligible[eligible_idx] = 1'b0;
                mem_pair_eligible[eligible_idx] = 1'b0;
            end
            if (is_mem(payload_q[eligible_idx]) && older_unissued_mem)
                eligible[eligible_idx] = 1'b0;

            if (valid_q[eligible_idx] && !issued_q[eligible_idx] &&
                (!src1_ready_now[eligible_idx] ||
                 !src2_ready_now[eligible_idx]))
                raw_hazard_o[0] = 1'b1;

            if (valid_q[eligible_idx] && !issued_q[eligible_idx]) begin
                trace_unissued_count = trace_unissued_count + 1'b1;
                if (src1_ready_now[eligible_idx] &&
                    src2_ready_now[eligible_idx])
                    trace_operand_ready_count =
                        trace_operand_ready_count + 1'b1;
                else
                    trace_raw_block_count = trace_raw_block_count + 1'b1;
                if (eligible[eligible_idx])
                    trace_eligible_count = trace_eligible_count + 1'b1;
                else if (src1_ready_now[eligible_idx] &&
                         src2_ready_now[eligible_idx]) begin
                    if ((is_mem(payload_q[eligible_idx]) &&
                         (older_unissued_mem ||
                         (older_live_control &&
                           !is_speculative_load_candidate(
                               payload_q[eligible_idx])))))
                        trace_mem_order_block_count =
                            trace_mem_order_block_count + 1'b1;
                    else if (older_unissued_hard || older_persistent_hard ||
                             ((ENABLE_SPECULATION != 0) &&
                              is_early_conditional_branch(
                                  payload_q[eligible_idx]) &&
                              older_unresolved_conditional) ||
                             (is_persistent_hard(payload_q[eligible_idx]) &&
                              (id_q[eligible_idx] != next_retire_id_i)))
                        trace_hard_block_count =
                            trace_hard_block_count + 1'b1;
                end
            end
        end
    end

    reg select_ex0_valid;
    reg select_ex1_valid;
    reg select_mem_valid;
    reg select_mem2_valid;
    reg [RETIRE_SLOT_WIDTH-1:0] select_ex0;
    reg [RETIRE_SLOT_WIDTH-1:0] select_ex1;
    reg [RETIRE_SLOT_WIDTH-1:0] select_mem;
    reg [RETIRE_SLOT_WIDTH-1:0] select_mem2;
    integer select_offset;
    integer select_slot;
    integer selected_idx;
    integer selected_mem_pipe;
    integer selected_mem2_pipe;
    reg past_selected_mem;
    reg checked_next_mem;
    reg [2:0] trace_pipe_uses_rs1;
    reg [2:0] trace_pipe_uses_rs2;

    always_comb begin
        select_ex0_valid = 1'b0;
        select_ex1_valid = 1'b0;
        select_mem_valid = 1'b0;
        select_mem2_valid = 1'b0;
        select_ex0 = {RETIRE_SLOT_WIDTH{1'b0}};
        select_ex1 = {RETIRE_SLOT_WIDTH{1'b0}};
        select_mem = {RETIRE_SLOT_WIDTH{1'b0}};
        select_mem2 = {RETIRE_SLOT_WIDTH{1'b0}};
        selected_idx = 0;
        selected_mem_pipe = `OPENRV64_EXEC_PIPE_MEM0;
        selected_mem2_pipe = `OPENRV64_EXEC_PIPE_MEM0;
        past_selected_mem = 1'b0;
        checked_next_mem = 1'b0;

        // Reserve fixed-capability work first, in age order.
        for (select_offset = 0; select_offset < DEPTH;
             select_offset = select_offset + 1) begin
            select_slot = next_retire_slot_i + select_offset;
            if (select_slot >= DEPTH)
                select_slot = select_slot - DEPTH;
            if (!select_ex0_valid && eligible[select_slot] &&
                is_fixed_ex0(payload_q[select_slot])) begin
                select_ex0_valid = 1'b1;
                select_ex0 = select_slot[RETIRE_SLOT_WIDTH-1:0];
            end
            if (!select_ex1_valid && eligible[select_slot] &&
                is_fixed_ex1(payload_q[select_slot])) begin
                select_ex1_valid = 1'b1;
                select_ex1 = select_slot[RETIRE_SLOT_WIDTH-1:0];
            end
            if (!select_mem_valid && eligible[select_slot] &&
                is_mem(payload_q[select_slot])) begin
                select_mem_valid = 1'b1;
                select_mem = select_slot[RETIRE_SLOT_WIDTH-1:0];
            end
        end

        // Flexible base-ALU instructions consume remaining EX lanes oldest
        // first.  A slot is never selected twice.
        for (select_offset = 0; select_offset < DEPTH;
             select_offset = select_offset + 1) begin
            select_slot = next_retire_slot_i + select_offset;
            if (select_slot >= DEPTH)
                select_slot = select_slot - DEPTH;
            if (!select_ex0_valid && eligible[select_slot] &&
                is_flexible_alu(payload_q[select_slot]) &&
                (!select_ex1_valid ||
                 (select_ex1 != select_slot[RETIRE_SLOT_WIDTH-1:0]))) begin
                select_ex0_valid = 1'b1;
                select_ex0 = select_slot[RETIRE_SLOT_WIDTH-1:0];
            end
        end
        for (select_offset = 0; select_offset < DEPTH;
             select_offset = select_offset + 1) begin
            select_slot = next_retire_slot_i + select_offset;
            if (select_slot >= DEPTH)
                select_slot = select_slot - DEPTH;
            if (!select_ex1_valid && eligible[select_slot] &&
                is_flexible_alu(payload_q[select_slot]) &&
                (!select_ex0_valid ||
                 (select_ex0 != select_slot[RETIRE_SLOT_WIDTH-1:0]))) begin
                select_ex1_valid = 1'b1;
                select_ex1 = select_slot[RETIRE_SLOT_WIDTH-1:0];
            end
        end

        // The first candidate is the oldest eligible memory operation.  Scan
        // forward to exactly the next unissued memory operation; do not skip
        // an unready or same-lane operation to manufacture a pair.
        if (select_mem_valid) begin
            for (select_offset = 0; select_offset < DEPTH;
                 select_offset = select_offset + 1) begin
                select_slot = next_retire_slot_i + select_offset;
                if (select_slot >= DEPTH)
                    select_slot = select_slot - DEPTH;
                if (!past_selected_mem &&
                    (select_slot[RETIRE_SLOT_WIDTH-1:0] == select_mem)) begin
                    past_selected_mem = 1'b1;
                end else if (past_selected_mem && !checked_next_mem &&
                             valid_q[select_slot] &&
                             !issued_q[select_slot] &&
                             is_mem(payload_q[select_slot])) begin
                    checked_next_mem = 1'b1;
                    if (mem_pair_eligible[select_slot] &&
                        (is_mem1_op(payload_q[select_slot]) !=
                         is_mem1_op(payload_q[select_mem]))) begin
                        select_mem2_valid = 1'b1;
                        select_mem2 =
                            select_slot[RETIRE_SLOT_WIDTH-1:0];
                    end
                end
            end
        end

        // Ordinary loads route to MEM0; stores and every RV64A operation route
        // to MEM1.  Route both payloads before consulting ready so execution
        // capability checks cannot create a ready/fire/payload loop.
        if (select_mem_valid &&
            is_mem1_op(payload_q[select_mem]))
            selected_mem_pipe = `OPENRV64_EXEC_PIPE_MEM1;
        if (select_mem2_valid &&
            is_mem1_op(payload_q[select_mem2]))
            selected_mem2_pipe = `OPENRV64_EXEC_PIPE_MEM1;
        pipe_id_o =
            {`OPENRV64_EXEC_PIPE_COUNT*
             `OPENRV64_INSTR_ID_WIDTH{1'b0}};
        pipe_slot_o =
            {`OPENRV64_EXEC_PIPE_COUNT*RETIRE_SLOT_WIDTH{1'b0}};
        pipe_payload_o =
            {`OPENRV64_EXEC_PIPE_COUNT*
             `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH{1'b0}};
        pipe_src1_producer_valid_o =
            {`OPENRV64_EXEC_PIPE_COUNT{1'b0}};
        pipe_src1_producer_id_o =
            {`OPENRV64_EXEC_PIPE_COUNT*
             `OPENRV64_INSTR_ID_WIDTH{1'b0}};
        pipe_src2_producer_valid_o =
            {`OPENRV64_EXEC_PIPE_COUNT{1'b0}};
        pipe_src2_producer_id_o =
            {`OPENRV64_EXEC_PIPE_COUNT*
             `OPENRV64_INSTR_ID_WIDTH{1'b0}};
        trace_pipe_uses_rs1 = 3'b000;
        trace_pipe_uses_rs2 = 3'b000;

        if (select_ex0_valid) begin
            selected_idx = select_ex0;
            pipe_id_o[
                0*`OPENRV64_INSTR_ID_WIDTH +:
                `OPENRV64_INSTR_ID_WIDTH] = id_q[selected_idx];
            pipe_slot_o[0*RETIRE_SLOT_WIDTH +: RETIRE_SLOT_WIDTH] =
                select_ex0;
            pipe_payload_o[
                0*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +:
                `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH] = payload_q[selected_idx];
            pipe_payload_o[
                0*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + PAYLOAD_RS1_DATA +:
                `RV64_XLEN] = src1_data_now[selected_idx];
            pipe_payload_o[
                0*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + PAYLOAD_RS2_DATA +:
                `RV64_XLEN] = src2_data_now[selected_idx];
            pipe_src1_producer_valid_o[0] =
                src1_producer_valid_q[selected_idx];
            pipe_src1_producer_id_o[
                0*`OPENRV64_INSTR_ID_WIDTH +:
                `OPENRV64_INSTR_ID_WIDTH] = src1_tag_q[selected_idx];
            pipe_src2_producer_valid_o[0] =
                src2_producer_valid_q[selected_idx];
            pipe_src2_producer_id_o[
                0*`OPENRV64_INSTR_ID_WIDTH +:
                `OPENRV64_INSTR_ID_WIDTH] = src2_tag_q[selected_idx];
            trace_pipe_uses_rs1[0] = uses_rs1_q[selected_idx];
            trace_pipe_uses_rs2[0] = uses_rs2_q[selected_idx];
        end
        if (select_ex1_valid) begin
            selected_idx = select_ex1;
            pipe_id_o[
                1*`OPENRV64_INSTR_ID_WIDTH +:
                `OPENRV64_INSTR_ID_WIDTH] = id_q[selected_idx];
            pipe_slot_o[1*RETIRE_SLOT_WIDTH +: RETIRE_SLOT_WIDTH] =
                select_ex1;
            pipe_payload_o[
                1*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +:
                `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH] = payload_q[selected_idx];
            pipe_payload_o[
                1*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + PAYLOAD_RS1_DATA +:
                `RV64_XLEN] = src1_data_now[selected_idx];
            pipe_payload_o[
                1*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + PAYLOAD_RS2_DATA +:
                `RV64_XLEN] = src2_data_now[selected_idx];
            pipe_src1_producer_valid_o[1] =
                src1_producer_valid_q[selected_idx];
            pipe_src1_producer_id_o[
                1*`OPENRV64_INSTR_ID_WIDTH +:
                `OPENRV64_INSTR_ID_WIDTH] = src1_tag_q[selected_idx];
            pipe_src2_producer_valid_o[1] =
                src2_producer_valid_q[selected_idx];
            pipe_src2_producer_id_o[
                1*`OPENRV64_INSTR_ID_WIDTH +:
                `OPENRV64_INSTR_ID_WIDTH] = src2_tag_q[selected_idx];
            trace_pipe_uses_rs1[1] = uses_rs1_q[selected_idx];
            trace_pipe_uses_rs2[1] = uses_rs2_q[selected_idx];
        end
        if (select_mem_valid) begin
            pipe_id_o[
                selected_mem_pipe*`OPENRV64_INSTR_ID_WIDTH +:
                `OPENRV64_INSTR_ID_WIDTH] = id_q[select_mem];
            pipe_slot_o[
                selected_mem_pipe*RETIRE_SLOT_WIDTH +:
                RETIRE_SLOT_WIDTH] = select_mem;
            pipe_payload_o[
                selected_mem_pipe*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +:
                `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH] = payload_q[select_mem];
            pipe_payload_o[
                selected_mem_pipe*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +
                PAYLOAD_RS1_DATA +: `RV64_XLEN] =
                src1_data_now[select_mem];
            pipe_payload_o[
                selected_mem_pipe*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +
                PAYLOAD_RS2_DATA +: `RV64_XLEN] =
                src2_data_now[select_mem];
            pipe_src1_producer_valid_o[selected_mem_pipe] =
                src1_producer_valid_q[select_mem];
            pipe_src1_producer_id_o[
                selected_mem_pipe*`OPENRV64_INSTR_ID_WIDTH +:
                `OPENRV64_INSTR_ID_WIDTH] = src1_tag_q[select_mem];
            pipe_src2_producer_valid_o[selected_mem_pipe] =
                src2_producer_valid_q[select_mem];
            pipe_src2_producer_id_o[
                selected_mem_pipe*`OPENRV64_INSTR_ID_WIDTH +:
                `OPENRV64_INSTR_ID_WIDTH] = src2_tag_q[select_mem];
            trace_pipe_uses_rs1[2] = uses_rs1_q[select_mem];
            trace_pipe_uses_rs2[2] = uses_rs2_q[select_mem];
        end
        if (select_mem2_valid) begin
            pipe_id_o[
                selected_mem2_pipe*`OPENRV64_INSTR_ID_WIDTH +:
                `OPENRV64_INSTR_ID_WIDTH] = id_q[select_mem2];
            pipe_slot_o[
                selected_mem2_pipe*RETIRE_SLOT_WIDTH +:
                RETIRE_SLOT_WIDTH] = select_mem2;
            pipe_payload_o[
                selected_mem2_pipe*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +:
                `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH] = payload_q[select_mem2];
            pipe_payload_o[
                selected_mem2_pipe*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +
                PAYLOAD_RS1_DATA +: `RV64_XLEN] =
                src1_data_now[select_mem2];
            pipe_payload_o[
                selected_mem2_pipe*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +
                PAYLOAD_RS2_DATA +: `RV64_XLEN] =
                src2_data_now[select_mem2];
            pipe_src1_producer_valid_o[selected_mem2_pipe] =
                src1_producer_valid_q[select_mem2];
            pipe_src1_producer_id_o[
                selected_mem2_pipe*`OPENRV64_INSTR_ID_WIDTH +:
                `OPENRV64_INSTR_ID_WIDTH] = src1_tag_q[select_mem2];
            pipe_src2_producer_valid_o[selected_mem2_pipe] =
                src2_producer_valid_q[select_mem2];
            pipe_src2_producer_id_o[
                selected_mem2_pipe*`OPENRV64_INSTR_ID_WIDTH +:
                `OPENRV64_INSTR_ID_WIDTH] = src2_tag_q[select_mem2];
            trace_pipe_uses_rs1[2] =
                uses_rs1_q[select_mem] | uses_rs1_q[select_mem2];
            trace_pipe_uses_rs2[2] =
                uses_rs2_q[select_mem] | uses_rs2_q[select_mem2];
        end
    end

    // Keep valid generation in a separate process from payload routing.
    // Execution readiness depends on the routed operation's capability; a
    // combined ready -> valid -> payload process forms a false combinational
    // loop in synthesis even though the payload selection itself is stable.
    always @* begin
        pipe_valid_o = {
            2'b00,
            select_ex1_valid,
            select_ex0_valid
        };
        if (select_mem_valid)
            pipe_valid_o[selected_mem_pipe] = 1'b1;
        // Coupled acceptance is required: allowing the younger operation to
        // enter its queue alone would hide the still-unissued older operation
        // from the cross-queue memory-order gate.
        if (select_mem2_valid &&
            pipe_ready_i[selected_mem_pipe] &&
            pipe_ready_i[selected_mem2_pipe])
            pipe_valid_o[selected_mem2_pipe] = 1'b1;
    end

    wire issue_ex0 = pipe_valid_o[0] && pipe_ready_i[0];
    wire issue_ex1 = pipe_valid_o[1] && pipe_ready_i[1];
    wire issue_mem0 = pipe_valid_o[2] && pipe_ready_i[2];
    wire issue_mem1 = pipe_valid_o[3] && pipe_ready_i[3];
    wire issue_mem_primary = select_mem_valid &&
        (is_mem1_op(payload_q[select_mem]) ? issue_mem1 : issue_mem0);
    wire issue_mem_secondary = select_mem2_valid &&
        (is_mem1_op(payload_q[select_mem2]) ? issue_mem1 : issue_mem0);

    integer entry_idx;
    integer completion_port;
    integer retire_lane;
    integer allocation_lane;
    reg [RETIRE_SLOT_WIDTH-1:0] update_slot;
    reg [`OPENRV64_INSTR_ID_WIDTH-1:0] update_id;
    reg [`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH-1:0] update_completion;
    reg [31:0] survivor_owner_valid;
    reg [31:0] survivor_owner_ready;
    reg [`OPENRV64_INSTR_ID_WIDTH-1:0] survivor_owner_id [0:31];
    reg [`RV64_XLEN-1:0] survivor_owner_data [0:31];
    reg [COUNT_WIDTH-1:0] survivor_count;
    reg survivor_retiring;
    reg recover_retiring;
    reg survivor_result_ready;
    reg [`RV64_XLEN-1:0] survivor_result_data;
    reg [`RV64_REG_ADDR_WIDTH-1:0] survivor_rd;
    reg [`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH-1:0]
        survivor_completion;
    integer survivor_idx;
    integer survivor_lane;
    integer survivor_port;

    wire selective_squash = squash_frontend_i &&
                            (ENABLE_SPECULATION != 0);

    // Recovery rebuilds the rename/ownership view from the entries retained
    // through the mispredicted branch.  Per-entry completion data is kept for
    // exactly this purpose: a squashed younger WAW must reveal the older live
    // producer rather than the stale architectural GPR value.
    always @* begin
        survivor_owner_valid = 32'd0;
        survivor_owner_ready = 32'd0;
        survivor_count = {COUNT_WIDTH{1'b0}};
        for (owner_idx = 0; owner_idx < 32; owner_idx = owner_idx + 1) begin
            survivor_owner_id[owner_idx] =
                {`OPENRV64_INSTR_ID_WIDTH{1'b0}};
            survivor_owner_data[owner_idx] = {`RV64_XLEN{1'b0}};
        end
        for (survivor_idx = 0; survivor_idx < DEPTH;
             survivor_idx = survivor_idx + 1) begin
            survivor_retiring = 1'b0;
            for (survivor_lane = 0; survivor_lane < 3;
                 survivor_lane = survivor_lane + 1) begin
                if (retire_valid_i[survivor_lane] &&
                    (retire_id_i[
                        survivor_lane*`OPENRV64_INSTR_ID_WIDTH +:
                        `OPENRV64_INSTR_ID_WIDTH] ==
                     id_q[survivor_idx]))
                    survivor_retiring = 1'b1;
            end
            if (valid_q[survivor_idx] && !survivor_retiring &&
                !id_is_younger(id_q[survivor_idx], squash_id_i)) begin
                survivor_count = survivor_count + 1'b1;
                survivor_rd = payload_q[survivor_idx][
                    PAYLOAD_RD +: `RV64_REG_ADDR_WIDTH];
                survivor_result_ready = result_ready_q[survivor_idx];
                survivor_result_data = result_data_q[survivor_idx];
                for (survivor_port = 0; survivor_port < 3;
                     survivor_port = survivor_port + 1) begin
                    survivor_completion = completion_payload_i[
                        survivor_port*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +:
                        `OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH];
                    if (completion_valid_i[survivor_port] &&
                        completion_safe(survivor_completion) &&
                        (completion_id_i[
                            survivor_port*`OPENRV64_INSTR_ID_WIDTH +:
                            `OPENRV64_INSTR_ID_WIDTH] ==
                         id_q[survivor_idx])) begin
                        survivor_result_ready = 1'b1;
                        survivor_result_data = survivor_completion[
                            `OPENRV64_COMPLETE_DATA_LSB +: `RV64_XLEN];
                    end
                end
                if (payload_q[survivor_idx][PAYLOAD_REG_WRITE] &&
                    (survivor_rd != `RV64_REG_X0) &&
                    (!survivor_owner_valid[survivor_rd] ||
                     id_is_younger(
                         id_q[survivor_idx],
                         survivor_owner_id[survivor_rd]))) begin
                    survivor_owner_valid[survivor_rd] = 1'b1;
                    survivor_owner_ready[survivor_rd] =
                        survivor_result_ready;
                    survivor_owner_id[survivor_rd] = id_q[survivor_idx];
                    survivor_owner_data[survivor_rd] =
                        survivor_result_data;
                end
            end
        end
        survivor_owner_valid[`RV64_REG_X0] = 1'b0;
        survivor_owner_ready[`RV64_REG_X0] = 1'b0;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            count_q <= {COUNT_WIDTH{1'b0}};
            owner_valid_q <= 32'd0;
            owner_ready_q <= 32'd0;
            for (owner_idx = 0; owner_idx < 32; owner_idx = owner_idx + 1) begin
                owner_id_q[owner_idx] <=
                    {`OPENRV64_INSTR_ID_WIDTH{1'b0}};
                owner_data_q[owner_idx] <= {`RV64_XLEN{1'b0}};
            end
            for (entry_idx = 0; entry_idx < DEPTH;
                 entry_idx = entry_idx + 1) begin
                valid_q[entry_idx] <= 1'b0;
                issued_q[entry_idx] <= 1'b0;
                id_q[entry_idx] <=
                    {`OPENRV64_INSTR_ID_WIDTH{1'b0}};
                payload_q[entry_idx] <=
                    {`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH{1'b0}};
                uses_rs1_q[entry_idx] <= 1'b0;
                uses_rs2_q[entry_idx] <= 1'b0;
                src1_ready_q[entry_idx] <= 1'b0;
                src2_ready_q[entry_idx] <= 1'b0;
                src1_producer_valid_q[entry_idx] <= 1'b0;
                src2_producer_valid_q[entry_idx] <= 1'b0;
                src1_tag_q[entry_idx] <=
                    {`OPENRV64_INSTR_ID_WIDTH{1'b0}};
                src2_tag_q[entry_idx] <=
                    {`OPENRV64_INSTR_ID_WIDTH{1'b0}};
                result_ready_q[entry_idx] <= 1'b0;
                result_data_q[entry_idx] <= {`RV64_XLEN{1'b0}};
            end
        end else if (flush_i ||
                     (squash_frontend_i &&
                      (ENABLE_SPECULATION == 0))) begin
            count_q <= {COUNT_WIDTH{1'b0}};
            owner_valid_q <= 32'd0;
            owner_ready_q <= 32'd0;
            for (entry_idx = 0; entry_idx < DEPTH;
                 entry_idx = entry_idx + 1) begin
                valid_q[entry_idx] <= 1'b0;
                issued_q[entry_idx] <= 1'b0;
            end
        end else if (selective_squash) begin
            count_q <= survivor_count;
            owner_valid_q <= survivor_owner_valid;
            owner_ready_q <= survivor_owner_ready;
            for (owner_idx = 0; owner_idx < 32;
                 owner_idx = owner_idx + 1) begin
                owner_id_q[owner_idx] <= survivor_owner_id[owner_idx];
                owner_data_q[owner_idx] <= survivor_owner_data[owner_idx];
            end

            // Preserve the resolving branch and all older work.  Any younger
            // completion already in flight is harmless because IDs are never
            // reused after recovery; its retirement-slot write will miss.
            for (entry_idx = 0; entry_idx < DEPTH;
                 entry_idx = entry_idx + 1) begin
                recover_retiring = 1'b0;
                for (retire_lane = 0; retire_lane < 3;
                     retire_lane = retire_lane + 1) begin
                    if (retire_valid_i[retire_lane] &&
                        (retire_id_i[
                            retire_lane*`OPENRV64_INSTR_ID_WIDTH +:
                            `OPENRV64_INSTR_ID_WIDTH] ==
                         id_q[entry_idx]))
                        recover_retiring = 1'b1;
                end
                if (!valid_q[entry_idx] || recover_retiring ||
                    id_is_younger(id_q[entry_idx], squash_id_i)) begin
                    valid_q[entry_idx] <= 1'b0;
                    issued_q[entry_idx] <= 1'b0;
                    result_ready_q[entry_idx] <= 1'b0;
                end else begin
                    for (completion_port = 0; completion_port < 3;
                         completion_port = completion_port + 1) begin
                        update_id = completion_id_i[
                            completion_port*`OPENRV64_INSTR_ID_WIDTH +:
                            `OPENRV64_INSTR_ID_WIDTH];
                        update_completion = completion_payload_i[
                            completion_port*
                            `OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +:
                            `OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH];
                        if (completion_valid_i[completion_port] &&
                            completion_safe(update_completion) &&
                            (update_id == id_q[entry_idx])) begin
                            result_ready_q[entry_idx] <= 1'b1;
                            result_data_q[entry_idx] <= update_completion[
                                `OPENRV64_COMPLETE_DATA_LSB +: `RV64_XLEN];
                        end
                        if (completion_valid_i[completion_port] &&
                            completion_safe(update_completion) &&
                            !src1_ready_q[entry_idx] &&
                            (src1_tag_q[entry_idx] == update_id)) begin
                            src1_ready_q[entry_idx] <= 1'b1;
                            payload_q[entry_idx][
                                PAYLOAD_RS1_DATA +: `RV64_XLEN] <=
                                update_completion[
                                    `OPENRV64_COMPLETE_DATA_LSB +:
                                    `RV64_XLEN];
                        end
                        if (completion_valid_i[completion_port] &&
                            completion_safe(update_completion) &&
                            !src2_ready_q[entry_idx] &&
                            (src2_tag_q[entry_idx] == update_id)) begin
                            src2_ready_q[entry_idx] <= 1'b1;
                            payload_q[entry_idx][
                                PAYLOAD_RS2_DATA +: `RV64_XLEN] <=
                                update_completion[
                                    `OPENRV64_COMPLETE_DATA_LSB +:
                                    `RV64_XLEN];
                        end
                    end
                end
            end

            if (issue_ex0 &&
                !id_is_younger(id_q[select_ex0], squash_id_i))
                issued_q[select_ex0] <= 1'b1;
            if (issue_ex1 &&
                !id_is_younger(id_q[select_ex1], squash_id_i))
                issued_q[select_ex1] <= 1'b1;
            if (issue_mem_primary &&
                !id_is_younger(id_q[select_mem], squash_id_i))
                issued_q[select_mem] <= 1'b1;
            if (issue_mem_secondary &&
                !id_is_younger(id_q[select_mem2], squash_id_i))
                issued_q[select_mem2] <= 1'b1;
        end else begin
            count_q <= count_q + decode_count - retire_count;
            owner_valid_q <= owner_valid_view;
            owner_ready_q <= owner_ready_view;
            for (owner_idx = 0; owner_idx < 32; owner_idx = owner_idx + 1) begin
                owner_id_q[owner_idx] <= owner_id_view[owner_idx];
                owner_data_q[owner_idx] <= owner_data_view[owner_idx];
            end

            // Persist completion wakeups so a one-cycle completion broadcast
            // is sufficient no matter how long the consumer waits to issue.
            for (entry_idx = 0; entry_idx < DEPTH;
                 entry_idx = entry_idx + 1) begin
                if (valid_q[entry_idx]) begin
                    for (completion_port = 0; completion_port < 3;
                         completion_port = completion_port + 1) begin
                        update_id = completion_id_i[
                            completion_port*`OPENRV64_INSTR_ID_WIDTH +:
                            `OPENRV64_INSTR_ID_WIDTH];
                        update_completion = completion_payload_i[
                            completion_port*
                            `OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +:
                            `OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH];
                        if (completion_valid_i[completion_port] &&
                            completion_safe(update_completion) &&
                            (id_q[entry_idx] == update_id)) begin
                            result_ready_q[entry_idx] <= 1'b1;
                            result_data_q[entry_idx] <= update_completion[
                                `OPENRV64_COMPLETE_DATA_LSB +: `RV64_XLEN];
                        end
                        if (completion_valid_i[completion_port] &&
                            completion_safe(update_completion) &&
                            !src1_ready_q[entry_idx] &&
                            (src1_tag_q[entry_idx] == update_id)) begin
                            src1_ready_q[entry_idx] <= 1'b1;
                            payload_q[entry_idx][
                                PAYLOAD_RS1_DATA +: `RV64_XLEN] <=
                                update_completion[
                                    `OPENRV64_COMPLETE_DATA_LSB +:
                                    `RV64_XLEN];
                        end
                        if (completion_valid_i[completion_port] &&
                            completion_safe(update_completion) &&
                            !src2_ready_q[entry_idx] &&
                            (src2_tag_q[entry_idx] == update_id)) begin
                            src2_ready_q[entry_idx] <= 1'b1;
                            payload_q[entry_idx][
                                PAYLOAD_RS2_DATA +: `RV64_XLEN] <=
                                update_completion[
                                    `OPENRV64_COMPLETE_DATA_LSB +:
                                    `RV64_XLEN];
                        end
                    end
                end
            end

            if (issue_ex0)
                issued_q[select_ex0] <= 1'b1;
            if (issue_ex1)
                issued_q[select_ex1] <= 1'b1;
            if (issue_mem_primary)
                issued_q[select_mem] <= 1'b1;
            if (issue_mem_secondary)
                issued_q[select_mem2] <= 1'b1;

            for (retire_lane = 0; retire_lane < 3;
                 retire_lane = retire_lane + 1) begin
                update_slot = retire_slot_i[
                    retire_lane*RETIRE_SLOT_WIDTH +: RETIRE_SLOT_WIDTH];
                if (retire_valid_i[retire_lane]) begin
                    valid_q[update_slot] <= 1'b0;
                    issued_q[update_slot] <= 1'b0;
                    result_ready_q[update_slot] <= 1'b0;
                end
            end

            for (allocation_lane = 0; allocation_lane < 3;
                 allocation_lane = allocation_lane + 1) begin
                update_slot = allocation_slot_i[
                    allocation_lane*RETIRE_SLOT_WIDTH +:
                    RETIRE_SLOT_WIDTH];
                if (decode_fire[allocation_lane]) begin
                    valid_q[update_slot] <= 1'b1;
                    issued_q[update_slot] <= 1'b0;
                    id_q[update_slot] <= allocation_id_i[
                        allocation_lane*`OPENRV64_INSTR_ID_WIDTH +:
                        `OPENRV64_INSTR_ID_WIDTH];
                    payload_q[update_slot] <= admit_payload[allocation_lane];
                    uses_rs1_q[update_slot] <=
                        decode_uses_rs1_i[allocation_lane];
                    uses_rs2_q[update_slot] <=
                        decode_uses_rs2_i[allocation_lane];
                    src1_ready_q[update_slot] <=
                        admit_src1_ready[allocation_lane];
                    src2_ready_q[update_slot] <=
                        admit_src2_ready[allocation_lane];
                    src1_producer_valid_q[update_slot] <=
                        admit_src1_producer_valid[allocation_lane];
                    src2_producer_valid_q[update_slot] <=
                        admit_src2_producer_valid[allocation_lane];
                    src1_tag_q[update_slot] <=
                        admit_src1_tag[allocation_lane];
                    src2_tag_q[update_slot] <=
                        admit_src2_tag[allocation_lane];
                    result_ready_q[update_slot] <= 1'b0;
                    result_data_q[update_slot] <= {`RV64_XLEN{1'b0}};
                end
            end
        end
    end

    assign waw_hazard_o = 3'b000;
    assign read_port_hazard_o = 3'b000;
    assign write_busy_o = owner_valid_q;
    assign queue_count_o = count_q;

    wire unused_retire_hard = |retire_hard_i;

`ifndef SYNTHESIS
    reg debug_window;
    reg [63:0] debug_pc;
    integer debug_lane;
    integer debug_slot;
    initial begin
        debug_window = $value$plusargs("issue_window_debug_pc=%h", debug_pc);
    end

    initial begin
        if ((ENABLE != 0) && (DEPTH != (1 << RETIRE_SLOT_WIDTH)))
            $fatal(1, "issue-window depth must be a power of two");
        if ((ENABLE != 0) &&
            (DEPTH >= (1 << (`OPENRV64_INSTR_ID_WIDTH - 1))))
            $fatal(1,
                   "issue-window depth must fit the modular ID half-range");
    end

    always @(posedge clk) begin
        if (rst_n && !flush_i && !squash_frontend_i) begin
            if ((decode_valid_i != 3'b000) &&
                (decode_valid_i != 3'b001) &&
                (decode_valid_i != 3'b011) &&
                (decode_valid_i != 3'b111))
                $fatal(1, "window decode input must be a contiguous prefix");
            if ((count_q + decode_count - retire_count) > DEPTH)
                $fatal(1, "issue window overflow");
        end
    end

    always @(negedge clk) begin
        if (rst_n && debug_window) begin
            for (debug_lane = 0; debug_lane < 3;
                 debug_lane = debug_lane + 1) begin
                if (decode_fire[debug_lane] &&
                    (admit_payload[debug_lane][274 +: 64] == debug_pc)) begin
                    debug_slot = allocation_slot_i[
                        debug_lane*RETIRE_SLOT_WIDTH +: RETIRE_SLOT_WIDTH];
                    $display({"WINDOW_DEBUG_ALLOC pc=%016x id=%016x slot=%0d ",
                              "s1_ready=%0d s1_tag=%016x s1_data=%016x ",
                              "s2_ready=%0d s2_tag=%016x s2_data=%016x"},
                             debug_pc,
                             allocation_id_i[
                                 debug_lane*`OPENRV64_INSTR_ID_WIDTH +:
                                 `OPENRV64_INSTR_ID_WIDTH],
                             debug_slot,
                             admit_src1_ready[debug_lane],
                             admit_src1_tag[debug_lane],
                             admit_src1_data[debug_lane],
                             admit_src2_ready[debug_lane],
                             admit_src2_tag[debug_lane],
                             admit_src2_data[debug_lane]);
                end
            end
            for (debug_slot = 0; debug_slot < DEPTH;
                 debug_slot = debug_slot + 1) begin
                if (valid_q[debug_slot] &&
                    (payload_q[debug_slot][274 +: 64] == debug_pc) &&
                    ((issue_ex0 && (select_ex0 == debug_slot)) ||
                     (issue_ex1 && (select_ex1 == debug_slot)) ||
                     (issue_mem_primary &&
                      (select_mem == debug_slot)) ||
                     (issue_mem_secondary &&
                      (select_mem2 == debug_slot)))) begin
                    $display({"WINDOW_DEBUG_ISSUE pc=%016x id=%016x slot=%0d ",
                              "s1_ready=%0d s1_tag=%016x s1_data=%016x ",
                              "s2_ready=%0d s2_tag=%016x s2_data=%016x"},
                             debug_pc, id_q[debug_slot], debug_slot,
                             src1_ready_now[debug_slot],
                             src1_tag_q[debug_slot],
                             src1_data_now[debug_slot],
                             src2_ready_now[debug_slot],
                             src2_tag_q[debug_slot],
                             src2_data_now[debug_slot]);
                end
            end
        end
    end
`endif

endmodule
