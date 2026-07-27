# Minimal Linux configuration for OpenRV64

This document describes a first-boot Linux configuration for the current
single-hart OpenRV64 platform running in S-mode under OpenSBI. The immediate
target is early console output, normal `printk`/`dmesg`, working timer ticks,
and an intentional panic when no root filesystem is present. An initramfs can
be added after that path works.

The configuration fragment below was resolved with `olddefconfig` against the
local Linux 7.2.0-rc4 tree in `/home/bill/src/linux`. Kconfig dependencies can
change, so re-run the checks in this document when changing kernel versions.

## Hardware and firmware contract

| Item                    | Current OpenRV64 contract                                        |
|-------------------------|------------------------------------------------------------------|
| Execution mode          | Linux in S-mode; OpenSBI remains in M-mode                       |
| ISA                     | RV64IMA, Zicsr, Zifencei, Zicntr, Svade                          |
| Deliberately absent     | C, F, D, V                                                       |
| Virtual memory          | Sv39                                                             |
| Page-table A/D behavior | Svade: clear A or D bits cause page faults for software handling |
| Harts                   | One                                                              |
| RAM                     | `0x8000_0000` through `0x8fff_ffff` (256 MiB)                    |
| OpenSBI firmware        | `0x8010_0000`                                                    |
| Linux `Image`           | `0x8020_0000`                                                    |
| FDT                     | `0x8ff0_0000`, passed in `a1`; hart ID 0 passed in `a0`          |
| Timebase                | 10 MHz                                                           |
| Clock event             | SBI TIME, delivered to Linux as STIP                             |
| UART                    | `ns16550a` at `0x1000_0000`, 1.8432 MHz input clock, 115200 baud |
| External interrupts     | PLIC at `0x0c00_0000`; see the PLIC limitation below             |

The raw RISC-V Linux `Image` must be used. It is already linked for the
standard RISC-V load offset and `0x8020_0000` is 2 MiB aligned. Do not load
`vmlinux`, an ELF file, or a compressed `Image.xz` into the current raw-image
loader.

## Required CPU configuration

These settings are not optional for this RTL:

```text
CONFIG_ARCH_RV64I=y
CONFIG_MMU=y
CONFIG_NONPORTABLE=y
# CONFIG_RISCV_M_MODE is not set
# CONFIG_SMP is not set
# CONFIG_RISCV_ISA_C is not set
# CONFIG_FPU is not set
# CONFIG_RISCV_ISA_V is not set
CONFIG_RISCV_EMULATED_UNALIGNED_ACCESS=y
```

The reasons are:

- `CONFIG_MMU=y` selects the normal Sv39 Linux path. A no-MMU kernel is a
  different target and would not validate the implemented MMU.
- `CONFIG_RISCV_M_MODE=n` is required because OpenSBI enters Linux in S-mode.
  It also causes Linux to select `CONFIG_RISCV_SBI=y`.
- `CONFIG_SMP=n` matches the one-hart platform and removes HSM/IPI and
  secondary-hart assumptions from initial bring-up.
- `CONFIG_RISCV_ISA_C=n` is mandatory. The core does not implement compressed
  instructions. Leaving the Linux default enabled causes an illegal
  instruction before useful diagnostics are likely.
- `CONFIG_FPU=n` and `CONFIG_RISCV_ISA_V=n` match the scalar integer core.
  The repository's experimental vector RTL is not the ratified RISC-V V
  extension and must not be advertised to Linux.
- `CONFIG_RISCV_EMULATED_UNALIGNED_ACCESS=y` avoids treating unaligned access
  as efficient hardware behavior and retains Linux emulation for userspace.
  Kernel code is built with strict alignment.

`CONFIG_NONPORTABLE=y` needs special emphasis. In Linux 7.2-rc4,
`CONFIG_PORTABLE` selects EFI, and RISC-V EFI selects
`CONFIG_RISCV_ISA_C`. Consequently, attempting to disable `C` while leaving
the portable default enabled does not work: `olddefconfig` turns `C` back on.
Selecting `NONPORTABLE` removes that forced EFI/`C` chain. Also keep
`CONFIG_EFI=n`.

## Minimum `dmesg` fragment

Start from `tinyconfig` and merge this fragment:

```text
# Raw, uncompressed arch/riscv/boot/Image.
CONFIG_KERNEL_UNCOMPRESSED=y
# CONFIG_KERNEL_XZ is not set

# CPU, privilege, and memory model.
CONFIG_ARCH_RV64I=y
CONFIG_MMU=y
CONFIG_NONPORTABLE=y
# CONFIG_RISCV_M_MODE is not set
# CONFIG_SMP is not set
# CONFIG_RISCV_ISA_C is not set
# CONFIG_FPU is not set
# CONFIG_RISCV_ISA_V is not set
CONFIG_RISCV_EMULATED_UNALIGNED_ACCESS=y
# CONFIG_RISCV_PROBE_UNALIGNED_ACCESS is not set

# Reduce simulated timer traffic.
CONFIG_HZ_100=y
# CONFIG_HZ_250 is not set

# OpenSBI, timer, and interrupt-controller paths. Most are selected by RISCV,
# but listing them makes the required final .config state explicit.
CONFIG_RISCV_SBI=y
# CONFIG_RISCV_SBI_V01 is not set
CONFIG_RISCV_TIMER=y
CONFIG_RISCV_INTC=y
CONFIG_SIFIVE_PLIC=y

# Diagnostic output and the DT-described 16550 UART.
CONFIG_PRINTK=y
CONFIG_BUG=y
CONFIG_TTY=y
# CONFIG_VT is not set
CONFIG_SERIAL_8250=y
CONFIG_SERIAL_8250_CONSOLE=y
CONFIG_SERIAL_8250_NR_UARTS=1
CONFIG_SERIAL_8250_RUNTIME_UARTS=1
CONFIG_SERIAL_OF_PLATFORM=y
CONFIG_SERIAL_EARLYCON_RISCV_SBI=y

# The current DT has no bootargs. Force a known diagnostic command line for
# bring-up. earlycon=sbi uses the OpenSBI DBCN extension.
CONFIG_CMDLINE="earlycon=sbi console=ttyS0,115200n8 ignore_loglevel loglevel=8"
CONFIG_CMDLINE_FORCE=y

# No corresponding platform devices exist yet.
# CONFIG_MODULES is not set
# CONFIG_BLOCK is not set
# CONFIG_NET is not set
# CONFIG_PCI is not set
# CONFIG_ACPI is not set
# CONFIG_EFI is not set
# CONFIG_BLK_DEV_INITRD is not set
```

This configuration is expected to print the boot log and eventually panic
because no root filesystem was supplied. That panic is success for the first
milestone; it proves substantially more than the existing S-mode SBI payload.

`earlycon=sbi` is the first console and uses the OpenSBI debug-console
extension already exercised by the OpenSBI smoke test. The normal
`console=ttyS0` path takes over after the DT-backed 8250 driver probes.
Keeping both paths distinguishes an early kernel failure from a UART-driver
failure.

`CONFIG_ARCH_VIRT` is not required. The CPU interrupt controller, RISC-V
timer, PLIC, OF, and SBI support are generic RISC-V selections; OpenRV64 is
not a QEMU `virt` machine even though parts of its physical map are similar.

## Producing the configuration and `Image`

Save the fragment above as `/tmp/openrv64-linux.fragment`, then run:

```sh
linux=/home/bill/src/linux
out=/tmp/openrv64-linux-build

make -C "$linux" O="$out" ARCH=riscv tinyconfig
cp "$out/.config" "$out/tiny-base.config"
"$linux/scripts/kconfig/merge_config.sh" -m -O "$out" \
    "$out/tiny-base.config" /tmp/openrv64-linux.fragment
make -C "$linux" O="$out" ARCH=riscv \
    CROSS_COMPILE=riscv64-linux-gnu- olddefconfig

make -C "$linux" O="$out" ARCH=riscv \
    CROSS_COMPILE=riscv64-linux-gnu- -j"$(nproc)" Image
```

The file to load is:

```text
/tmp/openrv64-linux-build/arch/riscv/boot/Image
```

Check the resolved configuration before simulation:

```sh
grep -E \
  'CONFIG_(PRINTK|NONPORTABLE|RISCV_ISA_C|FPU|RISCV_ISA_V|SMP|MMU|RISCV_SBI|RISCV_TIMER|SERIAL_8250|SERIAL_OF_PLATFORM|SERIAL_EARLYCON_RISCV_SBI|CMDLINE)' \
  "$out/.config"
```

Require `CONFIG_PRINTK=y`; `earlycon` and the UART console can register with
`CONFIG_PRINTK=n`, but there is no kernel log buffer to replay and their write
callbacks will never receive normal kernel messages.

Reject the build if any of these appear:

```text
# CONFIG_PRINTK is not set
CONFIG_RISCV_ISA_C=y
CONFIG_FPU=y
CONFIG_RISCV_ISA_V=y
CONFIG_SMP=y
CONFIG_RISCV_M_MODE=y
CONFIG_EFI=y
```

The kernel build itself has no libc dependency and uses the soft-float LP64
ABI when `CONFIG_FPU=n`. The installed `riscv64-linux-gnu-` compiler is
suitable for building the kernel.

## Adding a minimal initramfs

There is currently no DT-described block device or network device. A kernel
cannot reach a persistent root filesystem until such a device is added. The
shortest path to a shell is therefore an initramfs embedded in `Image`.

Add:

```text
CONFIG_BLK_DEV_INITRD=y
CONFIG_INITRAMFS_SOURCE="/absolute/path/to/openrv64-rootfs"
CONFIG_INITRAMFS_COMPRESSION_NONE=y
CONFIG_BINFMT_ELF=y
CONFIG_BINFMT_SCRIPT=y
CONFIG_DEVTMPFS=y
CONFIG_TMPFS=y
CONFIG_PROC_FS=y
CONFIG_SYSFS=y
```

Append `rdinit=/init` to `CONFIG_CMDLINE`. The rootfs must contain an
executable `/init`; that program should mount `/proc`, `/sys`, and `/dev`
itself. `CONFIG_DEVTMPFS_MOUNT` does not automatically mount `/dev` while
running from initramfs.

Do not use an ordinary RISC-V distribution BusyBox binary without inspecting
it. Most RV64 distribution userspace is built for RV64GC with the LP64D ABI,
so it may contain compressed and floating-point instructions that this core
cannot execute. The initial userspace must be statically built for
RV64IMA/Zicsr/Zifencei with the soft-float LP64 ABI, or be a deliberately tiny
assembly/C init with the same ISA constraints.

An external initrd is possible later, but the simulator would need to load it
into free RAM and add `linux,initrd-start` and `linux,initrd-end` to `/chosen`.
Embedding it avoids that additional loader and DT work.

## Platform issues Kconfig cannot fix

The sole PLIC context is supervisor external interrupt 9 and drives `SEIP`,
matching the device tree. The minimal platform does not provide a separate
machine PLIC context.

### Zicntr DT declaration

The hardware and OpenSBI expose the `time` counter, and the legacy
`riscv,isa` property makes current Linux infer Zicntr from `i`. However, the
new `riscv,isa-extensions` binding does not make that implication. Add
`"zicntr"` to `riscv,isa-extensions` and `_zicntr` to the legacy ISA string so
the DT states the hardware contract directly rather than relying on legacy
inference.

### No root or shutdown device

The current DT has RAM, CPU interrupt control, CLINT, PLIC, and UART only.
There is no block device, network device, or poweroff/reset device. Expect a
no-root panic with the first fragment. Use an embedded initramfs for the next
milestone and terminate simulation by recognizing a chosen console string or
testbench-visible completion write.

## Expected first-boot checkpoints

The useful order is:

1. OpenSBI banner and handoff to `0x8020_0000`.
2. SBI early-console Linux banner.
3. CPU ISA line showing no C/F/D/V and Svade present.
4. 256 MiB memory discovery from the FDT.
5. Sv39 page-table setup without an A/D-bit fault loop.
6. `riscv-timer` registration at 10 MHz.
7. Repeated timer interrupts without a hang.
8. `ttyS0` probe and console handoff.
9. Expected root-filesystem panic, or `/init` when an initramfs is embedded.

If output stops before the normal 8250 console registers, keep the SBI
earlycon enabled and debug the last printed checkpoint. If time stops or the
kernel hangs after enabling interrupts, inspect SBI TIME calls and STIP
delivery before changing scheduler or tick Kconfig options.
