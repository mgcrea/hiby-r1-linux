/*
 * Second USB-boot stage for the HiBy R1: run by the boot ROM (PROGRAM_START2)
 * after Rockbox's usbstage1 has set up DDR and the host has loaded the
 * kernel. Sets the PLLs and bus clocks to the values the host put in the
 * parameter block (stock's), clears the USB-boot request, arms the watchdog
 * and jumps to the kernel with a0..a3 from the block.
 */
#include <stdint.h>

#define REG(a)		(*(volatile uint32_t *)(a))
#define CPCCR		REG(0xb0000000)
#define CPAPCR		REG(0xb0000010)
#define CPMPCR		REG(0xb0000014)
#define CPEPCR		REG(0xb0000018)
#define CLKGR0		REG(0xb0000020)
#define SLPC		REG(0xb00000cc)
#define CPCSR		REG(0xb00000d4)

#define PLL_EN		0x1
#define PLL_ON		0x8
#define CCR_MUX		0xff000000	/* SEL_SRC, SEL_CPLL, SEL_H0PLL, SEL_H2PLL */
#define CCR_DIV		0x000fffff
#define CCR_CE		0x00700000
#define CSR_MUX_OK	0xf0000000
#define CSR_DIV_BUSY	0x7

#define TCU		0xb0002000
#define WDT_TDR		REG(TCU + 0x00)
#define WDT_TCER	(*(volatile uint8_t *)(TCU + 0x04))
#define WDT_TCSR	(*(volatile uint16_t *)(TCU + 0x0c))
#define TCU_TFCR	REG(TCU + 0x28)
#define TCU_TSCR	REG(TCU + 0x3c)

struct params {
	uint32_t magic;			/* "R1BT" */
	uint32_t entry;
	uint32_t arg[4];
	uint32_t apcr, mpcr, epcr, ccr;	/* 0: leave as is */
	uint32_t wdt_ticks;		/* 0: no watchdog */
	uint32_t status;		/* progress, for a host that reads it */
};

extern struct params params;

/* Busy loops that give up rather than hang the R1 with no way to tell. */
#define WAIT(cond)	do { int n = 1 << 22; while (!(cond) && --n); } while (0)

static void set_mux(uint32_t mux)
{
	CPCCR = (CPCCR & ~CCR_MUX & ~CCR_CE) | (mux & CCR_MUX);
	WAIT((CPCSR & CSR_MUX_OK) == CSR_MUX_OK);
}

static void set_div(uint32_t div)
{
	CPCCR = (CPCCR & ~CCR_DIV) | (div & CCR_DIV & ~CCR_CE) | CCR_CE;
	WAIT(!(CPCSR & CSR_DIV_BUSY));
	CPCCR &= ~CCR_CE;
}

static void set_pll(volatile uint32_t *reg, uint32_t val)
{
	if (!val || ((*reg & PLL_ON) && (*reg & ~0xc) == (val & ~0xc)))
		return;
	*reg &= ~PLL_EN;
	WAIT(!(*reg & PLL_ON));
	*reg = (val & ~0xc) | PLL_EN;
	WAIT(*reg & PLL_ON);
}

void stage2_main(void)
{
	void (*kernel)(uint32_t, uint32_t, uint32_t, uint32_t);

	params.status = 1;
	if (params.ccr) {
		/* Everything on EXCLK (24 MHz) while APLL changes, as Rockbox's
		 * clk_init(): SCLK_A from EXCLK, CPU and AHB from SCLK_A. */
		set_mux(0x55000000);
		set_div(0);
	}
	set_pll(&CPAPCR, params.apcr);
	set_pll(&CPMPCR, params.mpcr);
	set_pll(&CPEPCR, params.epcr);
	if (params.ccr) {
		set_div(params.ccr);
		set_mux(params.ccr);
	}
	params.status = 2;

	/* The boot ROM reads SLPC at reset: leave no USB-boot request. */
	SLPC = 0;

	if (params.wdt_ticks) {
		uint32_t t = params.wdt_ticks;

		CLKGR0 &= ~(1u << 18);	/* TCU clock */
		WDT_TCER = 0;
		TCU_TFCR = 1u << 24;
		TCU_TSCR = 1u << 16;
		WDT_TDR = t | (t * 2 / 3) << 16;
		WDT_TCSR = (1u << 10) | (1u << 1) | (5u << 3);
		WDT_TCER = 1;
	}
	params.status = 3;

	kernel = (void *)params.entry;
	kernel(params.arg[0], params.arg[1], params.arg[2], params.arg[3]);
}
