#!/bin/sh
# Run inside the r1-mainline image by build.sh.
# Rockbox wants mipsel-elf-*; Debian's mipsel-linux-gnu-* do, given
# non-PIC, non-PIE code and a stub for a glibc header limits.h pulls in.
mkdir -p /xbin /xinc/gnu
: > /xinc/gnu/stubs-o32_soft.h
for t in gcc-ar gcc-nm gcc-ranlib ld ar as objcopy objdump nm ranlib strip size readelf cpp; do
	ln -sf /usr/bin/mipsel-linux-gnu-$t /xbin/mipsel-elf-$t
done
printf '#!/bin/sh\nexec /usr/bin/mipsel-linux-gnu-gcc -mno-abicalls -fno-pic -no-pie -Wl,--build-id=none -idirafter /xinc "$@"\n' > /xbin/mipsel-elf-gcc
chmod +x /xbin/mipsel-elf-gcc
