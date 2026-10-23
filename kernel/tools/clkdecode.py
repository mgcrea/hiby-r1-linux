"""Group the stock clocks dumped by clkdump.ko by driver type.

usage: python3 clkdecode.py out/stock-dt/clkdump.txt

Prints, per ops symbol, each clock's rate, parent, enable state and the
32-bit words that follow its 12-byte struct clk_hw (core, clk, init).
"""
import re, struct, sys
from collections import defaultdict

clocks, raw = {}, defaultdict(dict)
for line in open(sys.argv[1]):
    m = re.search(r"clkdump: (\S+) rate=(\d+) en=(\d) parent=(\S+) flags=(\S+) hw=(\S+) ops=(\S+?)\+", line)
    if m:
        name, rate, en, parent, flags, hw, ops = m.groups()
        clocks.setdefault(name, dict(rate=int(rate), en=int(en), parent=parent, ops=ops))
        continue
    m = re.search(r"clkdump: (\S+) ([-+]\d+): ([0-9a-f ]+)$", line)
    if m:
        raw[m.group(1)][int(m.group(2))] = bytes.fromhex(m.group(3).replace(" ", ""))

by_ops = defaultdict(list)
for name, c in clocks.items():
    by_ops[c["ops"]].append(name)
for ops, names in sorted(by_ops.items()):
    print(f"== {ops} ({len(names)})")
    for name in names:
        c, r = clocks[name], raw[name]
        blob = r[-16] + r[16] + r[48]          # hw-16 .. hw+80
        words = struct.unpack("<24I", blob)
        after = words[4 + 3:4 + 3 + 12]         # skip 16 bytes before, 12 of clk_hw
        print(f"  {name:22} {c['rate']:>10} en={c['en']} <- {c['parent']:16} " + " ".join(f"{w:08x}" for w in after))
