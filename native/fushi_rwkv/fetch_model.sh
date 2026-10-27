#!/usr/bin/env bash
# 下载 RWKV-Instant 权重到 native/fushi_rwkv/model/ 并校验 SHA-256。
#   大模型 RWKV_trained_on_5000_10000.bin（~11 MB，AGPL，见 UPSTREAM.md）
#   小模型发布包 sm56-package.zip（~5.6 MB：weights.int8.bin / weights.f32.bin / 黄金测试向量；
#   许可尚未声明，见 README.md「小模型」）
# 都不入库。
#
# 用法: fetch_model.sh [目标目录]
#   本机直连 GitHub 不稳时先 export HTTPS_PROXY=http://127.0.0.1:34151（curl 会读它）。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST_DIR="${1:-$SCRIPT_DIR/model}"

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{ print $1 }'
  else
    shasum -a 256 "$1" | awk '{ print $1 }'
  fi
}

# fetch_pinned <文件名> <sha256> <url>...
fetch_pinned() {
  local name="$1" sha="$2"
  shift 2
  local target="$DEST_DIR/$name"
  if [[ -f "$target" && "$(sha256_of "$target")" == "$sha" ]]; then
    echo "OK (cached): $target"
    return 0
  fi
  local tmp="$target.download" url actual
  for url in "$@"; do
    echo "downloading $url"
    if curl -fL --retry 3 --retry-delay 2 -o "$tmp" "$url"; then
      actual="$(sha256_of "$tmp")"
      if [[ "$actual" == "$sha" ]]; then
        mv -f "$tmp" "$target"
        echo "OK: $target (sha256 $sha)"
        return 0
      fi
      echo "::warning::sha256 mismatch from $url: $actual" >&2
    fi
    rm -f "$tmp"
  done
  echo "::error::could not fetch $name with sha256 $sha" >&2
  return 1
}

mkdir -p "$DEST_DIR"

# 大模型：钉死到具体 commit（与 src/lib.rs 的 UPSTREAM_SHA 一致）；第二个是同一文件在
# JSchoreels/anki 的副本（字节相同，作备用）。SHA-256 同 src/lib.rs 的 MODEL_SHA256。
BIG="RWKV_trained_on_5000_10000.bin"
fetch_pinned "$BIG" 749ad1ad18d5b6ef8c4185802fa0c1e4a14e67cd7874f3efeaae355fffb1b9ec \
  "https://raw.githubusercontent.com/Pedrubik2000/kuma3-anki-core/c639bcec696f2317f9bb9a736d433b9d6c0d9c56/qt/aqt/rwkv_inference/$BIG" \
  "https://raw.githubusercontent.com/JSchoreels/anki/0dd75c5f8fa4ea3543f5a3559870e8aea047bf80/qt/aqt/rwkv_inference/$BIG"

# 小模型：GitHub release 资产；SHA-256 同 src/lib.rs 的 SMALL_MODEL_PACKAGE_SHA256。
fetch_pinned sm56-package.zip 7b1790f49fdabf1279510247cc9bc3bf3ac461b67cf0135ab8e51589b5efe71a \
  "https://github.com/JSchoreels/anki-rwkv/releases/download/small-model-sm56-2026-10-24/sm56-package.zip"
