# RTL and testbench source manifests.

ISA_SRCS := rtl/core/isa/rv64-i.v rtl/core/isa/rv64-a.v rtl/core/isa/rv64-m.v \
	rtl/core/isa/rv64-zicsr.v rtl/core/isa/rv64-priv.v rtl/core/isa/rv64-zifencei.v \
	rtl/core/isa/rv64-zba.v rtl/core/isa/rv64-zbb.v \
	rtl/core/isa/rv64-zbc.v rtl/core/isa/rv64-zbs.v rtl/core/isa/rv64-b.v
FP_ISA_SRCS := rtl/core/isa/rv64-f.v rtl/core/isa/rv64-d.v
FPR_SRCS := rtl/core/regs/prf.v rtl/core/regs/rv64-fd-fpr.v
FPU_SRCS := rtl/core/exec/fpu/defs.v rtl/core/exec/fpu/rv64-fd.v
VEC_DEFS := rtl/core/exec/vec/defs.v
VEC_REG_SRCS := rtl/core/regs/prf.v rtl/core/regs/rv64-i-vec.v
VEC_EXEC_SRCS := $(VEC_DEFS) rtl/core/exec/vec/rv64-vec.v
VEC_LSU_SRCS := $(VEC_DEFS) rtl/core/exec/vec/rv64-vec-lsu.v
ARITH_DEPS := rtl/core/arith/prefix-addsub.v
CMU_SRCS := rtl/core/cmu/cmu.v
DECODE_SRCS := rtl/core/decode/defs/early-defs.v rtl/core/decode/defs/alu-defs.v \
	rtl/core/decode/defs/lsu-defs.v rtl/core/decode/defs/br-defs.v \
	rtl/core/decode/early.v rtl/core/decode/decode_top.v rtl/core/decode/rv64-c.v \
	rtl/core/decode/imm.v rtl/core/decode/alu.v \
	rtl/core/decode/lsu.v rtl/core/decode/br.v rtl/core/decode/system.v rtl/core/decode/fence.v \
	rtl/core/decode/reg/alu.v rtl/core/decode/reg/lsu.v rtl/core/decode/reg/system.v
REG_SRCS := rtl/core/regs/prf.v rtl/core/regs/rv64-i-gpr.v \
	rtl/core/regs/rv64-i-gpr_3p.v \
	rtl/core/regs/rv64-i-pmp.v $(CMU_SRCS) rtl/core/regs/rv64-i-csrs.v
RENAME_SRCS := rtl/core/rename/identity.v
FETCH_SRCS := rtl/core/fetch/fetch-defs.v rtl/core/fetch/fetch.v \
	rtl/core/fetch/fetch_3w.v
L1_CACHE_SRCS := rtl/cache/l1/l1.v rtl/cache/l1/wrapper.v \
	rtl/core/cache/l1/l1i/array.v rtl/core/cache/l1/l1i/ccx.v \
	rtl/core/cache/l1/l1i/frontend_if.v \
	rtl/core/cache/l1/l1i/mshr.v rtl/core/cache/l1/l1i/l1i.v \
	rtl/core/cache/l1/l1d/array.v rtl/core/cache/l1/l1d/ccx.v \
	rtl/core/cache/l1/l1d/lsu_if.v rtl/core/cache/l1/l1d/mshr.v \
	rtl/core/cache/l1/l1d/l1d.v
BUS_SRCS := rtl/core/bus/bus-defs.v rtl/core/bus/tlb.v \
	rtl/core/bus/tlb_l2.v rtl/core/bus/ptw.v \
	rtl/core/bus/gen_bus.v rtl/core/bus/ccx_bus.v rtl/core/bus/bus.v \
	$(L1_CACHE_SRCS)
CCX_PROTOCOL_SRCS := rtl/complex/protocol/defs.v \
	rtl/complex/protocol/hart_legacy_adapter.v \
	rtl/complex/protocol/axi_master.v rtl/complex/protocol/crossbar.v \
	rtl/complex/protocol/wrapper_nh.v rtl/complex/protocol/wrapper_1h.v \
	rtl/complex/protocol/wrapper_2h.v rtl/complex/protocol/wrapper_4h.v
COMPLEX_BUS_SRCS := rtl/complex/bus/defs.v \
	rtl/complex/bus/wishbone_backend.v rtl/bus/genbus_interface.v
CCX_L2_SRCS := rtl/cache/l2/sram_way.v rtl/cache/l2/l2_native.v
CORE_COMPLEX_SRCS := rtl/complex/protocol/defs.v \
	rtl/complex/protocol/line_crossbar.v \
	$(CCX_L2_SRCS) \
	$(COMPLEX_BUS_SRCS) \
	rtl/complex/wrapper_nh.v
CCX_COHERENT_SRCS := rtl/complex/coherent/protocol/defs.v \
	rtl/complex/coherent/directory.v \
	rtl/complex/coherent/snoop_filter.v \
	rtl/complex/coherent/probe_tracker.v \
	rtl/complex/coherent/l1d_probe_endpoint.v \
	rtl/complex/coherent/control.v \
	rtl/complex/coherent/protocol/coherent_protocol.v \
	rtl/complex/2h/ccx.v rtl/complex/4h/ccx.v
DISPATCH_SRCS := $(RENAME_SRCS) rtl/core/dispatch/reg_map.v \
	rtl/core/dispatch/reg_map_3p.v rtl/core/dispatch/dispatch_3p.v \
	rtl/core/dispatch/dispatch_window_3p.v \
	rtl/core/dispatch/dispatch_barrier_3p.v \
	rtl/core/dispatch/dispatch_issue_3p.v \
	rtl/core/dispatch/dispatch_control_3p.v \
	rtl/core/dispatch/dispatch_1p.v rtl/core/dispatch/dispatch.v
BP_SRC := rtl/core/exec/bp/bp.v
BP_DEPS := rtl/core/exec/bp/defs.v rtl/core/exec/bp/stall.v \
	rtl/core/exec/bp/always_branch.v rtl/core/exec/bp/always_decline.v \
	rtl/core/exec/bp/repeat_last.v rtl/core/exec/bp/btfnt.v \
	rtl/core/exec/bp/bimodal.v rtl/core/exec/bp/gshare_btb.v \
	rtl/core/exec/bp/tournament_btb.v rtl/core/exec/bp/ras.v
EXEC_SRCS := rtl/core/exec/exec_pipe_ex0.v rtl/core/exec/exec_pipe_ex1.v \
	rtl/core/exec/lsq.v rtl/core/exec/lsu/atomics.v \
	rtl/core/exec/exec_lsu.v \
	rtl/core/exec/exec_pipe_mem.v rtl/core/exec/exec_top_3p.v \
	rtl/core/exec/exec_top_1p.v rtl/core/exec/exec_top.v \
	rtl/core/exec/alu/rv64-i.v rtl/core/exec/alu/rv64-m.v \
	rtl/core/exec/lsu/rv64-i.v rtl/core/exec/lsu/rv64-a.v \
	rtl/core/exec/br.v $(BP_SRC) rtl/core/exec/system/csr.v
EXCEPT_SRCS := rtl/core/except/except-defs.v rtl/core/except/except.v \
	rtl/core/except/vector.v
STAGE_SRCS := rtl/core/stage/stage.v
RETIRE_SRCS := rtl/core/retire/retire.v rtl/core/retire/retire_queue_3p.v \
	rtl/core/retire/retire_records_3p.v rtl/core/retire/retire_3p.v
TRACE_SRCS := rtl/core/trace/trace-defs.v
BACKEND_SRCS := rtl/core/backend/backend_3p.v
CORE_SRCS := rtl/core/rv64_top.v rtl/core/rv64_top_3p.v $(BACKEND_SRCS) \
	$(STAGE_SRCS) $(FETCH_SRCS) $(BUS_SRCS) $(DECODE_SRCS) $(REG_SRCS) \
	$(DISPATCH_SRCS) $(EXEC_SRCS) $(RETIRE_SRCS) $(EXCEPT_SRCS) $(TRACE_SRCS)
CORE_3P_AXI_SRCS := rtl/core/rv64_top_3p.v $(BACKEND_SRCS) \
	$(STAGE_SRCS) rtl/core/fetch/fetch-defs.v rtl/core/fetch/fetch_3w.v \
	rtl/core/bus/bus-defs.v rtl/core/bus/tlb.v rtl/core/bus/tlb_l2.v \
	rtl/core/bus/ptw.v rtl/core/bus/ccx_bus.v rtl/core/bus/bus.v \
	$(L1_CACHE_SRCS) \
	$(DECODE_SRCS) \
	rtl/core/regs/prf.v rtl/core/regs/rv64-i-gpr_3p.v \
	rtl/core/regs/rv64-i-pmp.v $(CMU_SRCS) \
	rtl/core/regs/rv64-i-csrs.v $(RENAME_SRCS) \
	rtl/core/dispatch/reg_map_3p.v \
	rtl/core/dispatch/dispatch_3p.v rtl/core/dispatch/dispatch_window_3p.v \
	rtl/core/dispatch/dispatch_barrier_3p.v \
	rtl/core/dispatch/dispatch_issue_3p.v \
	rtl/core/dispatch/dispatch_control_3p.v rtl/core/dispatch/dispatch.v \
	rtl/core/exec/exec_pipe_ex0.v rtl/core/exec/exec_pipe_ex1.v \
	rtl/core/exec/lsq.v rtl/core/exec/lsu/atomics.v \
	rtl/core/exec/exec_lsu.v \
	rtl/core/exec/exec_pipe_mem.v rtl/core/exec/exec_top_3p.v \
	rtl/core/exec/exec_top.v rtl/core/exec/alu/rv64-i.v \
	rtl/core/exec/alu/rv64-m.v rtl/core/exec/lsu/rv64-i.v \
	rtl/core/exec/lsu/rv64-a.v rtl/core/exec/br.v $(BP_SRC) \
	rtl/core/exec/system/csr.v rtl/core/retire/retire_queue_3p.v \
	rtl/core/retire/retire_records_3p.v \
	rtl/core/retire/retire_3p.v $(EXCEPT_SRCS) $(TRACE_SRCS)
CLINT_SRCS := rtl/clint/clint.v
PLIC_SRCS := rtl/plic/plic.v
UART_SRCS := rtl/periph/uart/uart.v
GPIO_SRCS := rtl/periph/gpio/gpio.v
TIMER_SRCS := rtl/periph/timer/timer.v
ROM_SRCS := rtl/soc/bus/rom.v
MEMORY_SRCS := rtl/soc/bus/memory.v
MEM_CHANNEL_SRCS := rtl/soc/memory/timing_dram.v \
	rtl/soc/memory/timing_dram_banked.v \
	rtl/soc/memory/timing_ddr3.v rtl/soc/memory/timing_ddr4.v \
	rtl/soc/memory/timing_gddr6.v \
	rtl/soc/memory/timing_hbm2.v rtl/soc/memory/timing_magic.v \
	rtl/soc/memory/mem_channel.v
DDR3_TIMING_SRCS := rtl/soc/memory/timing_dram_banked.v \
	rtl/soc/memory/timing_ddr3.v rtl/soc/memory/timing_magic.v
AXI_DDR3_SRCS := $(DDR3_TIMING_SRCS) \
	rtl/soc/memory/mem_channel.v rtl/soc/memory/axi_ddr3.v
MESH_ROUTER_SRCS := rtl/mesh/router_tile.v
SOC_BUS_SRCS := rtl/soc/bus/mem_map.v rtl/soc/bus/decode.v
RESET_SEQUENCER_SRCS := rtl/soc/reset_sequencer.v
PLATFORM_SRCS := rtl/soc/platform.sv rtl/openrv64_top.sv \
	rtl/soc/bus/axi_to_scalar.v rtl/soc/bus/axi_to_wide.v \
	rtl/soc/bus/ccx_l2_bridge.v \
	$(CORE_COMPLEX_SRCS) \
	$(AXI_DDR3_SRCS) \
	$(RESET_SEQUENCER_SRCS) $(SOC_BUS_SRCS) $(ROM_SRCS) $(MEMORY_SRCS) \
	$(CLINT_SRCS) $(PLIC_SRCS) $(UART_SRCS) $(GPIO_SRCS) $(TIMER_SRCS)
TOP_SIM_SRCS := rtl/openrv64_top.sv tb/openrv64_cycle_trace.sv tb/tb_openrv64_top.sv
PLATFORM_SIM_SRCS := tb/tb_platform.sv
RESET_SEQUENCER_SIM_SRCS := tb/tb_reset_sequencer.sv
UART_FIRMWARE_SIM_SRCS := tb/openrv64_cycle_trace.sv \
	tb/tb_uart_firmware.sv
OPENSBI_SIM_SRCS := tb/tb_opensbi.sv
SW_TRACE_SIM_SRCS := rtl/openrv64_top.sv tb/openrv64_cycle_trace.sv tb/tb_sw_trace.sv
CLINT_SIM_SRCS := tb/tb_clint.sv
PLIC_SIM_SRCS := tb/tb_plic.sv
UART_SIM_SRCS := tb/tb_uart16550.sv
GPIO_SIM_SRCS := tb/tb_gpio.sv
TIMER_SIM_SRCS := tb/tb_timer.sv
ROM_SIM_SRCS := tb/tb_soc_rom.sv
MEMORY_SIM_SRCS := tb/tb_soc_memory.sv
MEM_CHANNEL_SIM_SRCS := tb/tb_mem_channel.sv
L2_AXI_DDR3_SIM_SRCS := tb/tb_l2_axi_ddr3.sv
MESH_ROUTER_SIM_SRCS := tb/tb_mesh_router_tile.sv
SOC_BUS_SIM_SRCS := tb/tb_soc_bus_decode.sv
CORE_BUS_SIM_SRCS := tb/tb_core_bus.sv
CCX_PROTOCOL_1H_SIM_SRCS := tb/tb_ccx_protocol_1h.sv
CCX_PROTOCOL_NH_SIM_SRCS := tb/tb_ccx_protocol_nh.sv
L1_CACHE_SIM_SRCS := tb/tb_l1_cache.sv
CCX_L2_SIM_SRCS := tb/tb_ccx_l2.sv
GENBUS_SIM_SRCS := tb/tb_genbus_interface.sv
CORE_COMPLEX_SIM_SRCS := tb/tb_core_complex.sv
CCX_BUS_SIM_SRCS := tb/tb_ccx_bus.sv
CCX_L1I_SIM_SRCS := tb/tb_ccx_l1i.sv
L1I_TOP_SIM_SRCS := rtl/openrv64_l1i_top.v \
	rtl/cache/l1/l1.v rtl/cache/l1/wrapper.v \
	rtl/core/cache/l1/l1i/array.v rtl/core/cache/l1/l1i/ccx.v \
	rtl/core/cache/l1/l1i/frontend_if.v \
	rtl/core/cache/l1/l1i/mshr.v rtl/core/cache/l1/l1i/l1i.v \
	tb/tb_openrv64_l1i_top.sv
TLB_SIM_SRCS := tb/tb_tlb.sv
TLB_L2_SIM_SRCS := tb/tb_tlb_l2.sv
PTW_SIM_SRCS := tb/tb_ptw.sv
PTW_CONTEXT_SIM_SRCS := rtl/openrv64_top.sv tb/tb_ptw_context.sv
DECODE_EARLY_SIM_SRCS := tb/tb_decode_early.sv
DECODE_TOP_SIM_SRCS := rtl/core/decode/early.v rtl/core/decode/imm.v \
	rtl/core/decode/alu.v rtl/core/decode/lsu.v rtl/core/decode/br.v rtl/core/decode/system.v rtl/core/decode/fence.v \
	rtl/core/decode/reg/alu.v rtl/core/decode/reg/lsu.v rtl/core/decode/reg/system.v tb/tb_decode_top.sv
DECODE_RV64C_SIM_SRCS := rtl/core/decode/rv64-c.v \
	rtl/core/decode/early.v rtl/core/decode/imm.v rtl/core/decode/alu.v \
	rtl/core/decode/lsu.v rtl/core/decode/br.v rtl/core/decode/system.v \
	rtl/core/decode/fence.v rtl/core/decode/reg/alu.v \
	rtl/core/decode/reg/lsu.v rtl/core/decode/reg/system.v \
	rtl/core/decode/decode_top.v tb/tb_decode_rv64c.sv
DECODE_IMM_SIM_SRCS := tb/tb_decode_imm.sv
DECODE_ALU_SIM_SRCS := tb/tb_decode_alu.sv
DECODE_LSU_SIM_SRCS := tb/tb_decode_lsu.sv
DECODE_REG_ALU_SIM_SRCS := tb/tb_decode_reg_alu.sv
DECODE_REG_LSU_SIM_SRCS := tb/tb_decode_reg_lsu.sv
DECODE_BR_SIM_SRCS := tb/tb_decode_br.sv
ISA_BITMANIP_SIM_SRCS := tb/tb_isa_bitmanip.sv
ISA_FP_SIM_SRCS := tb/tb_isa_fp.sv
STAGE_SIM_SRCS := tb/tb_stage.sv
RV64I_GPR_SIM_SRCS := tb/tb_rv64-i-gpr.sv
RV64I_CSRS_SIM_SRCS := tb/tb_rv64-i-csrs.sv
RV64I_PMP_SIM_SRCS := tb/tb_rv64-i-pmp.sv
FETCH_SIM_SRCS := tb/tb_fetch.sv
FETCH_3W_SIM_SRCS := tb/tb_fetch_3w.sv
FETCH_3W_CAROUSEL_SIM_SRCS := tb/tb_fetch_3w_carousel.sv
FETCH_3W_SECTOR_SIM_SRCS := tb/tb_fetch_3w_sector.sv
FETCH_3W_PAIR512_SIM_SRCS := tb/tb_fetch_3w_pair512.sv
FETCH_3W_PAIR1024_SIM_SRCS := tb/tb_fetch_3w_pair1024.sv
PREFIX_ADDSUB_SIM_SRCS := tb/tb_prefix_addsub.sv
EXEC_ALU_RV64I_SIM_SRCS := tb/tb_exec_alu_rv64-i.sv
EXEC_ALU_RV64M_SIM_SRCS := tb/tb_exec_alu_rv64-m.sv
LSQ_SIM_SRCS := tb/tb_lsq.sv
LSU_ATOMICS_SIM_SRCS := tb/tb_lsu_atomics.sv
EXEC_LSU_RV64I_SIM_SRCS := tb/tb_exec_lsu_rv64-i.sv
EXEC_LSU_RV64A_SIM_SRCS := tb/tb_exec_lsu_rv64-a.sv
ATOMIC_CONTEXT_SIM_SRCS := rtl/openrv64_top.sv tb/tb_atomic_context.sv
EXEC_BR_SIM_SRCS := tb/tb_exec_br.sv
EXEC_BP_SIM_SRCS := tb/tb_exec_bp.sv
RV64FD_FPR_SIM_SRCS := tb/tb_rv64-fd-fpr.sv
EXEC_FPU_RV64FD_SIM_SRCS := tb/tb_exec_fpu_rv64-fd.sv
RV64I_VEC_SIM_SRCS := tb/tb_rv64-i-vec.sv
EXEC_VEC_SIM_SRCS := tb/tb_exec_vec.sv
EXEC_VEC_LSU_SIM_SRCS := tb/tb_exec_vec_lsu.sv
VEC_TEST_TOP_SIM_SRCS := rtl/openrv64_vec_test_top.sv \
	tb/tb_openrv64_vec_test_top.sv
VEC_CACHE_SIM_SRCS := rtl/core/exec/vec/rv64-vec-cache.v \
	tb/tb_vec_sram_cache.sv
VEC_CACHE_BUS_SIM_SRCS := rtl/core/exec/vec/rv64-vec-cache.v \
	rtl/core/exec/vec/rv64-vec-cache-bus.v tb/tb_vec_cache_bus.sv
VEC_MATMUL_SIM_SRCS := rtl/openrv64_vec_test_top.sv \
	tb/tb_openrv64_vec_matmul.sv
VEC_MATMUL_BF16_SIM_SRCS := rtl/openrv64_vec_test_top.sv \
	tb/tb_openrv64_vec_matmul_bf16.sv
VEC_TEST_TOP_DEPS := rtl/core/exec/vec/instr-defs.v $(VEC_DEFS) \
	rtl/core/exec/vec/rv64-vec.v rtl/core/exec/vec/rv64-vec-lsu.v \
	rtl/core/exec/vec/rv64-vec-cache.v \
	$(VEC_REG_SRCS) rtl/core/regs/rv64-i-gpr.v \
	rtl/core/exec/alu/rv64-i.v rtl/core/exec/br.v $(ARITH_DEPS) \
	$(DECODE_SRCS)
BP_CONTEXT_SIM_SRCS := rtl/openrv64_top.sv tb/tb_bp_context.sv
EXCEPT_SIM_SRCS := tb/tb_except.sv
EXEC_SYSTEM_CSR_SIM_SRCS := tb/tb_exec_system_csr.sv
TRAP_CONTEXT_SIM_SRCS := rtl/openrv64_top.sv tb/tb_trap_context.sv
PRIV_CONTEXT_SIM_SRCS := rtl/openrv64_top.sv tb/tb_priv_context.sv
IRQ_CONTEXT_SIM_SRCS := rtl/openrv64_top.sv tb/tb_irq_context.sv
LOAD_USE_CONTEXT_SIM_SRCS := rtl/openrv64_top.sv tb/tb_load_use_context.sv
REG_OWNER_SIM_SRCS := tb/tb_reg_owner.sv
DISPATCH_SIM_SRCS := tb/tb_dispatch.sv
YOSYS ?= yosys
YOSYS_ALU_REPORT_DIR ?= sim/yosys/alu
YOSYS_FRONTEND_REPORT_DIR ?= sim/yosys/frontend
YOSYS_CORE_RESOURCE_DIR ?= sim/yosys/core-sky130
LIBERTY ?=
ABC_CONSTR ?=
ABC_DELAY_PS ?=
CURL ?= curl
SKY130_LIBERTY ?= sim/pdk/sky130_fd_sc_hd__tt_025C_1v80.lib
SKY130_ABC_CONSTR ?= synth/sky130/abc.constr
SKY130_LIBERTY_SHA256 := ec0e1067a35c8bf20b11e58d1e8ac53326067e4dac84a125cc1b917a3518d0d9
SKY130_LIBERTY_URL := https://raw.githubusercontent.com/The-OpenROAD-Project/OpenROAD-flow-scripts/f255c15b3dd4362a704b6af9f617b4091bdd4e6a/flow/platforms/sky130hd/lib/sky130_fd_sc_hd__tt_025C_1v80.lib
