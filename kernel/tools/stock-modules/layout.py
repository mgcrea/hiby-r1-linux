"""Compare a module's struct module layout and vermagic with a stock module.

usage: python layout.py built.ko stock.ko
"""
import sys

from elftools.elf.elffile import ELFFile
from elftools.elf.relocation import RelocationSection


def describe(path):
    elf = ELFFile(open(path, "rb"))
    sec = elf.get_section_by_name(".gnu.linkonce.this_module")
    symtab = elf.get_section_by_name(".symtab")
    relocs = {}
    for s in elf.iter_sections():
        if isinstance(s, RelocationSection) and s.name.endswith("this_module"):
            for r in s.iter_relocations():
                relocs[symtab.get_symbol(r["r_info_sym"]).name] = r["r_offset"]
    modinfo = elf.get_section_by_name(".modinfo").data().split(b"\0")
    vermagic = next((m[9:].decode() for m in modinfo if m.startswith(b"vermagic=")), None)
    return {
        "size": sec.data_size,
        "init": relocs.get("init_module"),
        "exit": relocs.get("cleanup_module"),
        "vermagic": vermagic,
        "e_flags": hex(elf.header.e_flags),
        "versions": elf.get_section_by_name("__versions") is not None,
    }


built, stock = describe(sys.argv[1]), describe(sys.argv[2])
ok = True
for key in built:
    match = built[key] == stock[key]
    ok &= match
    print(f"{key:9} built={built[key]!r:52} stock={stock[key]!r} {'ok' if match else 'MISMATCH'}")
sys.exit(0 if ok else 1)
