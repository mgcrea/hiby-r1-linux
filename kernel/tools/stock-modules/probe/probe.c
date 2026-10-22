#include <linux/module.h>
#include <linux/kernel.h>

static int __init probe_init(void)
{
	pr_info("r1probe: loaded\n");
	return 0;
}

static void __exit probe_exit(void)
{
}

module_init(probe_init);
module_exit(probe_exit);
MODULE_LICENSE("GPL");
