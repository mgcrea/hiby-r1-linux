/* Print what fbpaint needs: the framebuffer's physical address and layout. */
#include <fcntl.h>
#include <linux/fb.h>
#include <stdio.h>
#include <sys/ioctl.h>

int main(void)
{
	struct fb_fix_screeninfo fix;
	struct fb_var_screeninfo var;
	int fd = open("/dev/fb0", O_RDONLY);

	if (fd < 0 || ioctl(fd, FBIOGET_FSCREENINFO, &fix) || ioctl(fd, FBIOGET_VSCREENINFO, &var)) {
		perror("fb0");
		return 1;
	}
	printf("smem_start=0x%08lx smem_len=%u line_length=%u xres=%u yres=%u yres_virtual=%u yoffset=%u bpp=%u\n",
	       fix.smem_start, fix.smem_len, fix.line_length, var.xres, var.yres,
	       var.yres_virtual, var.yoffset, var.bits_per_pixel);
	return 0;
}
