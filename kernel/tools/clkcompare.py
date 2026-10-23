"""Compare mainline's clock tree with the stock kernel's.

usage: python3 clkcompare.py out/stock-dt/clkdump.txt mainline-clk_summary.txt

Stock rates and enable states come from clkdump.ko's log; mainline's from
/sys/kernel/debug/clk/clk_summary. A stock clock maps to the mainline clock
that implements it (a stock divider and gate pair is one mainline clock).
"""
import re, sys

STOCK_TO_MAINLINE = {
    "ext": "ext", "rtc_ext": "rtc", "apll": "apll", "mpll": "mpll", "epll": "epll",
    "sclka": "sclk_a", "mux_cpu_l2c": "cpu_mux", "div_cpu": "cpu", "div_l2c": "l2cache",
    "div_ahb0": "ahb0", "mux_ahb2": "ahb2_apb_mux", "div_ahb2": "ahb2", "div_apb": "pclk",
    "div_ddr": "ddr", "gate_ddr": "ddr",
    "div_macphy": "mac_phy",
}
for clk in ("msc0", "msc1", "lcd", "sfc", "ssi", "cim", "pwm"):
    STOCK_TO_MAINLINE[f"div_{clk}"] = clk
for clk in ("msc0", "msc1", "lcd", "sfc", "cim", "pwm", "nemc", "efuse", "otg", "i2c0",
            "i2c1", "sadc", "uart0", "uart1", "uart2", "uart3", "dtrng", "tcu", "ost",
            "pdma", "aes", "hash", "intc"):
    STOCK_TO_MAINLINE[f"gate_{clk}"] = clk
STOCK_TO_MAINLINE.update({"gate_ssi0": "ssi", "gate_audio": "aic", "gate_rtc": "rtc_gate",
                          "gate_usbphy": "usb_phy"})

stock = {}
for line in open(sys.argv[1]):
    m = re.search(r"clkdump: (\S+) rate=(\d+) en=(\d)", line)
    if m:
        stock.setdefault(m.group(1), (int(m.group(2)), m.group(3) == "1"))

main = {}
for line in open(sys.argv[2]):
    f = line.split()
    if len(f) >= 9 and f[1].isdigit() and f[4].isdigit():
        main[f[0]] = (int(f[4]), f[8] == "Y")

bad = 0
for s, m in sorted(STOCK_TO_MAINLINE.items(), key=lambda kv: kv[1]):
    srate, sen = stock[s]
    if m not in main:
        print(f"MISSING  {m:14} (stock {s})")
        bad += 1
        continue
    mrate, men = main[m]
    gate = s.startswith("gate_") or s in ("div_ddr",)
    ok = mrate == srate and (not s.startswith("gate_") or men == sen)
    bad += not ok
    print(f"{'ok  ' if ok else 'DIFF'}     {m:14} {mrate:>11} {'on ' if men else 'off'}   stock {s:14} {srate:>11} {'on' if sen else 'off'}")
print(f"{bad} difference(s)")
sys.exit(1 if bad else 0)
