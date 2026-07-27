.section .text.boot, "ax", @progbits
.option norvc
.globl _start
.type _start, @function

/*
 * All four harts reset at the common physical entry.  Each hart installs an
 * independent Sv39 root one 1 MiB physical prefix apart:
 *
 *   hart N: VA 0x40000000-0x4001ffff
 *        -> PA (0x80000000 + N*0x100000)-(+0x1ffff)
 *
 * The image builder copies the supervisor image and regenerates the page
 * tables under each prefix.  The virtual program image is identical.
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

    la   t0, root_page_table
    slli t1, tp, 20
    add  t0, t0, t1
    srli t0, t0, 12
    li   t1, 8
    slli t1, t1, 60
    or   t0, t0, t1
    csrw satp, t0
    sfence.vma x0, x0

    la   t0, supervisor_start
    csrw mepc, t0
    li   t0, 0x800
    csrw mstatus, t0
    mret

machine_trap:
    li   a0, 0x34484641494c
    ebreak
.Lmachine_halt:
    j    .Lmachine_halt

.size _start, .-_start

.section .text.startup, "ax", @progbits
.option norvc
.globl supervisor_start
.type supervisor_start, @function

supervisor_start:
    la   sp, __stack_top
    call coremark_loop

    /*
     * This store is the physical-prefix check.  The value identifies the
     * hart, while the virtual address is the same for all four harts.
     */
    la   t0, coremark_4h_done_mailbox
    addi t1, tp, 1
    sw   t1, 0(t0)
    fence rw, rw

    .globl coremark_4h_vm_done
coremark_4h_vm_done:
    addi x0, x0, 0
.Lsupervisor_halt:
    j    .Lsupervisor_halt

.size supervisor_start, .-supervisor_start

.section .data, "aw", @progbits
.balign 8
.globl coremark_4h_done_mailbox
coremark_4h_done_mailbox:
    .word 0
    .word 0

/*
 * Linker-sized template tables.  tools/make_4h_sv39_image.py regenerates all
 * entries for every physical prefix, including hart zero.
 */
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
