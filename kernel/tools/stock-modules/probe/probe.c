#include <linux/module.h>
#include <linux/kernel.h>
#include <asm/mipsregs.h>

static int __init probe_init(void)
{
	pr_info("r1probe: loaded\n");
	/* What mainline's cpu-probe and cache setup read. */
	pr_info("r1probe: prid %08x config0 %08x config1 %08x config2 %08x config3 %08x\n",
		read_c0_prid(), read_c0_config(), read_c0_config1(), read_c0_config2(),
		read_c0_config3());
	return 0;
}

static void __exit probe_exit(void)
{
}

module_init(probe_init);
module_exit(probe_exit);
MODULE_LICENSE("GPL");
