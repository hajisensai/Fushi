#!/usr/bin/env bash
set -euo pipefail

placebo_ref="v7.360.1"
output_dir=""
work_dir=""

usage() {
  cat <<'EOF'
Usage: build_placebo.sh --output DIR [--ref GIT_REF] [--work-dir DIR]

Build the Windows x64 D3D11-only libplacebo bundle under MSYS2 MINGW64.
The result contains one self-contained libplacebo DLL plus headers and license.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      output_dir="$2"
      shift 2
      ;;
    --ref)
      placebo_ref="$2"
      shift 2
      ;;
    --work-dir)
      work_dir="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$output_dir" ]]; then
  echo "--output is required" >&2
  usage >&2
  exit 2
fi

if [[ "${MSYSTEM:-}" != "MINGW64" ]]; then
  echo "Run this script in an MSYS2 MINGW64 shell" >&2
  exit 2
fi

for command in git meson ninja pkg-config sha256sum strip objdump ldd cygpath pacman; do
  command -v "$command" >/dev/null || {
    echo "Missing required command: $command" >&2
    exit 2
  }
done

# MSYS2 is rolling-release. Refuse silent toolchain drift so a vendor refresh
# cannot replace the checked-in binary under the same upstream/version record.
expected_packages=(
  'mingw-w64-x86_64-binutils 2.47-3'
  'mingw-w64-x86_64-gcc 16.2.0-3'
  'mingw-w64-x86_64-meson 1.12.0-1'
  'mingw-w64-x86_64-ninja 1.13.2-1'
  'mingw-w64-x86_64-shaderc 2026.3-1'
  'mingw-w64-x86_64-spirv-cross 1~1.4.357.0-1'
)
for expected in "${expected_packages[@]}"; do
  package="${expected%% *}"
  actual="$(pacman -Q "$package")"
  if [[ "$actual" != "$expected" ]]; then
    echo "MSYS2 package drift: expected '$expected', got '$actual'" >&2
    exit 1
  fi
done

output_dir="$(mkdir -p "$output_dir" && cd "$output_dir" && pwd)"
case "$output_dir" in
  /|/usr|/mingw64|"${HOME:-__unset__}")
    echo "Refusing unsafe output directory: $output_dir" >&2
    exit 2
    ;;
esac
if [[ -z "$work_dir" ]]; then
  work_dir="$(mktemp -d "${TMPDIR:-/tmp}/fushi-libplacebo.XXXXXX")"
  trap 'rm -rf "$work_dir"' EXIT
else
  mkdir -p "$work_dir"
  work_dir="$(cd "$work_dir" && pwd)"
fi
case "$work_dir" in
  /|/usr|/mingw64|"${HOME:-__unset__}")
    echo "Refusing unsafe work directory: $work_dir" >&2
    exit 2
    ;;
esac

source_dir="$work_dir/libplacebo"
static_pc_dir="$work_dir/static-pc"
build_dir="$work_dir/build"
mingw_prefix="$(cygpath -m "${MINGW_PREFIX:-/mingw64}")"
shaderc_version="$(PKG_CONFIG_PATH=/mingw64/lib/pkgconfig pkg-config --modversion shaderc_combined)"
spirv_cross_version="$(PKG_CONFIG_PATH=/mingw64/lib/pkgconfig pkg-config --modversion spirv-cross-c)"
mkdir -p "$static_pc_dir"

# A caller may reuse --work-dir while changing --ref. Never silently build the
# previous checkout: replace only this script-owned source subdirectory.
rm -rf "$source_dir"
git clone --depth 1 --branch "$placebo_ref" \
  https://github.com/haasn/libplacebo.git "$source_dir"

cat >"$static_pc_dir/shaderc_combined.pc" <<EOF
prefix=$mingw_prefix
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: shaderc_combined
Description: Static shaderc_combined for the self-contained libplacebo DLL
Version: $shaderc_version
Libs: -L\${libdir} -lshaderc_combined -lglslang -lSPIRV-Tools-opt -lSPIRV-Tools
Cflags: -I\${includedir}
EOF

cat >"$static_pc_dir/spirv-cross-c-shared.pc" <<EOF
prefix=$mingw_prefix
libdir=\${prefix}/lib
includedir=\${prefix}/include/spirv_cross

Name: spirv-cross-c-shared
Description: Static SPIRV-Cross C API for the self-contained libplacebo DLL
Version: $spirv_cross_version
Libs: -L\${libdir} -lspirv-cross-c -lspirv-cross-glsl -lspirv-cross-hlsl -lspirv-cross-msl -lspirv-cross-cpp -lspirv-cross-reflect -lspirv-cross-core
Cflags: -I\${includedir}
EOF

export PKG_CONFIG_PATH="$static_pc_dir:/mingw64/lib/pkgconfig"

rm -rf "$build_dir"
meson setup "$build_dir" "$source_dir" --buildtype=release --prefer-static \
  -Ddefault_library=shared \
  -Dc_link_args="-static-libgcc -static-libstdc++ -Wl,-Bstatic -lstdc++ -lwinpthread -Wl,-Bdynamic" \
  -Dcpp_link_args="-static-libgcc -static-libstdc++ -Wl,-Bstatic -lstdc++ -lwinpthread -Wl,-Bdynamic" \
  -Dvulkan=disabled -Dopengl=disabled -Dd3d11=enabled -Dshaderc=enabled -Dglslang=disabled \
  -Dlcms=disabled -Ddovi=disabled -Dlibdovi=disabled -Dxxhash=disabled -Dunwind=disabled \
  -Ddemos=false -Dtests=false -Dbench=false -Dfuzz=false
ninja -C "$build_dir"

rm -rf "$output_dir/bin" "$output_dir/include"
mkdir -p "$output_dir/bin" "$output_dir/include"
cp "$build_dir"/src/libplacebo-*.dll "$output_dir/bin/"
strip --strip-unneeded "$output_dir"/bin/libplacebo-*.dll
cp -r "$source_dir/src/include/libplacebo" "$output_dir/include/"
cp "$build_dir/src/include/libplacebo/config.h" "$output_dir/include/libplacebo/config.h"
rm -f "$output_dir/include/libplacebo/config.h.in"
cp "$source_dir/LICENSE" "$output_dir/LICENSE.libplacebo"

mapfile -t bundled_dlls < <(find "$output_dir/bin" -maxdepth 1 -type f -name '*.dll' -printf '%f\n' | sort)
if [[ ${#bundled_dlls[@]} -ne 1 || "${bundled_dlls[0]}" != libplacebo-*.dll ]]; then
  echo "Expected exactly one libplacebo DLL, got: ${bundled_dlls[*]:-(none)}" >&2
  exit 1
fi

(
  cd "$output_dir/bin"
  sha256sum "${bundled_dlls[0]}" >SHA256SUMS
  cat SHA256SUMS
)

if ldd "$output_dir/bin/${bundled_dlls[0]}" | grep -qi '/mingw64/'; then
  echo "Unexpected MSYS2 runtime dependency:" >&2
  ldd "$output_dir/bin/${bundled_dlls[0]}" | grep -i '/mingw64/' >&2
  exit 1
fi

exports="$(objdump -p "$output_dir/bin/${bundled_dlls[0]}")"
for symbol in pl_d3d11_create pl_mpv_user_shader_parse pl_render_image pl_log_create_; do
  grep -q "$symbol" <<<"$exports" || {
    echo "Missing required export: $symbol" >&2
    exit 1
  }
done
grep -E 'pl_d3d11_create|pl_mpv_user_shader_parse|pl_render_image|pl_log_create_' <<<"$exports"
