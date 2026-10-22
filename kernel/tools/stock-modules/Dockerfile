# Builds kernel modules that load into the R1's stock 4.4.94 kernel, from a
# vanilla kernel.org tree configured to the same struct module layout.
FROM --platform=linux/amd64 debian:bookworm
RUN apt-get update && apt-get install -y --no-install-recommends \
      gcc libc6-dev gcc-mipsel-linux-gnu binutils-mipsel-linux-gnu make bc bison flex \
      libssl-dev libelf-dev ca-certificates curl xz-utils python3 \
    && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL https://cdn.kernel.org/pub/linux/kernel/v4.x/linux-4.4.94.tar.xz | tar -xJ -C /opt
WORKDIR /opt/linux-4.4.94
