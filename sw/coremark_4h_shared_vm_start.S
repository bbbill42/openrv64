.section .text.boot, "ax", @progbits
.option norvc
.globl _start
.type _start, @function

/*
 * All four harts share code and read-only data.  Supervisor code uses
 * mhartid to select one private 4 KiB page for its stack, sink, and
 * completion record.  OPENRV64_4H_BARE leaves satp in Bare mode; otherwise
 * all four harts install exactly the same Sv39 root.
 */
_start:
    la   t0, machine_trap
    csrw mtvec, t0

    /* One 16 MiB NAPOT PMP region covers 0x80000000-0x80ffffff. */
    li   t0, 0x201fffff
    csrw pmpaddr0, t0
    li   t0, 0x1f
    csrw pmpcfg0, t0

    csrr tp, mhartid
    li   t0, 4
    bgeu tp, t0, machine_trap

#ifndef OPENRV64_4H_BARE
    /* Every hart writes the same SATP value. */
    la   t0, root_page_table
    srli t0, t0, 12
    li   t1, 8
    slli t1, t1, 60
    or   t0, t0, t1
    csrw satp, t0
    sfence.vma x0, x0
#endif

    la   t0, supervisor_start
    csrw mepc, t0
    li   t0, 0x800
    csrw mstatus, t0
    mret

machine_trap:
    li   a0, 0x5348415244464149
    ebreak
.Lmachine_halt:
    j    .Lmachine_halt

.size _start, .-_start

.section .text.startup, "ax", @progbits
.option norvc
.globl supervisor_start
.type supervisor_start, @function

supervisor_start:
    la   s0, coremark_4h_shared_pages
    slli t0, tp, 12
    add  s0, s0, t0
    li   t0, 4096
    add  sp, s0, t0
    addi sp, sp, -16

    /* Word 1 is this hart's private CoreMark-derived sink. */
    li   t0, 0x6d5a56a9
    sw   t0, 4(s0)
    addi a0, s0, 4
    call coremark_loop_with_sink
    sw   a0, 8(s0)

    /*
     * Word 0 is the completion mailbox.  Its VA is hart-private-base plus
     * mhartid*4096 even though every hart has the same page table.
     */
    addi t0, tp, 1
    sw   t0, 0(s0)
    fence rw, rw

    .globl coremark_4h_shared_vm_done
coremark_4h_shared_vm_done:
#ifdef OPENRV64_4H_BARE
    .globl coremark_4h_bare_done
coremark_4h_bare_done:
#endif
    addi x0, x0, 0
.Lsupervisor_halt:
    j    .Lsupervisor_halt

.size supervisor_start, .-supervisor_start

.section .hart_private, "aw", @nobits
.balign 4096
.globl coremark_4h_shared_pages
coremark_4h_shared_pages:
#ifdef OPENRV64_4H_BARE
    .globl coremark_4h_bare_pages
coremark_4h_bare_pages:
#endif
    .zero 16384

.section .page_table.root, "a", @progbits
.balign 4096
.globl root_page_table
root_page_table:
    .zero 4096

.section .page_table.level1, "a", @progbits
.balign 4096
level1_page_table:
    .zero 4096

.section .page_table.level0, "a", @progbits
.balign 4096
level0_page_table:
    .zero 4096
