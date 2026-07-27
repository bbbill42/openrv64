`timescale 1ns/1ps
`include "complex/protocol/defs.v"
`include "complex/coherent/protocol/defs.v"

// Non-inclusive coherent frontend for the shared L2.
//
// The frontend is the coherence home for clean, write-through private
// caches.  It owns an independently tagged snoop-filter directory, removes
// recorded D$ sharers before forwarding a cacheable write, and invalidates a
// directory victim before reusing its entry.  The L2 remains a non-inclusive
// data backend and does not know which private caches retain a clean copy.
//
// This first implementation permits one global transaction.  That is
// deliberately stronger than RVWMO and lower throughput than the final
// per-line home design, but it provides a simple correctness baseline.
module openrv64_ccx_coherent_protocol #(
    parameter integer NUM_HARTS = 2,
    parameter integer HART_ID_BASE = 0,
    parameter integer DIRECTORY_ENTRIES = 256,
    parameter integer DIRECTORY_WAYS = 4,
    parameter integer DIRECTORY_ENTRY_WIDTH =
        (DIRECTORY_ENTRIES > 1) ? $clog2(DIRECTORY_ENTRIES) : 1
) (
    input  wire                         clk_i,
    input  wire                         rst_ni,

    input  wire                         req_valid_i,
    output wire                         req_ready_o,
    input  wire [`OPENRV64_CCX_HART_ID_WIDTH-1:0] req_hart_id_i,
    input  wire [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] req_txn_id_i,
    input  wire [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] req_source_id_i,
    input  wire [`OPENRV64_CCX_OP_WIDTH-1:0] req_op_i,
    input  wire                         req_lock_i,
    input  wire [`OPENRV64_CCX_ORDER_WIDTH-1:0] req_order_i,
    input  wire [`OPENRV64_CCX_KIND_WIDTH-1:0] req_kind_i,
    input  wire [`OPENRV64_CCX_ATTR_WIDTH-1:0] req_attr_i,
    input  wire [2:0]                   req_size_i,
    input  wire [63:0]                  req_addr_i,
    input  wire [`OPENRV64_CCX_BURST_LEN_WIDTH-1:0]
                                               req_burst_len_i,

    input  wire                         wdata_valid_i,
    output wire                         wdata_ready_o,
    input  wire [`OPENRV64_CCX_HART_ID_WIDTH-1:0] wdata_hart_id_i,
    input  wire [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] wdata_txn_id_i,
    input  wire [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0]
                                               wdata_source_id_i,
    input  wire [`OPENRV64_CCX_BEAT_INDEX_WIDTH-1:0]
                                               wdata_beat_index_i,
    input  wire                         wdata_last_i,
    input  wire [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] wdata_i,
    input  wire [`OPENRV64_CCX_LINE_STRB_WIDTH-1:0] wstrb_i,

    output wire                         resp_valid_o,
    input  wire                         resp_ready_i,
    output wire [`OPENRV64_CCX_HART_ID_WIDTH-1:0] resp_hart_id_o,
    output wire [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] resp_txn_id_o,
    output wire [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] resp_source_id_o,
    output wire [`OPENRV64_CCX_BEAT_INDEX_WIDTH-1:0]
                                               resp_beat_index_o,
    output wire                         resp_last_o,
    output wire [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] resp_rdata_o,
    output wire                         resp_error_o,
    output wire                         resp_sc_success_o,

    output wire [NUM_HARTS-1:0]         probe_valid_o,
    input  wire [NUM_HARTS-1:0]         probe_ready_i,
    output wire [NUM_HARTS*`OPENRV64_CCX_PROBE_ID_WIDTH-1:0]
                                               probe_id_o,
    output wire [NUM_HARTS*`OPENRV64_CCX_PROBE_CMD_WIDTH-1:0]
                                               probe_command_o,
    output wire [NUM_HARTS*`OPENRV64_CCX_PROBE_CACHE_WIDTH-1:0]
                                               probe_cache_mask_o,
    output wire [NUM_HARTS*64-1:0]      probe_line_addr_o,

    input  wire [NUM_HARTS-1:0]         probe_resp_valid_i,
    output wire [NUM_HARTS-1:0]         probe_resp_ready_o,
    input  wire [NUM_HARTS*`OPENRV64_CCX_PROBE_ID_WIDTH-1:0]
                                               probe_resp_id_i,
    input  wire [NUM_HARTS*`OPENRV64_CCX_PROBE_RESP_WIDTH-1:0]
                                               probe_resp_kind_i,
    input  wire [NUM_HARTS*`OPENRV64_CCX_LINE_DATA_WIDTH-1:0]
                                               probe_resp_data_i,
    input  wire [NUM_HARTS-1:0]         probe_resp_error_i,

    output wire                         l2_req_valid_o,
    input  wire                         l2_req_ready_i,
    output wire [`OPENRV64_CCX_HART_ID_WIDTH-1:0] l2_req_hart_id_o,
    output wire [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] l2_req_txn_id_o,
    output wire [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0]
                                               l2_req_source_id_o,
    output wire [`OPENRV64_CCX_OP_WIDTH-1:0] l2_req_op_o,
    output wire                         l2_req_lock_o,
    output wire [`OPENRV64_CCX_ORDER_WIDTH-1:0] l2_req_order_o,
    output wire [`OPENRV64_CCX_KIND_WIDTH-1:0] l2_req_kind_o,
    output wire [`OPENRV64_CCX_ATTR_WIDTH-1:0] l2_req_attr_o,
    output wire [2:0]                   l2_req_size_o,
    output wire [63:0]                  l2_req_addr_o,
    output wire [`OPENRV64_CCX_BURST_LEN_WIDTH-1:0]
                                               l2_req_burst_len_o,

    output wire                         l2_wdata_valid_o,
    input  wire                         l2_wdata_ready_i,
    output wire [`OPENRV64_CCX_HART_ID_WIDTH-1:0]
                                               l2_wdata_hart_id_o,
    output wire [`OPENRV64_CCX_TXN_ID_WIDTH-1:0]
                                               l2_wdata_txn_id_o,
    output wire [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0]
                                               l2_wdata_source_id_o,
    output wire [`OPENRV64_CCX_BEAT_INDEX_WIDTH-1:0]
                                               l2_wdata_beat_index_o,
    output wire                         l2_wdata_last_o,
    output wire [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] l2_wdata_o,
    output wire [`OPENRV64_CCX_LINE_STRB_WIDTH-1:0] l2_wstrb_o,

    input  wire                         l2_resp_valid_i,
    output wire                         l2_resp_ready_o,
    input  wire [`OPENRV64_CCX_HART_ID_WIDTH-1:0] l2_resp_hart_id_i,
    input  wire [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] l2_resp_txn_id_i,
    input  wire [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0]
                                               l2_resp_source_id_i,
    input  wire [`OPENRV64_CCX_BEAT_INDEX_WIDTH-1:0]
                                               l2_resp_beat_index_i,
    input  wire                         l2_resp_last_i,
    input  wire [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] l2_resp_rdata_i,
    input  wire                         l2_resp_error_i,
    input  wire                         l2_resp_sc_success_i,

    input  wire                         protocol_error_clear_i,
    output wire                         protocol_error_o
);

    localparam [3:0] ST_IDLE              = 4'd0;
    localparam [3:0] ST_WAIT_WDATA        = 4'd1;
    localparam [3:0] ST_DIR_LOOKUP        = 4'd2;
    localparam [3:0] ST_EVICT_PROBE_START = 4'd3;
    localparam [3:0] ST_EVICT_PROBE_WAIT  = 4'd4;
    localparam [3:0] ST_DIR_ALLOCATE      = 4'd5;
    localparam [3:0] ST_WRITE_PROBE_START = 4'd6;
    localparam [3:0] ST_WRITE_PROBE_WAIT  = 4'd7;
    localparam [3:0] ST_DIR_CLEAR         = 4'd8;
    localparam [3:0] ST_L2_REQ            = 4'd9;
    localparam [3:0] ST_L2_WDATA          = 4'd10;
    localparam [3:0] ST_L2_RESP           = 4'd11;
    localparam [3:0] ST_DIR_RECORD        = 4'd12;
    localparam [3:0] ST_RESP              = 4'd13;

    reg [3:0] state_q;
    reg [`OPENRV64_CCX_HART_ID_WIDTH-1:0] req_hart_id_q;
    reg [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] req_txn_id_q;
    reg [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] req_source_id_q;
    reg [`OPENRV64_CCX_OP_WIDTH-1:0] req_op_q;
    reg [`OPENRV64_CCX_ORDER_WIDTH-1:0] req_order_q;
    reg [`OPENRV64_CCX_KIND_WIDTH-1:0] req_kind_q;
    reg [`OPENRV64_CCX_ATTR_WIDTH-1:0] req_attr_q;
    reg [2:0] req_size_q;
    reg [63:0] req_addr_q;
    reg command_error_q;

    reg [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] wdata_q;
    reg [`OPENRV64_CCX_LINE_STRB_WIDTH-1:0] wstrb_q;

    reg [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] resp_rdata_q;
    reg resp_error_q;
    reg resp_sc_success_q;

    reg [DIRECTORY_ENTRY_WIDTH-1:0] directory_entry_q;
    reg [NUM_HARTS-1:0] probe_target_q;
    reg [`OPENRV64_CCX_PROBE_CACHE_WIDTH-1:0] probe_cache_mask_q;
    reg [63:0] probe_line_addr_q;
    reg [`OPENRV64_CCX_PROBE_ID_WIDTH-1:0] next_probe_id_q;

    reg protocol_error_q;
    reg [NUM_HARTS-1:0] reservation_valid_q;
    reg [63:0] reservation_line_q [0:NUM_HARTS-1];
    integer reservation_hart;
    reg [NUM_HARTS-1:0] request_hart_mask_r;
    reg request_sc_reservation_match_r;
    integer request_hart;

    wire request_fire = req_valid_i && req_ready_o;
    wire wdata_fire = wdata_valid_i && wdata_ready_o;
    wire l2_request_fire = l2_req_valid_o && l2_req_ready_i;
    wire l2_wdata_fire = l2_wdata_valid_o && l2_wdata_ready_i;
    wire l2_response_fire = l2_resp_valid_i && l2_resp_ready_o;
    wire response_fire = resp_valid_o && resp_ready_i;

    wire request_hart_valid =
        (req_hart_id_i >=
         `OPENRV64_CCX_HART_ID_WIDTH'(HART_ID_BASE)) &&
        (req_hart_id_i <
         `OPENRV64_CCX_HART_ID_WIDTH'(HART_ID_BASE + NUM_HARTS));
    wire request_op_supported =
        (req_op_i == `OPENRV64_CCX_OP_READ) ||
        (req_op_i == `OPENRV64_CCX_OP_WRITE) ||
        (req_op_i == `OPENRV64_CCX_OP_LR) ||
        (req_op_i == `OPENRV64_CCX_OP_SC) ||
        (req_op_i == `OPENRV64_CCX_OP_FENCE);
    wire request_protocol_error =
        !request_hart_valid || !request_op_supported || req_lock_i;
    wire wdata_protocol_error =
        (wdata_hart_id_i != req_hart_id_q) ||
        (wdata_txn_id_i != req_txn_id_q) ||
        (wdata_source_id_i != req_source_id_q) ||
        (wdata_beat_index_i !=
         {`OPENRV64_CCX_BEAT_INDEX_WIDTH{1'b0}}) ||
        !wdata_last_i;

    wire request_cacheable =
        |(req_attr_q & `OPENRV64_CCX_ATTR_CACHEABLE) &&
        !(|(req_attr_q & `OPENRV64_CCX_ATTR_DEVICE));
    wire request_private_fill =
        request_cacheable &&
        ((req_op_q == `OPENRV64_CCX_OP_READ) ||
         (req_op_q == `OPENRV64_CCX_OP_LR)) &&
        ((req_source_id_q == `OPENRV64_CCX_SOURCE_ICACHE) ||
         (req_source_id_q == `OPENRV64_CCX_SOURCE_DCACHE));
    wire request_is_write =
        (req_op_q == `OPENRV64_CCX_OP_WRITE) ||
        (req_op_q == `OPENRV64_CCX_OP_SC);
    wire request_coherent_write =
        request_cacheable &&
        request_is_write;
    wire [63:0] request_line_addr =
        {req_addr_q[63:6], 6'b000000};
    always @* begin
        request_hart_mask_r = {NUM_HARTS{1'b0}};
        request_sc_reservation_match_r = 1'b0;
        for (request_hart = 0;
             request_hart < NUM_HARTS;
             request_hart = request_hart + 1) begin
            if (req_hart_id_q ==
                `OPENRV64_CCX_HART_ID_WIDTH'(
                    HART_ID_BASE + request_hart)) begin
                request_hart_mask_r[request_hart] = 1'b1;
                request_sc_reservation_match_r =
                    reservation_valid_q[request_hart] &&
                    (reservation_line_q[request_hart] ==
                     request_line_addr);
            end
        end
    end
    wire [NUM_HARTS-1:0] request_hart_mask =
        request_hart_mask_r;
    wire request_sc_reservation_match =
        request_sc_reservation_match_r;

    wire directory_lookup_hit;
    wire [DIRECTORY_ENTRY_WIDTH-1:0] directory_lookup_entry;
    wire [NUM_HARTS-1:0] directory_lookup_i_sharers;
    wire [NUM_HARTS-1:0] directory_lookup_d_sharers;
    wire directory_victim_valid;
    wire [DIRECTORY_ENTRY_WIDTH-1:0] directory_victim_entry;
    wire [63:0] directory_victim_line_addr;
    wire [NUM_HARTS-1:0] directory_victim_i_sharers;
    wire [NUM_HARTS-1:0] directory_victim_d_sharers;
    /*
     * The requester invalidates its own line before issuing SC.  Probing it
     * again would deadlock: its L1D access waits for the SC response while the
     * home waits for that same L1D to accept the redundant probe.  Probe only
     * other sharers, then clear every D-sharer bit in ST_DIR_CLEAR.
     *
     * Ordinary write-through stores retain the requester's updated clean
     * copy, and likewise probe only the other sharers.
     */
    wire [NUM_HARTS-1:0] write_probe_targets =
        directory_lookup_d_sharers & ~request_hart_mask;

    wire directory_allocate = state_q == ST_DIR_ALLOCATE;
    wire directory_clear = state_q == ST_DIR_CLEAR;
    wire directory_record = state_q == ST_DIR_RECORD;
    wire directory_write_valid =
        directory_allocate || directory_clear || directory_record;
    wire [NUM_HARTS-1:0] directory_record_i =
        (req_source_id_q == `OPENRV64_CCX_SOURCE_ICACHE) ?
            ({{(NUM_HARTS-1){1'b0}}, 1'b1} <<
             (req_hart_id_q -
              `OPENRV64_CCX_HART_ID_WIDTH'(HART_ID_BASE))) :
            {NUM_HARTS{1'b0}};
    wire [NUM_HARTS-1:0] directory_record_d =
        (req_source_id_q == `OPENRV64_CCX_SOURCE_DCACHE) ?
            ({{(NUM_HARTS-1){1'b0}}, 1'b1} <<
             (req_hart_id_q -
              `OPENRV64_CCX_HART_ID_WIDTH'(HART_ID_BASE))) :
            {NUM_HARTS{1'b0}};

    openrv64_ccx_snoop_filter #(
        .NUM_HARTS(NUM_HARTS),
        .ENTRIES(DIRECTORY_ENTRIES),
        .WAYS(DIRECTORY_WAYS),
        .ENTRY_WIDTH(DIRECTORY_ENTRY_WIDTH)
    ) u_snoop_filter (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .lookup_line_addr_i(request_line_addr),
        .lookup_hit_o(directory_lookup_hit),
        .lookup_entry_o(directory_lookup_entry),
        .lookup_i_sharers_o(directory_lookup_i_sharers),
        .lookup_d_sharers_o(directory_lookup_d_sharers),
        .victim_valid_o(directory_victim_valid),
        .victim_entry_o(directory_victim_entry),
        .victim_line_addr_o(directory_victim_line_addr),
        .victim_i_sharers_o(directory_victim_i_sharers),
        .victim_d_sharers_o(directory_victim_d_sharers),
        .write_valid_i(directory_write_valid),
        .write_allocate_i(directory_allocate),
        .write_entry_i(directory_entry_q),
        .write_line_addr_i(request_line_addr),
        .write_add_i_sharers_i(
            directory_record ? directory_record_i :
                               {NUM_HARTS{1'b0}}),
        .write_add_d_sharers_i(
            directory_record ? directory_record_d :
                               {NUM_HARTS{1'b0}}),
        .write_clear_i_sharers_i({NUM_HARTS{1'b0}}),
        .write_clear_d_sharers_i(
            directory_clear ?
                ((req_op_q == `OPENRV64_CCX_OP_SC) ?
                 {NUM_HARTS{1'b1}} : probe_target_q) :
                              {NUM_HARTS{1'b0}})
    );

    wire probe_tracker_start =
        (state_q == ST_EVICT_PROBE_START) ||
        (state_q == ST_WRITE_PROBE_START);
    wire probe_tracker_start_ready;
    wire probe_tracker_done;
    wire probe_tracker_done_ready =
        (state_q == ST_EVICT_PROBE_WAIT) ||
        (state_q == ST_WRITE_PROBE_WAIT);
    wire [NUM_HARTS-1:0] probe_ack_valid;
    wire [NUM_HARTS-1:0] probe_ack_ready;
    wire probe_tracker_protocol_error;
    reg [NUM_HARTS-1:0] bad_probe_response;
    integer probe_response_hart;

    always @* begin
        bad_probe_response = {NUM_HARTS{1'b0}};
        for (probe_response_hart = 0;
             probe_response_hart < NUM_HARTS;
             probe_response_hart = probe_response_hart + 1) begin
            if (probe_resp_valid_i[probe_response_hart] &&
                ((probe_resp_kind_i[
                    probe_response_hart*
                    `OPENRV64_CCX_PROBE_RESP_WIDTH +:
                    `OPENRV64_CCX_PROBE_RESP_WIDTH] !=
                  `OPENRV64_CCX_PROBE_RESP_ACK) ||
                 probe_resp_error_i[probe_response_hart]))
                bad_probe_response[probe_response_hart] = 1'b1;
        end
    end

    assign probe_ack_valid =
        probe_resp_valid_i & ~bad_probe_response;
    assign probe_resp_ready_o = probe_ack_ready;

    openrv64_ccx_probe_tracker #(
        .NUM_HARTS(NUM_HARTS)
    ) u_probe_tracker (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .start_valid_i(probe_tracker_start),
        .start_ready_o(probe_tracker_start_ready),
        .start_target_harts_i(probe_target_q),
        .start_probe_id_i(next_probe_id_q),
        .start_command_i(`OPENRV64_CCX_PROBE_INV),
        .start_cache_mask_i(probe_cache_mask_q),
        .start_line_addr_i(probe_line_addr_q),
        .probe_valid_o(probe_valid_o),
        .probe_ready_i(probe_ready_i),
        .probe_id_o(probe_id_o),
        .probe_command_o(probe_command_o),
        .probe_cache_mask_o(probe_cache_mask_o),
        .probe_line_addr_o(probe_line_addr_o),
        .probe_ack_valid_i(probe_ack_valid),
        .probe_ack_ready_o(probe_ack_ready),
        .probe_ack_id_i(probe_resp_id_i),
        .busy_o(),
        .done_valid_o(probe_tracker_done),
        .done_ready_i(probe_tracker_done_ready),
        .done_probe_id_o(),
        .protocol_error_clear_i(protocol_error_clear_i),
        .protocol_error_o(probe_tracker_protocol_error)
    );

    assign req_ready_o =
        (state_q == ST_IDLE) &&
        (req_burst_len_i ==
         {`OPENRV64_CCX_BURST_LEN_WIDTH{1'b0}});
    assign wdata_ready_o = state_q == ST_WAIT_WDATA;

    assign resp_valid_o = state_q == ST_RESP;
    assign resp_hart_id_o = req_hart_id_q;
    assign resp_txn_id_o = req_txn_id_q;
    assign resp_source_id_o = req_source_id_q;
    assign resp_beat_index_o =
        {`OPENRV64_CCX_BEAT_INDEX_WIDTH{1'b0}};
    assign resp_last_o = 1'b1;
    assign resp_rdata_o = resp_rdata_q;
    assign resp_error_o = resp_error_q;
    assign resp_sc_success_o = resp_sc_success_q;

    assign l2_req_valid_o = state_q == ST_L2_REQ;
    assign l2_req_hart_id_o = req_hart_id_q;
    assign l2_req_txn_id_o = req_txn_id_q;
    assign l2_req_source_id_o = req_source_id_q;
    // L2 remains private-cache unaware.  The coherence home consumes LR/SC
    // intent and presents the successful data operations as ordinary reads
    // and writes.
    assign l2_req_op_o =
        (req_op_q == `OPENRV64_CCX_OP_LR) ?
            `OPENRV64_CCX_OP_READ :
        (req_op_q == `OPENRV64_CCX_OP_SC) ?
            `OPENRV64_CCX_OP_WRITE : req_op_q;
    assign l2_req_lock_o = 1'b0;
    assign l2_req_order_o = `OPENRV64_CCX_ORDER_NONE;
    assign l2_req_kind_o = req_kind_q;
    assign l2_req_attr_o = req_attr_q;
    assign l2_req_size_o = req_size_q;
    assign l2_req_addr_o = req_addr_q;
    assign l2_req_burst_len_o =
        {`OPENRV64_CCX_BURST_LEN_WIDTH{1'b0}};

    assign l2_wdata_valid_o = state_q == ST_L2_WDATA;
    assign l2_wdata_hart_id_o = req_hart_id_q;
    assign l2_wdata_txn_id_o = req_txn_id_q;
    assign l2_wdata_source_id_o = req_source_id_q;
    assign l2_wdata_beat_index_o =
        {`OPENRV64_CCX_BEAT_INDEX_WIDTH{1'b0}};
    assign l2_wdata_last_o = 1'b1;
    assign l2_wdata_o = wdata_q;
    assign l2_wstrb_o = wstrb_q;

    assign l2_resp_ready_o = state_q == ST_L2_RESP;
    wire l2_response_identity_error =
        (l2_resp_hart_id_i != req_hart_id_q) ||
        (l2_resp_txn_id_i != req_txn_id_q) ||
        (l2_resp_source_id_i != req_source_id_q) ||
        (l2_resp_beat_index_i !=
         {`OPENRV64_CCX_BEAT_INDEX_WIDTH{1'b0}}) ||
        !l2_resp_last_i;

    assign protocol_error_o =
        protocol_error_q | probe_tracker_protocol_error;

    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            state_q <= ST_IDLE;
            req_hart_id_q <= {`OPENRV64_CCX_HART_ID_WIDTH{1'b0}};
            req_txn_id_q <= {`OPENRV64_CCX_TXN_ID_WIDTH{1'b0}};
            req_source_id_q <=
                {`OPENRV64_CCX_SOURCE_ID_WIDTH{1'b0}};
            req_op_q <= `OPENRV64_CCX_OP_READ;
            req_order_q <= `OPENRV64_CCX_ORDER_NONE;
            req_kind_q <= `OPENRV64_CCX_KIND_LEGACY;
            req_attr_q <= `OPENRV64_CCX_ATTR_NONE;
            req_size_q <= 3'd0;
            req_addr_q <= 64'd0;
            command_error_q <= 1'b0;
            wdata_q <= {`OPENRV64_CCX_LINE_DATA_WIDTH{1'b0}};
            wstrb_q <= {`OPENRV64_CCX_LINE_STRB_WIDTH{1'b0}};
            resp_rdata_q <= {`OPENRV64_CCX_LINE_DATA_WIDTH{1'b0}};
            resp_error_q <= 1'b0;
            resp_sc_success_q <= 1'b0;
            directory_entry_q <= {DIRECTORY_ENTRY_WIDTH{1'b0}};
            probe_target_q <= {NUM_HARTS{1'b0}};
            probe_cache_mask_q <= `OPENRV64_CCX_PROBE_CACHE_NONE;
            probe_line_addr_q <= 64'd0;
            next_probe_id_q <=
                {`OPENRV64_CCX_PROBE_ID_WIDTH{1'b0}};
            protocol_error_q <= 1'b0;
            reservation_valid_q <= {NUM_HARTS{1'b0}};
            for (reservation_hart = 0;
                 reservation_hart < NUM_HARTS;
                 reservation_hart = reservation_hart + 1)
                reservation_line_q[reservation_hart] <= 64'd0;
        end else begin
            if (protocol_error_clear_i)
                protocol_error_q <= 1'b0;
            if ((state_q == ST_IDLE) && req_valid_i &&
                (req_burst_len_i !=
                 {`OPENRV64_CCX_BURST_LEN_WIDTH{1'b0}}))
                protocol_error_q <= 1'b1;
            if (|(bad_probe_response & probe_resp_ready_o))
                protocol_error_q <= 1'b1;

            if (request_fire) begin
                req_hart_id_q <= req_hart_id_i;
                req_txn_id_q <= req_txn_id_i;
                req_source_id_q <= req_source_id_i;
                req_op_q <= req_op_i;
                req_order_q <= req_order_i;
                req_kind_q <= req_kind_i;
                req_attr_q <= req_attr_i;
                req_size_q <= req_size_i;
                req_addr_q <= req_addr_i;
                command_error_q <= request_protocol_error;
                resp_rdata_q <=
                    {`OPENRV64_CCX_LINE_DATA_WIDTH{1'b0}};
                resp_error_q <= request_protocol_error;
                resp_sc_success_q <= 1'b0;
                if (request_protocol_error)
                    protocol_error_q <= 1'b1;
                if ((req_op_i == `OPENRV64_CCX_OP_WRITE) ||
                    (req_op_i == `OPENRV64_CCX_OP_SC))
                    state_q <= ST_WAIT_WDATA;
                else if (request_protocol_error)
                    state_q <= ST_RESP;
                else
                    state_q <= ST_DIR_LOOKUP;
            end

            case (state_q)
                ST_IDLE: begin
                    // Request acceptance and initial state selection are
                    // handled above so the live command fields are captured
                    // before any directory action.
                end

                ST_WAIT_WDATA: begin
                    if (wdata_fire) begin
                        wdata_q <= wdata_i;
                        wstrb_q <= wstrb_i;
                        if (command_error_q || wdata_protocol_error) begin
                            resp_error_q <= 1'b1;
                            protocol_error_q <= 1'b1;
                            state_q <= ST_RESP;
                        end else begin
                            state_q <= ST_DIR_LOOKUP;
                        end
                    end
                end

                ST_DIR_LOOKUP: begin
                    if ((req_op_q == `OPENRV64_CCX_OP_SC) &&
                        request_sc_reservation_match)
                        resp_sc_success_q <= 1'b1;
                    // Every SC attempt consumes the requester's reservation,
                    // including a failed SC to a different line.
                    if (req_op_q == `OPENRV64_CCX_OP_SC) begin
                        for (reservation_hart = 0;
                             reservation_hart < NUM_HARTS;
                             reservation_hart =
                                 reservation_hart + 1)
                            if (req_hart_id_q ==
                                `OPENRV64_CCX_HART_ID_WIDTH'(
                                    HART_ID_BASE +
                                    reservation_hart))
                                reservation_valid_q[
                                    reservation_hart] <= 1'b0;
                    end
                    if ((req_op_q == `OPENRV64_CCX_OP_SC) &&
                        !request_sc_reservation_match) begin
                        // Failed SC performs no write.  Its data beat was
                        // consumed before lookup so the command/data channel
                        // cannot be left wedged.
                        resp_sc_success_q <= 1'b0;
                        state_q <= ST_RESP;
                    end else if (request_private_fill) begin
                        if (directory_lookup_hit) begin
                            directory_entry_q <=
                                directory_lookup_entry;
                            state_q <= ST_L2_REQ;
                        end else begin
                            directory_entry_q <=
                                directory_victim_entry;
                            if (directory_victim_valid &&
                                (|(directory_victim_i_sharers |
                                   directory_victim_d_sharers))) begin
                                probe_target_q <=
                                    directory_victim_i_sharers |
                                    directory_victim_d_sharers;
                                probe_cache_mask_q <= {
                                    |directory_victim_d_sharers,
                                    |directory_victim_i_sharers
                                };
                                probe_line_addr_q <=
                                    directory_victim_line_addr;
                                state_q <= ST_EVICT_PROBE_START;
                            end else begin
                                state_q <= ST_DIR_ALLOCATE;
                            end
                        end
                    end else if (request_coherent_write &&
                                 directory_lookup_hit &&
                                 (|write_probe_targets)) begin
                        directory_entry_q <= directory_lookup_entry;
                        probe_target_q <= write_probe_targets;
                        probe_cache_mask_q <=
                            `OPENRV64_CCX_PROBE_CACHE_D;
                        probe_line_addr_q <= request_line_addr;
                        state_q <= ST_WRITE_PROBE_START;
                    end else if ((req_op_q == `OPENRV64_CCX_OP_SC) &&
                                 directory_lookup_hit) begin
                        // The successful SC requester already invalidated
                        // itself.  With no remote sharers left to probe, still
                        // pass through directory clear before writing L2.
                        directory_entry_q <= directory_lookup_entry;
                        probe_target_q <= {NUM_HARTS{1'b0}};
                        state_q <= ST_DIR_CLEAR;
                    end else begin
                        state_q <= ST_L2_REQ;
                    end

                    // Any write that will reach L2 invalidates every matching
                    // reservation.  The SC requester's reservation was
                    // already consumed above, including on failure.
                    if (request_coherent_write &&
                        ((req_op_q != `OPENRV64_CCX_OP_SC) ||
                         request_sc_reservation_match)) begin
                        for (reservation_hart = 0;
                             reservation_hart < NUM_HARTS;
                             reservation_hart =
                                 reservation_hart + 1)
                            if (reservation_valid_q[
                                    reservation_hart] &&
                                (reservation_line_q[
                                     reservation_hart] ==
                                 request_line_addr))
                                reservation_valid_q[
                                    reservation_hart] <= 1'b0;
                    end
                end

                ST_EVICT_PROBE_START: begin
                    if (probe_tracker_start_ready) begin
                        next_probe_id_q <= next_probe_id_q + 1'b1;
                        state_q <= ST_EVICT_PROBE_WAIT;
                    end
                end

                ST_EVICT_PROBE_WAIT: begin
                    if (probe_tracker_done)
                        state_q <= ST_DIR_ALLOCATE;
                end

                ST_DIR_ALLOCATE: begin
                    state_q <= ST_L2_REQ;
                end

                ST_WRITE_PROBE_START: begin
                    if (probe_tracker_start_ready) begin
                        next_probe_id_q <= next_probe_id_q + 1'b1;
                        state_q <= ST_WRITE_PROBE_WAIT;
                    end
                end

                ST_WRITE_PROBE_WAIT: begin
                    if (probe_tracker_done)
                        state_q <= ST_DIR_CLEAR;
                end

                ST_DIR_CLEAR: begin
                    state_q <= ST_L2_REQ;
                end

                ST_L2_REQ: begin
                    if (l2_request_fire) begin
                        if (request_is_write)
                            state_q <= ST_L2_WDATA;
                        else
                            state_q <= ST_L2_RESP;
                    end
                end

                ST_L2_WDATA: begin
                    if (l2_wdata_fire)
                        state_q <= ST_L2_RESP;
                end

                ST_L2_RESP: begin
                    if (l2_response_fire) begin
                        resp_rdata_q <= l2_resp_rdata_i;
                        resp_error_q <=
                            l2_resp_error_i ||
                            l2_response_identity_error;
                        if (req_op_q != `OPENRV64_CCX_OP_SC)
                            resp_sc_success_q <=
                                l2_resp_sc_success_i;
                        if (l2_response_identity_error)
                            protocol_error_q <= 1'b1;
                        if ((req_op_q == `OPENRV64_CCX_OP_LR) &&
                            !l2_resp_error_i &&
                            !l2_response_identity_error) begin
                            for (reservation_hart = 0;
                                 reservation_hart < NUM_HARTS;
                                 reservation_hart =
                                     reservation_hart + 1)
                                if (req_hart_id_q ==
                                    `OPENRV64_CCX_HART_ID_WIDTH'(
                                        HART_ID_BASE +
                                        reservation_hart)) begin
                                    reservation_valid_q[
                                        reservation_hart] <= 1'b1;
                                    reservation_line_q[
                                        reservation_hart] <=
                                        request_line_addr;
                                end
                        end
                        if (request_private_fill &&
                            !l2_resp_error_i &&
                            !l2_response_identity_error)
                            state_q <= ST_DIR_RECORD;
                        else
                            state_q <= ST_RESP;
                    end
                end

                ST_DIR_RECORD: begin
                    state_q <= ST_RESP;
                end

                ST_RESP: begin
                    if (response_fire)
                        state_q <= ST_IDLE;
                end

                default: begin
                    state_q <= ST_IDLE;
                    protocol_error_q <= 1'b1;
                end
            endcase
        end
    end

    generate
        if ((NUM_HARTS != 2) && (NUM_HARTS != 4)) begin : g_bad_harts
            initial
                $fatal(1,
                       "coherent protocol supports NUM_HARTS=2 or 4");
        end
        if ((HART_ID_BASE < 0) ||
            ((HART_ID_BASE + NUM_HARTS) > 16)) begin : g_bad_ids
            initial
                $fatal(1, "coherent protocol hart ID range is invalid");
        end
    endgenerate

endmodule
