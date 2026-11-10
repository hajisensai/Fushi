#!/usr/bin/env bash
# 下载 RWKV-Instant 权重到 native/fushi_rwkv/model/ 并校验 SHA-256。
#   大模型 RWKV_trained_on_5000_10000.bin（~11 MB，AGPL，见 UPSTREAM.md）
#   小模型 sm72e25（无泄漏 SM72、第 25 轮起降温）：int8 / f32 权重、architecture.json、黄金测试向量
#   （共 ~2.1 MB，钉 JSchoreels/anki 的提交，AGPL；见 README.md「小模型」）
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

# 小模型 sm72e25：钉 JSchoreels/anki 的提交（同 src/lib.rs 的 SMALL_MODEL_SOURCE_SHA）；
# SHA-256 同 src/lib.rs 的 SMALL_MODEL_*_SHA256（与该提交的 manifest.json 一致）。
SMALL="https://raw.githubusercontent.com/JSchoreels/anki/986963d23e7ec9f22771c38998ef9042214c2b98"
fetch_pinned sm72e25_weights.int8.bin ff626af2e974346ed282615d190500148b22cfe05cbfd081b1e70d5a1dfa3cd9 \
  "$SMALL/qt/aqt/rwkv_inference/sm72e25/weights.int8.bin"
fetch_pinned sm72e25_weights.f32.bin 42b79e35ad78bf291817cb48979f48fd105b39fc43b6a5ca954938d3f25cf261 \
  "$SMALL/qt/aqt/rwkv_inference/sm72e25/weights.f32.bin"
fetch_pinned sm72e25_architecture.json 9bd41f1189dc0113277d371223ce805612aaec07101804160fe86312eed15de3 \
  "$SMALL/qt/aqt/rwkv_inference/sm72e25/architecture.json"
fetch_pinned sm72e25-vectors.json.gz db54656bc41a22a175d2b905304d45e6ae6b0bb4efd1af8dfce9185f40ee1a01 \
  "$SMALL/rslib/src/rwkv/testdata/sm72e25-vectors.json.gz"
