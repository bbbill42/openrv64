`timescale 1ns/1ps
`include "complex/protocol/defs.v"
`include "complex/coherent/protocol/defs.v"

// Fixed four-hart coherence-control variant.  This is not yet the complete
// CCX request/L2 datapath; it provides the directory and probe contract on
// which that datapath will be built.
`define OPENRV64_CCX_COHERENT_FIXED_MODULE openrv64_ccx_4h_control
`define OPENRV64_CCX_COHERENT_FIXED_HARTS 4
`include "complex/coherent/wrapper_fixed_template.vh"
`undef OPENRV64_CCX_COHERENT_FIXED_HARTS
`undef OPENRV64_CCX_COHERENT_FIXED_MODULE

`timescale 1ns/1ps

// Fixed four-hart L1D snoop termination.  The coherence home owns probe
// generation; this block provides four independent capture/invalidate/response
// paths so one hart's demand traffic cannot consume another hart's probe
// progress resources.
module openrv64_ccx_4h_l1d_probe_cluster #(
    parameter integer PROBE_TIMEOUT_CYCLES = 1024
) (
    input  wire                         clk_i,
    input  wire                         rst_ni,

    input  wire [3:0]                   probe_valid_i,
    output wire [3:0]                   probe_ready_o,
    input  wire [4*`OPENRV64_CCX_PROBE_ID_WIDTH-1:0] probe_id_i,
    input  wire [4*`OPENRV64_CCX_PROBE_CMD_WIDTH-1:0]
                                               probe_command_i,
    input  wire [4*`OPENRV64_CCX_PROBE_CACHE_WIDTH-1:0]
                                               probe_cache_mask_i,
    input  wire [4*64-1:0]              probe_line_addr_i,

    output wire [3:0]                   probe_resp_valid_o,
    input  wire [3:0]                   probe_resp_ready_i,
    output wire [4*`OPENRV64_CCX_PROBE_ID_WIDTH-1:0]
                                               probe_resp_id_o,
    output wire [4*`OPENRV64_CCX_PROBE_RESP_WIDTH-1:0]
                                               probe_resp_kind_o,
    output wire [4*`OPENRV64_CCX_LINE_DATA_WIDTH-1:0]
                                               probe_resp_data_o,
    output wire [3:0]                   probe_resp_error_o,

    output wire [3:0]                   l1d_invalidate_valid_o,
    input  wire [3:0]                   l1d_invalidate_ready_i,
    output wire [4*64-1:0]              l1d_invalidate_addr_o,
    output wire [3:0]                   clear_reservation_o,

    input  wire                         protocol_error_clear_i,
    output wire                         protocol_error_o
);

    wire [3:0] endpoint_protocol_error;
    genvar endpoint;
    generate
        for (endpoint = 0; endpoint < 4;
             endpoint = endpoint + 1) begin : g_endpoint
            openrv64_ccx_l1d_probe_endpoint #(
                .PROBE_TIMEOUT_CYCLES(PROBE_TIMEOUT_CYCLES)
            ) u_endpoint (
                .clk_i(clk_i),
                .rst_ni(rst_ni),
                .probe_valid_i(probe_valid_i[endpoint]),
                .probe_ready_o(probe_ready_o[endpoint]),
                .probe_id_i(
                    probe_id_i[
                        endpoint*`OPENRV64_CCX_PROBE_ID_WIDTH +:
                        `OPENRV64_CCX_PROBE_ID_WIDTH]),
                .probe_command_i(
                    probe_command_i[
                        endpoint*`OPENRV64_CCX_PROBE_CMD_WIDTH +:
                        `OPENRV64_CCX_PROBE_CMD_WIDTH]),
                .probe_cache_mask_i(
                    probe_cache_mask_i[
                        endpoint*`OPENRV64_CCX_PROBE_CACHE_WIDTH +:
                        `OPENRV64_CCX_PROBE_CACHE_WIDTH]),
                .probe_line_addr_i(
                    probe_line_addr_i[endpoint*64 +: 64]),
                .probe_resp_valid_o(
                    probe_resp_valid_o[endpoint]),
                .probe_resp_ready_i(
                    probe_resp_ready_i[endpoint]),
                .probe_resp_id_o(
                    probe_resp_id_o[
                        endpoint*`OPENRV64_CCX_PROBE_ID_WIDTH +:
                        `OPENRV64_CCX_PROBE_ID_WIDTH]),
                .probe_resp_kind_o(
                    probe_resp_kind_o[
                        endpoint*`OPENRV64_CCX_PROBE_RESP_WIDTH +:
                        `OPENRV64_CCX_PROBE_RESP_WIDTH]),
                .probe_resp_data_o(
                    probe_resp_data_o[
                        endpoint*`OPENRV64_CCX_LINE_DATA_WIDTH +:
                        `OPENRV64_CCX_LINE_DATA_WIDTH]),
                .probe_resp_error_o(
                    probe_resp_error_o[endpoint]),
                .invalidate_valid_o(
                    l1d_invalidate_valid_o[endpoint]),
                .invalidate_ready_i(
                    l1d_invalidate_ready_i[endpoint]),
                .invalidate_addr_o(
                    l1d_invalidate_addr_o[endpoint*64 +: 64]),
                .clear_reservation_o(
                    clear_reservation_o[endpoint]),
                .protocol_error_clear_i(
                    protocol_error_clear_i),
                .protocol_error_o(
                    endpoint_protocol_error[endpoint])
            );
        end
    endgenerate

    assign protocol_error_o = |endpoint_protocol_error;

endmodule
