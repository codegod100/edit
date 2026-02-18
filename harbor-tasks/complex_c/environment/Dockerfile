FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    coreutils \
    curl \
    gcc \
    git \
    grep \
    python3 \
    sed \
    xz-utils \
 && rm -rf /var/lib/apt/lists/*

# Install Zig (stable) for Zig-based tasks.
RUN curl -fsSL https://ziglang.org/download/0.13.0/zig-linux-x86_64-0.13.0.tar.xz -o /tmp/zig.tar.xz \
 && mkdir -p /opt \
 && tar -xJf /tmp/zig.tar.xz -C /opt \
 && ln -s /opt/zig-linux-x86_64-0.13.0/zig /usr/local/bin/zig \
 && rm -f /tmp/zig.tar.xz

WORKDIR /app
