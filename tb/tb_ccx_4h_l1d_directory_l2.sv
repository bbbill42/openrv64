`timescale 1ns/1ps
`include "complex/protocol/defs.v"
`include "complex/coherent/protocol/defs.v"
`include "core/bus/bus-defs.v"
`include "core/decode/defs/lsu-defs.v"

// Focused four-hart data-coherence integration test.
//
// Each req_* lane below is the LSU-side contract normally driven by the core
// memory channel.  The test deliberately does not instantiate execution,
// translation, or the LSQ: those blocks do not alter the private-cache/CCX
// coherence contract being checked here.
//
//   4 LSU agents -> 4 private L1D -> line crossbar -> directory -> L2 -> RAM
//
// Private caches are currently clean, write-through S/I endpoints.  A probe
// adapter holds an invalidate request at each real L1D until that cache
// accepts it, then returns the directory ACK.  It never fabricates an ACK
// before the cache invalidation handshake.
module tb_ccx_4h_l1d_directory_l2 #(
    parameter integer RANDOM_ROUNDS = 2048,
    parameter integer ATOMIC_INTERVAL = 32
);

    localparam integer NUM_HARTS = 4;
    localparam integer TAG_WIDTH = `OPENRV64_LSU_TAG_WIDTH;
    localparam integer TAG_COUNT = 1 << TAG_WIDTH;
    localparam integer MEMORY_LINES = 512;
    localparam integer MEMORY_LATENCY = 4;
    localparam [63:0] MEMORY_BASE = 64'h0000_0000_8000_0000;
    localparam [63:0] LINE_A = MEMORY_BASE;
    localparam [63:0] LINE_B = MEMORY_BASE + 64'h0000_0040;
    localparam [63:0] LINE_C = MEMORY_BASE + 64'h0000_0080;
    localparam integer PINGPONG_LINES = 16;
    localparam [63:0] PINGPONG_BASE =
        MEMORY_BASE + 64'h0000_1000;
    localparam [63:0] WRITE_A0 = 64'hc001_cafe_0000_0002;
    localparam [63:0] WRITE_A1 = 64'hc001_cafe_0000_0001;

    logic clk;
    logic rst_n;
    integer cycle_count;
    integer commands_before;
    integer reads_before;
    integer hart_index;
    integer memory_line_index;
    integer memory_word_index;
    integer memory_byte_index;

    // Four LSU-side request agents.
    logic [NUM_HARTS-1:0] lsu_req_valid;
    wire [NUM_HARTS-1:0] lsu_req_ready;
    logic [NUM_HARTS*TAG_WIDTH-1:0] lsu_req_tag;
    logic [NUM_HARTS-1:0] lsu_req_lock;
    logic [NUM_HARTS-1:0] lsu_req_write;
    logic [NUM_HARTS*64-1:0] lsu_req_addr;
    logic [NUM_HARTS*64-1:0] lsu_req_wdata;
    logic [NUM_HARTS*8-1:0] lsu_req_wstrb;
    wire [NUM_HARTS*64-1:0] lsu_req_rdata;
    wire [NUM_HARTS-1:0] lsu_req_error;
    wire [NUM_HARTS-1:0] lsu_resp_valid;
    wire [NUM_HARTS*TAG_WIDTH-1:0] lsu_resp_tag;
    wire [NUM_HARTS-1:0] lsu_posted_resp_valid;
    wire [NUM_HARTS*TAG_WIDTH-1:0] lsu_posted_resp_tag;
    wire [NUM_HARTS-1:0] lsu_store_resp_valid;
    wire [NUM_HARTS-1:0] lsu_store_resp_error;
    logic [NUM_HARTS-1:0] speculation_barrier;
    wire [NUM_HARTS-1:0] store_barrier_busy;
    logic [NUM_HARTS*TAG_WIDTH-1:0] next_lsu_tag;

    // The local RV64A engine decomposes each AMO into a marked read and
    // marked write.  The L1D CCX adapter converts that mark into explicit
    // LR/SC home operations; no fabric lock is asserted.
    logic [NUM_HARTS-1:0] atomic_select;
    logic [NUM_HARTS-1:0] atomic_valid;
    logic [NUM_HARTS-1:0] atomic_consume;
    logic [NUM_HARTS*`RV64_LSU_OP_WIDTH-1:0] atomic_op;
    logic [NUM_HARTS*`RV64_LSU_SIZE_WIDTH-1:0] atomic_size;
    logic [NUM_HARTS*64-1:0] atomic_addr;
    logic [NUM_HARTS*64-1:0] atomic_operand;
    logic [NUM_HARTS*TAG_WIDTH-1:0] atomic_tag;
    wire [NUM_HARTS-1:0] atomic_complete;
    wire [NUM_HARTS-1:0] atomic_illegal;
    wire [NUM_HARTS-1:0] atomic_misaligned;
    wire [NUM_HARTS-1:0] atomic_access_fault;
    wire [NUM_HARTS-1:0] atomic_page_fault;
    wire [NUM_HARTS*64-1:0] atomic_result;
    wire [NUM_HARTS-1:0] atomic_mem_valid;
    wire [NUM_HARTS-1:0] atomic_mem_lock;
    wire [NUM_HARTS-1:0] atomic_mem_write;
    wire [NUM_HARTS*64-1:0] atomic_mem_addr;
    wire [NUM_HARTS*64-1:0] atomic_mem_wdata;
    wire [NUM_HARTS*8-1:0] atomic_mem_wstrb;
    logic [NUM_HARTS-1:0] atomic_mem_inflight;

    wire [NUM_HARTS-1:0] cache_req_valid;
    wire [NUM_HARTS*TAG_WIDTH-1:0] cache_req_tag;
    wire [NUM_HARTS-1:0] cache_req_lock;
    wire [NUM_HARTS-1:0] cache_req_posted;
    wire [NUM_HARTS-1:0] cache_req_write;
    wire [NUM_HARTS*64-1:0] cache_req_addr;
    wire [NUM_HARTS*64-1:0] cache_req_wdata;
    wire [NUM_HARTS*8-1:0] cache_req_wstrb;
    wire [NUM_HARTS*3-1:0] atomic_state_debug;
    wire [NUM_HARTS*2-1:0] l1d_backend_state_debug;

    // Private L1D to CCX line-crossbar channels.
    wire [NUM_HARTS-1:0] hart_req_valid;
    wire [NUM_HARTS-1:0] hart_req_ready;
    wire [NUM_HARTS*`OPENRV64_CCX_HART_ID_WIDTH-1:0]
        hart_req_hart_id;
    wire [NUM_HARTS*`OPENRV64_CCX_TXN_ID_WIDTH-1:0]
        hart_req_txn_id;
    wire [NUM_HARTS*`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0]
        hart_req_source_id;
    wire [NUM_HARTS*`OPENRV64_CCX_OP_WIDTH-1:0] hart_req_op;
    wire [NUM_HARTS-1:0] hart_req_lock;
    wire [NUM_HARTS*`OPENRV64_CCX_ORDER_WIDTH-1:0] hart_req_order;
    wire [NUM_HARTS*`OPENRV64_CCX_KIND_WIDTH-1:0] hart_req_kind;
    wire [NUM_HARTS*`OPENRV64_CCX_ATTR_WIDTH-1:0] hart_req_attr;
    wire [NUM_HARTS*3-1:0] hart_req_size;
    wire [NUM_HARTS*64-1:0] hart_req_addr;
    wire [NUM_HARTS*`OPENRV64_CCX_BURST_LEN_WIDTH-1:0]
        hart_req_burst_len;

    wire [NUM_HARTS-1:0] hart_wdata_valid;
    wire [NUM_HARTS-1:0] hart_wdata_ready;
    wire [NUM_HARTS*`OPENRV64_CCX_HART_ID_WIDTH-1:0]
        hart_wdata_hart_id;
    wire [NUM_HARTS*`OPENRV64_CCX_TXN_ID_WIDTH-1:0]
        hart_wdata_txn_id;
    wire [NUM_HARTS*`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0]
        hart_wdata_source_id;
    wire [NUM_HARTS*`OPENRV64_CCX_BEAT_INDEX_WIDTH-1:0]
        hart_wdata_beat_index;
    wire [NUM_HARTS-1:0] hart_wdata_last;
    wire [NUM_HARTS*`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] hart_wdata;
    wire [NUM_HARTS*`OPENRV64_CCX_LINE_STRB_WIDTH-1:0] hart_wstrb;

    wire [NUM_HARTS-1:0] hart_resp_valid;
    wire [NUM_HARTS*`OPENRV64_CCX_HART_ID_WIDTH-1:0]
        hart_resp_hart_id;
    wire [NUM_HARTS*`OPENRV64_CCX_TXN_ID_WIDTH-1:0]
        hart_resp_txn_id;
    wire [NUM_HARTS*`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0]
        hart_resp_source_id;
    wire [NUM_HARTS*`OPENRV64_CCX_BEAT_INDEX_WIDTH-1:0]
        hart_resp_beat_index;
    wire [NUM_HARTS-1:0] hart_resp_last;
    wire [NUM_HARTS*`OPENRV64_CCX_LINE_DATA_WIDTH-1:0]
        hart_resp_rdata;
    wire [NUM_HARTS-1:0] hart_resp_error;
    wire [NUM_HARTS-1:0] hart_resp_sc_success;
    wire [NUM_HARTS-1:0] hart_resp_ready;

    // Crossbar to coherent-directory frontend.
    wire ccx_req_valid;
    wire ccx_req_ready;
    wire [`OPENRV64_CCX_HART_ID_WIDTH-1:0] ccx_req_hart_id;
    wire [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] ccx_req_txn_id;
    wire [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] ccx_req_source_id;
    wire [`OPENRV64_CCX_OP_WIDTH-1:0] ccx_req_op;
    wire ccx_req_lock;
    wire [`OPENRV64_CCX_ORDER_WIDTH-1:0] ccx_req_order;
    wire [`OPENRV64_CCX_KIND_WIDTH-1:0] ccx_req_kind;
    wire [`OPENRV64_CCX_ATTR_WIDTH-1:0] ccx_req_attr;
    wire [2:0] ccx_req_size;
    wire [63:0] ccx_req_addr;
    wire [`OPENRV64_CCX_BURST_LEN_WIDTH-1:0] ccx_req_burst_len;

    wire ccx_wdata_valid;
    wire ccx_wdata_ready;
    wire [`OPENRV64_CCX_HART_ID_WIDTH-1:0] ccx_wdata_hart_id;
    wire [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] ccx_wdata_txn_id;
    wire [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] ccx_wdata_source_id;
    wire [`OPENRV64_CCX_BEAT_INDEX_WIDTH-1:0] ccx_wdata_beat_index;
    wire ccx_wdata_last;
    wire [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] ccx_wdata;
    wire [`OPENRV64_CCX_LINE_STRB_WIDTH-1:0] ccx_wstrb;

    wire ccx_resp_valid;
    wire ccx_resp_ready;
    wire [`OPENRV64_CCX_HART_ID_WIDTH-1:0] ccx_resp_hart_id;
    wire [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] ccx_resp_txn_id;
    wire [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] ccx_resp_source_id;
    wire [`OPENRV64_CCX_BEAT_INDEX_WIDTH-1:0] ccx_resp_beat_index;
    wire ccx_resp_last;
    wire [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] ccx_resp_rdata;
    wire ccx_resp_error;
    wire ccx_resp_sc_success;

    // Coherence-home probes.
    wire [NUM_HARTS-1:0] probe_valid;
    wire [NUM_HARTS-1:0] probe_ready;
    wire [NUM_HARTS*`OPENRV64_CCX_PROBE_ID_WIDTH-1:0] probe_id;
    wire [NUM_HARTS*`OPENRV64_CCX_PROBE_CMD_WIDTH-1:0]
        probe_command;
    wire [NUM_HARTS*`OPENRV64_CCX_PROBE_CACHE_WIDTH-1:0]
        probe_cache_mask;
    wire [NUM_HARTS*64-1:0] probe_line_addr;
    wire [NUM_HARTS-1:0] probe_resp_valid;
    wire [NUM_HARTS-1:0] probe_resp_ready;
    wire [NUM_HARTS*`OPENRV64_CCX_PROBE_ID_WIDTH-1:0]
        probe_resp_id;
    wire [NUM_HARTS*`OPENRV64_CCX_PROBE_RESP_WIDTH-1:0]
        probe_resp_kind;
    wire [NUM_HARTS*`OPENRV64_CCX_LINE_DATA_WIDTH-1:0]
        probe_resp_data;
    wire [NUM_HARTS-1:0] probe_resp_error;
    wire [NUM_HARTS-1:0] l1d_invalidate_valid;
    wire [NUM_HARTS-1:0] l1d_invalidate_ready;
    wire [NUM_HARTS*64-1:0] l1d_invalidate_addr;
    wire [NUM_HARTS-1:0] clear_reservation;
    wire probe_endpoint_protocol_error;
    logic [31:0] probe_accept_count [0:NUM_HARTS-1];
    logic [31:0] invalidate_count [0:NUM_HARTS-1];
    logic [31:0] invalidate_cycle [0:NUM_HARTS-1];

    // Directory to shared L2.
    wire l2_req_valid;
    wire l2_req_ready;
    wire [`OPENRV64_CCX_HART_ID_WIDTH-1:0] l2_req_hart_id;
    wire [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] l2_req_txn_id;
    wire [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] l2_req_source_id;
    wire [`OPENRV64_CCX_OP_WIDTH-1:0] l2_req_op;
    wire l2_req_lock;
    wire [`OPENRV64_CCX_ORDER_WIDTH-1:0] l2_req_order;
    wire [`OPENRV64_CCX_KIND_WIDTH-1:0] l2_req_kind;
    wire [`OPENRV64_CCX_ATTR_WIDTH-1:0] l2_req_attr;
    wire [2:0] l2_req_size;
    wire [63:0] l2_req_addr;
    wire [`OPENRV64_CCX_BURST_LEN_WIDTH-1:0] l2_req_burst_len;

    wire l2_wdata_valid;
    wire l2_wdata_ready;
    wire [`OPENRV64_CCX_HART_ID_WIDTH-1:0] l2_wdata_hart_id;
    wire [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] l2_wdata_txn_id;
    wire [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] l2_wdata_source_id;
    wire [`OPENRV64_CCX_BEAT_INDEX_WIDTH-1:0] l2_wdata_beat_index;
    wire l2_wdata_last;
    wire [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] l2_wdata;
    wire [`OPENRV64_CCX_LINE_STRB_WIDTH-1:0] l2_wstrb;

    wire l2_resp_valid;
    wire l2_resp_ready;
    wire [`OPENRV64_CCX_HART_ID_WIDTH-1:0] l2_resp_hart_id;
    wire [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] l2_resp_txn_id;
    wire [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] l2_resp_source_id;
    wire [`OPENRV64_CCX_BEAT_INDEX_WIDTH-1:0] l2_resp_beat_index;
    wire l2_resp_last;
    wire [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] l2_resp_rdata;
    wire l2_resp_error;
    wire l2_resp_sc_success;
    wire protocol_error;

    // Shared L2 to bounded-latency line memory.
    wire bus_req_valid;
    wire bus_req_ready;
    wire bus_req_write;
    wire [63:0] bus_req_addr;
    wire [2:0] bus_req_size;
    wire [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] bus_req_wdata;
    wire [`OPENRV64_CCX_LINE_STRB_WIDTH-1:0] bus_req_wstrb;
    wire bus_req_cacheable;
    logic bus_resp_valid;
    wire bus_resp_ready;
    logic [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] bus_resp_rdata;
    logic bus_resp_error;
    logic [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0]
        memory [0:MEMORY_LINES-1];
    logic memory_pending;
    logic memory_pending_write;
    logic [63:0] memory_pending_addr;
    integer memory_delay;
    integer memory_read_count;
    integer memory_write_count;
    integer l2_command_count;
    integer l2_write_count;
    integer last_l2_write_cycle;

    // Reference state is updated at the coherence-home write-data acceptance
    // point.  That is the single total order exposed by this serialized home.
    logic [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0]
        reference_memory [0:MEMORY_LINES-1];
    logic expected_home_write_valid [0:NUM_HARTS-1];
    logic [63:0] expected_home_write_addr [0:NUM_HARTS-1];
    logic [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0]
        expected_home_write_data [0:NUM_HARTS-1];
    logic [`OPENRV64_CCX_LINE_STRB_WIDTH-1:0]
        expected_home_write_strb [0:NUM_HARTS-1];
    logic home_write_active;
    integer home_write_hart;
    logic [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] home_write_txn_id;
    logic [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] home_write_source_id;
    logic l2_read_expected_valid;
    logic [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0]
        l2_read_expected_data;
    logic [63:0] l2_read_expected_addr;
    integer home_score_hart;
    integer home_score_byte;

    // Request tags form the second scoreboard.  It checks each response
    // against the accepted request, independent of task scheduling order.
    logic tag_pending [0:NUM_HARTS-1][0:TAG_COUNT-1];
    logic tag_pending_posted [0:NUM_HARTS-1][0:TAG_COUNT-1];
    logic tag_pending_write [0:NUM_HARTS-1][0:TAG_COUNT-1];
    logic [63:0] tag_pending_addr [0:NUM_HARTS-1][0:TAG_COUNT-1];
    logic [63:0] tag_pending_read_data
        [0:NUM_HARTS-1][0:TAG_COUNT-1];
    integer request_sent_count [0:NUM_HARTS-1];
    integer response_received_count [0:NUM_HARTS-1];
    integer score_hart;
    integer score_tag;
    integer score_word;

    logic [31:0] random_state;
    logic [8:0] planned_line [0:NUM_HARTS-1];
    logic [2:0] planned_word [0:NUM_HARTS-1];
    logic planned_write [0:NUM_HARTS-1];
    logic [63:0] planned_addr [0:NUM_HARTS-1];
    logic [63:0] planned_data [0:NUM_HARTS-1];
    logic [63:0] planned_expected [0:NUM_HARTS-1];
    integer random_round;
    integer random_hart;
    integer random_prior_hart;
    integer random_seed;
    integer random_line_unique;
    integer random_store_hart;
    integer random_store_count;
    integer atomic_sequence;
    logic [NUM_HARTS-1:0] planned_store_mask;
    logic [63:0] atomic_random_addr;
    logic [63:0] atomic_random_operand;
    integer atomic_sc_success_count;
    integer atomic_lr_command_count;
    integer atomic_sc_command_count;
    integer standalone_lr_count;
    integer pingpong_line;
    integer pingpong_hart;
    logic [63:0] pingpong_addr;
    logic [63:0] pingpong_data [0:NUM_HARTS-1];
    logic contention_monitor_active;
    logic [63:0] contention_monitor_line;
    integer contention_expected_hart;
    integer contention_grant_count;

    function automatic [63:0] initial_memory_word;
        input [63:0] address;
        begin
            initial_memory_word =
                address ^ 64'h4c32_4449_5245_4354;
        end
    endfunction

    function automatic integer line_index;
        input [63:0] address;
        begin
            line_index = address[14:6];
        end
    endfunction

    function automatic [31:0] xorshift32;
        input [31:0] value;
        reg [31:0] next_value;
        begin
            next_value = value;
            next_value = next_value ^ (next_value << 13);
            next_value = next_value ^ (next_value >> 17);
            next_value = next_value ^ (next_value << 5);
            xorshift32 = next_value;
        end
    endfunction

    function automatic [63:0] amo_result;
        input [`RV64_LSU_OP_WIDTH-1:0] op;
        input [63:0] old_value;
        input [63:0] operand;
        begin
            case (op)
                `RV64_LSU_OP_AMOSWAP: amo_result = operand;
                `RV64_LSU_OP_AMOADD:  amo_result = old_value + operand;
                `RV64_LSU_OP_AMOXOR:  amo_result = old_value ^ operand;
                `RV64_LSU_OP_AMOAND:  amo_result = old_value & operand;
                `RV64_LSU_OP_AMOOR:   amo_result = old_value | operand;
                `RV64_LSU_OP_AMOMIN:  amo_result =
                    ($signed(old_value) < $signed(operand)) ?
                        old_value : operand;
                `RV64_LSU_OP_AMOMAX:  amo_result =
                    ($signed(old_value) > $signed(operand)) ?
                        old_value : operand;
                `RV64_LSU_OP_AMOMINU: amo_result =
                    (old_value < operand) ? old_value : operand;
                `RV64_LSU_OP_AMOMAXU: amo_result =
                    (old_value > operand) ? old_value : operand;
                default: amo_result = 64'd0;
            endcase
        end
    endfunction

    genvar hart;
    generate
        for (hart = 0; hart < NUM_HARTS; hart = hart + 1) begin : g_l1d
            assign cache_req_valid[hart] = atomic_select[hart] ?
                (atomic_mem_valid[hart] &&
                 !atomic_mem_inflight[hart]) :
                lsu_req_valid[hart];
            assign cache_req_tag[hart*TAG_WIDTH +: TAG_WIDTH] =
                atomic_select[hart] ?
                    atomic_tag[hart*TAG_WIDTH +: TAG_WIDTH] :
                    lsu_req_tag[hart*TAG_WIDTH +: TAG_WIDTH];
            assign cache_req_lock[hart] = atomic_select[hart] ?
                atomic_mem_lock[hart] : lsu_req_lock[hart];
            assign cache_req_posted[hart] =
                !atomic_select[hart] && lsu_req_write[hart] &&
                !lsu_req_lock[hart];
            assign cache_req_write[hart] = atomic_select[hart] ?
                atomic_mem_write[hart] : lsu_req_write[hart];
            assign cache_req_addr[hart*64 +: 64] =
                atomic_select[hart] ?
                    atomic_mem_addr[hart*64 +: 64] :
                    lsu_req_addr[hart*64 +: 64];
            assign cache_req_wdata[hart*64 +: 64] =
                atomic_select[hart] ?
                    atomic_mem_wdata[hart*64 +: 64] :
                    lsu_req_wdata[hart*64 +: 64];
            assign cache_req_wstrb[hart*8 +: 8] =
                atomic_select[hart] ?
                    atomic_mem_wstrb[hart*8 +: 8] :
                    lsu_req_wstrb[hart*8 +: 8];
            assign atomic_state_debug[hart*3 +: 3] =
                u_atomic_lsu.state_q;
            assign l1d_backend_state_debug[hart*2 +: 2] =
                u_l1d.backend_state_q;

            openrv64_exec_lsu_rv64a #(
                .SC_STATUS_IN_RDATA(1),
                .COHERENT_RESERVATIONS(1)
            ) u_atomic_lsu (
                .clk(clk),
                .rst_n(rst_n),
                .flush_i(1'b0),
                .valid_i(atomic_valid[hart]),
                .consume_i(atomic_consume[hart]),
                .clear_reservation_i(clear_reservation[hart]),
                .op_sel_i(
                    atomic_op[
                        hart*`RV64_LSU_OP_WIDTH +:
                        `RV64_LSU_OP_WIDTH]),
                .size_sel_i(
                    atomic_size[
                        hart*`RV64_LSU_SIZE_WIDTH +:
                        `RV64_LSU_SIZE_WIDTH]),
                .addr_i(atomic_addr[hart*64 +: 64]),
                .store_data_i(atomic_operand[hart*64 +: 64]),
                .mem_ready_i(
                    atomic_select[hart] &&
                    atomic_mem_inflight[hart] &&
                    lsu_resp_valid[hart]),
                .mem_error_i(lsu_req_error[hart]),
                .mem_page_fault_i(1'b0),
                .mem_access_allowed_i(1'b1),
                .mem_rdata_i(lsu_req_rdata[hart*64 +: 64]),
                .complete_o(atomic_complete[hart]),
                .illegal_o(atomic_illegal[hart]),
                .misaligned_o(atomic_misaligned[hart]),
                .access_fault_o(atomic_access_fault[hart]),
                .page_fault_o(atomic_page_fault[hart]),
                .result_o(atomic_result[hart*64 +: 64]),
                .mem_valid_o(atomic_mem_valid[hart]),
                .mem_lock_o(atomic_mem_lock[hart]),
                .mem_write_o(atomic_mem_write[hart]),
                .mem_addr_o(atomic_mem_addr[hart*64 +: 64]),
                .mem_wdata_o(atomic_mem_wdata[hart*64 +: 64]),
                .mem_wstrb_o(atomic_mem_wstrb[hart*8 +: 8])
            );

            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    atomic_mem_inflight[hart] <= 1'b0;
                end else begin
                    if (cache_req_valid[hart] &&
                        lsu_req_ready[hart] &&
                        atomic_select[hart])
                        atomic_mem_inflight[hart] <= 1'b1;
                    if (atomic_select[hart] &&
                        atomic_mem_inflight[hart] &&
                        lsu_resp_valid[hart])
                        atomic_mem_inflight[hart] <= 1'b0;
                end
            end

            openrv64_l1d_ccx #(
                .ENABLE(1),
                .CACHE_BYTES(1024),
                .LINE_BYTES(64),
                .WAYS(2),
                .FILL_BUFFER_LINES(4),
                .DEMAND_MSHRS(2),
                .STORE_BUFFER_LINES(2),
                .STORE_BUFFER_DRAIN_WATERMARK(2),
                .STORE_BUFFER_TIMEOUT_CYCLES(16384),
                .PREFETCH_ENABLE(0),
                .COHERENT_ATOMICS(1),
                .REQ_TAG_WIDTH(TAG_WIDTH),
                .REQ_DEPTH(1 << TAG_WIDTH),
                .HART_ID(`OPENRV64_CCX_HART_ID_WIDTH'(hart))
            ) u_l1d (
                .clk_i(clk),
                .rst_ni(rst_n),
                .req_valid_i(cache_req_valid[hart]),
                .req_ready_o(lsu_req_ready[hart]),
                .req_tag_i(
                    cache_req_tag[hart*TAG_WIDTH +: TAG_WIDTH]),
                .req_lock_i(cache_req_lock[hart]),
                .req_posted_i(cache_req_posted[hart]),
                .req_write_i(cache_req_write[hart]),
                .req_cacheable_i(1'b1),
                .req_addr_i(cache_req_addr[hart*64 +: 64]),
                .req_size_i(3'd3),
                .req_wdata_i(cache_req_wdata[hart*64 +: 64]),
                .req_wstrb_i(cache_req_wstrb[hart*8 +: 8]),
                .req_rdata_o(lsu_req_rdata[hart*64 +: 64]),
                .req_error_o(lsu_req_error[hart]),
                .resp_valid_o(lsu_resp_valid[hart]),
                .resp_ready_i(1'b1),
                .resp_tag_o(lsu_resp_tag[hart*TAG_WIDTH +: TAG_WIDTH]),
                .posted_resp_valid_o(lsu_posted_resp_valid[hart]),
                .posted_resp_ready_i(1'b1),
                .posted_resp_tag_o(
                    lsu_posted_resp_tag[hart*TAG_WIDTH +: TAG_WIDTH]),
                .store_resp_valid_o(lsu_store_resp_valid[hart]),
                .store_resp_ready_i(1'b1),
                .store_resp_error_o(lsu_store_resp_error[hart]),
                .prefetch_issued_o(),
                .prefetch_useful_o(),
                .prefetch_late_o(),
                .prefetch_dropped_o(),
                .prefetch_useless_o(),
                .prefetch_depth_o(),
                .speculation_barrier_i(speculation_barrier[hart]),
                .store_barrier_busy_o(store_barrier_busy[hart]),
                .invalidate_valid_i(l1d_invalidate_valid[hart]),
                .invalidate_ready_o(l1d_invalidate_ready[hart]),
                .invalidate_all_i(1'b0),
                .invalidate_addr_i(
                    l1d_invalidate_addr[hart*64 +: 64]),
                .ccx_req_valid_o(hart_req_valid[hart]),
                .ccx_req_ready_i(hart_req_ready[hart]),
                .ccx_req_hart_id_o(
                    hart_req_hart_id[
                        hart*`OPENRV64_CCX_HART_ID_WIDTH +:
                        `OPENRV64_CCX_HART_ID_WIDTH]),
                .ccx_req_txn_id_o(
                    hart_req_txn_id[
                        hart*`OPENRV64_CCX_TXN_ID_WIDTH +:
                        `OPENRV64_CCX_TXN_ID_WIDTH]),
                .ccx_req_source_id_o(
                    hart_req_source_id[
                        hart*`OPENRV64_CCX_SOURCE_ID_WIDTH +:
                        `OPENRV64_CCX_SOURCE_ID_WIDTH]),
                .ccx_req_op_o(
                    hart_req_op[
                        hart*`OPENRV64_CCX_OP_WIDTH +:
                        `OPENRV64_CCX_OP_WIDTH]),
                .ccx_req_lock_o(hart_req_lock[hart]),
                .ccx_req_order_o(
                    hart_req_order[
                        hart*`OPENRV64_CCX_ORDER_WIDTH +:
                        `OPENRV64_CCX_ORDER_WIDTH]),
                .ccx_req_kind_o(
                    hart_req_kind[
                        hart*`OPENRV64_CCX_KIND_WIDTH +:
                        `OPENRV64_CCX_KIND_WIDTH]),
                .ccx_req_attr_o(
                    hart_req_attr[
                        hart*`OPENRV64_CCX_ATTR_WIDTH +:
                        `OPENRV64_CCX_ATTR_WIDTH]),
                .ccx_req_size_o(hart_req_size[hart*3 +: 3]),
                .ccx_req_addr_o(hart_req_addr[hart*64 +: 64]),
                .ccx_req_burst_len_o(
                    hart_req_burst_len[
                        hart*`OPENRV64_CCX_BURST_LEN_WIDTH +:
                        `OPENRV64_CCX_BURST_LEN_WIDTH]),
                .ccx_wdata_valid_o(hart_wdata_valid[hart]),
                .ccx_wdata_ready_i(hart_wdata_ready[hart]),
                .ccx_wdata_hart_id_o(
                    hart_wdata_hart_id[
                        hart*`OPENRV64_CCX_HART_ID_WIDTH +:
                        `OPENRV64_CCX_HART_ID_WIDTH]),
                .ccx_wdata_txn_id_o(
                    hart_wdata_txn_id[
                        hart*`OPENRV64_CCX_TXN_ID_WIDTH +:
                        `OPENRV64_CCX_TXN_ID_WIDTH]),
                .ccx_wdata_source_id_o(
                    hart_wdata_source_id[
                        hart*`OPENRV64_CCX_SOURCE_ID_WIDTH +:
                        `OPENRV64_CCX_SOURCE_ID_WIDTH]),
                .ccx_wdata_beat_index_o(
                    hart_wdata_beat_index[
                        hart*`OPENRV64_CCX_BEAT_INDEX_WIDTH +:
                        `OPENRV64_CCX_BEAT_INDEX_WIDTH]),
                .ccx_wdata_last_o(hart_wdata_last[hart]),
                .ccx_wdata_o(
                    hart_wdata[
                        hart*`OPENRV64_CCX_LINE_DATA_WIDTH +:
                        `OPENRV64_CCX_LINE_DATA_WIDTH]),
                .ccx_wstrb_o(
                    hart_wstrb[
                        hart*`OPENRV64_CCX_LINE_STRB_WIDTH +:
                        `OPENRV64_CCX_LINE_STRB_WIDTH]),
                .ccx_resp_valid_i(hart_resp_valid[hart]),
                .ccx_resp_ready_o(hart_resp_ready[hart]),
                .ccx_resp_hart_id_i(
                    hart_resp_hart_id[
                        hart*`OPENRV64_CCX_HART_ID_WIDTH +:
                        `OPENRV64_CCX_HART_ID_WIDTH]),
                .ccx_resp_txn_id_i(
                    hart_resp_txn_id[
                        hart*`OPENRV64_CCX_TXN_ID_WIDTH +:
                        `OPENRV64_CCX_TXN_ID_WIDTH]),
                .ccx_resp_source_id_i(
                    hart_resp_source_id[
                        hart*`OPENRV64_CCX_SOURCE_ID_WIDTH +:
                        `OPENRV64_CCX_SOURCE_ID_WIDTH]),
                .ccx_resp_beat_index_i(
                    hart_resp_beat_index[
                        hart*`OPENRV64_CCX_BEAT_INDEX_WIDTH +:
                        `OPENRV64_CCX_BEAT_INDEX_WIDTH]),
                .ccx_resp_last_i(hart_resp_last[hart]),
                .ccx_resp_rdata_i(
                    hart_resp_rdata[
                        hart*`OPENRV64_CCX_LINE_DATA_WIDTH +:
                        `OPENRV64_CCX_LINE_DATA_WIDTH]),
                .ccx_resp_error_i(hart_resp_error[hart]),
                .ccx_resp_sc_success_i(hart_resp_sc_success[hart])
            );
        end
    endgenerate

    openrv64_ccx_line_crossbar #(
        .NUM_HARTS(NUM_HARTS),
        .HART_ID_BASE(0)
    ) u_crossbar (
        .clk_i(clk),
        .rst_ni(rst_n),
        .hart_req_valid_i(hart_req_valid),
        .hart_req_ready_o(hart_req_ready),
        .hart_req_hart_id_i(hart_req_hart_id),
        .hart_req_txn_id_i(hart_req_txn_id),
        .hart_req_source_id_i(hart_req_source_id),
        .hart_req_op_i(hart_req_op),
        .hart_req_lock_i(hart_req_lock),
        .hart_req_order_i(hart_req_order),
        .hart_req_kind_i(hart_req_kind),
        .hart_req_attr_i(hart_req_attr),
        .hart_req_size_i(hart_req_size),
        .hart_req_addr_i(hart_req_addr),
        .hart_req_burst_len_i(hart_req_burst_len),
        .mem_req_valid_o(ccx_req_valid),
        .mem_req_ready_i(ccx_req_ready),
        .mem_req_hart_id_o(ccx_req_hart_id),
        .mem_req_txn_id_o(ccx_req_txn_id),
        .mem_req_source_id_o(ccx_req_source_id),
        .mem_req_op_o(ccx_req_op),
        .mem_req_lock_o(ccx_req_lock),
        .mem_req_order_o(ccx_req_order),
        .mem_req_kind_o(ccx_req_kind),
        .mem_req_attr_o(ccx_req_attr),
        .mem_req_size_o(ccx_req_size),
        .mem_req_addr_o(ccx_req_addr),
        .mem_req_burst_len_o(ccx_req_burst_len),
        .hart_wdata_valid_i(hart_wdata_valid),
        .hart_wdata_ready_o(hart_wdata_ready),
        .hart_wdata_hart_id_i(hart_wdata_hart_id),
        .hart_wdata_txn_id_i(hart_wdata_txn_id),
        .hart_wdata_source_id_i(hart_wdata_source_id),
        .hart_wdata_beat_index_i(hart_wdata_beat_index),
        .hart_wdata_last_i(hart_wdata_last),
        .hart_wdata_i(hart_wdata),
        .hart_wstrb_i(hart_wstrb),
        .mem_wdata_valid_o(ccx_wdata_valid),
        .mem_wdata_ready_i(ccx_wdata_ready),
        .mem_wdata_hart_id_o(ccx_wdata_hart_id),
        .mem_wdata_txn_id_o(ccx_wdata_txn_id),
        .mem_wdata_source_id_o(ccx_wdata_source_id),
        .mem_wdata_beat_index_o(ccx_wdata_beat_index),
        .mem_wdata_last_o(ccx_wdata_last),
        .mem_wdata_o(ccx_wdata),
        .mem_wstrb_o(ccx_wstrb),
        .mem_resp_valid_i(ccx_resp_valid),
        .mem_resp_ready_o(ccx_resp_ready),
        .mem_resp_hart_id_i(ccx_resp_hart_id),
        .mem_resp_txn_id_i(ccx_resp_txn_id),
        .mem_resp_source_id_i(ccx_resp_source_id),
        .mem_resp_beat_index_i(ccx_resp_beat_index),
        .mem_resp_last_i(ccx_resp_last),
        .mem_resp_rdata_i(ccx_resp_rdata),
        .mem_resp_error_i(ccx_resp_error),
        .mem_resp_sc_success_i(ccx_resp_sc_success),
        .hart_resp_valid_o(hart_resp_valid),
        .hart_resp_ready_i(hart_resp_ready),
        .hart_resp_hart_id_o(hart_resp_hart_id),
        .hart_resp_txn_id_o(hart_resp_txn_id),
        .hart_resp_source_id_o(hart_resp_source_id),
        .hart_resp_beat_index_o(hart_resp_beat_index),
        .hart_resp_last_o(hart_resp_last),
        .hart_resp_rdata_o(hart_resp_rdata),
        .hart_resp_error_o(hart_resp_error),
        .hart_resp_sc_success_o(hart_resp_sc_success)
    );

    openrv64_ccx_coherent_protocol #(
        .NUM_HARTS(NUM_HARTS),
        .HART_ID_BASE(0),
        .DIRECTORY_ENTRIES(MEMORY_LINES),
        .DIRECTORY_WAYS(4)
    ) u_directory_frontend (
        .clk_i(clk),
        .rst_ni(rst_n),
        .req_valid_i(ccx_req_valid),
        .req_ready_o(ccx_req_ready),
        .req_hart_id_i(ccx_req_hart_id),
        .req_txn_id_i(ccx_req_txn_id),
        .req_source_id_i(ccx_req_source_id),
        .req_op_i(ccx_req_op),
        .req_lock_i(ccx_req_lock),
        .req_order_i(ccx_req_order),
        .req_kind_i(ccx_req_kind),
        .req_attr_i(ccx_req_attr),
        .req_size_i(ccx_req_size),
        .req_addr_i(ccx_req_addr),
        .req_burst_len_i(ccx_req_burst_len),
        .wdata_valid_i(ccx_wdata_valid),
        .wdata_ready_o(ccx_wdata_ready),
        .wdata_hart_id_i(ccx_wdata_hart_id),
        .wdata_txn_id_i(ccx_wdata_txn_id),
        .wdata_source_id_i(ccx_wdata_source_id),
        .wdata_beat_index_i(ccx_wdata_beat_index),
        .wdata_last_i(ccx_wdata_last),
        .wdata_i(ccx_wdata),
        .wstrb_i(ccx_wstrb),
        .resp_valid_o(ccx_resp_valid),
        .resp_ready_i(ccx_resp_ready),
        .resp_hart_id_o(ccx_resp_hart_id),
        .resp_txn_id_o(ccx_resp_txn_id),
        .resp_source_id_o(ccx_resp_source_id),
        .resp_beat_index_o(ccx_resp_beat_index),
        .resp_last_o(ccx_resp_last),
        .resp_rdata_o(ccx_resp_rdata),
        .resp_error_o(ccx_resp_error),
        .resp_sc_success_o(ccx_resp_sc_success),
        .probe_valid_o(probe_valid),
        .probe_ready_i(probe_ready),
        .probe_id_o(probe_id),
        .probe_command_o(probe_command),
        .probe_cache_mask_o(probe_cache_mask),
        .probe_line_addr_o(probe_line_addr),
        .probe_resp_valid_i(probe_resp_valid),
        .probe_resp_ready_o(probe_resp_ready),
        .probe_resp_id_i(probe_resp_id),
        .probe_resp_kind_i(probe_resp_kind),
        .probe_resp_data_i(probe_resp_data),
        .probe_resp_error_i(probe_resp_error),
        .l2_req_valid_o(l2_req_valid),
        .l2_req_ready_i(l2_req_ready),
        .l2_req_hart_id_o(l2_req_hart_id),
        .l2_req_txn_id_o(l2_req_txn_id),
        .l2_req_source_id_o(l2_req_source_id),
        .l2_req_op_o(l2_req_op),
        .l2_req_lock_o(l2_req_lock),
        .l2_req_order_o(l2_req_order),
        .l2_req_kind_o(l2_req_kind),
        .l2_req_attr_o(l2_req_attr),
        .l2_req_size_o(l2_req_size),
        .l2_req_addr_o(l2_req_addr),
        .l2_req_burst_len_o(l2_req_burst_len),
        .l2_wdata_valid_o(l2_wdata_valid),
        .l2_wdata_ready_i(l2_wdata_ready),
        .l2_wdata_hart_id_o(l2_wdata_hart_id),
        .l2_wdata_txn_id_o(l2_wdata_txn_id),
        .l2_wdata_source_id_o(l2_wdata_source_id),
        .l2_wdata_beat_index_o(l2_wdata_beat_index),
        .l2_wdata_last_o(l2_wdata_last),
        .l2_wdata_o(l2_wdata),
        .l2_wstrb_o(l2_wstrb),
        .l2_resp_valid_i(l2_resp_valid),
        .l2_resp_ready_o(l2_resp_ready),
        .l2_resp_hart_id_i(l2_resp_hart_id),
        .l2_resp_txn_id_i(l2_resp_txn_id),
        .l2_resp_source_id_i(l2_resp_source_id),
        .l2_resp_beat_index_i(l2_resp_beat_index),
        .l2_resp_last_i(l2_resp_last),
        .l2_resp_rdata_i(l2_resp_rdata),
        .l2_resp_error_i(l2_resp_error),
        .l2_resp_sc_success_i(l2_resp_sc_success),
        .protocol_error_clear_i(1'b0),
        .protocol_error_o(protocol_error)
    );

    openrv64_ccx_l2_native #(
        .CACHE_BYTES(256 * 1024),
        .LINE_BYTES(64),
        .WAYS(4),
        .MSHR_ENTRIES(2),
        .WAITERS_PER_MSHR(4),
        .COMMAND_ENTRIES(4),
        .RESPONSE_ENTRIES(8),
        .BUS_TRACK_ENTRIES(2)
    ) u_l2 (
        .clk_i(clk),
        .rst_ni(rst_n),
        .req_valid_i(l2_req_valid),
        .req_ready_o(l2_req_ready),
        .req_hart_id_i(l2_req_hart_id),
        .req_txn_id_i(l2_req_txn_id),
        .req_source_id_i(l2_req_source_id),
        .req_op_i(l2_req_op),
        .req_lock_i(l2_req_lock),
        .req_order_i(l2_req_order),
        .req_kind_i(l2_req_kind),
        .req_attr_i(l2_req_attr),
        .req_size_i(l2_req_size),
        .req_addr_i(l2_req_addr),
        .req_burst_len_i(l2_req_burst_len),
        .wdata_valid_i(l2_wdata_valid),
        .wdata_ready_o(l2_wdata_ready),
        .wdata_hart_id_i(l2_wdata_hart_id),
        .wdata_txn_id_i(l2_wdata_txn_id),
        .wdata_source_id_i(l2_wdata_source_id),
        .wdata_beat_index_i(l2_wdata_beat_index),
        .wdata_last_i(l2_wdata_last),
        .wdata_i(l2_wdata),
        .wstrb_i(l2_wstrb),
        .resp_valid_o(l2_resp_valid),
        .resp_ready_i(l2_resp_ready),
        .resp_hart_id_o(l2_resp_hart_id),
        .resp_txn_id_o(l2_resp_txn_id),
        .resp_source_id_o(l2_resp_source_id),
        .resp_beat_index_o(l2_resp_beat_index),
        .resp_last_o(l2_resp_last),
        .resp_rdata_o(l2_resp_rdata),
        .resp_error_o(l2_resp_error),
        .resp_sc_success_o(l2_resp_sc_success),
        .bus_req_valid_o(bus_req_valid),
        .bus_req_ready_i(bus_req_ready),
        .bus_req_write_o(bus_req_write),
        .bus_req_addr_o(bus_req_addr),
        .bus_req_size_o(bus_req_size),
        .bus_req_wdata_o(bus_req_wdata),
        .bus_req_wstrb_o(bus_req_wstrb),
        .bus_req_cacheable_o(bus_req_cacheable),
        .bus_resp_valid_i(bus_resp_valid),
        .bus_resp_ready_o(bus_resp_ready),
        .bus_resp_rdata_i(bus_resp_rdata),
        .bus_resp_error_i(bus_resp_error)
    );

    // Production four-hart probe termination.  Each endpoint owns independent
    // request/response storage and clears the local LR reservation as soon as
    // a D-cache invalidate is accepted.
    openrv64_ccx_4h_l1d_probe_cluster #(
        .PROBE_TIMEOUT_CYCLES(4096)
    ) u_probe_cluster (
        .clk_i(clk),
        .rst_ni(rst_n),
        .probe_valid_i(probe_valid),
        .probe_ready_o(probe_ready),
        .probe_id_i(probe_id),
        .probe_command_i(probe_command),
        .probe_cache_mask_i(probe_cache_mask),
        .probe_line_addr_i(probe_line_addr),
        .probe_resp_valid_o(probe_resp_valid),
        .probe_resp_ready_i(probe_resp_ready),
        .probe_resp_id_o(probe_resp_id),
        .probe_resp_kind_o(probe_resp_kind),
        .probe_resp_data_o(probe_resp_data),
        .probe_resp_error_o(probe_resp_error),
        .l1d_invalidate_valid_o(l1d_invalidate_valid),
        .l1d_invalidate_ready_i(l1d_invalidate_ready),
        .l1d_invalidate_addr_o(l1d_invalidate_addr),
        .clear_reservation_o(clear_reservation),
        .protocol_error_clear_i(1'b0),
        .protocol_error_o(probe_endpoint_protocol_error)
    );

    // Probe accounting remains test-only observability.
    generate
        for (hart = 0; hart < NUM_HARTS; hart = hart + 1) begin : g_probe
            wire probe_fire = probe_valid[hart] && probe_ready[hart];
            wire invalidate_fire =
                l1d_invalidate_valid[hart] &&
                l1d_invalidate_ready[hart];

            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    probe_accept_count[hart] <= 32'd0;
                    invalidate_count[hart] <= 32'd0;
                    invalidate_cycle[hart] <= 32'd0;
                end else begin
                    if (probe_fire)
                        probe_accept_count[hart] <=
                            probe_accept_count[hart] + 1'b1;

                    if (invalidate_fire) begin
                        invalidate_count[hart] <=
                            invalidate_count[hart] + 1'b1;
                        invalidate_cycle[hart] <= cycle_count;
                    end
                end
            end
        end
    endgenerate

    assign bus_req_ready = !memory_pending && !bus_resp_valid;

    // One-outstanding, fixed-latency backing store.  This is intentionally not
    // a DDR timing model; the integration boundary under test ends at L2.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            memory_pending <= 1'b0;
            memory_pending_write <= 1'b0;
            memory_pending_addr <= 64'd0;
            memory_delay <= 0;
            bus_resp_valid <= 1'b0;
            bus_resp_rdata <=
                {`OPENRV64_CCX_LINE_DATA_WIDTH{1'b0}};
            bus_resp_error <= 1'b0;
            memory_read_count <= 0;
            memory_write_count <= 0;
        end else begin
            if (bus_resp_valid && bus_resp_ready)
                bus_resp_valid <= 1'b0;

            if (bus_req_valid && bus_req_ready) begin
                if ((bus_req_size != 3'd6) ||
                    (bus_req_addr[5:0] != 6'd0) ||
                    !bus_req_cacheable)
                    $fatal(1, "malformed L2 memory request");
                memory_pending <= 1'b1;
                memory_pending_write <= bus_req_write;
                memory_pending_addr <= bus_req_addr;
                memory_delay <= MEMORY_LATENCY - 1;
                if (bus_req_write) begin
                    memory_write_count <= memory_write_count + 1;
                    for (memory_byte_index = 0;
                         memory_byte_index <
                             `OPENRV64_CCX_LINE_STRB_WIDTH;
                         memory_byte_index =
                             memory_byte_index + 1)
                        if (bus_req_wstrb[memory_byte_index])
                            memory[line_index(bus_req_addr)][
                                memory_byte_index*8 +: 8] <=
                                bus_req_wdata[
                                    memory_byte_index*8 +: 8];
                end else begin
                    memory_read_count <= memory_read_count + 1;
                end
            end else if (memory_pending) begin
                if (memory_delay == 0) begin
                    memory_pending <= 1'b0;
                    bus_resp_valid <= 1'b1;
                    bus_resp_rdata <= memory_pending_write ?
                        {`OPENRV64_CCX_LINE_DATA_WIDTH{1'b0}} :
                        memory[line_index(memory_pending_addr)];
                end else begin
                    memory_delay <= memory_delay - 1;
                end
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            l2_command_count <= 0;
            l2_write_count <= 0;
            last_l2_write_cycle <= -1;
        end else if (l2_req_valid && l2_req_ready) begin
            l2_command_count <= l2_command_count + 1;
            if (l2_req_op == `OPENRV64_CCX_OP_WRITE) begin
                l2_write_count <= l2_write_count + 1;
                last_l2_write_cycle <= cycle_count;
            end
        end
    end

    // Verify the exact command/data stream received by the coherence home.
    // Reference writes are applied in l2_wdata acceptance order, not in the
    // order in which the four stimulus tasks happened to start.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            home_write_active <= 1'b0;
            home_write_hart <= 0;
            home_write_txn_id <=
                {`OPENRV64_CCX_TXN_ID_WIDTH{1'b0}};
            home_write_source_id <=
                {`OPENRV64_CCX_SOURCE_ID_WIDTH{1'b0}};
            l2_read_expected_valid <= 1'b0;
            l2_read_expected_data <=
                {`OPENRV64_CCX_LINE_DATA_WIDTH{1'b0}};
            l2_read_expected_addr <= 64'd0;
            atomic_sc_success_count <= 0;
            atomic_lr_command_count <= 0;
            atomic_sc_command_count <= 0;
            for (home_score_hart = 0;
                 home_score_hart < NUM_HARTS;
                 home_score_hart = home_score_hart + 1) begin
                expected_home_write_valid[home_score_hart] <= 1'b0;
                expected_home_write_addr[home_score_hart] <= 64'd0;
                expected_home_write_data[home_score_hart] <=
                    {`OPENRV64_CCX_LINE_DATA_WIDTH{1'b0}};
                expected_home_write_strb[home_score_hart] <=
                    {`OPENRV64_CCX_LINE_STRB_WIDTH{1'b0}};
            end
        end else begin
            if (ccx_req_valid && ccx_req_ready) begin
                if (ccx_req_lock)
                    $fatal(1,
                        "fabric lock asserted instead of LR/SC opcode");
                if (ccx_req_op == `OPENRV64_CCX_OP_LR)
                    atomic_lr_command_count <=
                        atomic_lr_command_count + 1;
                if (ccx_req_op == `OPENRV64_CCX_OP_SC)
                    atomic_sc_command_count <=
                        atomic_sc_command_count + 1;
            end

            if (ccx_resp_valid && ccx_resp_ready &&
                (u_directory_frontend.req_op_q ==
                 `OPENRV64_CCX_OP_SC)) begin
                if (!ccx_resp_sc_success)
                    $fatal(1,
                        "guarded AMO reached a failed home SC");
                atomic_sc_success_count <=
                    atomic_sc_success_count + 1;
            end

            if (l2_req_valid && l2_req_ready) begin
                if ((l2_req_addr < MEMORY_BASE) ||
                    (l2_req_addr >=
                     (MEMORY_BASE + MEMORY_LINES*64)))
                    $fatal(1, "L2 request outside stress window addr=%016x",
                           l2_req_addr);
                if (l2_req_op == `OPENRV64_CCX_OP_WRITE) begin
                    home_score_hart = l2_req_hart_id;
                    if ((home_score_hart < 0) ||
                        (home_score_hart >= NUM_HARTS))
                        $fatal(1, "home write has invalid hart %0d",
                               home_score_hart);
                    if (home_write_active)
                        $fatal(1, "overlapping serialized home writes");
                    if (!expected_home_write_valid[home_score_hart])
                        $fatal(1,
                            "unexpected home write hart=%0d addr=%016x",
                            home_score_hart, l2_req_addr);
                    if ({l2_req_addr[63:6], 6'b0} !==
                        expected_home_write_addr[home_score_hart])
                        $fatal(1,
                            "home write order/address mismatch hart=%0d got=%016x expected=%016x",
                            home_score_hart, l2_req_addr,
                            expected_home_write_addr[home_score_hart]);
                    home_write_active <= 1'b1;
                    home_write_hart <= home_score_hart;
                    home_write_txn_id <= l2_req_txn_id;
                    home_write_source_id <= l2_req_source_id;
                end else if (l2_req_op == `OPENRV64_CCX_OP_READ) begin
                    if (l2_read_expected_valid)
                        $fatal(1, "overlapping serialized home reads");
                    l2_read_expected_valid <= 1'b1;
                    l2_read_expected_addr <=
                        {l2_req_addr[63:6], 6'b0};
                    if (l2_req_size == 3'd6)
                        l2_read_expected_data <=
                            reference_memory[line_index(l2_req_addr)];
                    else
                        l2_read_expected_data <=
                            ({{448{1'b0}},
                              reference_memory[
                                  line_index(l2_req_addr)][
                                  l2_req_addr[5:3]*64 +: 64]} <<
                             (l2_req_addr[5:3]*64));
                end
            end

            if (l2_wdata_valid && l2_wdata_ready) begin
                if (!home_write_active)
                    $fatal(1, "home write data arrived without command");
                if ((l2_wdata_hart_id != home_write_hart) ||
                    (l2_wdata_txn_id != home_write_txn_id) ||
                    (l2_wdata_source_id != home_write_source_id) ||
                    (l2_wdata_beat_index !=
                     {`OPENRV64_CCX_BEAT_INDEX_WIDTH{1'b0}}) ||
                    !l2_wdata_last)
                    $fatal(1, "home write data identity mismatch");
                if (l2_wdata !==
                    expected_home_write_data[home_write_hart])
                    $fatal(1,
                        "home write payload mismatch hart=%0d",
                        home_write_hart);
                if (l2_wstrb !==
                    expected_home_write_strb[home_write_hart])
                    $fatal(1,
                        "home write strobe mismatch hart=%0d got=%016x expected=%016x",
                        home_write_hart, l2_wstrb,
                        expected_home_write_strb[home_write_hart]);
                for (home_score_byte = 0;
                     home_score_byte <
                         `OPENRV64_CCX_LINE_STRB_WIDTH;
                     home_score_byte = home_score_byte + 1)
                    if (l2_wstrb[home_score_byte])
                        reference_memory[
                            line_index(
                                expected_home_write_addr[
                                    home_write_hart])][
                            home_score_byte*8 +: 8] <=
                            l2_wdata[home_score_byte*8 +: 8];
                expected_home_write_valid[home_write_hart] <= 1'b0;
                home_write_active <= 1'b0;
            end

            if (l2_resp_valid && l2_resp_ready &&
                l2_read_expected_valid) begin
                if (l2_resp_error ||
                    (l2_resp_rdata !== l2_read_expected_data))
                    $fatal(1,
                        "home read data mismatch addr=%016x error=%0b got=%0128x expected=%0128x",
                        l2_read_expected_addr, l2_resp_error,
                        l2_resp_rdata, l2_read_expected_data);
                l2_read_expected_valid <= 1'b0;
            end
        end
    end

    // Compare accepted LSU-side tags with the exact normal/posted response
    // stream.  Four harts may complete in any relative order.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (score_hart = 0;
                 score_hart < NUM_HARTS;
                 score_hart = score_hart + 1) begin
                request_sent_count[score_hart] <= 0;
                response_received_count[score_hart] <= 0;
                for (score_tag = 0;
                     score_tag < TAG_COUNT;
                     score_tag = score_tag + 1) begin
                    tag_pending[score_hart][score_tag] <= 1'b0;
                    tag_pending_posted[score_hart][score_tag] <= 1'b0;
                    tag_pending_write[score_hart][score_tag] <= 1'b0;
                    tag_pending_addr[score_hart][score_tag] <= 64'd0;
                    tag_pending_read_data[score_hart][score_tag] <=
                        64'd0;
                end
            end
        end else begin
            for (score_hart = 0;
                 score_hart < NUM_HARTS;
                 score_hart = score_hart + 1) begin
                if (cache_req_valid[score_hart] &&
                    lsu_req_ready[score_hart]) begin
                    score_tag =
                        cache_req_tag[
                            score_hart*TAG_WIDTH +: TAG_WIDTH];
                    if (tag_pending[score_hart][score_tag])
                        $fatal(1,
                            "hart %0d reused pending LSU tag %0d",
                            score_hart, score_tag);
                    tag_pending[score_hart][score_tag] <= 1'b1;
                    tag_pending_posted[score_hart][score_tag] <=
                        cache_req_posted[score_hart];
                    tag_pending_write[score_hart][score_tag] <=
                        cache_req_write[score_hart];
                    tag_pending_addr[score_hart][score_tag] <=
                        cache_req_addr[score_hart*64 +: 64];
                    score_word =
                        cache_req_addr[
                            score_hart*64 + 3 +: 3];
                    tag_pending_read_data[score_hart][score_tag] <=
                        reference_memory[
                            line_index(
                                cache_req_addr[
                                    score_hart*64 +: 64])][
                            score_word*64 +: 64];
                    request_sent_count[score_hart] <=
                        request_sent_count[score_hart] + 1;
                end

                if (lsu_resp_valid[score_hart]) begin
                    score_tag =
                        lsu_resp_tag[
                            score_hart*TAG_WIDTH +: TAG_WIDTH];
                    if (!tag_pending[score_hart][score_tag] ||
                        tag_pending_posted[score_hart][score_tag])
                        $fatal(1,
                            "hart %0d unexpected normal response tag=%0d",
                            score_hart, score_tag);
                    if (lsu_req_error[score_hart])
                        $fatal(1,
                            "hart %0d response error tag=%0d",
                            score_hart, score_tag);
                    if (!tag_pending_write[score_hart][score_tag] &&
                        (lsu_req_rdata[score_hart*64 +: 64] !==
                         tag_pending_read_data[score_hart][score_tag]))
                        $fatal(1,
                            "hart %0d response data mismatch tag=%0d addr=%016x got=%016x expected=%016x",
                            score_hart, score_tag,
                            tag_pending_addr[score_hart][score_tag],
                            lsu_req_rdata[score_hart*64 +: 64],
                            tag_pending_read_data[
                                score_hart][score_tag]);
                    tag_pending[score_hart][score_tag] <= 1'b0;
                    response_received_count[score_hart] <=
                        response_received_count[score_hart] + 1;
                end

                if (lsu_posted_resp_valid[score_hart]) begin
                    score_tag =
                        lsu_posted_resp_tag[
                            score_hart*TAG_WIDTH +: TAG_WIDTH];
                    if (!tag_pending[score_hart][score_tag] ||
                        !tag_pending_posted[score_hart][score_tag])
                        $fatal(1,
                            "hart %0d unexpected posted response tag=%0d",
                            score_hart, score_tag);
                    tag_pending[score_hart][score_tag] <= 1'b0;
                    response_received_count[score_hart] <=
                        response_received_count[score_hart] + 1;
                end
            end
        end
    end

    task automatic expect_home_write;
        input integer selected_hart;
        input [63:0] address;
        input [63:0] data;
        begin
            if (expected_home_write_valid[selected_hart])
                $fatal(1,
                    "hart %0d already has an expected home write",
                    selected_hart);
            expected_home_write_valid[selected_hart] = 1'b1;
            expected_home_write_addr[selected_hart] =
                {address[63:6], 6'b0};
            expected_home_write_data[selected_hart] =
                {`OPENRV64_CCX_LINE_DATA_WIDTH{1'b0}};
            expected_home_write_data[selected_hart][
                address[5:3]*64 +: 64] = data;
            expected_home_write_strb[selected_hart] =
                {`OPENRV64_CCX_LINE_STRB_WIDTH{1'b0}};
            expected_home_write_strb[selected_hart][
                address[5:3]*8 +: 8] = 8'hff;
        end
    endtask

    task automatic issue_load;
        input integer selected_hart;
        input [63:0] address;
        input [63:0] expected;
        logic [TAG_WIDTH-1:0] selected_tag;
        integer task_wait_cycles;
        begin
            selected_tag =
                next_lsu_tag[selected_hart*TAG_WIDTH +: TAG_WIDTH];
            @(negedge clk);
            lsu_req_valid[selected_hart] = 1'b1;
            lsu_req_lock[selected_hart] = 1'b0;
            lsu_req_write[selected_hart] = 1'b0;
            lsu_req_tag[selected_hart*TAG_WIDTH +: TAG_WIDTH] =
                selected_tag;
            lsu_req_addr[selected_hart*64 +: 64] = address;
            lsu_req_wdata[selected_hart*64 +: 64] = 64'd0;
            lsu_req_wstrb[selected_hart*8 +: 8] = 8'd0;
            task_wait_cycles = 0;
            while (!lsu_req_ready[selected_hart] &&
                   (task_wait_cycles < 1000)) begin
                @(negedge clk);
                task_wait_cycles = task_wait_cycles + 1;
            end
            if (!lsu_req_ready[selected_hart])
                $fatal(1, "hart %0d load request timeout",
                       selected_hart);
            @(posedge clk);
            @(negedge clk);
            lsu_req_valid[selected_hart] = 1'b0;
            lsu_req_addr[selected_hart*64 +: 64] = 64'd0;

            task_wait_cycles = 0;
            while (!lsu_resp_valid[selected_hart] &&
                   (task_wait_cycles < 4000)) begin
                @(negedge clk);
                task_wait_cycles = task_wait_cycles + 1;
            end
            if (!lsu_resp_valid[selected_hart])
                $fatal(1, "hart %0d load response timeout",
                       selected_hart);
            if (lsu_req_error[selected_hart] ||
                (lsu_resp_tag[
                    selected_hart*TAG_WIDTH +: TAG_WIDTH] !=
                 selected_tag) ||
                (lsu_req_rdata[selected_hart*64 +: 64] !== expected))
                $fatal(1,
                    "hart %0d load addr=%016x data=%016x expected=%016x tag=%0d/%0d error=%0b",
                    selected_hart, address,
                    lsu_req_rdata[selected_hart*64 +: 64], expected,
                    lsu_resp_tag[
                        selected_hart*TAG_WIDTH +: TAG_WIDTH],
                    selected_tag, lsu_req_error[selected_hart]);
            next_lsu_tag[selected_hart*TAG_WIDTH +: TAG_WIDTH] =
                selected_tag + 1'b1;
            @(posedge clk);
        end
    endtask

    task automatic issue_store;
        input integer selected_hart;
        input [63:0] address;
        input [63:0] data;
        logic [TAG_WIDTH-1:0] selected_tag;
        integer task_wait_cycles;
        begin
            selected_tag =
                next_lsu_tag[selected_hart*TAG_WIDTH +: TAG_WIDTH];
            @(negedge clk);
            expect_home_write(selected_hart, address, data);
            lsu_req_valid[selected_hart] = 1'b1;
            lsu_req_lock[selected_hart] = 1'b0;
            lsu_req_write[selected_hart] = 1'b1;
            lsu_req_tag[selected_hart*TAG_WIDTH +: TAG_WIDTH] =
                selected_tag;
            lsu_req_addr[selected_hart*64 +: 64] = address;
            lsu_req_wdata[selected_hart*64 +: 64] = data;
            lsu_req_wstrb[selected_hart*8 +: 8] = 8'hff;
            task_wait_cycles = 0;
            while (!lsu_req_ready[selected_hart] &&
                   (task_wait_cycles < 1000)) begin
                @(negedge clk);
                task_wait_cycles = task_wait_cycles + 1;
            end
            if (!lsu_req_ready[selected_hart])
                $fatal(1, "hart %0d store request timeout",
                       selected_hart);
            @(posedge clk);
            @(negedge clk);
            lsu_req_valid[selected_hart] = 1'b0;
            lsu_req_write[selected_hart] = 1'b0;
            lsu_req_addr[selected_hart*64 +: 64] = 64'd0;
            lsu_req_wdata[selected_hart*64 +: 64] = 64'd0;
            lsu_req_wstrb[selected_hart*8 +: 8] = 8'd0;

            task_wait_cycles = 0;
            while (!lsu_posted_resp_valid[selected_hart] &&
                   (task_wait_cycles < 1000)) begin
                @(negedge clk);
                task_wait_cycles = task_wait_cycles + 1;
            end
            if (!lsu_posted_resp_valid[selected_hart] ||
                (lsu_posted_resp_tag[
                    selected_hart*TAG_WIDTH +: TAG_WIDTH] !=
                 selected_tag))
                $fatal(1, "hart %0d posted store completion failed",
                       selected_hart);
            next_lsu_tag[selected_hart*TAG_WIDTH +: TAG_WIDTH] =
                selected_tag + 1'b1;
            @(posedge clk);
        end
    endtask

    task automatic drain_stores;
        input integer selected_hart;
        integer task_wait_cycles;
        begin
            @(negedge clk);
            speculation_barrier[selected_hart] = 1'b1;
            @(posedge clk);
            @(negedge clk);
            speculation_barrier[selected_hart] = 1'b0;
            task_wait_cycles = 0;
            while (store_barrier_busy[selected_hart] &&
                   (task_wait_cycles < 8000)) begin
                @(negedge clk);
                task_wait_cycles = task_wait_cycles + 1;
            end
            if (store_barrier_busy[selected_hart])
                $fatal(1, "hart %0d store barrier timeout",
                       selected_hart);
            if (lsu_store_resp_error[selected_hart])
                $fatal(1, "hart %0d downstream store error",
                       selected_hart);
            if (expected_home_write_valid[selected_hart])
                $fatal(1,
                    "hart %0d barrier completed before home write",
                    selected_hart);
        end
    endtask

    task automatic drain_store_mask;
        input [NUM_HARTS-1:0] selected_harts;
        begin
            // Independent snoop resources permit every private store buffer
            // to drain concurrently.  This is the adversarial configuration:
            // each home write may invalidate a hart whose own write is
            // already waiting for the same serialized home.
            fork
                if (selected_harts[0]) drain_stores(0);
                if (selected_harts[1]) drain_stores(1);
                if (selected_harts[2]) drain_stores(2);
                if (selected_harts[3]) drain_stores(3);
            join
        end
    endtask

    task automatic run_planned_operation;
        input integer selected_hart;
        begin
            if (planned_write[selected_hart])
                issue_store(selected_hart,
                            planned_addr[selected_hart],
                            planned_data[selected_hart]);
            else
                issue_load(selected_hart,
                           planned_addr[selected_hart],
                           planned_expected[selected_hart]);
        end
    endtask

    task automatic issue_lr_hold;
        input integer selected_hart;
        input [63:0] address;
        input [63:0] expected;
        logic [TAG_WIDTH-1:0] selected_tag;
        integer task_wait_cycles;
        begin
            selected_tag =
                next_lsu_tag[selected_hart*TAG_WIDTH +: TAG_WIDTH];
            @(negedge clk);
            atomic_select[selected_hart] = 1'b1;
            atomic_valid[selected_hart] = 1'b1;
            atomic_consume[selected_hart] = 1'b0;
            atomic_op[
                selected_hart*`RV64_LSU_OP_WIDTH +:
                `RV64_LSU_OP_WIDTH] = `RV64_LSU_OP_LR;
            atomic_size[
                selected_hart*`RV64_LSU_SIZE_WIDTH +:
                `RV64_LSU_SIZE_WIDTH] = `RV64_LSU_SIZE_DWORD;
            atomic_addr[selected_hart*64 +: 64] = address;
            atomic_operand[selected_hart*64 +: 64] = 64'd0;
            atomic_tag[selected_hart*TAG_WIDTH +: TAG_WIDTH] =
                selected_tag;

            task_wait_cycles = 0;
            while (!atomic_complete[selected_hart] &&
                   (task_wait_cycles < 12000)) begin
                @(negedge clk);
                task_wait_cycles = task_wait_cycles + 1;
            end
            if (!atomic_complete[selected_hart])
                $fatal(1, "hart %0d LR timeout", selected_hart);
            if (atomic_illegal[selected_hart] ||
                atomic_misaligned[selected_hart] ||
                atomic_access_fault[selected_hart] ||
                atomic_page_fault[selected_hart] ||
                (atomic_result[selected_hart*64 +: 64] !== expected))
                $fatal(1,
                    "hart %0d LR failed result=%016x expected=%016x",
                    selected_hart,
                    atomic_result[selected_hart*64 +: 64], expected);

            atomic_consume[selected_hart] = 1'b1;
            @(posedge clk);
            @(negedge clk);
            atomic_consume[selected_hart] = 1'b0;
            atomic_valid[selected_hart] = 1'b0;
            atomic_select[selected_hart] = 1'b0;
            atomic_op[
                selected_hart*`RV64_LSU_OP_WIDTH +:
                `RV64_LSU_OP_WIDTH] = `RV64_LSU_OP_INVALID;
            atomic_addr[selected_hart*64 +: 64] = 64'd0;
            next_lsu_tag[selected_hart*TAG_WIDTH +: TAG_WIDTH] =
                selected_tag + 1'b1;
        end
    endtask

    task automatic issue_sc_expect_fail;
        input integer selected_hart;
        input [63:0] address;
        input [63:0] data;
        integer task_wait_cycles;
        integer sc_commands_before;
        begin
            sc_commands_before = atomic_sc_command_count;
            @(negedge clk);
            atomic_select[selected_hart] = 1'b1;
            atomic_valid[selected_hart] = 1'b1;
            atomic_consume[selected_hart] = 1'b0;
            atomic_op[
                selected_hart*`RV64_LSU_OP_WIDTH +:
                `RV64_LSU_OP_WIDTH] = `RV64_LSU_OP_SC;
            atomic_size[
                selected_hart*`RV64_LSU_SIZE_WIDTH +:
                `RV64_LSU_SIZE_WIDTH] = `RV64_LSU_SIZE_DWORD;
            atomic_addr[selected_hart*64 +: 64] = address;
            atomic_operand[selected_hart*64 +: 64] = data;

            task_wait_cycles = 0;
            while (!atomic_complete[selected_hart] &&
                   (task_wait_cycles < 12000)) begin
                @(negedge clk);
                task_wait_cycles = task_wait_cycles + 1;
            end
            if (!atomic_complete[selected_hart])
                $fatal(1, "hart %0d failed-SC timeout", selected_hart);
            if (atomic_illegal[selected_hart] ||
                atomic_misaligned[selected_hart] ||
                atomic_access_fault[selected_hart] ||
                atomic_page_fault[selected_hart] ||
                (atomic_result[selected_hart*64 +: 64] !== 64'd1))
                $fatal(1,
                    "hart %0d SC did not report reservation loss result=%016x",
                    selected_hart,
                    atomic_result[selected_hart*64 +: 64]);
            if (atomic_sc_command_count != sc_commands_before)
                $fatal(1,
                    "hart %0d sent SC after invalidate cleared reservation",
                    selected_hart);

            atomic_consume[selected_hart] = 1'b1;
            @(posedge clk);
            @(negedge clk);
            atomic_consume[selected_hart] = 1'b0;
            atomic_valid[selected_hart] = 1'b0;
            atomic_select[selected_hart] = 1'b0;
            atomic_op[
                selected_hart*`RV64_LSU_OP_WIDTH +:
                `RV64_LSU_OP_WIDTH] = `RV64_LSU_OP_INVALID;
            atomic_addr[selected_hart*64 +: 64] = 64'd0;
            atomic_operand[selected_hart*64 +: 64] = 64'd0;
        end
    endtask

    task automatic issue_atomic;
        input integer selected_hart;
        input [`RV64_LSU_OP_WIDTH-1:0] selected_op;
        input [63:0] address;
        input [63:0] operand;
        logic [TAG_WIDTH-1:0] selected_tag;
        logic [63:0] expected_old;
        logic [63:0] expected_new;
        integer task_wait_cycles;
        integer sc_count_before;
        begin
            if (home_write_active || l2_read_expected_valid)
                $fatal(1, "atomic started while home was active");
            expected_old =
                reference_memory[line_index(address)][
                    address[5:3]*64 +: 64];
            expected_new =
                amo_result(selected_op, expected_old, operand);
            selected_tag =
                next_lsu_tag[selected_hart*TAG_WIDTH +: TAG_WIDTH];
            expect_home_write(selected_hart, address, expected_new);
            sc_count_before = atomic_sc_success_count;

            @(negedge clk);
            atomic_select[selected_hart] = 1'b1;
            atomic_valid[selected_hart] = 1'b1;
            atomic_consume[selected_hart] = 1'b0;
            atomic_op[
                selected_hart*`RV64_LSU_OP_WIDTH +:
                `RV64_LSU_OP_WIDTH] = selected_op;
            atomic_size[
                selected_hart*`RV64_LSU_SIZE_WIDTH +:
                `RV64_LSU_SIZE_WIDTH] = `RV64_LSU_SIZE_DWORD;
            atomic_addr[selected_hart*64 +: 64] = address;
            atomic_operand[selected_hart*64 +: 64] = operand;
            atomic_tag[selected_hart*TAG_WIDTH +: TAG_WIDTH] =
                selected_tag;

            task_wait_cycles = 0;
            while (!atomic_complete[selected_hart] &&
                   (task_wait_cycles < 12000)) begin
                @(negedge clk);
                task_wait_cycles = task_wait_cycles + 1;
            end
            if (!atomic_complete[selected_hart])
                $fatal(1,
                    "hart %0d atomic timeout engine=%0d mem_valid=%0b mem_write=%0b inflight=%0b l1_backend=%0d home=%0d ccx_req=%0b/%0b ccx_resp=%0b/%0b",
                    selected_hart,
                    atomic_state_debug[selected_hart*3 +: 3],
                    atomic_mem_valid[selected_hart],
                    atomic_mem_write[selected_hart],
                    atomic_mem_inflight[selected_hart],
                    l1d_backend_state_debug[selected_hart*2 +: 2],
                    u_directory_frontend.state_q,
                    ccx_req_valid, ccx_req_ready,
                    ccx_resp_valid, ccx_resp_ready);
            if (atomic_illegal[selected_hart] ||
                atomic_misaligned[selected_hart] ||
                atomic_access_fault[selected_hart] ||
                atomic_page_fault[selected_hart])
                $fatal(1,
                    "hart %0d atomic fault illegal=%0b misaligned=%0b access=%0b page=%0b",
                    selected_hart,
                    atomic_illegal[selected_hart],
                    atomic_misaligned[selected_hart],
                    atomic_access_fault[selected_hart],
                    atomic_page_fault[selected_hart]);
            if (atomic_result[selected_hart*64 +: 64] !==
                expected_old)
                $fatal(1,
                    "hart %0d atomic old value mismatch got=%016x expected=%016x",
                    selected_hart,
                    atomic_result[selected_hart*64 +: 64],
                    expected_old);
            if (atomic_sc_success_count != sc_count_before + 1)
                $fatal(1,
                    "hart %0d atomic did not complete one successful SC",
                    selected_hart);
            if (expected_home_write_valid[selected_hart])
                $fatal(1,
                    "hart %0d atomic completed before home write",
                    selected_hart);
            if (reference_memory[line_index(address)][
                    address[5:3]*64 +: 64] !== expected_new)
                $fatal(1,
                    "hart %0d atomic reference update mismatch",
                    selected_hart);

            atomic_consume[selected_hart] = 1'b1;
            @(posedge clk);
            @(negedge clk);
            atomic_consume[selected_hart] = 1'b0;
            atomic_valid[selected_hart] = 1'b0;
            atomic_select[selected_hart] = 1'b0;
            atomic_op[
                selected_hart*`RV64_LSU_OP_WIDTH +:
                `RV64_LSU_OP_WIDTH] = `RV64_LSU_OP_INVALID;
            atomic_addr[selected_hart*64 +: 64] = 64'd0;
            atomic_operand[selected_hart*64 +: 64] = 64'd0;
            next_lsu_tag[selected_hart*TAG_WIDTH +: TAG_WIDTH] =
                selected_tag + 1'b1;
        end
    endtask

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    always @(posedge clk)
        cycle_count <= cycle_count + 1;

    // Under four-way same-line store contention, all four commands are live
    // before the home is released.  The crossbar must grant one transaction
    // per hart in strict round-robin order.
    always @(posedge clk) begin
        if (rst_n && contention_monitor_active &&
            ccx_req_valid && ccx_req_ready &&
            (ccx_req_op == `OPENRV64_CCX_OP_WRITE) &&
            ({ccx_req_addr[63:6], 6'b0} ==
             contention_monitor_line)) begin
            if (ccx_req_hart_id !=
                `OPENRV64_CCX_HART_ID_WIDTH'(
                    contention_expected_hart))
                $fatal(1,
                    "same-line arbitration order got hart=%0d expected=%0d line=%016x",
                    ccx_req_hart_id, contention_expected_hart,
                    contention_monitor_line);
            contention_grant_count = contention_grant_count + 1;
            contention_expected_hart =
                (contention_expected_hart == NUM_HARTS - 1) ?
                    0 : contention_expected_hart + 1;
        end
    end

    initial begin
        for (memory_line_index = 0;
             memory_line_index < MEMORY_LINES;
             memory_line_index = memory_line_index + 1) begin
            memory[memory_line_index] =
                {`OPENRV64_CCX_LINE_DATA_WIDTH{1'b0}};
            reference_memory[memory_line_index] =
                {`OPENRV64_CCX_LINE_DATA_WIDTH{1'b0}};
            for (memory_word_index = 0;
                 memory_word_index < 8;
                 memory_word_index = memory_word_index + 1) begin
                memory[memory_line_index][memory_word_index*64 +: 64] =
                    initial_memory_word(
                        MEMORY_BASE + memory_line_index*64 +
                        memory_word_index*8);
                reference_memory[memory_line_index][
                    memory_word_index*64 +: 64] =
                    initial_memory_word(
                        MEMORY_BASE + memory_line_index*64 +
                        memory_word_index*8);
            end
        end
    end

    initial begin
        rst_n = 1'b0;
        cycle_count = 0;
        lsu_req_valid = {NUM_HARTS{1'b0}};
        lsu_req_lock = {NUM_HARTS{1'b0}};
        lsu_req_write = {NUM_HARTS{1'b0}};
        lsu_req_tag = {NUM_HARTS*TAG_WIDTH{1'b0}};
        lsu_req_addr = {NUM_HARTS*64{1'b0}};
        lsu_req_wdata = {NUM_HARTS*64{1'b0}};
        lsu_req_wstrb = {NUM_HARTS*8{1'b0}};
        speculation_barrier = {NUM_HARTS{1'b0}};
        next_lsu_tag = {NUM_HARTS*TAG_WIDTH{1'b0}};
        atomic_select = {NUM_HARTS{1'b0}};
        atomic_valid = {NUM_HARTS{1'b0}};
        atomic_consume = {NUM_HARTS{1'b0}};
        atomic_op =
            {NUM_HARTS{`RV64_LSU_OP_INVALID}};
        atomic_size =
            {NUM_HARTS{`RV64_LSU_SIZE_DWORD}};
        atomic_addr = {NUM_HARTS*64{1'b0}};
        atomic_operand = {NUM_HARTS*64{1'b0}};
        atomic_tag = {NUM_HARTS*TAG_WIDTH{1'b0}};
        if (!$value$plusargs("seed=%d", random_seed))
            random_seed = 32'h4c32_4343;
        random_state = random_seed;
        if (random_state == 0)
            random_state = 32'h1;
        random_store_count = 0;
        atomic_sequence = 0;
        standalone_lr_count = 0;
        contention_monitor_active = 1'b0;
        contention_monitor_line = 64'd0;
        contention_expected_hart = 0;
        contention_grant_count = 0;

        repeat (6) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        // Every L1D participates.  Harts 0 and 1 share A; harts 2 and 3
        // independently fill B and C through the same directory and L2.
        issue_load(0, LINE_A, initial_memory_word(LINE_A));
        issue_load(1, LINE_A, initial_memory_word(LINE_A));
        issue_load(2, LINE_B, initial_memory_word(LINE_B));
        issue_load(3, LINE_C, initial_memory_word(LINE_C));
        if (memory_read_count != 3)
            $fatal(1,
                "shared L2 did not merge/hit repeated line reads count=%0d",
                memory_read_count);

        // A resident repeat must hit in private L1D and emit no new L2
        // command.
        commands_before = l2_command_count;
        issue_load(0, LINE_A, initial_memory_word(LINE_A));
        if (l2_command_count != commands_before)
            $fatal(1, "hart 0 resident load escaped L1D");

        // Hart 2 has no cached A copy.  Its posted write must invalidate the
        // recorded harts 0 and 1 before L2 sees it.
        issue_store(2, LINE_A, WRITE_A0);
        drain_stores(2);
        if ((probe_accept_count[0] != 1) ||
            (probe_accept_count[1] != 1) ||
            (probe_accept_count[2] != 0) ||
            (probe_accept_count[3] != 0) ||
            (invalidate_count[0] != 1) ||
            (invalidate_count[1] != 1))
            $fatal(1,
                "first write probe targets/invalidations incorrect");
        if ((last_l2_write_cycle <= invalidate_cycle[0]) ||
            (last_l2_write_cycle <= invalidate_cycle[1]))
            $fatal(1, "L2 write crossed before private invalidations");

        // Hart 0 must miss after its probe and observe the value installed in
        // the shared L2, not the stale private value.  No backing-memory read
        // is expected because the non-inclusive L2 still owns its own copy.
        reads_before = memory_read_count;
        issue_load(0, LINE_A, WRITE_A0);
        if (memory_read_count != reads_before)
            $fatal(1, "post-invalidate reload missed shared L2");

        // Hart 3 becomes another sharer.  A write from the invalidated hart 1
        // then probes harts 0 and 3, proving that directory ownership changes
        // are not hard-wired to the first pair.
        issue_load(3, LINE_A, WRITE_A0);
        issue_store(1, LINE_A, WRITE_A1);
        drain_stores(1);
        if ((probe_accept_count[0] != 2) ||
            (probe_accept_count[1] != 1) ||
            (probe_accept_count[2] != 0) ||
            (probe_accept_count[3] != 1) ||
            (invalidate_count[0] != 2) ||
            (invalidate_count[3] != 1))
            $fatal(1,
                "second write probe targets/invalidations incorrect");
        issue_load(3, LINE_A, WRITE_A1);

        if (protocol_error || probe_endpoint_protocol_error)
            $fatal(1, "coherent protocol reported an integration error");
        if (l2_write_count != 2)
            $fatal(1, "L2 write command count=%0d expected=2",
                   l2_write_count);

        // Sixteen-line four-hart ping-pong.  Each line is first shared by all
        // readers, then receives four simultaneously queued stores, then four
        // ordered AMOs.  The concurrent store phase is the deadlock test; the
        // AMO phase verifies home LR/SC operation and repeated ownership loss.
        for (pingpong_line = 0;
             pingpong_line < PINGPONG_LINES;
             pingpong_line = pingpong_line + 1) begin
            pingpong_addr =
                PINGPONG_BASE + pingpong_line*64;

            fork
                issue_load(
                    0, pingpong_addr,
                    reference_memory[line_index(pingpong_addr)][0 +: 64]);
                issue_load(
                    1, pingpong_addr,
                    reference_memory[line_index(pingpong_addr)][0 +: 64]);
                issue_load(
                    2, pingpong_addr,
                    reference_memory[line_index(pingpong_addr)][0 +: 64]);
                issue_load(
                    3, pingpong_addr,
                    reference_memory[line_index(pingpong_addr)][0 +: 64]);
            join

            for (pingpong_hart = 0;
                 pingpong_hart < NUM_HARTS;
                 pingpong_hart = pingpong_hart + 1)
                pingpong_data[pingpong_hart] =
                    64'hcc40_0000_0000_0000 |
                    (64'(pingpong_line) << 8) |
                    64'(pingpong_hart);

            fork
                issue_store(0, pingpong_addr, pingpong_data[0]);
                issue_store(1, pingpong_addr, pingpong_data[1]);
                issue_store(2, pingpong_addr, pingpong_data[2]);
                issue_store(3, pingpong_addr, pingpong_data[3]);
            join
            random_store_count = random_store_count + NUM_HARTS;

            contention_monitor_line =
                {pingpong_addr[63:6], 6'b0};
            contention_expected_hart = u_crossbar.round_robin_q;
            contention_grant_count = 0;
            contention_monitor_active = 1'b1;
            drain_store_mask({NUM_HARTS{1'b1}});
            contention_monitor_active = 1'b0;
            if (contention_grant_count != NUM_HARTS)
                $fatal(1,
                    "same-line arbitration granted %0d/%0d harts line=%016x",
                    contention_grant_count, NUM_HARTS,
                    contention_monitor_line);

            issue_load(
                pingpong_line % NUM_HARTS,
                pingpong_addr,
                reference_memory[line_index(pingpong_addr)][0 +: 64]);

            for (pingpong_hart = 0;
                 pingpong_hart < NUM_HARTS;
                 pingpong_hart = pingpong_hart + 1) begin
                issue_atomic(
                    pingpong_hart,
                    `RV64_LSU_OP_AMOADD,
                    pingpong_addr,
                    64'd1);
                atomic_sequence = atomic_sequence + 1;
            end
        end
        $display(
            "pingpong: lines=%0d reads=%0d contended_stores=%0d atomics=%0d",
            PINGPONG_LINES, PINGPONG_LINES*NUM_HARTS,
            PINGPONG_LINES*NUM_HARTS,
            PINGPONG_LINES*NUM_HARTS);

        // An external writer must break a held LR reservation by forcing the
        // old cache out of the line.  The subsequent SC fails locally and
        // emits no home command.
        pingpong_addr = PINGPONG_BASE;
        issue_load(
            0, pingpong_addr,
            reference_memory[line_index(pingpong_addr)][0 +: 64]);
        issue_lr_hold(
            0, pingpong_addr,
            reference_memory[line_index(pingpong_addr)][0 +: 64]);
        standalone_lr_count = standalone_lr_count + 1;
        pingpong_data[1] = 64'h1a5c_0000_0000_0001;
        issue_store(1, pingpong_addr, pingpong_data[1]);
        random_store_count = random_store_count + 1;
        drain_stores(1);
        issue_sc_expect_fail(
            0, pingpong_addr, 64'hbad0_bad0_bad0_bad0);
        issue_load(0, pingpong_addr, pingpong_data[1]);

        // Four operations are launched per round.  Their lines are distinct
        // within the round, so the accepted home order is the only ordering
        // needed to update the reference model.  The separate directed phase
        // above covers same-line multi-writer probe progress.
        for (random_round = 0;
             random_round < RANDOM_ROUNDS;
             random_round = random_round + 1) begin
            planned_store_mask = {NUM_HARTS{1'b0}};
            // Keep the random phase at one writer per round so later reads
            // have a simple reference order.  Rotate the writer so every hart
            // generates the same amount of store traffic.
            random_store_hart =
                (random_round + random_seed) % NUM_HARTS;
            for (random_hart = 0;
                 random_hart < NUM_HARTS;
                 random_hart = random_hart + 1) begin
                random_line_unique = 0;
                while (!random_line_unique) begin
                    random_state = xorshift32(random_state);
                    planned_line[random_hart] = random_state[8:0];
                    random_line_unique = 1;
                    for (random_prior_hart = 0;
                         random_prior_hart < random_hart;
                         random_prior_hart =
                             random_prior_hart + 1)
                        if (planned_line[random_hart] ==
                            planned_line[random_prior_hart])
                            random_line_unique = 0;
                end
                random_state = xorshift32(random_state);
                planned_word[random_hart] = random_state[2:0];
                random_state = xorshift32(random_state);
                planned_write[random_hart] =
                    (random_hart == random_store_hart);
                random_state = xorshift32(random_state);
                planned_data[random_hart][31:0] = random_state;
                random_state = xorshift32(random_state);
                planned_data[random_hart][63:32] = random_state;
                planned_addr[random_hart] =
                    MEMORY_BASE +
                    planned_line[random_hart]*64 +
                    planned_word[random_hart]*8;
                planned_expected[random_hart] =
                    reference_memory[planned_line[random_hart]][
                        planned_word[random_hart]*64 +: 64];
                planned_store_mask[random_hart] =
                    planned_write[random_hart];
                if (planned_write[random_hart])
                    random_store_count = random_store_count + 1;
            end

            fork
                run_planned_operation(0);
                run_planned_operation(1);
                run_planned_operation(2);
                run_planned_operation(3);
            join
            drain_store_mask(planned_store_mask);

            if ((ATOMIC_INTERVAL > 0) &&
                (((random_round + 1) % ATOMIC_INTERVAL) == 0)) begin
                random_state = xorshift32(random_state);
                atomic_random_addr =
                    MEMORY_BASE +
                    random_state[8:0]*64;
                random_state = xorshift32(random_state);
                atomic_random_addr =
                    atomic_random_addr + random_state[2:0]*8;
                random_state = xorshift32(random_state);
                atomic_random_operand[31:0] = random_state;
                random_state = xorshift32(random_state);
                atomic_random_operand[63:32] = random_state;
                case (atomic_sequence % 9)
                    0: issue_atomic(atomic_sequence % NUM_HARTS,
                                    `RV64_LSU_OP_AMOSWAP,
                                    atomic_random_addr,
                                    atomic_random_operand);
                    1: issue_atomic(atomic_sequence % NUM_HARTS,
                                    `RV64_LSU_OP_AMOADD,
                                    atomic_random_addr,
                                    atomic_random_operand);
                    2: issue_atomic(atomic_sequence % NUM_HARTS,
                                    `RV64_LSU_OP_AMOXOR,
                                    atomic_random_addr,
                                    atomic_random_operand);
                    3: issue_atomic(atomic_sequence % NUM_HARTS,
                                    `RV64_LSU_OP_AMOAND,
                                    atomic_random_addr,
                                    atomic_random_operand);
                    4: issue_atomic(atomic_sequence % NUM_HARTS,
                                    `RV64_LSU_OP_AMOOR,
                                    atomic_random_addr,
                                    atomic_random_operand);
                    5: issue_atomic(atomic_sequence % NUM_HARTS,
                                    `RV64_LSU_OP_AMOMIN,
                                    atomic_random_addr,
                                    atomic_random_operand);
                    6: issue_atomic(atomic_sequence % NUM_HARTS,
                                    `RV64_LSU_OP_AMOMAX,
                                    atomic_random_addr,
                                    atomic_random_operand);
                    7: issue_atomic(atomic_sequence % NUM_HARTS,
                                    `RV64_LSU_OP_AMOMINU,
                                    atomic_random_addr,
                                    atomic_random_operand);
                    default:
                       issue_atomic(atomic_sequence % NUM_HARTS,
                                    `RV64_LSU_OP_AMOMAXU,
                                    atomic_random_addr,
                                    atomic_random_operand);
                endcase
                atomic_sequence = atomic_sequence + 1;
            end

            if (((random_round + 1) % 256) == 0)
                $display(
                    "progress: rounds=%0d ordinary_ops=%0d atomics=%0d cycles=%0d",
                    random_round + 1,
                    (random_round + 1)*NUM_HARTS,
                    atomic_sequence, cycle_count);
        end

        for (hart_index = 0;
             hart_index < NUM_HARTS;
             hart_index = hart_index + 1) begin
            if (request_sent_count[hart_index] !=
                response_received_count[hart_index])
                $fatal(1,
                    "hart %0d sent/received mismatch %0d/%0d",
                    hart_index, request_sent_count[hart_index],
                    response_received_count[hart_index]);
            for (memory_word_index = 0;
                 memory_word_index < TAG_COUNT;
                 memory_word_index = memory_word_index + 1)
                if (tag_pending[hart_index][memory_word_index])
                    $fatal(1,
                        "hart %0d tag %0d remains pending",
                        hart_index, memory_word_index);
            if (expected_home_write_valid[hart_index])
                $fatal(1,
                    "hart %0d expected home write remains pending",
                    hart_index);
        end
        if (home_write_active || l2_read_expected_valid)
            $fatal(1, "home verifier still has an active transaction");
        if ((atomic_lr_command_count !=
             (atomic_sequence + standalone_lr_count)) ||
            (atomic_sc_command_count != atomic_sequence) ||
            (atomic_sc_success_count != atomic_sequence))
            $fatal(1,
                "atomic command counts lr=%0d sc=%0d success=%0d expected_amo=%0d standalone_lr=%0d",
                atomic_lr_command_count, atomic_sc_command_count,
                atomic_sc_success_count, atomic_sequence,
                standalone_lr_count);
        if (l2_write_count !=
            (2 + random_store_count + atomic_sequence))
            $fatal(1,
                "home write count=%0d expected=%0d",
                l2_write_count,
                2 + random_store_count + atomic_sequence);
        if (protocol_error || probe_endpoint_protocol_error)
            $fatal(1, "coherent protocol failed during random stress");

        $display(
            "PASS: rounds=%0d ops=%0d stores=%0d atomics=%0d sent/received verified",
            RANDOM_ROUNDS, RANDOM_ROUNDS*NUM_HARTS,
            random_store_count, atomic_sequence);
        $finish;
    end

    initial begin
        repeat (RANDOM_ROUNDS*1000 + 200000) @(posedge clk);
        $fatal(1, "four-hart L1D/directory/L2 test timed out");
    end

endmodule
