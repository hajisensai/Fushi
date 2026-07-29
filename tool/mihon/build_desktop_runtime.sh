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
server_repository="https://github.com/miru-project/M-Extension-Server.git"
server_commit="ee55c65106bb18bf81a5ddc660d321b4e14ea2f9"
temurin_version="jdk-21.0.11+10"

case "$output_directory" in
  /|"") echo "refusing to write a desktop runtime to a filesystem root" >&2; exit 64 ;;
esac

mkdir -p "$download_cache"
working_root="$(mktemp -d "${TMPDIR:-/tmp}/hibiki-mihon-build.XXXXXX")"
trap 'rm -rf -- "$working_root"' EXIT
source_root="$working_root/M-Extension-Server"
staging_root="$working_root/output"

verified_download() {
  local download_url="$1"
  local archive_path="$2"
  local expected_sha256="$3"
  local archive_lock="$archive_path.lock"
  local lock_deadline=$((SECONDS + 120))
  local lock_owner=""
  local download_tmp=""

  if [[ -f "$archive_path" ]] &&
    printf '%s  %s\n' "$expected_sha256" "$archive_path" |
      shasum -a 256 --check >/dev/null 2>&1; then
    return
  fi

  while ! mkdir "$archive_lock" 2>/dev/null; do
    if [[ -f "$archive_lock/pid" ]]; then
      lock_owner="$(cat "$archive_lock/pid" 2>/dev/null || true)"
      if [[ "$lock_owner" =~ ^[0-9]+$ ]] &&
        ! kill -0 "$lock_owner" 2>/dev/null; then
        rm -rf -- "$archive_lock"
        continue
      fi
    fi
    if ((SECONDS >= lock_deadline)); then
      echo "timed out waiting for verified download lock: $archive_lock" >&2
      return 1
    fi
    sleep 0.1
  done
  printf '%s\n' "$$" >"$archive_lock/pid"

  if [[ -f "$archive_path" ]] &&
    printf '%s  %s\n' "$expected_sha256" "$archive_path" |
      shasum -a 256 --check >/dev/null 2>&1; then
    rmdir "$archive_lock" 2>/dev/null || rm -rf -- "$archive_lock"
    return
  fi

  find "$(dirname "$archive_path")" -maxdepth 1 -type f \
    -name "$(basename "$archive_path").tmp.*" -delete
  download_tmp="$(mktemp "$archive_path.tmp.XXXXXX")"
  if ! curl --fail --location --retry 3 --output "$download_tmp" "$download_url"; then
    rm -f -- "$download_tmp"
    rm -rf -- "$archive_lock"
    return 1
  fi
  if ! printf '%s  %s\n' "$expected_sha256" "$download_tmp" |
    shasum -a 256 --check >/dev/null; then
    rm -f -- "$download_tmp"
    rm -rf -- "$archive_lock"
    return 1
  fi
  mv "$download_tmp" "$archive_path"
  rmdir "$archive_lock" 2>/dev/null || rm -rf -- "$archive_lock"
}

git clone --filter=blob:none --no-checkout "$server_repository" "$source_root"
git -C "$source_root" checkout --detach "$server_commit"
git -C "$source_root" apply --unidiff-zero "$overlay_root/server-build.gradle.patch"
cp -R "$overlay_root/overlay/." "$source_root/"

prepare_jdk() {
  local architecture="$1"
  local archive="$2"
  local expected_sha256="$3"
  local archive_path="$download_cache/$archive"
  local download_version="${temurin_version/+/%2B}"
  local download_url="https://github.com/adoptium/temurin21-binaries/releases/download/$download_version/$archive"

  verified_download "$download_url" "$archive_path" "$expected_sha256"

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
JAVA_HOME="$host_jdk_home" "$source_root/gradlew" \
  -p "$source_root" :server:test :server:shadowJar --no-daemon

server_jar="$(find "$source_root/server/build" -maxdepth 1 -type f -name 'MExtensionServer-*.jar' -print -quit)"
if [[ -z "$server_jar" ]]; then
  echo "the online M-Extension-Server shadow JAR was not produced" >&2
  exit 1
fi
online_server_sha256="$(shasum -a 256 "$server_jar" | awk '{print $1}')"

JAVA_HOME="$host_jdk_home" "$source_root/gradlew" \
  -p "$source_root" :server:clean :server:test :server:shadowJar \
  --offline --no-daemon
server_jar="$(find "$source_root/server/build" -maxdepth 1 -type f -name 'MExtensionServer-*.jar' -print -quit)"
if [[ -z "$server_jar" ]]; then
  echo "the offline M-Extension-Server shadow JAR was not produced" >&2
  exit 1
fi
offline_server_sha256="$(shasum -a 256 "$server_jar" | awk '{print $1}')"
if [[ "$offline_server_sha256" != "$online_server_sha256" ]]; then
  echo "online/offline M-Extension-Server hash mismatch: online=$online_server_sha256 offline=$offline_server_sha256" >&2
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
cp "$overlay_root/UPSTREAM" "$staging_root/UPSTREAM-M-Extension-Server.txt"

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
