# Aggregate targets and phony declarations.

.PHONY: FORCE sw-uart sw-coremark-loop sw-coremark-loop-vm \
	sw-coremark-loop-4h-vm sim-4h-3p-sv39 \
	sw-coremark-loop-4h-shared-vm sw-atomic-4h-shared-vm \
	sw-coremark-loop-4h-bare sim-4h-3p-bare \
	sim-4h-3p-bare-configured \
	sim-4h-3p-shared-sv39 sim-4h-3p-atomic-sv39 \
	sim-4h-3p-shared-suite \
	sw-zero-sv39 bench-zero-sv39 sim-zero-sv39 sw-atomic \
	sim-atomic-soc \
	sw-memcpy sw-memcpy-4k \
	sw-memcpy-64k sim-memcpy sim-memcpy-4k sim-memcpy-64k \
	bench-memcpy bench-memcpy-4k bench-memcpy-64k \
	sw-coremark-loop-a53 sw-coremark-loop-a53-gem5 sw-vector-matmul sw-matmul-bf16 sim-coremark-loop-a53-qemu sim-coremark-loop-a53-gem5 opensbi sim-opensbi sim-opensbi-icarus sim sim-top sim-platform sim-reset-sequencer sim-uart-firmware sim-uart-firmware-perf sim-top-trace sim-sw-trace trace-report sim-clint sim-plic sim-uart sim-gpio sim-timer sim-rom sim-memory sim-soc-bus sim-core-bus sim-ccx-bus sim-tlb sim-tlb-l2 sim-ptw sim-ptw-context sim-decode-early sim-decode-top sim-decode-imm sim-decode-alu sim-decode-lsu sim-decode-reg-alu sim-decode-reg-lsu sim-decode-br sim-isa-bitmanip sim-stage sim-rv64-i-gpr sim-rv64-i-gpr-3p sim-rv64-i-csrs sim-rv64-i-pmp sim-fetch sim-fetch-2p sim-fetch-3w sim-prefix-addsub sim-dispatch sim-dispatch-barrier-3p sim-dispatch-issue-3p sim-dispatch-window-3p sim-dispatch-3p sim-reg-map-3p sim-exec-alu-rv64-i sim-exec-alu-rv64-m sim-exec-top-3p sim-exec-pipe-mem-timeout sim-exec-lsu-rv64-i sim-exec-lsu-rv64-a sim-atomic-context sim-exec-br sim-exec-bp sim-bp-context sim-bp-context-always-branch sim-bp-context-no-predecode sim-bp-context-always-decline sim-bp-context-repeat-last sim-bp-context-btfnt sim-bp-context-bimodal sim-except sim-exec-system-csr sim-trap-context sim-priv-context sim-irq-context sim-load-use-context sim-reg-owner sim-retire-queue-3p sim-retire-3p sim-backend-3p sim-top-3p sim-top-axi-3p sim-top-axi-3p-bp sim-top-axi-3p-perf sky130-liberty yosys-timing-alu yosys-timing-alu-rv64i yosys-timing-alu-rv64m yosys-timing-alu-rv64i-sky130 yosys-timing-frontend yosys-timing-frontend-sky130 clean
.PHONY: sim-isa-fp sim-rv64-fd-fpr sim-exec-fpu-rv64-fd
.PHONY: sim-decode-rv64c
.PHONY: sim-vec sim-rv64-i-vec sim-exec-vec sim-exec-vec-lsu \
	sim-vec-cache sim-vec-cache-axi sim-vec-cache-wb \
	sim-vec-cache-wb-512 sim-vec-test-top \
	sim-vec-matmul sim-vec-matmul-bf16
.PHONY: sim-bp-context-gshare-btb sim-bp-context-gshare-btb-512 \
	sim-bp-context-tournament-btb
.PHONY: yosys-resources-core-sky130
.PHONY: sim-opensbi-3p sim-opensbi-3p-platform \
	sim-linux-3p-platform-checkpoint sim-linux-3p-platform-restore
.PHONY: sim-linux
.PHONY: sim-l1-cache sim-l1d-prefetch sim-l1d-demand-mshr \
	sim-l1d-store-order \
	sim-l1d-store-buffer sim-l1i-top sim-ccx-protocol-1h \
	sim-ccx-protocol-2h sim-ccx-protocol-4h \
	sim-ccx-coherent-2h sim-ccx-coherent-4h \
	sim-ccx-coherent-protocol-2h sim-ccx-coherent-protocol-4h \
	sim-ccx-4h-l1d-directory-l2
.PHONY: sim-core-3p-magic sim-core-3p-magic-sweep sim-core-3p-ccx-l2 \
	sim-core-3p-ccx-l2-vm
.PHONY: sim-ccx-l2
.PHONY: sim-genbus-axi sim-genbus-wb sim-genbus-wb-widths
.PHONY: sim-core-complex-1h-axi sim-core-complex-2h-axi \
	sim-core-complex-4h-wb
.PHONY: sim-mem-channel sim-l2-axi-ddr3 sim-mesh-router
.PHONY: sim-prf sim-rename-identity sim-lsq sim-lsu-atomics
.PHONY: compliance-doctor compliance-smoke-local compliance-smoke-local-1p \
	compliance-smoke-local-3p compliance-smoke-local-platform \
	compliance-smoke-local-platform-3p \
	compliance-act4-generate compliance-act4-priv-generate compliance-isa \
	compliance-isa-3p compliance-isa-platform-3p compliance-priv compliance-diff \
	compliance-trace-contract compliance-quick compliance-full

FORCE:

sim: sim-top sim-reset-sequencer sim-platform sim-uart-firmware sim-clint sim-plic sim-uart sim-gpio sim-timer sim-rom sim-memory sim-soc-bus sim-core-bus sim-ccx-bus sim-tlb sim-tlb-l2 sim-ptw sim-ptw-context sim-decode-early sim-decode-top sim-decode-imm sim-decode-alu sim-decode-lsu sim-decode-reg-alu sim-decode-reg-lsu sim-decode-br sim-isa-bitmanip sim-stage sim-rv64-i-gpr sim-rv64-i-gpr-3p sim-rv64-i-csrs sim-rv64-i-pmp sim-fetch sim-fetch-2p sim-fetch-3w sim-prefix-addsub sim-dispatch sim-dispatch-barrier-3p sim-dispatch-issue-3p sim-dispatch-3p sim-reg-map-3p sim-exec-alu-rv64-i sim-exec-alu-rv64-m sim-exec-top-3p sim-exec-pipe-mem-timeout sim-exec-lsu-rv64-i sim-exec-lsu-rv64-a sim-atomic-context sim-exec-br sim-exec-bp sim-bp-context sim-except sim-exec-system-csr sim-trap-context sim-priv-context sim-irq-context sim-load-use-context sim-reg-owner sim-retire-queue-3p sim-retire-3p sim-backend-3p sim-top-3p sim-top-axi-3p
sim: sim-isa-fp sim-rv64-fd-fpr sim-exec-fpu-rv64-fd
sim: sim-decode-rv64c
sim: sim-atomic-soc
sim: sim-vec
sim: sim-prf
sim: sim-rename-identity
sim: sim-lsq
sim: sim-lsu-atomics
sim: sim-l1-cache
sim: sim-l1d-prefetch
sim: sim-l1d-demand-mshr
sim: sim-l1d-store-order sim-l1d-store-buffer
sim: sim-ccx-protocol-1h
sim: sim-ccx-protocol-2h sim-ccx-protocol-4h
sim: sim-ccx-coherent-2h sim-ccx-coherent-4h
sim: sim-ccx-coherent-protocol-2h sim-ccx-coherent-protocol-4h
sim: sim-ccx-4h-l1d-directory-l2
sim: sim-ccx-l2
sim: sim-genbus-axi sim-genbus-wb-widths
sim: sim-core-complex-1h-axi sim-core-complex-2h-axi \
	sim-core-complex-4h-wb
