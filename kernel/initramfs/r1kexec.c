/*
 * Start another kernel image from mainline, without a reset: the R1's flash
 * kernel uses it to boot the newer kernel on the SD card (r1-loader).
 *
 *   r1kexec IMAGE [LOAD [ENTRY]]
 *
 * IMAGE is a raw kernel with its DTB appended (out/r1-linux.bin), loaded at
 * LOAD (default 0x80100000) and entered at ENTRY (default LOAD), both as
 * kernel (KSEG0) addresses. a0-a3 reach the new kernel as 0, so it takes
 * its appended DTB, as after r1jump. kexec-tools does the same with more
 * code; this is one segment and the reboot.
 *
 * No libc: linked statically, glibc made this 670 KB of a flash image that
 * has to fit 5 MiB. MIPS o32 system calls only.
 */
#define NR(n)		(4000 + (n))
#define SYS_exit	NR(1)
#define SYS_read	NR(3)
#define SYS_write	NR(4)
#define SYS_open	NR(5)
#define SYS_close	NR(6)
#define SYS_sync	NR(36)
#define SYS_reboot	NR(88)
#define SYS_kexec_load	NR(311)

#define KSEG0		0x80000000UL
#define PAGE		4096UL
#define MAX_IMAGE	(16UL << 20)

struct kexec_segment {
	const void *buf;
	unsigned long bufsz;
	unsigned long mem;
	unsigned long memsz;
};

static char image[MAX_IMAGE];

/* Returns the result, or -errno. */
static long sys(long n, long a, long b, long c, long d)
{
	register long v0 __asm__("$2") = n;
	register long a0 __asm__("$4") = a;
	register long a1 __asm__("$5") = b;
	register long a2 __asm__("$6") = c;
	register long a3 __asm__("$7") = d;

	__asm__ volatile ("syscall"
		: "+r" (v0), "+r" (a3)
		: "r" (a0), "r" (a1), "r" (a2)
		: "$1", "$3", "$8", "$9", "$10", "$11", "$12", "$13", "$14",
		  "$15", "$24", "$25", "hi", "lo", "memory");
	return a3 ? -v0 : v0;
}

static unsigned long len(const char *s)
{
	unsigned long n = 0;

	while (s[n])
		n++;
	return n;
}

static void say(const char *s)
{
	sys(SYS_write, 2, (long)s, len(s), 0);
}

static void fail(const char *what, long err)
{
	char num[8];
	int i = sizeof(num) - 1;

	num[i] = 0;
	for (err = -err; i > 0 && (err || i == sizeof(num) - 1); err /= 10)
		num[--i] = '0' + err % 10;
	say("r1kexec: ");
	say(what);
	say(" failed, errno ");
	say(num + i);
	say("\n");
	sys(SYS_exit, 1, 0, 0, 0);
}

static unsigned long number(const char *s)
{
	unsigned long v = 0;
	int base = 10;

	if (s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) {
		base = 16;
		s += 2;
	}
	for (; *s; s++) {
		int d = *s >= '0' && *s <= '9' ? *s - '0' :
			*s >= 'a' && *s <= 'f' ? *s - 'a' + 10 :
			*s >= 'A' && *s <= 'F' ? *s - 'A' + 10 : base;
		if (d >= base)
			break;
		v = v * base + d;
	}
	return v;
}

void cmain(long *sp)
{
	int argc = sp[0];
	char **argv = (char **)(sp + 1);
	unsigned long load = 0x80100000UL, entry, size = 0;
	struct kexec_segment seg;
	long fd, n;

	if (argc < 2) {
		say("usage: r1kexec IMAGE [LOAD [ENTRY]]\n");
		sys(SYS_exit, 2, 0, 0, 0);
	}
	if (argc > 2)
		load = number(argv[2]);
	entry = argc > 3 ? number(argv[3]) : load;

	fd = sys(SYS_open, (long)argv[1], 0, 0, 0);
	if (fd < 0)
		fail("open", fd);
	while ((n = sys(SYS_read, fd, (long)image + size, MAX_IMAGE - size, 0)) > 0)
		size += n;
	if (n < 0)
		fail("read", n);
	if (size == MAX_IMAGE)
		fail("read (image too big)", 0);
	sys(SYS_close, fd, 0, 0, 0);

	seg.buf = image;
	seg.bufsz = size;
	seg.mem = load - KSEG0;
	seg.memsz = (size + PAGE - 1) & ~(PAGE - 1);
	n = sys(SYS_kexec_load, entry - KSEG0, 1, (long)&seg, 0);
	if (n < 0)
		fail("kexec_load", n);
	sys(SYS_sync, 0, 0, 0, 0);
	/* LINUX_REBOOT_MAGIC1, LINUX_REBOOT_MAGIC2, LINUX_REBOOT_CMD_KEXEC */
	n = sys(SYS_reboot, 0xfee1dead, 672274793, 0x45584543, 0);
	fail("reboot", n);
}

__asm__(".text\n"
	".globl __start\n"
	"__start:\n"
	"	move	$4, $sp\n"
	"	addiu	$sp, $sp, -16\n"
	"	jal	cmain\n"
	"	nop\n");
