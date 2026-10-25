/*
 * Write to the R1's SPI-NAND from mainline, and check what was written: the
 * erase, write and read-back of mtd-utils' flash_erase, nandwrite -p and
 * nanddump, which neither the initramfs's busybox nor the stock system's
 * glibc can give us. flash-install.sh pushes it to /tmp and runs it.
 *
 *   r1flash write DEV IMAGE          erase the blocks IMAGE needs and write
 *                                    it (its last page padded with 0xff),
 *                                    reading each block back to compare
 *   r1flash test DEV OFFSET BLOCKS   on BLOCKS blocks from OFFSET, which
 *                                    must read erased: write a pattern,
 *                                    read it back, erase them again
 *   r1flash dump DEV OUT [LENGTH]    copy the partition, or its first
 *                                    LENGTH bytes, to OUT
 *
 * No bad-block skipping: the R1's W25N01GV has no bad blocks (2026-10-24),
 * so one in the range stops it before anything is erased. The partitions
 * the device tree marks read-only refuse the erase (EROFS).
 */
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <mtd/mtd-user.h>

static struct mtd_info_user mtd;
static int fd;

static void die(const char *what)
{
	fprintf(stderr, "r1flash: %s: %s\n", what, errno ? strerror(errno) : "failed");
	exit(1);
}

static void open_mtd(const char *dev, int flags)
{
	fd = open(dev, flags);
	if (fd < 0 || ioctl(fd, MEMGETINFO, &mtd) < 0)
		die(dev);
}

/* Stops if a block in [off, off + len) is bad, before anything is erased */
static void check_blocks(unsigned int off, unsigned int len)
{
	for (loff_t b = off; b < off + len; b += mtd.erasesize) {
		int bad = ioctl(fd, MEMGETBADBLOCK, &b);

		if (bad < 0)
			die("bad block check");
		if (bad) {
			fprintf(stderr, "r1flash: block at 0x%llx is bad: nothing written\n", (long long)b);
			exit(1);
		}
	}
}

static void erase(unsigned int off, unsigned int len)
{
	for (unsigned int b = off; b < off + len; b += mtd.erasesize) {
		struct erase_info_user e = { .start = b, .length = mtd.erasesize };

		if (ioctl(fd, MEMERASE, &e) < 0)
			die("erase");
	}
}

static void put(unsigned int off, const unsigned char *buf, unsigned int len)
{
	if (pwrite(fd, buf, len, off) != (ssize_t)len)
		die("write");
}

static void get(unsigned int off, unsigned char *buf, unsigned int len)
{
	if (pread(fd, buf, len, off) != (ssize_t)len)
		die("read");
}

static unsigned int round_up(unsigned int n, unsigned int to)
{
	return (n + to - 1) / to * to;
}

/* One block at a time: the R1 has about 18 MB free with r1player up */
static int cmd_write(const char *dev, const char *path)
{
	FILE *f = fopen(path, "rb");
	struct stat st;

	if (!f || fstat(fileno(f), &st) < 0)
		die(path);
	open_mtd(dev, O_RDWR | O_SYNC);
	if ((unsigned long long)st.st_size > mtd.size) {
		fprintf(stderr, "r1flash: %s is %lld bytes, over the partition's %u\n",
			path, (long long)st.st_size, mtd.size);
		return 1;
	}

	unsigned char *blk = malloc(mtd.erasesize), *back = malloc(mtd.erasesize);

	if (!blk || !back)
		die("memory");
	check_blocks(0, round_up(st.st_size, mtd.erasesize));
	for (unsigned int off = 0; off < st.st_size; off += mtd.erasesize) {
		size_t n = fread(blk, 1, mtd.erasesize, f);
		/* The last page padded with 0xff, as nandwrite -p does */
		unsigned int len = round_up(n, mtd.writesize);

		if (!n)
			die(path);
		memset(blk + n, 0xff, len - n);
		erase(off, mtd.erasesize);
		put(off, blk, len);
		get(off, back, len);
		if (memcmp(blk, back, len)) {
			fprintf(stderr, "r1flash: READ-BACK DIFFERS in the block at 0x%x\n", off);
			return 1;
		}
	}
	printf("r1flash: wrote %lld bytes to %s and read them back\n", (long long)st.st_size, dev);
	return 0;
}

static int cmd_test(const char *dev, unsigned int off, unsigned int blocks)
{
	open_mtd(dev, O_RDWR | O_SYNC);

	unsigned int len = blocks * mtd.erasesize;
	unsigned char *pat = malloc(len), *back = malloc(len);

	if (!pat || !back)
		die("memory");
	if (off % mtd.erasesize || off + len > mtd.size) {
		fprintf(stderr, "r1flash: 0x%x + %u blocks isn't a block range of %s\n", off, blocks, dev);
		return 1;
	}
	get(off, back, len);
	for (unsigned int i = 0; i < len; i++) {
		if (back[i] != 0xff) {
			fprintf(stderr, "r1flash: 0x%x isn't erased (0x%02x at +0x%x): nothing written\n",
				off, back[i], i);
			return 1;
		}
	}
	check_blocks(off, len);

	/* Differs from page to page and block to block, so a misplaced page shows */
	for (unsigned int i = 0; i < len; i++)
		pat[i] = (unsigned char)(i * 7 + (i >> 11) * 13 + (i >> 17));
	put(off, pat, len);
	get(off, back, len);
	int same = !memcmp(pat, back, len);

	erase(off, len);
	get(off, back, len);
	int erased = 1;
	for (unsigned int i = 0; i < len; i++)
		erased &= back[i] == 0xff;

	printf("r1flash: %u blocks at 0x%x: pattern %s, erased again %s\n",
	       blocks, off, same ? "read back" : "DIFFERS", erased ? "yes" : "NO");
	return !(same && erased);
}

static int cmd_dump(const char *dev, const char *path, unsigned int len)
{
	open_mtd(dev, O_RDONLY);
	if (!len || len > mtd.size)
		len = mtd.size;

	unsigned char *buf = malloc(mtd.erasesize);
	FILE *f = fopen(path, "wb");

	if (!buf || !f)
		die(path);
	for (unsigned int off = 0; off < len; off += mtd.erasesize) {
		unsigned int n = len - off < mtd.erasesize ? len - off : mtd.erasesize;

		get(off, buf, n);
		if (fwrite(buf, 1, n, f) != n)
			die(path);
	}
	if (fclose(f))
		die(path);
	return 0;
}

int main(int argc, char **argv)
{
	if (argc == 4 && !strcmp(argv[1], "write"))
		return cmd_write(argv[2], argv[3]);
	if (argc == 5 && !strcmp(argv[1], "test"))
		return cmd_test(argv[2], strtoul(argv[3], NULL, 0), strtoul(argv[4], NULL, 0));
	if ((argc == 4 || argc == 5) && !strcmp(argv[1], "dump"))
		return cmd_dump(argv[2], argv[3], argc == 5 ? strtoul(argv[4], NULL, 0) : 0);
	fprintf(stderr, "usage: r1flash write DEV IMAGE | test DEV OFFSET BLOCKS | dump DEV OUT [LENGTH]\n");
	return 2;
}
