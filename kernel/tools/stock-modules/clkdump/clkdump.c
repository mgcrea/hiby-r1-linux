/*
 * clkdump: log the stock kernel's clocks with the raw driver data behind
 * them, to recover the X1600 CGU's register layout (mux, divider and gate
 * bits) for the mainline driver. Reads only; changes nothing.
 *
 *   insmod clkdump.ko names=ext,apll,mpll,...
 *
 * Only exported functions, plus __clk_lookup through kallsyms_lookup_name.
 * Of struct clk_core it reads the first three fields (name, ops, hw), whose
 * layout doesn't depend on the configuration.
 */
#include <linux/clk.h>
#include <linux/clk-provider.h>
#include <linux/kallsyms.h>
#include <linux/kernel.h>
#include <linux/module.h>

static char *names[160];
static int nnames;
module_param_array(names, charp, &nnames, 0);

struct core_head {
	const char *name;
	const void *ops;
	struct clk_hw *hw;
};

static int __init clkdump_init(void)
{
	struct clk *(*lookup)(const char *) = (void *)kallsyms_lookup_name("__clk_lookup");
	int i;

	if (!lookup)
		return -ENOENT;
	for (i = 0; i < nnames; i++) {
		struct clk *clk = lookup(names[i]);
		struct clk_hw *hw;
		struct core_head *core;
		struct clk *parent;

		if (!clk) {
			pr_info("clkdump: %s: not found\n", names[i]);
			continue;
		}
		hw = __clk_get_hw(clk);
		core = *(struct core_head **)hw;	/* clk_hw.core is its first field */
		parent = clk_get_parent(clk);
		pr_info("clkdump: %s rate=%lu en=%d parent=%s flags=%lx hw=%p ops=%pS\n",
			names[i], clk_get_rate(clk), __clk_is_enabled(clk),
			parent ? __clk_get_name(parent) : "-", __clk_get_flags(clk),
			hw, core->ops);
		pr_info("clkdump: %s -16: %*ph\n", names[i], 32, (u8 *)hw - 16);
		pr_info("clkdump: %s +16: %*ph\n", names[i], 32, (u8 *)hw + 16);
		pr_info("clkdump: %s +48: %*ph\n", names[i], 32, (u8 *)hw + 48);
	}
	return -ECANCELED;	/* nothing to keep loaded */
}

module_init(clkdump_init);
MODULE_LICENSE("GPL");
