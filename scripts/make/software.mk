# Software workloads and external reference-model runs.

sw-uart: $(UART_FIRMWARE_ELF) $(UART_FIRMWARE_BIN)

sw-coremark-loop: $(COREMARK_LOOP_ELF) $(COREMARK_LOOP_BIN)

sw-coremark-loop-vm: $(CORE_3P_VM_ELF) $(CORE_3P_VM_BIN) \
		$(CORE_3P_VM_MEMH) $(CORE_3P_VM_DISASM)

sw-coremark-loop-4h-vm: $(CORE_4H_VM_ELF) $(CORE_4H_VM_TEMPLATE_BIN) \
		$(CORE_4H_VM_BIN) $(CORE_4H_VM_MEMH) $(CORE_4H_VM_DISASM)

sw-coremark-loop-4h-shared-vm: $(CORE_4H_SHARED_VM_ELF) \
		$(CORE_4H_SHARED_VM_TEMPLATE_BIN) $(CORE_4H_SHARED_VM_BIN) \
		$(CORE_4H_SHARED_VM_MEMH) $(CORE_4H_SHARED_VM_DISASM)

sw-coremark-loop-4h-bare: $(CORE_4H_BARE_ELF) $(CORE_4H_BARE_BIN) \
		$(CORE_4H_BARE_MEMH) $(CORE_4H_BARE_DISASM)

sw-atomic-4h-shared-vm: $(ATOMIC_4H_SHARED_VM_ELF) \
		$(ATOMIC_4H_SHARED_VM_TEMPLATE_BIN) $(ATOMIC_4H_SHARED_VM_BIN) \
		$(ATOMIC_4H_SHARED_VM_MEMH) $(ATOMIC_4H_SHARED_VM_DISASM)

sim-4h-3p-sv39: $(CORE_4H_3P_VERILATOR_BUILD) $(CORE_4H_VM_MEMH)
	test -n "$(CORE_4H_VM_DONE_PC)"
	test -n "$(CORE_4H_VM_MAILBOX_VA)"
	$(CORE_4H_3P_VERILATOR_BUILD) \
		+memh=$(abspath $(CORE_4H_VM_MEMH)) \
		+memh_words=$(CORE_4H_VM_MEMH_WORDS) \
		+done_pc=$(CORE_4H_VM_DONE_PC) \
		+mailbox_va=$(CORE_4H_VM_MAILBOX_VA) \
		+max_cycles=$(CORE_4H_VM_MAX_CYCLES)

sim-4h-3p-shared-sv39: $(CORE_4H_3P_VERILATOR_BUILD) \
		$(CORE_4H_SHARED_VM_MEMH)
	test -n "$(CORE_4H_SHARED_VM_DONE_PC)"
	test -n "$(CORE_4H_SHARED_VM_MAILBOX_VA)"
	$(CORE_4H_3P_VERILATOR_BUILD) \
		+memh=$(abspath $(CORE_4H_SHARED_VM_MEMH)) \
		+memh_words=$(CORE_4H_SHARED_VM_MEMH_WORDS) \
		+done_pc=$(CORE_4H_SHARED_VM_DONE_PC) \
		+mailbox_va=$(CORE_4H_SHARED_VM_MAILBOX_VA) \
		+shared_satp=1 +mailbox_stride=4096 \
		+max_cycles=$(CORE_4H_SHARED_VM_MAX_CYCLES)

sim-4h-3p-bare:
	$(MAKE) sim-4h-3p-bare-configured \
		CORE_4H_3P_SPEC_LOAD_BASE=2147483648

sim-4h-3p-bare-configured: $(CORE_4H_3P_VERILATOR_BUILD) \
		$(CORE_4H_BARE_MEMH)
	test -n "$(CORE_4H_BARE_DONE_PC)"
	test -n "$(CORE_4H_BARE_MAILBOX_PA)"
	$(CORE_4H_3P_VERILATOR_BUILD) \
		+memh=$(abspath $(CORE_4H_BARE_MEMH)) \
		+memh_words=$(CORE_4H_BARE_MEMH_WORDS) \
		+done_pc=$(CORE_4H_BARE_DONE_PC) \
		+mailbox_va=$(CORE_4H_BARE_MAILBOX_PA) \
		+bare=1 +mailbox_stride=4096 \
		+max_cycles=$(CORE_4H_BARE_MAX_CYCLES)

sim-4h-3p-atomic-sv39: $(CORE_4H_3P_VERILATOR_BUILD) \
		$(ATOMIC_4H_SHARED_VM_MEMH)
	test -n "$(ATOMIC_4H_SHARED_VM_DONE_PC)"
	test -n "$(ATOMIC_4H_SHARED_VM_MAILBOX_VA)"
	test -n "$(ATOMIC_4H_SHARED_VM_SUCCESS_VA)"
	test -n "$(ATOMIC_4H_SHARED_VM_COUNTER_VA)"
	$(CORE_4H_3P_VERILATOR_BUILD) \
		+memh=$(abspath $(ATOMIC_4H_SHARED_VM_MEMH)) \
		+memh_words=$(ATOMIC_4H_SHARED_VM_MEMH_WORDS) \
		+done_pc=$(ATOMIC_4H_SHARED_VM_DONE_PC) \
		+mailbox_va=$(ATOMIC_4H_SHARED_VM_MAILBOX_VA) \
		+result_va=$(ATOMIC_4H_SHARED_VM_SUCCESS_VA) \
		+result_expected=$(ATOMIC_4H_SHARED_VM_SUCCESSES) \
		+atomic_counter_va=$(ATOMIC_4H_SHARED_VM_COUNTER_VA) \
		+atomic_expected=$(ATOMIC_4H_SHARED_VM_FINAL_VALUE) \
		+shared_satp=1 +mailbox_stride=4096 +atomic_test=1 \
		+max_cycles=$(ATOMIC_4H_SHARED_VM_MAX_CYCLES)

sim-4h-3p-shared-suite: sim-4h-3p-shared-sv39 \
		sim-4h-3p-atomic-sv39

sw-zero-sv39: $(ZERO_VM_ELF) $(ZERO_VM_BIN) $(ZERO_VM_MEMH) \
		$(ZERO_VM_DISASM)

sw-atomic: $(ATOMIC_SOC_ELF) $(ATOMIC_SOC_BIN) $(ATOMIC_SOC_DISASM)

sim-core-3p-magic: $(CORE_3P_MAGIC_VERILATOR_BUILD) \
		$(CORE_3P_MAGIC_MEMH)
	$(CORE_3P_MAGIC_VERILATOR_BUILD) \
		+memh=$(abspath $(CORE_3P_MAGIC_MEMH)) \
		+max_cycles=$(CORE_3P_MAGIC_MAX_CYCLES) \
		+expect_a0=$(CORE_3P_MAGIC_EXPECT_A0)

sim-core-3p-magic-sweep:
	$(MAKE) sim-core-3p-magic CORE_3P_MAGIC_MODE=0
	$(MAKE) sim-core-3p-magic CORE_3P_MAGIC_MODE=1
	$(MAKE) sim-core-3p-magic CORE_3P_MAGIC_MODE=2

sim-core-3p-ccx-l2: $(CORE_3P_CCX_L2_VERILATOR_BUILD) \
		$(CORE_3P_CCX_L2_MEMH)
	$(CORE_3P_CCX_L2_VERILATOR_BUILD) \
		+memh=$(abspath $(CORE_3P_CCX_L2_MEMH)) \
		+memh_words=$(CORE_3P_CCX_L2_MEMH_WORDS) \
		+max_cycles=$(CORE_3P_CCX_L2_MAX_CYCLES) \
		$(CORE_3P_CCX_L2_ARGS)

sim-core-3p-ccx-l2-vm: $(CORE_3P_VM_MEMH)
	test -n "$(CORE_3P_VM_DONE_PC)"
	$(MAKE) sim-core-3p-ccx-l2 \
		CORE_3P_CCX_L2_MODE=3 \
		CORE_3P_CCX_L2_RETIRE_DEPTH=16 \
		CORE_3P_CCX_L2_ISSUE_WINDOW=1 \
		CORE_3P_CCX_L2_SPECULATION_WINDOW=1 \
		CORE_3P_CCX_L2_POSTED_STORES=1 \
		CORE_3P_CCX_L2_L1D_PREFETCH_ENABLE=1 \
		CORE_3P_CCX_L2_DDR3=1 \
		CORE_3P_CCX_L2_MEMORY_TIMING_MODEL=0 \
		CORE_3P_CCX_L2_MEMH=$(CORE_3P_VM_MEMH) \
		CORE_3P_CCX_L2_MEMH_WORDS=$(CORE_3P_VM_MEMH_WORDS) \
		CORE_3P_CCX_L2_MAX_CYCLES=$(CORE_3P_VM_MAX_CYCLES) \
		CORE_3P_CCX_L2_SPEC_LOAD_BASE=1073741824 \
		CORE_3P_CCX_L2_SPEC_LOAD_SIZE=131072 \
		CORE_3P_CCX_L2_ARGS="+expect_a0=$(CORE_3P_CCX_L2_EXPECT_A0) +done_pc=$(CORE_3P_VM_DONE_PC) +require_sv39"

bench-zero-sv39: $(ZERO_VM_MEMH)
	test -n "$(ZERO_VM_MEASURE_END)"
	$(MAKE) sim-core-3p-ccx-l2 \
		CORE_3P_CCX_L2_MODE=3 \
		CORE_3P_CCX_L2_CONFIDENCE_GATE=1 \
		CORE_3P_CCX_L2_RETIRE_DEPTH=16 \
		CORE_3P_CCX_L2_ISSUE_WINDOW=1 \
		CORE_3P_CCX_L2_SPECULATION_WINDOW=1 \
		CORE_3P_CCX_L2_POSTED_STORES=1 \
		CORE_3P_CCX_L2_L1D_PREFETCH_ENABLE=1 \
		CORE_3P_CCX_L2_DDR3=1 \
		CORE_3P_CCX_L2_MEMORY_TIMING_MODEL=0 \
		CORE_3P_CCX_L2_MEMH=$(ZERO_VM_MEMH) \
		CORE_3P_CCX_L2_MEMH_WORDS=$(ZERO_VM_MEMH_WORDS) \
		CORE_3P_CCX_L2_MAX_CYCLES=$(ZERO_VM_MAX_CYCLES) \
		CORE_3P_CCX_L2_SPEC_LOAD_BASE=1074003968 \
		CORE_3P_CCX_L2_SPEC_LOAD_SIZE=262144 \
		CORE_3P_CCX_L2_ARGS="+done_pc=$(ZERO_VM_MEASURE_END) +require_zero_scatter"

sim-zero-sv39: $(ZERO_VM_MEMH)
	test -n "$(ZERO_VM_DONE)"
	$(MAKE) sim-core-3p-ccx-l2 \
		CORE_3P_CCX_L2_MODE=3 \
		CORE_3P_CCX_L2_CONFIDENCE_GATE=1 \
		CORE_3P_CCX_L2_RETIRE_DEPTH=16 \
		CORE_3P_CCX_L2_ISSUE_WINDOW=1 \
		CORE_3P_CCX_L2_SPECULATION_WINDOW=1 \
		CORE_3P_CCX_L2_POSTED_STORES=1 \
		CORE_3P_CCX_L2_L1D_PREFETCH_ENABLE=1 \
		CORE_3P_CCX_L2_DDR3=1 \
		CORE_3P_CCX_L2_MEMORY_TIMING_MODEL=0 \
		CORE_3P_CCX_L2_MEMH=$(ZERO_VM_MEMH) \
		CORE_3P_CCX_L2_MEMH_WORDS=$(ZERO_VM_MEMH_WORDS) \
		CORE_3P_CCX_L2_MAX_CYCLES=$(ZERO_VM_MAX_CYCLES) \
		CORE_3P_CCX_L2_SPEC_LOAD_BASE=1074003968 \
		CORE_3P_CCX_L2_SPEC_LOAD_SIZE=262144 \
		CORE_3P_CCX_L2_ARGS="+expect_a0=$(ZERO_VM_PASS) +done_pc=$(ZERO_VM_DONE) +require_zero_scatter"

sim-atomic-soc: $(CORE_3P_CCX_L2_VERILATOR_BUILD) $(ATOMIC_SOC_MEMH)
	$(CORE_3P_CCX_L2_VERILATOR_BUILD) \
		+memh=$(abspath $(ATOMIC_SOC_MEMH)) \
		+memh_words=$(ATOMIC_SOC_MEMH_WORDS) \
		+max_cycles=$(ATOMIC_SOC_MAX_CYCLES) \
		+expect_a0=$(ATOMIC_SOC_PASS)

sw-memcpy: sw-memcpy-4k sw-memcpy-64k

sw-memcpy-4k: $(MEMCPY_4K_ELF) $(MEMCPY_4K_BIN) \
	$(MEMCPY_4K_DISASM)

sw-memcpy-64k: $(MEMCPY_64K_ELF) $(MEMCPY_64K_BIN) \
	$(MEMCPY_64K_DISASM)

sim-memcpy: sim-memcpy-4k sim-memcpy-64k

sim-memcpy-4k: $(MEMCPY_4K_ELF)
	$(MAKE) sim-prefetch-3p-perf \
		AXI_3P_PERF_PIPELINE_TRACE=$(PREFETCH_PIPELINE_TRACE) \
		AXI_3P_PERF_ELF=$(MEMCPY_4K_ELF) \
		AXI_3P_PERF_BIN=sim/memcpy-4k-check.bin \
		AXI_3P_PERF_MEMH=sim/memcpy-4k-check.memh \
		AXI_3P_PERF_MEMH_BYTES=$(MEMCPY_MEMH_BYTES) \
		AXI_3P_PERF_MAX_CYCLES=$(MEMCPY_4K_MAX_CYCLES) \
		AXI_3P_PERF_ARGS="+memh_words=$(MEMCPY_MEMH_WORDS) +expect_a0=$(MEMCPY_PASS)" \
		AXI_3P_TRACE_CSV=sim/memcpy-4k-check-trace.csv \
		AXI_3P_TRACE_REPORT=sim/memcpy-4k-check-pipeline.txt

sim-memcpy-64k: $(MEMCPY_64K_ELF)
	$(MAKE) sim-prefetch-3p-perf \
		AXI_3P_PERF_PIPELINE_TRACE=$(PREFETCH_PIPELINE_TRACE) \
		AXI_3P_PERF_ELF=$(MEMCPY_64K_ELF) \
		AXI_3P_PERF_BIN=sim/memcpy-64k-check.bin \
		AXI_3P_PERF_MEMH=sim/memcpy-64k-check.memh \
		AXI_3P_PERF_MEMH_BYTES=$(MEMCPY_MEMH_BYTES) \
		AXI_3P_PERF_MAX_CYCLES=$(MEMCPY_64K_MAX_CYCLES) \
		AXI_3P_PERF_ARGS="+memh_words=$(MEMCPY_MEMH_WORDS) +expect_a0=$(MEMCPY_PASS)" \
		AXI_3P_TRACE_CSV=sim/memcpy-64k-check-trace.csv \
		AXI_3P_TRACE_REPORT=sim/memcpy-64k-check-pipeline.txt

bench-memcpy: bench-memcpy-4k bench-memcpy-64k

bench-memcpy-4k: $(MEMCPY_4K_ELF)
	test -n "$(MEMCPY_4K_MEASURE_END)"
	$(MAKE) sim-prefetch-3p-perf \
		AXI_3P_PERF_PIPELINE_TRACE=$(PREFETCH_PIPELINE_TRACE) \
		AXI_3P_PERF_ELF=$(MEMCPY_4K_ELF) \
		AXI_3P_PERF_BIN=sim/memcpy-4k-bench.bin \
		AXI_3P_PERF_MEMH=sim/memcpy-4k-bench.memh \
		AXI_3P_PERF_MEMH_BYTES=$(MEMCPY_MEMH_BYTES) \
		AXI_3P_PERF_MAX_CYCLES=$(MEMCPY_4K_MAX_CYCLES) \
		AXI_3P_PERF_ARGS="+memh_words=$(MEMCPY_MEMH_WORDS) +done_pc=$(MEMCPY_4K_MEASURE_END)" \
		AXI_3P_TRACE_CSV=sim/memcpy-4k-bench-trace.csv \
		AXI_3P_TRACE_REPORT=sim/memcpy-4k-bench-pipeline.txt

bench-memcpy-64k: $(MEMCPY_64K_ELF)
	test -n "$(MEMCPY_64K_MEASURE_END)"
	$(MAKE) sim-prefetch-3p-perf \
		AXI_3P_PERF_PIPELINE_TRACE=$(PREFETCH_PIPELINE_TRACE) \
		AXI_3P_PERF_ELF=$(MEMCPY_64K_ELF) \
		AXI_3P_PERF_BIN=sim/memcpy-64k-bench.bin \
		AXI_3P_PERF_MEMH=sim/memcpy-64k-bench.memh \
		AXI_3P_PERF_MEMH_BYTES=$(MEMCPY_MEMH_BYTES) \
		AXI_3P_PERF_MAX_CYCLES=$(MEMCPY_64K_MAX_CYCLES) \
		AXI_3P_PERF_ARGS="+memh_words=$(MEMCPY_MEMH_WORDS) +done_pc=$(MEMCPY_64K_MEASURE_END)" \
		AXI_3P_TRACE_CSV=sim/memcpy-64k-bench-trace.csv \
		AXI_3P_TRACE_REPORT=sim/memcpy-64k-bench-pipeline.txt

sw-vector-matmul: $(VEC_MATMUL_ELF) $(VEC_MATMUL_BIN) \
		$(VEC_MATMUL_DISASM)

sw-matmul-bf16: $(VEC_MATMUL_BF16_ELF) $(VEC_MATMUL_BF16_BIN) \
		$(VEC_MATMUL_BF16_DISASM)

sw-coremark-loop-a53: $(A53_COREMARK_ELF) $(A53_COREMARK_BIN) \
		$(A53_COREMARK_DISASM)

sw-coremark-loop-a53-gem5: $(A53_GEM5_ELF) $(A53_GEM5_DISASM)

sim-coremark-loop-a53-qemu: sw-coremark-loop-a53
	mkdir -p $(dir $(A53_QEMU_TRACE)) $(dir $(A53_QEMU_REPORT))
	$(QEMU_AARCH64) -M virt,secure=off,virtualization=off \
		-accel tcg,one-insn-per-tb=on -cpu cortex-a53 -smp 1 \
		-m 128M -display none -serial none -monitor none \
		-semihosting-config enable=on,target=native \
		-device loader,file=$(abspath $(A53_COREMARK_ELF)),cpu-num=0 \
		-d in_asm,exec,nochain -D $(A53_QEMU_TRACE)
	$(PYTHON) tools/qemu_one_insn_trace.py $(A53_QEMU_TRACE) \
		--output $(A53_QEMU_REPORT)
	@cat $(A53_QEMU_REPORT)

sim-coremark-loop-a53-gem5: sw-coremark-loop-a53-gem5
	test -x $(GEM5_AARCH64)
	test -f $(GEM5_A53_CONFIG)
# gem5 25.1 HPI underflows its activity recorder on the initial idle edge
# here. Ticked still accounts stopped cycles, so keeping the pipeline clocked
# avoids the bug without removing wait cycles.
	$(GEM5_AARCH64) -d $(A53_GEM5_OUTDIR) \
		--debug-flags=$(A53_GEM5_DEBUG_FLAGS) \
		--debug-file=$(notdir $(A53_GEM5_TRACE)) \
		$(GEM5_A53_CONFIG) --cpu=hpi --cpu-freq=1GHz \
		--num-cores=1 --mem-type=DDR3_1600_8x8 --mem-channels=1 \
		--mem-size=128MiB \
		-P 'system.cpu_cluster.cpus[0].enableIdling=False' \
		$(abspath $(A53_GEM5_ELF))
	$(PYTHON) tools/gem5_hpi_report.py $(A53_GEM5_STATS) \
		--trace $(A53_GEM5_TRACE) --output $(A53_GEM5_REPORT)
