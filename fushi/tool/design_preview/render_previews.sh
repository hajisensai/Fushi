#!/usr/bin/env bash
# 生成 2026-10 UI / 动效重做的效果图（静态 PNG + 动效胶片 + 慢放 GIF）。
#
# 用法（在仓库任意位置）：
#   fushi/tool/design_preview/render_previews.sh [输出目录]
# 默认输出到 docs/design/2026-10-ui-motion-redesign/。
#
# 原理：跑 test/design_preview/redesign_preview_test.dart——它用真实的主题工厂与
# 生产组件在 flutter test 的离屏光栅里画图，所以效果图与 app 实际观感同源。
# 需要：flutter（与 .fvmrc 同版本）；可选 ffmpeg 或 ImageMagick 合成 GIF。
# CJK 字体自动探测（Noto CJK / 微软雅黑 / 苹方），找不到时设
# FUSHI_PREVIEW_CJK_FONT=<字体路径>。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_DIR="$(cd "$APP_DIR/.." && pwd)"
OUT="${1:-$REPO_DIR/docs/design/2026-10-ui-motion-redesign}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

echo "==> 渲染效果图到 $OUT"
(cd "$APP_DIR" && FUSHI_DESIGN_PREVIEW_OUT="$OUT" \
  flutter test --no-pub test/design_preview/redesign_preview_test.dart)

FRAMES="$OUT/frames"
if [ -d "$FRAMES" ]; then
  echo "==> 合成慢放 GIF"
  while IFS= read -r dir; do
    rel="${dir#"$FRAMES"/}"
    name="motion_${rel//\//_}"
    gif="$OUT/$name.gif"
    if command -v ffmpeg >/dev/null 2>&1; then
      ffmpeg -nostdin -loglevel error -y -framerate 6 -i "$dir/%03d.png" \
        -vf "split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse" \
        -loop 0 "$gif"
    elif command -v convert >/dev/null 2>&1; then
      convert -delay 16 -loop 0 "$dir"/*.png "$gif"
    else
      echo "   跳过 GIF（未找到 ffmpeg / ImageMagick），分帧保留在 $dir"
      continue
    fi
    echo "   $gif"
  done < <(find "$FRAMES" -type f -name '000.png' -exec dirname {} \; | sort)
  if [ "${KEEP_FRAMES:-0}" != "1" ]; then rm -rf "$FRAMES"; fi
fi
echo "==> 完成"
ls -1 "$OUT"
