/*
 * r1jump: start another kernel from the R1's stock 4.4 kernel, which has no
 * kexec. Loads a raw image (vmlinux.bin or any bare-metal payload linked
 * for KSEG0), arms the hardware watchdog so a hang comes back to the stock
 * firmware, and jumps through an uncached stub (stub.S).
 *
 *   insmod r1jump.ko image=/tmp/vmlinux.bin load=0x80010000 entry=0x80xxxxxx
 *
 * The image goes over the stock kernel's own text/data, which no DMA buffer
 * can be in. Source pages are kept out of the destination range so the
 * copy never reads a page it has already overwritten.
 *
 * dry_run=1 does everything except the jump, then frees it all.
 */
#include <linux/delay.h>
#include <linux/fs.h>
#include <linux/gfp.h>
#include <linux/io.h>
#include <linux/kernel.h>
#include <linux/mm.h>
#include <linux/sched.h>
#include <linux/module.h>
#include <linux/slab.h>
#include <linux/vmalloc.h>
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

/* X1600 TCU / watchdog (same layout as JZ4740/X1000), at 0x10002000. */
#define TCU_PHYS	0x10002000
#define WDT_TDR		0x00
#define WDT_TCER	0x04
#define WDT_TCNT	0x08
#define WDT_TCSR	0x0c
#define TCU_TSCR	0x3c	/* timer stop clear */
#define TSCR_WDT	BIT(16)
#define TCSR_RTC_EN	BIT(1)
#define TCSR_PRESCALE_1024 (5 << 3)

static void arm_watchdog(unsigned int secs)
{
	void __iomem *tcu = (void __iomem *)CKSEG1ADDR(TCU_PHYS);
	/* 32768 Hz RTC clock / 1024 = 32 ticks per second. */
	u32 ticks = min_t(u32, secs * 32, 0xffff);

	writeb(0, tcu + WDT_TCER);
	writel(TSCR_WDT, tcu + TCU_TSCR);
	writew(TCSR_RTC_EN | TCSR_PRESCALE_1024, tcu + WDT_TCSR);
	writew(ticks, tcu + WDT_TDR);
	writew(0, tcu + WDT_TCNT);
	writeb(1, tcu + WDT_TCER);
}

/* Total index range and line size of a cache from Config1/Config2 fields. */
static void l1_geometry(u32 s, u32 l, u32 a, u32 *line, u32 *size)
{
	u32 sets = s == 7 ? 32 : 64 << s;

	*line = l ? 2 << l : 0;
	*size = *line * sets * (a + 1);
}

static bool overlaps(phys_addr_t p, size_t len, phys_addr_t lo, phys_addr_t hi)
{
	return p + len > lo && p < hi;
}

static bool in_dest(phys_addr_t p, phys_addr_t lo, phys_addr_t hi)
{
	return overlaps(p, PAGE_SIZE, lo, hi);
}

struct pagelist {
	struct page **pages;
	unsigned int n, cap;
};

static void pagelist_free(struct pagelist *pl)
{
	while (pl->n)
		__free_page(pl->pages[--pl->n]);
	kfree(pl->pages);
}

/* A page that is not inside [lo, hi). Rejected pages are parked in @rej. */
static struct page *outside_page(phys_addr_t lo, phys_addr_t hi, struct pagelist *rej)
{
	for (;;) {
		struct page *p = alloc_page(GFP_KERNEL);

		if (!p)
			return NULL;
		if (!in_dest(page_to_phys(p), lo, hi))
			return p;
		if (rej->n == rej->cap) {
			unsigned int cap = rej->cap ? rej->cap * 2 : 256;
			struct page **np = krealloc(rej->pages, cap * sizeof(*np), GFP_KERNEL);

			if (!np) {
				__free_page(p);
				return NULL;
			}
			rej->pages = np;
			rej->cap = cap;
		}
		rej->pages[rej->n++] = p;
	}
}

static int __init r1jump_init(void)
{
	struct pagelist src = {}, rej = {};
	struct page *stub_page = NULL, *param_page = NULL, *list_pages = NULL;
	struct r1jump_params *params;
	phys_addr_t lo, hi;
	u32 *list;
	loff_t size;
	struct file *f;
	unsigned int npages, list_order, i;
	u32 c1, c2;
	int ret;

	if (!entry)
		entry = load;
	f = filp_open(image, O_RDONLY, 0);
	if (IS_ERR(f))
		return PTR_ERR(f);
	size = i_size_read(file_inode(f));
	npages = DIV_ROUND_UP(size, PAGE_SIZE);
	lo = CPHYSADDR(load);
	hi = lo + (phys_addr_t)npages * PAGE_SIZE;
	pr_info("r1jump: %s, %lld bytes -> 0x%08lx..0x%08lx, entry 0x%08lx\n",
		image, size, load, load + npages * PAGE_SIZE, entry);

	src.pages = kcalloc(npages, sizeof(*src.pages), GFP_KERNEL);
	list_order = get_order(npages * 8);
	ret = -ENOMEM;
	if (!src.pages)
		goto out;
	src.cap = npages;

	for (i = 0; i < npages; i++) {
		struct page *p = outside_page(lo, hi, &rej);
		loff_t off = (loff_t)i * PAGE_SIZE;
		int n;

		if (!p) {
			pr_err("r1jump: no page for image page %u (%u rejected)\n", i, rej.n);
			goto out;
		}
		src.pages[src.n++] = p;
		memset(page_address(p), 0, PAGE_SIZE);
		n = kernel_read(f, off, page_address(p), min_t(loff_t, PAGE_SIZE, size - off));
		if (n < 0) {
			ret = n;
			goto out;
		}
	}

	stub_page = outside_page(lo, hi, &rej);
	param_page = outside_page(lo, hi, &rej);
	/* The pair list must be contiguous: retry until it lands outside. */
	for (;;) {
		list_pages = alloc_pages(GFP_KERNEL, list_order);
		if (!list_pages || !overlaps(page_to_phys(list_pages), PAGE_SIZE << list_order, lo, hi))
			break;
		__free_pages(list_pages, list_order);	/* rare; just try again */
		list_pages = NULL;
		schedule();
	}
	if (!stub_page || !param_page || !list_pages) {
		pr_err("r1jump: stub %p params %p list %p (order %u)\n", stub_page, param_page, list_pages, list_order);
		goto out;
	}
	if (r1jump_stub_end - r1jump_stub > PAGE_SIZE) {
		ret = -E2BIG;
		goto out;
	}

	list = page_address(list_pages);
	for (i = 0; i < npages; i++) {
		list[2 * i] = lo + i * PAGE_SIZE;
		list[2 * i + 1] = page_to_phys(src.pages[i]);
	}
	memcpy(page_address(stub_page), r1jump_stub, r1jump_stub_end - r1jump_stub);

	params = page_address(param_page);
	c1 = read_c0_config1();
	c2 = read_c0_config2();
	l1_geometry((c1 >> 13) & 7, (c1 >> 10) & 7, (c1 >> 7) & 7, &params->dline, &params->dsize);
	l1_geometry((c1 >> 22) & 7, (c1 >> 19) & 7, (c1 >> 16) & 7, &params->iline, &params->isize);
	params->sline = (c2 >> 4) & 0xf ? 2 << ((c2 >> 4) & 0xf) : 0;
	params->ssize = params->sline ? params->sline * (64 << ((c2 >> 8) & 0xf)) * ((c2 & 0xf) + 1) : 0;
	params->list = CKSEG1ADDR(page_to_phys(list_pages));
	params->count = npages;
	params->entry = entry;
	params->arg[0] = arg0;
	params->arg[1] = arg1;
	params->arg[2] = arg2;
	params->arg[3] = arg3;
	pr_info("r1jump: D %u/%u I %u/%u L2 %u/%u bytes, %u pages (%u rejected), stub %td bytes\n",
		params->dline, params->dsize, params->iline, params->isize,
		params->sline, params->ssize, npages, rej.n, r1jump_stub_end - r1jump_stub);

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
	((void (*)(unsigned long))CKSEG1ADDR(page_to_phys(stub_page)))(
		CKSEG1ADDR(page_to_phys(param_page)));
	unreachable();

out:
	if (list_pages)
		__free_pages(list_pages, list_order);
	if (param_page)
		__free_page(param_page);
	if (stub_page)
		__free_page(stub_page);
	pagelist_free(&src);
	pagelist_free(&rej);
	filp_close(f, NULL);
	return ret;
}

module_init(r1jump_init);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Jump from the HiBy R1 stock kernel into another kernel");
