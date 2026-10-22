ENTRY(_start)
SECTIONS
{
	. = 0x80010000;
	.text : { *(.text.start) *(.text*) *(.rodata*) }
	/DISCARD/ : { *(.data*) *(.sdata*) *(.bss*) *(.sbss*) *(.MIPS.*) *(.reginfo) *(.comment) *(.pdr) *(.gnu.attributes) }
	. = ALIGN(16) + 4096;
	_stack_top = .;
}
