# Build image for the Fushi Linux x64 app bundle (tool/linux/build_in_docker.sh).
#
# Debian trixie is the documented Linux build host (docs/agent/build.md): it has
# gcc 14 (fushidicts needs std::expected) and WPE WebKit 2.x dev packages
# (Ubuntu 24.04 does not). Consequence: the bundle needs glibc >= the trixie one
# on the target machine (Debian 13, Ubuntu 25.04+, Fedora 42+, Arch / SteamOS).
FROM debian:trixie

ARG FLUTTER_VERSION=3.47.6
ARG RUST_P2P=1.95.0
ARG RUST_ANKI=1.97.1
ARG RUSTUP_VERSION=1.28.2
ARG RUSTUP_SHA256=20a06e644b0d9bd2fbdbfd52d42540bdde820ea7df86e92e533c073da0cdd43c
ARG PROTOC_VERSION=31.1
ARG PROTOC_SHA256=96553041f1a91ea0efee963cb16f462f5985b4d65365f3907414c360044d8065

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    RUSTUP_HOME=/opt/rustup \
    CARGO_HOME=/opt/cargo \
    VCPKG_ROOT=/opt/vcpkg \
    FLUTTER_ROOT=/opt/flutter \
    PATH=/opt/toolchain-shim:/opt/flutter/bin:/opt/flutter/bin/cache/dart-sdk/bin:/opt/cargo/bin:/opt/protoc/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Build deps from docs/agent/build.md "Linux 桌面（源码构建）", plus what the
# native scripts need (vcpkg: curl/zip/unzip/tar/perl/autotools; anki-sync:
# protoc; fushidicts check: objdump) and Xvfb/dbus for headless smoke runs.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git unzip xz-utils zip tar file python3 perl \
      build-essential gcc-14 g++-14 clang cmake ninja-build make pkg-config \
      autoconf automake libtool bison binutils patchelf \
      libgtk-3-dev liblzma-dev libmpv-dev libsecret-1-dev libkeybinder-3.0-dev \
      libwpewebkit-2.0-dev libwpebackend-fdo-1.0-dev libwpe-1.0-dev libepoxy-dev libwayland-dev \
      libwebkit2gtk-4.1-dev libjson-glib-dev libx11-dev libxi-dev wayland-protocols \
      mpv ffmpeg pulseaudio-utils espeak-ng \
      xvfb xauth dbus dbus-x11 mesa-utils libgl1-mesa-dri \
    && rm -rf /var/lib/apt/lists/*

# Flutter's Linux build calls clang/clang++; Debian's clang + libstdc++ may lack
# std::expected, so route both to GNU 14 (same shim the old CI linux job used).
RUN mkdir -p /opt/toolchain-shim \
    && printf '#!/bin/sh\nexec gcc-14 "$@"\n' > /opt/toolchain-shim/clang \
    && printf '#!/bin/sh\nexec g++-14 "$@"\n' > /opt/toolchain-shim/clang++ \
    && chmod +x /opt/toolchain-shim/clang /opt/toolchain-shim/clang++

# Rust: 1.95.0 for the Fushi crates (names.sh P2P_RUST), 1.97.1 for fushi-anki-sync
# (native/fushi_anki_sync/rust-toolchain.toml picks it from the crate dir).
# rustup-init is a pinned, checksum-verified binary (no `curl | sh`; https only).
RUN curl --proto '=https' --tlsv1.2 -fsSL -o /tmp/rustup-init \
      "https://static.rust-lang.org/rustup/archive/${RUSTUP_VERSION}/x86_64-unknown-linux-gnu/rustup-init" \
    && echo "${RUSTUP_SHA256}  /tmp/rustup-init" | sha256sum -c - \
    && chmod +x /tmp/rustup-init \
    && /tmp/rustup-init -y --no-modify-path --profile minimal --default-toolchain "$RUST_P2P" \
    && rm /tmp/rustup-init \
    && rustup toolchain install "$RUST_ANKI" --profile minimal \
    && rustup target add x86_64-unknown-linux-gnu

RUN curl --proto '=https' --tlsv1.2 -fsSL -o /tmp/protoc.zip \
      "https://github.com/protocolbuffers/protobuf/releases/download/v${PROTOC_VERSION}/protoc-${PROTOC_VERSION}-linux-x86_64.zip" \
    && echo "${PROTOC_SHA256}  /tmp/protoc.zip" | sha256sum -c - \
    && unzip -q /tmp/protoc.zip -d /opt/protoc && rm /tmp/protoc.zip

# vcpkg for the static libtorrent bridge; build_linux_so.sh fetches its pinned baseline.
RUN git clone https://github.com/microsoft/vcpkg.git "$VCPKG_ROOT" \
    && "$VCPKG_ROOT/bootstrap-vcpkg.sh" -disableMetrics

RUN git config --global --add safe.directory '*' \
    && git clone --depth 1 --branch "$FLUTTER_VERSION" https://github.com/flutter/flutter.git "$FLUTTER_ROOT" \
    && flutter config --no-analytics --enable-linux-desktop \
    && dart --disable-analytics \
    && flutter precache --linux \
    && flutter --version

WORKDIR /src
