/*
 * fbpaint: bare-metal test payload for r1jump. Paints eight colour bands,
 * 100 rows each, over the framebuffer the stock kernel left scanning out,
 * then spins until the watchdog resets the R1. Seeing the bands proves the
 * jump reached the payload.
 *
 *   a0: framebuffer physical address, a1: its length, a2: line length
 *   (all from fbinfo).
 */
static const unsigned short colours[8] = {
	0xf800, 0x07e0, 0x001f, 0xffff, 0xffe0, 0xf81f, 0x07ff, 0x0000,
};

void paint(unsigned long fb, unsigned long len, unsigned long line)
{
	/* Uncached, so the LCD controller's DMA sees every store at once. */
	volatile unsigned short *p = (volatile unsigned short *)(fb | 0xa0000000);
	unsigned long rows = len / line, r, x;

	for (r = 0; r < rows; r++) {
		unsigned short c = colours[(r / 100) % 8];

		for (x = 0; x < line / 2; x++)
			p[r * (line / 2) + x] = c;
	}
	for (;;)
		;
}
