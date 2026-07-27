`timescale 1ns/1ps
`include "core/backend/backend-defs.v"
`include "core/isa/rv64-i.v"
`include "core/isa/rv64-priv.v"
`include "core/fetch/fetch-defs.v"
`include "core/bus/bus-defs.v"
`include "core/decode/defs/alu-defs.v"
`include "core/decode/defs/lsu-defs.v"
`include "core/decode/defs/br-defs.v"
`include "core/exec/bp/defs.v"
`include "core/except/except-defs.v"
`include "core/trace/trace-defs.v"
`include "core/cmu/defs.v"
`include "complex/protocol/defs.v"

// Selectable two-wide generic or three-wide AXI frontend plus EX0/EX1/MEM.
module openrv64_rv64_top_3p #(
    parameter [63:0] RESET_VECTOR = 64'h0000_0000_0000_0000,
    parameter [`OPENRV64_BUS_CONFIG_WIDTH-1:0] BUS_CONFIG =
        `OPENRV64_BUS_GEN,
    parameter ENABLE_RV64M = 0,
    parameter integer HPM_COUNTERS = 8,
    parameter integer RETIRE_DEPTH = 16,
    parameter integer PHYS_REG_COUNT = `OPENRV64_PHYS_REG_COUNT,
    parameter integer PHYS_REG_ADDR_WIDTH =
        (PHYS_REG_COUNT < 1) ? 1 : $clog2(PHYS_REG_COUNT + 1),
    parameter [2:0] COMPLETION_FORWARD_MASK = 3'b000,
    parameter [2:0] BRANCH_COMPLETION_FORWARD_MASK = 3'b001,
    parameter ENABLE_FULL_FORWARDING = 0,
    parameter RELAX_WAW = 1,
    parameter RELAX_HAZARDS = 0,
    parameter FREE_BRANCHES = 0,
    parameter ENABLE_EQ_BRANCH_PAIRING = 1,
    parameter ENABLE_ISSUE_WINDOW = 0,
    parameter ENABLE_SPECULATION_WINDOW = 0,
    parameter ENABLE_POSTED_STORES = 1,
    parameter integer STORE_QUEUE_DEPTH = 4,
    parameter [`RV64_XLEN-1:0] STORE_FORWARD_BASE = {`RV64_XLEN{1'b0}},
    parameter [`RV64_XLEN-1:0] STORE_FORWARD_SIZE = {`RV64_XLEN{1'b0}},
    parameter [`RV64_XLEN-1:0] SPEC_LOAD_BASE = {`RV64_XLEN{1'b0}},
    parameter [`RV64_XLEN-1:0] SPEC_LOAD_SIZE = {`RV64_XLEN{1'b0}},
    parameter ENABLE_RV64A = 1,
    parameter ENABLE_L1I = 1,
    parameter ENABLE_L1D = 1,
    parameter ENABLE_L1D_COHERENCE_PROBES = 0,
    parameter ENABLE_COHERENT_ATOMICS = 0,
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
    parameter integer L2_TLB_ENTRIES = 256,
    parameter integer L2_TLB_WAYS = 4,
    parameter integer PTW_PTE_CACHE_ENTRIES = 64,
    parameter integer PTW_CCX_TIMEOUT_CYCLES = 65536,
    parameter [`OPENRV64_CCX_HART_ID_WIDTH-1:0] HART_ID =
        {`OPENRV64_CCX_HART_ID_WIDTH{1'b0}},
    parameter ENABLE_MAGIC_MEMORY = 0,
    parameter ENABLE_TRACE = 0,
    parameter ENABLE_PREDECODE_TARGETS = 1,
    parameter ENABLE_FETCH_CAROUSEL = 1,
    parameter ENABLE_FETCH_ALT_LOOKASIDE = 3,
    // Optional bandwidth policy.  The default stashes every eligible
    // alternate path; set this to one to restrict stashing to weak BP output.
    parameter ENABLE_FETCH_ALT_CONFIDENCE_GATE = 0,
    parameter integer FETCH_ALT_PAIR_STACK_DEPTH = 2,
    parameter [`OPENRV64_BP_TYPE_WIDTH-1:0] BP_TYPE = `OPENRV64_BP_DEFAULT,
    parameter BP_RAS_ENABLE = 1,
    parameter integer BP_RAS_DEPTH = 8,
    parameter integer BP_BIMODAL_ENTRIES = 32,
    parameter integer BP_BIMODAL_COUNTER_BITS = 3,
    parameter integer BP_BIMODAL_UPDATE_DEPTH = 4,
    parameter integer BP_GSHARE_ENTRIES = 256,
    parameter integer BP_GSHARE_COUNTER_BITS = 3,
    parameter integer BP_BTB_ENTRIES = 256,
    parameter integer BP_BTB_TAG_BITS = 16,
    parameter integer BP_INFLIGHT_DEPTH = 16
) (
    input  wire        clk,
    input  wire        rst_n,
    output wire        mem_valid,
    input  wire        mem_ready,
    output wire        mem_write,
    output wire [63:0] mem_addr,
    output wire [63:0] mem_wdata,
    output wire [7:0]  mem_wstrb,
    input  wire [63:0] mem_rdata,
    input  wire        mem_error,
    output wire        pair512_req_valid,
    input  wire        pair512_req_ready,
    output wire [63:0] pair512_req_predicted_addr,
    output wire [63:0] pair512_req_unpredicted_addr,
    input  wire        pair512_resp_valid,
    input  wire [63:0] pair512_resp_predicted_addr,
    input  wire [`OPENRV64_AXI_DATA_WIDTH-1:0]
                              pair512_resp_predicted_data,
    input  wire [63:0] pair512_resp_unpredicted_addr,
    input  wire [`OPENRV64_AXI_DATA_WIDTH-1:0]
                              pair512_resp_unpredicted_data,
    output wire        pair1024_req_valid,
    input  wire        pair1024_req_ready,
    output wire [63:0] pair1024_req_predicted_addr,
    output wire [63:0] pair1024_req_unpredicted_addr,
    input  wire        pair1024_resp_valid,
    input  wire [63:0] pair1024_resp_predicted_addr,
    input  wire [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0]
                              pair1024_resp_predicted_data,
    input  wire [63:0] pair1024_resp_unpredicted_addr,
    input  wire [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0]
                              pair1024_resp_unpredicted_data,
    output wire [`OPENRV64_AXI_ID_WIDTH-1:0] m_axi_arid,
    output wire [`OPENRV64_AXI_ADDR_WIDTH-1:0] m_axi_araddr,
    output wire [7:0]  m_axi_arlen,
    output wire [2:0]  m_axi_arsize,
    output wire [1:0]  m_axi_arburst,
    output wire        m_axi_arlock,
    output wire [3:0]  m_axi_arcache,
    output wire [2:0]  m_axi_arprot,
    output wire [3:0]  m_axi_arqos,
    output wire        m_axi_arvalid,
    input  wire        m_axi_arready,
    input  wire [`OPENRV64_AXI_ID_WIDTH-1:0] m_axi_rid,
    input  wire [`OPENRV64_AXI_DATA_WIDTH-1:0] m_axi_rdata,
    input  wire [1:0]  m_axi_rresp,
    input  wire        m_axi_rlast,
    input  wire        m_axi_rvalid,
    output wire        m_axi_rready,
    output wire [`OPENRV64_AXI_ID_WIDTH-1:0] m_axi_awid,
    output wire [`OPENRV64_AXI_ADDR_WIDTH-1:0] m_axi_awaddr,
    output wire [7:0]  m_axi_awlen,
    output wire [2:0]  m_axi_awsize,
    output wire [1:0]  m_axi_awburst,
    output wire        m_axi_awlock,
    output wire [3:0]  m_axi_awcache,
    output wire [2:0]  m_axi_awprot,
    output wire [3:0]  m_axi_awqos,
    output wire        m_axi_awvalid,
    input  wire        m_axi_awready,
    output wire [`OPENRV64_AXI_DATA_WIDTH-1:0] m_axi_wdata,
    output wire [`OPENRV64_AXI_STRB_WIDTH-1:0] m_axi_wstrb_axi,
    output wire        m_axi_wlast,
    output wire        m_axi_wvalid,
    input  wire        m_axi_wready,
    input  wire [`OPENRV64_AXI_ID_WIDTH-1:0] m_axi_bid,
    input  wire [1:0]  m_axi_bresp,
    input  wire        m_axi_bvalid,
    output wire        m_axi_bready,

    output wire        ccx_req_valid,
    input  wire        ccx_req_ready,
    output wire [`OPENRV64_CCX_HART_ID_WIDTH-1:0] ccx_req_hart_id,
    output wire [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] ccx_req_txn_id,
    output wire [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] ccx_req_source_id,
    output wire [`OPENRV64_CCX_OP_WIDTH-1:0] ccx_req_op,
    output wire        ccx_req_lock,
    output wire [`OPENRV64_CCX_ORDER_WIDTH-1:0] ccx_req_order,
    output wire [`OPENRV64_CCX_KIND_WIDTH-1:0] ccx_req_kind,
    output wire [`OPENRV64_CCX_ATTR_WIDTH-1:0] ccx_req_attr,
    output wire [2:0]  ccx_req_size,
    output wire [63:0] ccx_req_addr,
    output wire [`OPENRV64_CCX_BURST_LEN_WIDTH-1:0] ccx_req_burst_len,
    output wire        ccx_wdata_valid,
    input  wire        ccx_wdata_ready,
    output wire [`OPENRV64_CCX_HART_ID_WIDTH-1:0] ccx_wdata_hart_id,
    output wire [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] ccx_wdata_txn_id,
    output wire [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] ccx_wdata_source_id,
    output wire [`OPENRV64_CCX_BEAT_INDEX_WIDTH-1:0] ccx_wdata_beat_index,
    output wire        ccx_wdata_last,
    output wire [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] ccx_wdata,
    output wire [`OPENRV64_CCX_LINE_STRB_WIDTH-1:0] ccx_wstrb,
    input  wire        ccx_resp_valid,
    output wire        ccx_resp_ready,
    input  wire [`OPENRV64_CCX_HART_ID_WIDTH-1:0] ccx_resp_hart_id,
    input  wire [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] ccx_resp_txn_id,
    input  wire [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] ccx_resp_source_id,
    input  wire [`OPENRV64_CCX_BEAT_INDEX_WIDTH-1:0] ccx_resp_beat_index,
    input  wire        ccx_resp_last,
    input  wire [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] ccx_resp_rdata,
    input  wire        ccx_resp_error,
    input  wire        ccx_resp_sc_success,

    input  wire        l1d_probe_valid_i,
    output wire        l1d_probe_ready_o,
    input  wire [63:0] l1d_probe_addr_i,
    input  wire        coherent_reservation_clear_i,

    input  wire        irq_m_software,
    input  wire        irq_m_timer,
    input  wire        irq_m_external,
    input  wire        irq_s_software,
    input  wire        irq_s_timer,
    input  wire        irq_s_external,
    output wire [63:0] dbg_pc,
    output wire [31:0] dbg_instr,
    output wire        dbg_halted,
    output wire [63:0]  trace_cycle,
    output wire [4:0]   trace_valid,
    output wire [4:0]   trace_stall,
    output wire [4:0]   trace_flush,
    output wire [4:0]   trace_advance,
    output wire [319:0] trace_ids,
    output wire [319:0] trace_pcs,
    output wire [159:0] trace_instrs,
    output wire [7:0]   trace_events,
    output wire [7:0]   trace_stall_causes,
    output wire         trace_retire_valid,
    output wire         trace_retire_arch,
    output wire         trace_retire_exception,
    output wire [`RV64_EXCEPT_CAUSE_WIDTH-1:0] trace_retire_cause,
    output wire [63:0]  trace_retire_next_pc,
    output wire         trace_retire_rd_write,
    output wire [`RV64_REG_ADDR_WIDTH-1:0] trace_retire_rd,
    output wire [63:0]  trace_retire_wdata
);

    reg [63:0] pc_q;
    reg [63:0] trace_cycle_q;
    reg [63:0] trace_next_id_q;
    reg [63:0] dbg_pc_q;
    reg [31:0] dbg_instr_q;
    reg halted_q;
    reg reset_pending_q;

    wire fetch_pc_ready;
    wire translation_barrier_busy;
    wire fetch_pc_valid = fetch_pc_ready && !halted_q &&
                          !reset_pending_q &&
                          !translation_barrier_busy;
    wire fetch_mem_valid;
    wire fetch_mem_next_valid;
    wire fetch_mem_ready;
    wire [63:0] fetch_mem_addr;
    wire [63:0] fetch_mem_exec_addr;
    wire [63:0] fetch_mem_rdata;
    wire fetch_mem_fault;
    wire fetch_mem_page_fault;
    wire fetch_redirect_replay;
    wire [2:0] fetch_decode_valid;
    wire [2:0] fetch_decode_ready;
    wire [3*`RV64_FETCH_DECODE_BUS_WIDTH-1:0] fetch_decode_bus;
    wire [3*64-1:0] fetch_decode_trace;
    wire fetch_pipe_req_valid;
    // The checkpoint trace reads this handshake directly from the generated
    // model.  Keep it materialized even when Verilator could fold it away.
    wire fetch_pipe_req_ready /* verilator public_flat_rd */;
    wire [63:0] fetch_pipe_req_addr;
    wire fetch_pipe_req_stash;
    wire fetch_pipe_req_demand;
    wire fetch_pipe_resp_valid;
    wire fetch_pipe_resp_ready;
    wire [63:0] fetch_pipe_resp_addr;
    wire [`OPENRV64_AXI_DATA_WIDTH-1:0] fetch_pipe_resp_data;
    wire fetch_pipe_resp_access_fault;
    wire fetch_pipe_resp_page_fault;
    wire fetch_pipe_resp_stash;
    wire fetch_pipe_resp_demand;
    wire fetch3_cancel;
    wire fetch3_cancel_stash;
    wire [63:0] fetch3_stream_pc;
    wire fetch_alt_restart_hit;
    wire use_ccx_bus = (BUS_CONFIG == `OPENRV64_BUS_AXI);

    wire backend_redirect;
    wire [`OPENRV64_INSTR_ID_WIDTH-1:0] backend_redirect_id;
    wire [63:0] backend_redirect_target;
    wire branch_resolved;
    wire branch_conditional;
    wire branch_taken;
    wire [63:0] branch_pc;
    wire [31:0] branch_instr;
    wire [`OPENRV64_INSTR_ID_WIDTH-1:0] branch_id;
    wire [$clog2(RETIRE_DEPTH)-1:0] branch_slot;
    wire [2:0] branch_train_valid;
    wire [2:0] branch_train_conditional;
    wire [2:0] branch_train_taken;
    wire [3*`RV64_XLEN-1:0] branch_train_pc;
    wire [2:0] branch_retire_age_valid;
    wire [3*`RV64_XLEN-1:0] branch_retire_age_addr;
    wire [3*`OPENRV64_INSTR_ID_WIDTH-1:0]
        backend_decode_allocation_id;
    wire [3*$clog2(RETIRE_DEPTH)-1:0]
        backend_decode_allocation_slot;
    wire backend_exception;
    wire backend_halt;
    wire backend_irq;
    wire backend_mret;
    wire backend_sret;
    wire backend_fence_i;
    wire backend_sfence_vma;
    wire backend_satp_write;
    wire [4:0] backend_cause;
    wire [63:0] backend_retire_pc;
    wire [63:0] backend_retire_next_pc;
    wire [63:0] backend_retire_tval;
    wire [63:0] backend_retire_trace_id;
    wire [31:0] backend_retire_instr;
    wire [4:0] backend_retire_rd;
    wire [63:0] backend_retire_wdata;
    wire [2:0] backend_retire_arch;
    wire [1:0] backend_retire_count;

    wire control_trap = backend_exception && !backend_halt;
    wire control_restart = backend_fence_i || backend_sfence_vma ||
                           backend_satp_write;
    wire control_flush = control_trap || backend_irq || backend_mret ||
                         backend_sret || control_restart;
    wire fetch_invalidate = reset_pending_q || control_flush || backend_halt;

    wire except_vector_valid;
    wire [63:0] except_vector_target;
    wire csr_irq_pending;
    wire [4:0] csr_irq_cause;
    wire [63:0] csr_trap_vector;
    wire [63:0] csr_mepc;
    wire [63:0] csr_sepc;
    wire csr_trap_to_s;
    wire [`RV64_PRIV_WIDTH-1:0] csr_priv_mode;
    wire [`RV64_PRIV_WIDTH-1:0] csr_data_priv_mode;
    wire csr_sret_allowed;
    wire csr_sfence_vma_allowed;
    wire [`RV64_SATP_MODE_WIDTH-1:0] csr_satp_mode;
    wire [`RV64_SATP_ASID_WIDTH-1:0] csr_satp_asid;
    wire [`RV64_SATP_PPN_WIDTH-1:0] csr_satp_root_ppn;
    wire csr_status_sum;
    wire csr_status_mxr;

    wire bp_branch_present;
    wire bp_branch_allocate;
    wire bp_prediction_taken;
    wire bp_prediction_weak;
    wire bp_prediction_target_valid;
    wire [63:0] bp_prediction_target;
    wire bp_target_mispredict;
    wire bp_update_overflow;
    wire bp_predict_redirect;
    wire [63:0] bp_predict_target;
    wire [63:0] bp_direct_target;
    wire bp_fetch_stall;
    wire bp_decode_stall;
    wire icache_branch_hint_valid;
    wire fetch_alt_pair_valid;
    wire icache_prefetch_valid;
    wire l1i_branch_prefetch_valid;
    wire l1i_next_line_prefetch;
    wire l1i_high_confidence_hint;
    wire l1i_predicted_line_resident;
    wire l1i_predicted_line_response;
    wire [63:0] icache_prefetch_taken_addr;
    wire [63:0] icache_prefetch_fallthrough_addr;
    wire [63:0] icache_prefetch_predicted_addr;
    wire [63:0] icache_prefetch_unpredicted_addr;
    wire [63:0] icache_prefetch_predicted_next_line;
    reg l1i_next_line_pending_q;
    reg [63:0] l1i_next_line_source_q;
    reg [63:0] l1i_next_line_addr_q;
    wire [63:0] l1i_prefetch_first_addr;
    wire [63:0] l1i_prefetch_second_addr;
    wire control_redirect = backend_redirect || bp_target_mispredict;

    wire fetch3_restart = reset_pending_q || except_vector_valid ||
                          control_restart || control_redirect ||
                          bp_predict_redirect;
    wire [63:0] fetch3_restart_pc = except_vector_valid ?
        except_vector_target : control_restart ? backend_retire_next_pc :
        control_redirect ? backend_redirect_target :
        bp_predict_redirect ? bp_predict_target : RESET_VECTOR;
    wire fetch3_invalidate = reset_pending_q || except_vector_valid ||
                             control_restart;

    generate
        if (BUS_CONFIG == `OPENRV64_BUS_GEN) begin : g_fetch_gen
            openrv64_fetch #(
                .ENABLE_TRACE(ENABLE_TRACE),
                .ENABLE_PREDECODE_TARGETS(ENABLE_PREDECODE_TARGETS),
                .DECODE_WIDTH(2)
            ) u_fetch (
                .clk(clk), .rst_n(rst_n), .flush_i(fetch_invalidate),
                .redirect_i(control_redirect), .redirect_replay_i(1'b0),
                .redirect_pc_i(backend_redirect_target),
                .redirect_replay_o(fetch_redirect_replay),
                .pc_ready_o(fetch_pc_ready), .pc_valid_i(fetch_pc_valid),
                .pc_i(pc_q), .mem_valid_o(fetch_mem_valid),
                .mem_next_valid_o(fetch_mem_next_valid),
                .mem_ready_i(fetch_mem_ready), .mem_write_o(),
                .mem_addr_o(fetch_mem_addr),
                .mem_exec_addr_o(fetch_mem_exec_addr),
                .mem_wdata_o(), .mem_wstrb_o(),
                .mem_rdata_i(fetch_mem_rdata), .mem_fault_i(fetch_mem_fault),
                .mem_page_fault_i(fetch_mem_page_fault),
                .decode_valid_o(fetch_decode_valid[0]),
                .decode_ready_i(fetch_decode_ready[0]),
                .decode_bus_o(fetch_decode_bus[
                    0*`RV64_FETCH_DECODE_BUS_WIDTH +:
                    `RV64_FETCH_DECODE_BUS_WIDTH]),
                .decode_pc_o(), .decode_instr_o(), .decode_fault_o(),
                .decode_page_fault_o(),
                .trace_id_i(ENABLE_TRACE ? trace_next_id_q : 64'd0),
                .trace_id_o(fetch_decode_trace[0*64 +: 64]),
                .decode_valid1_o(fetch_decode_valid[1]),
                .decode_ready1_i(fetch_decode_ready[1]),
                .decode_bus1_o(fetch_decode_bus[
                    1*`RV64_FETCH_DECODE_BUS_WIDTH +:
                    `RV64_FETCH_DECODE_BUS_WIDTH]),
                .decode_pc1_o(), .decode_instr1_o(), .decode_fault1_o(),
                .decode_page_fault1_o(),
                .trace_id1_o(fetch_decode_trace[1*64 +: 64])
            );
            assign fetch_decode_valid[2] = 1'b0;
            assign fetch_decode_bus[2*`RV64_FETCH_DECODE_BUS_WIDTH +:
                                    `RV64_FETCH_DECODE_BUS_WIDTH] =
                {`RV64_FETCH_DECODE_BUS_WIDTH{1'b0}};
            assign fetch_decode_trace[2*64 +: 64] = 64'd0;
            assign fetch_pipe_req_valid = 1'b0;
            assign fetch_pipe_req_addr = 64'd0;
            assign fetch_pipe_req_stash = 1'b0;
            assign fetch_pipe_req_demand = 1'b0;
            assign fetch_pipe_resp_ready = 1'b0;
            assign fetch3_cancel = 1'b0;
            assign fetch3_cancel_stash = 1'b1;
            assign fetch3_stream_pc = 64'd0;
            assign fetch_alt_restart_hit = 1'b0;
            assign pair512_req_valid = 1'b0;
            assign pair512_req_predicted_addr = 64'd0;
            assign pair512_req_unpredicted_addr = 64'd0;
            assign pair1024_req_valid = 1'b0;
            assign pair1024_req_predicted_addr = 64'd0;
            assign pair1024_req_unpredicted_addr = 64'd0;
        end else begin : g_fetch_axi
            openrv64_fetch_3w #(
                .ENABLE_CAROUSEL(ENABLE_FETCH_CAROUSEL),
                .ENABLE_TRACE(ENABLE_TRACE),
                .ENABLE_PREDECODE_TARGETS(ENABLE_PREDECODE_TARGETS),
                .ENABLE_ALT_LOOKASIDE(ENABLE_FETCH_ALT_LOOKASIDE),
                .BRANCH_PAIR_STACK_DEPTH(FETCH_ALT_PAIR_STACK_DEPTH)
            ) u_fetch (
                .clk(clk), .rst_n(rst_n), .restart_i(fetch3_restart),
                .restart_pc_i(fetch3_restart_pc),
                .invalidate_i(fetch3_invalidate),
                .stall_i(bp_fetch_stall || translation_barrier_busy),
                .flush_i(backend_halt), .cancel_o(fetch3_cancel),
                .cancel_stash_o(fetch3_cancel_stash),
                .req_valid_o(fetch_pipe_req_valid),
                .req_ready_i(fetch_pipe_req_ready),
                .req_addr_o(fetch_pipe_req_addr),
                .req_stash_o(fetch_pipe_req_stash),
                .req_demand_o(fetch_pipe_req_demand),
                .resp_valid_i(fetch_pipe_resp_valid),
                .resp_ready_o(fetch_pipe_resp_ready),
                .resp_addr_i(fetch_pipe_resp_addr),
                .resp_data_i(fetch_pipe_resp_data),
                .resp_access_fault_i(fetch_pipe_resp_access_fault),
                .resp_page_fault_i(fetch_pipe_resp_page_fault),
                .resp_stash_i(fetch_pipe_resp_stash),
                .resp_demand_i(fetch_pipe_resp_demand),
                .branch_pair_valid_i(fetch_alt_pair_valid),
                .branch_predicted_addr_i(
                    icache_prefetch_predicted_addr),
                .branch_unpredicted_addr_i(
                    icache_prefetch_unpredicted_addr),
                .ras_fetch_valid_i(ras_return_fetch_valid),
                .ras_fetch_addr_i(bp_prediction_target),
                .pair512_req_valid_o(pair512_req_valid),
                .pair512_req_ready_i(pair512_req_ready),
                .pair512_req_predicted_addr_o(
                    pair512_req_predicted_addr),
                .pair512_req_unpredicted_addr_o(
                    pair512_req_unpredicted_addr),
                .pair512_resp_valid_i(pair512_resp_valid),
                .pair512_resp_predicted_addr_i(
                    pair512_resp_predicted_addr),
                .pair512_resp_predicted_data_i(
                    pair512_resp_predicted_data),
                .pair512_resp_unpredicted_addr_i(
                    pair512_resp_unpredicted_addr),
                .pair512_resp_unpredicted_data_i(
                    pair512_resp_unpredicted_data),
                .pair1024_req_valid_o(pair1024_req_valid),
                .pair1024_req_ready_i(pair1024_req_ready),
                .pair1024_req_predicted_addr_o(
                    pair1024_req_predicted_addr),
                .pair1024_req_unpredicted_addr_o(
                    pair1024_req_unpredicted_addr),
                .pair1024_resp_valid_i(pair1024_resp_valid),
                .pair1024_resp_predicted_addr_i(
                    pair1024_resp_predicted_addr),
                .pair1024_resp_predicted_data_i(
                    pair1024_resp_predicted_data),
                .pair1024_resp_unpredicted_addr_i(
                    pair1024_resp_unpredicted_addr),
                .pair1024_resp_unpredicted_data_i(
                    pair1024_resp_unpredicted_data),
                .prefetch_age_valid_i(branch_retire_age_valid),
                .prefetch_age_addr_i(branch_retire_age_addr),
                // Mode 1 isolates unpredicted-side recovery.  Mode 2 also
                // serves the predicted target and exposes the current cost of
                // discarding bridge lines on a predicted redirect.
                .alt_restart_eligible_i(backend_redirect ||
                    ((ENABLE_FETCH_ALT_LOOKASIDE > 1) &&
                     (bp_predict_redirect || bp_target_mispredict))),
                .decode_valid_o(fetch_decode_valid),
                .decode_ready_i(fetch_decode_ready),
                .decode_bus_o(fetch_decode_bus),
                .trace_id_i(ENABLE_TRACE ? trace_next_id_q : 64'd0),
                .trace_id_o(fetch_decode_trace),
                .stream_pc_o(fetch3_stream_pc), .line_count_o(),
                .alt_restart_hit_o(fetch_alt_restart_hit)
            );
            assign fetch_pc_ready = 1'b0;
            assign fetch_mem_valid = 1'b0;
            assign fetch_mem_next_valid = 1'b0;
            assign fetch_mem_addr = 64'd0;
            assign fetch_mem_exec_addr = fetch3_stream_pc;
            assign fetch_redirect_replay = 1'b0;
        end
    endgenerate

    wire [`RV64_FETCH_DECODE_BUS_WIDTH-1:0] fetch_decode_bus0 =
        fetch_decode_bus[0*`RV64_FETCH_DECODE_BUS_WIDTH +:
                         `RV64_FETCH_DECODE_BUS_WIDTH];
    wire [`RV64_FETCH_DECODE_BUS_WIDTH-1:0] fetch_decode_bus1 =
        fetch_decode_bus[1*`RV64_FETCH_DECODE_BUS_WIDTH +:
                         `RV64_FETCH_DECODE_BUS_WIDTH];
    wire [`RV64_FETCH_DECODE_BUS_WIDTH-1:0] fetch_decode_bus2 =
        fetch_decode_bus[2*`RV64_FETCH_DECODE_BUS_WIDTH +:
                         `RV64_FETCH_DECODE_BUS_WIDTH];
    wire [31:0] instr0 =
        fetch_decode_bus0[`RV64_FETCH_DECODE_BUS_INSTR_BITS];
    wire [31:0] instr1 =
        fetch_decode_bus1[`RV64_FETCH_DECODE_BUS_INSTR_BITS];
    wire [31:0] instr2 =
        fetch_decode_bus2[`RV64_FETCH_DECODE_BUS_INSTR_BITS];
    wire [63:0] decode_pc0 =
        fetch_decode_bus0[`RV64_FETCH_DECODE_BUS_PC_BITS];
    wire [63:0] decode_pc1 =
        fetch_decode_bus1[`RV64_FETCH_DECODE_BUS_PC_BITS];
    wire [63:0] decode_pc2 =
        fetch_decode_bus2[`RV64_FETCH_DECODE_BUS_PC_BITS];
    wire instr_fault0 = fetch_decode_bus0[
        `RV64_FETCH_DECODE_BUS_ACCESS_FAULT_BIT];
    wire instr_fault1 = fetch_decode_bus1[
        `RV64_FETCH_DECODE_BUS_ACCESS_FAULT_BIT];
    wire instr_fault2 = fetch_decode_bus2[
        `RV64_FETCH_DECODE_BUS_ACCESS_FAULT_BIT];
    wire instr_page_fault0 = fetch_decode_bus0[
        `RV64_FETCH_DECODE_BUS_PAGE_FAULT_BIT];
    wire instr_page_fault1 = fetch_decode_bus1[
        `RV64_FETCH_DECODE_BUS_PAGE_FAULT_BIT];
    wire instr_page_fault2 = fetch_decode_bus2[
        `RV64_FETCH_DECODE_BUS_PAGE_FAULT_BIT];
    wire [2:0] predecode_valid = {
        fetch_decode_bus2[`RV64_FETCH_DECODE_BUS_PREDECODE_VALID_BIT],
        fetch_decode_bus1[`RV64_FETCH_DECODE_BUS_PREDECODE_VALID_BIT],
        fetch_decode_bus0[`RV64_FETCH_DECODE_BUS_PREDECODE_VALID_BIT]
    };
    wire [2:0] predecode_conditional = {
        fetch_decode_bus2[
            `RV64_FETCH_DECODE_BUS_PREDECODE_CONDITIONAL_BIT],
        fetch_decode_bus1[
            `RV64_FETCH_DECODE_BUS_PREDECODE_CONDITIONAL_BIT],
        fetch_decode_bus0[
            `RV64_FETCH_DECODE_BUS_PREDECODE_CONDITIONAL_BIT]
    };
    wire [3*20-1:0] predecode_offset = {
        fetch_decode_bus2[`RV64_FETCH_DECODE_BUS_PREDECODE_OFFSET_BITS],
        fetch_decode_bus1[`RV64_FETCH_DECODE_BUS_PREDECODE_OFFSET_BITS],
        fetch_decode_bus0[`RV64_FETCH_DECODE_BUS_PREDECODE_OFFSET_BITS]
    };

    wire [2:0] decode_valid;
    wire [2:0] decode_illegal;
    wire [2:0] decode_uses_rs1;
    wire [2:0] decode_uses_rs2;
    wire [3*5-1:0] decode_rs1;
    wire [3*5-1:0] decode_rs2;
    wire [3*5-1:0] decode_rd;
    wire [2:0] decode_reg_write;
    wire [3*64-1:0] decode_imm;
    wire [2:0] decode_mem_read;
    wire [2:0] decode_mem_write;
    wire [2:0] decode_branch;
    wire [2:0] decode_jump;
    wire [2:0] decode_br_indirect;
    wire [2:0] decode_word;
    wire [2:0] decode_system;
    wire [2:0] decode_fence;
    wire [3*`RV64_ALU_EXT_WIDTH-1:0] decode_alu_ext;
    wire [3*`RV64_ALU_OP_WIDTH-1:0] decode_alu_op;
    wire [3*`RV64_LSU_OP_WIDTH-1:0] decode_lsu_op;
    wire [3*`RV64_BR_OP_WIDTH-1:0] decode_br_op;

    genvar decode_lane;
    generate
        for (decode_lane = 0; decode_lane < 3;
             decode_lane = decode_lane + 1) begin : g_decode
            wire [31:0] lane_instr = (decode_lane == 0) ? instr0 :
                                     (decode_lane == 1) ? instr1 : instr2;
            openrv64_decode_top #(
                .ENABLE_RV64M(ENABLE_RV64M), .ENABLE_RV64A(ENABLE_RV64A)
            ) u_decode (
                .instr_i(lane_instr), .valid_o(decode_valid[decode_lane]),
                .illegal_o(decode_illegal[decode_lane]),
                .opcode_o(), .funct3_o(), .funct7_o(), .funct12_o(),
                .class_sel_o(), .format_sel_o(),
                .uses_rs1_o(decode_uses_rs1[decode_lane]),
                .uses_rs2_o(decode_uses_rs2[decode_lane]), .uses_rd_o(),
                .rs1_addr_o(decode_rs1[decode_lane*5 +: 5]),
                .rs2_addr_o(decode_rs2[decode_lane*5 +: 5]),
                .rd_addr_o(decode_rd[decode_lane*5 +: 5]),
                .reg_write_o(decode_reg_write[decode_lane]),
                .imm_valid_o(), .has_imm_o(),
                .imm_o(decode_imm[decode_lane*64 +: 64]),
                .mem_read_o(decode_mem_read[decode_lane]),
                .mem_write_o(decode_mem_write[decode_lane]),
                .branch_o(decode_branch[decode_lane]),
                .jump_o(decode_jump[decode_lane]),
                .word_op_o(decode_word[decode_lane]),
                .system_o(decode_system[decode_lane]),
                .fence_o(decode_fence[decode_lane]),
                .alu_ext_sel_o(decode_alu_ext[
                    decode_lane*`RV64_ALU_EXT_WIDTH +: `RV64_ALU_EXT_WIDTH]),
                .alu_op_sel_o(decode_alu_op[
                    decode_lane*`RV64_ALU_OP_WIDTH +: `RV64_ALU_OP_WIDTH]),
                .lsu_op_sel_o(decode_lsu_op[
                    decode_lane*`RV64_LSU_OP_WIDTH +: `RV64_LSU_OP_WIDTH]),
                .lsu_size_sel_o(), .lsu_unsigned_o(),
                .br_op_sel_o(decode_br_op[
                    decode_lane*`RV64_BR_OP_WIDTH +: `RV64_BR_OP_WIDTH]),
                .br_link_o(),
                .br_indirect_o(decode_br_indirect[decode_lane]),
                .subdecode_needed_o(),
                .extension_decode_possible_o()
            );
        end
    endgenerate

    // The scalar predictor is shared by the oldest control instruction in
    // the presented bundle.  Decode admission stops after that lane, so a
    // predicted-taken redirect never deposits a sequential younger lane into
    // the dispatch queue on the redirecting edge.
    wire [2:0] frontend_control = fetch_decode_valid &
                                  (predecode_valid |
                                   decode_branch | decode_jump);
    wire [2:0] frontend_control_select = {
        frontend_control[2] && !frontend_control[1] && !frontend_control[0],
        frontend_control[1] && !frontend_control[0],
        frontend_control[0]
    };
    wire [2:0] frontend_prefix_allow = {
        !frontend_control[0] && !frontend_control[1],
        !frontend_control[0],
        1'b1
    };
    wire [1:0] bp_lane = frontend_control_select[0] ? 2'd0 :
                         frontend_control_select[1] ? 2'd1 : 2'd2;
    wire bp_selected_predecode = predecode_valid[bp_lane];
    wire [19:0] bp_selected_predecode_offset =
        predecode_offset[bp_lane*20 +: 20];
    wire [63:0] bp_selected_pc = (bp_lane == 2'd0) ? decode_pc0 :
                                 (bp_lane == 2'd1) ? decode_pc1 : decode_pc2;
    wire [31:0] bp_selected_instr = (bp_lane == 2'd0) ? instr0 :
                                    (bp_lane == 2'd1) ? instr1 : instr2;
    wire [`OPENRV64_INSTR_ID_WIDTH-1:0] bp_selected_id =
        backend_decode_allocation_id[
            bp_lane*`OPENRV64_INSTR_ID_WIDTH +:
            `OPENRV64_INSTR_ID_WIDTH];
    wire [63:0] bp_selected_decode_imm =
        decode_imm[bp_lane*64 +: 64];
    wire [63:0] bp_selected_imm = bp_selected_predecode ?
        {{43{bp_selected_predecode_offset[19]}},
         bp_selected_predecode_offset, 1'b0} : bp_selected_decode_imm;
    wire bp_lookup_branch = bp_selected_predecode ?
        predecode_conditional[bp_lane] : decode_branch[bp_lane];
    wire bp_lookup_jump = bp_selected_predecode ?
        !predecode_conditional[bp_lane] : decode_jump[bp_lane];
    wire bp_lookup_indirect = bp_selected_predecode ?
        1'b0 : decode_br_indirect[bp_lane];
    wire bp_lookup_is_jalr =
        `RV64_OPCODE(bp_selected_instr) == `RV64_OPCODE_JALR;
    wire bp_lookup_rs1_link =
        (`RV64_RS1(bp_selected_instr) == 5'd1) ||
        (`RV64_RS1(bp_selected_instr) == 5'd5);
    wire bp_lookup_rd_link =
        (`RV64_RD(bp_selected_instr) == 5'd1) ||
        (`RV64_RD(bp_selected_instr) == 5'd5);
    wire bp_lookup_return = bp_lookup_indirect && bp_lookup_is_jalr &&
                            bp_lookup_rs1_link && !bp_lookup_rd_link;
    wire ras_return_fetch_valid;

    assign bp_branch_present = use_ccx_bus &&
                               (|frontend_control_select) &&
                               !control_flush && !control_redirect &&
                               !halted_q;
    assign bp_predict_redirect = bp_branch_allocate &&
                                 bp_prediction_taken;

    openrv64_prefix_addsub u_bp_target (
        .a_i(bp_selected_pc), .b_i(bp_selected_imm), .sub_i(1'b0),
        .result_o(bp_direct_target)
    );
    assign bp_predict_target = bp_prediction_target_valid ?
                               bp_prediction_target : bp_direct_target;

    openrv64_exec_bp #(
        .BP_TYPE(BP_TYPE),
        .ENABLE_RAS(BP_RAS_ENABLE),
        .RAS_DEPTH(BP_RAS_DEPTH),
        .BIMODAL_ENTRIES(BP_BIMODAL_ENTRIES),
        .BIMODAL_COUNTER_BITS(BP_BIMODAL_COUNTER_BITS),
        .BIMODAL_UPDATE_DEPTH(BP_BIMODAL_UPDATE_DEPTH),
        .GSHARE_ENTRIES(BP_GSHARE_ENTRIES),
        .GSHARE_COUNTER_BITS(BP_GSHARE_COUNTER_BITS),
        .BTB_ENTRIES(BP_BTB_ENTRIES),
        .BTB_TAG_BITS(BP_BTB_TAG_BITS),
        .INFLIGHT_DEPTH(BP_INFLIGHT_DEPTH),
        .ENABLE_TAGGED_RESOLUTION(ENABLE_SPECULATION_WINDOW)
    ) u_bp (
        .clk(clk), .rst_n(rst_n),
        .flush_i(control_flush ||
                 (control_redirect &&
                  (ENABLE_SPECULATION_WINDOW == 0))),
        .squash_i(control_redirect &&
                  (ENABLE_SPECULATION_WINDOW != 0)),
        .lookup_valid_i(bp_branch_present),
        .lookup_branch_i(bp_lookup_branch),
        .lookup_jump_i(bp_lookup_jump),
        .lookup_indirect_i(bp_lookup_indirect),
        .lookup_backward_i(bp_selected_imm[63]),
        .lookup_instr_i(bp_selected_instr),
        .lookup_pc_i(bp_selected_pc),
        .lookup_id_i(bp_selected_id),
        .lookup_allocate_i(bp_branch_allocate),
        .resolve_valid_i(branch_resolved),
        .resolve_branch_i(branch_conditional),
        .resolve_taken_i(branch_taken),
        .resolve_instr_i(branch_instr), .resolve_pc_i(branch_pc),
        .resolve_target_i(backend_redirect_target),
        .resolve_id_i(branch_id),
        .train_valid_i(branch_train_valid),
        .train_branch_i(branch_train_conditional),
        .train_taken_i(branch_train_taken),
        .train_pc_i(branch_train_pc),
        .prediction_taken_o(bp_prediction_taken),
        .prediction_weak_o(bp_prediction_weak),
        .prediction_target_valid_o(bp_prediction_target_valid),
        .prediction_target_o(bp_prediction_target),
        .target_mispredict_o(bp_target_mispredict),
        .update_overflow_o(bp_update_overflow),
        .fetch_stall_o(bp_fetch_stall),
        .decode_stall_o(bp_decode_stall)
    );

    wire [2:0] bp_lane_prediction = frontend_control_select &
                                    {3{bp_prediction_taken}};

    wire [2:0] decode_ebreak = {
        instr2 == `RV64_INSTR_EBREAK,
        instr1 == `RV64_INSTR_EBREAK, instr0 == `RV64_INSTR_EBREAK};
    wire [2:0] decode_ecall = {
        instr2 == `RV64_INSTR_ECALL,
        instr1 == `RV64_INSTR_ECALL, instr0 == `RV64_INSTR_ECALL};
    wire [3*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0]
        backend_decode_payload;

    generate
        for (decode_lane = 0; decode_lane < 3;
             decode_lane = decode_lane + 1) begin : g_packet
            wire [31:0] lane_instr = (decode_lane == 0) ? instr0 :
                                     (decode_lane == 1) ? instr1 : instr2;
            wire [63:0] lane_pc = (decode_lane == 0) ? decode_pc0 :
                                  (decode_lane == 1) ? decode_pc1 : decode_pc2;
            wire lane_instr_fault = (decode_lane == 0) ? instr_fault0 :
                (decode_lane == 1) ? instr_fault1 : instr_fault2;
            wire lane_page_fault = (decode_lane == 0) ? instr_page_fault0 :
                (decode_lane == 1) ? instr_page_fault1 : instr_page_fault2;
            assign backend_decode_payload[
                decode_lane*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +:
                `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH] = {
                fetch_decode_trace[decode_lane*64 +: 64],
                lane_pc,
                lane_instr,
                decode_rs1[decode_lane*5 +: 5],
                decode_rs2[decode_lane*5 +: 5],
                64'd0,
                64'd0,
                decode_imm[decode_lane*64 +: 64],
                decode_rd[decode_lane*5 +: 5],
                decode_alu_ext[decode_lane*`RV64_ALU_EXT_WIDTH +:
                               `RV64_ALU_EXT_WIDTH],
                decode_alu_op[decode_lane*`RV64_ALU_OP_WIDTH +:
                              `RV64_ALU_OP_WIDTH],
                decode_lsu_op[decode_lane*`RV64_LSU_OP_WIDTH +:
                              `RV64_LSU_OP_WIDTH],
                decode_br_op[decode_lane*`RV64_BR_OP_WIDTH +:
                             `RV64_BR_OP_WIDTH],
                decode_reg_write[decode_lane],
                decode_mem_read[decode_lane],
                decode_mem_write[decode_lane],
                decode_branch[decode_lane],
                decode_jump[decode_lane],
                bp_lane_prediction[decode_lane],
                decode_word[decode_lane],
                decode_system[decode_lane],
                decode_fence[decode_lane],
                decode_illegal[decode_lane] || !decode_valid[decode_lane],
                decode_ebreak[decode_lane],
                decode_ecall[decode_lane],
                lane_instr_fault,
                lane_page_fault,
                csr_priv_mode,
                csr_sret_allowed,
                csr_sfence_vma_allowed
            };
        end
    endgenerate

    wire [2:0] backend_decode_ready;
    wire frontend_decode_enable = !control_flush && !control_redirect &&
                                  !halted_q && !bp_decode_stall &&
                                  !translation_barrier_busy;
    wire [2:0] backend_decode_valid = fetch_decode_valid &
        frontend_prefix_allow & {3{frontend_decode_enable}};
    wire [2:0] frontend_decode_fire = backend_decode_valid &
                                      backend_decode_ready;
    wire [1:0] frontend_decode_count =
        {1'b0, frontend_decode_fire[0]} +
        {1'b0, frontend_decode_fire[1]} +
        {1'b0, frontend_decode_fire[2]};
    assign bp_branch_allocate =
        |(frontend_decode_fire & frontend_control_select);
    assign ras_return_fetch_valid = bp_branch_allocate &&
                                    bp_lookup_return &&
                                    bp_prediction_taken &&
                                    bp_prediction_target_valid;
    assign icache_branch_hint_valid = use_ccx_bus && bp_branch_allocate &&
                                      bp_lookup_branch;
    // Confidence policy: 0 = all branch pairs, 1 = weak pairs plus strong
    // next-line prefetch, 2 = weak pairs without strong next-line prefetch.
    assign fetch_alt_pair_valid = icache_branch_hint_valid &&
                                  ((ENABLE_FETCH_ALT_CONFIDENCE_GATE == 0) ||
                                   bp_prediction_weak);
    assign icache_prefetch_valid = fetch_alt_pair_valid;
    assign icache_prefetch_taken_addr = bp_direct_target;
    assign icache_prefetch_fallthrough_addr = bp_selected_pc + 64'd4;
    assign icache_prefetch_predicted_addr =
        bp_prediction_taken ? icache_prefetch_taken_addr :
                              icache_prefetch_fallthrough_addr;
    assign icache_prefetch_unpredicted_addr =
        bp_prediction_taken ? icache_prefetch_fallthrough_addr :
                              icache_prefetch_taken_addr;
    assign icache_prefetch_predicted_next_line =
        {icache_prefetch_predicted_addr[63:6], 6'b000000} + 64'd64;

    // Weak predictions retain the two-path hint.  A strong prediction arms
    // depth prefetching, but may not launch the following line ahead of the
    // predicted line itself.  Decoding proves a same-line destination is
    // already resident; other destinations wait for their demand response.
    assign l1i_high_confidence_hint =
        icache_branch_hint_valid &&
        (ENABLE_FETCH_ALT_CONFIDENCE_GATE == 1) &&
        !bp_prediction_weak;
    assign l1i_predicted_line_resident =
        icache_prefetch_predicted_addr[63:6] == bp_selected_pc[63:6];
    assign l1i_predicted_line_response =
        l1i_next_line_pending_q && fetch_pipe_resp_valid &&
        fetch_pipe_resp_ready && fetch_pipe_resp_demand &&
        !fetch_pipe_resp_access_fault && !fetch_pipe_resp_page_fault &&
        (fetch_pipe_resp_addr[63:6] == l1i_next_line_source_q[63:6]);
    assign l1i_next_line_prefetch =
        (l1i_high_confidence_hint && l1i_predicted_line_resident) ||
        l1i_predicted_line_response;
    assign l1i_branch_prefetch_valid =
        ((ENABLE_FETCH_ALT_LOOKASIDE == 0) && fetch_alt_pair_valid) ||
        l1i_next_line_prefetch;
    assign l1i_prefetch_first_addr = l1i_next_line_prefetch ?
        ((l1i_high_confidence_hint && l1i_predicted_line_resident) ?
         icache_prefetch_predicted_next_line : l1i_next_line_addr_q) :
        icache_prefetch_taken_addr;
    assign l1i_prefetch_second_addr = l1i_next_line_prefetch ?
        ((l1i_high_confidence_hint && l1i_predicted_line_resident) ?
         icache_prefetch_predicted_next_line : l1i_next_line_addr_q) :
        icache_prefetch_fallthrough_addr;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            l1i_next_line_pending_q <= 1'b0;
            l1i_next_line_source_q <= 64'd0;
            l1i_next_line_addr_q <= 64'd0;
        end else begin
            if (fetch3_restart || translation_barrier_busy)
                l1i_next_line_pending_q <= 1'b0;
            if (l1i_predicted_line_response)
                l1i_next_line_pending_q <= 1'b0;
            if (l1i_high_confidence_hint) begin
                l1i_next_line_pending_q <=
                    !l1i_predicted_line_resident;
                l1i_next_line_source_q <=
                    {icache_prefetch_predicted_addr[63:6], 6'b000000};
                l1i_next_line_addr_q <=
                    icache_prefetch_predicted_next_line;
            end
        end
    end
    assign fetch_decode_ready[0] = backend_decode_ready[0] &&
                                   frontend_prefix_allow[0] &&
                                   frontend_decode_enable;
    assign fetch_decode_ready[1] = backend_decode_ready[1] &&
                                   frontend_prefix_allow[1] &&
                                   frontend_decode_enable;
    assign fetch_decode_ready[2] = backend_decode_ready[2] &&
                                   frontend_prefix_allow[2] &&
                                   frontend_decode_enable;

    wire [11:0] backend_csr_addr;
    wire backend_csr_write;
    wire [11:0] backend_csr_write_addr;
    wire [63:0] backend_csr_wdata;
    assign backend_satp_write =
        backend_csr_write &&
        (backend_csr_write_addr == `RV64_CSR_SATP);
    wire [63:0] csr_rdata;
    wire csr_valid;
    wire csr_writable;
    wire backend_mem_valid;
    wire backend_mem_ready;
    wire backend_mem_bus_ready;
    wire [`OPENRV64_LSU_TAG_WIDTH-1:0] backend_mem_tag;
    wire backend_mem_xlate_only;
    wire backend_mem_physical;
    wire backend_mem_xlate_valid;
    wire backend_mem_xlate_ready;
    wire backend_mem_xlate_bus_ready;
    wire [`OPENRV64_LSU_TAG_WIDTH-1:0] backend_mem_xlate_tag;
    wire backend_mem_xlate_write;
    wire [63:0] backend_mem_xlate_vaddr;
    wire backend_mem_xlate_resp_valid;
    wire backend_mem_xlate_resp_ready;
    wire [`OPENRV64_LSU_TAG_WIDTH-1:0] backend_mem_xlate_resp_tag;
    wire [63:0] backend_mem_xlate_resp_paddr;
    wire backend_mem_xlate_resp_access_fault;
    wire backend_mem_xlate_resp_page_fault;
    wire backend_mem_resp_valid;
    wire backend_mem_resp_ready;
    wire [`OPENRV64_LSU_TAG_WIDTH-1:0] backend_mem_resp_tag;
    wire backend_mem_store_done_valid;
    wire backend_mem_store_done_ready;
    wire [`OPENRV64_LSU_TAG_WIDTH-1:0] backend_mem_store_done_tag;
    wire [63:0] backend_mem_resp_paddr;
    wire backend_mem_lock;
    wire backend_mem_write;
    wire [63:0] backend_mem_addr;
    wire [63:0] backend_mem_wdata;
    wire [7:0] backend_mem_wstrb;
    wire [63:0] backend_mem_rdata;
    wire backend_mem_access_fault;
    wire backend_mem_page_fault;
    wire unused_legacy_lsu_ready;
    wire [`RV64_XLEN-1:0] unused_legacy_lsu_rdata;
    wire unused_legacy_lsu_access_fault;
    wire unused_legacy_lsu_page_fault;
    wire backend_mem_access;
    wire [63:0] backend_mem_effective_addr;
    wire [2:0] backend_mem_size;
    wire backend_mem1_valid;
    wire [`OPENRV64_LSU_TAG_WIDTH-1:0] backend_mem1_tag;
    wire backend_mem1_lock;
    wire backend_mem1_write;
    wire [63:0] backend_mem1_addr;
    wire [63:0] backend_mem1_wdata;
    wire [7:0] backend_mem1_wstrb;
    wire backend_mem1_access;
    wire [63:0] backend_mem1_effective_addr;
    wire [2:0] backend_mem1_size;
    wire [`OPENRV64_EXEC_PIPE_COUNT-1:0] backend_issue_valid;
    wire [2:0] backend_complete_valid;
    wire [31:0] backend_write_busy;
    wire backend_barrier;
    localparam integer RETIRE_COUNT_WIDTH = $clog2(RETIRE_DEPTH + 1);
    localparam integer DISPATCH_COUNT_WIDTH = $clog2(
        ((ENABLE_ISSUE_WINDOW != 0) ? RETIRE_DEPTH : 6) + 1);
    wire [RETIRE_COUNT_WIDTH-1:0] backend_retire_occupancy;
    wire [DISPATCH_COUNT_WIDTH-1:0] backend_dispatch_occupancy;

    openrv64_backend_3p #(
        .RETIRE_DEPTH(RETIRE_DEPTH),
        .PHYS_REG_COUNT(PHYS_REG_COUNT),
        .PHYS_REG_ADDR_WIDTH(PHYS_REG_ADDR_WIDTH),
        .ENABLE_RV64M(ENABLE_RV64M),
        .ENABLE_TRACE(ENABLE_TRACE),
        .COMPLETION_FORWARD_MASK(COMPLETION_FORWARD_MASK),
        .BRANCH_COMPLETION_FORWARD_MASK(BRANCH_COMPLETION_FORWARD_MASK),
        .ENABLE_FULL_FORWARDING(ENABLE_FULL_FORWARDING),
        .RELAX_WAW(RELAX_WAW),
        .RELAX_HAZARDS(RELAX_HAZARDS),
        .FREE_BRANCHES(FREE_BRANCHES),
        .ENABLE_EQ_BRANCH_PAIRING(ENABLE_EQ_BRANCH_PAIRING),
        .ENABLE_ISSUE_WINDOW(ENABLE_ISSUE_WINDOW),
        .ENABLE_SPECULATION_WINDOW(ENABLE_SPECULATION_WINDOW),
        .ISSUE_WINDOW_DEPTH(RETIRE_DEPTH),
        .ENABLE_POSTED_STORES(ENABLE_POSTED_STORES),
        .STORE_QUEUE_DEPTH(STORE_QUEUE_DEPTH),
        .ENABLE_COHERENT_ATOMICS(ENABLE_COHERENT_ATOMICS),
        .STORE_FORWARD_BASE(STORE_FORWARD_BASE),
        .STORE_FORWARD_SIZE(STORE_FORWARD_SIZE),
        .CACHEABLE_BASE(L1D_CACHEABLE_BASE),
        .CACHEABLE_SIZE(L1D_CACHEABLE_SIZE),
        .SPEC_LOAD_BASE(SPEC_LOAD_BASE),
        .SPEC_LOAD_SIZE(SPEC_LOAD_SIZE)
    ) u_backend (
        .clk(clk), .rst_n(rst_n), .flush_i(control_flush),
        .squash_frontend_i(control_redirect),
        .coherent_reservation_clear_i(
            coherent_reservation_clear_i),
        .translation_bypass_i(
            (csr_data_priv_mode == `RV64_PRIV_M) ||
            (csr_satp_mode == `RV64_SATP_MODE_BARE)),
        .decode_valid_i(backend_decode_valid),
        .decode_ready_o(backend_decode_ready),
        .decode_payload_i(backend_decode_payload),
        .decode_uses_rs1_i(decode_uses_rs1),
        .decode_uses_rs2_i(decode_uses_rs2),
        .decode_allocation_id_o(backend_decode_allocation_id),
        .decode_allocation_slot_o(backend_decode_allocation_slot),
        .csr_addr_o(backend_csr_addr), .csr_rdata_i(csr_rdata),
        .csr_valid_i(csr_valid), .csr_writable_i(csr_writable),
        .csr_write_o(backend_csr_write),
        .csr_write_addr_o(backend_csr_write_addr),
        .csr_wdata_o(backend_csr_wdata),
        .mem_valid_o(backend_mem_valid), .mem_ready_i(backend_mem_ready),
        .mem_tag_o(backend_mem_tag),
        .mem_xlate_only_o(backend_mem_xlate_only),
        .mem_physical_o(backend_mem_physical),
        .mem_xlate_valid_o(backend_mem_xlate_valid),
        .mem_xlate_ready_i(backend_mem_xlate_ready),
        .mem_xlate_tag_o(backend_mem_xlate_tag),
        .mem_xlate_write_o(backend_mem_xlate_write),
        .mem_xlate_vaddr_o(backend_mem_xlate_vaddr),
        .mem_xlate_resp_valid_i(backend_mem_xlate_resp_valid),
        .mem_xlate_resp_ready_o(backend_mem_xlate_resp_ready),
        .mem_xlate_resp_tag_i(backend_mem_xlate_resp_tag),
        .mem_xlate_resp_paddr_i(backend_mem_xlate_resp_paddr),
        .mem_xlate_resp_access_fault_i(
            backend_mem_xlate_resp_access_fault),
        .mem_xlate_resp_page_fault_i(
            backend_mem_xlate_resp_page_fault),
        .mem_resp_valid_i(backend_mem_resp_valid),
        .mem_resp_ready_o(backend_mem_resp_ready),
        .mem_resp_tag_i(backend_mem_resp_tag),
        .mem_store_done_valid_i(backend_mem_store_done_valid),
        .mem_store_done_ready_o(backend_mem_store_done_ready),
        .mem_store_done_tag_i(backend_mem_store_done_tag),
        .mem_resp_paddr_i(backend_mem_resp_paddr),
        .mem_error_i(backend_mem_access_fault),
        .mem_page_fault_i(backend_mem_page_fault),
        .mem_access_allowed_i(1'b1),
        .mem_lock_o(backend_mem_lock),
        .mem_write_o(backend_mem_write), .mem_addr_o(backend_mem_addr),
        .mem_wdata_o(backend_mem_wdata), .mem_wstrb_o(backend_mem_wstrb),
        .mem_access_o(backend_mem_access),
        .mem_effective_addr_o(backend_mem_effective_addr),
        .mem_size_o(backend_mem_size), .mem_rdata_i(backend_mem_rdata),
        .mem1_valid_o(backend_mem1_valid),
        .mem1_ready_i(1'b0),
        .mem1_tag_o(backend_mem1_tag),
        .mem1_lock_o(backend_mem1_lock),
        .mem1_write_o(backend_mem1_write),
        .mem1_addr_o(backend_mem1_addr),
        .mem1_wdata_o(backend_mem1_wdata),
        .mem1_wstrb_o(backend_mem1_wstrb),
        .mem1_access_o(backend_mem1_access),
        .mem1_effective_addr_o(backend_mem1_effective_addr),
        .mem1_size_o(backend_mem1_size),
        .irq_pending_i(csr_irq_pending), .irq_cause_i(csr_irq_cause),
        .redirect_valid_o(backend_redirect),
        .redirect_id_o(backend_redirect_id),
        .redirect_target_o(backend_redirect_target),
        .branch_resolved_o(branch_resolved), .branch_taken_o(branch_taken),
        .branch_conditional_o(branch_conditional),
        .branch_id_o(branch_id), .branch_slot_o(branch_slot),
        .branch_pc_o(branch_pc), .branch_instr_o(branch_instr),
        .branch_train_valid_o(branch_train_valid),
        .branch_train_conditional_o(branch_train_conditional),
        .branch_train_taken_o(branch_train_taken),
        .branch_train_pc_o(branch_train_pc),
        .branch_retire_age_valid_o(branch_retire_age_valid),
        .branch_retire_age_addr_o(branch_retire_age_addr),
        .retire_arch_o(backend_retire_arch),
        .retire_count_o(backend_retire_count),
        .exception_o(backend_exception), .halt_o(backend_halt),
        .irq_o(backend_irq), .mret_o(backend_mret), .sret_o(backend_sret),
        .fence_i_o(backend_fence_i), .sfence_vma_o(backend_sfence_vma),
        .cause_o(backend_cause), .retire_pc_o(backend_retire_pc),
        .retire_next_pc_o(backend_retire_next_pc),
        .retire_tval_o(backend_retire_tval),
        .retire_trace_id_o(backend_retire_trace_id),
        .retire_instr_o(backend_retire_instr),
        .retire_rd_o(backend_retire_rd),
        .retire_wdata_o(backend_retire_wdata),
        .issue_valid_o(backend_issue_valid),
        .complete_valid_o(backend_complete_valid),
        .write_busy_o(backend_write_busy),
        .barrier_active_o(backend_barrier),
        .retire_occupancy_o(backend_retire_occupancy),
        .dispatch_occupancy_o(backend_dispatch_occupancy)
    );

    wire [11:0] csr_access_addr = backend_csr_write ?
                                  backend_csr_write_addr : backend_csr_addr;
    wire trap_enter = control_trap || backend_irq;
    wire trap_interrupt = backend_irq;
    wire [63:0] trap_pc = backend_irq ? backend_retire_next_pc :
                                       backend_retire_pc;
    wire [63:0] trap_tval = backend_irq ? 64'd0 : backend_retire_tval;

    wire csr_pmp_instr_allow;
    wire csr_pmp_data_allow;
    wire csr_pmp_bus_allow;
    wire core_mem_valid;
    wire core_mem_ready;
    wire core_mem_write;
    wire [63:0] core_mem_addr;
    wire [63:0] core_mem_pmp_addr;
    wire [63:0] core_mem_wdata;
    wire [7:0] core_mem_wstrb;
    wire [`RV64_PRIV_WIDTH-1:0] core_mem_priv;
    wire [2:0] core_mem_size;
    wire core_mem_exec;
    wire core_mem_error;
    wire core_pmp_valid;
    wire [63:0] core_pmp_addr;
    wire [`RV64_PRIV_WIDTH-1:0] core_pmp_priv;
    wire [2:0] core_pmp_size;
    wire core_pmp_write;
    wire core_pmp_exec;

    wire [1:0] cmu_issue_count =
        {1'b0, backend_issue_valid[0]} +
        {1'b0, backend_issue_valid[1]} +
        {1'b0, backend_issue_valid[2]};
    wire cmu_fetch_req_fire = use_ccx_bus ?
        (fetch_pipe_req_valid && fetch_pipe_req_ready) :
        (fetch_mem_valid && fetch_mem_ready);
    wire cmu_fetch_resp_fire = use_ccx_bus ?
        (fetch_pipe_resp_valid && fetch_pipe_resp_ready) :
        (fetch_mem_valid && fetch_mem_ready);
    wire cmu_fetch_cancel = use_ccx_bus ? fetch3_cancel :
                            (fetch_invalidate || control_redirect);
    wire cmu_lsu_req_fire = backend_mem_valid && backend_mem_ready;
    wire cmu_lsu_resp_fire =
        (backend_mem_resp_valid && backend_mem_resp_ready) ||
        (backend_mem_store_done_valid && backend_mem_store_done_ready);
    wire [`OPENRV64_CMU_EVENT_COUNT-1:0] cmu_perf_events = {
        1'b0,                                      // 37 lost issue slot 2
        1'b0,                                      // 36 lost issue slot 1
        1'b0,                                      // 35 lost issue slot 0
        1'b0,                                      // 34 completed behind head
        1'b0,                                      // 33 retire head incomplete
        cmu_lsu_req_fire && backend_mem_write,      // 32 store request
        1'b0,                                      // 31 L1D load miss
        1'b0,                                      // 30 L1D load hit
        1'b0,                                      // 29 demand waits prefetch
        1'b0,                                      // 28 useful L1I prefetch
        1'b0,                                      // 27 L1I prefetch launch
        1'b0,                                      // 26 L1I demand miss
        1'b0,                                      // 25 L1I demand hit
        1'b0,                                      // 24 LSU outstanding
        backend_mem_valid && !backend_mem_ready,   // 23 LSU request wait
        cmu_lsu_resp_fire,                         // 22 LSU response
        cmu_lsu_req_fire,                          // 21 LSU request
        cmu_fetch_cancel,                          // 20 fetch cancellation
        cmu_fetch_resp_fire,                       // 19 fetch response
        cmu_fetch_req_fire,                        // 18 fetch request
        bp_target_mispredict,                      // 17 target mispredict
        backend_redirect,                          // 16 direction mispredict
        1'b0,                                      // 15 redirect recovery
        control_redirect,                          // 14 redirect
        1'b0,                                      // 13 pipe busy stall
        backend_barrier && (backend_dispatch_occupancy != 0),
                                                    // 12 barrier stall
        1'b0,                                      // 11 RAW stall
        (backend_dispatch_occupancy == 0),          // 10 dispatch empty
        !(|fetch_decode_valid),                     //  9 frontend empty
        (backend_retire_count == 0),                //  8 zero retire
        (cmu_issue_count == 0),                     //  7 zero issue
        (backend_retire_count >= 2'd3),             //  6 retire lane 2
        (backend_retire_count >= 2'd2),             //  5 retire lane 1
        (backend_retire_count >= 2'd1),             //  4 retire lane 0
        (cmu_issue_count >= 2'd3),                  //  3 issue lane 2
        (cmu_issue_count >= 2'd2),                  //  2 issue lane 1
        (cmu_issue_count >= 2'd1),                  //  1 issue lane 0
        1'b0                                       //  0 cycle (CMU-owned)
    };

    openrv64_rv64i_csrs #(
        .ENABLE_RV64M(ENABLE_RV64M), .ENABLE_RV64A(ENABLE_RV64A),
        .HPM_COUNTERS(HPM_COUNTERS),
        .HART_ID(HART_ID)
    ) u_csrs (
        .clk(clk), .rst_n(rst_n), .csr_addr_i(csr_access_addr),
        .csr_rdata_o(csr_rdata), .csr_valid_o(csr_valid),
        .csr_writable_o(csr_writable), .csr_write_i(backend_csr_write),
        .csr_wdata_i(backend_csr_wdata), .trap_enter_i(trap_enter),
        .trap_interrupt_i(trap_interrupt), .trap_cause_i(backend_cause),
        .trap_pc_i(trap_pc), .trap_tval_i(trap_tval),
        .mret_i(backend_mret), .sret_i(backend_sret),
        .retire_count_i(backend_retire_count),
        .perf_events_i(cmu_perf_events),
        .irq_software_i(irq_m_software), .irq_timer_i(irq_m_timer),
        .irq_external_i(irq_m_external),
        .irq_s_software_i(irq_s_software), .irq_s_timer_i(irq_s_timer),
        .irq_s_external_i(irq_s_external),
        .irq_pending_o(csr_irq_pending), .irq_cause_o(csr_irq_cause),
        .trap_vector_o(csr_trap_vector), .trap_to_s_o(csr_trap_to_s),
        .mepc_o(csr_mepc), .sepc_o(csr_sepc),
        .priv_mode_o(csr_priv_mode), .data_priv_mode_o(csr_data_priv_mode),
        .sret_allowed_o(csr_sret_allowed),
        .sfence_vma_allowed_o(csr_sfence_vma_allowed),
        .satp_mode_o(csr_satp_mode), .satp_asid_o(csr_satp_asid),
        .satp_root_ppn_o(csr_satp_root_ppn),
        .status_sum_o(csr_status_sum), .status_mxr_o(csr_status_mxr),
        .pmp_instr_addr_i(use_ccx_bus ? fetch3_stream_pc :
                          fetch_mem_exec_addr),
        .pmp_instr_allow_o(csr_pmp_instr_allow),
        .pmp_data_valid_i(backend_mem_access),
        .pmp_data_addr_i(backend_mem_effective_addr),
        .pmp_data_size_i(backend_mem_size),
        .pmp_data_write_i(backend_mem_write),
        .pmp_data_allow_o(csr_pmp_data_allow),
        .pmp_bus_valid_i(core_pmp_valid), .pmp_bus_addr_i(core_pmp_addr),
        .pmp_bus_size_i(core_pmp_size), .pmp_bus_write_i(core_pmp_write),
        .pmp_bus_exec_i(core_pmp_exec),
        .pmp_bus_priv_mode_i(core_pmp_priv),
        .pmp_bus_allow_o(csr_pmp_bus_allow)
    );

    openrv64_except_vector #(.RESET_VECTOR(RESET_VECTOR)) u_vector (
        .reset_i(reset_pending_q), .trap_i(control_trap),
        .irq_i(backend_irq), .mret_i(backend_mret), .sret_i(backend_sret),
        .restart_i(control_restart), .redirect_i(1'b0),
        .trap_vector_i(csr_trap_vector), .mepc_i(csr_mepc),
        .sepc_i(csr_sepc), .restart_target_i(backend_retire_next_pc),
        .redirect_target_i(64'd0), .vector_valid_o(except_vector_valid),
        .vector_target_o(except_vector_target)
    );

    wire fetch_bus_ready;
    wire fetch_bus_access_fault;
    wire fetch_bus_page_fault;
    assign fetch_mem_ready = fetch_bus_ready;
    assign fetch_mem_fault = fetch_bus_access_fault;
    assign fetch_mem_page_fault = fetch_bus_page_fault;

    assign core_mem_ready = mem_ready;
    assign core_mem_error = mem_error;
    assign mem_valid = core_mem_valid;
    assign mem_write = core_mem_write;
    assign mem_addr = core_mem_addr;
    assign mem_wdata = core_mem_wdata;
    assign mem_wstrb = core_mem_wstrb;

    openrv64_core_bus #(
        .BUS_CONFIG(BUS_CONFIG),
        .ENABLE_MAGIC_MEMORY(ENABLE_MAGIC_MEMORY),
        .ENABLE_L1I(ENABLE_L1I),
        .ENABLE_L1D(ENABLE_L1D),
        .ENABLE_L1D_COHERENCE_PROBES(
            ENABLE_L1D_COHERENCE_PROBES),
        .ENABLE_COHERENT_ATOMICS(ENABLE_COHERENT_ATOMICS),
        .L1I_CACHE_BYTES(L1I_CACHE_BYTES),
        .L1D_CACHE_BYTES(L1D_CACHE_BYTES),
        .L1D_CACHEABLE_BASE(L1D_CACHEABLE_BASE),
        .L1D_CACHEABLE_SIZE(L1D_CACHEABLE_SIZE),
        .L1D_FILL_BUFFER_LINES(L1D_FILL_BUFFER_LINES),
        .L1D_DEMAND_MSHRS(L1D_DEMAND_MSHRS),
        .L1D_STORE_BUFFER_LINES(L1D_STORE_BUFFER_LINES),
        .L1D_PREFETCH_ENABLE(L1D_PREFETCH_ENABLE),
        .L1D_PREFETCH_MAX_STRIDE_LINES(
            L1D_PREFETCH_MAX_STRIDE_LINES),
        .L1D_PREFETCH_STREAMS(L1D_PREFETCH_STREAMS),
        .L1D_PREFETCH_DISTANCE(L1D_PREFETCH_DISTANCE),
        .L1D_PREFETCH_ADAPTIVE_ENABLE(
            L1D_PREFETCH_ADAPTIVE_ENABLE),
        .L1D_PREFETCH_MAX_DISTANCE(L1D_PREFETCH_MAX_DISTANCE),
        .L1D_PREFETCH_QUEUE_LINES(L1D_PREFETCH_QUEUE_LINES),
        .L1D_PREFETCH_OUTSTANDING(L1D_PREFETCH_OUTSTANDING),
        .L1D_PREFETCH_DEMAND_RESERVE(
            L1D_PREFETCH_DEMAND_RESERVE),
        .L1I_FILL_BUFFER_LINES(L1I_FILL_BUFFER_LINES),
        .L1I_DEMAND_MSHRS(L1I_DEMAND_MSHRS),
        .L2_TLB_ENTRIES(L2_TLB_ENTRIES),
        .L2_TLB_WAYS(L2_TLB_WAYS),
        .PTW_PTE_CACHE_ENTRIES(PTW_PTE_CACHE_ENTRIES),
        .PTW_CCX_TIMEOUT_CYCLES(PTW_CCX_TIMEOUT_CYCLES),
        .HART_ID(HART_ID)
    ) u_bus (
        .clk(clk), .rst_n(rst_n), .fetch_valid_i(fetch_mem_valid),
        .fetch_cancel_i(use_ccx_bus ? fetch3_cancel :
                        (fetch_invalidate || control_redirect)),
        .fetch_addr_i(fetch_mem_exec_addr), .fetch_priv_i(csr_priv_mode),
        .fetch_vm_mode_i((csr_priv_mode == `RV64_PRIV_M) ?
                         `RV64_SATP_MODE_BARE : csr_satp_mode),
        .fetch_asid_i(csr_satp_asid), .fetch_root_ppn_i(csr_satp_root_ppn),
        .fetch_sum_i(csr_status_sum), .fetch_mxr_i(csr_status_mxr),
        .fetch_ready_o(fetch_bus_ready), .fetch_rdata_o(fetch_mem_rdata),
        .fetch_access_fault_o(fetch_bus_access_fault),
        .fetch_page_fault_o(fetch_bus_page_fault),
        .fetch_pipe_req_valid_i(fetch_pipe_req_valid),
        .fetch_pipe_req_ready_o(fetch_pipe_req_ready),
        .fetch_pipe_req_addr_i(fetch_pipe_req_addr),
        .fetch_pipe_req_stash_i(fetch_pipe_req_stash),
        .fetch_pipe_req_demand_i(fetch_pipe_req_demand),
        .fetch_pipe_req_priv_i(csr_priv_mode),
        .fetch_pipe_req_vm_mode_i((csr_priv_mode == `RV64_PRIV_M) ?
                                  `RV64_SATP_MODE_BARE : csr_satp_mode),
        .fetch_pipe_req_asid_i(csr_satp_asid),
        .fetch_pipe_req_root_ppn_i(csr_satp_root_ppn),
        .fetch_pipe_req_sum_i(csr_status_sum),
        .fetch_pipe_req_mxr_i(csr_status_mxr),
        .fetch_pipe_resp_valid_o(fetch_pipe_resp_valid),
        .fetch_pipe_resp_ready_i(fetch_pipe_resp_ready),
        .fetch_pipe_resp_addr_o(fetch_pipe_resp_addr),
        .fetch_pipe_resp_data_o(fetch_pipe_resp_data),
        .fetch_pipe_resp_access_fault_o(fetch_pipe_resp_access_fault),
        .fetch_pipe_resp_page_fault_o(fetch_pipe_resp_page_fault),
        .fetch_pipe_resp_stash_o(fetch_pipe_resp_stash),
        .fetch_pipe_resp_demand_o(fetch_pipe_resp_demand),
        .fetch_pipe_cancel_stash_i(fetch3_cancel_stash),
        .l1d_probe_valid_i(l1d_probe_valid_i),
        .l1d_probe_ready_o(l1d_probe_ready_o),
        .l1d_probe_addr_i(l1d_probe_addr_i),
        .lsu_valid_i(1'b0), .lsu_lock_i(1'b0), .lsu_write_i(1'b0),
        .lsu_addr_i(64'd0), .lsu_wdata_i(64'd0),
        .lsu_wstrb_i(8'd0), .lsu_size_i(3'd0),
        .lsu_priv_i(csr_data_priv_mode),
        .lsu_vm_mode_i((csr_data_priv_mode == `RV64_PRIV_M) ?
                       `RV64_SATP_MODE_BARE : csr_satp_mode),
        .lsu_asid_i(csr_satp_asid), .lsu_root_ppn_i(csr_satp_root_ppn),
        .lsu_sum_i(csr_status_sum), .lsu_mxr_i(csr_status_mxr),
        .lsu_ready_o(unused_legacy_lsu_ready),
        .lsu_rdata_o(unused_legacy_lsu_rdata),
        .lsu_access_fault_o(unused_legacy_lsu_access_fault),
        .lsu_page_fault_o(unused_legacy_lsu_page_fault),
        .lsu_pipe_req_valid_i(backend_mem_valid &&
                              !translation_barrier_busy),
        .lsu_pipe_req_ready_o(backend_mem_bus_ready),
        .lsu_pipe_req_tag_i(backend_mem_tag),
        .lsu_pipe_req_xlate_only_i(backend_mem_xlate_only),
        .lsu_pipe_req_physical_i(backend_mem_physical),
        .lsu_pipe_req_lock_i(backend_mem_lock),
        .lsu_pipe_req_write_i(backend_mem_write),
        .lsu_pipe_req_addr_i(backend_mem_addr),
        .lsu_pipe_req_wdata_i(backend_mem_wdata),
        .lsu_pipe_req_wstrb_i(backend_mem_wstrb),
        .lsu_pipe_req_size_i(backend_mem_size),
        .lsu_pipe_req_priv_i(csr_data_priv_mode),
        .lsu_pipe_req_vm_mode_i((csr_data_priv_mode == `RV64_PRIV_M) ?
                                `RV64_SATP_MODE_BARE : csr_satp_mode),
        .lsu_pipe_req_asid_i(csr_satp_asid),
        .lsu_pipe_req_root_ppn_i(csr_satp_root_ppn),
        .lsu_pipe_req_sum_i(csr_status_sum),
        .lsu_pipe_req_mxr_i(csr_status_mxr),
        .lsu_pipe_req_translation_hit_o(),
        .lsu_pipe_req_translation_paddr_o(),
        .lsu_pipe_req_translation_page_fault_o(),
        .lsu_pipe_cancel_i(control_flush),
        .lsu_pipe_resp_valid_o(backend_mem_resp_valid),
        .lsu_pipe_resp_ready_i(backend_mem_resp_ready),
        .lsu_pipe_resp_tag_o(backend_mem_resp_tag),
        .lsu_pipe_store_done_valid_o(backend_mem_store_done_valid),
        .lsu_pipe_store_done_ready_i(backend_mem_store_done_ready),
        .lsu_pipe_store_done_tag_o(backend_mem_store_done_tag),
        .lsu_pipe_resp_paddr_o(backend_mem_resp_paddr),
        .lsu_pipe_resp_rdata_o(backend_mem_rdata),
        .lsu_pipe_resp_access_fault_o(backend_mem_access_fault),
        .lsu_pipe_resp_page_fault_o(backend_mem_page_fault),
        .lsu_xlate_req_valid_i(backend_mem_xlate_valid &&
                               !translation_barrier_busy),
        .lsu_xlate_req_ready_o(backend_mem_xlate_bus_ready),
        .lsu_xlate_req_tag_i(backend_mem_xlate_tag),
        .lsu_xlate_req_write_i(backend_mem_xlate_write),
        .lsu_xlate_req_vaddr_i(backend_mem_xlate_vaddr),
        .lsu_xlate_req_priv_i(csr_data_priv_mode),
        .lsu_xlate_req_vm_mode_i(
            (csr_data_priv_mode == `RV64_PRIV_M) ?
            `RV64_SATP_MODE_BARE : csr_satp_mode),
        .lsu_xlate_req_asid_i(csr_satp_asid),
        .lsu_xlate_req_root_ppn_i(csr_satp_root_ppn),
        .lsu_xlate_req_sum_i(csr_status_sum),
        .lsu_xlate_req_mxr_i(csr_status_mxr),
        .lsu_xlate_resp_valid_o(backend_mem_xlate_resp_valid),
        .lsu_xlate_resp_ready_i(backend_mem_xlate_resp_ready),
        .lsu_xlate_resp_tag_o(backend_mem_xlate_resp_tag),
        .lsu_xlate_resp_paddr_o(backend_mem_xlate_resp_paddr),
        .lsu_xlate_resp_access_fault_o(
            backend_mem_xlate_resp_access_fault),
        .lsu_xlate_resp_page_fault_o(
            backend_mem_xlate_resp_page_fault),
        .tlbi_i(backend_sfence_vma || backend_satp_write),
        .tlbi_busy_o(translation_barrier_busy),
        .icache_invalidate_i(backend_fence_i),
        .icache_prefetch_valid_i(l1i_branch_prefetch_valid &&
                                 !translation_barrier_busy),
        .icache_prefetch_taken_addr_i(l1i_prefetch_first_addr),
        .icache_prefetch_fallthrough_addr_i(
            l1i_prefetch_second_addr),
        .icache_age_valid_i(branch_retire_age_valid),
        .icache_age_addr_i(branch_retire_age_addr),
        .req_valid_o(core_mem_valid),
        .req_ready_i(core_mem_ready), .req_write_o(core_mem_write),
        .req_addr_o(core_mem_addr), .req_pmp_addr_o(core_mem_pmp_addr),
        .req_priv_o(core_mem_priv), .req_size_o(core_mem_size),
        .req_exec_o(core_mem_exec), .req_wdata_o(core_mem_wdata),
        .req_wstrb_o(core_mem_wstrb), .req_rdata_i(mem_rdata),
        .req_error_i(core_mem_error),
        .fetch_next_valid_i(fetch_mem_next_valid),
        .fetch_next_addr_i(pc_q),
        .pmp_valid_o(core_pmp_valid), .pmp_addr_o(core_pmp_addr),
        .pmp_priv_o(core_pmp_priv), .pmp_size_o(core_pmp_size),
        .pmp_write_o(core_pmp_write), .pmp_exec_o(core_pmp_exec),
        .pmp_allow_i(csr_pmp_bus_allow),
        .ccx_req_valid_o(ccx_req_valid),
        .ccx_req_ready_i(ccx_req_ready),
        .ccx_req_hart_id_o(ccx_req_hart_id),
        .ccx_req_txn_id_o(ccx_req_txn_id),
        .ccx_req_source_id_o(ccx_req_source_id),
        .ccx_req_op_o(ccx_req_op),
        .ccx_req_lock_o(ccx_req_lock),
        .ccx_req_order_o(ccx_req_order),
        .ccx_req_kind_o(ccx_req_kind),
        .ccx_req_attr_o(ccx_req_attr),
        .ccx_req_size_o(ccx_req_size),
        .ccx_req_addr_o(ccx_req_addr),
        .ccx_req_burst_len_o(ccx_req_burst_len),
        .ccx_wdata_valid_o(ccx_wdata_valid),
        .ccx_wdata_ready_i(ccx_wdata_ready),
        .ccx_wdata_hart_id_o(ccx_wdata_hart_id),
        .ccx_wdata_txn_id_o(ccx_wdata_txn_id),
        .ccx_wdata_source_id_o(ccx_wdata_source_id),
        .ccx_wdata_beat_index_o(ccx_wdata_beat_index),
        .ccx_wdata_last_o(ccx_wdata_last),
        .ccx_wdata_o(ccx_wdata),
        .ccx_wstrb_o(ccx_wstrb),
        .ccx_resp_valid_i(ccx_resp_valid),
        .ccx_resp_ready_o(ccx_resp_ready),
        .ccx_resp_hart_id_i(ccx_resp_hart_id),
        .ccx_resp_txn_id_i(ccx_resp_txn_id),
        .ccx_resp_source_id_i(ccx_resp_source_id),
        .ccx_resp_beat_index_i(ccx_resp_beat_index),
        .ccx_resp_last_i(ccx_resp_last),
        .ccx_resp_rdata_i(ccx_resp_rdata),
        .ccx_resp_error_i(ccx_resp_error),
        .ccx_resp_sc_success_i(ccx_resp_sc_success),
        .m_axi_arid_o(m_axi_arid), .m_axi_araddr_o(m_axi_araddr),
        .m_axi_arlen_o(m_axi_arlen), .m_axi_arsize_o(m_axi_arsize),
        .m_axi_arburst_o(m_axi_arburst), .m_axi_arlock_o(m_axi_arlock),
        .m_axi_arcache_o(m_axi_arcache), .m_axi_arprot_o(m_axi_arprot),
        .m_axi_arqos_o(m_axi_arqos), .m_axi_arvalid_o(m_axi_arvalid),
        .m_axi_arready_i(m_axi_arready), .m_axi_rid_i(m_axi_rid),
        .m_axi_rdata_i(m_axi_rdata), .m_axi_rresp_i(m_axi_rresp),
        .m_axi_rlast_i(m_axi_rlast), .m_axi_rvalid_i(m_axi_rvalid),
        .m_axi_rready_o(m_axi_rready), .m_axi_awid_o(m_axi_awid),
        .m_axi_awaddr_o(m_axi_awaddr), .m_axi_awlen_o(m_axi_awlen),
        .m_axi_awsize_o(m_axi_awsize), .m_axi_awburst_o(m_axi_awburst),
        .m_axi_awlock_o(m_axi_awlock), .m_axi_awcache_o(m_axi_awcache),
        .m_axi_awprot_o(m_axi_awprot), .m_axi_awqos_o(m_axi_awqos),
        .m_axi_awvalid_o(m_axi_awvalid), .m_axi_awready_i(m_axi_awready),
        .m_axi_wdata_o(m_axi_wdata), .m_axi_wstrb_o(m_axi_wstrb_axi),
        .m_axi_wlast_o(m_axi_wlast), .m_axi_wvalid_o(m_axi_wvalid),
        .m_axi_wready_i(m_axi_wready), .m_axi_bid_i(m_axi_bid),
        .m_axi_bresp_i(m_axi_bresp), .m_axi_bvalid_i(m_axi_bvalid),
        .m_axi_bready_o(m_axi_bready)
    );

    assign backend_mem_ready =
        backend_mem_bus_ready && !translation_barrier_busy;
    assign backend_mem_xlate_ready =
        backend_mem_xlate_bus_ready && !translation_barrier_busy;

    assign dbg_pc = dbg_pc_q;
    assign dbg_instr = dbg_instr_q;
    assign dbg_halted = halted_q;

    wire retire_event = (|backend_retire_arch) || backend_exception ||
                        backend_halt;
    wire [4:0] trace_valid_raw = {
        retire_event, backend_mem_valid, |backend_issue_valid,
        |backend_decode_valid, |fetch_decode_valid};
    wire [4:0] trace_advance_raw = {
        retire_event, backend_mem_valid && backend_mem_ready,
        |backend_issue_valid,
        |(backend_decode_valid & backend_decode_ready),
        |(fetch_decode_valid & fetch_decode_ready)};
    wire [4:0] trace_flush_raw = {control_flush, control_flush,
                                  control_flush, control_flush,
                                  fetch_invalidate || control_redirect};
    wire [7:0] trace_events_raw = {
        reset_pending_q,
        backend_halt,
        control_restart,
        backend_sret,
        backend_mret,
        backend_irq,
        control_trap,
        control_redirect
    };
    wire [7:0] trace_stall_causes_raw;
    assign trace_stall_causes_raw = {
        backend_barrier,
        (|fetch_decode_valid) && !(|fetch_decode_ready),
        (|backend_issue_valid) == 1'b0 &&
            (backend_dispatch_occupancy != 0),
        backend_mem_valid && !backend_mem_ready,
        use_ccx_bus ? (fetch_pipe_req_valid && !fetch_pipe_req_ready) :
                      (fetch_mem_valid && !fetch_mem_ready),
        (backend_dispatch_occupancy != 0) && (|backend_write_busy),
        (backend_dispatch_occupancy != 0) && (|backend_write_busy),
        (backend_dispatch_occupancy != 0) && (|backend_write_busy)
    };

    assign trace_cycle = ENABLE_TRACE ? trace_cycle_q : 64'd0;
    assign trace_valid = ENABLE_TRACE ? trace_valid_raw : 5'd0;
    assign trace_advance = ENABLE_TRACE ? trace_advance_raw : 5'd0;
    assign trace_flush = ENABLE_TRACE ? trace_flush_raw : 5'd0;
    assign trace_stall = ENABLE_TRACE ?
        (trace_valid_raw & ~trace_advance_raw & ~trace_flush_raw) : 5'd0;
    assign trace_ids = ENABLE_TRACE ? {
        backend_retire_trace_id, 64'd0, 64'd0,
        fetch_decode_trace[0 +: 64], fetch_decode_trace[0 +: 64]
    } : 320'd0;
    assign trace_pcs = ENABLE_TRACE ? {
        backend_retire_pc, backend_mem_effective_addr, 64'd0,
        decode_pc0, decode_pc0
    } : 320'd0;
    assign trace_instrs = ENABLE_TRACE ? {
        backend_retire_instr, 32'd0, 32'd0, instr0, instr0
    } : 160'd0;
    assign trace_events = ENABLE_TRACE ? trace_events_raw : 8'd0;
    assign trace_stall_causes = ENABLE_TRACE ?
                               trace_stall_causes_raw : 8'd0;
    assign trace_retire_valid = ENABLE_TRACE && retire_event;
    assign trace_retire_arch = ENABLE_TRACE && (|backend_retire_arch);
    assign trace_retire_exception = ENABLE_TRACE && backend_exception;
    assign trace_retire_cause = ENABLE_TRACE ? backend_cause : 5'd0;
    assign trace_retire_next_pc = ENABLE_TRACE ?
                                  backend_retire_next_pc : 64'd0;
    assign trace_retire_rd_write = ENABLE_TRACE &&
                                   (|backend_retire_arch) &&
                                   (backend_retire_rd != `RV64_REG_X0);
    assign trace_retire_rd = ENABLE_TRACE ? backend_retire_rd : 5'd0;
    assign trace_retire_wdata = ENABLE_TRACE ? backend_retire_wdata : 64'd0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pc_q <= RESET_VECTOR;
            trace_cycle_q <= 64'd0;
            trace_next_id_q <= 64'd1;
            dbg_pc_q <= RESET_VECTOR;
            dbg_instr_q <= `RV64_INSTR_NOP;
            halted_q <= 1'b0;
            reset_pending_q <= 1'b1;
        end else begin
            reset_pending_q <= 1'b0;
            if (except_vector_valid)
                pc_q <= except_vector_target;
            else if (control_redirect)
                pc_q <= backend_redirect_target;
            else if (bp_predict_redirect)
                pc_q <= bp_predict_target;
            else if (use_ccx_bus && (frontend_decode_count != 0))
                pc_q <= fetch3_stream_pc +
                        ({62'd0, frontend_decode_count} << 2);
            else if (!use_ccx_bus && fetch_pc_valid)
                pc_q <= pc_q + (pc_q[2] ? 64'd4 : 64'd8);

            if (ENABLE_TRACE) begin
                trace_cycle_q <= trace_cycle_q + 64'd1;
                if (use_ccx_bus && (frontend_decode_count != 0))
                    trace_next_id_q <= trace_next_id_q +
                                       frontend_decode_count;
                else if (!use_ccx_bus && fetch_pc_valid)
                    trace_next_id_q <= trace_next_id_q +
                                       (pc_q[2] ? 64'd1 : 64'd2);
            end

            if (retire_event) begin
                dbg_pc_q <= backend_retire_pc;
                dbg_instr_q <= backend_retire_instr;
            end
            if (backend_halt)
                halted_q <= 1'b1;
        end
    end

    wire unused_configuration = |{
        fetch_redirect_replay, backend_redirect_id, csr_trap_to_s,
        csr_pmp_instr_allow, csr_pmp_data_allow,
        backend_complete_valid, backend_retire_occupancy
    };

endmodule
