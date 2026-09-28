#!/bin/bash
# 把 FFmpeg 源码预先放进 ffmpeg-kit 的 src/ffmpeg 并打上 cert-pin 补丁。
#
# 为什么能「预先放」：ffmpeg-kit v6.0 的 download_library_source 先调
# library_is_downloaded，src/<lib> 目录存在且非空就直接跳过 clone
# （scripts/function.sh:2122-2129 / 2248-2280）。所以先 clone + 打补丁，
# 再跑 android.sh / ios.sh，补丁就会被编进去。
#
# 为什么补丁**不 commit**：ffmpeg-kit 的 ffmpeg.sh 每次构建都会
# `git checkout libavformat/file.c libavformat/protocols.c libavutil ffbuild`
# （scripts/android/ffmpeg.sh:382,395-397；scripts/apple/ffmpeg.sh:471,475-477），
# 这些路径与补丁触及的 libavformat/tls*.{c,h} 不相交，未提交的改动能活下来；
# 不 commit 还能让内嵌版本串保持 `FFmpeg version n6.0`，与现入库产物一致。
# 下面会校验「补丁只改了 tls* 文件」，哪天补丁越界碰到会被 checkout 回滚的路径
# 就当场失败，而不是静默编出一个没钉扎的产物。
#
# 用法：prepare_ffmpeg_src.sh <ffmpeg-kit 根目录>
# 可覆盖：FFMPEG_REPO（默认 https://github.com/arthenica/FFmpeg）、FFMPEG_REF（默认 n6.0，
#         即 scripts/source.sh:34-38 里 ffmpeg-kit v6.0 自己用的 ref）。
set -euo pipefail

KIT_DIR="${1:?usage: prepare_ffmpeg_src.sh <ffmpeg-kit dir>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH_FILE="${HERE}/ffmpeg-tls-pin-sha256.patch"
FFMPEG_REPO="${FFMPEG_REPO:-https://github.com/arthenica/FFmpeg}"
FFMPEG_REF="${FFMPEG_REF:-n6.0}"
SRC="${KIT_DIR}/src/ffmpeg"

[ -f "${PATCH_FILE}" ] || { echo "PATCH FILE MISSING: ${PATCH_FILE}"; exit 8; }

if [ ! -d "${SRC}/.git" ]; then
  # 必须是 git 工作树：ffmpeg.sh 里的 `git checkout ...` 要在这里执行。
  rm -rf "${SRC}"
  git clone --depth 1 --branch "${FFMPEG_REF}" "${FFMPEG_REPO}" "${SRC}"
fi

cd "${SRC}"
echo "FFmpeg source: $(git describe --tags --always) @ $(git rev-parse HEAD)"

if grep -q ff_tls_check_cert_pin libavformat/tls.c; then
  echo "cert-pin patch already applied"
else
  patch -p1 --forward --fuzz=0 < "${PATCH_FILE}"
fi

for f in libavformat/tls.h libavformat/tls.c libavformat/tls_openssl.c; do
  grep -q ff_tls_check_cert_pin "$f" || { echo "PATCH MISSING in $f"; exit 8; }
done
grep -q tls_pin_sha256 libavformat/tls.h || { echo "PATCH MISSING: tls_pin_sha256 option"; exit 8; }

# 补丁只能动 libavformat/tls*：ffmpeg.sh 会 `git checkout` 回滚 libavformat/file.c、
# libavformat/protocols.c、libavutil/、ffbuild/ 的未提交改动。判据查的是补丁文件本身
# （而不是工作树状态——构建机重跑时 ffmpeg-kit 自己的 sed 改动也在工作树里）。
unexpected="$(grep -E '^\+\+\+ ' "${PATCH_FILE}" | sed -E 's#^\+\+\+ b/##; s#[[:space:]].*$##' \
  | grep -v -E '^libavformat/tls[a-z_]*\.[ch]$' || true)"
if [ -n "${unexpected}" ]; then
  echo "cert-pin patch touches files outside libavformat/tls* (ffmpeg-kit may revert them):"
  echo "${unexpected}"
  exit 8
fi
echo "src/ffmpeg ready"
