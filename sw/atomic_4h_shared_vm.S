.section .text.boot, "ax", @progbits
.option norvc
.globl _start
.type _start, @function

_start:
    la   t0, machine_trap
    csrw mtvec, t0

    li   t0, 0x201fffff
    csrw pmpaddr0, t0
    li   t0, 0x1f
    csrw pmpcfg0, t0

    csrr tp, mhartid
    li   t0, 4
    bgeu tp, t0, machine_trap

    /* One address space: the SATP value is identical on every hart. */
    la   t0, root_page_table
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
    li   a0, 0x41544f4d4641494c
    ebreak
.Lmachine_halt:
    j    .Lmachine_halt

.size _start, .-_start

.section .text.startup, "ax", @progbits
.option norvc
.globl supervisor_start
.type supervisor_start, @function

.equ ATOMIC_SUCCESSES_PER_HART, 64
.equ ATOMIC_FINAL_VALUE, 256

supervisor_start:
    la   s4, atomic_4h_private_pages
    slli t0, tp, 12
    add  s4, s4, t0
    li   t0, 4096
    add  sp, s4, t0
    addi sp, sp, -16

    la   s1, atomic_4h_counter
    li   s2, ATOMIC_SUCCESSES_PER_HART
    li   s3, ATOMIC_FINAL_VALUE
    li   s0, 0

/*
 * Only hart (counter mod 4) is allowed to attempt the SC.  Every successful
 * SC advances by exactly one.  Other harts continuously establish reservations
 * and shared L1D copies on the same line, forcing real cross-hart invalidation.
 * The turn schedule does not require SC failure: only the eligible hart issues
 * SC, while the other three harts keep reading.
 */
.Latomic_retry:
    lr.w.aq t0, (s1)
    bgeu t0, s3, .Latomic_complete
    andi t1, t0, 3
    bne  t1, tp, .Latomic_retry
    addi t2, t0, 1
    sc.w.rl t3, t2, (s1)
    bnez t3, .Latomic_retry
    addi s0, s0, 1
    j    .Latomic_retry

.Latomic_complete:
    /*
     * Each hart records both completion and its successful-SC count in its
     * own page.  The testbench requires exactly 64 successes from each hart.
     */
    addi t0, tp, 1
    sw   t0, 0(s4)
    sw   s0, 4(s4)
    sw   t0, 8(s4)
    fence rw, rw

    .globl atomic_4h_shared_vm_done
atomic_4h_shared_vm_done:
    addi x0, x0, 0
.Lsupervisor_halt:
    j    .Lsupervisor_halt

.size supervisor_start, .-supervisor_start

.section .data, "aw", @progbits
.balign 64
.globl atomic_4h_counter
atomic_4h_counter:
    .word 0
    .zero 60

.section .hart_private, "aw", @nobits
.balign 4096
.globl atomic_4h_private_pages
atomic_4h_private_pages:
    .zero 16384
.globl atomic_4h_success_base
.set atomic_4h_success_base, atomic_4h_private_pages + 4

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
