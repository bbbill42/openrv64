`timescale 1ns/1ps
`include "core/backend/backend-defs.v"
`include "core/bus/bus-defs.v"
`include "core/isa/rv64-priv.v"
`include "complex/protocol/defs.v"
`include "complex/coherent/protocol/defs.v"

/*
 * Four full three-pipe cores behind one coherent CCX home and shared L2.
 *
 * This is deliberately below the platform boundary: there is no CLINT, PLIC,
 * UART, AXI fabric, or DDR controller.  All interrupt inputs are tied low and
 * a bounded-latency 512-bit memory terminates the L2 southbound interface.
 *
 * Plusargs select the original private-root image, a shared Sv39 address
 * space, or a shared physical image running S-mode with satp Bare.
 * Shared-space workloads use mhartid-indexed private pages; the atomic
 * workload additionally contends on one common LR/SC word.
 * This remains below the Linux/platform boundary and the current coherence
 * home serializes global transactions.
 */
module tb_4h_3p #(
    parameter integer MEMORY_LATENCY = 8,
    parameter integer L1I_CACHE_BYTES = 16 * 1024,
    parameter integer L1D_CACHE_BYTES = 16 * 1024,
    parameter integer L1D_PREFETCH_ENABLE = 1,
    parameter [63:0] SPEC_LOAD_BASE = 64'h0000_0000_4000_0000,
    parameter [63:0] SPEC_LOAD_SIZE = 64'h0000_0000_0002_0000,
    parameter integer L2_CACHE_BYTES = 256 * 1024,
    parameter integer L2_WAYS = 8,
    parameter integer L2_MSHRS = 8
);
    localparam integer NUM_HARTS = 4;
    localparam [63:0] PHYSICAL_BASE = 64'h0000_0000_8000_0000;
    localparam [63:0] VIRTUAL_BASE = 64'h0000_0000_4000_0000;
    localparam [63:0] PREFIX_STRIDE = 64'h0000_0000_0010_0000;
    localparam integer MEMORY_BYTES = 32'h0032_3000;
    localparam integer MEMORY_WORDS = MEMORY_BYTES / 64;
    localparam integer RETIRE_RESULT_PC_LSB = 329;

    logic clk;
    logic rst_n;

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
    wire [NUM_HARTS*`OPENRV64_CCX_ORDER_WIDTH-1:0]
        hart_req_order;
    wire [NUM_HARTS*`OPENRV64_CCX_KIND_WIDTH-1:0]
        hart_req_kind;
    wire [NUM_HARTS*`OPENRV64_CCX_ATTR_WIDTH-1:0]
        hart_req_attr;
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
    wire [NUM_HARTS-1:0] hart_resp_ready;
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
    wire [NUM_HARTS*`OPENRV64_CCX_PROBE_ID_WIDTH-1:0] probe_resp_id;
    wire [NUM_HARTS*`OPENRV64_CCX_PROBE_RESP_WIDTH-1:0]
        probe_resp_kind;
    wire [NUM_HARTS*`OPENRV64_CCX_LINE_DATA_WIDTH-1:0]
        probe_resp_data;
    wire [NUM_HARTS-1:0] probe_resp_error;
    wire [NUM_HARTS-1:0] l1d_invalidate_valid;
    wire [NUM_HARTS-1:0] l1d_invalidate_ready;
    wire [NUM_HARTS*64-1:0] l1d_invalidate_addr;
    wire [NUM_HARTS-1:0] coherent_reservation_clear;

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

    wire [NUM_HARTS*64-1:0] dbg_pc;
    wire [NUM_HARTS*32-1:0] dbg_instr;
    wire [NUM_HARTS-1:0] dbg_halted;

    logic [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0]
        memory [0:MEMORY_WORDS-1];
    logic memory_pending;
    logic memory_pending_write;
    logic [63:0] memory_pending_addr;
    integer memory_delay;
    integer memory_index;
    integer memory_byte;
    integer memory_reads;
    integer memory_writes;

    logic [63:0] done_pc;
    logic [63:0] mailbox_va;
    logic [63:0] result_va;
    logic [63:0] atomic_counter_va;
    logic done_pc_valid;
    logic mailbox_va_valid;
    logic result_va_valid;
    logic atomic_counter_va_valid;
    integer shared_satp;
    integer bare_mode;
    integer mailbox_stride;
    integer result_expected;
    integer atomic_expected;
    integer atomic_test;
    integer atomic_debug;
    integer max_cycles;
    integer cycles;
    integer first_done_cycle;
    logic progress_before_first_done;

    logic done_seen [0:NUM_HARTS-1];
    logic mailbox_seen [0:NUM_HARTS-1];
    logic result_seen [0:NUM_HARTS-1];
    logic root_seen [0:NUM_HARTS-1];
    logic satp_seen [0:NUM_HARTS-1];
    logic supervisor_fetch_seen [0:NUM_HARTS-1];
    integer done_cycle [0:NUM_HARTS-1];
    integer retired [0:NUM_HARTS-1];
    integer requests [0:NUM_HARTS-1];
    integer store_allocations [0:NUM_HARTS-1];
    integer fast_store_requests [0:NUM_HARTS-1];
    integer fallback_store_requests [0:NUM_HARTS-1];

    logic l2_write_active;
    logic [63:0] l2_write_addr;
    logic [`OPENRV64_CCX_HART_ID_WIDTH-1:0] l2_write_hart;
    integer atomic_last_value;
    logic atomic_final_seen;
    integer atomic_l2_successes [0:NUM_HARTS-1];
    integer lr_requests [0:NUM_HARTS-1];
    integer sc_requests [0:NUM_HARTS-1];
    integer sc_successes [0:NUM_HARTS-1];
    integer sc_failures [0:NUM_HARTS-1];
    integer atomic_line_probes [0:NUM_HARTS-1];
    integer reservation_clears [0:NUM_HARTS-1];
    logic home_request_active;
    logic [`OPENRV64_CCX_OP_WIDTH-1:0] home_request_op;
    logic [`OPENRV64_CCX_HART_ID_WIDTH-1:0] home_request_hart;
    logic protocol_error;
    logic probe_endpoint_protocol_error;

    function automatic [63:0] hart_prefix(input integer hart);
        hart_prefix = PHYSICAL_BASE + PREFIX_STRIDE * hart;
    endfunction

    function automatic [63:0] hart_image_base(input integer hart);
        hart_image_base = ((shared_satp != 0) || (bare_mode != 0)) ?
            PHYSICAL_BASE : hart_prefix(hart);
    endfunction

    function automatic [63:0] hart_root_pa(input integer hart);
        hart_root_pa = hart_image_base(hart) + 64'h20000;
    endfunction

    function automatic [63:0] hart_va_pa(
        input integer hart,
        input [63:0] virtual_address
    );
        if (bare_mode != 0)
            hart_va_pa = virtual_address + mailbox_stride * hart;
        else
            hart_va_pa = hart_image_base(hart) +
                (virtual_address - VIRTUAL_BASE) +
                ((shared_satp != 0) ? mailbox_stride * hart : 0);
    endfunction

    function automatic integer memory_line(input [63:0] address);
        memory_line = (address - PHYSICAL_BASE) >> 6;
    endfunction

    function automatic [63:0] mailbox_pa(input integer hart);
        mailbox_pa = hart_va_pa(hart, mailbox_va);
    endfunction

    function automatic [63:0] result_pa(input integer hart);
        result_pa = hart_va_pa(hart, result_va);
    endfunction

    function automatic [63:0] atomic_counter_pa;
        atomic_counter_pa =
            PHYSICAL_BASE + (atomic_counter_va - VIRTUAL_BASE);
    endfunction

    genvar hart;
    generate
        for (hart = 0; hart < NUM_HARTS; hart = hart + 1) begin : g_hart
            wire hart_done_retired =
                (u_core.backend_retire_arch[0] &&
                 (u_core.u_backend.queue_retire_result[
                      0*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +
                      RETIRE_RESULT_PC_LSB +: 64] == done_pc)) ||
                (u_core.backend_retire_arch[1] &&
                 (u_core.u_backend.queue_retire_result[
                      1*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +
                      RETIRE_RESULT_PC_LSB +: 64] == done_pc)) ||
                (u_core.backend_retire_arch[2] &&
                 (u_core.u_backend.queue_retire_result[
                      2*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +
                      RETIRE_RESULT_PC_LSB +: 64] == done_pc));

            openrv64_rv64_top_3p #(
                .RESET_VECTOR(PHYSICAL_BASE),
                .BUS_CONFIG(`OPENRV64_BUS_AXI),
                .HART_ID(`OPENRV64_CCX_HART_ID_WIDTH'(hart)),
                .ENABLE_ISSUE_WINDOW(1),
                .ENABLE_SPECULATION_WINDOW(1),
                .ENABLE_POSTED_STORES(1),
                .RETIRE_DEPTH(16),
                .PHYS_REG_COUNT(31),
                .ENABLE_L1I(1),
                .ENABLE_L1D(1),
                .ENABLE_L1D_COHERENCE_PROBES(1),
                .ENABLE_COHERENT_ATOMICS(1),
                .L1I_CACHE_BYTES(L1I_CACHE_BYTES),
                .L1D_CACHE_BYTES(L1D_CACHE_BYTES),
                .L1D_PREFETCH_ENABLE(L1D_PREFETCH_ENABLE),
                .SPEC_LOAD_BASE(SPEC_LOAD_BASE),
                .SPEC_LOAD_SIZE(SPEC_LOAD_SIZE)
            ) u_core (
                .clk(clk),
                .rst_n(rst_n),
                .mem_ready(1'b0),
                .mem_rdata(64'd0),
                .mem_error(1'b0),
                .pair512_req_ready(1'b0),
                .pair512_resp_valid(1'b0),
                .pair512_resp_predicted_addr(64'd0),
                .pair512_resp_predicted_data(
                    {`OPENRV64_AXI_DATA_WIDTH{1'b0}}),
                .pair512_resp_unpredicted_addr(64'd0),
                .pair512_resp_unpredicted_data(
                    {`OPENRV64_AXI_DATA_WIDTH{1'b0}}),
                .pair1024_req_ready(1'b0),
                .pair1024_resp_valid(1'b0),
                .pair1024_resp_predicted_addr(64'd0),
                .pair1024_resp_predicted_data(
                    {`OPENRV64_CCX_LINE_DATA_WIDTH{1'b0}}),
                .pair1024_resp_unpredicted_addr(64'd0),
                .pair1024_resp_unpredicted_data(
                    {`OPENRV64_CCX_LINE_DATA_WIDTH{1'b0}}),
                .m_axi_arready(1'b0),
                .m_axi_rid({`OPENRV64_AXI_ID_WIDTH{1'b0}}),
                .m_axi_rdata({`OPENRV64_AXI_DATA_WIDTH{1'b0}}),
                .m_axi_rresp(2'b00),
                .m_axi_rlast(1'b1),
                .m_axi_rvalid(1'b0),
                .m_axi_awready(1'b0),
                .m_axi_wready(1'b0),
                .m_axi_bid({`OPENRV64_AXI_ID_WIDTH{1'b0}}),
                .m_axi_bresp(2'b00),
                .m_axi_bvalid(1'b0),
                .ccx_req_valid(hart_req_valid[hart]),
                .ccx_req_ready(hart_req_ready[hart]),
                .ccx_req_hart_id(
                    hart_req_hart_id[
                        hart*`OPENRV64_CCX_HART_ID_WIDTH +:
                        `OPENRV64_CCX_HART_ID_WIDTH]),
                .ccx_req_txn_id(
                    hart_req_txn_id[
                        hart*`OPENRV64_CCX_TXN_ID_WIDTH +:
                        `OPENRV64_CCX_TXN_ID_WIDTH]),
                .ccx_req_source_id(
                    hart_req_source_id[
                        hart*`OPENRV64_CCX_SOURCE_ID_WIDTH +:
                        `OPENRV64_CCX_SOURCE_ID_WIDTH]),
                .ccx_req_op(
                    hart_req_op[
                        hart*`OPENRV64_CCX_OP_WIDTH +:
                        `OPENRV64_CCX_OP_WIDTH]),
                .ccx_req_lock(hart_req_lock[hart]),
                .ccx_req_order(
                    hart_req_order[
                        hart*`OPENRV64_CCX_ORDER_WIDTH +:
                        `OPENRV64_CCX_ORDER_WIDTH]),
                .ccx_req_kind(
                    hart_req_kind[
                        hart*`OPENRV64_CCX_KIND_WIDTH +:
                        `OPENRV64_CCX_KIND_WIDTH]),
                .ccx_req_attr(
                    hart_req_attr[
                        hart*`OPENRV64_CCX_ATTR_WIDTH +:
                        `OPENRV64_CCX_ATTR_WIDTH]),
                .ccx_req_size(hart_req_size[hart*3 +: 3]),
                .ccx_req_addr(hart_req_addr[hart*64 +: 64]),
                .ccx_req_burst_len(
                    hart_req_burst_len[
                        hart*`OPENRV64_CCX_BURST_LEN_WIDTH +:
                        `OPENRV64_CCX_BURST_LEN_WIDTH]),
                .ccx_wdata_valid(hart_wdata_valid[hart]),
                .ccx_wdata_ready(hart_wdata_ready[hart]),
                .ccx_wdata_hart_id(
                    hart_wdata_hart_id[
                        hart*`OPENRV64_CCX_HART_ID_WIDTH +:
                        `OPENRV64_CCX_HART_ID_WIDTH]),
                .ccx_wdata_txn_id(
                    hart_wdata_txn_id[
                        hart*`OPENRV64_CCX_TXN_ID_WIDTH +:
                        `OPENRV64_CCX_TXN_ID_WIDTH]),
                .ccx_wdata_source_id(
                    hart_wdata_source_id[
                        hart*`OPENRV64_CCX_SOURCE_ID_WIDTH +:
                        `OPENRV64_CCX_SOURCE_ID_WIDTH]),
                .ccx_wdata_beat_index(
                    hart_wdata_beat_index[
                        hart*`OPENRV64_CCX_BEAT_INDEX_WIDTH +:
                        `OPENRV64_CCX_BEAT_INDEX_WIDTH]),
                .ccx_wdata_last(hart_wdata_last[hart]),
                .ccx_wdata(
                    hart_wdata[
                        hart*`OPENRV64_CCX_LINE_DATA_WIDTH +:
                        `OPENRV64_CCX_LINE_DATA_WIDTH]),
                .ccx_wstrb(
                    hart_wstrb[
                        hart*`OPENRV64_CCX_LINE_STRB_WIDTH +:
                        `OPENRV64_CCX_LINE_STRB_WIDTH]),
                .ccx_resp_valid(hart_resp_valid[hart]),
                .ccx_resp_ready(hart_resp_ready[hart]),
                .ccx_resp_hart_id(
                    hart_resp_hart_id[
                        hart*`OPENRV64_CCX_HART_ID_WIDTH +:
                        `OPENRV64_CCX_HART_ID_WIDTH]),
                .ccx_resp_txn_id(
                    hart_resp_txn_id[
                        hart*`OPENRV64_CCX_TXN_ID_WIDTH +:
                        `OPENRV64_CCX_TXN_ID_WIDTH]),
                .ccx_resp_source_id(
                    hart_resp_source_id[
                        hart*`OPENRV64_CCX_SOURCE_ID_WIDTH +:
                        `OPENRV64_CCX_SOURCE_ID_WIDTH]),
                .ccx_resp_beat_index(
                    hart_resp_beat_index[
                        hart*`OPENRV64_CCX_BEAT_INDEX_WIDTH +:
                        `OPENRV64_CCX_BEAT_INDEX_WIDTH]),
                .ccx_resp_last(hart_resp_last[hart]),
                .ccx_resp_rdata(
                    hart_resp_rdata[
                        hart*`OPENRV64_CCX_LINE_DATA_WIDTH +:
                        `OPENRV64_CCX_LINE_DATA_WIDTH]),
                .ccx_resp_error(hart_resp_error[hart]),
                .ccx_resp_sc_success(hart_resp_sc_success[hart]),
                .l1d_probe_valid_i(l1d_invalidate_valid[hart]),
                .l1d_probe_ready_o(l1d_invalidate_ready[hart]),
                .l1d_probe_addr_i(
                    l1d_invalidate_addr[hart*64 +: 64]),
                .coherent_reservation_clear_i(
                    coherent_reservation_clear[hart]),
                .irq_m_software(1'b0),
                .irq_m_timer(1'b0),
                .irq_m_external(1'b0),
                .irq_s_software(1'b0),
                .irq_s_timer(1'b0),
                .irq_s_external(1'b0),
                .dbg_pc(dbg_pc[hart*64 +: 64]),
                .dbg_instr(dbg_instr[hart*32 +: 32]),
                .dbg_halted(dbg_halted[hart])
            );

            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    done_seen[hart] <= 1'b0;
                    done_cycle[hart] <= -1;
                    retired[hart] <= 0;
                    requests[hart] <= 0;
                    store_allocations[hart] <= 0;
                    fast_store_requests[hart] <= 0;
                    fallback_store_requests[hart] <= 0;
                    root_seen[hart] <= 1'b0;
                    satp_seen[hart] <= 1'b0;
                    supervisor_fetch_seen[hart] <= 1'b0;
                end else begin
                    if ((atomic_debug != 0) && (cycles != 0) &&
                        ((cycles % 500) == 0))
                        $display(
                            "ATOMIC_HART_DEBUG cycle=%0d hart=%0d active=%b irrev=%b inflight=%b engine_state=%0d engine_op=%0d local_res=%b l1_backend=%0d l1_res_req=%b l1_res_done=%b l1_req=%b/%b",
                            cycles, hart,
                            u_core.u_backend.u_exec.g_3p.u_exec.u_lsu.u_atomics.active_q,
                            u_core.u_backend.u_exec.g_3p.u_exec.u_lsu.u_atomics.irrevocable_q,
                            u_core.u_backend.u_exec.g_3p.u_exec.u_lsu.u_atomics.req_inflight_q,
                            u_core.u_backend.u_exec.g_3p.u_exec.u_lsu.u_atomics.u_engine.state_q,
                            u_core.u_backend.u_exec.g_3p.u_exec.u_lsu.u_atomics.u_engine.op_q,
                            u_core.u_backend.u_exec.g_3p.u_exec.u_lsu.u_atomics.u_engine.reservation_valid_q,
                            u_core.u_bus.g_ccx.u_bus.u_l1d.backend_state_q,
                            u_core.u_bus.g_ccx.u_bus.u_l1d.request_reservation_q,
                            u_core.u_bus.g_ccx.u_bus.u_l1d.coherent_lr_reservation_done_q,
                            u_core.u_bus.g_ccx.u_bus.u_l1d.req_valid_i,
                            u_core.u_bus.g_ccx.u_bus.u_l1d.req_ready_o);
                    retired[hart] <= retired[hart] +
                        u_core.backend_retire_arch[0] +
                        u_core.backend_retire_arch[1] +
                        u_core.backend_retire_arch[2];
                    if (u_core.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq.
                        store_alloc_fire)
                        store_allocations[hart] <=
                            store_allocations[hart] + 1;
                    if (u_core.u_bus.g_ccx.u_bus.pipe_fast_request_fire &&
                        u_core.u_bus.g_ccx.u_bus.lsu_pipe_req_write_i)
                        fast_store_requests[hart] <=
                            fast_store_requests[hart] + 1;
                    if (u_core.u_bus.g_ccx.u_bus.pipe_fallback_candidate &&
                        u_core.u_bus.g_ccx.u_bus.lsu_pipe_req_ready_o &&
                        u_core.u_bus.g_ccx.u_bus.lsu_pipe_req_write_i)
                        fallback_store_requests[hart] <=
                            fallback_store_requests[hart] + 1;
                    if (hart_req_valid[hart] &&
                        hart_req_ready[hart]) begin
                        requests[hart] <= requests[hart] + 1;
                        if ((hart_req_source_id[
                                 hart*`OPENRV64_CCX_SOURCE_ID_WIDTH +:
                                 `OPENRV64_CCX_SOURCE_ID_WIDTH] ==
                             `OPENRV64_CCX_SOURCE_PTW) &&
                            ((hart_req_addr[hart*64 +: 64] &
                              64'hffff_ffff_ffff_ffc0) ==
                             hart_root_pa(hart)))
                            root_seen[hart] <= 1'b1;
                        if ((hart_req_source_id[
                                 hart*`OPENRV64_CCX_SOURCE_ID_WIDTH +:
                                 `OPENRV64_CCX_SOURCE_ID_WIDTH] ==
                            `OPENRV64_CCX_SOURCE_ICACHE) &&
                            (hart_req_addr[hart*64 +: 64] >=
                             hart_image_base(hart) + 64'h1000) &&
                            (hart_req_addr[hart*64 +: 64] <
                             hart_image_base(hart) + 64'h20000))
                            supervisor_fetch_seen[hart] <= 1'b1;
                    end
                    if ((bare_mode != 0) &&
                        (u_core.csr_priv_mode == `RV64_PRIV_S) &&
                        (u_core.csr_satp_mode ==
                         `RV64_SATP_MODE_BARE))
                        satp_seen[hart] <= 1'b1;
                    else if ((u_core.csr_priv_mode == `RV64_PRIV_S) &&
                             (u_core.csr_satp_mode ==
                              `RV64_SATP_MODE_SV39)) begin
                        if ((u_core.csr_satp_root_ppn !=
                             (hart_root_pa(hart) >> 12)) ||
                            (u_core.csr_satp_asid != 0))
                            $fatal(1,
                                "hart %0d wrong SATP mode=%0d asid=%0d ppn=%h expected=%h",
                                hart, u_core.csr_satp_mode,
                                u_core.csr_satp_asid,
                                u_core.csr_satp_root_ppn,
                                (hart_root_pa(hart) >> 12));
                        satp_seen[hart] <= 1'b1;
                    end
                    if (done_pc_valid && hart_done_retired &&
                        !done_seen[hart]) begin
                        done_seen[hart] <= 1'b1;
                        done_cycle[hart] <= cycles;
                    end
                end
            end
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
        .DIRECTORY_ENTRIES(1024),
        .DIRECTORY_WAYS(4)
    ) u_coherence_home (
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
        .CACHE_BYTES(L2_CACHE_BYTES),
        .LINE_BYTES(64),
        .WAYS(L2_WAYS),
        .MSHR_ENTRIES(L2_MSHRS),
        .WAITERS_PER_MSHR(8),
        .COMMAND_ENTRIES(16),
        .RESPONSE_ENTRIES(16),
        .BUS_TRACK_ENTRIES(L2_MSHRS)
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

    openrv64_ccx_4h_l1d_probe_cluster #(
        .PROBE_TIMEOUT_CYCLES(65536)
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
        .clear_reservation_o(coherent_reservation_clear),
        .protocol_error_clear_i(1'b0),
        .protocol_error_o(probe_endpoint_protocol_error)
    );

    assign bus_req_ready = !memory_pending && !bus_resp_valid;

    /*
     * The coherent home is globally blocking, so one accepted request owns
     * the response channel until completion.  Count architected LR/SC traffic
     * and distinguish failed SC responses from writes that reached L2.
     */
    integer atomic_hart;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            home_request_active <= 1'b0;
            home_request_op <= `OPENRV64_CCX_OP_READ;
            home_request_hart <=
                {`OPENRV64_CCX_HART_ID_WIDTH{1'b0}};
            for (atomic_hart = 0;
                 atomic_hart < NUM_HARTS;
                 atomic_hart = atomic_hart + 1) begin
                lr_requests[atomic_hart] <= 0;
                sc_requests[atomic_hart] <= 0;
                sc_successes[atomic_hart] <= 0;
                sc_failures[atomic_hart] <= 0;
                atomic_line_probes[atomic_hart] <= 0;
                reservation_clears[atomic_hart] <= 0;
            end
        end else begin
            for (atomic_hart = 0;
                 atomic_hart < NUM_HARTS;
                 atomic_hart = atomic_hart + 1) begin
                if (coherent_reservation_clear[atomic_hart])
                    reservation_clears[atomic_hart] <=
                        reservation_clears[atomic_hart] + 1;
                if ((atomic_test != 0) &&
                    atomic_counter_va_valid &&
                    probe_valid[atomic_hart] &&
                    probe_ready[atomic_hart] &&
                    (probe_command[
                         atomic_hart*`OPENRV64_CCX_PROBE_CMD_WIDTH +:
                         `OPENRV64_CCX_PROBE_CMD_WIDTH] ==
                     `OPENRV64_CCX_PROBE_INV) &&
                    (|(probe_cache_mask[
                          atomic_hart*`OPENRV64_CCX_PROBE_CACHE_WIDTH +:
                          `OPENRV64_CCX_PROBE_CACHE_WIDTH] &
                       `OPENRV64_CCX_PROBE_CACHE_D)) &&
                    (probe_line_addr[atomic_hart*64 +: 64] ==
                     (atomic_counter_pa() &
                      64'hffff_ffff_ffff_ffc0)))
                    atomic_line_probes[atomic_hart] <=
                        atomic_line_probes[atomic_hart] + 1;
            end
            if (ccx_req_valid && ccx_req_ready) begin
                if (home_request_active)
                    $fatal(1,
                        "coherence home accepted overlapping requests");
                home_request_active <= 1'b1;
                home_request_op <= ccx_req_op;
                home_request_hart <= ccx_req_hart_id;
                if (ccx_req_op == `OPENRV64_CCX_OP_LR)
                    lr_requests[ccx_req_hart_id] <=
                        lr_requests[ccx_req_hart_id] + 1;
                if (ccx_req_op == `OPENRV64_CCX_OP_SC)
                    sc_requests[ccx_req_hart_id] <=
                        sc_requests[ccx_req_hart_id] + 1;
            end

            if (ccx_resp_valid && ccx_resp_ready) begin
                if (!home_request_active)
                    $fatal(1,
                        "coherence home produced response without request");
                if (ccx_resp_hart_id != home_request_hart)
                    $fatal(1,
                        "coherence home response changed hart request=%0d response=%0d",
                        home_request_hart, ccx_resp_hart_id);
                if (home_request_op == `OPENRV64_CCX_OP_SC) begin
                    if (ccx_resp_sc_success)
                        sc_successes[home_request_hart] <=
                            sc_successes[home_request_hart] + 1;
                    else
                        sc_failures[home_request_hart] <=
                            sc_failures[home_request_hart] + 1;
                end
                home_request_active <= 1'b0;
            end
        end
    end

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
            memory_reads <= 0;
            memory_writes <= 0;
        end else begin
            if (bus_resp_valid && bus_resp_ready)
                bus_resp_valid <= 1'b0;

            if (bus_req_valid && bus_req_ready) begin
                if ((bus_req_size != 3'd6) ||
                    (bus_req_addr[5:0] != 6'd0) ||
                    !bus_req_cacheable ||
                    (bus_req_addr < PHYSICAL_BASE) ||
                    (bus_req_addr >= PHYSICAL_BASE + MEMORY_BYTES))
                    $fatal(1,
                        "malformed/out-of-range L2 memory request addr=%h size=%0d",
                        bus_req_addr, bus_req_size);
                memory_pending <= 1'b1;
                memory_pending_write <= bus_req_write;
                memory_pending_addr <= bus_req_addr;
                memory_delay <= MEMORY_LATENCY - 1;
                if (bus_req_write) begin
                    memory_writes <= memory_writes + 1;
                    for (memory_byte = 0;
                         memory_byte <
                             `OPENRV64_CCX_LINE_STRB_WIDTH;
                         memory_byte = memory_byte + 1)
                        if (bus_req_wstrb[memory_byte])
                            memory[memory_line(bus_req_addr)][
                                memory_byte*8 +: 8] <=
                                bus_req_wdata[memory_byte*8 +: 8];
                end else begin
                    memory_reads <= memory_reads + 1;
                end
            end else if (memory_pending) begin
                if (memory_delay == 0) begin
                    memory_pending <= 1'b0;
                    bus_resp_valid <= 1'b1;
                    bus_resp_rdata <= memory_pending_write ?
                        {`OPENRV64_CCX_LINE_DATA_WIDTH{1'b0}} :
                        memory[memory_line(memory_pending_addr)];
                end else begin
                    memory_delay <= memory_delay - 1;
                end
            end
        end
    end

    /*
     * Track the L2-facing write command/data pair.  Checking here, above the
     * write-back L2, proves each identical virtual mailbox reached the
     * physical prefix selected by that hart's page tables.
     */
    integer mailbox_hart;
    integer mailbox_byte_offset;
    integer result_byte_offset;
    integer atomic_byte_offset;
    logic [31:0] observed_atomic_value;
    logic [63:0] observed_write_addr;
    logic [`OPENRV64_CCX_HART_ID_WIDTH-1:0] observed_write_hart;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            l2_write_active <= 1'b0;
            l2_write_addr <= 64'd0;
            l2_write_hart <=
                {`OPENRV64_CCX_HART_ID_WIDTH{1'b0}};
            atomic_last_value <= 0;
            atomic_final_seen <= 1'b0;
            for (mailbox_hart = 0;
                 mailbox_hart < NUM_HARTS;
                 mailbox_hart = mailbox_hart + 1) begin
                mailbox_seen[mailbox_hart] <= 1'b0;
                result_seen[mailbox_hart] <= 1'b0;
                atomic_l2_successes[mailbox_hart] <= 0;
            end
        end else begin
            if (l2_req_valid && l2_req_ready &&
                (l2_req_op == `OPENRV64_CCX_OP_WRITE)) begin
                if (l2_write_active)
                    $fatal(1, "overlapping L2 write commands in scoreboard");
                l2_write_active <= 1'b1;
                l2_write_addr <= l2_req_addr;
                l2_write_hart <= l2_req_hart_id;
            end

            if (l2_wdata_valid && l2_wdata_ready) begin
                observed_write_addr = l2_write_active ?
                    l2_write_addr : l2_req_addr;
                observed_write_hart = l2_write_active ?
                    l2_write_hart : l2_req_hart_id;
                if (!l2_write_active &&
                    !(l2_req_valid && l2_req_ready &&
                      (l2_req_op == `OPENRV64_CCX_OP_WRITE)))
                    $fatal(1, "L2 write data without a write command");
                l2_write_active <= 1'b0;

                for (mailbox_hart = 0;
                     mailbox_hart < NUM_HARTS;
                     mailbox_hart = mailbox_hart + 1) begin
                    if (mailbox_va_valid &&
                        ((observed_write_addr &
                          64'hffff_ffff_ffff_ffc0) ==
                         (mailbox_pa(mailbox_hart) &
                          64'hffff_ffff_ffff_ffc0))) begin
                        mailbox_byte_offset =
                            mailbox_pa(mailbox_hart)[5:0];
                        if (l2_wstrb[
                                mailbox_byte_offset +: 4] == 4'hf) begin
                            if ((observed_write_hart != mailbox_hart) ||
                                (l2_wdata[
                                     mailbox_byte_offset*8 +: 32] !=
                                 32'(mailbox_hart + 1)))
                                $fatal(1,
                                    "bad mailbox write hart=%0d owner=%0d addr=%h data=%h strb=%h",
                                    mailbox_hart, observed_write_hart,
                                    observed_write_addr, l2_wdata,
                                    l2_wstrb);
                            mailbox_seen[mailbox_hart] <= 1'b1;
                            $display(
                                "MAILBOX_VISIBLE cycle=%0d hart=%0d pa=%h value=%0d",
                                cycles, mailbox_hart,
                                mailbox_pa(mailbox_hart),
                                mailbox_hart + 1);
                        end
                    end

                    if (result_va_valid &&
                        ((observed_write_addr &
                          64'hffff_ffff_ffff_ffc0) ==
                         (result_pa(mailbox_hart) &
                          64'hffff_ffff_ffff_ffc0))) begin
                        result_byte_offset =
                            result_pa(mailbox_hart)[5:0];
                        if (l2_wstrb[
                                result_byte_offset +: 4] == 4'hf) begin
                            if ((observed_write_hart != mailbox_hart) ||
                                (l2_wdata[
                                     result_byte_offset*8 +: 32] !=
                                 32'(result_expected)))
                                $fatal(1,
                                    "bad result write hart=%0d owner=%0d addr=%h value=%0d expected=%0d",
                                    mailbox_hart, observed_write_hart,
                                    observed_write_addr,
                                    l2_wdata[
                                        result_byte_offset*8 +: 32],
                                    result_expected);
                            result_seen[mailbox_hart] <= 1'b1;
                        end
                    end
                end

                if (atomic_counter_va_valid &&
                    ((observed_write_addr &
                      64'hffff_ffff_ffff_ffc0) ==
                     (atomic_counter_pa() &
                      64'hffff_ffff_ffff_ffc0))) begin
                    atomic_byte_offset = atomic_counter_pa() & 63;
                    if (l2_wstrb[
                            atomic_byte_offset +: 4] != 4'hf)
                        $fatal(1,
                            "partial atomic counter write addr=%h strb=%h",
                            observed_write_addr, l2_wstrb);
                    observed_atomic_value =
                        l2_wdata[atomic_byte_offset*8 +: 32];
                    if ((observed_write_hart !=
                         (atomic_last_value & 3)) ||
                        (observed_atomic_value !=
                         atomic_last_value + 1))
                        $fatal(1,
                            "atomic order failure old=%0d new=%0d owner=%0d expected_owner=%0d",
                            atomic_last_value, observed_atomic_value,
                            observed_write_hart,
                            atomic_last_value & 3);
                    atomic_last_value <= observed_atomic_value;
                    atomic_l2_successes[observed_write_hart] <=
                        atomic_l2_successes[observed_write_hart] + 1;
                    if (observed_atomic_value == atomic_expected)
                        atomic_final_seen <= 1'b1;
                    else if (observed_atomic_value > atomic_expected)
                        $fatal(1,
                            "atomic counter exceeded expected value %0d",
                            atomic_expected);
                end
            end
        end
    end

    always #5 clk = ~clk;

    integer init_hart;
    string memh_path;
    integer memh_words;
    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        done_pc = 64'd0;
        mailbox_va = 64'd0;
        result_va = 64'd0;
        atomic_counter_va = 64'd0;
        done_pc_valid = 1'b0;
        mailbox_va_valid = 1'b0;
        result_va_valid = 1'b0;
        atomic_counter_va_valid = 1'b0;
        shared_satp = 0;
        bare_mode = 0;
        mailbox_stride = 0;
        result_expected = 0;
        atomic_expected = 0;
        atomic_test = 0;
        atomic_debug = 0;
        max_cycles = 800000;
        cycles = 0;
        first_done_cycle = -1;
        progress_before_first_done = 1'b0;

        for (memory_index = 0;
             memory_index < MEMORY_WORDS;
             memory_index = memory_index + 1)
            memory[memory_index] =
                {`OPENRV64_CCX_LINE_DATA_WIDTH{1'b0}};

        if (!$value$plusargs("memh=%s", memh_path))
            $fatal(1, "tb_4h_3p requires +memh=<512-bit image>");
        memh_words = MEMORY_WORDS;
        void'($value$plusargs("memh_words=%d", memh_words));
        if ((memh_words <= 0) || (memh_words > MEMORY_WORDS))
            $fatal(1, "invalid memh_words=%0d", memh_words);
        $readmemh(memh_path, memory, 0, memh_words - 1);

        if ($value$plusargs("done_pc=%h", done_pc))
            done_pc_valid = 1'b1;
        if ($value$plusargs("mailbox_va=%h", mailbox_va))
            mailbox_va_valid = 1'b1;
        if ($value$plusargs("result_va=%h", result_va))
            result_va_valid = 1'b1;
        if ($value$plusargs(
                "atomic_counter_va=%h", atomic_counter_va))
            atomic_counter_va_valid = 1'b1;
        void'($value$plusargs("shared_satp=%d", shared_satp));
        void'($value$plusargs("bare=%d", bare_mode));
        void'($value$plusargs("mailbox_stride=%d", mailbox_stride));
        void'($value$plusargs("result_expected=%d", result_expected));
        void'($value$plusargs("atomic_expected=%d", atomic_expected));
        void'($value$plusargs("atomic_test=%d", atomic_test));
        void'($value$plusargs("atomic_debug=%d", atomic_debug));
        void'($value$plusargs("max_cycles=%d", max_cycles));
        if (!done_pc_valid || !mailbox_va_valid)
            $fatal(1, "tb_4h_3p requires +done_pc and +mailbox_va");
        if (((shared_satp != 0) || (bare_mode != 0)) &&
            (mailbox_stride <= 0))
            $fatal(1,
                "shared-image workload requires positive +mailbox_stride");
        if ((shared_satp != 0) && (bare_mode != 0))
            $fatal(1, "+shared_satp and +bare are mutually exclusive");
        if ((atomic_test != 0) &&
            (!atomic_counter_va_valid || !result_va_valid ||
             (atomic_expected <= 0) || (result_expected <= 0)))
            $fatal(1,
                "atomic workload requires counter/result addresses and positive expectations");

        repeat (12) @(posedge clk);
        rst_n = 1'b1;
    end

    always @(posedge clk) begin
        if (rst_n) begin
            cycles <= cycles + 1;

            if ((atomic_test != 0) && (cycles != 0) &&
                ((cycles % 50000) == 0)) begin
                $display(
                    "ATOMIC_PROGRESS cycle=%0d value=%0d lr=%0d,%0d,%0d,%0d sc=%0d,%0d,%0d,%0d probes=%0d,%0d,%0d,%0d",
                    cycles, atomic_last_value,
                    lr_requests[0], lr_requests[1],
                    lr_requests[2], lr_requests[3],
                    sc_successes[0] + sc_failures[0],
                    sc_successes[1] + sc_failures[1],
                    sc_successes[2] + sc_failures[2],
                    sc_successes[3] + sc_failures[3],
                    atomic_line_probes[0], atomic_line_probes[1],
                    atomic_line_probes[2], atomic_line_probes[3]);
                $fflush();
            end

            if (protocol_error || probe_endpoint_protocol_error)
                $fatal(1,
                    "coherence protocol error home=%0b endpoint=%0b",
                    protocol_error, probe_endpoint_protocol_error);
            if (|dbg_halted)
                $fatal(1,
                    "hart halted mask=%b pc=%h instr=%h",
                    dbg_halted, dbg_pc, dbg_instr);

            if ((first_done_cycle < 0) &&
                (done_seen[0] || done_seen[1] ||
                 done_seen[2] || done_seen[3])) begin
                first_done_cycle <= cycles;
                progress_before_first_done <=
                    (retired[0] > 0) && (retired[1] > 0) &&
                    (retired[2] > 0) && (retired[3] > 0);
            end

            if (done_seen[0] && done_seen[1] &&
                done_seen[2] && done_seen[3] &&
                mailbox_seen[0] && mailbox_seen[1] &&
                mailbox_seen[2] && mailbox_seen[3] &&
                (!result_va_valid ||
                 (result_seen[0] && result_seen[1] &&
                  result_seen[2] && result_seen[3])) &&
                ((atomic_test == 0) || atomic_final_seen)) begin
                if (!progress_before_first_done)
                    $fatal(1,
                        "a hart completed before all four made retirement progress");
                for (init_hart = 0;
                     init_hart < NUM_HARTS;
                     init_hart = init_hart + 1) begin
                    if ((bare_mode == 0) && !root_seen[init_hart])
                        $fatal(1,
                            "hart %0d never fetched its Sv39 root", init_hart);
                    if (!satp_seen[init_hart])
                        $fatal(1,
                            "hart %0d never entered expected supervisor address mode",
                            init_hart);
                    if (!supervisor_fetch_seen[init_hart])
                        $fatal(1,
                            "hart %0d never fetched from its physical prefix",
                            init_hart);
                    if (atomic_test != 0) begin
                        if (atomic_l2_successes[init_hart] !=
                            result_expected)
                            $fatal(1,
                                "hart %0d L2 atomic successes=%0d expected=%0d",
                                init_hart,
                                atomic_l2_successes[init_hart],
                                result_expected);
                        if (sc_successes[init_hart] !=
                            result_expected)
                            $fatal(1,
                                "hart %0d SC successes=%0d expected=%0d",
                                init_hart, sc_successes[init_hart],
                                result_expected);
                        if (sc_requests[init_hart] !=
                            sc_successes[init_hart] +
                            sc_failures[init_hart])
                            $fatal(1,
                                "hart %0d SC accounting requests=%0d success=%0d failure=%0d",
                                init_hart, sc_requests[init_hart],
                                sc_successes[init_hart],
                                sc_failures[init_hart]);
                        if (atomic_line_probes[init_hart] == 0)
                            $fatal(1,
                                "hart %0d received no atomic-line invalidation probes",
                                init_hart);
                        if (reservation_clears[init_hart] <
                            atomic_line_probes[init_hart])
                            $fatal(1,
                                "hart %0d reservation clears=%0d probes=%0d",
                                init_hart,
                                reservation_clears[init_hart],
                                atomic_line_probes[init_hart]);
                    end
                end
                if ((atomic_test != 0) &&
                    (atomic_last_value != atomic_expected))
                    $fatal(1,
                        "atomic final value=%0d expected=%0d",
                        atomic_last_value, atomic_expected);
                $display(
                    "PASS tb_4h_3p cycles=%0d first_done=%0d done=%0d,%0d,%0d,%0d",
                    cycles, first_done_cycle,
                    done_cycle[0], done_cycle[1],
                    done_cycle[2], done_cycle[3]);
                $display(
                    "  retired=%0d,%0d,%0d,%0d ccx_req=%0d,%0d,%0d,%0d",
                    retired[0], retired[1], retired[2], retired[3],
                    requests[0], requests[1], requests[2], requests[3]);
                $display(
                    "  stores allocated=%0d,%0d,%0d,%0d fast=%0d,%0d,%0d,%0d fallback=%0d,%0d,%0d,%0d",
                    store_allocations[0], store_allocations[1],
                    store_allocations[2], store_allocations[3],
                    fast_store_requests[0], fast_store_requests[1],
                    fast_store_requests[2], fast_store_requests[3],
                    fallback_store_requests[0], fallback_store_requests[1],
                    fallback_store_requests[2],
                    fallback_store_requests[3]);
                $display(
                    "  l2_memory reads=%0d writes=%0d shared_satp=%0d bare=%0d",
                    memory_reads, memory_writes, shared_satp, bare_mode);
                if (atomic_test != 0) begin
                    $display(
                        "  atomic final=%0d lr=%0d,%0d,%0d,%0d",
                        atomic_last_value,
                        lr_requests[0], lr_requests[1],
                        lr_requests[2], lr_requests[3]);
                    $display(
                        "  sc success=%0d,%0d,%0d,%0d failure=%0d,%0d,%0d,%0d",
                        sc_successes[0], sc_successes[1],
                        sc_successes[2], sc_successes[3],
                        sc_failures[0], sc_failures[1],
                        sc_failures[2], sc_failures[3]);
                    $display(
                        "  atomic probes=%0d,%0d,%0d,%0d reservation_clears=%0d,%0d,%0d,%0d",
                        atomic_line_probes[0], atomic_line_probes[1],
                        atomic_line_probes[2], atomic_line_probes[3],
                        reservation_clears[0], reservation_clears[1],
                        reservation_clears[2], reservation_clears[3]);
                end
                $finish;
            end

            if ((cycles >= max_cycles) && (atomic_test != 0))
                $display(
                    "ATOMIC_TIMEOUT value=%0d lr=%0d,%0d,%0d,%0d sc_success=%0d,%0d,%0d,%0d sc_failure=%0d,%0d,%0d,%0d probes=%0d,%0d,%0d,%0d clears=%0d,%0d,%0d,%0d home_state=%0d",
                    atomic_last_value,
                    lr_requests[0], lr_requests[1],
                    lr_requests[2], lr_requests[3],
                    sc_successes[0], sc_successes[1],
                    sc_successes[2], sc_successes[3],
                    sc_failures[0], sc_failures[1],
                    sc_failures[2], sc_failures[3],
                    atomic_line_probes[0], atomic_line_probes[1],
                    atomic_line_probes[2], atomic_line_probes[3],
                    reservation_clears[0], reservation_clears[1],
                    reservation_clears[2], reservation_clears[3],
                    u_coherence_home.state_q);
            if (cycles >= max_cycles)
                $fatal(1,
                    "timeout cycles=%0d done=%0b%0b%0b%0b mailbox=%0b%0b%0b%0b pc=%h",
                    cycles, done_seen[3], done_seen[2],
                    done_seen[1], done_seen[0],
                    mailbox_seen[3], mailbox_seen[2],
                    mailbox_seen[1], mailbox_seen[0], dbg_pc);
        end
    end

endmodule
