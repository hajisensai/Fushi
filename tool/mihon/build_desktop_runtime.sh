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
corretto_version="21.0.12.8.1"
corretto_base_url="https://corretto.aws/downloads/resources/$corretto_version"
x64_archive="amazon-corretto-$corretto_version-macosx-x64.tar.gz"
x64_archive_sha256="a018ae6221babf065f770479b1bf0ab0d23bea78ed18f236c40bb5d4736612ffa"
arm64_archive="amazon-corretto-$corretto_version-macosx-aarch64.tar.gz"
arm64_archive_sha256="cb230d7ac82784a4438663cdaf91d0d04037a9b4fb99ea41e138d88ce1224ab7"
requested_architectures="${FUSHI_MIHON_ARCHS:-all}"

case "$requested_architectures" in
  all|host) ;;
  *) echo "FUSHI_MIHON_ARCHS must be 'all' or 'host'" >&2; exit 64 ;;
esac

case "$(uname -m)" in
  arm64) host_architecture="arm64" ;;
  x86_64) host_architecture="x64" ;;
  *) echo "unsupported macOS build architecture: $(uname -m)" >&2; exit 1 ;;
esac

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
#
# 补丁必须带上下文，这里也**绝不能**加回 `--unidiff-zero`（BUG-1428）：零上下文
# 补丁里纯插入的 hunk 没有任何可校验的内容，`git apply --check` 对上游漂移
# exit 0，真 apply 时按行号把新代码盲插到错误位置（实测 JGroupFilter 的
# `stateString` 字段被插到 `name` 与 `type` 之间——data class 的字段顺序是位置
# 语义，编译照过、行为已错）。带上下文之后，上游只是整体位移则 git 自动重定位，
# 内容真变了就硬失败。
git -C "$source_root" apply "$overlay_root/server-build.gradle.patch"
cp -R "$overlay_root/overlay/." "$source_root/"

download_verified_archive() {
  local archive="$1"
  local expected_sha256="$2"
  local archive_path="$download_cache/$archive"
  local partial_path="$archive_path.partial"
  local download_url="$corretto_base_url/$archive"

  if [[ -f "$archive_path" ]] &&
    ! printf '%s  %s\n' "$expected_sha256" "$archive_path" | shasum -a 256 --check >/dev/null 2>&1; then
    echo "resuming incomplete cached JDK archive: $archive_path" >&2
    if [[ ! -f "$partial_path" ]]; then
      mv "$archive_path" "$partial_path"
    else
      rm -f -- "$archive_path"
    fi
  fi

  if [[ ! -f "$archive_path" ]]; then
    local attempt
    for attempt in 1 2 3; do
      echo "downloading $archive (attempt $attempt/3)" >&2
      if curl \
        --fail \
        --location \
        --http1.1 \
        --retry 5 \
        --retry-all-errors \
        --continue-at - \
        --output "$partial_path" \
        "$download_url"; then
        if printf '%s  %s\n' "$expected_sha256" "$partial_path" | shasum -a 256 --check >/dev/null 2>&1; then
          mv "$partial_path" "$archive_path"
          break
        fi
        echo "checksum mismatch for completed JDK archive: $archive" >&2
        rm -f -- "$partial_path"
      fi
    done
  fi

  if [[ ! -f "$archive_path" ]] ||
    ! printf '%s  %s\n' "$expected_sha256" "$archive_path" | shasum -a 256 --check >/dev/null 2>&1; then
    echo "failed to download a verified JDK archive: $archive" >&2
    return 1
  fi
}

if [[ "$requested_architectures" == all ]]; then
  download_verified_archive "$x64_archive" "$x64_archive_sha256" &
  x64_download_pid=$!
  download_verified_archive "$arm64_archive" "$arm64_archive_sha256" &
  arm64_download_pid=$!
  download_failed=false
  wait "$x64_download_pid" || download_failed=true
  wait "$arm64_download_pid" || download_failed=true
  if [[ "$download_failed" == true ]]; then
    echo "failed to download the pinned macOS JDK archives" >&2
    exit 1
  fi
elif [[ "$host_architecture" == arm64 ]]; then
  download_verified_archive "$arm64_archive" "$arm64_archive_sha256"
else
  download_verified_archive "$x64_archive" "$x64_archive_sha256"
fi

prepare_jdk() {
  local architecture="$1"
  local archive="$2"
  local expected_sha256="$3"
  local archive_path="$download_cache/$archive"

  printf '%s  %s\n' "$expected_sha256" "$archive_path" | shasum -a 256 --check >/dev/null

  local extract_root="$working_root/jdk-$architecture"
  mkdir -p "$extract_root"
  tar -xzf "$archive_path" -C "$extract_root"
  local jdk_bundle
  jdk_bundle="$(find "$extract_root" -mindepth 1 -maxdepth 1 -type d -print -quit)"
  printf '%s\n' "$jdk_bundle/Contents/Home"
}

x64_jdk_home=""
arm64_jdk_home=""
if [[ "$requested_architectures" == all || "$host_architecture" == x64 ]]; then
  x64_jdk_home="$(prepare_jdk \
    "x64" \
    "$x64_archive" \
    "$x64_archive_sha256")"
fi
if [[ "$requested_architectures" == all || "$host_architecture" == arm64 ]]; then
  arm64_jdk_home="$(prepare_jdk \
    "arm64" \
    "$arm64_archive" \
    "$arm64_archive_sha256")"
fi

if [[ "$host_architecture" == arm64 ]]; then
  host_jdk_home="$arm64_jdk_home"
else
  host_jdk_home="$x64_jdk_home"
fi

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
if [[ -n "$x64_jdk_home" ]]; then
  build_runtime "$x64_jdk_home" "runtime-macos-x64"
fi
if [[ -n "$arm64_jdk_home" ]]; then
  build_runtime "$arm64_jdk_home" "runtime-macos-arm64"
fi

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
  "corretto": {
    "version": "$corretto_version",
    "macosX64ArchiveSha256": "$x64_archive_sha256",
    "macosArm64ArchiveSha256": "$arm64_archive_sha256"
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
