# flatpak-builder host for the Fushi Flatpak. Run privileged (bubblewrap needs it).
FROM debian:trixie
RUN apt-get update && apt-get install -y --no-install-recommends \
      flatpak flatpak-builder elfutils patch ca-certificates git xz-utils zstd python3 curl \n      ostree gnupg \
    && rm -rf /var/lib/apt/lists/*
RUN flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
