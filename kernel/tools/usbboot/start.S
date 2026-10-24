/* Entry of stage2: the parameter block sits at a fixed offset (8) that the
 * host fills in before upload. */
	.set	noreorder
	.section .text.start, "ax"
	.globl	_start
	.globl	params
_start:
	b	1f
	nop
params:
	.word	0x54423152	/* magic "R1BT" */
	.space	4 * 13
1:	li	$sp, 0x8000e000
	jal	stage2_main
	nop
2:	b	2b
	nop
