# Software artifact build recipes.

$(UART_FIRMWARE_ELF): $(OPENRV64_MAKEFILES) sw/start.S sw/uart.c sw/openrv64.ld
	$(RISCV_CC) $(UART_FIRMWARE_CFLAGS) -nostdlib -nostartfiles \
		-Wl,--build-id=none,-Map=$(UART_FIRMWARE_MAP) \
		-T sw/openrv64.ld -o $@ sw/start.S sw/uart.c

$(UART_FIRMWARE_BIN): $(UART_FIRMWARE_ELF)
	$(RISCV_OBJCOPY) -O binary $< $@

$(COREMARK_LOOP_ELF): $(OPENRV64_MAKEFILES) sw/coremark_loop_start.S \
		sw/coremark_loop.c sw/openrv64.ld
	$(RISCV_CC) $(COREMARK_LOOP_CFLAGS) -nostdlib \
		-Wl,--build-id=none,--gc-sections,-Map,$(COREMARK_LOOP_MAP) \
		-T sw/openrv64.ld -o $@ sw/coremark_loop_start.S \
		sw/coremark_loop.c

$(COREMARK_LOOP_BIN): $(COREMARK_LOOP_ELF)
	$(RISCV_OBJCOPY) -O binary $< $@

$(CORE_3P_MAGIC_ELF): $(OPENRV64_MAKEFILES) sw/coremark_loop_start.S \
		sw/coremark_loop.c sw/openrv64-magic.ld
	mkdir -p $(dir $@)
	$(RISCV_CC) $(COREMARK_LOOP_CFLAGS) -nostdlib \
		-Wl,--build-id=none,--gc-sections,-Map,$(CORE_3P_MAGIC_MAP) \
		-T sw/openrv64-magic.ld -o $@ sw/coremark_loop_start.S \
		sw/coremark_loop.c

$(CORE_3P_MAGIC_BIN): $(CORE_3P_MAGIC_ELF)
	$(RISCV_OBJCOPY) -O binary $< $@

$(CORE_3P_MAGIC_MEMH): $(CORE_3P_MAGIC_BIN) tools/bin2mem.py
	$(PYTHON) tools/bin2mem.py $< $@ \
		--size $(CORE_3P_MAGIC_SRAM_BYTES) --word-bytes 32

$(CORE_3P_VM_ELF): $(OPENRV64_MAKEFILES) sw/coremark_loop_vm_start.S \
		sw/coremark_loop.c sw/openrv64-vm.ld
	mkdir -p $(dir $@)
	$(RISCV_CC) $(COREMARK_VM_CFLAGS) -nostdlib \
		-Wl,--build-id=none,--gc-sections,-Map,$(CORE_3P_VM_MAP) \
		-T sw/openrv64-vm.ld -o $@ sw/coremark_loop_vm_start.S \
		sw/coremark_loop.c

$(CORE_3P_VM_BIN): $(CORE_3P_VM_ELF)
	$(RISCV_OBJCOPY) -O binary $< $@

$(CORE_3P_VM_MEMH): $(CORE_3P_VM_BIN) tools/bin2mem.py
	$(PYTHON) tools/bin2mem.py $< $@ \
		--size $(CORE_3P_VM_MEMH_BYTES) --word-bytes 32

$(CORE_3P_VM_DISASM): $(CORE_3P_VM_ELF)
	$(RISCV_OBJDUMP) -d -M no-aliases $< > $@

$(CORE_4H_VM_ELF): $(OPENRV64_MAKEFILES) sw/coremark_4h_vm_start.S \
		sw/coremark_loop.c sw/openrv64-vm.ld
	mkdir -p $(dir $@)
	$(RISCV_CC) $(COREMARK_VM_CFLAGS) -nostdlib \
		-Wl,--build-id=none,--gc-sections,-Map,$(CORE_4H_VM_MAP) \
		-T sw/openrv64-vm.ld -o $@ sw/coremark_4h_vm_start.S \
		sw/coremark_loop.c

$(CORE_4H_VM_TEMPLATE_BIN): $(CORE_4H_VM_ELF)
	$(RISCV_OBJCOPY) -O binary $< $@

$(CORE_4H_VM_BIN): $(CORE_4H_VM_TEMPLATE_BIN) \
		tools/make_4h_sv39_image.py
	$(PYTHON) tools/make_4h_sv39_image.py $< $@

$(CORE_4H_VM_MEMH): $(CORE_4H_VM_BIN) tools/bin2mem.py
	$(PYTHON) tools/bin2mem.py $< $@ \
		--size $(CORE_4H_VM_MEMH_BYTES) --word-bytes 64

$(CORE_4H_VM_DISASM): $(CORE_4H_VM_ELF)
	$(RISCV_OBJDUMP) -d -M no-aliases $< > $@

$(CORE_4H_SHARED_VM_ELF): $(OPENRV64_MAKEFILES) \
		sw/coremark_4h_shared_vm_start.S sw/coremark_loop.c \
		sw/openrv64-4h-shared-vm.ld
	mkdir -p $(dir $@)
	$(RISCV_CC) $(COREMARK_VM_CFLAGS) -nostdlib \
		-Wl,--build-id=none,--gc-sections,-Map,$(CORE_4H_SHARED_VM_MAP) \
		-T sw/openrv64-4h-shared-vm.ld -o $@ \
		sw/coremark_4h_shared_vm_start.S sw/coremark_loop.c

$(CORE_4H_SHARED_VM_TEMPLATE_BIN): $(CORE_4H_SHARED_VM_ELF)
	$(RISCV_OBJCOPY) -O binary $< $@

$(CORE_4H_SHARED_VM_BIN): $(CORE_4H_SHARED_VM_TEMPLATE_BIN) \
		tools/make_shared_sv39_image.py
	$(PYTHON) tools/make_shared_sv39_image.py $< $@

$(CORE_4H_SHARED_VM_MEMH): $(CORE_4H_SHARED_VM_BIN) tools/bin2mem.py
	$(PYTHON) tools/bin2mem.py $< $@ \
		--size $(CORE_4H_SHARED_VM_MEMH_BYTES) --word-bytes 64

$(CORE_4H_SHARED_VM_DISASM): $(CORE_4H_SHARED_VM_ELF)
	$(RISCV_OBJDUMP) -d -M no-aliases $< > $@

$(CORE_4H_BARE_ELF): $(OPENRV64_MAKEFILES) \
		sw/coremark_4h_shared_vm_start.S sw/coremark_loop.c \
		sw/openrv64-4h-bare.ld
	mkdir -p $(dir $@)
	$(RISCV_CC) $(COREMARK_VM_CFLAGS) -DOPENRV64_4H_BARE -nostdlib \
		-Wl,--build-id=none,--gc-sections,-Map,$(CORE_4H_BARE_MAP) \
		-T sw/openrv64-4h-bare.ld -o $@ \
		sw/coremark_4h_shared_vm_start.S sw/coremark_loop.c

$(CORE_4H_BARE_BIN): $(CORE_4H_BARE_ELF)
	$(RISCV_OBJCOPY) -O binary $< $@

$(CORE_4H_BARE_MEMH): $(CORE_4H_BARE_BIN) tools/bin2mem.py
	$(PYTHON) tools/bin2mem.py $< $@ \
		--size $(CORE_4H_BARE_MEMH_BYTES) --word-bytes 64

$(CORE_4H_BARE_DISASM): $(CORE_4H_BARE_ELF)
	$(RISCV_OBJDUMP) -d -M no-aliases $< > $@

$(ATOMIC_4H_SHARED_VM_ELF): $(OPENRV64_MAKEFILES) \
		sw/atomic_4h_shared_vm.S sw/openrv64-4h-shared-vm.ld
	mkdir -p $(dir $@)
	$(RISCV_CC) $(ATOMIC_SOC_ASFLAGS) \
		-Wl,--build-id=none,--gc-sections,-Map,$(ATOMIC_4H_SHARED_VM_MAP) \
		-T sw/openrv64-4h-shared-vm.ld -o $@ \
		sw/atomic_4h_shared_vm.S

$(ATOMIC_4H_SHARED_VM_TEMPLATE_BIN): $(ATOMIC_4H_SHARED_VM_ELF)
	$(RISCV_OBJCOPY) -O binary $< $@

$(ATOMIC_4H_SHARED_VM_BIN): $(ATOMIC_4H_SHARED_VM_TEMPLATE_BIN) \
		tools/make_shared_sv39_image.py
	$(PYTHON) tools/make_shared_sv39_image.py $< $@

$(ATOMIC_4H_SHARED_VM_MEMH): $(ATOMIC_4H_SHARED_VM_BIN) tools/bin2mem.py
	$(PYTHON) tools/bin2mem.py $< $@ \
		--size $(ATOMIC_4H_SHARED_VM_MEMH_BYTES) --word-bytes 64

$(ATOMIC_4H_SHARED_VM_DISASM): $(ATOMIC_4H_SHARED_VM_ELF)
	$(RISCV_OBJDUMP) -d -M no-aliases $< > $@

$(ZERO_VM_ELF): $(OPENRV64_MAKEFILES) sw/zero/zero_sv39.S \
		sw/zero/openrv64-zero-sv39.ld
	mkdir -p $(dir $@)
	$(RISCV_CC) $(COREMARK_VM_CFLAGS) -nostdlib \
		-Wl,--build-id=none,--gc-sections,-Map,$(ZERO_VM_MAP) \
		-T sw/zero/openrv64-zero-sv39.ld -o $@ \
		sw/zero/zero_sv39.S

$(ZERO_VM_BIN): $(ZERO_VM_ELF)
	$(RISCV_OBJCOPY) -O binary $< $@

$(ZERO_VM_MEMH): $(ZERO_VM_BIN) tools/bin2mem.py
	$(PYTHON) tools/bin2mem.py $< $@ \
		--size $(ZERO_VM_MEMH_BYTES) --word-bytes 32

$(ZERO_VM_DISASM): $(ZERO_VM_ELF)
	$(RISCV_OBJDUMP) -d -M no-aliases $< > $@

$(ATOMIC_SOC_ELF): $(OPENRV64_MAKEFILES) sw/atomic/atomic.S sw/openrv64.ld
	mkdir -p $(dir $@)
	$(RISCV_CC) $(ATOMIC_SOC_ASFLAGS) \
		-Wl,--build-id=none,-Map,$(ATOMIC_SOC_MAP) \
		-T sw/openrv64.ld -o $@ sw/atomic/atomic.S

$(ATOMIC_SOC_BIN): $(ATOMIC_SOC_ELF)
	$(RISCV_OBJCOPY) -O binary $< $@

$(ATOMIC_SOC_DISASM): $(ATOMIC_SOC_ELF)
	$(RISCV_OBJDUMP) -d -M no-aliases $< > $@

$(ATOMIC_SOC_MEMH): $(ATOMIC_SOC_BIN) tools/bin2mem.py
	mkdir -p $(dir $@)
	$(PYTHON) tools/bin2mem.py $< $@ \
		--size $(ATOMIC_SOC_MEMH_BYTES) --word-bytes 32

$(MEMCPY_4K_ELF): $(OPENRV64_MAKEFILES) sw/memcpy/memcpy.S sw/openrv64.ld
	mkdir -p $(dir $@)
	$(RISCV_CC) $(MEMCPY_ASFLAGS) \
		-Wa,--defsym,MEMCPY_BYTES=4096 \
		-Wl,--build-id=none,-Map,$(MEMCPY_4K_MAP) \
		-T sw/openrv64.ld -o $@ sw/memcpy/memcpy.S

$(MEMCPY_4K_BIN): $(MEMCPY_4K_ELF)
	$(RISCV_OBJCOPY) -O binary $< $@

$(MEMCPY_4K_DISASM): $(MEMCPY_4K_ELF)
	$(RISCV_OBJDUMP) -d -M no-aliases $< > $@

$(MEMCPY_64K_ELF): $(OPENRV64_MAKEFILES) sw/memcpy/memcpy.S sw/openrv64.ld
	mkdir -p $(dir $@)
	$(RISCV_CC) $(MEMCPY_ASFLAGS) \
		-Wa,--defsym,MEMCPY_BYTES=65536 \
		-Wl,--build-id=none,-Map,$(MEMCPY_64K_MAP) \
		-T sw/openrv64.ld -o $@ sw/memcpy/memcpy.S

$(MEMCPY_64K_BIN): $(MEMCPY_64K_ELF)
	$(RISCV_OBJCOPY) -O binary $< $@

$(MEMCPY_64K_DISASM): $(MEMCPY_64K_ELF)
	$(RISCV_OBJDUMP) -d -M no-aliases $< > $@

$(L1I_COREMARK_MEMH): $(COREMARK_LOOP_BIN) tools/bin2mem.py
	$(PYTHON) tools/bin2mem.py $< $@ --size 0x800 --word-bytes 64

$(VEC_MATMUL_ELF): $(OPENRV64_MAKEFILES) sw/vector/matmul.S sw/vector/matmul.ld
	mkdir -p $(VEC_MATMUL_BUILD_DIR)
	$(RISCV_CC) -march=rv64i -mabi=lp64 -mcmodel=medany -mno-relax \
		-nostdlib -nostartfiles -Wl,--build-id=none,-Map,$(VEC_MATMUL_MAP) \
		-T sw/vector/matmul.ld -o $@ sw/vector/matmul.S

$(VEC_MATMUL_BIN): $(VEC_MATMUL_ELF)
	$(RISCV_OBJCOPY) -O binary $< $@

$(VEC_MATMUL_DISASM): $(VEC_MATMUL_ELF)
	$(RISCV_OBJDUMP) -d -M no-aliases $< > $@

$(VEC_MATMUL_MEMH): $(VEC_MATMUL_BIN) tools/bin2mem.py
	$(PYTHON) tools/bin2mem.py $< $@ --size 0x700 --word-bytes 8

$(VEC_MATMUL_BF16_ELF): $(OPENRV64_MAKEFILES) sw/matmul_bf16.S sw/matmul_bf16.ld
	mkdir -p $(VEC_MATMUL_BUILD_DIR)
	$(RISCV_CC) -march=rv64i -mabi=lp64 -mcmodel=medany -mno-relax \
		-nostdlib -nostartfiles \
		-Wl,--build-id=none,-Map,$(VEC_MATMUL_BF16_MAP) \
		-T sw/matmul_bf16.ld -o $@ sw/matmul_bf16.S

$(VEC_MATMUL_BF16_BIN): $(VEC_MATMUL_BF16_ELF)
	$(RISCV_OBJCOPY) -O binary $< $@

$(VEC_MATMUL_BF16_DISASM): $(VEC_MATMUL_BF16_ELF)
	$(RISCV_OBJDUMP) -d -M no-aliases $< > $@

$(VEC_MATMUL_BF16_MEMH): $(VEC_MATMUL_BF16_BIN) tools/bin2mem.py
	$(PYTHON) tools/bin2mem.py $< $@ --size 0xf00 --word-bytes 8

$(A53_COREMARK_ELF): $(OPENRV64_MAKEFILES) sw/arm_a53/coremark_loop_start.S \
		sw/coremark_loop.c sw/arm_a53/coremark_loop.ld
	mkdir -p $(dir $@)
	$(AARCH64_CC) $(A53_COREMARK_CFLAGS) -nostdlib -nostartfiles \
		-static -no-pie \
		-Wl,--build-id=none,--gc-sections,-Map,$(A53_COREMARK_MAP) \
		-T sw/arm_a53/coremark_loop.ld -o $@ \
		sw/arm_a53/coremark_loop_start.S sw/coremark_loop.c

$(A53_COREMARK_BIN): $(A53_COREMARK_ELF)
	$(AARCH64_OBJCOPY) -O binary $< $@

$(A53_COREMARK_DISASM): $(A53_COREMARK_ELF)
	$(AARCH64_OBJDUMP) -d -S $< > $@

$(A53_GEM5_ELF): $(OPENRV64_MAKEFILES) sw/arm_a53/coremark_loop_se_start.S \
		sw/coremark_loop.c sw/arm_a53/coremark_loop_se.ld
	mkdir -p $(dir $@)
	$(AARCH64_CC) $(A53_COREMARK_CFLAGS) -nostdlib -nostartfiles \
		-static -no-pie \
		-Wl,--build-id=none,--gc-sections,-Map,$(A53_GEM5_MAP) \
		-T sw/arm_a53/coremark_loop_se.ld -o $@ \
		sw/arm_a53/coremark_loop_se_start.S sw/coremark_loop.c

$(A53_GEM5_DISASM): $(A53_GEM5_ELF)
	$(AARCH64_OBJDUMP) -d -S $< > $@

$(AXI_3P_PERF_BIN): $(AXI_3P_PERF_ELF)
	mkdir -p $(dir $@)
	$(RISCV_OBJCOPY) -O binary $< $@

$(AXI_3P_PERF_MEMH): $(AXI_3P_PERF_BIN) tools/bin2mem.py
	mkdir -p $(dir $@)
	$(PYTHON) tools/bin2mem.py $(AXI_3P_PERF_BIN) $@ \
		--size $(AXI_3P_PERF_MEMH_BYTES) --word-bytes 32

$(UART_FIRMWARE_MEMH): $(UART_FIRMWARE_BIN) tools/bin2mem.py
	mkdir -p $(dir $@)
	$(PYTHON) tools/bin2mem.py $< $@ --size 0x10000
