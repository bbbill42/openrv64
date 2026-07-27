OUTPUT_ARCH(riscv)
ENTRY(_start)

PHDRS
{
    boot PT_LOAD FLAGS(5);
    supervisor_text PT_LOAD FLAGS(5);
    supervisor_data PT_LOAD FLAGS(6);
}

SECTIONS
{
    .boot 0x80000000 :
    {
        KEEP(*(.text.boot))
    } :boot

    /*
     * Mirror the shared-Sv39 image layout at its physical addresses.  The
     * privilege transition remains, but satp stays Bare.
     */
    .text 0x80001000 :
    {
        KEEP(*(.text.startup))
        *(.text .text.*)
    } :supervisor_text

    .rodata ALIGN(8) :
    {
        *(.rodata .rodata.*)
    } :supervisor_text

    .data ALIGN(8) :
    {
        *(.data .data.*)
        *(.sdata .sdata.*)
    } :supervisor_data

    .bss ALIGN(8) (NOLOAD) :
    {
        __bss_start = .;
        *(.bss .bss.*)
        *(.sbss .sbss.*)
        *(COMMON)
        . = ALIGN(8);
        __bss_end = .;
    } :supervisor_data

    .hart_private ALIGN(4096) (NOLOAD) :
    {
        __hart_private_start = .;
        KEEP(*(.hart_private))
        __hart_private_end = .;
    } :supervisor_data

    __supervisor_image_end = .;
    PROVIDE(__global_pointer$ = __supervisor_image_end + 0x800);

    ASSERT(__supervisor_image_end <= 0x80020000,
           "bare shared image exceeds 128 KiB window")
    ASSERT((__hart_private_start & 0xfff) == 0,
           "hart-private storage must be page aligned")
    ASSERT((__hart_private_end - __hart_private_start) == 16384,
           "four-hart private storage must contain four 4 KiB pages")

    /DISCARD/ :
    {
        *(.page_table.*)
        *(.eh_frame .eh_frame.*)
        *(.note .note.*)
    }
}
