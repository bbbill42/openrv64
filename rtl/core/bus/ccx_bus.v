`timescale 1ns/1ps
`include "core/isa/rv64-i.v"
`include "core/isa/rv64-priv.v"
`include "core/bus/bus-defs.v"
`include "complex/protocol/defs.v"

// Core memory boundary with native private-cache and PTE CCX clients.  The
// residual AXI path is used only for cacheless instruction fetch.  With
// ENABLE_L1I set, translated and PMP-approved fetches enter a pipelined
// native-CCX L1I.
// TLB-hit tagged cacheable loads/stores and Bare tagged cacheable traffic use
// L1D's native tagged path.  Translation misses, faults, locked accesses, and
// uncached/device requests use the precise translation/PMP slot.  The caller
// must present stores only after they are architecturally irrevocable.  No LSU
// request can enter AXI.
module openrv64_core_ccx_bus #(
    parameter integer TLB_ENTRIES = 16,
    parameter integer L2_TLB_ENTRIES = 256,
    parameter integer L2_TLB_WAYS = 4,
    parameter integer FETCH_OUTSTANDING = 4,
    parameter integer ENABLE_L1I = 1,
    parameter integer ENABLE_L1D = 1,
    parameter integer ENABLE_L1D_COHERENCE_PROBES = 0,
    parameter integer ENABLE_COHERENT_ATOMICS = 0,
    parameter integer L1I_CACHE_BYTES = 16 * 1024,
    parameter integer L1D_CACHE_BYTES = 16 * 1024,
    parameter [`RV64_XLEN-1:0] L1D_CACHEABLE_BASE =
        {`RV64_XLEN{1'b0}},
    parameter [`RV64_XLEN-1:0] L1D_CACHEABLE_SIZE =
        {`RV64_XLEN{1'b1}},
    parameter integer L1D_FILL_BUFFER_LINES = 8,
    parameter integer L1D_DEMAND_MSHRS = 3,
    parameter integer L1D_STORE_BUFFER_LINES = 8,
    parameter integer L1D_PREFETCH_ENABLE = 1,
    parameter integer L1D_PREFETCH_MAX_STRIDE_LINES = 64,
    parameter integer L1D_PREFETCH_STREAMS = 2,
    parameter integer L1D_PREFETCH_DISTANCE = 1,
    parameter integer L1D_PREFETCH_ADAPTIVE_ENABLE = 1,
    parameter integer L1D_PREFETCH_MAX_DISTANCE = 4,
    parameter integer L1D_PREFETCH_QUEUE_LINES = 4,
    parameter integer L1D_PREFETCH_OUTSTANDING = 4,
    parameter integer L1D_PREFETCH_DEMAND_RESERVE = 2,
    parameter integer L1I_FILL_BUFFER_LINES = 8,
    parameter integer L1I_DEMAND_MSHRS = 4,
    parameter integer PTW_PTE_CACHE_ENTRIES = 64,
    parameter integer PTW_CCX_TIMEOUT_CYCLES = 65536,
    parameter [`OPENRV64_CCX_HART_ID_WIDTH-1:0] HART_ID =
        {`OPENRV64_CCX_HART_ID_WIDTH{1'b0}},
    parameter integer AXI_ADDR_WIDTH = `OPENRV64_AXI_ADDR_WIDTH,
    parameter integer AXI_DATA_WIDTH = `OPENRV64_AXI_DATA_WIDTH,
    parameter integer AXI_ID_WIDTH = `OPENRV64_AXI_ID_WIDTH
) (
    input  wire                         clk,
    input  wire                         rst_n,

    input  wire                         fetch_req_valid_i,
    output wire                         fetch_req_ready_o,
    input  wire [`RV64_XLEN-1:0]        fetch_req_addr_i,
    input  wire                         fetch_req_stash_i,
    input  wire                         fetch_req_demand_i,
    input  wire [`RV64_PRIV_WIDTH-1:0]  fetch_req_priv_i,
    input  wire [`RV64_SATP_MODE_WIDTH-1:0] fetch_req_vm_mode_i,
    input  wire [`RV64_SATP_ASID_WIDTH-1:0] fetch_req_asid_i,
    input  wire [`RV64_SATP_PPN_WIDTH-1:0] fetch_req_root_ppn_i,
    input  wire                         fetch_req_sum_i,
    input  wire                         fetch_req_mxr_i,
    input  wire                         fetch_cancel_i,
    input  wire                         fetch_cancel_stash_i,
    output wire                         fetch_resp_valid_o,
    input  wire                         fetch_resp_ready_i,
    output wire [`RV64_XLEN-1:0]        fetch_resp_addr_o,
    output wire [AXI_DATA_WIDTH-1:0]    fetch_resp_data_o,
    output wire                         fetch_resp_access_fault_o,
    output wire                         fetch_resp_page_fault_o,
    output wire                         fetch_resp_stash_o,
    output wire                         fetch_resp_demand_o,

    input  wire                         lsu_valid_i,
    input  wire                         lsu_lock_i,
    input  wire                         lsu_write_i,
    input  wire [`RV64_XLEN-1:0]        lsu_addr_i,
    input  wire [`RV64_XLEN-1:0]        lsu_wdata_i,
    input  wire [7:0]                   lsu_wstrb_i,
    input  wire [2:0]                   lsu_size_i,
    input  wire [`RV64_PRIV_WIDTH-1:0]  lsu_priv_i,
    input  wire [`RV64_SATP_MODE_WIDTH-1:0] lsu_vm_mode_i,
    input  wire [`RV64_SATP_ASID_WIDTH-1:0] lsu_asid_i,
    input  wire [`RV64_SATP_PPN_WIDTH-1:0] lsu_root_ppn_i,
    input  wire                         lsu_sum_i,
    input  wire                         lsu_mxr_i,
    output wire                         lsu_ready_o,
    output wire [`RV64_XLEN-1:0]        lsu_rdata_o,
    output wire                         lsu_access_fault_o,
    output wire                         lsu_page_fault_o,

    input  wire                         lsu_pipe_req_valid_i,
    output wire                         lsu_pipe_req_ready_o,
    input  wire [`OPENRV64_LSU_TAG_WIDTH-1:0] lsu_pipe_req_tag_i,
    input  wire                         lsu_pipe_req_xlate_only_i,
    input  wire                         lsu_pipe_req_physical_i,
    input  wire                         lsu_pipe_req_lock_i,
    input  wire                         lsu_pipe_req_write_i,
    input  wire [`RV64_XLEN-1:0]        lsu_pipe_req_addr_i,
    input  wire [`RV64_XLEN-1:0]        lsu_pipe_req_wdata_i,
    input  wire [7:0]                   lsu_pipe_req_wstrb_i,
    input  wire [2:0]                   lsu_pipe_req_size_i,
    input  wire [`RV64_PRIV_WIDTH-1:0]  lsu_pipe_req_priv_i,
    input  wire [`RV64_SATP_MODE_WIDTH-1:0] lsu_pipe_req_vm_mode_i,
    input  wire [`RV64_SATP_ASID_WIDTH-1:0] lsu_pipe_req_asid_i,
    input  wire [`RV64_SATP_PPN_WIDTH-1:0] lsu_pipe_req_root_ppn_i,
    input  wire                         lsu_pipe_req_sum_i,
    input  wire                         lsu_pipe_req_mxr_i,
    output wire                         lsu_pipe_req_translation_hit_o,
    output wire [`RV64_XLEN-1:0]        lsu_pipe_req_translation_paddr_o,
    output wire                         lsu_pipe_req_translation_page_fault_o,
    input  wire                         lsu_pipe_cancel_i,
    output wire                         lsu_pipe_resp_valid_o,
    input  wire                         lsu_pipe_resp_ready_i,
    output wire [`OPENRV64_LSU_TAG_WIDTH-1:0] lsu_pipe_resp_tag_o,
    output wire [`RV64_XLEN-1:0]        lsu_pipe_resp_paddr_o,
    output wire [`RV64_XLEN-1:0]        lsu_pipe_resp_rdata_o,
    output wire                         lsu_pipe_resp_access_fault_o,
    output wire                         lsu_pipe_resp_page_fault_o,
    output wire                         lsu_pipe_store_done_valid_o,
    input  wire                         lsu_pipe_store_done_ready_i,
    output wire [`OPENRV64_LSU_TAG_WIDTH-1:0]
                                        lsu_pipe_store_done_tag_o,

    input  wire                         lsu_xlate_req_valid_i,
    output wire                         lsu_xlate_req_ready_o,
    input  wire [`OPENRV64_LSU_TAG_WIDTH-1:0] lsu_xlate_req_tag_i,
    input  wire                         lsu_xlate_req_write_i,
    input  wire [`RV64_XLEN-1:0]        lsu_xlate_req_vaddr_i,
    input  wire [`RV64_PRIV_WIDTH-1:0]  lsu_xlate_req_priv_i,
    input  wire [`RV64_SATP_MODE_WIDTH-1:0] lsu_xlate_req_vm_mode_i,
    input  wire [`RV64_SATP_ASID_WIDTH-1:0] lsu_xlate_req_asid_i,
    input  wire [`RV64_SATP_PPN_WIDTH-1:0] lsu_xlate_req_root_ppn_i,
    input  wire                         lsu_xlate_req_sum_i,
    input  wire                         lsu_xlate_req_mxr_i,
    output wire                         lsu_xlate_resp_valid_o,
    input  wire                         lsu_xlate_resp_ready_i,
    output wire [`OPENRV64_LSU_TAG_WIDTH-1:0] lsu_xlate_resp_tag_o,
    output wire [`RV64_XLEN-1:0]        lsu_xlate_resp_paddr_o,
    output wire                         lsu_xlate_resp_access_fault_o,
    output wire                         lsu_xlate_resp_page_fault_o,

    input  wire                         tlbi_i,
    output wire                         tlbi_busy_o,
    input  wire                         icache_invalidate_i,
    input  wire                         icache_prefetch_valid_i,
    input  wire [`RV64_XLEN-1:0]        icache_prefetch_taken_addr_i,
    input  wire [`RV64_XLEN-1:0]        icache_prefetch_fallthrough_addr_i,
    input  wire [2:0]                   icache_age_valid_i,
    input  wire [3*`RV64_XLEN-1:0]      icache_age_addr_i,

    // Optional external coherence probe.  This invalidates one D-cache line;
    // reservation clearing remains a separate backend integration seam.
    input  wire                         l1d_probe_valid_i,
    output wire                         l1d_probe_ready_o,
    input  wire [`RV64_XLEN-1:0]        l1d_probe_addr_i,

    // One physical protection probe is presented for the transaction which
    // would be launched this cycle.  Denials complete locally as access
    // faults and never escape onto CCX or AXI.
    output wire                         pmp_valid_o,
    output wire [`RV64_XLEN-1:0]        pmp_addr_o,
    output wire [`RV64_PRIV_WIDTH-1:0]  pmp_priv_o,
    output wire [2:0]                   pmp_size_o,
    output wire                         pmp_write_o,
    output wire                         pmp_exec_o,
    input  wire                         pmp_allow_i,

    output wire                         ccx_req_valid_o,
    input  wire                         ccx_req_ready_i,
    output wire [`OPENRV64_CCX_HART_ID_WIDTH-1:0]
                                        ccx_req_hart_id_o,
    output wire [`OPENRV64_CCX_TXN_ID_WIDTH-1:0]
                                        ccx_req_txn_id_o,
    output wire [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0]
                                        ccx_req_source_id_o,
    output wire [`OPENRV64_CCX_OP_WIDTH-1:0] ccx_req_op_o,
    output wire                         ccx_req_lock_o,
    output wire [`OPENRV64_CCX_ORDER_WIDTH-1:0] ccx_req_order_o,
    output wire [`OPENRV64_CCX_KIND_WIDTH-1:0] ccx_req_kind_o,
    output wire [`OPENRV64_CCX_ATTR_WIDTH-1:0] ccx_req_attr_o,
    output wire [2:0]                   ccx_req_size_o,
    output wire [63:0]                  ccx_req_addr_o,
    output wire [`OPENRV64_CCX_BURST_LEN_WIDTH-1:0]
                                        ccx_req_burst_len_o,
    output wire                         ccx_wdata_valid_o,
    input  wire                         ccx_wdata_ready_i,
    output wire [`OPENRV64_CCX_HART_ID_WIDTH-1:0]
                                        ccx_wdata_hart_id_o,
    output wire [`OPENRV64_CCX_TXN_ID_WIDTH-1:0]
                                        ccx_wdata_txn_id_o,
    output wire [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0]
                                        ccx_wdata_source_id_o,
    output wire [`OPENRV64_CCX_BEAT_INDEX_WIDTH-1:0]
                                        ccx_wdata_beat_index_o,
    output wire                         ccx_wdata_last_o,
    output wire [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0]
                                        ccx_wdata_o,
    output wire [`OPENRV64_CCX_LINE_STRB_WIDTH-1:0]
                                        ccx_wstrb_o,
    input  wire                         ccx_resp_valid_i,
    output wire                         ccx_resp_ready_o,
    input  wire [`OPENRV64_CCX_HART_ID_WIDTH-1:0]
                                        ccx_resp_hart_id_i,
    input  wire [`OPENRV64_CCX_TXN_ID_WIDTH-1:0]
                                        ccx_resp_txn_id_i,
    input  wire [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0]
                                        ccx_resp_source_id_i,
    input  wire [`OPENRV64_CCX_BEAT_INDEX_WIDTH-1:0]
                                        ccx_resp_beat_index_i,
    input  wire                         ccx_resp_last_i,
    input  wire [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0]
                                        ccx_resp_rdata_i,
    input  wire                         ccx_resp_error_i,
    input  wire                         ccx_resp_sc_success_i,

    output wire [AXI_ID_WIDTH-1:0]      m_axi_arid_o,
    output wire [AXI_ADDR_WIDTH-1:0]    m_axi_araddr_o,
    output wire [7:0]                   m_axi_arlen_o,
    output wire [2:0]                   m_axi_arsize_o,
    output wire [1:0]                   m_axi_arburst_o,
    output wire                         m_axi_arlock_o,
    output wire [3:0]                   m_axi_arcache_o,
    output wire [2:0]                   m_axi_arprot_o,
    output wire [3:0]                   m_axi_arqos_o,
    output wire                         m_axi_arvalid_o,
    input  wire                         m_axi_arready_i,

    input  wire [AXI_ID_WIDTH-1:0]      m_axi_rid_i,
    input  wire [AXI_DATA_WIDTH-1:0]    m_axi_rdata_i,
    input  wire [1:0]                   m_axi_rresp_i,
    input  wire                         m_axi_rlast_i,
    input  wire                         m_axi_rvalid_i,
    output wire                         m_axi_rready_o,

    output wire [AXI_ID_WIDTH-1:0]      m_axi_awid_o,
    output wire [AXI_ADDR_WIDTH-1:0]    m_axi_awaddr_o,
    output wire [7:0]                   m_axi_awlen_o,
    output wire [2:0]                   m_axi_awsize_o,
    output wire [1:0]                   m_axi_awburst_o,
    output wire                         m_axi_awlock_o,
    output wire [3:0]                   m_axi_awcache_o,
    output wire [2:0]                   m_axi_awprot_o,
    output wire [3:0]                   m_axi_awqos_o,
    output wire                         m_axi_awvalid_o,
    input  wire                         m_axi_awready_i,

    output wire [AXI_DATA_WIDTH-1:0]    m_axi_wdata_o,
    output wire [(AXI_DATA_WIDTH/8)-1:0] m_axi_wstrb_o,
    output wire                         m_axi_wlast_o,
    output wire                         m_axi_wvalid_o,
    input  wire                         m_axi_wready_i,

    input  wire [AXI_ID_WIDTH-1:0]      m_axi_bid_i,
    input  wire [1:0]                   m_axi_bresp_i,
    input  wire                         m_axi_bvalid_i,
    output wire                         m_axi_bready_o
);

    localparam integer AXI_BYTES = AXI_DATA_WIDTH / 8;
    localparam integer AXI_BYTE_BITS = $clog2(AXI_BYTES);
    localparam integer FETCH_SLOT_WIDTH =
        (FETCH_OUTSTANDING > 1) ? $clog2(FETCH_OUTSTANDING) : 1;
    localparam integer FETCH_COUNT_WIDTH =
        $clog2(FETCH_OUTSTANDING + 1);
    localparam [2:0] FETCH_EMPTY = 3'd0;
    localparam [2:0] FETCH_TRANSLATE = 3'd1;
    localparam [2:0] FETCH_MISS = 3'd2;
    localparam [2:0] FETCH_WAIT_R = 3'd3;
    localparam [2:0] FETCH_COMPLETE = 3'd4;
    localparam [2:0] FETCH_WAIT_L1I = 3'd5;

    localparam [2:0] LSU_IDLE = 3'd0;
    localparam [2:0] LSU_TRANSLATE = 3'd1;
    localparam [2:0] LSU_MISS = 3'd2;
    localparam [2:0] LSU_ACCESS = 3'd3;
    localparam [2:0] LSU_WAIT = 3'd4;
    localparam [2:0] LSU_RESP = 3'd5;

    localparam [1:0] OWNER_FETCH = 2'd0;
    localparam [1:0] OWNER_LSU = 2'd1;
    localparam [1:0] OWNER_PREFETCH = 2'd2;
    localparam [1:0] ACCESS_READ = 2'd0;
    localparam [1:0] ACCESS_WRITE = 2'd1;
    localparam [1:0] ACCESS_EXEC = 2'd2;
    localparam integer L1D_REQ_TAG_WIDTH =
        `OPENRV64_LSU_TAG_WIDTH;
    localparam [1:0] CCX_CLIENT_ICACHE = 2'd0;
    localparam [1:0] CCX_CLIENT_DCACHE = 2'd1;
    localparam [1:0] CCX_CLIENT_PTE = 2'd2;
    localparam [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] PTE_TXN_ID =
        {`OPENRV64_CCX_TXN_ID_WIDTH{1'b0}};

    localparam [2:0] PREFETCH_XLATE_IDLE = 3'd0;
    localparam [2:0] PREFETCH_XLATE_LOOKUP = 3'd1;
    localparam [2:0] PREFETCH_XLATE_MISS = 3'd2;
    localparam [2:0] PREFETCH_XLATE_PMP = 3'd3;
    localparam [2:0] PREFETCH_XLATE_RESP = 3'd4;

    // Fetch slots decouple frontend admission from translation, PMP, and L1I.
    // Responses complete slots independently but are retired to the frontend
    // in request order.
    reg [2:0] fetch_state_q [0:FETCH_OUTSTANDING-1];
    reg [`RV64_XLEN-1:0] fetch_vaddr_q [0:FETCH_OUTSTANDING-1];
    reg [`RV64_PRIV_WIDTH-1:0]
        fetch_priv_q [0:FETCH_OUTSTANDING-1];
    reg [`RV64_SATP_MODE_WIDTH-1:0]
        fetch_vm_mode_q [0:FETCH_OUTSTANDING-1];
    reg [`RV64_SATP_ASID_WIDTH-1:0]
        fetch_asid_q [0:FETCH_OUTSTANDING-1];
    reg [`RV64_SATP_PPN_WIDTH-1:0]
        fetch_root_ppn_q [0:FETCH_OUTSTANDING-1];
    reg fetch_sum_q [0:FETCH_OUTSTANDING-1];
    reg fetch_mxr_q [0:FETCH_OUTSTANDING-1];
    reg fetch_stash_q [0:FETCH_OUTSTANDING-1];
    reg fetch_demand_q [0:FETCH_OUTSTANDING-1];
    reg fetch_cancelled_q [0:FETCH_OUTSTANDING-1];
    reg [AXI_DATA_WIDTH-1:0]
        fetch_data_q [0:FETCH_OUTSTANDING-1];
    reg fetch_access_fault_q [0:FETCH_OUTSTANDING-1];
    reg fetch_page_fault_q [0:FETCH_OUTSTANDING-1];
    // These are round-robin allocation and completion cursors.  Fetch
    // responses are address-qualified and may return out of request order.
    reg [FETCH_SLOT_WIDTH-1:0] fetch_head_q;
    reg [FETCH_SLOT_WIDTH-1:0] fetch_tail_q;
    reg [FETCH_COUNT_WIDTH-1:0] fetch_count_q;

    reg fetch_xlate_found_r;
    reg [FETCH_SLOT_WIDTH-1:0] fetch_xlate_slot_r;
    reg fetch_free_found_r;
    reg [FETCH_SLOT_WIDTH-1:0] fetch_free_slot_r;
    reg fetch_complete_found_r;
    reg [FETCH_SLOT_WIDTH-1:0] fetch_complete_slot_r;
    reg fetch_drop_found_r;
    reg [FETCH_SLOT_WIDTH-1:0] fetch_drop_slot_r;
    reg fetch_resp_hold_valid_q;
    reg [FETCH_SLOT_WIDTH-1:0] fetch_resp_hold_slot_q;
    reg [FETCH_SLOT_WIDTH-1:0] fetch_free_scan_slot_r;
    reg [FETCH_SLOT_WIDTH-1:0] fetch_complete_scan_slot_r;
    integer fetch_scan;
    integer fetch_free_scan;
    integer fetch_complete_scan;
    always @* begin
        fetch_xlate_found_r = 1'b0;
        fetch_xlate_slot_r = {FETCH_SLOT_WIDTH{1'b0}};
        for (fetch_scan = 0; fetch_scan < FETCH_OUTSTANDING;
             fetch_scan = fetch_scan + 1) begin
            if (!fetch_xlate_found_r &&
                (fetch_state_q[fetch_scan] == FETCH_TRANSLATE) &&
                !fetch_cancelled_q[fetch_scan]) begin
                fetch_xlate_found_r = 1'b1;
                fetch_xlate_slot_r = fetch_scan[FETCH_SLOT_WIDTH-1:0];
            end
        end
    end

    always @* begin
        fetch_free_found_r = 1'b0;
        fetch_free_slot_r = {FETCH_SLOT_WIDTH{1'b0}};
        fetch_free_scan_slot_r = {FETCH_SLOT_WIDTH{1'b0}};
        for (fetch_free_scan = 0;
             fetch_free_scan < FETCH_OUTSTANDING;
             fetch_free_scan = fetch_free_scan + 1) begin
            fetch_free_scan_slot_r =
                fetch_tail_q + FETCH_SLOT_WIDTH'(fetch_free_scan);
            if (!fetch_free_found_r &&
                (fetch_state_q[fetch_free_scan_slot_r] == FETCH_EMPTY)) begin
                fetch_free_found_r = 1'b1;
                fetch_free_slot_r = fetch_free_scan_slot_r;
            end
        end
    end

    always @* begin
        fetch_complete_found_r = 1'b0;
        fetch_complete_slot_r = {FETCH_SLOT_WIDTH{1'b0}};
        fetch_drop_found_r = 1'b0;
        fetch_drop_slot_r = {FETCH_SLOT_WIDTH{1'b0}};
        fetch_complete_scan_slot_r = {FETCH_SLOT_WIDTH{1'b0}};
        for (fetch_complete_scan = 0;
             fetch_complete_scan < FETCH_OUTSTANDING;
             fetch_complete_scan = fetch_complete_scan + 1) begin
            fetch_complete_scan_slot_r =
                fetch_head_q + FETCH_SLOT_WIDTH'(fetch_complete_scan);
            if (!fetch_complete_found_r &&
                (fetch_state_q[fetch_complete_scan_slot_r] ==
                 FETCH_COMPLETE) &&
                !fetch_cancelled_q[fetch_complete_scan_slot_r]) begin
                fetch_complete_found_r = 1'b1;
                fetch_complete_slot_r = fetch_complete_scan_slot_r;
            end
            if (!fetch_drop_found_r &&
                (fetch_state_q[fetch_complete_scan_slot_r] ==
                 FETCH_COMPLETE) &&
                fetch_cancelled_q[fetch_complete_scan_slot_r]) begin
                fetch_drop_found_r = 1'b1;
                fetch_drop_slot_r = fetch_complete_scan_slot_r;
            end
        end
        // The legacy cacheless AXI endpoint promises in-order frontend
        // responses.  Native L1I is tagged and may expose any completed slot.
        if (ENABLE_L1I == 0) begin
            fetch_complete_found_r =
                (fetch_state_q[fetch_head_q] == FETCH_COMPLETE) &&
                !fetch_cancelled_q[fetch_head_q];
            fetch_complete_slot_r = fetch_head_q;
            fetch_drop_found_r =
                (fetch_state_q[fetch_head_q] == FETCH_COMPLETE) &&
                fetch_cancelled_q[fetch_head_q];
            fetch_drop_slot_r = fetch_head_q;
        end
    end

    wire fetch_accept = fetch_req_valid_i && fetch_req_ready_o;
    wire [FETCH_SLOT_WIDTH-1:0] fetch_response_slot =
        fetch_resp_hold_valid_q ? fetch_resp_hold_slot_q :
                                  fetch_complete_slot_r;
    wire fetch_resp_fire = fetch_resp_valid_o && fetch_resp_ready_i;
    wire fetch_drop = fetch_drop_found_r && !fetch_resp_valid_o;
    wire fetch_pop = fetch_drop || fetch_resp_fire;
    wire [FETCH_SLOT_WIDTH-1:0] fetch_pop_slot =
        fetch_resp_fire ? fetch_response_slot : fetch_drop_slot_r;

    // An ordinary redirect may replace the cancelled stream with one
    // qualified architectural demand on the same edge. The cancellation
    // loop observes pre-edge slot validity, so it cancels older entries
    // while leaving a newly allocated replacement intact.
    wire fetch_redirect_replacement = fetch_cancel_i &&
        !fetch_cancel_stash_i && fetch_req_stash_i &&
        fetch_req_demand_i;
    assign fetch_req_ready_o = rst_n &&
        (!fetch_cancel_i || fetch_redirect_replacement) &&
        fetch_free_found_r;
    assign fetch_resp_valid_o = fetch_resp_hold_valid_q ||
                                fetch_complete_found_r;
    assign fetch_resp_addr_o = fetch_vaddr_q[fetch_response_slot];
    assign fetch_resp_data_o = fetch_data_q[fetch_response_slot];
    assign fetch_resp_access_fault_o =
        fetch_access_fault_q[fetch_response_slot];
    assign fetch_resp_page_fault_o =
        fetch_page_fault_q[fetch_response_slot];
    assign fetch_resp_stash_o = fetch_stash_q[fetch_response_slot];
    assign fetch_resp_demand_o = fetch_demand_q[fetch_response_slot];

    wire itlb_lookup_hit;
    wire [`RV64_XLEN-1:0] itlb_lookup_paddr;
    wire itlb_lookup_page_fault;
    wire fetch_xlate_bare = fetch_xlate_found_r &&
        (fetch_vm_mode_q[fetch_xlate_slot_r] == `RV64_SATP_MODE_BARE);
    wire fetch_lookup_valid = fetch_xlate_found_r;
    wire [`RV64_XLEN-1:0] fetch_lookup_vaddr =
        fetch_vaddr_q[fetch_xlate_slot_r];
    wire [`RV64_PRIV_WIDTH-1:0] fetch_lookup_priv =
        fetch_priv_q[fetch_xlate_slot_r];
    wire [`RV64_SATP_MODE_WIDTH-1:0] fetch_lookup_vm_mode =
        fetch_vm_mode_q[fetch_xlate_slot_r];
    wire fetch_lookup_bare = fetch_lookup_valid &&
        (fetch_lookup_vm_mode == `RV64_SATP_MODE_BARE);
    wire fetch_lookup_ready = fetch_lookup_bare || itlb_lookup_hit;
    wire [`RV64_XLEN-1:0] fetch_lookup_paddr = fetch_lookup_bare ?
        fetch_lookup_vaddr : itlb_lookup_paddr;

    // L1I owns speculative virtual jobs.  This blocking side service shares
    // the existing ITLB/PTW/PMP resources, always below architectural demand
    // traffic.  Its faults return only to L1I and are discarded there.
    reg [2:0] prefetch_xlate_state_q;
    reg [`RV64_XLEN-1:0] prefetch_xlate_vaddr_q;
    reg [`RV64_XLEN-1:0] prefetch_xlate_paddr_q;
    reg [`RV64_PRIV_WIDTH-1:0] prefetch_xlate_priv_q;
    reg [`RV64_SATP_MODE_WIDTH-1:0] prefetch_xlate_vm_mode_q;
    reg [`RV64_SATP_ASID_WIDTH-1:0] prefetch_xlate_asid_q;
    reg [`RV64_SATP_PPN_WIDTH-1:0] prefetch_xlate_root_ppn_q;
    reg prefetch_xlate_sum_q;
    reg prefetch_xlate_mxr_q;
    reg prefetch_xlate_fault_q;
    wire l1i_xlate_req_valid;
    wire l1i_xlate_req_ready;
    wire [`RV64_XLEN-1:0] l1i_xlate_req_vaddr;
    wire [`RV64_PRIV_WIDTH-1:0] l1i_xlate_req_priv;
    wire [`RV64_SATP_MODE_WIDTH-1:0] l1i_xlate_req_vm_mode;
    wire [`RV64_SATP_ASID_WIDTH-1:0] l1i_xlate_req_asid;
    wire [`RV64_SATP_PPN_WIDTH-1:0] l1i_xlate_req_root_ppn;
    wire l1i_xlate_req_sum;
    wire l1i_xlate_req_mxr;
    wire l1i_xlate_resp_valid;
    wire l1i_xlate_resp_ready;
    wire [`RV64_XLEN-1:0] l1i_xlate_resp_paddr;
    wire l1i_xlate_resp_fault;

    assign l1i_xlate_req_ready =
        (prefetch_xlate_state_q == PREFETCH_XLATE_IDLE) && !tlbi_i;
    assign l1i_xlate_resp_valid =
        (prefetch_xlate_state_q == PREFETCH_XLATE_RESP);
    assign l1i_xlate_resp_paddr = prefetch_xlate_paddr_q;
    assign l1i_xlate_resp_fault = prefetch_xlate_fault_q;
    wire prefetch_xlate_lookup =
        (prefetch_xlate_state_q == PREFETCH_XLATE_LOOKUP) &&
        !fetch_lookup_valid;
    wire prefetch_xlate_bare = prefetch_xlate_lookup &&
        (prefetch_xlate_vm_mode_q == `RV64_SATP_MODE_BARE);

    reg [2:0] lsu_state_q;
    reg lsu_lock_q;
    reg lsu_write_q;
    reg lsu_xlate_only_q;
    reg lsu_physical_q;
    reg [`RV64_XLEN-1:0] lsu_vaddr_q;
    reg [`RV64_XLEN-1:0] lsu_paddr_q;
    reg [`RV64_XLEN-1:0] lsu_wdata_q;
    reg [7:0] lsu_wstrb_q;
    reg [2:0] lsu_size_q;
    reg [`RV64_PRIV_WIDTH-1:0] lsu_priv_q;
    reg [`RV64_SATP_MODE_WIDTH-1:0] lsu_vm_mode_q;
    reg [`RV64_SATP_ASID_WIDTH-1:0] lsu_asid_q;
    reg [`RV64_SATP_PPN_WIDTH-1:0] lsu_root_ppn_q;
    reg lsu_sum_q;
    reg lsu_mxr_q;
    reg [`RV64_XLEN-1:0] lsu_rdata_q;
    reg lsu_access_fault_q;
    reg lsu_page_fault_q;
    reg pipe_fallback_active_q;
    reg pipe_fallback_cancelled_q;
    reg [`OPENRV64_LSU_TAG_WIDTH-1:0] pipe_fallback_tag_q;
    reg pipe_inflight_q [0:`OPENRV64_LSU_OUTSTANDING-1];
    reg pipe_cancelled_q [0:`OPENRV64_LSU_OUTSTANDING-1];
    reg pipe_write_q [0:`OPENRV64_LSU_OUTSTANDING-1];
    reg pipe_local_resp_valid_q;
    reg [`OPENRV64_LSU_TAG_WIDTH-1:0] pipe_local_resp_tag_q;
    reg [`RV64_XLEN-1:0] pipe_local_resp_paddr_q;
    reg pipe_local_resp_access_fault_q;
    reg pipe_local_resp_page_fault_q;
    reg xlate_local_resp_valid_q;
    reg [`OPENRV64_LSU_TAG_WIDTH-1:0] xlate_local_resp_tag_q;
    reg [`RV64_XLEN-1:0] xlate_local_resp_paddr_q;
    reg xlate_local_resp_page_fault_q;
    reg xlate_fallback_active_q;
    reg [`OPENRV64_LSU_TAG_WIDTH-1:0] xlate_fallback_tag_q;
    integer pipe_index;

    wire pipe_req_tag_valid =
        lsu_pipe_req_tag_i < `OPENRV64_LSU_OUTSTANDING;
    wire pipe_req_tag_busy = pipe_req_tag_valid &&
        (pipe_inflight_q[lsu_pipe_req_tag_i] ||
         (pipe_local_resp_valid_q &&
          (pipe_local_resp_tag_q == lsu_pipe_req_tag_i)) ||
         (pipe_fallback_active_q &&
          (pipe_fallback_tag_q == lsu_pipe_req_tag_i)));

    wire dtlb_lookup_hit;
    wire [`RV64_XLEN-1:0] dtlb_lookup_paddr;
    wire dtlb_lookup_page_fault;
    wire pipe_req_bare = lsu_pipe_req_physical_i ||
        (lsu_pipe_req_vm_mode_i == `RV64_SATP_MODE_BARE);
    wire xlate_req_bare =
        lsu_xlate_req_vm_mode_i == `RV64_SATP_MODE_BARE;
    wire lsu_xlate_bare = (lsu_state_q == LSU_TRANSLATE) &&
        (lsu_physical_q ||
         (lsu_vm_mode_q == `RV64_SATP_MODE_BARE));
    wire pipe_fast_state_available =
        ((lsu_state_q == LSU_IDLE) && !lsu_valid_i) ||
        ((lsu_state_q == LSU_MISS) &&
         (pipe_fallback_active_q || xlate_fallback_active_q) &&
         !lsu_lock_q && !lsu_valid_i);
    wire serial_dtlb_lookup = (lsu_state_q == LSU_TRANSLATE) &&
                              !lsu_xlate_bare;
    wire xlate_dtlb_lookup = lsu_xlate_req_valid_i &&
                             !xlate_req_bare && !tlbi_i &&
                             !tlbi_busy_o;
    wire dtlb_lookup_is_xlate = xlate_dtlb_lookup &&
                                !serial_dtlb_lookup;
    wire dtlb_lookup_valid = serial_dtlb_lookup ||
                             dtlb_lookup_is_xlate;
    wire [`RV64_XLEN-1:0] dtlb_lookup_vaddr =
        dtlb_lookup_is_xlate ? lsu_xlate_req_vaddr_i : lsu_vaddr_q;
    wire [`RV64_SATP_MODE_WIDTH-1:0] dtlb_lookup_vm_mode =
        dtlb_lookup_is_xlate ? lsu_xlate_req_vm_mode_i : lsu_vm_mode_q;
    wire [`RV64_SATP_ASID_WIDTH-1:0] dtlb_lookup_asid =
        dtlb_lookup_is_xlate ? lsu_xlate_req_asid_i : lsu_asid_q;
    wire [1:0] dtlb_lookup_access = dtlb_lookup_is_xlate ?
        (lsu_xlate_req_write_i ? ACCESS_WRITE : ACCESS_READ) :
        (lsu_write_q ? ACCESS_WRITE : ACCESS_READ);
    wire [`RV64_PRIV_WIDTH-1:0] dtlb_lookup_priv =
        dtlb_lookup_is_xlate ? lsu_xlate_req_priv_i : lsu_priv_q;
    wire dtlb_lookup_sum = dtlb_lookup_is_xlate ?
        lsu_xlate_req_sum_i : lsu_sum_q;
    wire dtlb_lookup_mxr = dtlb_lookup_is_xlate ?
        lsu_xlate_req_mxr_i : lsu_mxr_q;

    assign lsu_ready_o = (lsu_state_q == LSU_RESP) &&
                         !pipe_fallback_active_q;
    assign lsu_rdata_o = lsu_rdata_q;
    assign lsu_access_fault_o = lsu_ready_o && lsu_access_fault_q;
    assign lsu_page_fault_o = lsu_ready_o && lsu_page_fault_q;

    // A single PTW serves I- and D-side misses.  TLB hits and already-issued
    // AXI reads continue while a walk is active.
    reg miss_active_q;
    reg [1:0] miss_owner_q;
    reg [FETCH_SLOT_WIDTH-1:0] miss_fetch_slot_q;
    reg miss_invalidated_q;

    // Cancellation and PTW response may arrive on the same edge.  The queued
    // cancellation bit is one cycle too old to resolve that race, so derive
    // the current cancellation decision for the active fetch walk explicitly.
    wire fetch_miss_redirect_cancel_now = fetch_cancel_i &&
        (fetch_state_q[miss_fetch_slot_q] != FETCH_EMPTY) &&
        (!fetch_stash_q[miss_fetch_slot_q] || fetch_cancel_stash_i);
    reg fetch_miss_age_cancel_now_r;
    integer fetch_cancel_age_port;
    always @* begin
        fetch_miss_age_cancel_now_r = 1'b0;
        for (fetch_cancel_age_port = 0; fetch_cancel_age_port < 3;
             fetch_cancel_age_port = fetch_cancel_age_port + 1) begin
            if (icache_age_valid_i[fetch_cancel_age_port] &&
                (fetch_state_q[miss_fetch_slot_q] != FETCH_EMPTY) &&
                fetch_stash_q[miss_fetch_slot_q] &&
                !fetch_demand_q[miss_fetch_slot_q] &&
                (fetch_vaddr_q[miss_fetch_slot_q][`RV64_XLEN-1:6] ==
                 icache_age_addr_i[
                    fetch_cancel_age_port*`RV64_XLEN + 6 +:
                    `RV64_XLEN-6]))
                fetch_miss_age_cancel_now_r = 1'b1;
        end
    end
    wire fetch_miss_cancel_now = fetch_miss_redirect_cancel_now ||
                                 fetch_miss_age_cancel_now_r;

    wire ptw_req_ready;
    wire ptw_resp_valid;
    wire [`RV64_XLEN-1:0] ptw_resp_paddr;
    wire ptw_resp_page_fault;
    wire ptw_resp_access_fault;
    wire ptw_resp_invalidated;
    wire ptw_resp_global;
    wire [`RV64_PAGE_LEVEL_WIDTH-1:0] ptw_resp_level;
    wire ptw_resp_readable;
    wire ptw_resp_writable;
    wire ptw_resp_executable;
    wire ptw_resp_user;
    wire ptw_resp_accessed;
    wire ptw_resp_dirty;
    wire ptw_invalidate_busy;
    wire l1d_store_barrier_busy;
    wire ptw_pmp_valid;
    wire ptw_pmp_ready;
    wire [`RV64_XLEN-1:0] ptw_pmp_addr;
    wire ptw_ccx_req_valid;
    wire ptw_ccx_req_ready;
    wire [`OPENRV64_CCX_HART_ID_WIDTH-1:0] ptw_ccx_req_hart_id;
    wire [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] ptw_ccx_req_txn_id;
    wire [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] ptw_ccx_req_source_id;
    wire [`OPENRV64_CCX_OP_WIDTH-1:0] ptw_ccx_req_op;
    wire ptw_ccx_req_lock;
    wire [`OPENRV64_CCX_ORDER_WIDTH-1:0] ptw_ccx_req_order;
    wire [`OPENRV64_CCX_KIND_WIDTH-1:0] ptw_ccx_req_kind;
    wire [`OPENRV64_CCX_ATTR_WIDTH-1:0] ptw_ccx_req_attr;
    wire [2:0] ptw_ccx_req_size;
    wire [63:0] ptw_ccx_req_addr;
    wire [`OPENRV64_CCX_BURST_LEN_WIDTH-1:0]
        ptw_ccx_req_burst_len;
    wire ptw_ccx_resp_ready;

    wire lsu_l1_tlb_miss = (lsu_state_q == LSU_TRANSLATE) &&
                           !lsu_xlate_bare && !dtlb_lookup_hit;
    wire xlate_l1_tlb_miss = dtlb_lookup_is_xlate &&
                             !dtlb_lookup_hit;
    wire fetch_l1_tlb_miss = fetch_xlate_found_r &&
                             !fetch_xlate_bare && !itlb_lookup_hit;
    wire prefetch_l1_tlb_miss = prefetch_xlate_lookup &&
        !prefetch_xlate_bare && !itlb_lookup_hit;

    // The single indexed main TLB serves micro-TLB misses. Demand LSU has
    // priority, then demand fetch, then speculative instruction prefetch.
    // A main-TLB hit
    // refills the requesting micro-TLB. A live tagged LSU consumes that hit
    // directly; captured LSU and fetch requests consume the refill on the
    // following cycle. Only a main-TLB miss starts the blocking walker.
    // A live tagged LSU request may consume a main-TLB hit while an unrelated
    // walk is active. A miss still cannot be captured or start another walk
    // until miss_active_q clears.
    wire l2_tlb_select_xlate = xlate_l1_tlb_miss;
    wire l2_tlb_select_serial_lsu =
        !miss_active_q && !l2_tlb_select_xlate &&
        lsu_l1_tlb_miss;
    wire l2_tlb_select_lsu = l2_tlb_select_xlate ||
                             l2_tlb_select_serial_lsu;
    wire l2_tlb_select_fetch = !miss_active_q &&
                               !l2_tlb_select_lsu &&
                               fetch_l1_tlb_miss;
    wire l2_tlb_select_prefetch = !miss_active_q &&
        !l2_tlb_select_lsu && !l2_tlb_select_fetch &&
        prefetch_l1_tlb_miss;
    wire l2_tlb_lookup_valid = l2_tlb_select_lsu ||
        l2_tlb_select_fetch || l2_tlb_select_prefetch;
    wire [`RV64_XLEN-1:0] l2_tlb_lookup_vaddr =
        l2_tlb_select_xlate ? lsu_xlate_req_vaddr_i :
        l2_tlb_select_serial_lsu ? lsu_vaddr_q :
        l2_tlb_select_fetch ? fetch_vaddr_q[fetch_xlate_slot_r] :
        prefetch_xlate_vaddr_q;
    wire [`RV64_SATP_MODE_WIDTH-1:0] l2_tlb_lookup_vm_mode =
        l2_tlb_select_xlate ? lsu_xlate_req_vm_mode_i :
        l2_tlb_select_serial_lsu ? lsu_vm_mode_q :
        l2_tlb_select_fetch ? fetch_vm_mode_q[fetch_xlate_slot_r] :
        prefetch_xlate_vm_mode_q;
    wire [`RV64_SATP_ASID_WIDTH-1:0] l2_tlb_lookup_asid =
        l2_tlb_select_xlate ? lsu_xlate_req_asid_i :
        l2_tlb_select_serial_lsu ? lsu_asid_q :
        l2_tlb_select_fetch ? fetch_asid_q[fetch_xlate_slot_r] :
        prefetch_xlate_asid_q;
    wire [1:0] l2_tlb_lookup_access = l2_tlb_select_xlate ?
        (lsu_xlate_req_write_i ? ACCESS_WRITE : ACCESS_READ) :
        l2_tlb_select_serial_lsu ?
        (lsu_write_q ? ACCESS_WRITE : ACCESS_READ) : ACCESS_EXEC;
    wire [`RV64_PRIV_WIDTH-1:0] l2_tlb_lookup_priv =
        l2_tlb_select_xlate ? lsu_xlate_req_priv_i :
        l2_tlb_select_serial_lsu ? lsu_priv_q :
        l2_tlb_select_fetch ? fetch_priv_q[fetch_xlate_slot_r] :
        prefetch_xlate_priv_q;
    wire l2_tlb_lookup_sum =
        l2_tlb_select_xlate ? lsu_xlate_req_sum_i :
        l2_tlb_select_serial_lsu ? lsu_sum_q :
        l2_tlb_select_fetch ? fetch_sum_q[fetch_xlate_slot_r] :
        prefetch_xlate_sum_q;
    wire l2_tlb_lookup_mxr =
        l2_tlb_select_xlate ? lsu_xlate_req_mxr_i :
        l2_tlb_select_serial_lsu ? lsu_mxr_q :
        l2_tlb_select_fetch ? fetch_mxr_q[fetch_xlate_slot_r] :
        prefetch_xlate_mxr_q;
    wire l2_tlb_lookup_hit;
    wire [`RV64_XLEN-1:0] l2_tlb_lookup_paddr;
    wire l2_tlb_lookup_page_fault;
    wire l2_tlb_lookup_global;
    wire [`RV64_PAGE_LEVEL_WIDTH-1:0] l2_tlb_lookup_level;
    wire l2_tlb_lookup_readable;
    wire l2_tlb_lookup_writable;
    wire l2_tlb_lookup_executable;
    wire l2_tlb_lookup_user;
    wire l2_tlb_lookup_accessed;
    wire l2_tlb_lookup_dirty;

    // A pipe-side main-TLB miss is first captured by the fallback state.
    // Only that captured request may start a walk; using the live pipe request
    // here would launch the PTW before its tag and attributes were retained.
    wire lsu_needs_walk = l2_tlb_select_serial_lsu &&
                          !l2_tlb_lookup_hit;
    wire fetch_needs_walk =
        l2_tlb_select_fetch && !l2_tlb_lookup_hit;
    wire prefetch_needs_walk =
        l2_tlb_select_prefetch && !l2_tlb_lookup_hit;
    wire start_lsu_walk = !miss_active_q && ptw_req_ready &&
                          lsu_needs_walk;
    wire start_fetch_walk = !miss_active_q && ptw_req_ready &&
                            !lsu_needs_walk && fetch_needs_walk;
    wire start_prefetch_walk = !miss_active_q && ptw_req_ready &&
        !lsu_needs_walk && !fetch_needs_walk && prefetch_needs_walk;
    wire ptw_req_valid = start_lsu_walk || start_fetch_walk ||
                         start_prefetch_walk;
    wire [1:0] ptw_req_owner = start_lsu_walk ? OWNER_LSU :
        start_fetch_walk ? OWNER_FETCH : OWNER_PREFETCH;
    wire [`RV64_XLEN-1:0] ptw_req_vaddr = start_lsu_walk ?
        lsu_vaddr_q : start_fetch_walk ?
        fetch_vaddr_q[fetch_xlate_slot_r] :
        prefetch_xlate_vaddr_q;
    wire [1:0] ptw_req_access = start_lsu_walk ?
        (lsu_write_q ? ACCESS_WRITE : ACCESS_READ) : ACCESS_EXEC;
    wire [`RV64_PRIV_WIDTH-1:0] ptw_req_priv = start_lsu_walk ?
        lsu_priv_q : start_fetch_walk ?
        fetch_priv_q[fetch_xlate_slot_r] :
        prefetch_xlate_priv_q;
    wire [`RV64_SATP_MODE_WIDTH-1:0] ptw_req_vm_mode = start_lsu_walk ?
        lsu_vm_mode_q : start_fetch_walk ?
        fetch_vm_mode_q[fetch_xlate_slot_r] :
        prefetch_xlate_vm_mode_q;
    wire [`RV64_SATP_ASID_WIDTH-1:0] ptw_req_asid = start_lsu_walk ?
        lsu_asid_q : start_fetch_walk ?
        fetch_asid_q[fetch_xlate_slot_r] :
        prefetch_xlate_asid_q;
    wire [`RV64_SATP_PPN_WIDTH-1:0] ptw_req_root_ppn = start_lsu_walk ?
        lsu_root_ppn_q : start_fetch_walk ?
        fetch_root_ppn_q[fetch_xlate_slot_r] :
        prefetch_xlate_root_ppn_q;
    wire ptw_req_sum = start_lsu_walk ?
        lsu_sum_q : start_fetch_walk ?
        fetch_sum_q[fetch_xlate_slot_r] :
        prefetch_xlate_sum_q;
    wire ptw_req_mxr = start_lsu_walk ?
        lsu_mxr_q : start_fetch_walk ?
        fetch_mxr_q[fetch_xlate_slot_r] :
        prefetch_xlate_mxr_q;

    wire itlb_fill_for_fetch = (miss_owner_q == OWNER_FETCH) &&
        !fetch_cancelled_q[miss_fetch_slot_q];
    wire itlb_fill_for_prefetch = (miss_owner_q == OWNER_PREFETCH);
    wire itlb_ptw_fill_valid = ptw_resp_valid && miss_active_q &&
        (itlb_fill_for_fetch || itlb_fill_for_prefetch) &&
        !miss_invalidated_q && !ptw_resp_invalidated &&
        !ptw_resp_page_fault && !ptw_resp_access_fault && !tlbi_i;
    wire dtlb_ptw_fill_valid = ptw_resp_valid && miss_active_q &&
        (miss_owner_q == OWNER_LSU) && !miss_invalidated_q &&
        !ptw_resp_invalidated &&
        !ptw_resp_page_fault && !ptw_resp_access_fault && !tlbi_i;
    wire itlb_l2_fill_valid = l2_tlb_lookup_hit &&
        (l2_tlb_select_fetch || l2_tlb_select_prefetch) && !tlbi_i;
    wire dtlb_l2_fill_valid = l2_tlb_lookup_hit &&
        l2_tlb_select_lsu && !tlbi_i;
    wire itlb_fill_valid = itlb_ptw_fill_valid || itlb_l2_fill_valid;
    wire dtlb_fill_valid = dtlb_ptw_fill_valid || dtlb_l2_fill_valid;

    wire itlb_lookup_is_prefetch = prefetch_xlate_lookup;
    wire [`RV64_XLEN-1:0] itlb_lookup_vaddr =
        itlb_lookup_is_prefetch ? prefetch_xlate_vaddr_q :
        fetch_lookup_vaddr;
    wire [`RV64_SATP_MODE_WIDTH-1:0] itlb_lookup_vm_mode =
        itlb_lookup_is_prefetch ? prefetch_xlate_vm_mode_q :
        fetch_lookup_vm_mode;
    wire [`RV64_SATP_ASID_WIDTH-1:0] itlb_lookup_asid =
        itlb_lookup_is_prefetch ? prefetch_xlate_asid_q :
        fetch_asid_q[fetch_xlate_slot_r];
    wire [`RV64_PRIV_WIDTH-1:0] itlb_lookup_priv =
        itlb_lookup_is_prefetch ? prefetch_xlate_priv_q :
        fetch_lookup_priv;
    wire itlb_lookup_sum =
        itlb_lookup_is_prefetch ? prefetch_xlate_sum_q :
        fetch_sum_q[fetch_xlate_slot_r];
    wire itlb_lookup_mxr =
        itlb_lookup_is_prefetch ? prefetch_xlate_mxr_q :
        fetch_mxr_q[fetch_xlate_slot_r];
    wire [`RV64_XLEN-1:0] itlb_fill_vaddr = itlb_fill_for_prefetch ?
        prefetch_xlate_vaddr_q : fetch_vaddr_q[miss_fetch_slot_q];
    wire [`RV64_SATP_MODE_WIDTH-1:0] itlb_fill_vm_mode =
        itlb_fill_for_prefetch ? prefetch_xlate_vm_mode_q :
        fetch_vm_mode_q[miss_fetch_slot_q];
    wire [`RV64_SATP_ASID_WIDTH-1:0] itlb_fill_asid =
        itlb_fill_for_prefetch ? prefetch_xlate_asid_q :
        fetch_asid_q[miss_fetch_slot_q];
    wire [`RV64_XLEN-1:0] selected_itlb_fill_vaddr =
        itlb_ptw_fill_valid ? itlb_fill_vaddr : l2_tlb_lookup_vaddr;
    wire [`RV64_XLEN-1:0] selected_itlb_fill_paddr =
        itlb_ptw_fill_valid ? ptw_resp_paddr : l2_tlb_lookup_paddr;
    wire [`RV64_SATP_MODE_WIDTH-1:0] selected_itlb_fill_vm_mode =
        itlb_ptw_fill_valid ? itlb_fill_vm_mode :
        l2_tlb_lookup_vm_mode;
    wire [`RV64_SATP_ASID_WIDTH-1:0] selected_itlb_fill_asid =
        itlb_ptw_fill_valid ? itlb_fill_asid : l2_tlb_lookup_asid;
    wire selected_itlb_fill_global = itlb_ptw_fill_valid ?
        ptw_resp_global : l2_tlb_lookup_global;
    wire [`RV64_PAGE_LEVEL_WIDTH-1:0] selected_itlb_fill_level =
        itlb_ptw_fill_valid ? ptw_resp_level : l2_tlb_lookup_level;
    wire selected_itlb_fill_readable = itlb_ptw_fill_valid ?
        ptw_resp_readable : l2_tlb_lookup_readable;
    wire selected_itlb_fill_writable = itlb_ptw_fill_valid ?
        ptw_resp_writable : l2_tlb_lookup_writable;
    wire selected_itlb_fill_executable = itlb_ptw_fill_valid ?
        ptw_resp_executable : l2_tlb_lookup_executable;
    wire selected_itlb_fill_user = itlb_ptw_fill_valid ?
        ptw_resp_user : l2_tlb_lookup_user;
    wire selected_itlb_fill_accessed = itlb_ptw_fill_valid ?
        ptw_resp_accessed : l2_tlb_lookup_accessed;
    wire selected_itlb_fill_dirty = itlb_ptw_fill_valid ?
        ptw_resp_dirty : l2_tlb_lookup_dirty;

    wire [`RV64_XLEN-1:0] selected_dtlb_fill_vaddr =
        dtlb_ptw_fill_valid ? lsu_vaddr_q : l2_tlb_lookup_vaddr;
    wire [`RV64_XLEN-1:0] selected_dtlb_fill_paddr =
        dtlb_ptw_fill_valid ? ptw_resp_paddr : l2_tlb_lookup_paddr;
    wire [`RV64_SATP_MODE_WIDTH-1:0] selected_dtlb_fill_vm_mode =
        dtlb_ptw_fill_valid ? lsu_vm_mode_q : l2_tlb_lookup_vm_mode;
    wire [`RV64_SATP_ASID_WIDTH-1:0] selected_dtlb_fill_asid =
        dtlb_ptw_fill_valid ? lsu_asid_q : l2_tlb_lookup_asid;
    wire selected_dtlb_fill_global = dtlb_ptw_fill_valid ?
        ptw_resp_global : l2_tlb_lookup_global;
    wire [`RV64_PAGE_LEVEL_WIDTH-1:0] selected_dtlb_fill_level =
        dtlb_ptw_fill_valid ? ptw_resp_level : l2_tlb_lookup_level;
    wire selected_dtlb_fill_readable = dtlb_ptw_fill_valid ?
        ptw_resp_readable : l2_tlb_lookup_readable;
    wire selected_dtlb_fill_writable = dtlb_ptw_fill_valid ?
        ptw_resp_writable : l2_tlb_lookup_writable;
    wire selected_dtlb_fill_executable = dtlb_ptw_fill_valid ?
        ptw_resp_executable : l2_tlb_lookup_executable;
    wire selected_dtlb_fill_user = dtlb_ptw_fill_valid ?
        ptw_resp_user : l2_tlb_lookup_user;
    wire selected_dtlb_fill_accessed = dtlb_ptw_fill_valid ?
        ptw_resp_accessed : l2_tlb_lookup_accessed;
    wire selected_dtlb_fill_dirty = dtlb_ptw_fill_valid ?
        ptw_resp_dirty : l2_tlb_lookup_dirty;

    openrv64_bus_tlb #(
        .ENTRIES(TLB_ENTRIES), .ASID_WIDTH(`RV64_SATP_ASID_WIDTH)
    ) u_itlb (
        .clk(clk), .rst_n(rst_n), .tlbi_i(tlbi_i),
        .lookup_valid_i((fetch_lookup_valid && !fetch_lookup_bare) ||
                        (prefetch_xlate_lookup && !prefetch_xlate_bare)),
        .lookup_vaddr_i(itlb_lookup_vaddr),
        .lookup_vm_mode_i(itlb_lookup_vm_mode),
        .lookup_asid_i(itlb_lookup_asid),
        .lookup_access_i(ACCESS_EXEC),
        .lookup_priv_i(itlb_lookup_priv),
        .lookup_sum_i(itlb_lookup_sum),
        .lookup_mxr_i(itlb_lookup_mxr),
        .lookup_hit_o(itlb_lookup_hit),
        .lookup_paddr_o(itlb_lookup_paddr),
        .lookup_page_fault_o(itlb_lookup_page_fault),
        .fill_valid_i(itlb_fill_valid),
        .fill_vaddr_i(selected_itlb_fill_vaddr),
        .fill_paddr_i(selected_itlb_fill_paddr),
        .fill_vm_mode_i(selected_itlb_fill_vm_mode),
        .fill_asid_i(selected_itlb_fill_asid),
        .fill_global_i(selected_itlb_fill_global),
        .fill_level_i(selected_itlb_fill_level),
        .fill_readable_i(selected_itlb_fill_readable),
        .fill_writable_i(selected_itlb_fill_writable),
        .fill_executable_i(selected_itlb_fill_executable),
        .fill_user_i(selected_itlb_fill_user),
        .fill_accessed_i(selected_itlb_fill_accessed),
        .fill_dirty_i(selected_itlb_fill_dirty)
    );

    openrv64_bus_tlb #(
        .ENTRIES(TLB_ENTRIES), .ASID_WIDTH(`RV64_SATP_ASID_WIDTH)
    ) u_dtlb (
        .clk(clk), .rst_n(rst_n), .tlbi_i(tlbi_i),
        .lookup_valid_i(dtlb_lookup_valid),
        .lookup_vaddr_i(dtlb_lookup_vaddr),
        .lookup_vm_mode_i(dtlb_lookup_vm_mode),
        .lookup_asid_i(dtlb_lookup_asid),
        .lookup_access_i(dtlb_lookup_access),
        .lookup_priv_i(dtlb_lookup_priv),
        .lookup_sum_i(dtlb_lookup_sum),
        .lookup_mxr_i(dtlb_lookup_mxr),
        .lookup_hit_o(dtlb_lookup_hit),
        .lookup_paddr_o(dtlb_lookup_paddr),
        .lookup_page_fault_o(dtlb_lookup_page_fault),
        .fill_valid_i(dtlb_fill_valid),
        .fill_vaddr_i(selected_dtlb_fill_vaddr),
        .fill_paddr_i(selected_dtlb_fill_paddr),
        .fill_vm_mode_i(selected_dtlb_fill_vm_mode),
        .fill_asid_i(selected_dtlb_fill_asid),
        .fill_global_i(selected_dtlb_fill_global),
        .fill_level_i(selected_dtlb_fill_level),
        .fill_readable_i(selected_dtlb_fill_readable),
        .fill_writable_i(selected_dtlb_fill_writable),
        .fill_executable_i(selected_dtlb_fill_executable),
        .fill_user_i(selected_dtlb_fill_user),
        .fill_accessed_i(selected_dtlb_fill_accessed),
        .fill_dirty_i(selected_dtlb_fill_dirty)
    );

    wire l2_tlb_fill_valid = ptw_resp_valid && miss_active_q &&
        !miss_invalidated_q && !ptw_resp_invalidated &&
        !ptw_resp_page_fault && !ptw_resp_access_fault && !tlbi_i;
    wire [`RV64_XLEN-1:0] l2_tlb_fill_vaddr =
        (miss_owner_q == OWNER_LSU) ? lsu_vaddr_q :
        (miss_owner_q == OWNER_PREFETCH) ? prefetch_xlate_vaddr_q :
        fetch_vaddr_q[miss_fetch_slot_q];
    wire [`RV64_SATP_MODE_WIDTH-1:0] l2_tlb_fill_vm_mode =
        (miss_owner_q == OWNER_LSU) ? lsu_vm_mode_q :
        (miss_owner_q == OWNER_PREFETCH) ? prefetch_xlate_vm_mode_q :
        fetch_vm_mode_q[miss_fetch_slot_q];
    wire [`RV64_SATP_ASID_WIDTH-1:0] l2_tlb_fill_asid =
        (miss_owner_q == OWNER_LSU) ? lsu_asid_q :
        (miss_owner_q == OWNER_PREFETCH) ? prefetch_xlate_asid_q :
        fetch_asid_q[miss_fetch_slot_q];

    openrv64_bus_tlb_l2 #(
        .ENTRIES(L2_TLB_ENTRIES),
        .WAYS(L2_TLB_WAYS),
        .ASID_WIDTH(`RV64_SATP_ASID_WIDTH)
    ) u_l2_tlb (
        .clk(clk), .rst_n(rst_n), .tlbi_i(tlbi_i),
        .lookup_valid_i(l2_tlb_lookup_valid),
        .lookup_vaddr_i(l2_tlb_lookup_vaddr),
        .lookup_vm_mode_i(l2_tlb_lookup_vm_mode),
        .lookup_asid_i(l2_tlb_lookup_asid),
        .lookup_access_i(l2_tlb_lookup_access),
        .lookup_priv_i(l2_tlb_lookup_priv),
        .lookup_sum_i(l2_tlb_lookup_sum),
        .lookup_mxr_i(l2_tlb_lookup_mxr),
        .lookup_hit_o(l2_tlb_lookup_hit),
        .lookup_paddr_o(l2_tlb_lookup_paddr),
        .lookup_page_fault_o(l2_tlb_lookup_page_fault),
        .lookup_global_o(l2_tlb_lookup_global),
        .lookup_level_o(l2_tlb_lookup_level),
        .lookup_readable_o(l2_tlb_lookup_readable),
        .lookup_writable_o(l2_tlb_lookup_writable),
        .lookup_executable_o(l2_tlb_lookup_executable),
        .lookup_user_o(l2_tlb_lookup_user),
        .lookup_accessed_o(l2_tlb_lookup_accessed),
        .lookup_dirty_o(l2_tlb_lookup_dirty),
        .fill_valid_i(l2_tlb_fill_valid),
        .fill_vaddr_i(l2_tlb_fill_vaddr),
        .fill_paddr_i(ptw_resp_paddr),
        .fill_vm_mode_i(l2_tlb_fill_vm_mode),
        .fill_asid_i(l2_tlb_fill_asid),
        .fill_global_i(ptw_resp_global),
        .fill_level_i(ptw_resp_level),
        .fill_readable_i(ptw_resp_readable),
        .fill_writable_i(ptw_resp_writable),
        .fill_executable_i(ptw_resp_executable),
        .fill_user_i(ptw_resp_user),
        .fill_accessed_i(ptw_resp_accessed),
        .fill_dirty_i(ptw_resp_dirty)
    );

    openrv64_bus_ptw #(
        .PTE_CACHE_ENTRIES(PTW_PTE_CACHE_ENTRIES),
        .CCX_TIMEOUT_CYCLES(PTW_CCX_TIMEOUT_CYCLES),
        .HART_ID(HART_ID),
        .TXN_ID(PTE_TXN_ID)
    ) u_ptw (
        .clk(clk), .rst_n(rst_n), .invalidate_i(tlbi_i),
        .invalidate_busy_o(ptw_invalidate_busy),
        .shootdown_ready_i(!l1d_store_barrier_busy),
        .req_valid_i(ptw_req_valid),
        .req_ready_o(ptw_req_ready), .req_vaddr_i(ptw_req_vaddr),
        .req_access_i(ptw_req_access), .req_priv_i(ptw_req_priv),
        .req_vm_mode_i(ptw_req_vm_mode), .req_asid_i(ptw_req_asid),
        .req_root_ppn_i(ptw_req_root_ppn), .req_sum_i(ptw_req_sum),
        .req_mxr_i(ptw_req_mxr), .resp_valid_o(ptw_resp_valid),
        .resp_ready_i(1'b1), .resp_paddr_o(ptw_resp_paddr),
        .resp_page_fault_o(ptw_resp_page_fault),
        .resp_access_fault_o(ptw_resp_access_fault),
        .resp_invalidated_o(ptw_resp_invalidated),
        .resp_global_o(ptw_resp_global), .resp_level_o(ptw_resp_level),
        .resp_readable_o(ptw_resp_readable),
        .resp_writable_o(ptw_resp_writable),
        .resp_executable_o(ptw_resp_executable),
        .resp_user_o(ptw_resp_user), .resp_accessed_o(ptw_resp_accessed),
        .resp_dirty_o(ptw_resp_dirty),
        .pmp_valid_o(ptw_pmp_valid),
        .pmp_ready_i(ptw_pmp_ready),
        .pmp_addr_o(ptw_pmp_addr),
        .pmp_allow_i(pmp_allow_i),
        .ccx_req_valid_o(ptw_ccx_req_valid),
        .ccx_req_ready_i(ptw_ccx_req_ready),
        .ccx_req_hart_id_o(ptw_ccx_req_hart_id),
        .ccx_req_txn_id_o(ptw_ccx_req_txn_id),
        .ccx_req_source_id_o(ptw_ccx_req_source_id),
        .ccx_req_op_o(ptw_ccx_req_op),
        .ccx_req_lock_o(ptw_ccx_req_lock),
        .ccx_req_order_o(ptw_ccx_req_order),
        .ccx_req_kind_o(ptw_ccx_req_kind),
        .ccx_req_attr_o(ptw_ccx_req_attr),
        .ccx_req_size_o(ptw_ccx_req_size),
        .ccx_req_addr_o(ptw_ccx_req_addr),
        .ccx_req_burst_len_o(ptw_ccx_req_burst_len),
        .ccx_resp_valid_i(ccx_resp_valid_i),
        .ccx_resp_ready_o(ptw_ccx_resp_ready),
        .ccx_resp_hart_id_i(ccx_resp_hart_id_i),
        .ccx_resp_txn_id_i(ccx_resp_txn_id_i),
        .ccx_resp_source_id_i(ccx_resp_source_id_i),
        .ccx_resp_beat_index_i(ccx_resp_beat_index_i),
        .ccx_resp_last_i(ccx_resp_last_i),
        .ccx_resp_rdata_i(ccx_resp_rdata_i),
        .ccx_resp_error_i(ccx_resp_error_i)
    );

    // Normal tagged LSU traffic is physical. Translation has its own tagged
    // channel, allowing one D micro-TLB probe and one L1D access in a cycle.
    assign lsu_pipe_req_translation_hit_o = 1'b0;
    assign lsu_pipe_req_translation_paddr_o =
        {`RV64_XLEN{1'b0}};
    assign lsu_pipe_req_translation_page_fault_o = 1'b0;
    wire [`RV64_XLEN-1:0] pipe_req_paddr = lsu_pipe_req_addr_i;
    wire pipe_req_cacheable = (L1D_CACHEABLE_SIZE != 0) &&
        ((pipe_req_paddr - L1D_CACHEABLE_BASE) <
         L1D_CACHEABLE_SIZE);
    wire pipe_fast_class = pipe_req_bare &&
        !lsu_pipe_req_xlate_only_i &&
        !lsu_pipe_req_lock_i && pipe_req_cacheable;
    wire pipe_local_resp_available =
        !pipe_local_resp_valid_q || lsu_pipe_resp_ready_i;
    wire pipe_fast_candidate = lsu_pipe_req_valid_i &&
        pipe_req_tag_valid && !pipe_req_tag_busy && !lsu_pipe_cancel_i &&
        pipe_fast_class && pipe_local_resp_available &&
        pipe_fast_state_available && !ptw_pmp_valid;
    wire pipe_fallback_candidate = lsu_pipe_req_valid_i &&
        pipe_req_tag_valid && !pipe_req_tag_busy && !lsu_pipe_cancel_i &&
        !pipe_fast_class &&
        !pipe_fallback_active_q &&
        !lsu_valid_i && (lsu_state_q == LSU_IDLE) &&
        !miss_active_q;

    wire xlate_l1_hit = dtlb_lookup_is_xlate && dtlb_lookup_hit;
    wire xlate_l2_hit = l2_tlb_select_xlate && l2_tlb_lookup_hit;
    wire xlate_lookup_hit = xlate_l1_hit || xlate_l2_hit;
    wire [`RV64_XLEN-1:0] xlate_lookup_paddr =
        xlate_req_bare ? lsu_xlate_req_vaddr_i :
        xlate_l1_hit ? dtlb_lookup_paddr : l2_tlb_lookup_paddr;
    wire xlate_lookup_page_fault =
        (xlate_l1_hit && dtlb_lookup_page_fault) ||
        (xlate_l2_hit && l2_tlb_lookup_page_fault);
    wire xlate_fallback_response_pending =
        xlate_fallback_active_q && (lsu_state_q == LSU_RESP);
    // A fast hit is returned combinationally when no older response occupies
    // the output. The one-entry register is only a skid buffer. Do not let a
    // queued fast response indefinitely displace a completed page walk.
    wire xlate_local_resp_available =
        (!xlate_local_resp_valid_q &&
         !xlate_fallback_response_pending) ||
        (lsu_xlate_resp_ready_i &&
         !(xlate_local_resp_valid_q &&
           xlate_fallback_response_pending));
    wire xlate_fast_candidate = lsu_xlate_req_valid_i &&
        !tlbi_i && !tlbi_busy_o && xlate_local_resp_available &&
        (xlate_req_bare || xlate_lookup_hit);
    wire xlate_fallback_candidate = lsu_xlate_req_valid_i &&
        !tlbi_i && !tlbi_busy_o &&
        !xlate_req_bare && dtlb_lookup_is_xlate &&
        !dtlb_lookup_hit && l2_tlb_select_xlate &&
        !l2_tlb_lookup_hit && !miss_active_q &&
        !pipe_fallback_candidate &&
        !xlate_fallback_active_q && !pipe_fallback_active_q &&
        !lsu_valid_i && (lsu_state_q == LSU_IDLE);
    assign lsu_xlate_req_ready_o =
        xlate_fast_candidate || xlate_fallback_candidate;
    wire xlate_request_fire =
        lsu_xlate_req_valid_i && lsu_xlate_req_ready_o;

    wire ptw_pmp_candidate = ptw_pmp_valid;

    wire fetch_axi_candidate = fetch_xlate_found_r && fetch_lookup_ready &&
                               !itlb_lookup_page_fault &&
                               !fetch_cancel_i;
    wire [`RV64_XLEN-1:0] fetch_axi_addr = {
        fetch_lookup_paddr[`RV64_XLEN-1:AXI_BYTE_BITS],
        {AXI_BYTE_BITS{1'b0}}
    };

    // The L1I accepts tagged, decoupled 256-bit frontend requests and stores
    // native 64-byte lines.  The fetch slot is the L1I request tag, so a hit
    // may complete while older misses remain outstanding.
    reg l1i_req_active_q;
    reg [`RV64_XLEN-1:0] l1i_req_vaddr_q;
    reg [`RV64_XLEN-1:0] l1i_req_paddr_q;
    reg [FETCH_SLOT_WIDTH-1:0] l1i_req_slot_q;
    reg l1i_invalidate_pending_q;
    wire l1i_invalidate_ready;
    wire l1i_invalidate_valid = icache_invalidate_i ||
                                l1i_invalidate_pending_q;
    wire l1i_req_ready;
    wire l1i_resp_valid;
    wire l1i_resp_ready;
    wire [FETCH_SLOT_WIDTH-1:0] l1i_resp_tag;
    wire [AXI_DATA_WIDTH-1:0] l1i_req_rdata;
    wire l1i_req_error;
    wire axi_r_error;
    wire l1i_enabled = (ENABLE_L1I != 0);
    wire fetch_cache_candidate = fetch_axi_candidate &&
        (!l1i_enabled || (!l1i_req_active_q &&
                          !l1i_invalidate_valid));

    // Tagged fast-path data gets the single PMP probe first, except when the
    // active walker needs it.  Once a request enters L1D, the probe is free
    // again while the tagged cache response is pending.
    wire select_pipe_probe = pipe_fast_candidate;
    wire select_lsu_probe = !select_pipe_probe &&
                            (lsu_state_q == LSU_ACCESS);
    wire select_ptw_probe = !select_pipe_probe && !select_lsu_probe &&
                            ptw_pmp_candidate;
    wire select_fetch_probe = !select_pipe_probe && !select_lsu_probe &&
                              !select_ptw_probe && fetch_cache_candidate;
    wire select_prefetch_probe = !select_pipe_probe && !select_lsu_probe &&
        !select_ptw_probe && !select_fetch_probe &&
        (prefetch_xlate_state_q == PREFETCH_XLATE_PMP);
    assign pmp_valid_o = select_pipe_probe || select_lsu_probe ||
                         select_ptw_probe ||
                         select_fetch_probe || select_prefetch_probe;
    assign pmp_addr_o = select_pipe_probe ? pipe_req_paddr :
                        select_lsu_probe ? lsu_paddr_q :
                        select_ptw_probe ? ptw_pmp_addr :
                        select_fetch_probe ? fetch_axi_addr :
                        prefetch_xlate_paddr_q;
    assign pmp_priv_o = select_pipe_probe ? lsu_pipe_req_priv_i :
                        select_lsu_probe ? lsu_priv_q :
                        select_ptw_probe ? `RV64_PRIV_S :
                        select_fetch_probe ? fetch_lookup_priv :
                        prefetch_xlate_priv_q;
    assign pmp_size_o = select_pipe_probe ? lsu_pipe_req_size_i :
                        select_lsu_probe ? lsu_size_q :
                        select_ptw_probe ? 3'd3 : 3'd5;
    assign pmp_write_o = select_pipe_probe ? lsu_pipe_req_write_i :
                         select_lsu_probe ? lsu_write_q :
                         1'b0;
    assign pmp_exec_o = select_fetch_probe || select_prefetch_probe;

    wire pipe_pmp_denied = select_pipe_probe && !pmp_allow_i;
    wire lsu_pmp_denied = select_lsu_probe && !pmp_allow_i;
    assign ptw_pmp_ready = select_ptw_probe;
    wire fetch_pmp_denied = select_fetch_probe && !pmp_allow_i;
    wire prefetch_pmp_complete = select_prefetch_probe;
    wire fetch_l1i_launch = l1i_enabled && select_fetch_probe && pmp_allow_i;
    wire l1i_req_valid = l1i_enabled &&
                         (l1i_req_active_q || fetch_l1i_launch);
    wire [`RV64_XLEN-1:0] l1i_req_vaddr = l1i_req_active_q ?
        l1i_req_vaddr_q : fetch_lookup_vaddr;
    wire [`RV64_XLEN-1:0] l1i_req_paddr = l1i_req_active_q ?
        l1i_req_paddr_q : fetch_axi_addr;
    wire [FETCH_SLOT_WIDTH-1:0] l1i_req_slot = l1i_req_active_q ?
        l1i_req_slot_q : fetch_xlate_slot_r;
    wire l1i_req_fire = l1i_req_valid && l1i_req_ready;
    wire l1i_resp_fire = l1i_resp_valid && l1i_resp_ready;
    wire [FETCH_SLOT_WIDTH-1:0] l1i_resp_slot = l1i_resp_tag;
    assign l1i_resp_ready = 1'b1;

    wire l1d_pipe_request = select_pipe_probe && pmp_allow_i;
    wire l1d_serial_tag_busy =
        pipe_inflight_q[pipe_fallback_tag_q] ||
        (pipe_local_resp_valid_q &&
         (pipe_local_resp_tag_q == pipe_fallback_tag_q));
    wire l1d_serial_request = select_lsu_probe && pmp_allow_i &&
                              !lsu_xlate_only_q &&
                              !l1d_serial_tag_busy;
    wire l1d_req_valid = l1d_pipe_request || l1d_serial_request;
    wire l1d_req_ready;
    wire [`RV64_XLEN-1:0] l1d_req_rdata;
    wire l1d_req_error;
    wire l1d_serial_cacheable = (L1D_CACHEABLE_SIZE != 0) &&
        ((lsu_paddr_q - L1D_CACHEABLE_BASE) < L1D_CACHEABLE_SIZE);
    wire l1d_req_lock = l1d_pipe_request ? 1'b0 : lsu_lock_q;
    wire l1d_req_write = l1d_pipe_request ?
        lsu_pipe_req_write_i : lsu_write_q;
    wire l1d_req_cacheable = l1d_pipe_request ?
        pipe_req_cacheable : l1d_serial_cacheable;
    wire [`RV64_XLEN-1:0] l1d_req_addr = l1d_pipe_request ?
        pipe_req_paddr : lsu_paddr_q;
    wire [2:0] l1d_req_size = l1d_pipe_request ?
        lsu_pipe_req_size_i : lsu_size_q;
    wire [`RV64_XLEN-1:0] l1d_req_wdata = l1d_pipe_request ?
        lsu_pipe_req_wdata_i : lsu_wdata_q;
    wire [7:0] l1d_req_wstrb = l1d_pipe_request ?
        lsu_pipe_req_wstrb_i : lsu_wstrb_q;
    wire l1d_posted_request = l1d_req_write && !l1d_req_lock &&
        l1d_req_cacheable &&
        (l1d_pipe_request || pipe_fallback_active_q);
    // The LSU tag is the global request identity.  Pipe fallback and serial
    // processing are control states, not separate tag namespaces.
    wire [L1D_REQ_TAG_WIDTH-1:0] l1d_req_tag =
        l1d_pipe_request ? lsu_pipe_req_tag_i : pipe_fallback_tag_q;
    wire l1d_resp_valid;
    wire l1d_resp_ready;
    wire [L1D_REQ_TAG_WIDTH-1:0] l1d_resp_tag;
    wire l1d_resp_is_pipe = pipe_inflight_q[l1d_resp_tag];
    wire [`OPENRV64_LSU_TAG_WIDTH-1:0] l1d_resp_pipe_tag =
        l1d_resp_tag;
    wire l1d_posted_resp_valid;
    wire l1d_posted_resp_ready;
    wire [L1D_REQ_TAG_WIDTH-1:0] l1d_posted_resp_tag;
    wire l1d_posted_resp_is_pipe =
        pipe_inflight_q[l1d_posted_resp_tag];
    wire [`OPENRV64_LSU_TAG_WIDTH-1:0] l1d_posted_resp_pipe_tag =
        l1d_posted_resp_tag;
    wire l1d_store_resp_valid;
    wire l1d_store_resp_error;
    wire l1d_invalidate_ready;
    assign l1d_probe_ready_o =
        (ENABLE_L1D_COHERENCE_PROBES != 0) &&
        l1d_invalidate_ready;

    wire l1d_ccx_req_valid;
    wire l1d_ccx_req_ready;
    wire [`OPENRV64_CCX_HART_ID_WIDTH-1:0] l1d_ccx_req_hart_id;
    wire [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] l1d_ccx_req_txn_id;
    wire [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] l1d_ccx_req_source_id;
    wire [`OPENRV64_CCX_OP_WIDTH-1:0] l1d_ccx_req_op;
    wire l1d_ccx_req_lock;
    wire [`OPENRV64_CCX_ORDER_WIDTH-1:0] l1d_ccx_req_order;
    wire [`OPENRV64_CCX_KIND_WIDTH-1:0] l1d_ccx_req_kind;
    wire [`OPENRV64_CCX_ATTR_WIDTH-1:0] l1d_ccx_req_attr;
    wire [2:0] l1d_ccx_req_size;
    wire [63:0] l1d_ccx_req_addr;
    wire [`OPENRV64_CCX_BURST_LEN_WIDTH-1:0] l1d_ccx_req_burst_len;
    wire l1d_ccx_wdata_valid;
    wire [`OPENRV64_CCX_HART_ID_WIDTH-1:0] l1d_ccx_wdata_hart_id;
    wire [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] l1d_ccx_wdata_txn_id;
    wire [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] l1d_ccx_wdata_source_id;
    wire [`OPENRV64_CCX_BEAT_INDEX_WIDTH-1:0] l1d_ccx_wdata_beat_index;
    wire l1d_ccx_wdata_last;
    wire [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] l1d_ccx_wdata;
    wire [`OPENRV64_CCX_LINE_STRB_WIDTH-1:0] l1d_ccx_wstrb;
    wire l1d_ccx_resp_valid = ccx_resp_valid_i &&
        (ccx_resp_source_id_i == `OPENRV64_CCX_SOURCE_DCACHE);
    wire l1d_ccx_resp_ready;

    wire l1i_ccx_req_valid;
    wire l1i_ccx_req_ready;
    wire [`OPENRV64_CCX_HART_ID_WIDTH-1:0] l1i_ccx_req_hart_id;
    wire [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] l1i_ccx_req_source_id;
    wire [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] l1i_ccx_req_txn_id;
    wire [`OPENRV64_CCX_OP_WIDTH-1:0] l1i_ccx_req_op;
    wire [`OPENRV64_CCX_ORDER_WIDTH-1:0] l1i_ccx_req_order;
    wire [`OPENRV64_CCX_KIND_WIDTH-1:0] l1i_ccx_req_kind;
    wire [`OPENRV64_CCX_ATTR_WIDTH-1:0] l1i_ccx_req_attr;
    wire [2:0] l1i_ccx_req_size;
    wire [63:0] l1i_ccx_req_addr;
    wire [`OPENRV64_CCX_BURST_LEN_WIDTH-1:0] l1i_ccx_req_burst_len;
    wire l1i_ccx_resp_valid = ccx_resp_valid_i &&
        (ccx_resp_source_id_i == `OPENRV64_CCX_SOURCE_ICACHE);
    wire l1i_ccx_resp_ready;

    openrv64_l1d_ccx #(
        .ENABLE(ENABLE_L1D),
        .COHERENT_ATOMICS(ENABLE_COHERENT_ATOMICS),
        .ADDR_WIDTH(`RV64_XLEN),
        .CACHE_BYTES(L1D_CACHE_BYTES),
        .LINE_BYTES(64),
        .WAYS(4),
        .FILL_BUFFER_LINES(L1D_FILL_BUFFER_LINES),
        .DEMAND_MSHRS(L1D_DEMAND_MSHRS),
        .STORE_BUFFER_LINES(L1D_STORE_BUFFER_LINES),
        .PREFETCH_ENABLE(L1D_PREFETCH_ENABLE),
        .PREFETCH_CACHEABLE_BASE(L1D_CACHEABLE_BASE),
        .PREFETCH_CACHEABLE_SIZE(L1D_CACHEABLE_SIZE),
        .PREFETCH_MAX_STRIDE_LINES(L1D_PREFETCH_MAX_STRIDE_LINES),
        .PREFETCH_STREAMS(L1D_PREFETCH_STREAMS),
        .PREFETCH_DISTANCE(L1D_PREFETCH_DISTANCE),
        .PREFETCH_ADAPTIVE_ENABLE(L1D_PREFETCH_ADAPTIVE_ENABLE),
        .PREFETCH_MAX_DISTANCE(L1D_PREFETCH_MAX_DISTANCE),
        .PREFETCH_QUEUE_LINES(L1D_PREFETCH_QUEUE_LINES),
        .PREFETCH_OUTSTANDING(L1D_PREFETCH_OUTSTANDING),
        .PREFETCH_DEMAND_RESERVE(L1D_PREFETCH_DEMAND_RESERVE),
        .REQ_TAG_WIDTH(L1D_REQ_TAG_WIDTH),
        .REQ_DEPTH(`OPENRV64_LSU_OUTSTANDING),
        .HART_ID(HART_ID)
    ) u_l1d (
        .clk_i(clk),
        .rst_ni(rst_n),
        .req_valid_i(l1d_req_valid),
        .req_ready_o(l1d_req_ready),
        .req_tag_i(l1d_req_tag),
        .req_lock_i(l1d_req_lock),
        .req_posted_i(l1d_posted_request),
        .req_write_i(l1d_req_write),
        .req_cacheable_i(l1d_req_cacheable),
        .req_addr_i(l1d_req_addr),
        .req_size_i(l1d_req_size),
        .req_wdata_i(l1d_req_wdata),
        .req_wstrb_i(l1d_req_wstrb),
        .req_rdata_o(l1d_req_rdata),
        .req_error_o(l1d_req_error),
        .resp_valid_o(l1d_resp_valid),
        .resp_ready_i(l1d_resp_ready),
        .resp_tag_o(l1d_resp_tag),
        .posted_resp_valid_o(l1d_posted_resp_valid),
        .posted_resp_ready_i(l1d_posted_resp_ready),
        .posted_resp_tag_o(l1d_posted_resp_tag),
        .store_resp_valid_o(l1d_store_resp_valid),
        .store_resp_ready_i(1'b1),
        .store_resp_error_o(l1d_store_resp_error),
        .prefetch_issued_o(),
        .prefetch_useful_o(),
        .prefetch_late_o(),
        .prefetch_dropped_o(),
        .prefetch_useless_o(),
        .prefetch_depth_o(),
        .speculation_barrier_i(tlbi_i),
        .store_barrier_busy_o(l1d_store_barrier_busy),
        .invalidate_valid_i(
            (ENABLE_L1D_COHERENCE_PROBES != 0) &&
            l1d_probe_valid_i),
        .invalidate_ready_o(l1d_invalidate_ready),
        .invalidate_all_i(1'b0),
        .invalidate_addr_i(l1d_probe_addr_i),
        .ccx_req_valid_o(l1d_ccx_req_valid),
        .ccx_req_ready_i(l1d_ccx_req_ready),
        .ccx_req_hart_id_o(l1d_ccx_req_hart_id),
        .ccx_req_txn_id_o(l1d_ccx_req_txn_id),
        .ccx_req_source_id_o(l1d_ccx_req_source_id),
        .ccx_req_op_o(l1d_ccx_req_op),
        .ccx_req_lock_o(l1d_ccx_req_lock),
        .ccx_req_order_o(l1d_ccx_req_order),
        .ccx_req_kind_o(l1d_ccx_req_kind),
        .ccx_req_attr_o(l1d_ccx_req_attr),
        .ccx_req_size_o(l1d_ccx_req_size),
        .ccx_req_addr_o(l1d_ccx_req_addr),
        .ccx_req_burst_len_o(l1d_ccx_req_burst_len),
        .ccx_wdata_valid_o(l1d_ccx_wdata_valid),
        .ccx_wdata_ready_i(ccx_wdata_ready_i),
        .ccx_wdata_hart_id_o(l1d_ccx_wdata_hart_id),
        .ccx_wdata_txn_id_o(l1d_ccx_wdata_txn_id),
        .ccx_wdata_source_id_o(l1d_ccx_wdata_source_id),
        .ccx_wdata_beat_index_o(l1d_ccx_wdata_beat_index),
        .ccx_wdata_last_o(l1d_ccx_wdata_last),
        .ccx_wdata_o(l1d_ccx_wdata),
        .ccx_wstrb_o(l1d_ccx_wstrb),
        .ccx_resp_valid_i(l1d_ccx_resp_valid),
        .ccx_resp_ready_o(l1d_ccx_resp_ready),
        .ccx_resp_hart_id_i(ccx_resp_hart_id_i),
        .ccx_resp_txn_id_i(ccx_resp_txn_id_i),
        .ccx_resp_source_id_i(ccx_resp_source_id_i),
        .ccx_resp_beat_index_i(ccx_resp_beat_index_i),
        .ccx_resp_last_i(ccx_resp_last_i),
        .ccx_resp_rdata_i(ccx_resp_rdata_i),
        .ccx_resp_error_i(ccx_resp_error_i),
        .ccx_resp_sc_success_i(ccx_resp_sc_success_i)
    );

    // SATP writes and SFENCE.VMA use the same conservative global barrier.
    // The PTW is invalidated immediately, but its ordered shootdown cannot
    // issue until all older posted L1D stores have completed downstream.
    assign tlbi_busy_o = l1d_store_barrier_busy || ptw_invalidate_busy;

    openrv64_l1i_ccx #(
        .ENABLE(ENABLE_L1I),
        .ADDR_WIDTH(`RV64_XLEN),
        .CACHE_BYTES(L1I_CACHE_BYTES),
        .FILL_BUFFER_LINES(L1I_FILL_BUFFER_LINES),
        .DEMAND_MSHRS(L1I_DEMAND_MSHRS),
        .REQ_TAG_WIDTH(FETCH_SLOT_WIDTH),
        .HART_ID(HART_ID)
    ) u_l1i (
        .clk_i(clk),
        .rst_ni(rst_n),
        .req_valid_i(l1i_req_valid),
        .req_ready_o(l1i_req_ready),
        .req_cacheable_i(1'b1),
        .req_tag_i(l1i_req_slot),
        .req_addr_i(l1i_req_vaddr),
        .req_phys_addr_i(l1i_req_paddr),
        .resp_valid_o(l1i_resp_valid),
        .resp_ready_i(l1i_resp_ready),
        .resp_tag_o(l1i_resp_tag),
        .req_rdata_o(l1i_req_rdata),
        .req_error_o(l1i_req_error),
        .prefetch_valid_i(icache_prefetch_valid_i),
        .prefetch_taken_addr_i(icache_prefetch_taken_addr_i),
        .prefetch_fallthrough_addr_i(
            icache_prefetch_fallthrough_addr_i),
        .prefetch_priv_i(fetch_req_priv_i),
        .prefetch_vm_mode_i(fetch_req_vm_mode_i),
        .prefetch_asid_i(fetch_req_asid_i),
        .prefetch_root_ppn_i(fetch_req_root_ppn_i),
        .prefetch_sum_i(fetch_req_sum_i),
        .prefetch_mxr_i(fetch_req_mxr_i),
        .retire_age_valid_i(icache_age_valid_i),
        .retire_age_addr_i(icache_age_addr_i),
        .prefetch_flush_i(tlbi_i || icache_invalidate_i),
        .xlate_req_valid_o(l1i_xlate_req_valid),
        .xlate_req_ready_i(l1i_xlate_req_ready),
        .xlate_req_vaddr_o(l1i_xlate_req_vaddr),
        .xlate_req_priv_o(l1i_xlate_req_priv),
        .xlate_req_vm_mode_o(l1i_xlate_req_vm_mode),
        .xlate_req_asid_o(l1i_xlate_req_asid),
        .xlate_req_root_ppn_o(l1i_xlate_req_root_ppn),
        .xlate_req_sum_o(l1i_xlate_req_sum),
        .xlate_req_mxr_o(l1i_xlate_req_mxr),
        .xlate_resp_valid_i(l1i_xlate_resp_valid),
        .xlate_resp_ready_o(l1i_xlate_resp_ready),
        .xlate_resp_paddr_i(l1i_xlate_resp_paddr),
        .xlate_resp_fault_i(l1i_xlate_resp_fault),
        .invalidate_valid_i(l1i_invalidate_valid),
        .invalidate_ready_o(l1i_invalidate_ready),
        .invalidate_all_i(1'b1),
        .invalidate_addr_i({`RV64_XLEN{1'b0}}),
        .ccx_req_valid_o(l1i_ccx_req_valid),
        .ccx_req_ready_i(l1i_ccx_req_ready),
        .ccx_req_hart_id_o(l1i_ccx_req_hart_id),
        .ccx_req_source_id_o(l1i_ccx_req_source_id),
        .ccx_req_txn_id_o(l1i_ccx_req_txn_id),
        .ccx_req_op_o(l1i_ccx_req_op),
        .ccx_req_order_o(l1i_ccx_req_order),
        .ccx_req_kind_o(l1i_ccx_req_kind),
        .ccx_req_attr_o(l1i_ccx_req_attr),
        .ccx_req_size_o(l1i_ccx_req_size),
        .ccx_req_addr_o(l1i_ccx_req_addr),
        .ccx_req_burst_len_o(l1i_ccx_req_burst_len),
        .ccx_resp_valid_i(l1i_ccx_resp_valid),
        .ccx_resp_ready_o(l1i_ccx_resp_ready),
        .ccx_resp_hart_id_i(ccx_resp_hart_id_i),
        .ccx_resp_source_id_i(ccx_resp_source_id_i),
        .ccx_resp_txn_id_i(ccx_resp_txn_id_i),
        .ccx_resp_rdata_i(ccx_resp_rdata_i),
        .ccx_resp_beat_index_i(ccx_resp_beat_index_i),
        .ccx_resp_last_i(ccx_resp_last_i),
        .ccx_resp_error_i(ccx_resp_error_i),
        .ccx_resp_sc_success_i(ccx_resp_sc_success_i)
    );

    // The hart exposes one native CCX command port.  I-cache, D-cache, and PTE
    // tags are independent, so response routing uses source_id as required by
    // the native protocol.  Command arbitration is round-robin and holds its
    // grant across downstream backpressure.
    reg ccx_cmd_grant_valid_q;
    reg [1:0] ccx_cmd_grant_client_q;
    reg [1:0] ccx_cmd_last_client_q;
    reg ccx_cmd_next_valid_r;
    reg [1:0] ccx_cmd_next_client_r;

    always @* begin
        ccx_cmd_next_valid_r = 1'b0;
        ccx_cmd_next_client_r = CCX_CLIENT_ICACHE;
        case (ccx_cmd_last_client_q)
            CCX_CLIENT_ICACHE: begin
                if (l1d_ccx_req_valid) begin
                    ccx_cmd_next_valid_r = 1'b1;
                    ccx_cmd_next_client_r = CCX_CLIENT_DCACHE;
                end else if (ptw_ccx_req_valid) begin
                    ccx_cmd_next_valid_r = 1'b1;
                    ccx_cmd_next_client_r = CCX_CLIENT_PTE;
                end else if (l1i_ccx_req_valid) begin
                    ccx_cmd_next_valid_r = 1'b1;
                    ccx_cmd_next_client_r = CCX_CLIENT_ICACHE;
                end
            end
            CCX_CLIENT_DCACHE: begin
                if (ptw_ccx_req_valid) begin
                    ccx_cmd_next_valid_r = 1'b1;
                    ccx_cmd_next_client_r = CCX_CLIENT_PTE;
                end else if (l1i_ccx_req_valid) begin
                    ccx_cmd_next_valid_r = 1'b1;
                    ccx_cmd_next_client_r = CCX_CLIENT_ICACHE;
                end else if (l1d_ccx_req_valid) begin
                    ccx_cmd_next_valid_r = 1'b1;
                    ccx_cmd_next_client_r = CCX_CLIENT_DCACHE;
                end
            end
            default: begin
                if (l1i_ccx_req_valid) begin
                    ccx_cmd_next_valid_r = 1'b1;
                    ccx_cmd_next_client_r = CCX_CLIENT_ICACHE;
                end else if (l1d_ccx_req_valid) begin
                    ccx_cmd_next_valid_r = 1'b1;
                    ccx_cmd_next_client_r = CCX_CLIENT_DCACHE;
                end else if (ptw_ccx_req_valid) begin
                    ccx_cmd_next_valid_r = 1'b1;
                    ccx_cmd_next_client_r = CCX_CLIENT_PTE;
                end
            end
        endcase
    end

    wire ccx_cmd_selected_l1d =
        ccx_cmd_grant_client_q == CCX_CLIENT_DCACHE;
    wire ccx_cmd_selected_ptw =
        ccx_cmd_grant_client_q == CCX_CLIENT_PTE;
    wire ccx_cmd_selected_valid = ccx_cmd_selected_l1d ?
        l1d_ccx_req_valid : ccx_cmd_selected_ptw ?
        ptw_ccx_req_valid : l1i_ccx_req_valid;

    assign ccx_req_valid_o = ccx_cmd_grant_valid_q &&
                             ccx_cmd_selected_valid;
    assign ccx_req_hart_id_o = ccx_cmd_selected_l1d ?
        l1d_ccx_req_hart_id : ccx_cmd_selected_ptw ?
        ptw_ccx_req_hart_id : l1i_ccx_req_hart_id;
    assign ccx_req_txn_id_o = ccx_cmd_selected_l1d ?
        l1d_ccx_req_txn_id : ccx_cmd_selected_ptw ?
        ptw_ccx_req_txn_id : l1i_ccx_req_txn_id;
    assign ccx_req_source_id_o = ccx_cmd_selected_l1d ?
        l1d_ccx_req_source_id : ccx_cmd_selected_ptw ?
        ptw_ccx_req_source_id : l1i_ccx_req_source_id;
    assign ccx_req_op_o = ccx_cmd_selected_l1d ?
        l1d_ccx_req_op : ccx_cmd_selected_ptw ?
        ptw_ccx_req_op : l1i_ccx_req_op;
    assign ccx_req_lock_o = ccx_cmd_selected_l1d ?
        l1d_ccx_req_lock : ccx_cmd_selected_ptw ?
        ptw_ccx_req_lock : 1'b0;
    assign ccx_req_order_o = ccx_cmd_selected_l1d ?
        l1d_ccx_req_order : ccx_cmd_selected_ptw ?
        ptw_ccx_req_order : l1i_ccx_req_order;
    assign ccx_req_kind_o = ccx_cmd_selected_l1d ?
        l1d_ccx_req_kind : ccx_cmd_selected_ptw ?
        ptw_ccx_req_kind : l1i_ccx_req_kind;
    assign ccx_req_attr_o = ccx_cmd_selected_l1d ?
        l1d_ccx_req_attr : ccx_cmd_selected_ptw ?
        ptw_ccx_req_attr : l1i_ccx_req_attr;
    assign ccx_req_size_o = ccx_cmd_selected_l1d ?
        l1d_ccx_req_size : ccx_cmd_selected_ptw ?
        ptw_ccx_req_size : l1i_ccx_req_size;
    assign ccx_req_addr_o = ccx_cmd_selected_l1d ?
        l1d_ccx_req_addr : ccx_cmd_selected_ptw ?
        ptw_ccx_req_addr : l1i_ccx_req_addr;
    assign ccx_req_burst_len_o = ccx_cmd_selected_l1d ?
        l1d_ccx_req_burst_len : ccx_cmd_selected_ptw ?
        ptw_ccx_req_burst_len :
        l1i_ccx_req_burst_len;
    assign l1d_ccx_req_ready = ccx_cmd_grant_valid_q &&
        ccx_cmd_selected_l1d && ccx_req_ready_i;
    assign l1i_ccx_req_ready = ccx_cmd_grant_valid_q &&
        !ccx_cmd_selected_l1d && !ccx_cmd_selected_ptw &&
        ccx_req_ready_i;
    assign ptw_ccx_req_ready = ccx_cmd_grant_valid_q &&
        ccx_cmd_selected_ptw && ccx_req_ready_i;

    assign ccx_wdata_valid_o = l1d_ccx_wdata_valid;
    assign ccx_wdata_hart_id_o = l1d_ccx_wdata_hart_id;
    assign ccx_wdata_txn_id_o = l1d_ccx_wdata_txn_id;
    assign ccx_wdata_source_id_o = l1d_ccx_wdata_source_id;
    assign ccx_wdata_beat_index_o = l1d_ccx_wdata_beat_index;
    assign ccx_wdata_last_o = l1d_ccx_wdata_last;
    assign ccx_wdata_o = l1d_ccx_wdata;
    assign ccx_wstrb_o = l1d_ccx_wstrb;

    assign ccx_resp_ready_o =
        (ccx_resp_source_id_i == `OPENRV64_CCX_SOURCE_DCACHE) ?
        l1d_ccx_resp_ready :
        (ccx_resp_source_id_i == `OPENRV64_CCX_SOURCE_ICACHE) ?
        l1i_ccx_resp_ready :
        (ccx_resp_source_id_i == `OPENRV64_CCX_SOURCE_PTW) ?
        ptw_ccx_resp_ready : 1'b0;

    wire direct_fetch_arvalid = !l1i_enabled && select_fetch_probe &&
                                pmp_allow_i;
    wire fetch_arvalid = direct_fetch_arvalid;

    assign m_axi_arvalid_o = fetch_arvalid;
    assign m_axi_arid_o =
        {{(AXI_ID_WIDTH-FETCH_SLOT_WIDTH){1'b0}},
         fetch_xlate_slot_r};
    assign m_axi_araddr_o = fetch_axi_addr;
    assign m_axi_arlen_o = 8'd0;
    assign m_axi_arsize_o = 3'd5;
    assign m_axi_arburst_o = 2'b01;
    assign m_axi_arlock_o = 1'b0;
    assign m_axi_arcache_o = 4'b1110;
    assign m_axi_arprot_o = {
        1'b1,
        1'b0,
        fetch_priv_q[fetch_xlate_slot_r] == `RV64_PRIV_U
    };
    assign m_axi_arqos_o = 4'd0;
    wire axi_ar_fire = m_axi_arvalid_o && m_axi_arready_i;
    wire fetch_ar_fire = axi_ar_fire;
    wire direct_fetch_ar_fire = fetch_ar_fire;

    wire l1d_request_fire = l1d_req_valid && l1d_req_ready;
    wire pipe_fast_request_fire = l1d_request_fire && l1d_pipe_request;
    assign lsu_pipe_req_ready_o =
        (pipe_fast_candidate &&
         (pipe_pmp_denied || (pmp_allow_i && l1d_req_ready))) ||
        pipe_fallback_candidate;

    assign m_axi_awid_o = {AXI_ID_WIDTH{1'b0}};
    assign m_axi_awaddr_o = {AXI_ADDR_WIDTH{1'b0}};
    assign m_axi_awlen_o = 8'd0;
    assign m_axi_awsize_o = 3'd0;
    assign m_axi_awburst_o = 2'b01;
    assign m_axi_awlock_o = 1'b0;
    assign m_axi_awcache_o = 4'b0000;
    assign m_axi_awprot_o = 3'b000;
    assign m_axi_awqos_o = 4'd0;
    assign m_axi_awvalid_o = 1'b0;
    assign m_axi_wdata_o = {AXI_DATA_WIDTH{1'b0}};
    assign m_axi_wstrb_o = {AXI_BYTES{1'b0}};
    assign m_axi_wlast_o = 1'b1;
    assign m_axi_wvalid_o = 1'b0;

    assign m_axi_bready_o = 1'b0;

    wire r_is_fetch = (m_axi_rid_i < FETCH_OUTSTANDING);
    wire [FETCH_SLOT_WIDTH-1:0] r_fetch_slot =
        m_axi_rid_i[FETCH_SLOT_WIDTH-1:0];
    assign m_axi_rready_o = r_is_fetch && !l1i_enabled &&
        (fetch_state_q[r_fetch_slot] == FETCH_WAIT_R);
    wire axi_r_fire = m_axi_rvalid_i && m_axi_rready_o;
    assign axi_r_error = m_axi_rresp_i[1] || !m_axi_rlast_i;

    wire pipe_fallback_visible = pipe_fallback_active_q &&
        !pipe_fallback_cancelled_q && (lsu_state_q == LSU_RESP);
    wire pipe_l1d_inflight = l1d_resp_is_pipe &&
        pipe_inflight_q[l1d_resp_pipe_tag];
    wire pipe_l1d_cancelled = pipe_l1d_inflight &&
        pipe_cancelled_q[l1d_resp_pipe_tag];
    wire pipe_l1d_visible = l1d_resp_valid && l1d_resp_is_pipe &&
        pipe_l1d_inflight && !pipe_l1d_cancelled &&
        !pipe_local_resp_valid_q && !pipe_fallback_visible;
    assign l1d_resp_ready = l1d_resp_is_pipe ?
        (!pipe_l1d_inflight || pipe_l1d_cancelled ||
         (!pipe_local_resp_valid_q && !pipe_fallback_visible &&
          lsu_pipe_resp_ready_i)) :
        (lsu_state_q == LSU_WAIT);
    assign lsu_pipe_resp_valid_o = pipe_local_resp_valid_q ||
                                   pipe_l1d_visible ||
                                   pipe_fallback_visible;
    assign lsu_pipe_resp_tag_o = pipe_local_resp_valid_q ?
        pipe_local_resp_tag_q : pipe_l1d_visible ?
        l1d_resp_pipe_tag : pipe_fallback_tag_q;
    assign lsu_pipe_resp_paddr_o = pipe_local_resp_valid_q ?
        pipe_local_resp_paddr_q : pipe_fallback_visible ?
        lsu_paddr_q : {`RV64_XLEN{1'b0}};
    assign lsu_pipe_resp_rdata_o = pipe_l1d_visible ? l1d_req_rdata :
        pipe_fallback_visible ? lsu_rdata_q : {`RV64_XLEN{1'b0}};
    assign lsu_pipe_resp_access_fault_o = pipe_local_resp_valid_q ?
        pipe_local_resp_access_fault_q :
        pipe_l1d_visible ? l1d_req_error :
        (pipe_fallback_visible && lsu_access_fault_q);
    assign lsu_pipe_resp_page_fault_o =
        pipe_local_resp_valid_q ? pipe_local_resp_page_fault_q :
        (pipe_fallback_visible && lsu_page_fault_q);

    wire pipe_store_done_inflight = l1d_posted_resp_is_pipe &&
        pipe_inflight_q[l1d_posted_resp_pipe_tag] &&
        pipe_write_q[l1d_posted_resp_pipe_tag];
    wire fallback_store_done_inflight =
        !l1d_posted_resp_is_pipe && pipe_fallback_active_q &&
        lsu_write_q && (lsu_state_q == LSU_WAIT) &&
        (l1d_posted_resp_pipe_tag == pipe_fallback_tag_q);
    assign lsu_pipe_store_done_valid_o = l1d_posted_resp_valid &&
        (pipe_store_done_inflight || fallback_store_done_inflight);
    assign lsu_pipe_store_done_tag_o = l1d_posted_resp_pipe_tag;
    assign l1d_posted_resp_ready =
        (pipe_store_done_inflight || fallback_store_done_inflight) ?
            lsu_pipe_store_done_ready_i : 1'b1;
    wire l1d_posted_resp_fire =
        l1d_posted_resp_valid && l1d_posted_resp_ready;

    wire xlate_fallback_visible =
        !xlate_local_resp_valid_q && xlate_fallback_response_pending;
    wire xlate_fast_resp_visible =
        !xlate_local_resp_valid_q &&
        !xlate_fallback_response_pending &&
        xlate_fast_candidate;
    wire xlate_fallback_response_fire =
        xlate_fallback_visible && lsu_xlate_resp_ready_i;
    wire xlate_fast_response_fire =
        xlate_fast_resp_visible && lsu_xlate_resp_ready_i;
    assign lsu_xlate_resp_valid_o = xlate_local_resp_valid_q ||
                                    xlate_fallback_visible ||
                                    xlate_fast_resp_visible;
    assign lsu_xlate_resp_tag_o = xlate_local_resp_valid_q ?
        xlate_local_resp_tag_q : xlate_fallback_visible ?
        xlate_fallback_tag_q : lsu_xlate_req_tag_i;
    assign lsu_xlate_resp_paddr_o = xlate_local_resp_valid_q ?
        xlate_local_resp_paddr_q : xlate_fallback_visible ?
        lsu_paddr_q : xlate_lookup_paddr;
    assign lsu_xlate_resp_access_fault_o =
        xlate_fallback_visible && lsu_access_fault_q;
    assign lsu_xlate_resp_page_fault_o = xlate_local_resp_valid_q ?
        xlate_local_resp_page_fault_q :
        xlate_fallback_visible ? lsu_page_fault_q :
        (xlate_fast_resp_visible && xlate_lookup_page_fault);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            l1i_req_active_q <= 1'b0;
            l1i_req_vaddr_q <= {`RV64_XLEN{1'b0}};
            l1i_req_paddr_q <= {`RV64_XLEN{1'b0}};
            l1i_req_slot_q <= {FETCH_SLOT_WIDTH{1'b0}};
            l1i_invalidate_pending_q <= 1'b0;
        end else begin
            if (fetch_l1i_launch && !l1i_req_fire) begin
                l1i_req_active_q <= 1'b1;
                l1i_req_vaddr_q <= fetch_lookup_vaddr;
                l1i_req_paddr_q <= fetch_axi_addr;
                l1i_req_slot_q <= fetch_xlate_slot_r;
            end
            if (l1i_req_fire)
                l1i_req_active_q <= 1'b0;

            if (icache_invalidate_i)
                l1i_invalidate_pending_q <= 1'b1;
            if (l1i_invalidate_valid && l1i_invalidate_ready)
                l1i_invalidate_pending_q <= 1'b0;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            prefetch_xlate_state_q <= PREFETCH_XLATE_IDLE;
            prefetch_xlate_vaddr_q <= {`RV64_XLEN{1'b0}};
            prefetch_xlate_paddr_q <= {`RV64_XLEN{1'b0}};
            prefetch_xlate_priv_q <= `RV64_PRIV_M;
            prefetch_xlate_vm_mode_q <= `RV64_SATP_MODE_BARE;
            prefetch_xlate_asid_q <=
                {`RV64_SATP_ASID_WIDTH{1'b0}};
            prefetch_xlate_root_ppn_q <=
                {`RV64_SATP_PPN_WIDTH{1'b0}};
            prefetch_xlate_sum_q <= 1'b0;
            prefetch_xlate_mxr_q <= 1'b0;
            prefetch_xlate_fault_q <= 1'b0;
        end else begin
            case (prefetch_xlate_state_q)
                PREFETCH_XLATE_IDLE: begin
                    if (l1i_xlate_req_valid && l1i_xlate_req_ready) begin
                        prefetch_xlate_vaddr_q <= l1i_xlate_req_vaddr;
                        prefetch_xlate_priv_q <= l1i_xlate_req_priv;
                        prefetch_xlate_vm_mode_q <=
                            l1i_xlate_req_vm_mode;
                        prefetch_xlate_asid_q <= l1i_xlate_req_asid;
                        prefetch_xlate_root_ppn_q <=
                            l1i_xlate_req_root_ppn;
                        prefetch_xlate_sum_q <= l1i_xlate_req_sum;
                        prefetch_xlate_mxr_q <= l1i_xlate_req_mxr;
                        prefetch_xlate_fault_q <= 1'b0;
                        prefetch_xlate_state_q <= PREFETCH_XLATE_LOOKUP;
                    end
                end

                PREFETCH_XLATE_LOOKUP: begin
                    if (prefetch_xlate_bare) begin
                        prefetch_xlate_paddr_q <= prefetch_xlate_vaddr_q;
                        prefetch_xlate_state_q <= PREFETCH_XLATE_PMP;
                    end else if (prefetch_xlate_lookup && itlb_lookup_hit) begin
                        if (itlb_lookup_page_fault) begin
                            prefetch_xlate_fault_q <= 1'b1;
                            prefetch_xlate_state_q <= PREFETCH_XLATE_RESP;
                        end else begin
                            prefetch_xlate_paddr_q <= itlb_lookup_paddr;
                            prefetch_xlate_state_q <= PREFETCH_XLATE_PMP;
                        end
                    end else if (start_prefetch_walk) begin
                        prefetch_xlate_state_q <= PREFETCH_XLATE_MISS;
                    end
                end

                PREFETCH_XLATE_MISS: begin
                    if (ptw_resp_valid && miss_active_q &&
                        (miss_owner_q == OWNER_PREFETCH)) begin
                        if (miss_invalidated_q || ptw_resp_invalidated ||
                            tlbi_i) begin
                            prefetch_xlate_state_q <=
                                PREFETCH_XLATE_LOOKUP;
                        end else if (ptw_resp_page_fault ||
                                     ptw_resp_access_fault) begin
                            prefetch_xlate_fault_q <= 1'b1;
                            prefetch_xlate_state_q <= PREFETCH_XLATE_RESP;
                        end else begin
                            prefetch_xlate_paddr_q <= ptw_resp_paddr;
                            prefetch_xlate_state_q <= PREFETCH_XLATE_PMP;
                        end
                    end
                end

                PREFETCH_XLATE_PMP: begin
                    if (prefetch_pmp_complete) begin
                        prefetch_xlate_fault_q <= !pmp_allow_i;
                        prefetch_xlate_state_q <= PREFETCH_XLATE_RESP;
                    end
                end

                PREFETCH_XLATE_RESP: begin
                    if (l1i_xlate_resp_valid && l1i_xlate_resp_ready)
                        prefetch_xlate_state_q <= PREFETCH_XLATE_IDLE;
                end

                default:
                    prefetch_xlate_state_q <= PREFETCH_XLATE_IDLE;
            endcase
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ccx_cmd_grant_valid_q <= 1'b0;
            ccx_cmd_grant_client_q <= CCX_CLIENT_ICACHE;
            ccx_cmd_last_client_q <= CCX_CLIENT_PTE;
        end else begin
            if (ccx_cmd_grant_valid_q) begin
                if (ccx_req_valid_o && ccx_req_ready_i) begin
                    ccx_cmd_grant_valid_q <= 1'b0;
                    ccx_cmd_last_client_q <=
                        ccx_cmd_grant_client_q;
                end
            end else if (ccx_cmd_next_valid_r) begin
                ccx_cmd_grant_valid_q <= 1'b1;
                ccx_cmd_grant_client_q <= ccx_cmd_next_client_r;
            end
        end
    end

    integer fetch_index;
    integer fetch_age_port;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fetch_head_q <= {FETCH_SLOT_WIDTH{1'b0}};
            fetch_tail_q <= {FETCH_SLOT_WIDTH{1'b0}};
            fetch_count_q <= {FETCH_COUNT_WIDTH{1'b0}};
            fetch_resp_hold_valid_q <= 1'b0;
            fetch_resp_hold_slot_q <= {FETCH_SLOT_WIDTH{1'b0}};
            for (fetch_index = 0; fetch_index < FETCH_OUTSTANDING;
                 fetch_index = fetch_index + 1) begin
                fetch_state_q[fetch_index] <= FETCH_EMPTY;
                fetch_vaddr_q[fetch_index] <= {`RV64_XLEN{1'b0}};
                fetch_priv_q[fetch_index] <= `RV64_PRIV_M;
                fetch_vm_mode_q[fetch_index] <= `RV64_SATP_MODE_BARE;
                fetch_asid_q[fetch_index] <=
                    {`RV64_SATP_ASID_WIDTH{1'b0}};
                fetch_root_ppn_q[fetch_index] <=
                    {`RV64_SATP_PPN_WIDTH{1'b0}};
                fetch_sum_q[fetch_index] <= 1'b0;
                fetch_mxr_q[fetch_index] <= 1'b0;
                fetch_stash_q[fetch_index] <= 1'b0;
                fetch_demand_q[fetch_index] <= 1'b0;
                fetch_cancelled_q[fetch_index] <= 1'b0;
                fetch_data_q[fetch_index] <= {AXI_DATA_WIDTH{1'b0}};
                fetch_access_fault_q[fetch_index] <= 1'b0;
                fetch_page_fault_q[fetch_index] <= 1'b0;
            end
        end else begin
            if (!fetch_resp_hold_valid_q && fetch_resp_valid_o &&
                !fetch_resp_ready_i) begin
                fetch_resp_hold_valid_q <= 1'b1;
                fetch_resp_hold_slot_q <= fetch_complete_slot_r;
            end
            if (fetch_resp_fire)
                fetch_resp_hold_valid_q <= 1'b0;

            case ({fetch_accept, fetch_pop})
                2'b10: fetch_count_q <= fetch_count_q + 1'b1;
                2'b01: fetch_count_q <= fetch_count_q - 1'b1;
                default: begin
                end
            endcase
            if (fetch_accept) begin
                fetch_state_q[fetch_free_slot_r] <= FETCH_TRANSLATE;
                fetch_vaddr_q[fetch_free_slot_r] <= {
                    fetch_req_addr_i[`RV64_XLEN-1:AXI_BYTE_BITS],
                    {AXI_BYTE_BITS{1'b0}}
                };
                fetch_priv_q[fetch_free_slot_r] <= fetch_req_priv_i;
                fetch_vm_mode_q[fetch_free_slot_r] <= fetch_req_vm_mode_i;
                fetch_asid_q[fetch_free_slot_r] <= fetch_req_asid_i;
                fetch_root_ppn_q[fetch_free_slot_r] <=
                    fetch_req_root_ppn_i;
                fetch_sum_q[fetch_free_slot_r] <= fetch_req_sum_i;
                fetch_mxr_q[fetch_free_slot_r] <= fetch_req_mxr_i;
                fetch_stash_q[fetch_free_slot_r] <= fetch_req_stash_i;
                fetch_demand_q[fetch_free_slot_r] <= fetch_req_demand_i;
                fetch_cancelled_q[fetch_free_slot_r] <= 1'b0;
                fetch_data_q[fetch_free_slot_r] <=
                    {AXI_DATA_WIDTH{1'b0}};
                fetch_access_fault_q[fetch_free_slot_r] <= 1'b0;
                fetch_page_fault_q[fetch_free_slot_r] <= 1'b0;
                fetch_tail_q <= fetch_free_slot_r + 1'b1;
            end
            if (fetch_pop) begin
                fetch_state_q[fetch_pop_slot] <= FETCH_EMPTY;
                fetch_stash_q[fetch_pop_slot] <= 1'b0;
                fetch_demand_q[fetch_pop_slot] <= 1'b0;
                fetch_cancelled_q[fetch_pop_slot] <= 1'b0;
                fetch_head_q <= fetch_pop_slot + 1'b1;
            end

            if (fetch_cancel_i) begin
                for (fetch_index = 0; fetch_index < FETCH_OUTSTANDING;
                     fetch_index = fetch_index + 1) begin
                    if ((fetch_state_q[fetch_index] != FETCH_EMPTY) &&
                        (!fetch_stash_q[fetch_index] ||
                         fetch_cancel_stash_i)) begin
                        fetch_cancelled_q[fetch_index] <= 1'b1;
                        if (fetch_state_q[fetch_index] == FETCH_TRANSLATE)
                            fetch_state_q[fetch_index] <= FETCH_COMPLETE;
                    end else if (fetch_state_q[fetch_index] !=
                                 FETCH_EMPTY) begin
                        // A redirect preserves qualified work only for the
                        // stash.  It must no longer complete the abandoned
                        // architectural demand after fetch restarts.
                        fetch_demand_q[fetch_index] <= 1'b0;
                    end
                end
            end
            for (fetch_age_port = 0; fetch_age_port < 3;
                 fetch_age_port = fetch_age_port + 1) begin
                if (icache_age_valid_i[fetch_age_port]) begin
                    for (fetch_index = 0;
                         fetch_index < FETCH_OUTSTANDING;
                         fetch_index = fetch_index + 1) begin
                        if ((fetch_state_q[fetch_index] != FETCH_EMPTY) &&
                            fetch_stash_q[fetch_index] &&
                            !fetch_demand_q[fetch_index] &&
                            (fetch_vaddr_q[fetch_index][`RV64_XLEN-1:6] ==
                             icache_age_addr_i[
                                fetch_age_port*`RV64_XLEN +
                                6 +: `RV64_XLEN-6])) begin
                            fetch_cancelled_q[fetch_index] <= 1'b1;
                            if (fetch_state_q[fetch_index] ==
                                FETCH_TRANSLATE)
                                fetch_state_q[fetch_index] <=
                                    FETCH_COMPLETE;
                        end
                    end
                end
            end

            if (fetch_xlate_found_r && fetch_lookup_ready &&
                itlb_lookup_page_fault) begin
                fetch_state_q[fetch_xlate_slot_r] <= FETCH_COMPLETE;
                fetch_page_fault_q[fetch_xlate_slot_r] <= 1'b1;
            end else if (fetch_pmp_denied) begin
                fetch_state_q[fetch_xlate_slot_r] <= FETCH_COMPLETE;
                fetch_access_fault_q[fetch_xlate_slot_r] <= 1'b1;
            end else if (fetch_l1i_launch) begin
                fetch_state_q[fetch_xlate_slot_r] <= FETCH_WAIT_L1I;
            end else if (direct_fetch_ar_fire) begin
                fetch_state_q[fetch_xlate_slot_r] <= FETCH_WAIT_R;
            end

            if (start_fetch_walk)
                fetch_state_q[fetch_xlate_slot_r] <= FETCH_MISS;
            if (ptw_resp_valid && miss_active_q &&
                (miss_owner_q == OWNER_FETCH)) begin
                if (fetch_cancelled_q[miss_fetch_slot_q] ||
                    fetch_miss_cancel_now) begin
                    fetch_state_q[miss_fetch_slot_q] <= FETCH_COMPLETE;
                end else if (miss_invalidated_q ||
                             ptw_resp_invalidated || tlbi_i) begin
                    fetch_state_q[miss_fetch_slot_q] <= FETCH_TRANSLATE;
                end else if (ptw_resp_page_fault ||
                             ptw_resp_access_fault) begin
                    fetch_state_q[miss_fetch_slot_q] <= FETCH_COMPLETE;
                    fetch_page_fault_q[miss_fetch_slot_q] <=
                        ptw_resp_page_fault;
                    fetch_access_fault_q[miss_fetch_slot_q] <=
                        ptw_resp_access_fault;
                end else begin
                    fetch_state_q[miss_fetch_slot_q] <= FETCH_TRANSLATE;
                end
            end

            if (!l1i_enabled && axi_r_fire && r_is_fetch) begin
                fetch_state_q[r_fetch_slot] <= FETCH_COMPLETE;
                fetch_data_q[r_fetch_slot] <= m_axi_rdata_i;
                fetch_access_fault_q[r_fetch_slot] <= axi_r_error;
                fetch_page_fault_q[r_fetch_slot] <= 1'b0;
            end
            if (l1i_enabled && l1i_resp_fire) begin
                fetch_state_q[l1i_resp_slot] <= FETCH_COMPLETE;
                fetch_data_q[l1i_resp_slot] <= l1i_req_rdata;
                fetch_access_fault_q[l1i_resp_slot] <= l1i_req_error;
                fetch_page_fault_q[l1i_resp_slot] <= 1'b0;
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lsu_state_q <= LSU_IDLE;
            lsu_lock_q <= 1'b0;
            lsu_write_q <= 1'b0;
            lsu_xlate_only_q <= 1'b0;
            lsu_physical_q <= 1'b0;
            lsu_vaddr_q <= {`RV64_XLEN{1'b0}};
            lsu_paddr_q <= {`RV64_XLEN{1'b0}};
            lsu_wdata_q <= {`RV64_XLEN{1'b0}};
            lsu_wstrb_q <= 8'd0;
            lsu_size_q <= 3'd0;
            lsu_priv_q <= `RV64_PRIV_M;
            lsu_vm_mode_q <= `RV64_SATP_MODE_BARE;
            lsu_asid_q <= {`RV64_SATP_ASID_WIDTH{1'b0}};
            lsu_root_ppn_q <= {`RV64_SATP_PPN_WIDTH{1'b0}};
            lsu_sum_q <= 1'b0;
            lsu_mxr_q <= 1'b0;
            lsu_rdata_q <= {`RV64_XLEN{1'b0}};
            lsu_access_fault_q <= 1'b0;
            lsu_page_fault_q <= 1'b0;
            pipe_fallback_active_q <= 1'b0;
            pipe_fallback_cancelled_q <= 1'b0;
            pipe_fallback_tag_q <=
                {`OPENRV64_LSU_TAG_WIDTH{1'b0}};
            pipe_local_resp_valid_q <= 1'b0;
            pipe_local_resp_tag_q <=
                {`OPENRV64_LSU_TAG_WIDTH{1'b0}};
            pipe_local_resp_paddr_q <= {`RV64_XLEN{1'b0}};
            pipe_local_resp_access_fault_q <= 1'b0;
            pipe_local_resp_page_fault_q <= 1'b0;
            xlate_local_resp_valid_q <= 1'b0;
            xlate_local_resp_tag_q <=
                {`OPENRV64_LSU_TAG_WIDTH{1'b0}};
            xlate_local_resp_paddr_q <= {`RV64_XLEN{1'b0}};
            xlate_local_resp_page_fault_q <= 1'b0;
            xlate_fallback_active_q <= 1'b0;
            xlate_fallback_tag_q <=
                {`OPENRV64_LSU_TAG_WIDTH{1'b0}};
            for (pipe_index = 0;
                 pipe_index < `OPENRV64_LSU_OUTSTANDING;
                 pipe_index = pipe_index + 1) begin
                pipe_inflight_q[pipe_index] <= 1'b0;
                pipe_cancelled_q[pipe_index] <= 1'b0;
                pipe_write_q[pipe_index] <= 1'b0;
            end
        end else begin
            // A translated posted store is equally irrevocable once the
            // tagged request has been accepted.  Preserve its translation,
            // physical write, and eventual error response across redirects.
            // A marked AMO phase is irrevocable after this slot accepts it.
            // Dropping its read response would prevent the MEM lane from
            // issuing the matching write phase.
            if (lsu_pipe_cancel_i && pipe_fallback_active_q &&
                (!lsu_write_q || lsu_xlate_only_q) && !lsu_lock_q)
                pipe_fallback_cancelled_q <= 1'b1;

            if (lsu_pipe_cancel_i) begin
                pipe_local_resp_valid_q <= 1'b0;
                for (pipe_index = 0;
                     pipe_index < `OPENRV64_LSU_OUTSTANDING;
                     pipe_index = pipe_index + 1)
                    if (pipe_inflight_q[pipe_index] &&
                        !pipe_write_q[pipe_index])
                        pipe_cancelled_q[pipe_index] <= 1'b1;
            end

            if (pipe_fast_candidate && pipe_pmp_denied &&
                lsu_pipe_req_ready_o) begin
                pipe_local_resp_valid_q <= 1'b1;
                pipe_local_resp_tag_q <= lsu_pipe_req_tag_i;
                pipe_local_resp_paddr_q <= pipe_req_paddr;
                pipe_local_resp_access_fault_q <= 1'b1;
                pipe_local_resp_page_fault_q <= 1'b0;
            end else if (pipe_local_resp_valid_q &&
                         lsu_pipe_resp_ready_i) begin
                pipe_local_resp_valid_q <= 1'b0;
            end

            if (xlate_fast_candidate && lsu_xlate_req_ready_o &&
                !xlate_fast_response_fire) begin
                xlate_local_resp_valid_q <= 1'b1;
                xlate_local_resp_tag_q <= lsu_xlate_req_tag_i;
                xlate_local_resp_paddr_q <= xlate_lookup_paddr;
                xlate_local_resp_page_fault_q <=
                    xlate_lookup_page_fault;
            end else if (xlate_local_resp_valid_q &&
                         lsu_xlate_resp_ready_i) begin
                xlate_local_resp_valid_q <= 1'b0;
            end

            if (pipe_fast_request_fire) begin
                pipe_inflight_q[lsu_pipe_req_tag_i] <= 1'b1;
                pipe_cancelled_q[lsu_pipe_req_tag_i] <= 1'b0;
                pipe_write_q[lsu_pipe_req_tag_i] <=
                    lsu_pipe_req_write_i;
            end

            if (l1d_resp_valid && l1d_resp_ready &&
                l1d_resp_is_pipe && pipe_l1d_inflight) begin
                pipe_inflight_q[l1d_resp_pipe_tag] <= 1'b0;
                pipe_cancelled_q[l1d_resp_pipe_tag] <= 1'b0;
                pipe_write_q[l1d_resp_pipe_tag] <= 1'b0;
            end
            if (l1d_posted_resp_fire && pipe_store_done_inflight) begin
                pipe_inflight_q[l1d_posted_resp_pipe_tag] <= 1'b0;
                pipe_cancelled_q[l1d_posted_resp_pipe_tag] <= 1'b0;
                pipe_write_q[l1d_posted_resp_pipe_tag] <= 1'b0;
            end

            case (lsu_state_q)
                LSU_IDLE: begin
                    if (lsu_valid_i || pipe_fallback_candidate ||
                        xlate_fallback_candidate) begin
                        lsu_lock_q <= pipe_fallback_candidate ?
                            lsu_pipe_req_lock_i : 1'b0;
                        lsu_write_q <= xlate_fallback_candidate ?
                            lsu_xlate_req_write_i :
                            pipe_fallback_candidate ?
                            lsu_pipe_req_write_i : lsu_write_i;
                        lsu_xlate_only_q <= xlate_fallback_candidate ||
                            (pipe_fallback_candidate &&
                             lsu_pipe_req_xlate_only_i);
                        lsu_physical_q <= pipe_fallback_candidate ?
                            lsu_pipe_req_physical_i : 1'b0;
                        lsu_vaddr_q <= xlate_fallback_candidate ?
                            lsu_xlate_req_vaddr_i :
                            pipe_fallback_candidate ?
                            lsu_pipe_req_addr_i : lsu_addr_i;
                        lsu_wdata_q <= pipe_fallback_candidate ?
                            lsu_pipe_req_wdata_i : lsu_wdata_i;
                        lsu_wstrb_q <= pipe_fallback_candidate ?
                            lsu_pipe_req_wstrb_i : lsu_wstrb_i;
                        lsu_size_q <= pipe_fallback_candidate ?
                            lsu_pipe_req_size_i : lsu_size_i;
                        lsu_priv_q <= xlate_fallback_candidate ?
                            lsu_xlate_req_priv_i :
                            pipe_fallback_candidate ?
                            lsu_pipe_req_priv_i : lsu_priv_i;
                        lsu_vm_mode_q <= xlate_fallback_candidate ?
                            lsu_xlate_req_vm_mode_i :
                            pipe_fallback_candidate ?
                            lsu_pipe_req_vm_mode_i : lsu_vm_mode_i;
                        lsu_asid_q <= xlate_fallback_candidate ?
                            lsu_xlate_req_asid_i :
                            pipe_fallback_candidate ?
                            lsu_pipe_req_asid_i : lsu_asid_i;
                        lsu_root_ppn_q <= xlate_fallback_candidate ?
                            lsu_xlate_req_root_ppn_i :
                            pipe_fallback_candidate ?
                            lsu_pipe_req_root_ppn_i : lsu_root_ppn_i;
                        lsu_sum_q <= xlate_fallback_candidate ?
                            lsu_xlate_req_sum_i :
                            pipe_fallback_candidate ?
                            lsu_pipe_req_sum_i : lsu_sum_i;
                        lsu_mxr_q <= xlate_fallback_candidate ?
                            lsu_xlate_req_mxr_i :
                            pipe_fallback_candidate ?
                            lsu_pipe_req_mxr_i : lsu_mxr_i;
                        lsu_rdata_q <= {`RV64_XLEN{1'b0}};
                        lsu_access_fault_q <= 1'b0;
                        lsu_page_fault_q <= 1'b0;
                        if (pipe_fallback_candidate) begin
                            pipe_fallback_active_q <= 1'b1;
                            pipe_fallback_cancelled_q <= 1'b0;
                            pipe_fallback_tag_q <= lsu_pipe_req_tag_i;
                        end
                        if (xlate_fallback_candidate) begin
                            xlate_fallback_active_q <= 1'b1;
                            xlate_fallback_tag_q <= lsu_xlate_req_tag_i;
                        end
                        lsu_state_q <= LSU_TRANSLATE;
                    end
                end

                LSU_TRANSLATE: begin
                    if (lsu_xlate_bare) begin
                        lsu_paddr_q <= lsu_vaddr_q;
                        lsu_state_q <= xlate_fallback_active_q ?
                            LSU_RESP : LSU_ACCESS;
                    end else if (dtlb_lookup_hit) begin
                        if (dtlb_lookup_page_fault) begin
                            lsu_page_fault_q <= 1'b1;
                            lsu_state_q <= LSU_RESP;
                        end else begin
                            lsu_paddr_q <= dtlb_lookup_paddr;
                            lsu_state_q <= xlate_fallback_active_q ?
                                LSU_RESP : LSU_ACCESS;
                        end
                    end else if (start_lsu_walk) begin
                        lsu_state_q <= LSU_MISS;
                    end
                end

                LSU_MISS: begin
                    if (ptw_resp_valid && miss_active_q &&
                        (miss_owner_q == OWNER_LSU)) begin
                        if (miss_invalidated_q || ptw_resp_invalidated ||
                            tlbi_i) begin
                            lsu_state_q <= LSU_TRANSLATE;
                        end else if (ptw_resp_page_fault ||
                                     ptw_resp_access_fault) begin
                            lsu_page_fault_q <= ptw_resp_page_fault;
                            lsu_access_fault_q <= ptw_resp_access_fault;
                            lsu_state_q <= LSU_RESP;
                        end else begin
                            lsu_state_q <= LSU_TRANSLATE;
                        end
                    end
                end

                LSU_ACCESS: begin
                    if (lsu_pmp_denied) begin
                        lsu_access_fault_q <= 1'b1;
                        lsu_state_q <= LSU_RESP;
                    end else if (lsu_xlate_only_q &&
                                 select_lsu_probe) begin
                        lsu_state_q <= LSU_RESP;
                    end else if (l1d_request_fire &&
                                 l1d_serial_request) begin
                        lsu_state_q <= LSU_WAIT;
                    end
                end

                LSU_WAIT: begin
                    if (l1d_posted_resp_fire &&
                        fallback_store_done_inflight) begin
                        lsu_state_q <= LSU_IDLE;
                        pipe_fallback_active_q <= 1'b0;
                        pipe_fallback_cancelled_q <= 1'b0;
                    end else if (l1d_resp_valid && l1d_resp_ready &&
                        !l1d_resp_is_pipe) begin
                        lsu_rdata_q <= l1d_req_rdata;
                        lsu_access_fault_q <= l1d_req_error;
                        lsu_state_q <= LSU_RESP;
                    end
                end

                LSU_RESP: begin
                    if ((xlate_fallback_active_q &&
                         xlate_fallback_response_fire) ||
                        (!xlate_fallback_active_q &&
                         (!pipe_fallback_active_q ||
                          pipe_fallback_cancelled_q ||
                          lsu_pipe_resp_ready_i))) begin
                        lsu_state_q <= LSU_IDLE;
                        pipe_fallback_active_q <= 1'b0;
                        pipe_fallback_cancelled_q <= 1'b0;
                        xlate_fallback_active_q <= 1'b0;
                    end
                end

                default: lsu_state_q <= LSU_IDLE;
            endcase
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            miss_active_q <= 1'b0;
            miss_owner_q <= OWNER_FETCH;
            miss_fetch_slot_q <= {FETCH_SLOT_WIDTH{1'b0}};
            miss_invalidated_q <= 1'b0;
        end else begin
            if (ptw_req_valid && ptw_req_ready) begin
                miss_active_q <= 1'b1;
                miss_owner_q <= ptw_req_owner;
                if (start_fetch_walk)
                    miss_fetch_slot_q <= fetch_xlate_slot_r;
                miss_invalidated_q <= 1'b0;
            end
            if (tlbi_i && miss_active_q)
                miss_invalidated_q <= 1'b1;
            if (ptw_resp_valid) begin
                miss_active_q <= 1'b0;
                miss_invalidated_q <= 1'b0;
            end
        end
    end

`ifndef SYNTHESIS
    integer fetch_assert_index;
    initial begin
        if (AXI_DATA_WIDTH != 256)
            $fatal(1, "openrv64_core_ccx_bus currently requires 256-bit AXI");
        if ((FETCH_OUTSTANDING < 2) ||
            ((1 << FETCH_SLOT_WIDTH) != FETCH_OUTSTANDING))
            $fatal(1, "FETCH_OUTSTANDING must be a power of two >= 2");
        if (AXI_ID_WIDTH < FETCH_SLOT_WIDTH)
            $fatal(1, "AXI ID width cannot encode every fetch slot");
    end

    always @(posedge clk) begin
        if (rst_n) begin
            for (fetch_assert_index = 0;
                 fetch_assert_index < FETCH_OUTSTANDING;
                 fetch_assert_index = fetch_assert_index + 1) begin
                if (fetch_cancelled_q[fetch_assert_index] &&
                    (fetch_state_q[fetch_assert_index] ==
                     FETCH_TRANSLATE))
                    $fatal(1,
                        "cancelled fetch slot re-entered translation slot=%0d addr=%016x",
                        fetch_assert_index,
                        fetch_vaddr_q[fetch_assert_index]);
            end
        end
        if (rst_n && !l1i_enabled && axi_r_fire && r_is_fetch &&
            (fetch_state_q[r_fetch_slot] != FETCH_WAIT_R))
            $fatal(1, "AXI fetch response arrived without a pending request");
        if (rst_n && l1i_resp_fire &&
            (fetch_state_q[l1i_resp_slot] != FETCH_WAIT_L1I))
            $fatal(1, "L1I response does not name an outstanding fetch");
        if (rst_n && l1d_request_fire && l1d_serial_request &&
            l1d_serial_tag_busy)
            $fatal(1, "L1D serial request reused an active global LSU tag");
    end
`endif

endmodule
