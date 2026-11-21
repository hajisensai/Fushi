#!/bin/sh
# Build-time check (runtime stage of both Dockerfiles): every ELF file in the
# bundle resolves its shared libraries and glibc symbol versions on this base
# image. Fails the image build instead of the first start, e.g. for a bundle
# built on a newer distro than Debian trixie (the build-multiplatform
# linux-server artifact is built on ubuntu-latest; release bundles target
# glibc 2.35).
set -eu
ROOT="${1:-/opt/fushi_server}"
bad=0
for f in "$ROOT"/bin/* "$ROOT"/lib/*.so*; do
  [ -f "$f" ] && [ ! -L "$f" ] || continue
  [ "$(head -c 4 "$f" | od -An -c | tr -d ' ')" = '177ELF' ] || continue
  out="$(LD_LIBRARY_PATH="$ROOT/lib" ldd "$f" 2>&1 || true)"
  case "$out" in
    *'not found'*)
      echo "$f:"
      echo "$out" | grep 'not found'
      bad=1
      ;;
    *) ;;
  esac
done
if [ "$bad" != 0 ]; then
  echo "bundle does not run on $(ldd --version | head -n 1)" >&2
  exit 1
fi
echo "bundle libraries ok"
