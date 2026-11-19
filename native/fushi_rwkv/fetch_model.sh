#!/usr/bin/env bash
# 下载 RWKV-Instant 权重到 native/fushi_rwkv/model/ 并校验 SHA-256。
#   大模型 RWKV_trained_on_5000_10000.bin（~11 MB，AGPL，见 UPSTREAM.md）
#   小模型 sm98（Instant-Only，show-time 间隔训练）：int8 / f32 权重、architecture.json、黄金测试向量
#   （共 ~2.1 MB，AGPL；见 README.md「小模型」）。int8 权重首选 Fushi 自己的镜像 release
#   （hajisensai/Fushi tag rwkv-models，内容寻址、永不覆盖），上游 JSchoreels/anki 钉死提交的 raw URL 备用；
#   其余三个文件只在上游提交里。
#   省内存的 Tiny 小模型 sm101（Instant-Only，同上四个文件，~2 MB）：设置里可选，测试两套都对拍。
# 都不入库。
#
# 用法: fetch_model.sh [目标目录]
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

# 小模型 sm98：钉 JSchoreels/anki 的提交（同 src/lib.rs 的 SMALL_MODEL_SOURCE_SHA）；
# SHA-256 同 src/lib.rs 的 SMALL_MODEL_*_SHA256（与该提交的 manifest.json 一致）。
MIRROR="https://github.com/hajisensai/Fushi/releases/download/rwkv-models"
SMALL="https://raw.githubusercontent.com/JSchoreels/anki/001440b03395f24ffc1714b18ad3d9d4d89d2067"
fetch_pinned sm98_weights.int8.bin b2f335bd712b9d602150201de41ab5a0f0a4c291644705e2aa1ed2a1bf1592c3   "$MIRROR/b2f335bd712b9d60-sm98-weights.int8.bin"   "$SMALL/qt/aqt/rwkv_inference/sm98/weights.int8.bin"
fetch_pinned sm98_weights.f32.bin a006dcc039d19142dc95d257d9c238fb93c7efa12b78e18ec6ae881ac9009a24   "$SMALL/qt/aqt/rwkv_inference/sm98/weights.f32.bin"
fetch_pinned sm98_architecture.json 9bd41f1189dc0113277d371223ce805612aaec07101804160fe86312eed15de3   "$SMALL/qt/aqt/rwkv_inference/sm98/architecture.json"
fetch_pinned sm98-vectors.json.gz c7d8df407966fccd8f98227241816e114ce9ed1dfea799587e481c1d5926a453   "$SMALL/rslib/src/rwkv/testdata/sm98-vectors.json.gz"
# Tiny 小模型 sm101：同一提交；SHA-256 同 src/lib.rs 的 TINY_MODEL_*_SHA256。
fetch_pinned sm101_weights.int8.bin 77703dd2f2a21a1bcadaedfed1cec93ee0fd6fd6d3c840be221e72b5e1c05066   "$MIRROR/77703dd2f2a21a1b-sm101-weights.int8.bin"   "$SMALL/qt/aqt/rwkv_inference/sm101/weights.int8.bin"
fetch_pinned sm101_weights.f32.bin 2faacb5b913bcfbdc0e363532d533e3bcff6872c8358f1ef753ca87f9d2a60fd   "$SMALL/qt/aqt/rwkv_inference/sm101/weights.f32.bin"
fetch_pinned sm101_architecture.json 49650457329d43ff7f3f04f68926e371d49060699142cfec9497cb759ac7a75f   "$SMALL/qt/aqt/rwkv_inference/sm101/architecture.json"
fetch_pinned sm101-vectors.json.gz 18de8ae77a1a40986dc432531116dfb009beae2385001ef425389a3ad7919a9e   "$SMALL/rslib/src/rwkv/testdata/sm101-vectors.json.gz"
