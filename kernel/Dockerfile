# Builds the mainline kernel for the R1 and its initramfs. The source tree
# lives in the r1-linux volume (Linux needs a case-sensitive filesystem).
FROM debian:bookworm
RUN dpkg --add-architecture mipsel && apt-get update && apt-get install -y --no-install-recommends \
      gcc libc6-dev gcc-mipsel-linux-gnu binutils-mipsel-linux-gnu make bc bison flex \
      libssl-dev libelf-dev ca-certificates curl xz-utils python3 cpio rsync kmod \
      device-tree-compiler git busybox-static:mipsel \
    && rm -rf /var/lib/apt/lists/*
