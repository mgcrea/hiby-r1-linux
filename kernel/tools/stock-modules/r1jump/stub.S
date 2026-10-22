/*
 * Position-independent final stage of r1jump, copied to a free page and run
 * uncached from KSEG1 with interrupts off. Uses registers only: no stack, no
 * cached loads or stores, so no stale line from the old kernel can be
 * written back over the new one later.
 *
 *   a0: KSEG1 address of struct r1jump_params (see r1jump.c)
 *
 * 1. Write back and invalidate L1 D and L2 by index, so memory holds
 *    everything the old kernel wrote (including the image pages).
 * 2. Copy each (dst, src) page through KSEG1.
 * 3. Invalidate L1 I and D, then jump to the entry point.
 */
#include <asm/asm.h>
#include <asm/regdef.h>

#define P_DLINE		0
#define P_DSIZE		4
#define P_SLINE		8
#define P_SSIZE		12
#define P_ILINE		16
#define P_ISIZE		20
#define P_LIST		24	/* KSEG1 address of the (dst, src) pairs */
#define P_COUNT		28
#define P_ENTRY		32
#define P_ARG0		36
#define P_ARG1		40
#define P_ARG2		44
#define P_ARG3		48

#define KSEG0		0x80000000
#define KSEG1		0xa0000000
#define PAGE		4096

	.set	noreorder
	.set	noat
	.set	mips32r2
	.text
	.globl	r1jump_stub
	.globl	r1jump_stub_end

r1jump_stub:
	move	s0, a0

	/* L1 D: Index_Writeback_Inv_D (op 1) */
	lw	t0, P_DLINE(s0)
	lw	t1, P_DSIZE(s0)
	li	t2, KSEG0
	addu	t3, t2, t1
1:	cache	0x01, 0(t2)
	addu	t2, t2, t0
	bne	t2, t3, 1b
	nop

	/* L2: Index_Writeback_Inv_SD (op 3), skipped when absent */
	lw	t0, P_SLINE(s0)
	lw	t1, P_SSIZE(s0)
	beqz	t1, 3f
	nop
	li	t2, KSEG0
	addu	t3, t2, t1
2:	cache	0x03, 0(t2)
	addu	t2, t2, t0
	bne	t2, t3, 2b
	nop
3:	sync

	/* Copy pages, uncached on both sides. */
	lw	t4, P_LIST(s0)
	lw	t5, P_COUNT(s0)
	li	t6, KSEG1
4:	beqz	t5, 6f
	nop
	lw	t0, 0(t4)		/* dst phys */
	lw	t1, 4(t4)		/* src phys */
	or	t0, t0, t6
	or	t1, t1, t6
	addiu	t2, t1, PAGE
5:	lw	t3, 0(t1)
	lw	t7, 4(t1)
	lw	t8, 8(t1)
	lw	t9, 12(t1)
	sw	t3, 0(t0)
	sw	t7, 4(t0)
	sw	t8, 8(t0)
	sw	t9, 12(t0)
	addiu	t1, t1, 16
	bne	t1, t2, 5b
	addiu	t0, t0, 16
	addiu	t4, t4, 8
	b	4b
	addiu	t5, t5, -1
6:	sync

	/* L1 I: Index_Invalidate_I (op 0) */
	lw	t0, P_ILINE(s0)
	lw	t1, P_ISIZE(s0)
	li	t2, KSEG0
	addu	t3, t2, t1
7:	cache	0x00, 0(t2)
	addu	t2, t2, t0
	bne	t2, t3, 7b
	nop

	/* L1 D again: nothing above went through it, but be certain. */
	lw	t0, P_DLINE(s0)
	lw	t1, P_DSIZE(s0)
	li	t2, KSEG0
	addu	t3, t2, t1
8:	cache	0x01, 0(t2)
	addu	t2, t2, t0
	bne	t2, t3, 8b
	nop
	sync

	lw	t9, P_ENTRY(s0)
	lw	a0, P_ARG0(s0)
	lw	a1, P_ARG1(s0)
	lw	a2, P_ARG2(s0)
	lw	a3, P_ARG3(s0)
	jr.hb	t9
	nop
r1jump_stub_end:
