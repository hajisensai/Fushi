#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: $0 OUTPUT_DIRECTORY [DOWNLOAD_CACHE]" >&2
  exit 64
fi

mkdir -p "$(dirname "$1")"
output_directory="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
download_cache="${2:-${RUNNER_TEMP:-/tmp}/hibiki-mihon-downloads}"
script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd "$script_directory/../.." && pwd)"
overlay_root="$repository_root/third_party/m_extension_server"
# 上游 miru-project/M-Extension-Server 已从 GitHub 消失（404），原先的
# `git clone` 会转去交互取凭据并以 exit 128 挂掉整个 job。源码按 MPL-2.0
# vendored 进 upstream_src/，构建从本地树取，不再依赖任何外部仓库。
vendored_source_root="$overlay_root/upstream_src"
server_commit="ee55c65106bb18bf81a5ddc660d321b4e14ea2f9"
# 上游 server/build.gradle.kts 用 `git rev-list HEAD --count` 生成 revision，
# vendored 树没有 .git 会退化成空串。走上游自带的 ProductRevision 钩子把它钉成
# 被 vendor 的 commit 短 SHA，产物名与 manifest 因此直接指向真相源。
server_revision="${server_commit:0:7}"
temurin_version="jdk-21.0.11+10"

case "$output_directory" in
  /|"") echo "refusing to write a desktop runtime to a filesystem root" >&2; exit 64 ;;
esac

mkdir -p "$download_cache"
working_root="$(mktemp -d "${TMPDIR:-/tmp}/hibiki-mihon-build.XXXXXX")"
trap 'rm -rf -- "$working_root"' EXIT
source_root="$working_root/M-Extension-Server"
staging_root="$working_root/output"

if [[ ! -f "$vendored_source_root/settings.gradle.kts" ]]; then
  echo "vendored M-Extension-Server source is missing at $vendored_source_root" >&2
  exit 1
fi
mkdir -p "$source_root"
cp -R "$vendored_source_root/." "$source_root/"
# `git apply` 在非 git 目录下同样可用（实测 exit 0），补丁与 overlay 的应用顺序
# 和语义与 clone 时代完全一致：先打 build/上游逻辑补丁，再用 Hibiki 的安全
# overlay 覆盖同名文件。
git -C "$source_root" apply --unidiff-zero "$overlay_root/server-build.gradle.patch"
cp -R "$overlay_root/overlay/." "$source_root/"

prepare_jdk() {
  local architecture="$1"
  local archive="$2"
  local expected_sha256="$3"
  local archive_path="$download_cache/$archive"
  local download_version="${temurin_version/+/%2B}"
  local download_url="https://github.com/adoptium/temurin21-binaries/releases/download/$download_version/$archive"

  if [[ ! -f "$archive_path" ]]; then
    curl --fail --location --retry 3 --output "$archive_path" "$download_url"
  fi
  printf '%s  %s\n' "$expected_sha256" "$archive_path" | shasum -a 256 --check >/dev/null

  local extract_root="$working_root/jdk-$architecture"
  mkdir -p "$extract_root"
  tar -xzf "$archive_path" -C "$extract_root"
  local jdk_bundle
  jdk_bundle="$(find "$extract_root" -mindepth 1 -maxdepth 1 -type d -print -quit)"
  printf '%s\n' "$jdk_bundle/Contents/Home"
}

x64_jdk_home="$(prepare_jdk \
  "x64" \
  "OpenJDK21U-jdk_x64_mac_hotspot_21.0.11_10.tar.gz" \
  "34180eb03e6d207c388cce3da668f6cc7cd7508c185c24782fadac2c9c0e66f9")"
arm64_jdk_home="$(prepare_jdk \
  "arm64" \
  "OpenJDK21U-jdk_aarch64_mac_hotspot_21.0.11_10.tar.gz" \
  "6ebcf221c9b41507b14c098e93c6ead6440b8d9bd154f8ec666c4c73abbdb201")"

case "$(uname -m)" in
  arm64) host_jdk_home="$arm64_jdk_home" ;;
  x86_64) host_jdk_home="$x64_jdk_home" ;;
  *) echo "unsupported macOS build architecture: $(uname -m)" >&2; exit 1 ;;
esac

# Compile and execute the Java 21-targeted server tests with the same verified
# toolchain that is bundled. A host Java 17 can compile Kotlin JVM 21 bytecode
# but cannot execute the resulting test classes.
JAVA_HOME="$host_jdk_home" ProductRevision="$server_revision" "$source_root/gradlew" \
  -p "$source_root" :server:test :server:shadowJar --no-daemon

server_jar="$(find "$source_root/server/build" -maxdepth 1 -type f -name 'MExtensionServer-*.jar' -print -quit)"
if [[ -z "$server_jar" ]]; then
  echo "the M-Extension-Server shadow JAR was not produced" >&2
  exit 1
fi

build_runtime() {
  local target_jdk_home="$1"
  local runtime_name="$2"
  local detected_modules
  detected_modules="$("$host_jdk_home/bin/jdeps" --ignore-missing-deps --multi-release 21 --print-module-deps "$server_jar")"
  local modules
  modules="$(printf '%s\n' "$detected_modules,java.base,java.desktop,java.logging,java.naming,java.net.http,java.prefs,java.security.jgss,java.sql,jdk.crypto.ec,jdk.unsupported" |
    tr ',' '\n' | sed '/^$/d' | sort -u | paste -sd, -)"

  "$host_jdk_home/bin/jlink" \
    --module-path "$target_jdk_home/jmods" \
    --add-modules "$modules" \
    --strip-debug \
    --no-header-files \
    --no-man-pages \
    --compress=2 \
    --output "$staging_root/$runtime_name"
}

mkdir -p "$staging_root"
build_runtime "$x64_jdk_home" "runtime-macos-x64"
build_runtime "$arm64_jdk_home" "runtime-macos-arm64"

cp "$server_jar" "$staging_root/m-extension-server.jar"
cp "$source_root/LICENSE" "$staging_root/LICENSE-M-Extension-Server.txt"
cp "$overlay_root/NOTICE" "$staging_root/NOTICE-M-Extension-Server.txt"

server_sha256="$(shasum -a 256 "$staging_root/m-extension-server.jar" | awk '{print $1}')"
cat >"$staging_root/checksums.json" <<EOF
{
  "mExtensionServer": {
    "version": "v1.0.5.0",
    "commit": "$server_commit",
    "sha256": "$server_sha256"
  },
  "temurin": {
    "version": "$temurin_version",
    "macosX64ArchiveSha256": "34180eb03e6d207c388cce3da668f6cc7cd7508c185c24782fadac2c9c0e66f9",
    "macosArm64ArchiveSha256": "6ebcf221c9b41507b14c098e93c6ead6440b8d9bd154f8ec666c4c73abbdb201"
  }
}
EOF

backup_directory=""
if [[ -e "$output_directory" ]]; then
  backup_directory="$output_directory.backup.$RANDOM.$RANDOM"
  mv "$output_directory" "$backup_directory"
fi
if mv "$staging_root" "$output_directory"; then
  if [[ -n "$backup_directory" ]]; then
    rm -rf -- "$backup_directory"
  fi
else
  if [[ -n "$backup_directory" && ! -e "$output_directory" ]]; then
    mv "$backup_directory" "$output_directory"
  fi
  exit 1
fi
