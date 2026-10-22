/*
 * r1jump: start another kernel from the R1's stock 4.4 kernel, which has no
 * kexec. Loads a raw image (vmlinux.bin or any bare-metal payload linked
 * for KSEG0), arms the hardware watchdog so a hang comes back to the stock
 * firmware, and jumps through an uncached stub (stub.S).
 *
 *   insmod r1jump.ko image=/tmp/vmlinux.bin load=0x80010000 entry=0x80xxxxxx
 *
 * An image in /tmp costs RAM twice (tmpfs plus the copy). About 15 MB is
 * free with hiby_player running: enough for a compressed (zboot) kernel,
 * not for an 8 MB vmlinux.bin. The SD card is on the USB host while ADB is.
 *
 * The image goes over the stock kernel's own text/data, which no DMA buffer
 * can be in. Source pages are kept out of the destination range so the
 * copy never reads a page it has already overwritten.
 *
 * Only exported functions are called: inline helpers that read struct page,
 * struct inode or the zone lists (alloc_page, page_address, i_size_read,
 * kmalloc, ...) assume a layout that HiBy's build doesn't share. Memory comes
 * from __get_free_pages as KSEG0 addresses (no highmem on 64 MB), so the
 * physical address is CPHYSADDR(v).
 *
 * dry_run=1 does everything except the jump, then frees it all.
 * wdt_only=1 arms the watchdog for wdt_secs and returns, to check it resets
 * the R1.
 */
#include <linux/delay.h>
#include <linux/fs.h>
#include <linux/gfp.h>
#include <linux/io.h>
#include <linux/kernel.h>
#include <linux/module.h>
#include <asm/mipsregs.h>

static char *image = "/tmp/vmlinux.bin";
module_param(image, charp, 0);
static ulong load = 0x80010000;
module_param(load, ulong, 0);
static ulong entry;
module_param(entry, ulong, 0);
static uint wdt_secs = 30;
module_param(wdt_secs, uint, 0);
static bool dry_run;
module_param(dry_run, bool, 0);
static bool wdt_only;
module_param(wdt_only, bool, 0);
/* Passed to the new kernel in a0..a3 (MIPS boot protocol). */
static ulong arg0, arg1, arg2, arg3;
module_param(arg0, ulong, 0);
module_param(arg1, ulong, 0);
module_param(arg2, ulong, 0);
module_param(arg3, ulong, 0);

/* Must match the P_* offsets in stub.S. */
struct r1jump_params {
	u32 dline, dsize, sline, ssize, iline, isize;
	u32 list, count, entry;
	u32 arg[4];
};

extern char r1jump_stub[], r1jump_stub_end[];

/*
 * X1600 watchdog at 0x10002000 (TCU base). The sequence copies the stock
 * driver's ingenic_wdt_set_timeout, read from its disassembly: TDR is a
 * 32-bit register (timeout in the low half, ticks * 2 / 3 in the high
 * half), and TCSR bit 10 clears the counter, as its ping does.
 */
#define TCU_PHYS	0x10002000
#define WDT_TDR		0x00
#define WDT_TCER	0x04
#define WDT_TCSR	0x0c
#define TCU_TFCR	0x28	/* flag clear */
#define TCU_TSCR	0x3c	/* timer stop clear */
#define TCU_WDT		BIT(16)
#define TFCR_WDT	BIT(24)
#define TCSR_RTC_EN	BIT(1)
#define TCSR_PRESCALE_1024 (5 << 3)
#define TCSR_CLEAR	BIT(10)

static void arm_watchdog(unsigned int secs)
{
	void __iomem *tcu = (void __iomem *)CKSEG1ADDR(TCU_PHYS);
	/* 32768 Hz RTC clock / 1024 = 32 ticks per second. */
	u32 ticks = min_t(u32, secs * 32, 0xffff);

	__raw_writeb(0, tcu + WDT_TCER);
	__raw_writel(TFCR_WDT, tcu + TCU_TFCR);
	__raw_writel(TCU_WDT, tcu + TCU_TSCR);
	__raw_writel(ticks | (ticks * 2 / 3) << 16, tcu + WDT_TDR);
	__raw_writew(TCSR_CLEAR | TCSR_RTC_EN | TCSR_PRESCALE_1024, tcu + WDT_TCSR);
	__raw_writeb(1, tcu + WDT_TCER);
}

/* Total index range and line size of a cache from Config1/Config2 fields. */
static void l1_geometry(u32 s, u32 l, u32 a, u32 *line, u32 *size)
{
	u32 sets = s == 7 ? 32 : 64 << s;

	*line = l ? 2 << l : 0;
	*size = *line * sets * (a + 1);
}

/*
 * Fail rather than wake the OOM killer: it picks hiby_player, whose launcher
 * then reboots the R1.
 */
#define R1JUMP_GFP	(GFP_KERNEL | __GFP_NORETRY | __GFP_NOWARN)

static phys_addr_t dest_lo, dest_hi;

static bool in_dest(unsigned long v, unsigned int order)
{
	phys_addr_t p = CPHYSADDR(v);

	return p + (PAGE_SIZE << order) > dest_lo && p < dest_hi;
}

/*
 * Pages that landed inside the destination, kept allocated so the allocator
 * doesn't hand them out again. Chained through their first word.
 */
static unsigned long rejected;
static unsigned int nrejected;

static void free_rejected(void)
{
	while (rejected) {
		unsigned long next = *(unsigned long *)rejected;

		free_page(rejected);
		rejected = next;
	}
}

/* A free page outside the destination, or 0. */
static unsigned long outside_page(void)
{
	for (;;) {
		unsigned long v = __get_free_page(R1JUMP_GFP);

		if (!v || !in_dest(v, 0))
			return v;
		*(unsigned long *)v = rejected;
		rejected = v;
		nrejected++;
	}
}

static int __init r1jump_init(void)
{
	unsigned long stub = 0, param = 0, list = 0, parked[8];
	struct r1jump_params *params;
	unsigned int npages, nloaded = 0, nparked = 0, list_order, i;
	u32 *pairs = NULL;
	loff_t size;
	struct file *f;
	u32 c1, c2;
	int ret;

	if (wdt_only) {
		pr_info("r1jump: watchdog only, %u s\n", wdt_secs);
		arm_watchdog(wdt_secs);
		return -ECANCELED;
	}
	if (!entry)
		entry = load;
	f = filp_open(image, O_RDONLY, 0);
	if (IS_ERR(f))
		return PTR_ERR(f);
	size = vfs_llseek(f, 0, SEEK_END);
	if (size <= 0) {
		filp_close(f, NULL);
		return size < 0 ? size : -EINVAL;
	}
	npages = DIV_ROUND_UP(size, PAGE_SIZE);
	dest_lo = CPHYSADDR(load);
	dest_hi = dest_lo + (phys_addr_t)npages * PAGE_SIZE;
	pr_info("r1jump: %s, %lld bytes -> 0x%08lx..0x%08lx, entry 0x%08lx\n",
		image, size, load, load + npages * PAGE_SIZE, entry);

	/* The (dst, src) list is contiguous; park blocks that land inside. */
	list_order = get_order(npages * 8);
	ret = -ENOMEM;
	for (;;) {
		list = __get_free_pages(R1JUMP_GFP, list_order);
		if (!list || !in_dest(list, list_order))
			break;
		if (nparked == ARRAY_SIZE(parked)) {
			free_pages(list, list_order);
			list = 0;
			break;
		}
		parked[nparked++] = list;
	}
	stub = outside_page();
	param = outside_page();
	if (!list || !stub || !param) {
		pr_err("r1jump: list %lx (order %u) stub %lx params %lx\n", list, list_order, stub, param);
		goto out;
	}
	if (r1jump_stub_end - r1jump_stub > PAGE_SIZE) {
		ret = -E2BIG;
		goto out;
	}

	pairs = (u32 *)list;
	for (; nloaded < npages; nloaded++) {
		unsigned long v = outside_page();
		loff_t off = (loff_t)nloaded * PAGE_SIZE;
		int n;

		if (!v) {
			pr_err("r1jump: no page for image page %u (%u rejected)\n", nloaded, nrejected);
			goto out;
		}
		pairs[2 * nloaded] = dest_lo + off;
		pairs[2 * nloaded + 1] = CPHYSADDR(v);
		memset((void *)v, 0, PAGE_SIZE);
		n = kernel_read(f, off, (char *)v, min_t(loff_t, PAGE_SIZE, size - off));
		if (n < 0) {
			ret = n;
			nloaded++;
			goto out;
		}
	}
	memcpy((void *)stub, r1jump_stub, r1jump_stub_end - r1jump_stub);

	params = (struct r1jump_params *)param;
	c1 = read_c0_config1();
	c2 = read_c0_config2();
	l1_geometry((c1 >> 13) & 7, (c1 >> 10) & 7, (c1 >> 7) & 7, &params->dline, &params->dsize);
	l1_geometry((c1 >> 22) & 7, (c1 >> 19) & 7, (c1 >> 16) & 7, &params->iline, &params->isize);
	params->sline = (c2 >> 4) & 0xf ? 2 << ((c2 >> 4) & 0xf) : 0;
	params->ssize = params->sline ? params->sline * (64 << ((c2 >> 8) & 0xf)) * ((c2 & 0xf) + 1) : 0;
	params->list = CKSEG1ADDR(CPHYSADDR(list));
	params->count = npages;
	params->entry = entry;
	params->arg[0] = arg0;
	params->arg[1] = arg1;
	params->arg[2] = arg2;
	params->arg[3] = arg3;
	pr_info("r1jump: D %u/%u I %u/%u L2 %u/%u bytes, %u pages (%u rejected, %u lists parked), stub %td bytes\n",
		params->dline, params->dsize, params->iline, params->isize,
		params->sline, params->ssize, npages, nrejected, nparked,
		r1jump_stub_end - r1jump_stub);

	if (dry_run) {
		pr_info("r1jump: dry run, not jumping\n");
		ret = -ECANCELED;
		goto out;
	}

	pr_info("r1jump: watchdog %u s, jumping\n", wdt_secs);
	msleep(200);		/* let the log reach dmesg readers */
	arm_watchdog(wdt_secs);
	local_irq_disable();
	/* Everything the stub needs is reached through KSEG1 from here on. */
	((void (*)(unsigned long))CKSEG1ADDR(CPHYSADDR(stub)))(CKSEG1ADDR(CPHYSADDR(param)));
	unreachable();

out:
	for (i = 0; i < nloaded; i++)
		free_page(CKSEG0ADDR(pairs[2 * i + 1]));
	if (list)
		free_pages(list, list_order);
	while (nparked)
		free_pages(parked[--nparked], list_order);
	if (param)
		free_page(param);
	if (stub)
		free_page(stub);
	free_rejected();
	filp_close(f, NULL);
	return ret;
}

module_init(r1jump_init);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Jump from the HiBy R1 stock kernel into another kernel");
