`timescale 1ns/1ps
`include "core/backend/backend-defs.v"
`include "core/bus/bus-defs.v"
`include "core/isa/rv64-i.v"

module tb_lsq;
    localparam integer IDW = `OPENRV64_INSTR_ID_WIDTH;
    localparam integer TAGW = `OPENRV64_LSU_TAG_WIDTH;
    localparam integer METAW = 8;

    logic clk, rst_n, flush, squash_younger, translation_bypass;
    logic [IDW-1:0] squash_id;
    logic l_valid, l_immediate, l_input_fault;
    wire l_ready;
    logic [IDW-1:0] l_id;
    logic [2:0] l_slot, l_size;
    logic [METAW-1:0] l_meta;
    logic [63:0] l_vaddr;
    logic s_valid, s_immediate, s_input_fault, s_atomic;
    wire s_ready;
    logic [IDW-1:0] s_id;
    logic [2:0] s_slot, s_size;
    logic [METAW-1:0] s_meta;
    logic [63:0] s_vaddr, s_wdata;
    logic [7:0] s_wstrb;
    logic head_valid;
    logic [IDW-1:0] head_id;
    logic [2:0] head_slot;

    wire atomic_start_valid, atomic_start_allowed;
    wire [TAGW-1:0] atomic_start_tag;
    wire [IDW-1:0] atomic_start_id;
    wire [2:0] atomic_start_slot;
    wire [METAW-1:0] atomic_start_meta;
    logic atomic_active, atomic_irrevocable, atomic_done;
    logic [TAGW-1:0] atomic_tag;

    wire xlate_valid, xlate_write;
    logic xlate_ready;
    wire [TAGW-1:0] xlate_tag;
    wire [63:0] xlate_vaddr;
    logic xlate_resp_valid, xlate_resp_access_fault;
    logic xlate_resp_page_fault;
    wire xlate_resp_ready;
    logic [TAGW-1:0] xlate_resp_tag;
    logic [63:0] xlate_resp_paddr;

    wire req_valid, req_write;
    logic req_ready;
    wire [TAGW-1:0] req_tag;
    wire [63:0] req_addr, req_vaddr, req_wdata;
    wire [2:0] req_size;
    wire [7:0] req_wstrb;
    logic resp_valid, resp_access_fault, resp_page_fault;
    wire resp_ready;
    logic [TAGW-1:0] resp_tag;
    logic [63:0] resp_paddr, resp_rdata;
    logic store_done_valid;
    logic [TAGW-1:0] store_done_tag;
    wire store_done_ready;
    wire result_valid, result_access_fault, result_page_fault;
    wire result_store, store_pending;
    logic result_ready;
    wire [IDW-1:0] result_id;
    wire [2:0] result_slot;
    wire [METAW-1:0] result_meta;
    wire [63:0] result_rdata;

    openrv64_lsq #(
        .RETIRE_SLOT_WIDTH(3),
        .META_WIDTH(METAW),
        .LOAD_QUEUE_DEPTH(2),
        .STORE_QUEUE_DEPTH(2),
        .TAG_WIDTH(TAGW),
        .CACHEABLE_BASE(64'h0),
        .CACHEABLE_SIZE(64'h1_0000)
    ) dut (
        .clk(clk), .rst_n(rst_n), .flush_i(flush),
        .squash_younger_i(squash_younger), .squash_id_i(squash_id),
        .translation_bypass_i(translation_bypass),
        .load_alloc_valid_i(l_valid), .load_alloc_ready_o(l_ready),
        .load_alloc_id_i(l_id), .load_alloc_slot_i(l_slot),
        .load_alloc_meta_i(l_meta), .load_alloc_immediate_i(l_immediate),
        .load_alloc_access_fault_i(l_input_fault),
        .load_alloc_vaddr_i(l_vaddr), .load_alloc_size_i(l_size),
        .store_alloc_valid_i(s_valid), .store_alloc_ready_o(s_ready),
        .store_alloc_id_i(s_id), .store_alloc_slot_i(s_slot),
        .store_alloc_meta_i(s_meta), .store_alloc_immediate_i(s_immediate),
        .store_alloc_access_fault_i(s_input_fault),
        .store_alloc_atomic_i(s_atomic), .store_alloc_vaddr_i(s_vaddr),
        .store_alloc_size_i(s_size), .store_alloc_wdata_i(s_wdata),
        .store_alloc_wstrb_i(s_wstrb),
        .ordered_head_valid_i(head_valid), .ordered_head_id_i(head_id),
        .ordered_head_slot_i(head_slot),
        .atomic_start_valid_o(atomic_start_valid),
        .atomic_start_tag_o(atomic_start_tag),
        .atomic_start_id_o(atomic_start_id),
        .atomic_start_slot_o(atomic_start_slot),
        .atomic_start_meta_o(atomic_start_meta),
        .atomic_start_access_allowed_o(atomic_start_allowed),
        .atomic_active_i(atomic_active), .atomic_tag_i(atomic_tag),
        .atomic_irrevocable_i(atomic_irrevocable),
        .atomic_done_i(atomic_done),
        .xlate_req_valid_o(xlate_valid),
        .xlate_req_ready_i(xlate_ready),
        .xlate_req_tag_o(xlate_tag),
        .xlate_req_write_o(xlate_write),
        .xlate_req_vaddr_o(xlate_vaddr),
        .xlate_resp_valid_i(xlate_resp_valid),
        .xlate_resp_ready_o(xlate_resp_ready),
        .xlate_resp_tag_i(xlate_resp_tag),
        .xlate_resp_paddr_i(xlate_resp_paddr),
        .xlate_resp_access_fault_i(xlate_resp_access_fault),
        .xlate_resp_page_fault_i(xlate_resp_page_fault),
        .req_valid_o(req_valid), .req_ready_i(req_ready),
        .req_tag_o(req_tag), .req_write_o(req_write),
        .req_addr_o(req_addr), .req_vaddr_o(req_vaddr),
        .req_size_o(req_size), .req_wdata_o(req_wdata),
        .req_wstrb_o(req_wstrb),
        .resp_valid_i(resp_valid), .resp_ready_o(resp_ready),
        .resp_tag_i(resp_tag), .resp_paddr_i(resp_paddr),
        .resp_rdata_i(resp_rdata),
        .resp_access_fault_i(resp_access_fault),
        .resp_page_fault_i(resp_page_fault),
        .store_done_valid_i(store_done_valid),
        .store_done_ready_o(store_done_ready),
        .store_done_tag_i(store_done_tag),
        .result_valid_o(result_valid), .result_ready_i(result_ready),
        .result_id_o(result_id), .result_slot_o(result_slot),
        .result_meta_o(result_meta), .result_rdata_o(result_rdata),
        .result_access_fault_o(result_access_fault),
        .result_page_fault_o(result_page_fault),
        .result_store_o(result_store), .store_pending_o(store_pending)
    );

    always #5 clk = ~clk;

    task automatic tick;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    task automatic complete_store(input [TAGW-1:0] tag);
        begin
            store_done_tag = tag;
            store_done_valid = 1'b1;
            #1;
            if (!store_done_ready)
                $fatal(1, "store completion blocked tag=%0d", tag);
            tick();
            store_done_valid = 1'b0;
        end
    endtask

    task automatic reset_dut;
        begin
            rst_n = 1'b0;
            repeat (2) tick();
            rst_n = 1'b1;
            tick();
        end
    endtask

    task automatic alloc_store(
        input [IDW-1:0] id,
        input [2:0] slot,
        input [63:0] addr,
        input [2:0] size,
        input [63:0] data,
        input [7:0] strb
    );
        begin
            s_id = id; s_slot = slot; s_meta = id; s_vaddr = addr;
            s_size = size; s_wdata = data; s_wstrb = strb; s_valid = 1'b1;
            #1;
            if (!s_ready) $fatal(1, "store allocation blocked id=%0d", id);
            tick();
            s_valid = 1'b0;
        end
    endtask

    task automatic alloc_load(
        input [IDW-1:0] id,
        input [2:0] slot,
        input [63:0] addr,
        input [2:0] size
    );
        begin
            l_id = id; l_slot = slot; l_meta = id; l_vaddr = addr;
            l_size = size; l_valid = 1'b1;
            #1;
            if (!l_ready) $fatal(1, "load allocation blocked id=%0d", id);
            tick();
            l_valid = 1'b0;
        end
    endtask

    task automatic take_req(
        input write,
        input [63:0] addr,
        output [TAGW-1:0] tag
    );
        integer n;
        begin
            n = 0;
            while (!req_valid && n < 20) begin tick(); n = n + 1; end
            if (!req_valid) $fatal(1, "request timeout addr=%h", addr);
            if (req_write != write || req_addr != addr)
                $fatal(1,
                    "request mismatch wr=%b/%b addr=%h/%h",
                    req_write, write, req_addr, addr);
            tag = req_tag;
            req_ready = 1'b1;
            tick();
            req_ready = 1'b0;
        end
    endtask

    task automatic take_xlate(
        input write,
        input [63:0] vaddr,
        output [TAGW-1:0] tag
    );
        integer n;
        begin
            n = 0;
            while (!xlate_valid && n < 20) begin tick(); n = n + 1; end
            if (!xlate_valid)
                $fatal(1, "translation request timeout addr=%h", vaddr);
            if (xlate_write != write || xlate_vaddr != vaddr)
                $fatal(1,
                    "translation mismatch wr=%b/%b addr=%h/%h",
                    xlate_write, write, xlate_vaddr, vaddr);
            tag = xlate_tag;
            xlate_ready = 1'b1;
            tick();
            xlate_ready = 1'b0;
        end
    endtask

    task automatic respond_xlate(
        input [TAGW-1:0] tag,
        input [63:0] paddr,
        input access_fault,
        input page_fault
    );
        begin
            xlate_resp_tag = tag;
            xlate_resp_paddr = paddr;
            xlate_resp_access_fault = access_fault;
            xlate_resp_page_fault = page_fault;
            xlate_resp_valid = 1'b1;
            #1;
            if (!xlate_resp_ready)
                $fatal(1, "translation response blocked tag=%0d", tag);
            tick();
            xlate_resp_valid = 1'b0;
            xlate_resp_access_fault = 1'b0;
            xlate_resp_page_fault = 1'b0;
        end
    endtask

    task automatic respond(
        input [TAGW-1:0] tag,
        input [63:0] paddr,
        input [63:0] data,
        input access_fault,
        input page_fault
    );
        begin
            resp_tag = tag; resp_paddr = paddr; resp_rdata = data;
            resp_access_fault = access_fault; resp_page_fault = page_fault;
            resp_valid = 1'b1;
            #1;
            if (!resp_ready) $fatal(1, "response blocked tag=%0d", tag);
            tick();
            resp_valid = 1'b0;
            resp_access_fault = 1'b0;
            resp_page_fault = 1'b0;
        end
    endtask

    task automatic take_result(
        input [IDW-1:0] id,
        input is_store,
        input [63:0] data,
        input access_fault,
        input page_fault
    );
        integer n;
        begin
            n = 0;
            while (!result_valid && n < 20) begin tick(); n = n + 1; end
            if (!result_valid) $fatal(1, "result timeout id=%0d", id);
            if (result_id != id || result_store != is_store ||
                result_rdata != data ||
                result_access_fault != access_fault ||
                result_page_fault != page_fault)
                $fatal(1,
                    "result mismatch id=%0d/%0d store=%b/%b data=%h/%h fault=%b%b/%b%b",
                    result_id, id, result_store, is_store,
                    result_rdata, data,
                    result_access_fault, result_page_fault,
                    access_fault, page_fault);
            result_ready = 1'b1;
            tick();
            result_ready = 1'b0;
        end
    endtask

    task automatic respond_result(
        input [TAGW-1:0] tag,
        input [63:0] paddr,
        input [63:0] response_data,
        input [IDW-1:0] id,
        input is_store,
        input [63:0] expected_data
    );
        begin
            resp_tag = tag; resp_paddr = paddr;
            resp_rdata = response_data;
            resp_access_fault = 1'b0; resp_page_fault = 1'b0;
            resp_valid = 1'b1; result_ready = 1'b1;
            #1;
            if (!resp_ready || !result_valid || result_id != id ||
                result_store != is_store || result_rdata != expected_data ||
                result_access_fault || result_page_fault)
                $fatal(1,
                    "access response/result mismatch tag=%0d id=%0d/%0d store=%b/%b data=%h/%h",
                    tag, result_id, id, result_store, is_store,
                    result_rdata, expected_data);
            tick();
            resp_valid = 1'b0; result_ready = 1'b0;
        end
    endtask

    reg [TAGW-1:0] st, lt;
    initial begin
        clk = 0; rst_n = 0; flush = 0;
        squash_younger = 0; squash_id = 0;
        translation_bypass = 0;
        l_valid = 0; l_id = 0; l_slot = 0; l_meta = 0;
        l_immediate = 0; l_input_fault = 0; l_vaddr = 0; l_size = 0;
        s_valid = 0; s_id = 0; s_slot = 0; s_meta = 0;
        s_immediate = 0; s_input_fault = 0; s_atomic = 0;
        s_vaddr = 0; s_size = 0; s_wdata = 0; s_wstrb = 0;
        head_valid = 0; head_id = 0; head_slot = 0;
        atomic_active = 0; atomic_tag = 0; atomic_irrevocable = 0;
        atomic_done = 0; xlate_ready = 0; xlate_resp_valid = 0;
        xlate_resp_tag = 0; xlate_resp_paddr = 0;
        xlate_resp_access_fault = 0; xlate_resp_page_fault = 0;
        req_ready = 0; resp_valid = 0; resp_tag = 0;
        store_done_valid = 0; store_done_tag = 0;
        resp_paddr = 0; resp_rdata = 0; resp_access_fault = 0;
        resp_page_fault = 0; result_ready = 0;

        reset_dut();

        // The first untranslated operation probes the D micro-TLB directly
        // from its allocation port. A same-cycle hit is captured into the new
        // LSQ entry without a mandatory queue/readback bubble.
        l_id = IDW'(14);
        l_slot = 3'd6;
        l_meta = 8'd14;
        l_vaddr = 64'h1600;
        l_size = 3'd3;
        l_valid = 1'b1;
        xlate_ready = 1'b1;
        #1;
        if (!l_ready || !xlate_valid || xlate_write ||
            xlate_vaddr != 64'h1600)
            $fatal(1,
                "allocation-time translation absent ready=%b xlate=%b/%b/%h",
                l_ready, xlate_valid, xlate_write, xlate_vaddr);
        lt = xlate_tag;
        xlate_resp_tag = lt;
        xlate_resp_paddr = 64'h2600;
        xlate_resp_valid = 1'b1;
        #1;
        if (!xlate_resp_ready)
            $fatal(1, "allocation-time translation response blocked");
        tick();
        l_valid = 1'b0;
        xlate_ready = 1'b0;
        xlate_resp_valid = 1'b0;
        take_req(1'b0, 64'h2600, lt);
        respond_result(lt, 64'h2600, 64'ha5a5_5a5a_a5a5_5a5a,
                       IDW'(14), 0, 64'ha5a5_5a5a_a5a5_5a5a);

        reset_dut();

        // Bare/identity translation snapshots paddr at allocation and reaches
        // the physical access directly, without a translation-only request.
        translation_bypass = 1'b1;
        alloc_load(IDW'(0), 3'd0, 64'h0800, 3'd3);
        take_req(1'b0, 64'h0800, lt);
        respond_result(lt, 64'h0800, 64'h0123_4567_89ab_cdef,
                       IDW'(0), 0, 64'h0123_4567_89ab_cdef);
        translation_bypass = 1'b0;

        reset_dut();

        // Early store translation, but physical access only at ordered head.
        alloc_store(IDW'(1), 3'd1, 64'h1000, 3'd3,
                    64'hfeed_face_cafe_beef, 8'hff);
        take_xlate(1'b1, 64'h1000, st);
        respond_xlate(st, 64'h2000, 0, 0);
        repeat (2) begin
            tick();
            if (req_valid)
                $fatal(1, "store physically issued before ordered head");
        end
        head_valid = 1; head_id = IDW'(1); head_slot = 3'd1;
        take_req(1'b1, 64'h2000, st);
        // Cacheable stores complete architecturally from request acceptance,
        // before the later L1D response.  Their tag remains occupied until
        // that response returns.
        take_result(IDW'(1), 1, 0, 0, 0);
        if (!store_pending)
            $fatal(1, "accepted posted store was released before response");
        alloc_store(IDW'(2), 3'd2, 64'h1100, 3'd3,
                    64'h1111_2222_3333_4444, 8'hff);
        s_id = IDW'(3); s_slot = 3'd3; s_meta = IDW'(3);
        s_vaddr = 64'h1200; s_size = 3'd3;
        s_wdata = 64'h5555_6666_7777_8888; s_wstrb = 8'hff;
        s_valid = 1'b1;
        #1;
        if (s_ready)
            $fatal(1, "posted store tag was reused before response");
        s_valid = 1'b0;
        complete_store(st);
        #1;
        if (result_valid)
            $fatal(1, "posted store response produced a second result");
        alloc_store(IDW'(3), 3'd3, 64'h1200, 3'd3,
                    64'h5555_6666_7777_8888, 8'hff);
        head_valid = 0;
        flush = 1; tick(); flush = 0;

        reset_dut();

        // Once an ordered atomic starts, it owns the memory path until its
        // real response completes.  Younger LSQ work may allocate, but must
        // not translate or access L1D while the atomic is active.
        translation_bypass = 1'b1;
        s_atomic = 1'b1;
        alloc_store(IDW'(9), 3'd1, 64'h5000, 3'd3,
                    64'h0102_0304_0506_0708, 8'hff);
        s_atomic = 1'b0;
        head_valid = 1'b1;
        head_id = IDW'(9);
        head_slot = 3'd1;
        #1;
        if (!atomic_start_valid || atomic_start_id != IDW'(9))
            $fatal(1, "ordered atomic did not start");
        atomic_tag = atomic_start_tag;
        atomic_active = 1'b1;
        tick();
        alloc_load(IDW'(10), 3'd2, 64'h6000, 3'd3);
        repeat (2) begin
            #1;
            if (req_valid || xlate_valid || atomic_start_valid)
                $fatal(1,
                    "LSQ escaped active atomic req=%b xlate=%b restart=%b",
                    req_valid, xlate_valid, atomic_start_valid);
            tick();
        end
        atomic_done = 1'b1;
        atomic_active = 1'b0;
        tick();
        atomic_done = 1'b0;
        head_valid = 1'b0;
        take_req(1'b0, 64'h6000, lt);
        respond_result(lt, 64'h6000, 64'h8877_6655_4433_2211,
                       IDW'(10), 0, 64'h8877_6655_4433_2211);
        translation_bypass = 1'b0;

        reset_dut();

        // A full architectural flush must retain an already accepted posted
        // store until its independent L1D tag-release response arrives.
        translation_bypass = 1'b1;
        alloc_store(IDW'(4), 3'd4, 64'h1800, 3'd3,
                    64'h0123_4567_89ab_cdef, 8'hff);
        head_valid = 1; head_id = IDW'(4); head_slot = 3'd4;
        take_req(1'b1, 64'h1800, st);
        take_result(IDW'(4), 1, 0, 0, 0);
        head_valid = 0;
        flush = 1; tick(); flush = 0;
        if (!store_pending)
            $fatal(1, "full flush discarded accepted posted store");
        complete_store(st);
        #1;
        if (store_pending || result_valid)
            $fatal(1,
                "post-flush store completion left pending/result state");
        translation_bypass = 1'b0;

        reset_dut();

        // Store tag release and an unrelated load result are independent and
        // may fire together.  The store response must not consume or corrupt
        // the normal result port.
        translation_bypass = 1'b1;
        alloc_store(IDW'(5), 3'd5, 64'h2000, 3'd3,
                    64'h1111_2222_3333_4444, 8'hff);
        head_valid = 1; head_id = IDW'(5); head_slot = 3'd5;
        take_req(1'b1, 64'h2000, st);
        take_result(IDW'(5), 1, 0, 0, 0);
        head_valid = 0;
        alloc_load(IDW'(6), 3'd6, 64'h3000, 3'd3);
        take_req(1'b0, 64'h3000, lt);
        store_done_tag = st;
        store_done_valid = 1'b1;
        resp_tag = lt;
        resp_paddr = 64'h3000;
        resp_rdata = 64'h8877_6655_4433_2211;
        resp_valid = 1'b1;
        result_ready = 1'b1;
        #1;
        if (!store_done_ready || !resp_ready || !result_valid ||
            result_store || result_id != IDW'(6) ||
            result_rdata != 64'h8877_6655_4433_2211)
            $fatal(1,
                "concurrent store/load completion failed store_ready=%b resp_ready=%b result=%b/%b/%0d/%h",
                store_done_ready, resp_ready, result_valid, result_store,
                result_id, result_rdata);
        tick();
        store_done_valid = 1'b0;
        resp_valid = 1'b0;
        result_ready = 1'b0;
        if (store_pending)
            $fatal(1, "concurrent store completion retained stale state");
        translation_bypass = 1'b0;

        reset_dut();

        // Exercise the exact MRET-like boundary: architectural store result
        // consumption and full flush coincide, followed by delayed L1D tag
        // release.
        translation_bypass = 1'b1;
        alloc_store(IDW'(7), 3'd7, 64'h3800, 3'd3,
                    64'ha5a5_5a5a_a5a5_5a5a, 8'hff);
        head_valid = 1; head_id = IDW'(7); head_slot = 3'd7;
        take_req(1'b1, 64'h3800, st);
        head_valid = 0;
        flush = 1'b1;
        result_ready = 1'b1;
        #1;
        if (!result_valid || !result_store || result_id != IDW'(7))
            $fatal(1, "flush-cycle posted-store result absent");
        tick();
        flush = 1'b0;
        result_ready = 1'b0;
        if (!store_pending)
            $fatal(1, "flush-cycle result released posted-store tag early");
        complete_store(st);
        if (store_pending)
            $fatal(1, "delayed completion after flush retained store");
        translation_bypass = 1'b0;

        reset_dut();

        // A tag release can arrive on the flush edge itself.  Both sides see
        // the pre-edge accepted-store state, so this must consume the tag
        // exactly once rather than preserve or discard it inconsistently.
        translation_bypass = 1'b1;
        alloc_store(IDW'(8), 3'd0, 64'h4000, 3'd3,
                    64'hccdd_eeff_0011_2233, 8'hff);
        head_valid = 1; head_id = IDW'(8); head_slot = 3'd0;
        take_req(1'b1, 64'h4000, st);
        take_result(IDW'(8), 1, 0, 0, 0);
        head_valid = 0;
        store_done_tag = st;
        store_done_valid = 1'b1;
        flush = 1'b1;
        tick();
        store_done_valid = 1'b0;
        flush = 1'b0;
        if (store_pending || result_valid)
            $fatal(1, "flush-edge store completion was not consumed once");
        translation_bypass = 1'b0;

        reset_dut();

        // Younger cacheable load waits for an older store paddr, then passes
        // because the translated physical lines differ.
        alloc_store(IDW'(2), 3'd2, 64'h3000, 3'd3,
                    64'h1111_2222_3333_4444, 8'hff);
        alloc_load(IDW'(3), 3'd3, 64'h4000, 3'd3);
        take_xlate(1'b1, 64'h3000, st);
        take_xlate(1'b0, 64'h4000, lt);
        respond_xlate(lt, 64'h5000, 0, 0);
        repeat (2) begin
            tick();
            if (req_valid)
                $fatal(1, "load passed store with unknown paddr");
        end
        respond_xlate(st, 64'h6000, 0, 0);
        take_req(1'b0, 64'h5000, lt);
        respond_result(lt, 64'h5000, 64'h0123_4567_89ab_cdef,
                       IDW'(3), 0, 64'h0123_4567_89ab_cdef);
        flush = 1; tick(); flush = 0;

        reset_dut();

        // Translation and access are distinct channels. Once both physical
        // addresses are known, a younger disjoint load reaches L1D.
        alloc_store(IDW'(4), 3'd4, 64'h3000, 3'd3,
                    64'h1111_2222_3333_4444, 8'hff);
        take_xlate(1'b1, 64'h3000, st);
        respond_xlate(st, 64'h6000, 0, 0);
        alloc_load(IDW'(5), 3'd5, 64'h4000, 3'd3);
        take_xlate(1'b0, 64'h4000, lt);
        respond_xlate(lt, 64'h5000, 0, 0);
        take_req(1'b0, 64'h5000, lt);
        respond_result(lt, 64'h5000, 64'h0123_4567_89ab_cdef,
                       IDW'(5), 0, 64'h0123_4567_89ab_cdef);
        flush = 1; tick(); flush = 0;

        reset_dut();

        // Translation admission and physical L1D access are independent.
        // A younger translation must issue in the same cycle as an older
        // already-translated load reaches the data cache.
        alloc_load(IDW'(12), 3'd4, 64'h14_000, 3'd3);
        take_xlate(1'b0, 64'h14_000, st);
        respond_xlate(st, 64'h4000, 0, 0);
        alloc_load(IDW'(13), 3'd5, 64'h15_000, 3'd3);
        #1;
        if (!req_valid || req_write || req_addr != 64'h4000 ||
            !xlate_valid || xlate_write || xlate_vaddr != 64'h15_000)
            $fatal(1,
                "translation/access overlap absent req=%b/%b/%h xlate=%b/%b/%h",
                req_valid, req_write, req_addr,
                xlate_valid, xlate_write, xlate_vaddr);
        st = req_tag;
        lt = xlate_tag;
        req_ready = 1'b1;
        xlate_ready = 1'b1;
        tick();
        req_ready = 1'b0;
        xlate_ready = 1'b0;
        respond_xlate(lt, 64'h5000, 0, 0);
        respond_result(st, 64'h4000, 64'h1111_2222_3333_4444,
                       IDW'(12), 0, 64'h1111_2222_3333_4444);
        take_req(1'b0, 64'h5000, lt);
        respond_result(lt, 64'h5000, 64'h5555_6666_7777_8888,
                       IDW'(13), 0, 64'h5555_6666_7777_8888);

        reset_dut();

        // An arbitrary VA may translate before ordered retirement, but a
        // translated physical address outside cacheable RAM must not issue a
        // device read until that load becomes the ordered head.
        alloc_load(IDW'(14), 3'd6, 64'hffff_ffd6_1000_2000, 3'd3);
        take_xlate(1'b0, 64'hffff_ffd6_1000_2000, lt);
        respond_xlate(lt, 64'h1_0020, 0, 0);
        repeat (2) begin
            tick();
            if (req_valid)
                $fatal(1,
                    "translated non-RAM load escaped before ordered head");
        end
        head_valid = 1'b1;
        head_id = IDW'(14);
        head_slot = 3'd6;
        take_req(1'b0, 64'h1_0020, lt);
        respond_result(lt, 64'h1_0020, 64'h0bad_f00d_dead_beef,
                       IDW'(14), 0, 64'h0bad_f00d_dead_beef);
        head_valid = 1'b0;

        reset_dut();

        // A cacheable load may pass an older translated store when the byte
        // ranges are disjoint, even if both addresses occupy one cache line.
        translation_bypass = 1'b1;
        alloc_store(IDW'(4), 3'd4, 64'h7000, 3'd3,
                    64'h1111_2222_3333_4444, 8'hff);
        alloc_load(IDW'(5), 3'd5, 64'h7008, 3'd3);
        take_req(1'b0, 64'h7008, lt);
        respond_result(lt, 64'h7008, 64'h0123_4567_89ab_cdef,
                       IDW'(5), 0, 64'h0123_4567_89ab_cdef);
        translation_bypass = 1'b0;
        flush = 1; tick(); flush = 0;

        reset_dut();

        // A fully-covered same-word load forwards without physical access.
        alloc_store(IDW'(6), 3'd6, 64'h8002, 3'd2,
                    64'h0000_aabb_ccdd_0000, 8'h3c);
        alloc_load(IDW'(7), 3'd7, 64'h8002, 3'd2);
        take_xlate(1'b1, 64'h8002, st);
        respond_xlate(st, 64'h8002, 0, 0);
        take_xlate(1'b0, 64'h8002, lt);
        respond_xlate(lt, 64'h8002, 0, 0);
        #1;
        if (req_valid && !req_write)
            $fatal(1, "forwarded load issued physical read");
        take_result(IDW'(7), 0, 64'h0000_aabb_ccdd_0000, 0, 0);
        flush = 1; tick(); flush = 0;

        reset_dut();

        // An uncacheable/device load must not consume store-forwarded data.
        // It waits for the older store to complete, then performs its own
        // physical access so device read side effects remain observable.
        translation_bypass = 1'b1;
        alloc_store(IDW'(8), 3'd0, 64'h1_0008, 3'd3,
                    64'h5566_7788_99aa_bbcc, 8'hff);
        alloc_load(IDW'(9), 3'd1, 64'h1_0008, 3'd3);
        #1;
        if (result_valid)
            $fatal(1, "uncacheable load forwarded from older store");
        head_valid = 1; head_id = IDW'(8); head_slot = 3'd0;
        take_req(1'b1, 64'h1_0008, st);
        respond_result(st, 64'h1_0008, 64'd0, IDW'(8), 1, 64'd0);
        head_id = IDW'(9); head_slot = 3'd1;
        take_req(1'b0, 64'h1_0008, lt);
        respond_result(lt, 64'h1_0008, 64'h0123_4567_89ab_cdef,
                       IDW'(9), 0, 64'h0123_4567_89ab_cdef);
        head_valid = 0;
        translation_bypass = 1'b0;

        reset_dut();

        // Translation faults complete locally and precisely.
        alloc_load(IDW'(8), 3'd0, 64'h9000, 3'd3);
        take_xlate(1'b0, 64'h9000, lt);
        respond_xlate(lt, 0, 0, 1);
        #1;
        if (req_valid)
            $fatal(1, "faulted translation issued physical access");
        take_result(IDW'(8), 0, 0, 0, 1);

        reset_dut();

        // Selective recovery quarantines an accepted younger request until its
        // response returns.  The stale tag must not be reused or complete a
        // newly allocated instruction.
        alloc_load(IDW'(10), 3'd2, 64'ha000, 3'd3);
        take_xlate(1'b0, 64'ha000, lt);
        squash_id = IDW'(9);
        squash_younger = 1'b1;
        tick();
        squash_younger = 1'b0;
        alloc_load(IDW'(11), 3'd3, 64'hb000, 3'd3);
        take_xlate(1'b0, 64'hb000, st);
        if (st == lt)
            $fatal(1, "selective squash reused quarantined tag=%0d", lt);
        respond_xlate(lt, 64'hc000, 0, 0);
        #1;
        if (result_valid)
            $fatal(1, "killed translation produced a result");
        respond_xlate(st, 64'hd000, 0, 0);
        take_req(1'b0, 64'hd000, st);
        respond_result(st, 64'hd000, 64'h1122_3344_5566_7788,
                       IDW'(11), 0, 64'h1122_3344_5566_7788);

        reset_dut();

        // A killed physical response may coincide with a valid local result.
        // Consume the stale response, but complete the live local instruction.
        alloc_load(IDW'(30), 3'd6, 64'h10_000, 3'd3);
        take_xlate(1'b0, 64'h10_000, lt);
        respond_xlate(lt, 64'h3000, 0, 0);
        take_req(1'b0, 64'h3000, lt);
        squash_id = IDW'(29);
        squash_younger = 1'b1;
        tick();
        squash_younger = 1'b0;
        l_immediate = 1'b1;
        alloc_load(IDW'(31), 3'd7, 64'h12_000, 3'd3);
        l_immediate = 1'b0;
        resp_tag = lt;
        resp_paddr = 64'h3000;
        resp_rdata = 64'hdead_beef_dead_beef;
        resp_valid = 1'b1;
        result_ready = 1'b1;
        #1;
        if (!resp_ready || !result_valid || result_id != IDW'(31) ||
            result_rdata != 64'd0)
            $fatal(1,
                "killed response displaced local result id=%0d data=%h",
                result_id, result_rdata);
        tick();
        resp_valid = 1'b0;
        result_ready = 1'b0;

        reset_dut();

        // A redirect may coincide with the response of an older surviving
        // load.  That response must still complete rather than being consumed
        // as though the load were on the squashed path.
        alloc_load(IDW'(20), 3'd4, 64'he000, 3'd3);
        take_xlate(1'b0, 64'he000, lt);
        respond_xlate(lt, 64'hf000, 0, 0);
        take_req(1'b0, 64'hf000, lt);
        squash_id = IDW'(21);
        squash_younger = 1'b1;
        resp_tag = lt;
        resp_paddr = 64'hf000;
        resp_rdata = 64'h8877_6655_4433_2211;
        resp_valid = 1'b1;
        result_ready = 1'b1;
        #1;
        if (!resp_ready || !result_valid || result_id != IDW'(20) ||
            result_rdata != 64'h8877_6655_4433_2211)
            $fatal(1, "surviving redirect-cycle response was lost");
        tick();
        squash_younger = 1'b0;
        resp_valid = 1'b0;
        result_ready = 1'b0;

        $display("PASS: unified LSQ ordering, physical bypass, forwarding, faults, and selective recovery");
        $finish;
    end

    wire unused = &{
        1'b0, result_slot, result_meta, store_pending,
        atomic_start_valid, atomic_start_tag, atomic_start_id,
        atomic_start_slot, atomic_start_meta, atomic_start_allowed,
        req_vaddr, req_size, req_wdata, req_wstrb
    };
endmodule
