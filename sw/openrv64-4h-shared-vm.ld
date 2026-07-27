OUTPUT_ARCH(riscv)
ENTRY(_start)

PHDRS
{
    boot PT_LOAD FLAGS(5);
    supervisor_text PT_LOAD FLAGS(5);
    supervisor_data PT_LOAD FLAGS(6);
    page_tables PT_LOAD FLAGS(4);
}

SECTIONS
{
    .boot 0x80000000 :
    {
        KEEP(*(.text.boot))
    } :boot

    /*
     * All harts execute one supervisor image and install the same Sv39 root.
     * The four private pages are selected in software with mhartid.
     */
    .text 0x40001000 : AT(0x80001000)
    {
        KEEP(*(.text.startup))
        *(.text .text.*)
    } :supervisor_text

    .rodata ALIGN(8) :
        AT(0x80000000 + (ADDR(.rodata) - 0x40000000))
    {
        *(.rodata .rodata.*)
    } :supervisor_text

    .data ALIGN(8) :
        AT(0x80000000 + (ADDR(.data) - 0x40000000))
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

    .page_table.root 0x80020000 : AT(0x80020000)
    {
        KEEP(*(.page_table.root))
    } :page_tables

    .page_table.level1 0x80021000 : AT(0x80021000)
    {
        KEEP(*(.page_table.level1))
    } :page_tables

    .page_table.level0 0x80022000 : AT(0x80022000)
    {
        KEEP(*(.page_table.level0))
    } :page_tables

    ASSERT(__supervisor_image_end <= 0x40020000,
           "shared supervisor image exceeds mapped 128 KiB window")
    ASSERT((__hart_private_start & 0xfff) == 0,
           "hart-private storage must be page aligned")
    ASSERT((__hart_private_end - __hart_private_start) == 16384,
           "four-hart private storage must contain four 4 KiB pages")
    ASSERT(SIZEOF(.page_table.root) == 4096,
           "Sv39 root page table must be exactly 4 KiB")
    ASSERT(SIZEOF(.page_table.level1) == 4096,
           "Sv39 level-1 page table must be exactly 4 KiB")
    ASSERT(SIZEOF(.page_table.level0) == 4096,
           "Sv39 level-0 page table must be exactly 4 KiB")

    /DISCARD/ :
    {
        *(.eh_frame .eh_frame.*)
        *(.note .note.*)
    }
}
