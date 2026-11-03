#!/usr/bin/env bash
# 复现 README 里的对比表：每组配置跑一遍全样片，只留 ALL 汇总行。
cd "$(dirname "$0")"
run() {
  tag=$1; shift
  python bench.py "$tag" "$@" > "results/$tag.log" 2>&1 || { echo "FAIL $tag"; tail -3 "results/$tag.log"; return; }
  printf '%-10s %s\n' "$tag" "$(grep '^ALL' "results/$tag.log" | cut -c5-)"
}
mkdir -p results
run v1_auto mode=auto min_pixels=60 stable_k=0
run v2_auto mode=auto min_pixels=60 stable_k=2
run ocrbox_k2 mode=ocrbox stable_k=2
run best
run ocrbox2 mode=ocrbox2 thresh=0.45
run glyph mode=glyph min_pixels=60 stable_k=2
