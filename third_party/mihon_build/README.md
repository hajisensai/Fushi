# Mihon runtime 离线构建包

`tool/mihon/build_desktop_runtime.{sh,ps1}` 构建 M-Extension-Server JAR 与 jlink JVM 时用到的全部
外部件，都按 sha256 钉在 `tool/vendored_binaries.json`、存放在 `vendored-binaries` release，
在本目录按原路径取回（gitignored）。构建期不再连 corretto.aws / adoptium / services.gradle.org /
Maven Central / Google Maven / jitpack：2026-11-27 发版时 Maven Central 回 429，Linux 构建在
Gradle 解析依赖这一步红掉。

| 路径 | 清单组 | 内容 |
|---|---|---|
| `gradle-9.2.1-bin.zip` | `mihon-build` | Gradle 官方发行包（sha256 与 services.gradle.org 的 `.sha256` 一致） |
| `gradle-ro-dep-cache.tar.gz` | `mihon-build` | 一份 Gradle `caches/modules-2`，作只读依赖缓存（`GRADLE_RO_DEP_CACHE`）用 |
| `jdk/amazon-corretto-21.0.12.8.1-linux-x64.tar.gz` | `mihon-jdk-linux-x64` | Corretto 21（Linux bundle） |
| `jdk/amazon-corretto-21.0.12.8.1-linux-aarch64.tar.gz` | `mihon-jdk-linux-arm64` | Corretto 21（arm64 Linux 开发机） |
| `jdk/amazon-corretto-21.0.12.8.1-macosx-aarch64.tar.gz` | `mihon-jdk-macos-arm64` | Corretto 21（macOS arm64） |
| `jdk/OpenJDK21U-jdk_x64_windows_hotspot_21.0.11_10.zip` | `mihon-jdk-windows-x64` | Temurin 21（Windows） |

JDK 的 sha256 同时钉在构建脚本里（写进产物的 `checksums.json`），两处必须一致。

构建脚本自己调 `tool/vendored_binaries.py fetch --group mihon-build --group mihon-jdk-<平台>`，
然后：解开 Gradle 发行包直接跑（不走 `gradlew`，wrapper 会联网下发行包）、解开依赖缓存设成
`GRADLE_RO_DEP_CACHE`、`GRADLE_USER_HOME` 每次全新、加 `--offline`。缓存缺件时 Gradle 当场红并
点名缺的坐标，不会悄悄联网。

CI 上 Mihon runtime 本身按输入哈希存进原生产物持久库（`.github/actions/native-artifact-store`，
名字由 `.github/actions/native-store-names/names.sh` 的 `mihon_name` 算，本目录是输入之一），命中
时连上面这些件都不取；只有未命中才 `fetch-vendored-binaries` 这几组再离线构建。

## 依赖变了怎么重新打包

改了 `third_party/m_extension_server`（版本目录、补丁、overlay 里的依赖）或 Gradle 版本后，离线构建
会报缺坐标。在任一台机器上：

1. 准备一个空目录 `H`，`FUSHI_MIHON_GRADLE_ONLINE_HOME=H` 跑一次构建脚本（这一次联网解析）。
2. `python3 tool/mihon/pack_gradle_dep_cache.py H third_party/mihon_build/gradle-ro-dep-cache.tar.gz`
3. `python3 tool/vendored_binaries.py register --group mihon-build third_party/mihon_build/gradle-ro-dep-cache.tar.gz`
   （换 Gradle 版本时同样 register 新发行包、改两个构建脚本里的 `gradle_version` / `$gradleVersion`
   与 `.gitignore` 行；换 JDK 时 register 新归档、改脚本里的版本与 sha256。）
4. `python3 tool/vendored_binaries.py publish`，再不带 `FUSHI_MIHON_GRADLE_ONLINE_HOME` 离线跑一次确认。

依赖坐标与 OS 无关（JVM 件；jogamp 自带的 natives 走 `third_party/jogamp`），所以一台机器打的包
三端通用；2026-11-27 的这份在 Windows 上打，也只在 Windows 上离线构建验证过。
