#!/usr/bin/env bash
# 下载 RWKV-Instant 通用预训练权重到 native/fushi_rwkv/model/ 并校验 SHA-256。
# 权重（~11 MB）不入库；来源与许可见 UPSTREAM.md。
#
# 用法: fetch_model.sh [目标目录]
#   本机直连 GitHub 不稳时先 export HTTPS_PROXY=http://127.0.0.1:34151（curl 会读它）。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST_DIR="${1:-$SCRIPT_DIR/model}"
NAME="RWKV_trained_on_5000_10000.bin"
SHA256="749ad1ad18d5b6ef8c4185802fa0c1e4a14e67cd7874f3efeaae355fffb1b9ec"
SIZE=11082637
# 钉死到具体 commit（与 src/lib.rs 的 UPSTREAM_SHA 一致）；第二个是同一文件在
# JSchoreels/anki 的副本（字节相同，作备用）。
URLS=(
  "https://raw.githubusercontent.com/Pedrubik2000/kuma3-anki-core/c639bcec696f2317f9bb9a736d433b9d6c0d9c56/qt/aqt/rwkv_inference/$NAME"
  "https://raw.githubusercontent.com/JSchoreels/anki/0dd75c5f8fa4ea3543f5a3559870e8aea047bf80/qt/aqt/rwkv_inference/$NAME"
)

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{ print $1 }'
  else
    shasum -a 256 "$1" | awk '{ print $1 }'
  fi
}

mkdir -p "$DEST_DIR"
target="$DEST_DIR/$NAME"
if [[ -f "$target" && "$(sha256_of "$target")" == "$SHA256" ]]; then
  echo "OK (cached): $target"
  exit 0
fi

tmp="$target.download"
for url in "${URLS[@]}"; do
  echo "downloading $url"
  if curl -fL --retry 3 --retry-delay 2 -o "$tmp" "$url"; then
    actual="$(sha256_of "$tmp")"
    if [[ "$actual" == "$SHA256" ]]; then
      mv -f "$tmp" "$target"
      echo "OK: $target ($SIZE bytes, sha256 $SHA256)"
      exit 0
    fi
    echo "::warning::sha256 mismatch from $url: $actual" >&2
  fi
  rm -f "$tmp"
done
echo "::error::could not fetch $NAME with sha256 $SHA256" >&2
exit 1
