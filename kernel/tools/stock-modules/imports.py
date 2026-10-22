"""List a module's imported symbols and whether the stock kernel exports them.

usage: python imports.py module.ko stock-kallsyms.txt
"""
import sys

from elftools.elf.elffile import ELFFile

elf = ELFFile(open(sys.argv[1], "rb"))
undefined = sorted({s.name for s in elf.get_section_by_name(".symtab").iter_symbols()
                    if s["st_shndx"] == "SHN_UNDEF" and s.name})
words = open(sys.argv[2]).read().split()
exported = {w[len("__ksymtab_"):] for w in words if w.startswith("__ksymtab_")}
missing = [u for u in undefined if u not in exported]
for u in undefined:
    print(f"{u:28} {'exported' if u in exported else 'MISSING'}")
sys.exit(1 if missing else 0)
