# Builds the mainline kernel for the R1 and its initramfs. The source tree
# lives in the r1-linux volume (Linux needs a case-sensitive filesystem).
FROM debian:bookworm
RUN dpkg --add-architecture mipsel && apt-get update && apt-get install -y --no-install-recommends \
      gcc libc6-dev gcc-mipsel-linux-gnu binutils-mipsel-linux-gnu make bc bison flex \
      libssl-dev libelf-dev ca-certificates curl xz-utils python3 cpio rsync kmod \
      device-tree-compiler git busybox-static:mipsel libc6-dev-mipsel-cross \
    && rm -rf /var/lib/apt/lists/*
# tinyalsa for the initramfs: tinymix, and the library r1tone links against,
# without the plugin code (dlopen, which a static binary can't use). pcm.c
# calls snd_utils_close_dev_node() outside its plugin guard: stub it.
# A master commit (2026-09-29), not v2.0.0: that release's pcm_state() hands
# the kernel a stale appl_ptr on architectures that can't mmap the PCM status
# page (MIPS among them), which empties the buffer before every write.
ARG TINYALSA=961babfe962e71d952ae734074cc89576b28a9e7
RUN curl -fsSL https://github.com/tinyalsa/tinyalsa/archive/$TINYALSA.tar.gz | tar -xz -C /opt \
    && mv /opt/tinyalsa-$TINYALSA /opt/tinyalsa \
    && cd /opt/tinyalsa \
    && for f in pcm pcm_hw mixer mixer_hw limits; do \
         mipsel-linux-gnu-gcc -c -Os -Iinclude -o src/$f.o src/$f.c; done \
    && echo 'void snd_utils_close_dev_node(void *node) {}' > src/no_plugins.c \
    && mipsel-linux-gnu-gcc -c -Os -o src/no_plugins.o src/no_plugins.c \
    && mipsel-linux-gnu-ar rcs libtinyalsa.a src/*.o \
    && mipsel-linux-gnu-gcc -static -Os -Iinclude -o tinymix utils/tinymix.c libtinyalsa.a
