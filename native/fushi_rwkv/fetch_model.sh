#!/usr/bin/env bash
# 下载 RWKV-Instant 权重到 native/fushi_rwkv/model/ 并校验 SHA-256。
#   大模型 RWKV_trained_on_5000_10000.bin（~11 MB，AGPL，见 UPSTREAM.md）
#   小模型 sm113（Small Instant-Only，show-time 间隔训练）：int8 / f32 权重、architecture.json、黄金测试向量
#   （共 ~2.1 MB，AGPL；见 README.md「小模型」）。int8 权重首选 Fushi 自己的镜像 release
#   （hajisensai/Fushi tag rwkv-models，内容寻址、永不覆盖），上游 JSchoreels/anki 钉死提交的 raw URL 备用；
#   其余三个文件只在上游提交里。
#   六层 Tiny 小模型 sm130io（Instant-Only，同上四个文件，~1.3 MB）：默认档位，测试两套都对拍。
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

# 小模型 sm113：钉 JSchoreels/anki 的提交（同 src/lib.rs 的 SMALL_MODEL_SOURCE_SHA）；
# SHA-256 同 src/lib.rs 的 SMALL_MODEL_*_SHA256（与该提交的 manifest.json 一致）。
MIRROR="https://github.com/hajisensai/Fushi/releases/download/rwkv-models"
SMALL="https://raw.githubusercontent.com/JSchoreels/anki/6cb164606984c14432ef5e9befdedd6cc070f539"
fetch_pinned sm113_weights.int8.bin 87bce8dbb48a11dd599646547d241b39b6c881a8f7702aacd6284f6a9d1ecc54   "$MIRROR/87bce8dbb48a11dd-sm113-weights.int8.bin"   "$SMALL/qt/aqt/rwkv_inference/sm113/weights.int8.bin"
fetch_pinned sm113_weights.f32.bin cc87f080eb5f25405aa2afc85fe532b9f59888aa6bbf1464e1a445cb92c42388   "$SMALL/qt/aqt/rwkv_inference/sm113/weights.f32.bin"
fetch_pinned sm113_architecture.json 9bd41f1189dc0113277d371223ce805612aaec07101804160fe86312eed15de3   "$SMALL/qt/aqt/rwkv_inference/sm113/architecture.json"
fetch_pinned sm113-vectors.json.gz d54978f43e1f89c75ef0f72dd438789d378ffddd96667eef0908c86a7813830e   "$SMALL/rslib/src/rwkv/testdata/sm113-vectors.json.gz"
# 六层 Tiny 小模型 sm130io：同一提交；SHA-256 同 src/lib.rs 的 TINY_MODEL_*_SHA256。
fetch_pinned sm130io_weights.int8.bin 24b39f61129bd9eb45156f45a32e749e1a0cf8d75e9271c2ed7038f9d6265771   "$MIRROR/24b39f61129bd9eb-sm130io-weights.int8.bin"   "$SMALL/qt/aqt/rwkv_inference/sm130io/weights.int8.bin"
fetch_pinned sm130io_weights.f32.bin 89703de0a195426905e59a0abd428a52a09b0eab1ba653b5a902e5f849018f82   "$SMALL/qt/aqt/rwkv_inference/sm130io/weights.f32.bin"
fetch_pinned sm130io_architecture.json e5acb452e53788141c44d3ad9d98bcec124b9cfbecaa29718085717ee4022618   "$SMALL/qt/aqt/rwkv_inference/sm130io/architecture.json"
fetch_pinned sm130io-vectors.json.gz 19711eb2c0c4a4de84f36d66c3a829e748548be4e7b35dc8604e3ea795b7af3b   "$SMALL/rslib/src/rwkv/testdata/sm130io-vectors.json.gz"
