`timescale 1ns/1ps
`include "complex/protocol/defs.v"
`include "complex/coherent/protocol/defs.v"

// One private-L1D invalidate-snoop endpoint.
//
// Probe acceptance is decoupled from invalidation completion.  Capturing a
// D-cache probe immediately clears the hart's LR reservation and holds the
// addressed invalidation against L1D until the cache has revoked the line.
// Only that real completion produces the matching probe response.
module openrv64_ccx_l1d_probe_endpoint #(
    parameter integer PROBE_TIMEOUT_CYCLES = 1024,
    parameter integer TIMEOUT_WIDTH =
        (PROBE_TIMEOUT_CYCLES > 1) ?
        $clog2(PROBE_TIMEOUT_CYCLES + 1) : 1
) (
    input  wire                         clk_i,
    input  wire                         rst_ni,

    input  wire                         probe_valid_i,
    output wire                         probe_ready_o,
    input  wire [`OPENRV64_CCX_PROBE_ID_WIDTH-1:0] probe_id_i,
    input  wire [`OPENRV64_CCX_PROBE_CMD_WIDTH-1:0] probe_command_i,
    input  wire [`OPENRV64_CCX_PROBE_CACHE_WIDTH-1:0]
                                               probe_cache_mask_i,
    input  wire [63:0]                  probe_line_addr_i,

    output wire                         probe_resp_valid_o,
    input  wire                         probe_resp_ready_i,
    output wire [`OPENRV64_CCX_PROBE_ID_WIDTH-1:0] probe_resp_id_o,
    output wire [`OPENRV64_CCX_PROBE_RESP_WIDTH-1:0]
                                               probe_resp_kind_o,
    output wire [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0]
                                               probe_resp_data_o,
    output wire                         probe_resp_error_o,

    output wire                         invalidate_valid_o,
    input  wire                         invalidate_ready_i,
    output wire [63:0]                  invalidate_addr_o,
    output wire                         clear_reservation_o,

    input  wire                         protocol_error_clear_i,
    output wire                         protocol_error_o
);

    localparam [TIMEOUT_WIDTH-1:0] TIMEOUT_LAST =
        TIMEOUT_WIDTH'(PROBE_TIMEOUT_CYCLES - 1);

    reg invalidate_pending_q;
    reg response_valid_q;
    reg [`OPENRV64_CCX_PROBE_ID_WIDTH-1:0] response_id_q;
    reg [`OPENRV64_CCX_PROBE_RESP_WIDTH-1:0] response_kind_q;
    reg response_error_q;
    reg [63:0] invalidate_addr_q;
    reg [TIMEOUT_WIDTH-1:0] timeout_q;
    reg protocol_error_q;

    wire incoming_dcache =
        |(probe_cache_mask_i & `OPENRV64_CCX_PROBE_CACHE_D);
    wire incoming_supported =
        probe_command_i == `OPENRV64_CCX_PROBE_INV;
    wire probe_fire = probe_valid_i && probe_ready_o;
    wire invalidate_fire =
        invalidate_pending_q && invalidate_ready_i;
    wire response_fire = response_valid_q && probe_resp_ready_i;

    assign probe_ready_o = !invalidate_pending_q && !response_valid_q;
    assign probe_resp_valid_o = response_valid_q;
    assign probe_resp_id_o = response_id_q;
    assign probe_resp_kind_o = response_kind_q;
    assign probe_resp_data_o =
        {`OPENRV64_CCX_LINE_DATA_WIDTH{1'b0}};
    assign probe_resp_error_o = response_error_q;
    assign invalidate_valid_o = invalidate_pending_q;
    assign invalidate_addr_o = invalidate_addr_q;
    assign clear_reservation_o = probe_fire && incoming_dcache;
    assign protocol_error_o = protocol_error_q;

    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            invalidate_pending_q <= 1'b0;
            response_valid_q <= 1'b0;
            response_id_q <=
                {`OPENRV64_CCX_PROBE_ID_WIDTH{1'b0}};
            response_kind_q <= `OPENRV64_CCX_PROBE_RESP_ACK;
            response_error_q <= 1'b0;
            invalidate_addr_q <= 64'd0;
            timeout_q <= {TIMEOUT_WIDTH{1'b0}};
            protocol_error_q <= 1'b0;
        end else begin
            if (protocol_error_clear_i)
                protocol_error_q <= 1'b0;

            if (response_fire) begin
                response_valid_q <= 1'b0;
                response_error_q <= 1'b0;
            end

            if (probe_fire) begin
                response_id_q <= probe_id_i;
                invalidate_addr_q <=
                    {probe_line_addr_i[63:6], 6'b0};
                timeout_q <= {TIMEOUT_WIDTH{1'b0}};
                if (!incoming_supported) begin
                    response_valid_q <= 1'b1;
                    response_kind_q <=
                        `OPENRV64_CCX_PROBE_RESP_ERROR;
                    response_error_q <= 1'b1;
                    protocol_error_q <= 1'b1;
                end else if (incoming_dcache) begin
                    invalidate_pending_q <= 1'b1;
                end else begin
                    // This endpoint represents only L1D.  An I-only probe is
                    // therefore a clean miss here.
                    response_valid_q <= 1'b1;
                    response_kind_q <=
                        `OPENRV64_CCX_PROBE_RESP_ACK;
                    response_error_q <= 1'b0;
                end
            end

            if (invalidate_fire) begin
                invalidate_pending_q <= 1'b0;
                response_valid_q <= 1'b1;
                response_kind_q <= `OPENRV64_CCX_PROBE_RESP_ACK;
                response_error_q <= 1'b0;
                timeout_q <= {TIMEOUT_WIDTH{1'b0}};
            end else if (invalidate_pending_q) begin
                if (timeout_q != TIMEOUT_LAST)
                    timeout_q <= timeout_q + 1'b1;
                else
                    // Never manufacture an ACK after timeout.  A missing
                    // release is a coherence fault, not permission to create
                    // a second owner.
                    protocol_error_q <= 1'b1;
            end
        end
    end

    generate
        if (PROBE_TIMEOUT_CYCLES < 1) begin : g_bad_timeout
            initial
                $fatal(1, "L1D probe timeout must be at least one cycle");
        end
    endgenerate

endmodule
