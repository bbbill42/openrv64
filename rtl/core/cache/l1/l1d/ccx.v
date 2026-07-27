`timescale 1ns/1ps
`include "complex/protocol/defs.v"

// CCX wire-format adapter for the L1D backend.
//
// Request selection, transaction ownership, and response routing deliberately
// remain outside this module.  This module owns only the protocol-facing
// command/data channel encoding and their independent ready/valid handshakes.
// That keeps the cache policy state out of the CCX pin-level implementation.
module openrv64_l1d_ccx_interface #(
    parameter integer COHERENT_ATOMICS = 0,
    parameter [`OPENRV64_CCX_HART_ID_WIDTH-1:0] HART_ID =
        {`OPENRV64_CCX_HART_ID_WIDTH{1'b0}}
) (
    input  wire                      send_valid_i,
    input  wire                      suppress_read_i,
    input  wire                      command_sent_i,
    input  wire                      wdata_sent_i,
    input  wire                      request_write_i,
    input  wire                      request_atomic_i,
    input  wire                      request_cacheable_i,
    input  wire                      request_line_read_i,
    input  wire [2:0]                request_size_i,
    input  wire [63:0]               request_addr_i,
    input  wire [`OPENRV64_CCX_TXN_ID_WIDTH-1:0]
                                     request_txn_id_i,
    input  wire [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0]
                                     request_wdata_i,
    input  wire [`OPENRV64_CCX_LINE_STRB_WIDTH-1:0]
                                     request_wstrb_i,

    output wire                      command_fire_o,
    output wire                      wdata_fire_o,

    output wire                      ccx_req_valid_o,
    input  wire                      ccx_req_ready_i,
    output wire [`OPENRV64_CCX_HART_ID_WIDTH-1:0]
                                     ccx_req_hart_id_o,
    output wire [`OPENRV64_CCX_TXN_ID_WIDTH-1:0]
                                     ccx_req_txn_id_o,
    output wire [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0]
                                     ccx_req_source_id_o,
    output wire [`OPENRV64_CCX_OP_WIDTH-1:0] ccx_req_op_o,
    output wire                      ccx_req_lock_o,
    output wire [`OPENRV64_CCX_ORDER_WIDTH-1:0] ccx_req_order_o,
    output wire [`OPENRV64_CCX_KIND_WIDTH-1:0] ccx_req_kind_o,
    output wire [`OPENRV64_CCX_ATTR_WIDTH-1:0] ccx_req_attr_o,
    output wire [2:0]                ccx_req_size_o,
    output wire [63:0]               ccx_req_addr_o,
    output wire [`OPENRV64_CCX_BURST_LEN_WIDTH-1:0]
                                     ccx_req_burst_len_o,

    output wire                      ccx_wdata_valid_o,
    input  wire                      ccx_wdata_ready_i,
    output wire [`OPENRV64_CCX_HART_ID_WIDTH-1:0]
                                     ccx_wdata_hart_id_o,
    output wire [`OPENRV64_CCX_TXN_ID_WIDTH-1:0]
                                     ccx_wdata_txn_id_o,
    output wire [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0]
                                     ccx_wdata_source_id_o,
    output wire [`OPENRV64_CCX_BEAT_INDEX_WIDTH-1:0]
                                     ccx_wdata_beat_index_o,
    output wire                      ccx_wdata_last_o,
    output wire [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0]
                                     ccx_wdata_o,
    output wire [`OPENRV64_CCX_LINE_STRB_WIDTH-1:0]
                                     ccx_wstrb_o,

    input  wire                      response_ready_i,
    input  wire                      ccx_resp_valid_i,
    output wire                      ccx_resp_ready_o,
    input  wire [`OPENRV64_CCX_HART_ID_WIDTH-1:0]
                                     ccx_resp_hart_id_i,
    input  wire [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0]
                                     ccx_resp_source_id_i,
    input  wire [`OPENRV64_CCX_BEAT_INDEX_WIDTH-1:0]
                                     ccx_resp_beat_index_i,
    input  wire                      ccx_resp_last_i,
    output wire                      response_fire_o,
    output wire                      response_for_dcache_o,
    output wire                      response_protocol_error_o
);

    assign ccx_req_valid_o = send_valid_i && !command_sent_i &&
                             !(suppress_read_i && !request_write_i);
    assign ccx_req_hart_id_o = HART_ID;
    assign ccx_req_txn_id_o = request_txn_id_i;
    assign ccx_req_source_id_o = `OPENRV64_CCX_SOURCE_DCACHE;
    // A coherent home owns the reservation used by a marked read/modify/write
    // sequence. Keep this opt-in: the single-hart native L2 still consumes
    // the established READ/WRITE compatibility encoding.
    assign ccx_req_op_o =
        (COHERENT_ATOMICS != 0) && request_atomic_i ?
            (request_write_i ? `OPENRV64_CCX_OP_SC :
                               `OPENRV64_CCX_OP_LR) :
            (request_write_i ? `OPENRV64_CCX_OP_WRITE :
                               `OPENRV64_CCX_OP_READ);
    assign ccx_req_lock_o = 1'b0;
    assign ccx_req_order_o = `OPENRV64_CCX_ORDER_NONE;
    assign ccx_req_kind_o = `OPENRV64_CCX_KIND_DATA;
    assign ccx_req_attr_o = request_cacheable_i ?
        `OPENRV64_CCX_ATTR_CACHEABLE : `OPENRV64_CCX_ATTR_DEVICE;
    assign ccx_req_size_o = request_line_read_i ? 3'd6 : request_size_i;
    assign ccx_req_addr_o = request_addr_i;
    assign ccx_req_burst_len_o =
        {`OPENRV64_CCX_BURST_LEN_WIDTH{1'b0}};

    assign ccx_wdata_valid_o = send_valid_i && request_write_i &&
                               !wdata_sent_i;
    assign ccx_wdata_hart_id_o = HART_ID;
    assign ccx_wdata_txn_id_o = request_txn_id_i;
    assign ccx_wdata_source_id_o = `OPENRV64_CCX_SOURCE_DCACHE;
    assign ccx_wdata_beat_index_o =
        {`OPENRV64_CCX_BEAT_INDEX_WIDTH{1'b0}};
    assign ccx_wdata_last_o = 1'b1;
    assign ccx_wdata_o = request_wdata_i;
    assign ccx_wstrb_o = request_wstrb_i;

    assign command_fire_o = ccx_req_valid_o && ccx_req_ready_i;
    assign wdata_fire_o = ccx_wdata_valid_o && ccx_wdata_ready_i;

    assign ccx_resp_ready_o = response_ready_i;
    assign response_fire_o = ccx_resp_valid_i && ccx_resp_ready_o;
    assign response_for_dcache_o =
        (ccx_resp_hart_id_i == HART_ID) &&
        (ccx_resp_source_id_i == `OPENRV64_CCX_SOURCE_DCACHE);
    assign response_protocol_error_o =
        (ccx_resp_beat_index_i !=
         {`OPENRV64_CCX_BEAT_INDEX_WIDTH{1'b0}}) ||
        !ccx_resp_last_i;

endmodule
