#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 OUTPUT_DIRECTORY" >&2
  exit 64
fi

mkdir -p "$(dirname "$1")"
output_directory="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
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
# 离线构建包（third_party/mihon_build/README.md）：JDK 归档、Gradle 发行包、Gradle 依赖缓存都是
# tool/vendored_binaries.json 钉住的 vendored 件，构建期不连 corretto.aws / services.gradle.org /
# Maven Central（2026-11-27 发版时 Maven Central 回 429 把 Linux 构建弄红）。
offline_kit="$repository_root/third_party/mihon_build"
gradle_version="9.2.1"
corretto_version="21.0.12.8.1"
# macOS 版只出 Apple Silicon（arm64），不再支持 Intel Mac：macOS 只出
# runtime-macos-arm64 一份 JVM 镜像，也只钉 aarch64 的 JDK（x64 归档与哈希已删除）。
x64_archive=""
x64_archive_sha256=""
arm64_archive="amazon-corretto-$corretto_version-macosx-aarch64.tar.gz"
arm64_archive_sha256="cb230d7ac82784a4438663cdaf91d0d04037a9b4fb99ea41e138d88ce1224ab7"

jdk_group="mihon-jdk-macos-arm64"

# Linux：Dart 侧按 `<exe 目录>/mihon_bridge/runtime/bin/java` 找 JVM
# （desktop_mihon_runtime.dart `_javaExecutablePath`，与 Windows 同布局），bundle
# 只跑在构建机同架构上，所以只出宿主架构一份、目录名固定 `runtime`。哈希取自
# corretto/corretto-21 的 21.0.12.8.1 release notes。
host_os="$(uname -s)"
case "$host_os" in
  Darwin) ;;
  Linux)
    x64_archive="amazon-corretto-$corretto_version-linux-x64.tar.gz"
    x64_archive_sha256="75faed442d38a89c27f920e45ab24f9f71ff8ca6b732bfea90cdb500decd3c6b"
    arm64_archive="amazon-corretto-$corretto_version-linux-aarch64.tar.gz"
    arm64_archive_sha256="fd94500b0d3d7e6e040a9dc1b34cbe25046454e5e3047b68c1842fa6894e9bbc"
    jdk_group=""
    ;;
  *) echo "unsupported desktop runtime build host: $host_os" >&2; exit 1 ;;
esac

case "$(uname -m)" in
  arm64|aarch64) host_architecture="arm64" ;;
  x86_64) host_architecture="x64" ;;
  *) echo "unsupported build architecture: $(uname -m)" >&2; exit 1 ;;
esac
if [[ "$host_os" == Darwin && "$host_architecture" != arm64 ]]; then
  echo "macOS 版只支持 Apple Silicon（arm64），不在 Intel Mac 上构建 Mihon runtime" >&2
  exit 1
fi
if [[ -z "$jdk_group" ]]; then
  jdk_group="mihon-jdk-linux-$host_architecture"
fi

# 按宿主选校验工具，不按「PATH 里有没有 sha256sum」：macOS 14+ 自带的
# /sbin/sha256sum 是 BSD 实现，不认 GNU 的 `--status` 选项，探测到它就走
# GNU 分支会让每个归档都判校验失败。macOS 一律用自带的 shasum；Linux 用
# coreutils 的 sha256sum（精简镜像常没有 perl 版 shasum）。
case "$host_os" in
  Darwin) sha256_tool=(shasum -a 256) ;;
  *) sha256_tool=(sha256sum) ;;
esac
sha256_check() {
  "${sha256_tool[@]}" --check >/dev/null 2>&1
}
sha256_of() {
  "${sha256_tool[@]}" "$1" | awk '{print $1}'
}

case "$output_directory" in
  /|"") echo "refusing to write a desktop runtime to a filesystem root" >&2; exit 64 ;;
esac

working_root="$(mktemp -d "${TMPDIR:-/tmp}/fushi-mihon-build.XXXXXX")"
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
# 和语义与 clone 时代完全一致：先打 build/上游逻辑补丁，再用 Fushi 的安全
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

# 把 vendored 的 org.jogamp 离线 Maven 仓库搬进构建树。补丁后的 build.gradle.kts
# 用 `rootProject.file("fushi-offline-maven/jogamp")` 找它，目录在就离线解析、
# 不在就回落到两个远端镜像（见 third_party/jogamp/UPSTREAM：那两个主机分别在
# 2026-08-09 和 2026-08-25 把 CI 弄红过，而 Maven Central 根本没有 2.5.0）。
# 路径必须与补丁里的字面量一致，守卫 fushi/test/build/mihon_vendored_jogamp_guard_test.dart。
jogamp_repo="$repository_root/third_party/jogamp"
if [[ ! -f "$jogamp_repo/org/jogamp/jogl/jogl-all/2.5.0/jogl-all-2.5.0.jar" ]]; then
  echo "vendored org.jogamp repository is missing at $jogamp_repo" >&2
  exit 1
fi
mkdir -p "$source_root/fushi-offline-maven/jogamp"
cp -R "$jogamp_repo/org" "$source_root/fushi-offline-maven/jogamp/"

# 构建用到的离线件一次取齐（已在盘上且哈希对得上就只算一遍 sha256；CI 由
# .github/actions/fetch-vendored-binaries 预先放好，这里只是校验）。
py=python3
if ! python3 -c '' >/dev/null 2>&1; then py=python; fi
"$py" "$repository_root/tool/vendored_binaries.py" fetch --group mihon-build --group "$jdk_group"

prepare_jdk() {
  local architecture="$1"
  local archive="$2"
  local expected_sha256="$3"
  local archive_path="$offline_kit/jdk/$archive"

  printf '%s  %s\n' "$expected_sha256" "$archive_path" | sha256_check

  local extract_root="$working_root/jdk-$architecture"
  mkdir -p "$extract_root"
  tar -xzf "$archive_path" -C "$extract_root"
  local jdk_bundle
  jdk_bundle="$(find "$extract_root" -mindepth 1 -maxdepth 1 -type d -print -quit)"
  if [[ "$host_os" == Linux ]]; then
    printf '%s\n' "$jdk_bundle"
  else
    printf '%s\n' "$jdk_bundle/Contents/Home"
  fi
}

if [[ "$host_architecture" == arm64 ]]; then
  host_jdk_home="$(prepare_jdk \
    "arm64" \
    "$arm64_archive" \
    "$arm64_archive_sha256")"
else
  host_jdk_home="$(prepare_jdk \
    "x64" \
    "$x64_archive" \
    "$x64_archive_sha256")"
fi

# Gradle 发行包（不走 gradlew：wrapper 会去 services.gradle.org 下发行包）。
gradle_root="$working_root/gradle-dist"
mkdir -p "$gradle_root"
unzip -q "$offline_kit/gradle-$gradle_version-bin.zip" -d "$gradle_root"
gradle_launcher="$gradle_root/gradle-$gradle_version/bin/gradle"

# Compile and execute the Java 21-targeted server tests with the same verified
# toolchain that is bundled. A host Java 17 can compile Kotlin JVM 21 bytecode
# but cannot execute the resulting test classes.
#
# 依赖只从 vendored 的只读依赖缓存取（Gradle 官方的 GRADLE_RO_DEP_CACHE：目录下是一份
# caches/modules-2 拷贝），GRADLE_USER_HOME 每次全新、--offline 禁止任何远端解析：缓存缺件就当场
# 红并点名缺的坐标，而不是悄悄联网。依赖变了按 third_party/mihon_build/README.md 重新打包。
# FUSHI_MIHON_GRADLE_ONLINE_HOME 只给重新打包用：指向一个空目录时联网解析并把缓存留在那里。
if [[ -n "${FUSHI_MIHON_GRADLE_ONLINE_HOME:-}" ]]; then
  mkdir -p "$FUSHI_MIHON_GRADLE_ONLINE_HOME"
  JAVA_HOME="$host_jdk_home" ProductRevision="$server_revision" \
    GRADLE_USER_HOME="$FUSHI_MIHON_GRADLE_ONLINE_HOME" \
    sh "$gradle_launcher" -p "$source_root" :server:test :server:shadowJar --no-daemon
else
  ro_dep_cache="$working_root/gradle-ro-dep-cache"
  mkdir -p "$ro_dep_cache"
  tar -xzf "$offline_kit/gradle-ro-dep-cache.tar.gz" -C "$ro_dep_cache"
  JAVA_HOME="$host_jdk_home" ProductRevision="$server_revision" \
    GRADLE_USER_HOME="$working_root/gradle-home" GRADLE_RO_DEP_CACHE="$ro_dep_cache" \
    sh "$gradle_launcher" -p "$source_root" :server:test :server:shadowJar --no-daemon --offline
fi

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
if [[ "$host_os" == Linux ]]; then
  build_runtime "$host_jdk_home" "runtime"
else
  build_runtime "$host_jdk_home" "runtime-macos-arm64"
fi

cp "$server_jar" "$staging_root/m-extension-server.jar"
cp "$source_root/LICENSE" "$staging_root/LICENSE-M-Extension-Server.txt"
cp "$overlay_root/NOTICE" "$staging_root/NOTICE-M-Extension-Server.txt"

server_sha256="$(sha256_of "$staging_root/m-extension-server.jar")"
if [[ "$host_os" == Linux ]]; then
  corretto_archive_hashes="    \"linuxX64ArchiveSha256\": \"$x64_archive_sha256\",
    \"linuxArm64ArchiveSha256\": \"$arm64_archive_sha256\""
else
  corretto_archive_hashes="    \"macosArm64ArchiveSha256\": \"$arm64_archive_sha256\""
fi
cat >"$staging_root/checksums.json" <<EOF
{
  "mExtensionServer": {
    "version": "v1.0.5.0",
    "commit": "$server_commit",
    "sha256": "$server_sha256"
  },
  "corretto": {
    "version": "$corretto_version",
$corretto_archive_hashes
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
