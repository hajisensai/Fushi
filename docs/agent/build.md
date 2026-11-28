# 构建与依赖补丁

> [CLAUDE.md](../../CLAUDE.md) 的子文档。构建上手见 [README.md](../../README.md)；这里只补 agent 关心的增量。

## 平台与 SDK

5 平台均出包：Android / iOS / macOS / Windows / Linux（`auto` 下五个平台统一走 Material 3，另一档是 Apple（glass）设计系统；隐藏的 Cupertino / macOS 渲染器已于 2026-11-28 整删；桌面 EPUB 渲染：Windows 靠 fork 的 `flutter_inappwebview_windows`，Linux 靠 vendored 的 `packages/flutter_inappwebview_linux`（WPE WebKit，见下「Linux 桌面（源码构建）」）。Android：`compileSdk 36` / `minSdkVersion 26` / `targetSdk 35`。

**macOS 只出 Apple Silicon（arm64），不再支持 Intel Mac（2026-10 起）。** `flutter build macos --release` 默认出 universal，靠 `fushi/macos/Runner.xcodeproj` 工程级 `EXCLUDED_ARCHS = x86_64`（Flutter 把它透传给 xcodebuild；`fushi/macos/Podfile` 的 `post_install` 给 Pods 钉同一份）收成 arm64；`release-desktop.yml` 的「Verify macOS app is arm64-only」门钉住 app 本体恰好是 arm64，随包原生件（`libfushi_p2p.dylib` / `libfushi_fsrs.dylib` / `libfushi_compute.dylib` / `libfushi_torrent_ffi.dylib` / `fushi-anki-sync` / 统一 FFmpeg（`ffmpeg-unified-macos.tar.gz`）/ Mihon `runtime-macos-arm64`）一律只出 arm64，并按 app 本体的 `lipo -archs` 核对。发布资产名随之从 `fushi-<v>-macos.zip` 改为 `fushi-<v>-macos-arm64.zip`：已发出去的旧版（universal，可能跑在 Intel Mac 上）的更新器只认 `-macos.zip`，改名让它们选不中 Intel 上启动不了的 arm64 包，代价是旧版在 Apple Silicon 上也跨不过这一版的应用内自动更新（判「无更新」），需要手动下载一次新版。iOS 模拟器的 x86_64 切片、Windows / Linux / Android 的 x64 不在此列。Intel Mac 上的开发构建同样不再支持（`build_desktop_runtime.sh` / `script/build_and_run.sh` 在 Intel 宿主上直接报错）。

## Linux 桌面（源码构建）

**定位（2026-11-23 起）**：Linux App 与其他四端一样随 `release-desktop.yml` 自动出包发布（下文「Flatpak」一段）：每个通道的 release 带 `fushi-<v>-linux-x86_64.flatpak`（主分发，签名 OSTree 仓库在 GitHub Pages，应用内自更新）与 `fushi-<v>-linux-x64.tar.gz`（便携 bundle，给不用 Flatpak 的发行版；没有应用内安装器，更新器只打开发布页）。PR 上不编 Linux App（`build-multiplatform.yml` 只有 `linux-server`），Linux App 的回归由 `develop` 每次 push 的 `release-desktop.yml` `linux` job 兜住。下面是本地自己编、自己验的全部前提；改动 Linux 相关代码时按「验证」一节在 Docker 里自证。

bundle 布局：`build/linux/x64/<mode>/bundle/{fushi, lib/, data/, mihon_bridge/}`。runner 的 RUNPATH 是 `$ORIGIN/lib`，但它**只管 exe 的直接依赖**——插件 `.so` 的 `DT_NEEDED` 走插件自己的 RUNPATH，Dart VM 发起的 `DynamicLibrary.open` 也不吃 exe 的 RUNPATH。所以：

- 随包库被插件依赖时，插件 RUNPATH 必须带 `$ORIGIN`（`flutter_onnxruntime` 曾因此在任何非构建机上让整个 app 起不来，见 `third_party/flutter_onnxruntime/PATCHES.md` 第 12 条）。
- Dart 侧 FFI 库在 Linux 上按 `<exe 目录>/lib/<名>` 绝对路径优先加载（fushidicts / fushi_torrent / pdfium 一致；pdfium_dart 上游本来就这么做）。
- 验证一律在**脱离构建树**的环境里做（bundle 拷进干净容器再 `ldd ./fushi`），在构建机上 ldd 永远是绿的——插件的构建期 RUNPATH 指回构建目录。检查命令：`find bundle/lib -xtype l`（不得有悬空链接）与 `ldd bundle/fushi | grep "not found"`（只允许发行版运行时依赖缺失）。

随包原生库：`libfushidicts_ffi.so`（CMake 同构建）、`libonnxruntime.so.1`（插件下载 1.22.0）、`libpdfium.so` / `libsqlite3.so`（native assets）、`libfushi_torrent_ffi.so`（`native/fushi_torrent/build_linux_so.sh` 静态链，copy-if-present；缺失时下载后端回退外接 qBittorrent）、`mihon_bridge/`（`tool/mihon/build_desktop_runtime.sh` 的 Linux 分支：Corretto 21 linux jlink 出 `runtime/` + M-Extension-Server JAR）。

**WebView = WPE WebKit，运行时可选**：

- runner 只链接薄注册层 `fushi_wpe_loader.cc`（不依赖 WPE），注册时 dlopen 同目录的 `libflutter_inappwebview_linux_wpe.so`。实现库只在构建机有 WPE 开发包时产出；Ubuntu 24.04 官方源**没有** WPE；Debian trixie（WPE 2.48，FDO 后端）/ Fedora / Arch 有。
- 目标机缺 WPE、或不允许非特权 user namespace（WPE 的 bubblewrap 沙箱必需；Docker 默认、Ubuntu 24.04+ 的 AppArmor userns 限制都会触发）时，app 照常启动，WebView 位置显示原因（`LinuxWebViewRuntime` / `LinuxWebViewUnavailablePlaceholder`），headless 抛 `LinuxWebViewUnavailableException`。不做这层时 WebKit 会在第一次建 WebView（启动预热）时 `g_error` 中止整个进程。
- 资源投递走自定义 scheme（与 WKWebView 同路径，判据 `webViewUsesCustomSchemeTransport`）：WPE 没有能拦截 `https://` 的 `shouldInterceptRequest`。

运行时依赖（发行版包，打包时声明）：GTK 3、`libmpv2`（media_kit；音乐模块播放音频 CD 要它带 `cdda` 协议——发行版的 libmpv 编没编 libcdio 各不相同，用 `mpv --list-protocols | grep cdda` 核对，没有就换带 `-Dcdda=enabled` 的构建；另外发行版 mpv 没有 Fushi 的 `cdda-seek-sector-offset.patch`，seek 后会整段提前最多 587 个样本，见 `tool/bluray/forks/README.md`）、`libkeybinder-3.0`（全局快捷键）、`ffmpeg` / `ffprobe` 在 PATH（Linux 不随包 FFmpeg：播放器的发行版 `libmpv2` 与 PATH 上的 ffmpeg 本来就共用系统 FFmpeg，统一 FFmpeg 只覆盖随包的 Windows / macOS / Android / iOS）、`parecord`（录音，PulseAudio / PipeWire-pulse）、可选 WPE WebKit 2.x（Debian：`libwpewebkit-2.0-1 libwpebackend-fdo-1.0-1`；Fedora / Arch：`wpewebkit`；没装时阅读器 / 弹窗 / LNReader 小说源显示安装提示）、可选 Open JTalk（制卡词音频的最后兜底 TTS，能读汉字；Debian / Ubuntu：`open-jtalk open-jtalk-mecab-naist-jdic hts-voice-nitech-jp-atr503-m001`，非标准路径用 `FUSHI_OPEN_JTALK_DIC` / `FUSHI_OPEN_JTALK_VOICE` 指定）或 `espeak-ng`（只读纯假名）。

**单实例**：runner 以 `G_APPLICATION_HANDLES_COMMAND_LINE` 注册到会话 D-Bus（id `app.fushi.reader`），第二次启动（文件关联 / `fushi://` 深链 / 终端 `fushi <路径>`）把第一条非 flag 参数经 `app.fushi/external_video` 交给已开着的实例并前置窗口（`linux/runner/my_application.cc` + `external_open_handoff.cc`）；Dart 处理器注册前到达的参数在 runner 排队，Dart 发 `externalOpenReady` 后冲出，首帧前不前置窗口（BUG-3089）；首实例退出链开始时 Dart 发 `appExiting`，此后它对二次启动回退出码 75、不接管，二次启动方等名字让出后自己按首实例启动（BUG-3087，对应 Windows「窗口不可见 ⇔ 正在退出」）；`--fushi-restarted` 先等旧实例让出名字；设了 `FUSHI_TEST_HIDDEN` / `FUSHI_TEST_ROOT` 的测试实例不参与单实例；没有会话总线时 GLib 自动退化成多实例。系统关联本身靠打包时装的 `.desktop`（`Exec=fushi %u` + `MimeType=x-scheme-handler/fushi;…`），本仓不随带。

构建依赖（Debian trixie 一条龙）：`clang cmake ninja-build make pkg-config g++`（≥ 14，fushidicts 要 `std::expected`）、`libgtk-3-dev liblzma-dev libmpv-dev libsecret-1-dev libkeybinder-3.0-dev`，要 WebView 再加 `libwpewebkit-2.0-dev libwpebackend-fdo-1.0-dev libwpe-1.0-dev libepoxy-dev libwayland-dev`；要 app 外全局查词卡（`fushi_lookup_card`，独立进程，见 [Linux 全局查词卡](../specs/2026-11-05-linux-global-lookup-card.md)）再加 `libwebkit2gtk-4.1-dev libjson-glib-dev libx11-dev libxi-dev`，缺了只是不编这个 helper；`wayland-protocols`（≥ 1.39）让 runner 能读 Wayland 应用里选中的字，缺了只读 X11 PRIMARY；`libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev` 让 Steam Deck 游戏模式的截屏识字能读 Gamescope 的 PipeWire 画面，缺了游戏模式截屏直接报 `capture_failed`。Flutter（3.50.0）用 `CC=clang` 调 CMake，而 Debian 的 clang 配 libstdc++ 时 `std::expected` 不一定可用：在 PATH 前面放两个垫片脚本把 `clang` / `clang++` 指到 `gcc` / `g++`（≥ 14）再 `flutter build linux`。Mihon 运行时：`tool/mihon/build_desktop_runtime.sh bundle/mihon_bridge` 在 Linux 上出宿主架构的 `runtime/` + JAR。

本机没有 Linux：用 Docker Desktop（`debian:trixie` + 拷进 `/opt/flutter` 的 3.50.0 SDK）构建；源码以 `git ls-files -co --exclude-standard` 打包进 docker 卷再编，别直接 bind mount 工作区（`.dart_tool/package_config.json` 会被写成 Linux 路径）。跑 app / 集成测试用 `Xvfb :99` + `dbus-run-session`；容器里没有 user namespace，WebView 相关测试要设 `WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1`（**只限容器测试**）。

**一条命令出包（2026-11-03）**：`bash tool/linux/build_in_docker.sh [--skip-native] [--clean]`（Git Bash / Linux / macOS 宿主均可）按上面的做法在 `tool/linux/Dockerfile`（trixie + Flutter 3.50.0 + Rust 1.95.0 / 1.97.1 + protoc 31.1 + vcpkg）里跑 `tool/linux/build_bundle.sh`，产出 `build/linux-dist/fushi-<版本>-linux-x64.tar.gz`。与 app CMake 的 copy-if-present 不同，**出包时 p2p / fsrs / torrent 一律必需**，并补上 CMake 不管的 `fushi-anki-sync`、`mihon_bridge/`、`fushi_cli`；缺任何一件即失败。缓存放在 `fushi-linux-*` 命名卷里，`--skip-native` 跳过 p2p / torrent 与 bootstrap 的 Rust 重编；容器默认只用一半核心与 12 GB。产物要求 glibc ≥ 2.38（实测）。无头冒烟：`bash tool/linux/smoke_in_docker.sh [秒]` → `build/linux-dist/smoke/{run.log,screen.png}`。悬浮字幕 / 桌面歌词窗（`linux/runner/floating_lyric_window.cc`：X11 override-redirect 置顶窗；Wayland 有 layer-shell 时运行时 dlopen `libgtk-layer-shell.so.0` 走 overlay 层，没有时降级为不置顶、不记位置、拒绝穿透的普通窗）取证：`bash tool/linux/floating_lyric_itest_in_docker.sh` → `build/linux-dist/floating-lyric/{itest.log,ready.png,passthrough.png,xwininfo-*.txt}`。目标机运行库（Ubuntu 26.04 / WSL 实测缺的）：`libsecret-1-0 libsoup-3.0-0 libpulse0 libwayland-server0 libkeybinder-3.0-0 libmpv2 libgles2 libegl1 libgl1-mesa-dri`，外加 PATH 上的 `ffmpeg ffprobe parecord`（`pulseaudio-utils`）；可选 WPE：Debian 13 `libwpewebkit-2.0-1 libwpebackend-fdo-1.0-1 libwpe-1.0-1`、Fedora / Arch `wpewebkit`；查词卡 helper 要 `libwebkit2gtk-4.1-0 libjson-glib-1.0-0 libxi6`（GNOME 49 Flatpak 运行时自带）。**Ubuntu 26.04 的官方源没有 WPE WebKit**（实测 `apt-cache search wpe` 为空），Ubuntu 上阅读器 / 弹窗只显示安装提示——要覆盖 Ubuntu 只能随包 / Flatpak 带 WPE 或改用 WebKitGTK。

**Flatpak（官方 Linux 分发，2026-11-07）**：两层。`tool/linux/flatpak/baseapp/`（`app.fushi.reader.BaseApp`：WPE WebKit、mpv 等 GNOME 49 运行时缺的库，`-g0` 不带调试信息）只在它或 `tool/linux/flatpak/Dockerfile` 变了时重编（数小时）；`app.fushi.reader.yml` 以 `base:` 叠上 Linux bundle（几分钟）。构建脚本只有一份 `tool/linux/flatpak/flatpak_build.sh`（`baseapp` / `app` / `publish`），本机经 `build_flatpak.sh` 在特权 Docker 容器里跑，CI 直接调它。CI：`release-desktop.yml` 的 `flatpak-baseapp` job 经原生产物持久库（名字由 `native-store-names` 的 `flatpak` 平台算）取或编 BaseApp，`linux` job 编 bundle（`FUSHI_BUILD_NAME` / `FUSHI_BUILD_NUMBER` = 通道版本）并按通道提交到 Flatpak branch（debug / beta / stable），`publish` 先把签名的 OSTree 仓库部署到 GitHub Pages（`https://<owner>.github.io/<repo>/repo/`，可用变量 `FLATPAK_REPO_URL` 覆盖），再传 `fushi-<v>-linux-x86_64.flatpak` 资产与清单。应用内自更新（`fushi/lib/src/utils/misc/flatpak_updater.dart`）：版本检查照旧读 GitHub release，安装经 `org.freedesktop.portal.Flatpak` 的 `UpdateMonitor.Update`，重启用 `Spawn` + `LATEST_VERSION`；通道由已装 branch 决定。**一次性设置（2026-11-23 已完成）**：secret `FLATPAK_GPG_PRIVATE_KEY`（ed25519、无口令，指纹 `1A34855921FDA71009C65B9E7066DC128E09FF05`；私钥与公钥备份在维护者本机 `~/.fushi-secrets/`，不入库）；Pages 已开、Source = GitHub Actions。`deploy-pages` 部署时用 publish job 自己的环境（`release-auto` / `release-publish`），不需要 `github-pages` 环境。没有 key 时只出未签名 bundle、不发仓库也不传资产（2026-11-23 之前就是这样，Linux 包从未发出过）。**改 `finish-args` = 已装用户要手动更新一次**：portal 拒绝需要新权限的更新（应用内提示用 `flatpak update app.fushi.reader`）。最近一次：2026-11-23 为应用外查词抓整句加 `--talk-name=org.a11y.Bus` 与 `--filesystem=xdg-run/at-spi:ro`（拍板台 `design-linux-atspi-flatpak`，理由见 `docs/specs/2026-11-05-linux-global-lookup-card.md`），含这两条的第一版起已装用户要手动更新一次。portal 的真实错误名（`portal/flatpak-portal.c`）：新权限 = `org.freedesktop.DBus.Error.NotSupported` 且带 `n_ops`，用户在「更新 Fushi？」对话框点了拒绝 = `AccessDenied`（portal 会记住，之后每次都拒，应用内提示去系统隐私设置放开）。`publish` 镜像线上仓库时用同一把公钥校验每个提交的签名，**换 key 要先清空 Pages 上的旧仓库**，否则镜像校验失败、发布中止。

## Melos

仓库根是 Melos workspace（`fushi_workspace`）。常用：`melos run analyze` / `melos run test` / `melos run build:android`。

## 准备 + 构建

`tool/bootstrap.sh`（Windows：`.\tool\bootstrap.ps1`）一条命令完成：取回不入库的预编译二进制（见「vendored 二进制」）→ `flutter pub get` → `ci/apply-patches.sh`。`melos bootstrap` 经 post hook 做同样两步。然后：

> **代理**：`pub get` 只认继承来的 `HTTPS_PROXY`/`HTTP_PROXY`，而 agent 每次工具调用都是新 shell —— 上一条命令里设的代理不会留到下一条，这是「`setup_worktree.ps1` 首跑 socket error、带代理重跑就过」的根因。`bootstrap.ps1` 按 `调用方环境变量 > FUSHI_BOOTSTRAP_PROXY > <主 checkout>/tool/bootstrap.local.env`（gitignore，本机私有，一次配好所有 worktree 通用）取代理，三者都没有也照常直连跑（CI 不受影响），只是会先探一次 pub.dev 并在不通时把配法打在前面——**探测只示警不拦路**（实测单次探测会误报：探测 10s 超时失败的同一时刻，`pub get` 自带重试仍 45s 跑通），真判死刑交给 `pub get` 自己，失败时把同一份配法作为报错抛出。代理地址绝不写进入库脚本。

> **Flutter 与 bash 的定位**：`bootstrap.ps1` 按 `fushi/.fvmrc` 的版本号找 Flutter：`FUSHI_FLUTTER`（显式覆盖）> fvm 缓存（`FVM_CACHE_PATH` / `FVM_HOME` / `%LOCALAPPDATA%vm` / `~/fvm`）> 常见安装目录（各固定盘与家目录下的 `flutter_sdk/flutter_<版本>`、`flutter_<版本>`）> PATH 上**自报版本相符**的 flutter；都找不到就报错并列出查过的目录，**不回退到别的版本**。`ci/apply-patches.sh` 用 `git --exec-path` 推导出的 Git for Windows `bash.exe` 跑，不用 PATH 上的裸 `bash`（Windows 上常是 `System32ash.exe` 即 WSL）。

> **Windows 构建先决条件：Visual Studio 的「C++ ATL」组件**（2026-09-09，v101 统一
> 更新提醒引入 `flutter_local_notifications` 之后成为硬要求）。它的 Windows 实现
> `flutter_local_notifications_windows` 直接 `#include <atlbase.h>`，装了 VS 的
> 「使用 C++ 的桌面开发」但没勾 ATL 的机器会在
> `plugin.cpp(5,10): error C1083: Cannot open include file: 'atlbase.h'` 停住——
> 判据是 `<VS>\VC\Tools\MSVC\<ver>\` 下**没有 `atlmfc` 目录**。
> 修法：VS Installer → 修改 → 单个组件 → 勾「适用于最新 v143 生成工具的 C++ ATL
> (x86 和 x64)」。**CI 不受影响**：GitHub 的 `windows-2022` image 自带该组件。

```bash
cd fushi
flutter build apk --release --target-platform android-arm64 --split-per-abi
```

### 新 worktree 第一次 flutter test（2026-11-20）

`tool/setup_worktree.ps1` 在 bootstrap 之后跑 `fushi/tool/worktree_seed.dart` 的两步，都只影响速度，不影响结果；失败时打黄字、退出码原样报出，worktree 照常可用。

- **以前那条「从兄弟 worktree 拷 `fushi/build/test_cache` 的 dill」预热已删除**：它从来没起作用。`test/flutter_test_config.dart` import 了 `package:fushi`，所以任何 fushi 测试编出的 dill 都带源 worktree 绝对路径下的 fushi/lib、packages/*、third_party/*。front_end（Dart 3.13.5 `incremental_compiler.dart` 的 `_initializeFromDill`）发现某个 `package:` 库的路径和本 worktree 的 package_config 对不上，就抛 `PackageChangedError`，被静默吞掉，然后**丢掉整份 dill 冷编**。旧注释里「只重编路径不同的库、复用 SDK 与 pub 部分」的说法是错的；每个 worktree 白拷约 680 MB，首编反而更慢（实测 86 s，冷编 72 s）。
- **hook 下载产物**（`worktree_seed.dart hooks`）：pdfium_dart 0.2.5 和 sqlite3 3.5.2 的 build hook 原来在每个新 worktree 都从 GitHub 重下一遍（pdfium 约 17 s）。现在从全机缓存 `%LOCALAPPDATA%/fushi-heavy/hook-downloads/` 或兄弟 worktree 拷 `.dart_tool/hooks_runner/shared/` 下按内容寻址的文件：`sqlite3/build/download-*/` 和 `pdfium_dart/build/chromium_*/<平台>/`。只拷大于 0 字节、2 分钟内没再写过的文件，先写临时名再改名。input.json、hook.dill、依赖哈希这些写死了绝对路径的东西不拷。拷之前要校验内容：sqlite3 按目录名里的 sha256 前缀校验（它的 hook 自己还会再验一遍全量哈希）。pdfium 的 hook 只看文件存不存在，还是非原子写入，截断的库会一直到加载时才报错，所以**只拷 sha256 与钉值相符的文件**。钉值表在 `fushi/tool/worktree_seed/hook_downloads.dart`，覆盖 chromium_7811 的 13 个平台：先从上游 bblanchon/pdfium-binaries 下发布包，核对 GitHub 列出的 digest，再对包里的库算哈希；本机已有的 4 个平台（win-x64、android-arm/arm64/x64）文件与钉值一致。**pdfium_dart 升级、换了 chromium 版本号之后，钉值表要按同样的方法补**，否则 pdfium 不再复用（只是变慢，不会出错）。
- **第三方库编译 seed**（`worktree_seed.dart kernel`）：全机缓存放在 `%LOCALAPPDATA%/fushi-heavy/test-seed/<key>/`，key 由 Flutter SDK 路径、framework / engine / Dart 版本、`pubspec.lock` 的 sha256、`fushi/pubspec.yaml` 的 version 算出，保留最近 4 个。缓存里有 seed 就**拷贝**（不能用硬链接：flutter test 会原地写回这个文件）成 `fushi/build/test_cache/build/<md5>.cache.dill.track.dill`；worktree 里已经有自己的编译缓存时不动。缓存里没有，就在当前 worktree 生成一份：
  - 生成一个入口，只 import worktree 代码用到的第三方 `package:` 库。仓内包要排除，**依赖仓内包的第三方包也要排除**，例如 marquee 依赖仓内覆盖的 `third_party/fading_edge_scrollview`，带上它 dill 里就会混进 worktree 路径。
  - 入口放在 `fushi/build/test_seed/`，那里没有 `flutter_test_config.dart`，flutter_tools 找配置找到包根就停。
  - 经 `tool/heavy.dart` 用真实的 `flutter test` 编一次。编译参数就是 flutter_tools 自己的，不用手工复刻 frontend_server 参数。
  - 校验 dill 里除入口和 `.dart_tool/` 外不含任何 worktree 路径，才存进缓存；生成期间加 `<key>.lock` 锁防并发。

  正确性由 frontend_server 兜底：它会把 dill 里每个源文件和磁盘逐字节比对，变了的就重编，所以 seed 过期或不全只会慢、不会错。不想做这一步时加 `-SkipTestSeed`。
- **实测**（2026-11-20，本机，同时有别的会话在跑测试，每格只测一两次，绝对秒数有噪声）。单条只 import flutter_test 的测试，新 worktree 第一次 `heavy flutter test -v`：

  | setup 做了什么 | hooks | Compile | heavy 记的 ran |
  |---|---|---|---|
  | 旧版（拷兄弟 dill） | 21.7 s | 81.0 s | 112 s |
  | 只删掉旧预热（冷编） | 23.0 s | 49.2 s | 79 s |
  | 现在（hook 产物 + seed，缓存命中） | 2.6 s | 35.4 s | 46 s |

  只比编译（同一个 worktree 清掉 test_cache 后重跑，hooks 已经是热的）：两个 worktree 各测一轮（第二轮顺序反过来）。只 import flutter_test 的测试：无 seed 43.6 s，有 seed 30.0 s / 29.5 s。import `package:fushi` 的组件测试 `test/widgets/fushi_card_focus_test.dart`：无 seed 42.6 s / 50.2 s，有 seed 30.0 s / 34.4 s。测试全部通过。缓存没命中时，setup 生成一次 seed 约 20～30 s（每个 key 全机只付一次），同时也把 hooks 和 unit_test_assets 跑掉了。
- **没做 / 剩下的**：
  - 剩下约 30 s 编的是 worktree 自己的代码（fushi/lib 约 2700 个库加 packages/*），front_end 按绝对路径认库，这部分跨 worktree 复用不了。要消掉得让 file URI 与 worktree 路径无关（multi-root scheme，要改 flutter_tools），没验证可行性。
  - unit_test_assets 和 impellerc 那 5～11 s 按 mtime 判断新旧，不能跨 worktree 复用。
  - seed 只服务 `fushi/` 的 flutter test，`packages/*` 各自的 `build/test_cache` 没有 seed。

### TODO-207 release channel invariants

客户端按 stable / beta / debug 三个通道过滤 GitHub Release。stable 只看正式 Latest；beta/debug 扫描最近 releases，但只接受 tag 形如 `v<version>-beta.<seq>` / `v<version>-debug.<seq>+<short-sha>` 且 `prerelease=true` 的 release。旧的 `debug-<sha>` tag 不可比较，客户端会忽略。

**数据库 schema 闸（2026-11-16）**：更新清单每个 asset 带 `dbSchemaVersion`（`tool/publish_update_manifest.sh` 从 `packages/fushi_core/lib/src/database/db_schema_version.dart` 的 `kFushiDbSchemaVersion` 抠出，`merge_update_manifest.py` 原样保留）。客户端选包时比本机 schema 低的 asset 一律跳过，不管发布序号 / 基版本怎么判——装上就是「库比程序新」、app 拒绝打开。所以调试版用户永远不会被推回 schema 更旧的正式版。schema 版本号只在那个常量里改；改写法要同步脚本里的 sed 正则（守卫 `fushi/test/utils/misc/update_checker_db_schema_guard_test.dart`）。

debug 通道发布的是 release-signed debug-channel APK：文件名保留 `-debug.apk` 供客户端过滤，APK 使用 release keystore、写入 `versionName=<version>-debug.<seq>` 和单调 `versionCode`（公式见下「版本号与 build number」），用于覆盖正式签名包并让同一平台后续 debug/beta/formal release 仍可比较。debug push 仍必须是 prerelease / non-Latest，绝不能创建或更新 formal / Latest。

**滚动 debug release（TODO-1049）**：debug 通道**不再**每次 push 新建一个 `v<version>-debug.<seq>+<short-sha>` GitHub Release——否则 debug 高频构建会在 Releases 列表无限堆积、淹没正式/beta 条目（用户明确诉求：调试版不该占 Release 位）。改为所有 debug 构建复用**同一个固定滚动 tag `debug-rolling`**（`steps.channel.outputs.publish_tag`），列表里 debug 永远只有 1 条。关键不变式：GitHub Release 的 git tag（`publish_tag=debug-rolling`）与「客户端版本比较用的版本化 tag」（`steps.channel.outputs.tag = v<version>-debug.<seq>+<short-sha>`）**解耦**——manifest `latest-debug.json` 的 `tag` 字段仍写版本化 tag（客户端据 `<seq>` 单调判断「有无更新」，逻辑零改动），而资产下载 URL 走 `releases/download/debug-rolling/<name>`（`publish_update_manifest.sh` 的 `DOWNLOAD_TAG`）。softprops 只 upsert 同名 asset、不删旧 commit 的 asset，故发布前有一步按当前 `versionName` token 清理滚动 release 上非本 seq 的陈旧资产（同 commit 的 Android+desktop 共享 seq、互不误删；新 commit 清旧 commit）。`release.yml` 里另有一步 GC 掉历史遗留的版本化 debug prerelease（tag 形如 `v...-debug.<seq>+`，不含滚动 tag），把列表收敛到单条。beta/formal 不受影响：其 release 就是版本化 tag 本身，`publish_tag == tag`。

**滚动 debug release 置顶（拍板台 RRYro9vSEU，2026-11-24）**：GitHub Releases 列表按 release 的 `created_at` 排，而它等于 **tag 所指提交的日期**（现算，不是建 release 的时间）。滚动 tag 原来一直指着 2026-08-10 的提交，调试版沉在第 40 条左右。两条发布 workflow 在 softprops 发布之后都跑 `tool/bump_rolling_release_tag.sh`：新造一个提交（tree 与父 = 默认分支尖端，日期为现在，提交信息带构建 sha），force 更新滚动 tag 指过去。只挪 tag、不删重建 release：release id、资产、`releases/download/<rolling tag>/<name>` 链接、更新清单全不动，没有窗口期，也不会删掉另一条 workflow 并行传的资产。不指向 develop 提交，是为了避开 GITHUB_TOKEN「目标提交相对默认分支改了 workflows」的限制。失败只 `::warning`（资产已发完），下一次发布自愈。守卫：`fushi/test/tools/bump_rolling_release_tag_script_test.dart`。

Android / Windows / macOS / iOS debug/beta workflow 必须使用跨 workflow 统一 release 序列（cross-workflow release sequence）：发布 workflow 都用完整历史 checkout 后的 `git rev-list --count HEAD` 生成 `<seq>`，不得用各自独立的 `github.run_number` / `GITHUB_RUN_NUMBER` 生成 tag、安装包版本或 Android `versionCode` 扩展位。Android `versionCode = versionCodeBase(1_000_000_000) + 100 × <seq> + abiOffset`（公式在 `fushi/android/app/build.gradle`，CI 只把 `<seq>` 当 `--build-number` 传入），不再用旧的 `PUBSPEC_BUILD × 1_000_000 + seq` build number——那个数会把 versionCode 顶到约 66 亿，溢出 int32 且超 Android 21 亿上限，beta/release 的 Android 包根本建不出来（TODO-414）。同一 commit / 同一语义版本的自动 debug 默认 tag 必须相同，合并到同一个 GitHub Release（single GitHub Release）。两条 workflow 的 concurrency 组**各自独立**（组名 = `fushi-release-<workflow 名>-<tag|sha>`；**push 事件按分支**：`fushi-release-<workflow 名>-<refs/heads/…>`，2026-09-30 起——同分支的 push 发布串行、正在跑的那轮跑完、排队中的旧 pending 被后来者顶掉，仍 `cancel-in-progress: false`，跳过的 commit 无害因为 debug 序号 = commit 数）：同一条 workflow 同 tag/sha 串行，两条 workflow 之间并行上传同一个 Release——GitHub 的 concurrency 组是仓库级的，2026-09-08 之前两条同名组，正式版 `release: published` 同时点燃两条时桌面/Apple 必须等 Android 整条跑完，且同组第二个 pending 会把第一个 pending 取消（2026-09-03 实测 cancelled + 0 job）。并行安全性依赖三处既有设计：rolling prune 只删本平台资产（TODO-1131）、softprops 建 release 撞车重取、`publish_update_manifest.sh` 的重取合并循环（TODO-781）；守卫 `fushi/test/build/release_workflow_concurrency_guard_test.dart`。客户端自装平台必须先按本平台 asset 过滤 release：Android 只接受匹配通道的 APK，Windows 只接受匹配通道的 `-windows-setup.exe`，macOS 只接受 `-macos-arm64.zip`（也认改名前的 `-macos.zip`）；如果远端只有错平台新版本，Android/Windows/macOS 返回无更新而不是打开 release 页。iOS 发布 no-codesign `.ipa` 只作为 GitHub 下载产物，不做应用内自动安装。Unsupported 平台仍可在没有本平台自装 asset 时打开 release 页。若手动 Android / desktop/Apple workflow 指定 `tag_name`，也应使用同一个 tag 合并到同一个 Release，由各平台客户端选择自己的 asset。

> Google Drive 同步的 OAuth 凭据已写死进源码默认值（`lib/src/sync/google_drive_auth.dart`），构建无需再传 `--dart-define`。如需换凭据，改该文件的 `defaultValue` 或自行加 `--dart-define` 覆盖。

## 无头服务端 fushi_server（Linux CLI + WebUI）

- 源码 `packages/fushi_server/`（纯 Dart，依赖 `packages/fushi_engine`）；本机构建 `cd packages/fushi_server && dart build cli`，产物 `build/cli/<os>_<arch>/bundle/`（`bin/` 可执行 + `lib/` native asset）。**不要 `dart compile exe`**：sqlite3 是 native asset，单文件 exe 运行时打不开 DB。
- CI：`build-multiplatform.yml` 的 `linux-server` job（PR 上只覆盖服务端；Linux App 在 `release-desktop.yml` 出包，见上「Linux 桌面」；PR 上按下文「PR 平台 job 的路径门」在服务端的 Dart 依赖闭包或它随包的原生库变动时才开）跑 `dart build cli`，再把两块随包原生库放进 `bundle/lib/`（fushi_p2p 与 fushi-anki-sync 同理随包，见下两节）：① `libfushi_torrent_ffi.so`（`native/fushi_torrent/build_linux_so.sh`：vcpkg manifest **静态链** libtorrent 2.0.11 + boost + openssl，overlay triplet `x64-linux-fpic`，ABI 校验同 `native-torrent-gate.yml`；目标机零运行库依赖）② `libonnxruntime.so` 1.22.0 CPU 版（与 `third_party/flutter_onnxruntime/linux` 同版本；CUDA 用户自换 GPU 包并配 `onnxruntime_library`）。随后用这份 `.so` 跑 `packages/fushi_torrent` 的 FFI 测试，再真进程冒烟：起 `serve`，断言 admin API 报 `backend=embedded` 且 17 语 ASR plan 无 error（= 两块库都真被 dlopen 了）。工件名 `fushi_server-linux-x64`。
- 服务端找随包库的规则在 `packages/fushi_server/lib/src/native_libs.dart`：`<exe 同级>` → `<exe>/../lib/` → cwd；都没有就交给引擎按裸名走系统搜索路径。
- 发布：Release **落在独立仓 [hajisensai/fushi-server](https://github.com/hajisensai/fushi-server)，不落本仓**（2026-09-14 起）。那边只有 README / LICENSE / 一条薄 workflow `release.yml`（`schedule` 每 30 分钟以 `channel: auto` 调一次，另有 `workflow_dispatch` 可手动指定 channel = debug / beta / formal / auto 与 source_ref），它 `uses: hajisensai/Fushi/.github/workflows/release-server.yml@develop` 调本仓的**可复用 workflow**（`workflow_call`）：Linux（`ubuntu-22.04`，静态 `.so`）+ Windows（vcpkg DLL）两个包，各自真进程冒烟后由 publish job 用调用方的 `GITHUB_TOKEN` 发到 fushi-server 的 GitHub Release，tag `v<version>-beta.<seq>` / `v<version>` / 滚动的 `debug-rolling`（body 记 `source-sha: <sha>`）；release 发出后 docker job 用同一份 Linux 包打 `ghcr.io/hajisensai/fushi-server` 镜像、冒烟后推送（正式版 `latest` / `x.y.z` / `x.y` / `x`，测试版 `beta` / `x.y.z-beta.<seq>`，调试版 `debug` / `debug-<seq>`）。**三通道自动跟 app（2026-11-24 用户拍板）**：跨仓事件要 PAT，所以由 fushi-server 定时轮询，`tool/server_release_plan.py`（测试 `tool/server_release_plan_test.py`，ci-config-gate 跑）每轮按「app 的 `releases/latest` → app 最新 `-beta.<seq>` → develop 新提交（只动 docs / app 自身文件的跳过）」挑一个 fushi-server 还没有的目标；同一目标在最近 10 次失败 run 里失败满 2 次就跳过并告警（job 名带 `[target:<key>]`），修好后手动 dispatch。提交不含 `SERVER_BUILD_FLOOR`（脚本常量，现为 #3400 合入点 `283a92028615`：Flutter 3.50 钉点 + 服务端打包脚本）的 app release 直接不当候选（如 v3.3.0，源码根本构建不出服务端包）；workflow 的构建契约不再兼容旧源码时，同一提交里抬高这个下限。源码 checkout 显式钉 `repository: hajisensai/Fushi`（公开仓，**零 PAT / 零 secret**）。版本与 app 一致，取 `fushi/pubspec.yaml` 的 `version:`（2026-11-24 起；`packages/fushi_server/pubspec.yaml` 的 version 只是包版本），序号仍是 `tool/release_sequence.sh`（在 hibiki checkout 上算）。服务端远程自更新按 `release.json` 的 channel 选源：formal 只看 `releases/latest`，beta 看 beta + formal、不收 `debug-rolling`，debug 三者都收。**本仓自己不能发服务端包**：channel job 断言 `github.repository != hajisensai/Fushi` 直接红——app 稳定通道更新检查走本仓 `releases/latest`，服务端包在本仓成为 Latest 会把五端 app 的更新判成「远端不比本机新」而停更；搬到独立仓后 formal 就是正常的 Latest。`tool/check_release_policy.ps1` 锁：只有 `workflow_call`、有这条断言、每个 checkout 都钉源仓、版本取 app 的、auto 走 plan 脚本、docker job 在 publish 之后。手动发包：`gh workflow run release.yml -R hajisensai/fushi-server -f channel=beta -f source_ref=develop`。没有安装包。安装、systemd、配置、admin API、上传协议见 [packages/fushi_server/README.md](../../packages/fushi_server/README.md)。

## 互联 P2P 隧道原生库 fushi_p2p（Rust / iroh）

- 源码 `native/fushi_p2p/`（Rust crate，C ABI）+ 纯 Dart FFI 包 `packages/fushi_p2p/`。每端一个构建脚本，产物落 `native/fushi_p2p/prebuilt/<平台>/`（不入库）：`build_windows_dll.ps1` / `build_android_so.{ps1,sh}` / `build_linux_so.sh` / `build_macos_dylib.sh`（只出 arm64）/ `build_ios_staticlib.sh`（staticlib + xcconfig 片段）。
- **五端都是「prebuilt 有则随包」**：Windows / Linux CMake、Android `jniLibs.srcDirs`、macOS Runner 构建阶段 `fushi/macos/bundle_fushi_p2p.sh`、iOS 链的是伞形静态库 `native/fushi_ios_umbrella`（fushi_p2p + fushi_fsrs + fushi_compute 合一、Rust std 只有一份；多份单独 .a 同时 `-force_load` 会撞重复 std 符号），经 `fushi/ios/Flutter/*.xcconfig` 可选 `#include?` 它生成的 xcconfig 给 `OTHER_LDFLAGS` 加 `$(FUSHI_IOS_NATIVE_LDFLAGS)`（`-force_load` 静态库，Dart 侧 `DynamicLibrary.process()`）。没装 Rust 的机器照常出包，P2P 能力判不可用——与内置 libtorrent 不同，Windows CMake **故意不在 Release 强制**，因为缺库只隐藏能力、不会「宣称有后端却打不开」。
- **发布包的保证在 CI**：`release.yml`（Android arm64-v8a / armeabi-v7a / x86_64）、`release-desktop.yml`（Windows / macOS arm64 / iOS device）、`release-server.yml`（Linux / Windows）都在出包前跑 Rust 构建，**失败即 job 失败**（与 libtorrent 同口径），出包后再核对库真的进了包（APK 每个带 `libflutter.so` 的 ABI、Windows bundle、macOS Frameworks 里的 dylib 恰好是 arm64、iOS Runner 导出 `fp2p_*`、服务端拿 bundle 里那份跑真隧道测试）。PR 上 `build-multiplatform.yml` 覆盖 Windows / macOS / iOS 三个 app 端与 Linux 服务端 bundle（`linux-server`；Linux、Windows 还跑 `packages/fushi_p2p` 真隧道测试；改到 `native/fushi_p2p/**` 或 `packages/fushi_p2p/**` 时路径门四个 job 全开），`native-p2p-gate.yml` 补 Android 三 ABI 交叉编译。Rust 钉 1.95.0，cargo-ndk 钉 4.1.2。
- 真隧道测试在库加载失败时**整组 skip 且退出码 0**，CI 因此额外断言日志里没有 skip 原因；`native/fushi_p2p/verify_abi.sh` 按 Dart 绑定 lookup 的 `fp2p_*` 名核对导出表。细节见 [native/fushi_p2p/README.md](../../native/fushi_p2p/README.md)。

## SRS 排程内核原生库 fushi_fsrs（Rust / fsrs-rs）

- 源码 `native/fushi_fsrs/`（Rust crate，C ABI）+ 纯 Dart FFI 在 `packages/fushi_srs/lib/src/ffi/`。构建脚本与 fushi_p2p 同形：`build_windows_dll.ps1` / `build_android_so.{ps1,sh}` / `build_linux_so.sh` / `build_macos_dylib.sh`（只出 arm64），产物落 `native/fushi_fsrs/prebuilt/<平台>/`（不入库）。
- **随包语义与 fushi_p2p 相同（copy-if-present）**：Windows / Linux CMake、Android `jniLibs.srcDirs`、macOS Runner 构建阶段 `fushi/macos/bundle_fushi_fsrs.sh`；缺库 = SRS 原生内核判不可用，不是构建失败。
- **iOS 暂未随包**：两份 Rust staticlib 同时 `-force_load` 会撞重复的 Rust std 符号，iOS 要改链伞形库 `native/fushi_ios_umbrella/`（`fp2p_*` + `ffsrs_*` 合一），Runner 尚未切换（步骤见 [native/fushi_fsrs/README.md](../../native/fushi_fsrs/README.md)「iOS」）；PR 上 `build-multiplatform.yml` 的 ios job 只核对伞形库能编过。
- **发布包的保证在 CI**（同 fushi_p2p 口径）：`release.yml`（Android 三 ABI）、`release-desktop.yml`（Windows / macOS arm64）、`release-server.yml`（Linux / Windows）出包前跑 Rust 构建，**失败即 job 失败**，出包后核对库进了包（APK 每个带 `libflutter.so` 的 ABI 都有 `libfushi_fsrs.so`、Windows bundle 有 `fushi_fsrs.dll`、macOS Frameworks 里的 dylib 恰好是 arm64 且导出 `ffsrs_*`）。fushi_fsrs **不进原生产物持久库**（冷编便宜），只靠 `Swatinem/rust-cache`；Rust / cargo-ndk 版本读 `native-store-names` 的 `p2p_rust` / `cargo_ndk`，与 fushi_p2p 同源。PR 上 `build-multiplatform.yml` 覆盖 Windows / macOS / iOS（伞形库）/ `linux-server`，`native-fsrs-gate.yml` 补 Android 三 ABI 与 `cargo test`。

## 计算内核原生库 fushi_compute（Rust：哈希 / 图像 / 文本）—— **硬依赖**

- 源码 `native/fushi_compute/`（Rust crate，C ABI `ffc_*`，`opt-level = 3`）+ 纯 Dart FFI 包 `packages/fushi_compute/`（各域绑定在 `lib/src/<域>/`）。构建脚本与 fushi_fsrs 同形：`build_windows_dll.ps1` / `build_android_so.{ps1,sh}` / `build_linux_so.sh` / `build_macos_dylib.sh`（只出 arm64，部署目标 13.4）；iOS 不单独出件，只进伞形库。产物落 `native/fushi_compute/prebuilt/<平台>/`（不入库）。`verify_abi.sh` 的期望符号集**递归**取自 `packages/fushi_compute/lib/` 下所有 `'ffc_*'` 字面量，新增域自动跟上。
- **与 fushi_p2p / fushi_fsrs 相反：缺库 = 构建失败**（所有者拍板：不维护 Dart 与 Rust 两份实现，没有 Dart 回退）。Windows / Linux CMake 配置期 `FATAL_ERROR`；macOS Runner 构建阶段 `fushi/macos/bundle_fushi_compute.sh` `exit 1`；iOS Runner 在编译前跑 `fushi/ios/check_fushi_compute.sh`（伞形库缺失、`FUSHI_IOS_NATIVE_LDFLAGS` 为空或 `.a` 不导出 `ffc_abi_version` 都失败——注意这让 iOS 构建从此必须先编伞形库，fushi_p2p / fushi_fsrs 也随之一起到位）；Android `checkFushiComputeNative`（挂 `preBuild`）按 Flutter 传的 `target-platform` 逐 ABI 查 `libfushi_compute.so`；无头服务端 bundle 由 `release-server.yml` 硬拷贝。守卫 `fushi/test/build/fushi_compute_hard_dependency_guard_test.dart`。
- **本地前提**：要装 Rust（cargo）。`tool/setup_worktree.ps1` → `tool/bootstrap.ps1` 在 pub get 之后按主机平台编一次（Windows `build_windows_dll.ps1`，Linux / macOS 对应 sh；`tool/bootstrap.sh` 同理），没有 cargo 直接报错失败；显式跳过用 `-SkipNativeCompute` / `FUSHI_BOOTSTRAP_SKIP_NATIVE_COMPUTE=1`。编 Android 包另需 NDK + `cargo install cargo-ndk`，先跑 `build_android_so.ps1 -Abis <要出的 ABI>`。`flutter test` / `dart test` 由 `FUSHI_COMPUTE_LIB`（绝对路径）或加载器在测试宿主下向上找 `native/fushi_compute/prebuilt/<平台>/` 定位。
- **CI**：跑 Dart / Flutter 测试的 job（`main.yml` build + unit-tests、`release.yml` tests、`server-gate.yml`、`golden-tests.yml`、`build-multiplatform.yml` android）一律经 composite action `.github/actions/setup-fushi-compute` 先编宿主平台库并导出 `FUSHI_COMPUTE_LIB`（需要 APK 的 job 再按 ABI 交叉编；工具链读 `native-store-names/names.sh` 的 `P2P_RUST` / `CARGO_NDK`；为省缓存配额不挂 rust-cache）。出包 job（`release.yml` Android 三 ABI、`release-desktop.yml` Windows / macOS / iOS、`release-server.yml` Linux / Windows、`build-multiplatform.yml` 四端）各自带 rust-cache 构建，失败即 job 失败，出包后硬核对（APK 每个 ABI、Windows bundle、macOS Frameworks 的 install name / arm64 / 符号 / ctypes 调 `ffc_abi_version` == 1、iOS Runner 导出 `ffc_*`），Windows 与 Linux 服务端再拿真库跑 `packages/fushi_compute` 整个 test 目录并断言没有 `native library not found`。PR 上 `native-compute-gate.yml` 补 Android 三 ABI 与 `cargo test --release --locked`。

## RWKV-Instant 排程推理原生库 fushi_rwkv（Rust，AGPL-3.0-or-later）—— **硬依赖**

- 源码 `native/fushi_rwkv/`（C ABI `frwkv_*`，`opt-level = 3` + LTO，`panic = "unwind"`）+ Dart FFI 包 `packages/fushi_rwkv/`（`FushiRwkv.load`，环境变量 `FUSHI_RWKV_LIB`）。接线**逐项照抄 fushi_compute**：同名构建脚本 `build_windows_dll.ps1` / `build_android_so.{ps1,sh}` / `build_linux_so.sh` / `build_macos_dylib.sh`（arm64，部署目标 13.4，`/usr/bin/strip -x` + dlopen 冒烟），产物落 `native/fushi_rwkv/prebuilt/<平台>/`；iOS 只进伞形库 `native/fushi_ios_umbrella`（`IOS_NATIVE` 持久库件名随之带上 `native/fushi_rwkv`）。`verify_abi.sh` 的期望集 = `src/` 里全部 `extern "C" fn frwkv_*` ∪ `packages/fushi_rwkv/lib/` 下的 `'frwkv_*'` 字面量，新增导出自动跟上；也认 Windows PE（取 `llvm-nm` 同目录的 `llvm-readobj` 读导出表）。
- 缺库 = 构建失败：Windows / Linux CMake `FATAL_ERROR`（`FUSHI_RWKV_DLL` / `FUSHI_RWKV_SO`）、macOS `fushi/macos/bundle_fushi_rwkv.sh` `exit 1`、iOS 编译前 `fushi/ios/check_fushi_rwkv.sh`（伞形库不导出 `frwkv_abi_version` 即失败）、Android `checkFushiRwkvNative`（挂 `preBuild`）。本地 `tool/bootstrap.ps1` / `bootstrap.sh` 紧接 fushi_compute 编它，`-SkipNativeCompute` 两个一起跳过。守卫 `fushi/test/build/fushi_rwkv_hard_dependency_guard_test.dart`。
- **CI**：凡用 `setup-fushi-compute` 的 job 紧跟着用 `.github/actions/setup-fushi-rwkv`（同样的 `android-abis`，导出 `FUSHI_RWKV_LIB`）；出包 job 与 fushi_compute 同处各带 rust-cache 构建并出包后核对（APK 每个 ABI、Windows bundle、macOS Frameworks、iOS Runner 导出 `frwkv_*`、服务端 Linux / Windows bundle），dlopen 冒烟比对的 ABI 版本从 `src/lib.rs` 的 `ABI_VERSION` 读、不写死。PR 上 `native-rwkv-gate.yml` 跑三种 CPU 内核的 `cargo test --release`（权重与小模型包按 `fetch_model.sh` 钉的两个 SHA-256 缓存）+ Android 三 ABI 真编与符号核对。
- **许可**：fushi_rwkv 是 AGPL-3.0-or-later（推理核心搬自 kuma3-anki-core，所有者 2026-10-19 拍板接受，见 `native/fushi_rwkv/UPSTREAM.md`）。动态加载它的四端 app 与静态链它的 iOS 伞形库 / Runner 都随之受 AGPL 约束（GPL-3.0 第 13 条允许与 AGPL-3.0 合并分发）。

## Windows 资源管理器封面缩略图 fushi_shell_thumbs（Rust，只随安装包）

- 源码 `native/fushi_shell_thumbs/`（拍板台 WoAtPpuvwm）：资源管理器里 epub / cbz / cbr / cb7 / pdf 显示封面。两个产物：`fushi_shell_thumbs.dll`（COM 进程内服务器，`IInitializeWithFile` + `IThumbnailProvider`）和 `fushi_shell_thumbs_host.exe`（每张缩略图一次性的宿主进程）。设计与边界见该目录 `README.md`。
- **不是 app 进程的依赖**：不进 CMake bundle、不进 `tool/native_libs.ps1`；只由 `release-desktop.yml` 的「Build and bundle fushi_shell_thumbs」步（`build_windows_dll.ps1 -InstallDirectory <Release>`，签名之前）放进 Release 目录，`fushi.iss` 的 `bookassoc` 任务按用户（`HKCU64`）注册。
- **为什么进程内 + 自己的宿主进程**：系统缩略图隔离进程（COM Surrogate）激活不到 HKCU 注册的 CLSID（2026-11-16 实测 `REGDB_E_CLASSNOTREG`），本安装器又是 `PrivilegesRequired=lowest`，所以 `DisableProcessIsolation=1`。explorer 里的 DLL 不解析文件，只把路径交给宿主进程（job 对象限 1 GiB、15 秒超时、普通优先级——低优先级在满载机器上会被饿到超时），宿主用 `{app}\7za\7z.dll`（rar / 7z）和 `{app}\pdfium.dll`（pdf）。升级时被 explorer 占着的旧 DLL 由 `[Code] FushiSetAsideThumbnailHandler` 改名挪开。
- 本地：`cargo test --profile quick`（端到端测试要 `FUSHI_TEST_7Z_DIR` / `FUSHI_TEST_PDFIUM_DLL`，没给就 SKIP 那几条）；`examples/probe.rs` 对真实文件出 PNG。PR 上 `native-shell-thumbs-gate.yml` 用钉死 SHA-256 的真 7z.dll / pdfium.dll 跑 `cargo test --release --locked`（`FUSHI_THUMBS_REQUIRE_DEPS=1`，缺依赖判红）。

## Android JVM 单测（`fushi/android/app/src/test`）

- CI：`main.yml` 的 `build` job 在 PR 改到 Android / 原生 / 插件 / pubspec（与 R8 校验同一个路径门）时跑
  `./gradlew :app:testDebugUnitTest`，红就判红；守卫 `fushi/test/build/android_jvm_unit_tests_ci_guard_test.dart`。
- **新 worktree 里直接能跑（2026-11-20）**：gradle wrapper（`fushi/android/gradlew`、`gradlew.bat`、
  `gradle/wrapper/gradle-wrapper.jar`，取自 Flutter 的 `bin/cache/artifacts/gradle_wrapper`，3.47.6 与 3.50.0 是同一份）入库，不再靠
  `flutter build apk` 现生成；`checkFushi{Compute,Rwkv,Music,Corpus}Native` 从 `preBuild` 挪到
  `merge<Variant>JniLibFolders`（把 .so 收进包的任务），所以 JVM 单测与纯编译任务不要求本机有 Android 预编译
  `.so`，出 APK / AAB 的任务缺库照旧失败。守卫 `fushi/test/build/android_gradle_runs_in_fresh_checkout_guard_test.dart`
  与四个 `fushi_*_hard_dependency_guard_test.dart`。起因与数据见 [heavy-lease.md](heavy-lease.md)。
- **出包任务先让 Android `.so` 对上源码（2026-11-20；2026-11-21 补上 `fushi_web_core`、改成每次都核对）**：五个 check（`checkFushiWebCoreNative` 只挂 Release 的 `merge*JniLibFolders`）之前先跑 `ensureFushiAndroidNative`，在
  Windows 上**每次**都调 `tool/native_libs.ps1 -Android -Abis <本次要出的 ABI>`（check 只看文件在不在，只在缺库时才备会把源码已变的旧 `.so` 静默打进包）：本地戳记 → 本机缓存
  `%LOCALAPPDATA%\fushi-native-cache`（`FUSHI_NATIVE_CACHE` 可改，每个产物留最近 4 棵源码树）→ 兄弟 worktree →
  `build_android_so.ps1` 现编（要 cargo-ndk 与 NDK 28.2.13676358），编完进缓存。同一份 `native/<crate>` 源码一台机器
  只编一次，之后每个新 worktree 是拷贝。也可以手动先跑那条命令。库已齐（CI 出包前自己编）时不做任何事；
  `native/<crate>` 有未提交改动时按工作区源码编、不进缓存；非 Windows 主机不代劳，check 照旧报错说明怎么编。
  只管「缺」不管「旧」：库在但源码之后改过时不会自动重编，手动跑 `tool/native_libs.ps1 -Android` 会按戳记重编。
- 本地定向跑（先在 `fushi/` 下 `flutter pub get` 生成插件注册与 `local.properties`），在 `fushi/android/` 下走租约：
  `dart ../tool/heavy.dart --check-only -- .\gradlew.bat :app:testDebugUnitTest --tests app.fushi.reader.CrossAppAudioPolicyTest`。
- 测试类路径上的 `android.jar` 全是抛 `Stub!` / "not mocked" 的桩，也没有 Robolectric：要单测的逻辑抽成不碰 Android
  类的纯 Java（例：`CrossAppAudioPolicy`、`AnkiChannelHandler.runsOnMainThread`），别让被测类的静态初始化里出现
  `new Handler(Looper.getMainLooper())` 这类调用。

## Rust 本地开发循环（quick profile）

- **改 Rust 时的「编译—测试」循环一律用 `quick` profile，不用 `--release`**：在 `native/<crate>/` 下
  `cargo test --profile quick --lib <过滤>`。带 feature 的照加（fushi_fsrs 的 `--features id_audit`）；有 `tests/*.rs`
  集成测试的 crate（fushi_music / fushi_rwkv / fushi_corpus）按需去掉 `--lib` 或写 `--test <名>`。profile 定义在仓库根
  `.cargo/config.toml`（cargo 从工作目录逐级向上找，所以在仓库任意子目录、或从根目录带 `--manifest-path` 都生效）。
- **为什么**：各 crate 的 `[profile.release]` 是出包配置（`lto = true` + `codegen-units = 1`）——改一行就把整个 crate 连同全部
  依赖重新做一遍 fat LTO，而且基本单线程；`cargo test --release` 还要把库本体（cdylib + staticlib）和测试可执行文件各做一遍。
  `quick` 继承 release（优化级别、各包 `opt-level` 覆盖、`panic`、不开 `debug-assertions` / `overflow-checks` 都不变，测试的
  运行语义与 CI 的 `cargo test --release` 相同），只改编译方式：不做 LTO、256 个 codegen unit、增量编译、不 strip（panic 回溯
  带函数名）。
- **实测**（2026-11-11，i5-12600KF，fushi_fsrs 6.8 万行，机器同时有其他会话在编）：

  | | `--release` | `--profile quick --lib` |
  |---|---|---|
  | 改一行后重编到可跑测试 | 7～15 分钟 | **8～9 秒** |
  | 全新 target 冷编（含依赖） | 约 15 分钟 | 2.5～5.5 分钟（看机器负载） |
  | 一轮「test + `id_audit` test + build」 | 约 40 分钟 | —— |
  | 全量 384 个测试（同负载背靠背） | `cargo test` 16 线程 263～301 秒 | `tool/rust_test.sh` 12 进程 **133 秒** |

- **`--lib`**：不带它，`cargo test` 会把库本体与测试可执行文件各编一遍；测试都写在 crate 内（`#[cfg(test)]`）的 crate
  （fushi_fsrs / fushi_compute / fushi_web_core）加 `--lib` 只编测试那一份，doctest 也跳过。
- **`--release` 只在三种时候用**：① 出产物（`build_*` 脚本、`tool/native_libs.ps1`，给 app 与 `flutter test` 用的库必须是
  release）；② 量性能（基准、README 里的耗时——`quick` 没有跨 crate 内联，**不要在 `quick` 下量性能**）；③ 复核只在 LTO /
  单 codegen unit 下才出现的问题。全量 `cargo test --release --locked` 由 PR CI 的 `native-*-gate.yml` 跑，本地不拿它当循环，
  一个分支至多 push 前跑一次。
- **一个 worktree 一个 target 目录（默认的 `native/<crate>/target/` 就是），不必另设 `CARGO_TARGET_DIR`**。跨 worktree
  共用一个目录曾经会静默拿错产物：cargo 给工作区内 crate 算单元哈希用的是相对工作区的路径，不同 worktree 的 `fushi_fsrs`
  是**同一个哈希**，新鲜度只比源文件 mtime——实测 B 侧加了一个必挂的测试，`cargo test` 0.3 秒报 6 passed、exit 0，用的是
  A 侧的产物。现在有两半接线防它：仓库根 `.cargo/config.toml` 的 `[env]` 把本 worktree 根目录放进 `FUSHI_WORKTREE_ROOT`
  （`relative = true`），每个 crate 的入口文件 `option_env!` 读它一次，cargo 把值记进新鲜度指纹，换 worktree 就判 dirty 重编
  本仓 crate（依赖不重编；值不进产物）。新加 crate 必须带上入口文件里那一行，守卫
  `fushi/test/build/native_crate_worktree_fingerprint_guard_test.dart`。仍然不建议共用：并发构建互相等目录锁，来回切换每次
  都要重编本仓 crate；**还没合到这份接线的旧分支共用目录照旧会拿错产物**。同一个 worktree 里的多个子代理共用它是对的。
- **跑一大批测试用 `bash tool/rust_test.sh <crate> [过滤...]`**（`--features <f>`、`--jobs <n>`、`-- <libtest 参数>`）：用
  `quick` 编一次，再把测试分给多个**进程**跑，退出码 0 = 全部通过且报告的测试数等于选中的数。fushi_fsrs 的测试在同一个进程
  里多线程跑不快（16 个测试单线程 7 秒，16 线程反而 11～18 秒；分到 8 个进程则 8 倍工作量只多三成时间）。同负载背靠背
  实测全量 384 个测试：`cargo test` 16 线程 263～301 秒，本脚本 12 进程 133 秒（机器闲时 85 秒）。跑个别测试直接
  `cargo test --profile quick --lib <过滤>` 即可。
- **为什么进程内多线程不快**：SQLite 的内存统计（`SQLITE_DEFAULT_MEMSTATUS`，默认开）让进程内每一次 SQLite 分配 / 释放都过
  同一把全局锁，而测试是多线程同时建库、建表、预编译语句，分配极密。对照实验：用 `-DSQLITE_DEFAULT_MEMSTATUS=0` 重编后
  同一批 16 个测试 1 / 4 / 16 线程是 7 / 3 / 3 秒，全量 16 线程 149～209 秒（开着是 337 秒，同负载背靠背）。已排除的：
  SQLite 全局页缓存（`SQLITE_ENABLE_MEMORY_MANAGEMENT`）、Rust 堆分配器。**生产构建没有关它**：`ffsrs_store_diag_counts`
  靠它报 SQLite 堆用量与高水位（移动端内存耗尽闪退的取证，BUG-4075，`store::ffi::tests::diag_counts_*` 钉着），而只读查询受
  这把锁的影响不大——K 条只读连接各跑同样多的「取行 + JSON 取值 + 排序 + 分组」查询，吞吐开 / 关分别是 2 条 1.54× / 2.02×、
  4 条 2.47× / 2.84×、8 条 2.52× / 2.63×。要在生产关掉它，得先给诊断换一个不靠全局统计的读数（例如按连接的
  `sqlite3_db_status`）。分进程跑时每个进程各有一把锁，所以脚本不改被测对象就拿到了并行。
- **循环里不跑两遍全量**：fushi_fsrs 的 `--features id_audit` 给 Dart 桥的 query / exec 路径加了 ID 绑定审计
  （`ids::audit::take`），默认构建没有；CI 两种都跑。本地按改动选一种——动了桥、ID 绑定或经桥执行的 SQL 就带
  `--features id_audit`，否则跑默认构建——两遍都跑留给 CI。
- **测试可执行文件的全局分配器只在量内存时记账**（`native/fushi_fsrs/src/store/sync2/mem_bench.rs`）：它原先对每次分配 / 释放
  都写同一条缓存行上的两个原子量，16 个测试线程互相抢，CPU 时间放大 27 倍（同一批测试单线程 6 秒、16 线程 170 秒）。给测试
  加全局状态（分配器、计数器、全局锁）前先想清楚它在 16 个线程下的代价。
- **sccache（可选）**：`tool/native_libs.ps1` 发现装了就自动挂上。实测只对冷编有用且有限：换一个 target 目录后 146 次可缓存编译只命中 26 次
  （带 build script 的依赖把 `OUT_DIR`——在 target 目录下——编进产物，下游跟着失配），冷编 153 秒 → 92 秒；对「改一行重编」
  没有帮助（工作区 crate 开了增量，sccache 不缓存增量编译）。缓存目录用 sccache 自己的配置文件指定（打算放
  `D:\dev-cache\sccache`、别落 C 盘；**2026-11-17 核对时 Windows 开发机没有配置文件**，用的是默认的
  `%LOCALAPPDATA%\Mozilla\sccache\cache`，约 6.7 GB）。
  **它也缓存 C 编译**：cc crate（`cc-rs`）见到 `RUSTC_WRAPPER` 的文件名是 `sccache` 就把 C 编译器也包进去
  （cc 1.10.0 `src/lib.rs` `rustc_wrapper_fallback`），所以 zstd-sys / libsqlite3-sys 的 `.o` 也进同一个缓存。C 的缓存键
  不含 target 目录：换一个 `CARGO_TARGET_DIR` 冷编 zstd-sys，25 个 C 编译全部命中（2026-11-17 实测）。手敲的
  `cargo build` / `cargo test --profile quick` 不设 `RUSTC_WRAPPER`，不经过 sccache。
- **本机故障：zstd-sys 报 `LNK1106: invalid file or disk full: cannot seek to 0x250E`（2026-11-17）**。表现：
  `setup_worktree` / `tool/native_libs.ps1` 编 fushi_fsrs 时 zstd-sys 的 build script 失败，lib.exe 打 `libzstd.a` 报
  `4f97f2375d6aa471-entropy_common.o : fatal error LNK1106`；删掉 build 目录、换 worktree 重编都一样；手敲
  `cargo build --profile quick` 却能过。PR #3563 / #3577 / #3579 的 worktree 都撞过。
  - **根因（本机环境，不是仓库脚本）**：sccache 缓存里 entropy_common.c 那一项存的是一个被截断的 COFF 对象。证据：
    00:01～03:27 之间 24 次失败（14 个不同 worktree、4 个 workflow）报的都是同一个文件、同一个偏移 `0x250E`，
    而正常的 entropy_common.o 是 10591 字节（`0x295F`），偏移 0x250E 落在文件内——每次读到的是同一份更短的字节，不是随机写坏；
    24 次全都开着 sccache（日志里有「rustc 编译缓存：sccache」）；C 缓存键不含 target 目录（见上一条），所以删 build 目录、
    换 worktree 都拿回同一份坏对象；quick profile 能过是因为手敲的命令没挂 sccache，不是因为 profile。03:43 起同样的
    构建全部恢复（缓存项被重写过），之后再没复现：2026-11-17 13:03 起在新 worktree 里经 sccache 冷编 zstd-sys 与
    `build_windows_dll.ps1 -IdAudit` 都过了 lib.exe 这一步；把缓存里 720 个 C 对象逐个按 COFF 头核对，没有截断的。
    坏项当初怎么写进去的没能还原（事后没有现场）；同一时段本机的提交内存（commit charge）顶着上限（见下一条），这是最可能的诱因，
    但没有直接证据。已排除：磁盘满（D: 剩 296 GB、C: 剩 309 GB）、路径长度（报错的是 out 目录里的相对文件名，
    其他 worktree 同长度路径能过）、cc 选错工具链（本机 PATH 上没有 gcc / clang / cc，日志里调的是 MSVC 的
    `HostX64\x64\lib.exe`）、多个构建并发写同一 target（每个 worktree 各有 target，cargo 对同一 target 加锁）。
  - **处置**：同一个 `.o` 反复报 LNK1106 / 「invalid file」、删 build 目录不管用时，带 `SCCACHE_RECACHE=1` 重编一次——
    sccache 对这次构建的每个编译都不读缓存、重编并覆盖缓存项（实测 zstd-sys 26 个编译全部「Forced recaches」）：
    `$env:SCCACHE_RECACHE = '1'; powershell -ExecutionPolicy Bypass -File native/fushi_fsrs/build_windows_dll.ps1 -IdAudit; Remove-Item Env:SCCACHE_RECACHE`。
    要彻底清就 `sccache --stop-server` 后删缓存目录。不要拿 `-SkipNativeCompute` 绕过去（测试会跑在旧的原生库上），
    也不要在脚本里加失败重试——坏项在缓存里，重试只会再拿到它。
- **本机故障：编 fushi_fsrs 时 rustc 报 `memory allocation of N bytes failed`（`STATUS_STACK_BUFFER_OVERRUN`，2026-11-17）**：
  是整机提交内存耗尽，不是 rustc 或仓库的问题。实测：13:05～13:19 连续两次 `build_windows_dll.ps1 -IdAudit` 在第二份
  （id_audit）库上报分配 2 MB / 50 MB 失败，当时空闲物理内存还有 20 GB 以上；同期采样提交内存 161.8 / 162.8 GB（页面文件
  系统托管、上限随用随涨），单个 rustc 只占约 1.5 GB，大头是别的进程（一个与本仓无关的 Python 推理进程 46 GB、58 个
  claude 进程合计 26 GB）。第三次同样的命令在负载回落后两份库都编过了。处置：先看任务管理器「性能 → 内存 → 已提交」，
  离上限近就等其他重负载结束或调大页面文件再编；同样不加重试。
- **改一行重编的时间花在哪**（2026-11-17，rustc 1.95，fushi_fsrs `cargo test --profile quick --lib --no-run`，
  `RUSTC_WORKSPACE_WRAPPER` 给本 crate 加 `-Ztime-passes`，依赖不受影响；机器上同时有别的会话占满 CPU）：rustc 本体每次
  15～17 秒，其中宏展开（`expand_crate`，整个 crate 每次重做、不走增量）3.3～4.4 秒、codegen 约 2.8 秒、写增量缓存
  （`serialize_dep_graph`）1.7～2.6 秒、链接（`run_linker`）link.exe 2.0～3.0 秒 / rust-lld 0.9～2.0 秒，其余是类型检查等
  查询。cargo 自身的空跑开销 0.4～0.5 秒。**端到端计时在这台机器上不可信**：同一操作在别的会话占满 CPU 时 14～50 秒乱跳，
  比任何配置差异都大，比较配置要看 `-Ztime-passes` 的分项。
  - **链接器不换**：rust-lld 每次省约 1 秒（约 6%），但链接器只能按 target 配，不能只给 `quick`——会连带改掉出包的
    cdylib / staticlib 和 CI 的 Windows 构建，收益配不上这个风险。
  - **Defender 实时扫描在本机是关的，但卡巴斯基（Kaspersky Internet Security 21.x，服务 `AVP21.26`）开着**，它的文件过滤
    驱动对每次开文件都生效（增量缓存、`.rlib`、链接产物都在其中）。排除目录要在卡巴斯基界面里由机主手动加
    （worktree 根、`~/.cargo`、`~/.rustup`、各 target 目录），命令行改不了；加了以后用上面的分项方法复测
    `serialize_dep_graph` / `run_linker` 再下结论。
- 旧分支 / 还没合到这份配置的 worktree：本机 `~/.cargo/config.toml` 里放同一段 `[profile.quick]` 即可（Windows 开发机
  2026-11-17 补上——此前文档写「已放」，实际文件不存在，旧分支上 `--profile quick` 会直接报找不到 profile）；
  `[env]` 那一段只能跟仓库走（要按 worktree 解析路径），旧分支没有。

## 默认分支（2026-11-25 起是 develop）

GitHub 默认分支是 `develop`（用户 2026-11-25 拍板：开发分支才是主分支，`main` 只当正式版快照，正式版发布后由 `release.yml` 自动从 develop 合进去，见下「快速发版」节的 main 同步）。在这之前默认分支是 `main`，它落后 develop 一个发布周期，于是 `schedule` / `workflow_run` / `pull_request_target`（只读默认分支上的 workflow 定义）都读到旧文件，留下过几处绕路，切换时一并收掉或改了注释：

- `build-multiplatform.yml` 的夜间整轮原本靠 `nightly-develop` 派发器转发到 develop，现在 `schedule` 直接在 develop 上整轮跑，派发器与 `nightly` 输入已删。
- 两条图表 workflow（`dev-activity.yml` / `star-history.yml`）的机器人提交改落 develop（`[skip ci]` + GITHUB_TOKEN，不触发任何构建），推送被拒时 rebase 重试；develop 历史里因此每天最多多两条 `chore(readme)` 提交。
- 滚动 debug release 的 `target_commitish` 与 `tool/bump_rolling_release_tag.sh` 挪 tag 用的「默认分支尖端」随之变成 develop 尖端，与构建产物同一条线。
- `native-cache-warm.yml` 的每日 schedule、`pr-merge-gate.yml` 的 `pull_request_target` 自动改读 develop 上的定义。
- `cache-cleanup` / `merged-pr-cleanup` / `feedback-link` / 设置目录发布当初为绕开默认分支而选的方案原样保留（各自注释已注明当初的理由已不成立，现方案仍可用）。

外部贡献者开 PR 默认指向 develop，不用再手动改 base。

## 发布通道

默认 push 只发 debug 通道；beta/test 和 formal 都必须手动触发。任何 push 触发的 GitHub Release 都必须是 prerelease 且 `make_latest: false`，不得创建或更新 Latest/正式 release。

- debug（push 自动）：**`main` push** 走 `.github/workflows/release.yml` 发布 Android debug GitHub prerelease，并走 `.github/workflows/release-desktop.yml` 发布 Windows debug installer、macOS app zip、iOS no-codesign IPA。**`develop` push 从 2026-09-03 起只跑 `release.yml`**（它是本仓唯一带 app 全量单测门的 workflow）——此前每次合并同时点燃三条长 workflow，runner 排队到互相 cancel，「Build and Test」实测常年被后续 push 的 concurrency 取消、等于没跑；`release-desktop.yml` 与 `build-multiplatform.yml` 的 push 触发已收到只剩 `main`，两者的 `pull_request` / `workflow_dispatch` / `release` 触发**不受影响**（桌面/Apple 产物随时可手动发；PR 上的平台编译门 2026-09-30 起按路径开，见下文「PR 平台 job 的路径门」）。**订正（2026-09-05 起）**：`release-desktop.yml` 的 push 已改回 `['main', 'develop']`（摘掉 develop 等于停发桌面/Apple debug 包，理由见该文件 `push:` 上的注释），所以每次 develop push 都有 Windows / macOS / iOS 的 release 构建；只剩 `build-multiplatform.yml` 的 push 是 `main`。（顺带订正一处长期陈旧的描述：`main.yml` **没有 push 触发器**，只有 `pull_request` 与 `workflow_dispatch`——「push 会走 main.yml 上传 Actions artifact」这句在本次改动之前就已不成立。）Artifact 名称为 `fushi-debug-apk-${{ github.sha }}`，Actions artifact APK 文件名为 `fushi-<version>-<short-sha>-debug.apk`，保留 14 天；Android debug GitHub Release 使用 release-signed debug-channel APK，文件名为 `fushi-<version>-debug.<seq>-<short-sha>-debug.apk`；Windows debug GitHub Release 使用 Inno Setup installer，文件名为 `fushi-<version>-debug.<seq>-windows-setup.exe`；macOS 为 `fushi-<version>-debug.<seq>-macos-arm64.zip`（更新器只吃它），另出同名 `.dmg` 供手动下载安装（挂载后拖进 Applications；未签名的 ad-hoc 包在 dmg 里附 Gatekeeper 放行说明 `打开说明 How to open.txt`）；iOS 为 `fushi-<version>-debug.<seq>-ios.ipa`。Windows/macOS/iOS 都用同一个 `0.x.y-debug.<seq>` 作为 Flutter `--build-name`，保证安装后的 `PackageInfo.version` 能停止同一 debug release 的重复提示/自动安装。GitHub Release 的 git tag 固定为滚动的 `debug-rolling`（TODO-1049，见上「滚动 debug release」）；客户端版本比较用的版本化 tag 仍为 `v<version>-debug.<seq>+<short-sha>`（写进 manifest `tag` 字段）。同一 commit 的 Android/Windows/macOS/iOS 自动 debug 必须落到同一个 GitHub Release（即同一个 `debug-rolling` 滚动 release），且必须是 prerelease / non-Latest；各客户端必须按本平台资产后缀过滤，不能互相吃错平台资产，也不能等 beta/test 或 formal installer。
- beta/test（手动）：通过 `.github/workflows/release.yml` 或 `.github/workflows/release-desktop.yml` 的 `workflow_dispatch` 选择 `beta`，或手动发布一个勾选 prerelease 且非 Latest 的 GitHub Release。Android 默认 tag 为 `v<version>-beta.<seq>`，产物包含 `fushi-<version>-beta.<seq>-<short-sha>-debug.apk` 与 split ABI release APK `fushi-<version>-beta.<seq>-<abi>.apk`；Windows 产物为 `fushi-<version>-beta.<seq>-windows-setup.exe`；macOS 产物为 `fushi-<version>-beta.<seq>-macos-arm64.zip`；iOS 产物为 `fushi-<version>-beta.<seq>-ios.ipa`。**版本名对所有版本 tag 从 tag 派生**（BUG-1836）：beta 包此前用 pubspec 的裸 `<version>`，导致「运行中代码版本」这条更新落地判据在 beta 通道退化成常量。唯一例外是 iOS 的 `--build-name`——Apple 只接受至多三段非负整数的 `CFBundleShortVersionString`，故传剥掉预发布段的 `apple_build_version_name`；`--dart-define=FUSHI_BUILD_VERSION` 仍注入完整版本名。如需 Android、Windows、macOS、iOS 合并到同一 beta/test Release，两个手动 workflow 使用同一个 `tag_name`；未指定时，同一 commit 上两条 workflow 的默认 `<seq>` 相同，也会合并到同一 Release。
- formal（手动）：通过手动 GitHub Release 或 `workflow_dispatch` 选择 `formal`。默认 tag 为 `v<version>`；Android 产物包含 debug APK 与 split ABI release APK，Windows 产物为 installer，macOS 为 app zip，iOS 为 no-codesign IPA。formal 是唯一允许成为 Latest 的通道。**`workflow_dispatch` 的 formal / beta 构建完不直接发布**，停在审批门等「发版」批准，见下「正式版预构建与审批发布」。
- 禁止事项：不要把 push、debug tag、debug APK 或 beta/test workflow 接到 formal/Latest；不要让 push 上传正式 release APK 或发布 formal/Latest；不要把 beta/test 发布成 non-prerelease 或 Latest。

### 暂停调试版自动发布（2026-11-27）

用途：测试版放出去试用期间（例如「测试版测 1 天再发正式版」），让 debug 通道不再出包，免得 debug 通道的用户被新提交打断、runner 也让给 beta / formal。开关是**仓库变量** `FUSHI_PAUSE_DEBUG_RELEASE`，值为 `true`（GitHub 表达式比较不分大小写）时暂停，删掉或改成别的值即恢复，不用改代码、不用提交。

- **暂停**：`gh variable set FUSHI_PAUSE_DEBUG_RELEASE --body true --repo hajisensai/Fushi`
- **恢复**：`gh variable delete FUSHI_PAUSE_DEBUG_RELEASE --repo hajisensai/Fushi`（或 `--body false`）。恢复后不自动补发暂停期间的提交：下一次进 push 路径的提交照常出包（序号 = commit 数，跳号无害）；想立刻出一版就手动 dispatch `channel=debug`（变量删掉之后）。
- 只作用于 **debug 通道的两个入口**：push 事件（在两条 workflow 里只会解析成 debug）与 `workflow_dispatch channel=debug`（2026-11-28 补上：此前只挡 push，有人手动 dispatch debug 就把 debug.33039 推给了 debug 通道用户）。`workflow_dispatch` 的 beta / formal、`release: published` 事件一律不看这个变量，暂停期间照常发，包括它们的 TestFlight。暂停期间确实要出一版 debug，先删变量再 dispatch。
- `release.yml`：`build` 与 `publish-android` 两个 job 在 job 级 `if` 上跳过（Android 构建、debug pulse、滚动 debug 资产上传、更新清单全不跑，连 runner 都不占）。`web-core-linux` / `test-native-linux` / `fushidicts-linux` / `tests` 不受影响——它们是 develop 上唯一的 app 全量单测门；`publish-settings-catalog`（官网设置目录）跟着 `tests` 照跑，它不是调试版发布。
- `release-desktop.yml`：windows / macos / flatpak-baseapp / linux / ios / testflight / publish 每个 job 都在 job 级 `if` 上跳过（含 develop push 每次的 debug TestFlight 上传）；`publish` 带 `always()`，不会随 needs 跳过，所以它自己也判。
- 服务端 `hajisensai/fushi-server`：`release-server.yml` 的 plan step 把同名变量交给 `tool/server_release_plan.py`，暂停时 auto 不再挑「develop 新提交 → debug」，app 正式版 / beta 的服务端候选照常。注意可复用 workflow 的 `vars` 取的是**调用方**仓的变量，所以要连服务端 debug 一起停，得在 fushi-server 上另设同名变量（`--repo hajisensai/fushi-server`）；只在本仓设时服务端 debug 照发（它不进五端 app 的更新通道，不影响测试版试用）。
- 守卫：`fushi/test/build/release_debug_pause_guard_test.dart`（每处引用必须是 `!(vars.FUSHI_PAUSE_DEBUG_RELEASE == 'true' && (github.event_name == 'push' || github.event.inputs.channel == 'debug'))` 整体表达式、哪些 job 挡哪些不挡、服务端暂停判断排在 formal / beta 之后）、`tool/check_release_policy.ps1`（同一表达式与出现次数）、`tool/server_release_plan_test.py`。

### 反馈修复的发布回填（2026-10-13）

应用内反馈的状态挂在**修复 commit** 上：`.github/workflows/feedback-link.yml` 只挂 push develop/main，由 `tool/feedback_link.mjs` 逐个 commit 解析 message，并用 `GITHUB_TOKEN` 查 `GET /repos/{repo}/commits/{sha}/pulls` 取关联 PR（只认已合并、base 是本分支的）解析其描述，把 `Feedback: <id>[, <id>…]` / `Feedback-NoApp: <id>…` 行（行首、不区分大小写）登记到反馈服务 `POST /v1/ci/feedback/fixed`（幂等：sha 与 scope 不变的重登记不重置发布记录）。commit message 里的 id 归该 commit，PR 描述里的 id 归该 PR 在这次 push 里最后一个 commit，同一 id 多次出现取 push 顺序最后的那个；main 上只处理 distinct 的 commit（正式版后 develop 同步进 main 不重登记）。不用 `pull_request_target`：它要在有 secret 的上下文里处理外部 PR，而合并本身就是 push。两条发布 workflow 在「Publish mirror update manifest」之后各有回填步骤（`release.yml` = android；`release-desktop.yml` 的 publish job 按本次真实存在的产物分别回填 windows / macos / ios），跑 `tool/feedback_mark_released.sh`：GET `pending?channel&platform` → 本地 `git cat-file -e` + `git merge-base --is-ancestor <fix> <github.sha>` → POST `released`，把「这个通道 / 平台的这个版本已包含修复」记下（`manifest_channel` 的 `formal` 映射成 `stable`）。回填与登记**都不会让 workflow 变红**：步骤 `continue-on-error: true`，脚本任何失败只打 `::warning`。需要仓库 **secret `FEEDBACK_CI_TOKEN`**（与反馈 Worker 的同名 secret 一致；未配置时两个脚本 `::notice` 后直接跳过）与可选的仓库 **variable `FEEDBACK_API_BASE`**（接口根，缺省 `https://rank.fushi.moe`）。守卫 `fushi/test/build/feedback_workflow_guard_test.dart`，脚本离线测试 `fushi/test/tools/feedback_{mark_released,link}_script_test.dart`。

### 仓库 BUG 同步进反馈（2026-11-27）

`docs/bugs/BUG-*.md` 里「① 未修复」的条目自动出现在应用内反馈（开发者处理台 `/dev` 与 App 开发者视图，列表项带 `repoBug`），不再靠 agent 手动 `fushi_cli feedback submit`。`.github/workflows/bug-feedback-sync.yml` 在 push develop（`docs/bugs/**` 变化）时跑 `tool/bug_feedback_sync.mjs`，做的是**对账**而不是追加，跑多少次结果都一样：

- 文件状态与 `tool/bug.dart statusIcons` 同一口径：有 ① 没勾 = open；勾了 `[x] ①` = fixed；没勾但「真实性」行有 ❌ = dropped；既无 ① 也无 ② = record。同号多个文件（develop 上还没 settle）的号整轮跳过。
- `GET /v1/ci/feedback/bugs` 拿服务端已同步的 `{bug, id, hash, status}`，本地算差异后 `POST /v1/ci/feedback/bugs`（每批 ≤ 25）：open 且服务端没有 → 新建（category bug、无反馈人、`origin {"source":"repo_bug"}`，标题 `BUG-NNNN · 标题`，正文是 BUG 文件全文 + 仓库链接，截到 8000 字）；open 且 `SHA-256(标题\n正文)` 变了 → 改文字（服务端那条是「已解决」的 = 回归，拉回 open、清修复记录、时间线记一笔；开发者手动 wont_fix / duplicate / closed 的只改文字不动状态）；服务端 open / in_progress 而文件 fixed → 走与 `/v1/ci/feedback/fixed` 同一份 `MARK_FIXED_SQL`，修复 commit 记本次 push 的 `github.sha`（scope app，发布回填照常跟进）；文件 dropped / record / 已删除或改号 → `closed`。
- 服务端：`services/leaderboard/src/feedback_repo_bugs.js` + 迁移 `0028_feedback_repo_bug.sql`（`repo_bug` 部分唯一索引保证一个号只有一条，INSERT … ON CONFLICT 原子 upsert）。不扣用户提交的 `feedback` 日预算，只扣 `write_rows`。
- 凭据沿用 secret `FEEDBACK_CI_TOKEN` 与 variable `FEEDBACK_API_BASE`；没配 token、或 Worker 还没部署带迁移 0028 的版本（接口 404）→ `::notice` 跳过；其他接口错误让这条 workflow 变红（不重试，下一次 push 重新对账）。
- 回填范围：仓库 variable `BUG_FEEDBACK_MIN_NUMBER`，只为号 ≥ 它的 BUG **新建**反馈（不设 = 全部未修复的都建），已建的照常更新 / 结案。首次上线：先手动部署 Worker（`leaderboard-worker-deploy.yml`，会先跑迁移 0028），再 `gh workflow run bug-feedback-sync.yml -f dry_run=true` 看 `PLAN` 行，确认后 `-f dry_run=false` 跑一次正式对账（之后每次 develop push 自动跑）。
- 归属（所有者 2026-11-27 拍板挂上）：仓库 variable `BUG_FEEDBACK_AS` = 开发者账户 id 或昵称，服务端按 `scripts/feedback.mjs --as` 同一口径解析（只认 `role='dev'`，查不到 / 昵称重名整批 400 `bad_account`），新建 / 改写的行 `account_id` 挂到该账户，App「我的反馈」里也看得到、能追加说明 / 结案；不设 = 不挂账户、只在开发者视图出现。不带 `as` 的改写不清已有归属。
- `bug-number-settle.yml` 用 `GITHUB_TOKEN` 推的改号提交不触发 workflow，改号由下一次 develop push 一并对账。
- 测试：`services/leaderboard/test/feedback_repo_bugs.test.js`（真迁移 + 真 Worker 路由端到端跑脚本：两次同步只一条、勾 ① 结案、改回重开、删除结案、撞号跳过、回填下限、分批）；守卫 `fushi/test/build/feedback_workflow_guard_test.dart`。

### 设置项目录自动同步到官网（2026-11-16）

官网 `fushi.moe/settings.md`、`/settings.json` 是给 AI 读的全量设置项目录（键、中英标题、位置、类型、可选值、范围、默认值），**不手工维护**：

- 导出器 `fushi/test/settings/settings_catalog_export_test.dart` 遍历 `fushi_cli config ls` 用的同一份设置索引（`buildSettingsIndex`，整棵 schema + 逃生口页面）。平时是普通单测（守「能走完整棵 schema、机密项不出值」）；设了 `FUSHI_SETTINGS_CATALOG_DIR` 才把 `settings-catalog.{json,md}` 写进那个目录。内容必须确定（不带时间戳 / commit）。
- **按出包平台各算一遍**（拍板台 pr3506，2026-11-21）：CI 在 Linux 上跑，而 Linux 不出包，所以导出器用 `debugHostPlatformOverride`（`fushi/lib/src/platform/host_platform.dart`）+ `debugDefaultTargetPlatformOverride` 按 Android / iOS / Windows / macOS 各建一个全新安装的 app 走一遍索引（文案取 Android 的中英两遍）。四个平台默认值一致的给 `default`，不一致的改给 `defaultByPlatform`（如 iOS 的挖矿片段格式 `mp4H264`、下载后端 `qbittorrent`）；只在部分平台显示的行给 `platforms`；顶层 `platforms` 列出算过的平台。字段是加法，`kSettingsCatalogSchema` 不变。前提是设置层读平台只经 `hostPlatform`：`lib/src/settings/`、`settings_index.dart`、`ctl_settings_body_*.dart` 与它们依赖的 `store_compliance.dart` / `DesktopLookupService.isDesktop` / `isDesktopSystemBallPlatform` 禁止直读 `Platform.isXxx`（`fushi/test/settings/settings_host_platform_guard_test.dart` 守），`PlatformServices` 的平台字段默认值与 `platform_utils.dart` 的平台判据也读它。读 `Platform.isXxx` 的其余代码（运行期能力判断）不受覆盖影响，若某个设置的默认值经它们间接算出，会在四个平台上都显示 CI 宿主的值——改成读 `hostPlatform` 即可。
- `release.yml` 的 `tests (checks)` 在每次 push 上跑它并传 artifact `settings-catalog`；同一 workflow 的 `publish-settings-catalog` job（`needs: tests` + `always()`，单测分片红不挡它，只有 run 被取消才不跑；job 级 `contents: write`，tests 仍只读）取本 run 的 artifact，由 `tool/publish_settings_catalog.sh` 推到 `update-manifest` 分支：develop → `settings-catalog-debug.*`，main → `settings-catalog-stable.*`。设置没变就不产生提交；与 `publish-android` 并发推同一分支时，脚本被拒后重取远端 tip、只在最新提交上重放这两个文件。没有 artifact 记 notice 后正常结束。
- **不用 `workflow_run`**：放在 `release.yml` 里同 run 发布链路最短。（当初还因为它只认默认分支上的定义，而默认分支曾是落后一个发布周期的 main；2026-11-25 起默认分支是 develop，见下文「默认分支」。）
- 官网仓（`hajisensai/fushi.moe`）的边缘 Worker `edge/src/settings-catalog.ts` 同域代理这两个文件（不带参数给 stable，没有就退回 debug；`?channel=debug` 指定），llms.txt 的「App reference」指向它。
- 加减设置项不需要做任何事；改了目录 JSON 的字段含义才要把导出器的 `kSettingsCatalogSchema` 与 Worker 的 `CATALOG_SCHEMA` 一起加一。接线（环境变量名 / artifact 名 / 发布 job 的触发条件与权限）由 `fushi/test/tools/settings_catalog_publish_script_test.dart` 守。

### Windows 安装器：原地升级与「数据存储位置」页

（历史备注：2.0 改名那一轮，formal 通道曾有「先发 Android 迁移桥包 `bridge-<version>-<abi>.apk`
再发本体」的 CI 硬门，让已出货的 Hibiki v1.2.0 先命中桥包。该硬门与 `bridge/*` 分支已随
2.7.0 正式版（资产表只有 `fushi-*`）一起退役；只剩
`fushi/test/utils/misc/formal_asset_naming_legacy_contract_test.dart` 继续钉住本体资产名
「产品族前缀 + ABI 全名」的命名契约，别再按桥包顺序发版。）

- 改名前的 Windows 老用户按 `-windows-setup.exe` 后缀直接拿
  `fushi-<version>-windows-setup.exe`，Inno `AppId` 未变 → 原地升级，数据由
  `legacy_support_dir_migration.dart` 自动搬迁。
- Windows 安装器的「数据存储位置」页（`fushi/windows/installer/fushi.iss`）**只在全新
  安装出现**。`IsFreshInstall` 是**三个**条件的 and：无卸载键、`%APPDATA%\Fushi\Fushi`
  不存在、`%APPDATA%\Hibiki\Hibiki` 也不存在（第三条兜改名前的老用户「卸载留数据后
  重装」——首启 `migrateLegacySupportDir` 会把旧名搬成新名并认出旧库，那台机器不该被
  再问一次）。用户的选择写进 `{app}\data_root.bootstrap`，app 首启在 `AppPaths.resolve()`
  之前由 `lib/src/storage/installer_data_root_bootstrap.dart` 一次性消费**后删除**。
  「消费」不等于「采纳」：app 侧还会独立否决安装器的选择——已有 `data_root` 偏好、平台
  support 根下已有主库、路径不是绝对路径、与安装目录相同或互相包含、目标下已有非空
  `documents`/`support` 子树，任何一条命中都只删文件不写偏好；**选中默认位置**
  （`<Documents>\Fushi`）同样**不写** pref，按全新安装的固定落点走。升级 / 保留数据重装 /
  静默自更新都不弹这页、不写这个文件；安装器是一次性写者，数据根的唯一真相源仍是 app 的
  `data_root` 偏好（要搬走走设置里的迁移）。
  改 iss 后本机可用 `ISCC.exe /DAppVersion=0.0.0 /DSourceDir=<任意含一个文件的目录>
  /DOutputDir=<临时目录> fushi.iss` 验编译，但**别运行**产物——同 AppId 会覆盖本机真实
  安装的卸载键。**CI 不编译这个 iss**：`build-multiplatform.yml` 的 `windows` 检查根本
  不碰它，真正跑 ISCC 的 `release-desktop.yml` 没有 `pull_request` 触发。所以 Pascal 侧
  的唯一门是源码守卫 `test/build/windows_installer_data_root_page_guard_test.dart`——
  它钉的是**效果**（整式比对、每条校验后必须 `Result := False;`、`if ... then Exit;`
  成对、跨语句顺序），改动 iss 后新增断言必须做变异实测再提交。

### 快速发版（跳测试）

手动发版嫌慢时用「快速编译」路径：`release.yml`（Android）的 `workflow_dispatch` 带 `skip_tests` 输入，**默认 `true`**——手动 dispatch（debug/beta/formal 任意通道）默认跳过 `flutter analyze` + 主 app 单元测试 + 5 个 package 测试，直接进编译+发布。`release build` 步骤本身仍会挡住硬编译失败，发版前的真机验证仍按 [CLAUDE.md](../../CLAUDE.md) 走。约束：
- `skip_tests` **只在 `workflow_dispatch` 生效**；`push`（自动 debug）与 `release`（手动 GitHub Release）事件的 `github.event.inputs.skip_tests` 为空，恒跑完整测试门——`main`/`develop` 的持续测试信号不被削弱，慢的只让手动、你在等的那次发版跳过。
- 想手动发版也跑测试：dispatch 时把 `skip_tests` 取消勾选（设为 `false`）。
- `release-desktop.yml`（Win/mac/iOS）本就无测试步骤，天生快，无需该开关。
- **正式版发布后 main 自动同步成 develop**（2026-09-08 起）：`release.yml` 的 `publish-android` job（2026-10-17 前在 build job 里）在正式通道（`workflow_dispatch channel=formal` 或手动发非 prerelease 的 GitHub Release）写完更新清单后，在临时克隆里 `git merge --no-ff -X theirs origin/develop` 进 main 再推（提交信息沿用人工时代的 `Merge develop into main for <tag>`）。main 上只有两种提交——从 develop 合来的合并提交，和 2026-11-25 之前两条图表 workflow 的机器人提交（当时默认分支是 main，scheduled 只在默认分支跑，SVG 落 main；之后改落 develop），所以 main 永远不是 develop 的祖先、纯快进不可行；`-X theirs` 让图表 SVG 冲突取 develop 的，其它冲突（modify/delete）直接红、绝不 force-push。只在 `release.yml` 做一次（桌面 workflow 不做，两条并行时不会推两条合并提交）；GITHUB_TOKEN 的 push 不级联触发 main 的 push 构建。守卫 `fushi/test/build/release_workflow_main_sync_guard_test.dart`。
- 平台并行：Android（`release.yml`）与桌面（`release-desktop.yml`）是两条独立 workflow，concurrency 组名含各自 workflow 名，同一 tag 同时 dispatch / 同一 `release: published` 事件点燃即真并行（2026-09-08 起；此前两条同名组会串行、后到的 pending 还会取消先到的 pending）；桌面内部 `apple needs: windows` 是**故意串行**，避免两 job 抢同一 release 上传，勿改。

### 正式版预构建与审批发布（2026-10-17）

用户要求：正式版必须**提前在云端构建好**，说「发版」时秒发，不再现场重新构建（原来一次 30~50 分钟）。

**结构**：两条发布 workflow 都拆成「构建 job」与「发布 job」，所有对外动作只在发布 job 里：

| workflow | 构建 job（只构建 / 签名 / 上传 run artifact） | 发布 job（挂审批门） |
|---|---|---|
| `release.yml` | `build` | `publish-android`：GitHub Release 上传 / 创建、滚动 debug 清理、更新清单、反馈回填、正式版 main 同步。通道解析结果经 build 的 job outputs 传过来，APK 取自 run artifact `fushi-<channel>-apk-<sha>` |
| `release-desktop.yml` | `windows` / `macos` / `ios` | `publish`（三平台 Release 资产 + 清单 + 回填）、`testflight`（取 `ios` 签好的 `ios-testflight-signed-ipa` artifact 后 `altool` 上传；该 artifact 刻意不叫 `desktop-artifacts-*`，App Store 签名包绝不进 Release） |

**审批门 = GitHub 环境**。发布 job 的 `environment` 是
`${{ (github.event_name == 'workflow_dispatch' && (github.event.inputs.channel == 'formal' || github.event.inputs.channel == 'beta')) && 'release-publish' || 'release-auto' }}`：

- `release-publish`（id `24572755799`）：必需审批人 hajisensai，`prevent_self_review=false`（自己 dispatch 的自己能批），不限分支。formal / beta 的 dispatch 跑完构建后发布 job 显示 **Waiting**。
- `release-auto`（id `24572756532`）：无任何保护规则。push 滚动 debug、手动发 GitHub Release（`release` 事件，本身就是发布动作）、`testflight_only` 补传、develop push 每次的 debug TestFlight 都走它，**不等人**，行为与改动前一致。
- 没用「表达式算出空串 = 不挂环境」：官方文档没有写这条语义，而 push 发布每天跑十几次，赌错就是全停；两个具名环境的行为都有文档保证。代价是 push 发布会在 `release-auto` 下留部署记录（纯展示）。
- `build_only=true`：两条 workflow 的发布 job 都整个跳过，不弹审批（`testflight` job 也因签名门关闭而跳过）。
- 期限：待审批 job 最长挂 **30 天**后自动失败（GitHub 上限；整条 run 上限 35 天）。审批 run 的 run artifact 保留期因此从 14 天提到 30 天（非审批 run 不变；签名 IPA artifact 非审批 run 只留 1 天）。超过 30 天没批，就重新 dispatch 构建。
- 守卫：`fushi/test/build/release_publish_gate_guard_test.dart`（对外动作只出现在挂门的 job、环境表达式逐字一致、构建 job 不挂环境、保留期 ≥ 30 天、publish-android 读的每个通道字段都经 job outputs 导出）。

**流程**：

1. 准备好 `docs/release-notes/<版本>.md` 与 `fushi/pubspec.yaml` 版本号（公告在构建时就读进 job outputs，批准时不再重读——构建后改公告要重新 dispatch）。
2. 预构建（同一 ref 上两条一起 dispatch；不给 `tag_name` 时两条按同一 commit 算出同一个 `v<version>` / `v<version>-beta.<seq>`，落到同一个 Release）：

   ```bash
   gh workflow run release.yml         --repo hajisensai/fushi --ref develop -f channel=formal
   gh workflow run release-desktop.yml --repo hajisensai/fushi --ref develop -f channel=formal
   ```

3. 等两条 run 都停在门口：Android 是 `publish-android` 在等；桌面是 `testflight`（`ios` 一完就到）与 `publish`（三平台都完才到）两个 job 在等。**批之前确认构建全绿**：桌面 `publish` 是 `always()`，某个平台构建失败时它照样会进门，批了就只发出其余平台。

   ```bash
   gh run list --repo hajisensai/fushi --workflow release.yml         --event workflow_dispatch --status waiting --json databaseId,headSha,displayTitle,createdAt
   gh run list --repo hajisensai/fushi --workflow release-desktop.yml --event workflow_dispatch --status waiting --json databaseId,headSha,displayTitle,createdAt
   gh run view <run> --repo hajisensai/fushi --json jobs --jq '.jobs[]|{name,status,conclusion}'
   gh api repos/hajisensai/fushi/actions/runs/<run>/pending_deployments \
     --jq '.[]|{env:.environment.name,id:.environment.id,can:.current_user_can_approve}'
   ```

4. 用户说「发版」→ 两条 run 各批一次（一次批准放行该 run 里当时所有在等 `release-publish` 的 job；桌面若只等到了 `testflight`，`publish` 稍后进门还要再批一次）：

   ```bash
   gh api -X POST repos/hajisensai/fushi/actions/runs/<run>/pending_deployments \
     -F 'environment_ids[]=24572755799' -f state=approved -f comment='发版'
   ```

   网页上同样可以在 run 页面点 **Review deployments**。不发了就 `-f state=rejected`（发布 job 失败、什么都不外发）。环境 id 变了用 `gh api repos/hajisensai/fushi/environments --jq '.environments[]|{name,id}'` 查。
5. 批准后发布 job 只做下载 artifact + 上传 + 写清单，Android 约 1~2 分钟、桌面约 2~3 分钟、TestFlight 上传约 5 分钟。

**注意**：待审批的 run 一直占着它的 concurrency 组（`fushi-release-<workflow>-<tag|sha>`）——同 tag/sha 再 dispatch 一次会排在后面，第三次会把排队的那条顶掉；已在门口等的那条不受影响。

### Apple 签名与 TestFlight

`release-desktop.yml` 的 `ios` / `macos` job 在仓库 secrets 齐全时额外做 Apple 签名，
完整清单、首次配置、证书轮换与排障见 [apple-signing.md](apple-signing.md)。这里只记
影响发布判断的三条：

- **Apple 凭据全部可选**。缺任何一项，对应链路整段跳过，未签名 IPA / ad-hoc macOS zip
  照常发布 —— fork 和无开发者账号的状态下发布链路完全不受影响。
- **TestFlight 上传两条路**：手动 `workflow_dispatch` 的 beta / formal 放行（输入
  `upload_testflight`，默认开；签名 IPA 在 `ios` job 里构建好，上传在独立的 `testflight` job，
  要等审批门批准，见下「正式版预构建与审批发布」），debug 只在 `testflight_only=true` 时放行；**push 的 debug 通道
  每次都传**（2026-11-02 用户拍板「改成每次 ci 自动推 tf，不用每次看」，取代 09-16 的「发布
  序列 % 3 == 0 才传」与 10-14 的「大合并后核序列、不整除手动补发」）。构建号 = 共享发布序列
  （commit 计数），沿 develop 每次 push 单调递增。只认 develop：`main` 的 push 不传（main 的 commit 数远低于 develop，序列落在已传号段下面，快进到已传过的 sha 时必撞号，见下条）。代价：每条 push 多一趟约 15 分钟签名构建，TestFlight 列表
  debug 构建变多（每个挂 90 天）。缺任一 Apple 密钥 push 门直接关（fork 照常绿）。被后续 push
  顶掉的 pending run 不传，由更新的那轮传。09-14 ~ 09-16 的定时通道 `testflight-debug.yml`
  已撤（两条节律并存会重复上传），守卫钉着不得回潮。
- **`testflight_only` 手动补传**仍保留（`gh workflow run release-desktop.yml --repo
  hajisensai/fushi --ref develop -f channel=debug -f testflight_only=true`）：只签 iOS、不发
  Release、走独立 concurrency 组。日常不需要；同一 sha 上 push 已传过时它必撞号（见下条）。
- **同一个 commit 不能重复传 TestFlight**（2026-10-22 实测）：build number 由
  `tool/release_sequence.sh`（commit 数 + 地板）算出、经 `--build-number` 直接喂给 iOS 构建，
  `pubspec.yaml` 的 `+build` 与 `workflow_dispatch` 输入都改不了它。所以在同一个 sha 上重跑
  `testflight_only` 必然算出同一个号，ASC 直接 409 `ENTITY_ERROR.ATTRIBUTE.INVALID.DUPLICATE`
  （`The bundle version must be higher than the previously uploaded version: '<seq>'`）：`ios`
  job 全绿、只有 `testflight` job 红，容易误判成签名或凭据问题。要真正再出一份新包，唯一前提是
  让序列涨一格（develop 多一个 commit），触发方式本身解决不了。纯为出包抬序列时优先落 docs 类
  改动——`docs/**` 不在本 workflow 的 push `paths` 里，不会顺带触发一轮全量构建，随后单独 dispatch
  `testflight_only` 只跑一轮 iOS。

- **GitHub Release 里的 `fushi-<版本>-ios.ipa` 仍是未签名包**，走的还是
  `flutter build ios --release --no-codesign`。老用户自签侧载的就是它，不能换成
  App Store 签名包。TestFlight 用的是另一次签名构建（手动 beta/formal，或每次 develop
  debug push），产物不进 Release 资产 —— 代价是这种 run 下 iOS 构建两次。
- macOS 走 **Developer ID + 公证**，不进 Mac App Store：`Release.entitlements` 已刻意
  去沙盒以支持应用内自动更新替换 `/Applications/fushi.app`，商店强制沙盒，两者不可兼得。

### Android 崩溃 / ANR 的 Dart 符号（2026-11-21，BUG-4955）

- Android 上 gen_snapshot 不 strip，`fushi/build/app/intermediates/flutter/release/<abi>/app.so` 是带
  `.symtab` + `.debug_info` + `.debug_line` 的完整 ELF，AGP 打包时才 strip 成 APK 里的 `lib/<abi>/libapp.so`（build-id 不变）。
  `release.yml` 每次 `flutter build apk --release` 之后用 `fushi/tool/android_dart_symbols.sh stash <target-platform>`
  收这份 ELF（逐 ABI 出包要逐次收：换 target-platform 重编会清掉上一份），出包后 `verify` 核对每个 release APK
  的 libapp.so build-id 与收到的一致，按发布序号上传 artifact `android-dart-symbols-<序号>`（正式 / 测试版 90 天、
  debug 通道 14 天，`continue-on-error`、不进 Release 资产）。守卫 `fushi/test/build/android_dart_symbols_guard_test.dart`。
- **不用 `--split-debug-info`**：它连带 `--dwarf-stack-traces`，会把 app 内的 Dart 栈改成 DWARF 形式，诊断日志的
  `ui_activity_probe` 调用点归因（`who=` / `fcb=`）与反馈里的符号化栈全部退化。这里运行时零改动。
- **还原**：ANR / tombstone 栈里 `base.apk (offset …) (???) (BuildId: <id>)` 的帧就是 libapp.so，`pc` 是相对 libapp.so
  装载基址的偏移（Dart ELF 的 vaddr 从 0 起）。按报告的版本 / 构建号下载 artifact
  （`gh run download <run-id> -n android-dart-symbols-<序号>`），先 `readelf -n <abi>/app.so` 核对 Build ID 与报告一致，再
  `llvm-symbolizer --obj=arm64-v8a/app.so 0x05cbbc30 0x0249c48c …`（NDK 的 `toolchains/llvm/prebuilt/*/bin/` 里有）
  得到 Dart 函数名与 `文件:行`。

### Windows 卡死 / 崩溃 dump 的符号（2026-11-27，BUG-5568）

- Windows 上 gen_snapshot 默认 `--strip`，包里 `data/app.so` 只剩节头；app.so 由 Dart 自己的 ELF loader
  装进私有内存（不是 LoadLibrary），dump 的模块表里没有它，cdb 里 Dart 帧全是 ``0x0000021e`f3f2966f`` 裸地址。
- **出包另存调试信息**：`release-desktop.yml` 的 `flutter build windows --release` 带
  `--extra-gen-snapshot-options=--save-debugging-info=…/fushi/build/windows-dart-symbols/app.windows-x64.symbols`，
  出包后 `dart tool/windows_dump_symbolize.dart verify <app.so> <symbols>` 核对 build-id，按发布序号上传 artifact
  `windows-dart-symbols-<序号>`（debug 通道 14 天、其余 90 天，`continue-on-error`、不进 Release 资产）。
  包里的 app.so 与 app 内 Dart 栈格式都不变；**不用 `--split-debug-info`**（理由同 Android）。守卫
  `fushi/test/build/windows_dart_symbols_guard_test.dart`。
- **dump 自带基址**：runner（`fushi/windows/runner/dart_aot_image.h`）找到装载中的 app.so，把
  `dart_aot base=0x… span=0x… build_id=…` 写进每份 minidump（user stream `0x46555348`），hang dump 时
  `hang_watchdog.log` 也记一行。BUG-5568 之前的 dump 没有这条，基址要从活进程扫（见 BUG 文件）。
- **引擎符号**：`flutter_windows.dll`（含 Dart VM 与 GC）的 pdb 在补丁引擎 zip 里——
  `ci/patches/flutter-engine/<Flutter 版本>/artifacts.json` 的 `url`，解压取 `windows-x64-release/`。
  装了补丁引擎的包签过名，md5 与 zip 里的 dll 不同，但 pdb GUID 一致，cdb 能直接匹配。
- **还原**：装的版本号 `3.4.0-debug.<序号>`（`fushi.exe` 文件版本）→ `gh run download <run-id> -n windows-dart-symbols-<序号>`，然后
  `dart tool/windows_dump_symbolize.dart stack --dump hang-….dmp --dart-symbols app.windows-x64.symbols --engine-symbols <引擎 pdb 目录>`
  （`--threads main` 只看主线程；旧 dump 加 `--base 0x…`）。输出是 cdb 的栈，Dart 帧后面接
  `[dart] 函数 (文件:行)`（经 `flutter symbolize`）。
- **看门狗自己没跑也会记**：看门狗线程两圈之间隔了 ≥2 s（不含系统睡眠）就往 `hang_watchdog.log` 写
  `watchdog thread did not run for … ms (wall clock … ms)`——整个进程没被调度时其它判据全都量不到。

### iOS 包体积与崩溃符号（2026-11-15）

- **slang 不生成 flat map**（`fushi/slang.yaml` 的 `flat_map: false`，BUG-4640）：17 个
  `_flatMapFunction` 在 iOS 快照里占 15 MB，还会让 Windows gen_snapshot 爆栈（BUG-1589）。
  文案只走生成的 getter，`t['key']` 编译不过；守卫 `test/build/slang_flat_map_disabled_guard_test.dart`。
- **两条 iOS 出包命令都 `--split-debug-info`、不 `--obfuscate`**（BUG-4655）：未签名包拆到
  `build/ios/dart-symbols-unsigned`，TestFlight 包拆到 `build/ios/dart-symbols-testflight`，各按
  发布序号上传 artifact `ios-dart-symbols-{unsigned,testflight}-<序号>`（与 `ios-dsyms-*` 同为 90 天）。
  不混淆是因为仓里有 `runtimeType.toString()` 判断，混淆只多省 0.7 MB。
  代价：release 包里的 Dart 栈是 DWARF 形式（`*** *** ***` 头 + `#00 abs 0x… virt 0x… _kDartIsolateSnapshotInstructions+0x…`），
  诊断日志 / 反馈里看不到文件名行号；`ui_activity_probe` 的调用点归因在 iOS release 包上会退化成原始帧。
  **还原**：按报告里的构建号下载对应 artifact（`gh run download <run-id> -n ios-dart-symbols-unsigned-<序号>`，
  TestFlight 包换 `testflight`），把栈原文存成文件后
  `flutter symbolize -i stack.txt -d app.ios-arm64.symbols`。原生帧（`Runner+偏移`）照旧用 `ios-dsyms-*` 的 dSYM。
- **iOS 包里每个 Mach-O 都 `strip -x`**（`tool/ios_strip_local_symbols.sh`，BUG-4656）：只去本地符号，
  逐个比对 strip 前后的导出集合与 Runner 的 FFI 前缀计数，变了就让出包失败，之后再跑一遍 7 个
  `verify_abi.sh`。崩溃符号化靠 dSYM，不受影响。
  - 未签名 IPA：`flutter build ios` 是 Xcode build 动作（`DEPLOYMENT_POSTPROCESSING=NO`），Runner 的
    `STRIP_STYLE=non-global` 不执行，嵌入的预编译 framework 也不 strip——在「Prepare unsigned iOS IPA
    release asset」里 ditto 之后、zip 之前 strip（Mac 实测 −27.4 MB 原始、IPA zip −4.1 MB）。
  - TestFlight：archive 动作下 Runner 已按 `STRIP_STYLE` 处理（实测再 strip 是空操作），但 CocoaPods
    嵌的预编译 framework 原样进包（Harfbuzz、PDFium 等，再 strip 还能省 9.8 MB）。`flutter build ipa`
    之后对归档里的 .app strip，再 `xcodebuild -exportArchive` 用同一份 ExportOptions 重签导出。
- **已知未修：dev_dependencies 插件的 framework 仍进 Release IPA**（integration_test 82 KB、
  flutter_native_splash 72 KB）。根因在 Flutter 3.47.6：release 构建只把它们从
  `GeneratedPluginRegistrant` 里滤掉（`flutter_tools/lib/src/flutter_plugins.dart:1410` 的 `releaseMode`
  过滤），而 `bin/podhelper.rb` 的 `flutter_install_plugin_pods`（:292）不看
  `.flutter-plugins-dependencies` 的 `dev_dependency` 标记，照样 `pod` 进所有配置。在 Podfile 里把它们
  限到 Debug / Profile 试过（Mac 实测 Pods-Runner-frameworks.sh 的 Release 段确实不再嵌入），但注册表只在
  跑 pub 的 `flutter build` 里按 release 重生成（`runner/flutter_command.dart:1982` 的
  `regeneratePlatformSpecificToolingIfApplicable`，`--no-pub` 时跳过）：`--no-pub` 的 release 构建或
  pub get 后直接用 Xcode archive，注册表仍 `@import flutter_native_splash`，编译直接
  `Module 'flutter_native_splash' not found`。为 150 KB 引入这个坑不划算，等 Flutter 的 podhelper
  自己按 `dev_dependency` 过滤。

## 版本号与 build number

Flutter 版本号以 `fushi/pubspec.yaml` 的 `version: X.Y.Z+build` 为准。准备 push 前先判断本轮改动是否影响用户可安装/可分发产物：

- **`+build`（build number）= 发布序号**：每次出包 / 发布单调 +1，**与语义版本是否变无关**——同一个 `X.Y.Z` 可连续 `+150`、`+151`…（实践即如此：多数发布只 +build、不动 `X.Y.Z`）。它仅做日志 / 可读版本标识，不进 Android `versionCode`。
- **语义版本 `X.Y.Z` 按里程碑升，不是每次发布都升**：
  - 一批功能完成 / 大模块 / 用户可见大改：升 minor 并重置 patch（如 `0.9.29` -> `0.10.0`）。
  - 一批修复 / 小功能阶段性收口：升 patch（如 `0.10.0` -> `0.10.1`）。
  - 单个零散 commit 通常**只 +build**；攒到一批 / 里程碑再升 `X.Y.Z`（届时 `+build` 也照常 +1）。
- Android `versionCode` 的单调递增由 CI 的 `git rev-list --count HEAD`（每个 commit +1）**加一次性地板**经 `--build-number` 喂给 `build.gradle` 的 `versionCodeBase + 100 × <seq> + abiOffset` 保证；`build.gradle` 还带 2.1e9 上限断言，越界即 fail-fast（TODO-414）。**不依赖 pubspec `+build`**。
- 纯文档、PM 元数据、不影响分发行为的 CI 维护不强制 bump；发布、安装包或运行行为变化应 bump。
- **序号算式收在 `tool/release_sequence.sh` 一个文件里**，六处 workflow 一律 `RELEASE_SEQUENCE=$(bash tool/release_sequence.sh)`，不得在 workflow 里写裸 `git rev-list --count HEAD` 赋值（守卫会红）。算式 = 提交计数 + `RELEASE_SEQUENCE_FLOOR`。
- **为什么有地板**：提交计数只在「历史只增不减」时单调，**重写历史会让它倒退**。2026-08-12 develop 被强推成重写后的历史，计数从 10546 掉到 9466，而已发布并装到用户机器上的最大序号是 10405。序号倒退会同时锁死三处单调比较——Android `versionCode`（系统安装器拒装）、app 内更新器的 `releaseSequence` 全序比较（永远提示已是最新）、`tool/merge_update_manifest.py` 的「Never downgrades the advertised top-level release」（新包写不进清单）。这三处都没错，错的是序号倒退，所以修在源头加地板，而不是去放宽任何一处守卫。2026-11-01 第二次重写（filter-repo 剪掉 54 个空提交）计数 20671 → 20619，已发布最大 22671，地板抬到 2200（20619 + 2200 = 22819）。
- **什么时候要再抬地板**：只有再次重写历史、且新的 `计数 + FLOOR` 不再高于「已发布过的最大序号」时。抬之前先去 GitHub Release 资产名里查真实的 `-debug.<seq>` / `-beta.<seq>` 最大值，别凭感觉加。守卫：`fushi/test/build/release_sequence_floor_guard_test.dart`。
- 发布 workflow 修改后必须运行 `tool/check_release_policy.ps1`（Windows：`powershell -NoProfile -ExecutionPolicy Bypass -File tool/check_release_policy.ps1`；GitHub Actions 用 `pwsh`）。该守卫会拒绝重新引入 workflow-local run number、缺失完整历史 checkout、缺失同 tag/commit 发布并发锁，或文档缺少 cross-workflow release sequence / single GitHub Release 规则。

## CI 缓存配额（TODO-2721）

GitHub Actions 给每个仓库的缓存配额是**硬上限 10 GB**，超了就按 LRU 静默驱逐。
驱逐不是洁癖问题：桌面发布 run `30729229450` 变红的最后一环就是 vcpkg 缓存被驱逐
后冷编 + 拉外部镜像失败。2026-08-02 实测 `gh api
repos/hajisensai/Fushi/actions/cache/usage` = **10.65 GB / 14 条**，长期在驱逐。

三条铁律（守卫 `fushi/test/build/workflow_cache_quota_guard_test.dart`）：

1. **pub cache 只准存一份，由 `subosito/flutter-action@v2` 存。**
   它的 `cache: true` 不只缓存 Flutter SDK，还会额外挂一个
   `Cache pub dependencies` 步骤把 `~/.pub-cache`（Windows 是
   `%LOCALAPPDATA%\Pub\Cache`）存成
   `flutter-pub-<os>-<channel>-<ver>-<arch>-<pubspec.lock hash>`。
   workflow 里再挂 `actions/cache` 存同一个目录只是换个 key 名存第二遍：实测
   `flutter-pub-linux-…-3fa29c49` = 149,357,387 B 与
   `Linux-pubcache-3fa29c49` = 149,365,205 B，同一批字节，三平台白占 447 MB，
   每个作业还要多解压一次（6~32 s）。**不要再加 `Cache pub packages` 步骤。**
   代价说清楚：flutter-action 那条 pub 缓存**没有 `restore-keys`**（实测其
   `actions/cache@v5` 输入里只有 `key`），所以 `pubspec.lock` 一变就是全冷，
   `flutter pub get` 要重下约 150 MB；旧的 `<OS>-pubcache-` 前缀能给个部分命中。
   这是有意取舍：换来的是 447 MB 永久配额 + 每作业少一次解压，而 lockfile 变更
   本来就不频繁，且那时重新解析依赖并不亏。
2. **Gradle 缓存三处必须逐字相同，且缓存步骤排在改 `*.gradle` 的 sed 前面。**
   `hashFiles()` 算的是**当时磁盘上**的内容。`main.yml` / `release.yml` 原先在缓存
   步骤之前就 `sed -i` 删掉了 `build.gradle` / `settings.gradle` 里的 aliyun 镜像行，
   而 `build-multiplatform.yml` 的同名 sed 在缓存步骤之后 —— 于是同一份内容被存成
   两条 key：`Linux-gradle-6facc6ed…`(2,901,298,096 B) 与
   `Linux-gradle-5709404c…`(2,901,388,049 B)，差 89,953 B，白占 2.7 GB。
3. **Gradle 只缓存下载物，不缓存派生产物。**
   `~/.gradle/caches` 全量含 `<ver>/transforms`（解包 AAR / jetify / desugar 输出），
   本机实测 5,073.7 MB，是 `modules-2`(1,937.2 MB) 的 2.6 倍，而它能从 modules-2
   重算。只列 `~/.gradle/caches/modules-2` + `~/.gradle/caches/journal-1` +
   `~/.gradle/wrapper/dists`。key 前缀带 `-v2-` 是为了让 `restore-keys` 够不到旧的
   胖缓存（否则每次先白拉 2.7 GB）。

另外：GitHub 缓存**按 ref 分桶**，`refs/pull/<N>/merge` 与 `refs/heads/develop` 上
同 key 是两条独立记录。正常 PR run 会命中 base 分支的缓存不新存，但仓库一旦超配额、
develop 那条被驱逐，下一个 PR run 就 miss 并在自己的 PR 桶里存一份 —— 越紧越复制，
是正反馈。`.github/workflows/cache-cleanup.yml` 在 PR 关闭时立刻删掉该 PR 桶
（GitHub 自己要等 7 天无访问才回收），并把当前用量写进 step summary。

查用量与逐条明细：

```bash
gh api repos/hajisensai/Fushi/actions/cache/usage
gh api "repos/hajisensai/Fushi/actions/caches?per_page=100"   --jq '.actions_caches[] | "\(.size_in_bytes) \(.ref) \(.key)"' | sort -rn
```

删存量缓存前先确认没有 in-flight 的 run 在用它（`gh run list --status in_progress`）。

**Windows 原生产物不再走 actions/cache，走持久库**（`.github/actions/native-artifact-store`）。
2026-09-29 实测整个缓存约 1 小时换一轮（10.8 GB / 21 条，最老条目 68 分钟前创建；
一条 15:27 存下的 vcpkg 二进制缓存 15:52 就已被驱逐），于是 libtorrent（冷编 20~27 min）
在 37 次桌面发布里 miss 22 次、18 次 PR 门里 miss 15 次，galgame helper / Mihon runtime
大多也在 miss。现在 libtorrent / fushi_p2p DLL、galgame helper dist、Mihon runtime、
fushi-anki-sync 五样按「输入哈希 + runner 镜像 + 工具链钉版」命名，存成 workflow
artifact（不占缓存配额，develop/main 保留 30 天、PR 7 天），下次按名字取；只认本仓
develop/main 产出的件（PR run 另外认同一 PR head 自己产出的件），并先核 SHA256SUMS。
取不到就照旧从源码编，所以它不会重演 TODO-416「跨 workflow artifact 过期即静默缺件」。
vcpkg 的两条 actions/cache 只在 libtorrent 持久库 miss 时才挂。
`release.yml` 的 Android `build` job 同样把 libtorrent `.so`（arm64-v8a）与 fushi_p2p
`.so`（arm64-v8a / armeabi-v7a / x86_64）存进这个库（名字另含实际 NDK 版本、镜像内 vcpkg
修订、Rust / cargo-ndk 钉版与 ABI 列表）：命中时跳过 vcpkg 缓存、Rust 工具链、rust-cache、
cargo-ndk 与两次交叉编（2026-09-30 实测合计约 13 min），恢复件与现编件过同一组产物校验
（`verify_torrent_abi.sh` + AArch64 + 16KB 对齐；`verify_abi.sh` 逐 ABI）。

同一个持久库也覆盖 macOS / iOS / Linux：fushi_p2p（macOS arm64 dylib、iOS device
staticlib、Linux .so）、fushi-anki-sync（macOS arm64 release / 各平台 PR 用的 debug）、
Linux 静态 torrent bridge。规则：

- **名字只有一种算法**：`.github/actions/native-store-names/names.sh`（已提交树的
  `git ls-tree` blob 哈希 + ImageOS/ImageVersion + fushi_p2p Rust 钉版 + job 的 CC/CXX）。
  所有生产方与消费方都 `uses: ./.github/actions/native-store-names`，不许在 workflow 里内联
  拼名字；fushi_p2p 的 Rust 工具链也从它的 `p2p_rust` 输出读。本地干跑：
  `bash .github/actions/native-store-names/names.sh linux`。构建开始读新目录时把它加进
  names.sh 的路径表。
- **每份 PR 门读的件在 develop 上都有生产方**：与发布同名的件（Windows 五样、macOS p2p、
  iOS p2p）由 `release-desktop.yml` 在 develop push 上存；PR 专用变体（三平台 anki-sync
  debug、Linux p2p / 静态 torrent bridge）由 `native-cache-warm.yml` 在 develop push（改到
  输入时，按平台只起需要的 runner）与每日 schedule（补 runner 镜像换代）上 restore → 未命中才
  编 → 跑与 PR 门同一套校验 → 存。build-multiplatform 在 develop 上只有夜间派发的整轮（见下节），
  不能指望它；没有这条的话每条新 PR 首跑都冷编。Linux 的三份件（p2p / 静态 torrent bridge /
  anki-sync debug）的消费方是 `linux-server` job（无头服务端 bundle），不是 Linux app。
- 命中时只跳工具链与编译，ABI 符号表 / FFI 真调用测试 / version 冒烟 / 签名核对照跑在还原出来的
  件上；save 只排在这些校验之后。
- 守卫 `fushi/test/build/native_store_names_single_source_guard_test.dart` 钉死以上几条（含
  「PR 门 restore 的每个件都有同 runner、同 CC/CXX 的 develop 生产方」）。

## 第三方 action 钉 SHA（2026-11-21，拍板 ci-pin-actions）

- `.github/` 下所有外部 `uses:` 一律写成 `owner/repo@<40 位 commit SHA> # <版本>`（`gh api repos/<owner>/<repo>/commits/<tag> --jq .sha` 取 SHA，注释写该提交对应的完整版本 tag）；tag / 分支可被上游强推改写，只有 SHA 不可变。本仓组合 action（`./.github/actions/*`）与 `docker://` 不在此列。守卫 `fushi/test/build/workflow_action_sha_pin_guard_test.dart`。
- 升级交给 `.github/dependabot.yml`（github-actions，覆盖 workflows 与组合 action，每周一合成一个 PR 提到 `develop`），SHA 与版本注释一起改。`dtolnay/rust-toolchain` 钉 master 的 SHA（注释 `# master`，工具链版本由 `toolchain:` 输入决定）并在 Dependabot 里 ignore，需要时手动换 master 最新 SHA。

## PR 主门分层：快门每推必跑，全量按需 / 合并后跑（2026-11-18）

**起因（实测）**：近 3 天 `main.yml`（Build Android APK）占全仓 runner 分钟的 59%，把并发槽顶满——Linux job 排队 p75 29 分钟、p90 56 分钟；一次 PR 运行真正干活约 50 分钟，墙钟中位数 102 分钟、p90 199 分钟，被后一次 push 取消而白烧 2394 分钟。近 7 天各会话为等 CI 纯空等约 27 小时（平均每次 67 分钟）。而 PR 上这份全量，`develop` 每次 push 的 `release.yml` 本来就再跑一遍。

**现在的形态**（`main.yml` 的 `plan` job 决定，判据写在它的注释里）：

| 层 | 跑什么 | 什么时候 |
|---|---|---|
| 快门 | `build`：analyze + JS 测试（`packages/` 有改动时加包测试）；`affected-tests`：目录枚举守卫整批 + 路径字面量点名的守卫 + 直接 import 改动库的测试 + 改动的测试文件 | 进 `develop` 的 PR，每次 push |
| 全量 | `unit-tests` 4 片 + 包测试 + R8 / JVM 校验 | 改了原生 / Android / 插件集合 / pubspec / `fushi/tool/` / workflow 自身；进 `main` 的 PR；fork PR；带 `full-ci` 标签；手动 dispatch；改动清单取不到 |
| 合并后 | `release.yml` 的 4 片单测 + analyze + 包测试 | `develop` / `main` 每次 push（一直如此） |

- **要在某条分支上跑全量**：`gh workflow run main.yml --ref <分支>`（结果挂在同一个 head commit 上，PR 页看得到）；或先给 PR 打 `full-ci` 标签再 push（标签在 push 时读，打完标签不会自动重跑）。
- **快门不是完备的**：只经传递依赖受影响的测试它选不到。回放最近 80 个已合并 PR，按传递 import 闭包选会选中 1400～3000 个测试文件（import 图里有大环），等于全量，所以不做。这类回归在合并后的 `develop` 上由 `release.yml` 暴露，红了按根因修——这正是「批量合并不逐条等 PR CI，合完看 `develop` 尖端」那条规则本来的做法。
- 选测与本地预检 `fushi/tool/pre_push_check.dart` 是同一份实现：从选测里删一条规则，等于从 PR 门里删。CI 上放开了 hub 上限（本地默认跳过「被 40 个以上测试 import 的库」）。
- 回放最近 80 个已合并 PR：72 个会触发主门，其中 50 个走快门、22 个走全量。
- 守卫：`fushi/test/build/pr_tiered_gate_guard_test.dart`（两层互斥、判不出来一律全量、全量 pattern 是 R8 门的超集、合并后的全量兜底还在）。

## PR 平台 job 的路径门（2026-09-30）

`build-multiplatform.yml` 在 `pull_request` 上先跑一个几秒的 `changes` job：拿 PR merge commit
与它的第一个父提交做 `git diff --name-only --no-renames`，按六组正则（`app_common` / `smoke` /
`windows_only` / `macos_only` / `ios_only` / `server_only`，定义与注释都在该 job 里）决定
`windows` / `macos` / `ios` / `linux-server` 开不开。依据是 upstream 09-20..09-30 的 232 条 PR：
只改 Dart / 文档的 153 条吃掉了平台 job 约 62% 的分钟数、零真拦截；仅有的 3 次真拦截（改
`fushi/windows/runner` 的 MSVC / LNK 错误、新增 `native/fushi_p2p` 那条 PR 的 macOS + iOS 链接错误）
全在改原生 / 平台代码的 PR 上。按 09-20 以来 241 条已合并 PR 回放这套路由：Windows 43 次、
macOS 32 次、iOS 25 次、linux-server 95 次（此前每个 job 都是 237 次）。

- **push（main）与手动 `workflow_dispatch` 行为不变**：整轮全开。Android appSmoke 仍只在人手动
  dispatch 时跑。
- **兜底**：① 编译 / 链接——`release-desktop.yml` 在每次 develop push 上就做 Windows / macOS / iOS
  的 release 构建，被路径门跳过的「只改 Dart 的 PR」合进 develop 后照样被编一遍；② appSmoke、
  debug 配置构建与 FFI 真调用测试只在 build-multiplatform 里——它的 `schedule` 每晚（UTC 18:41）
  在默认分支 develop 上整轮跑一次（Android appSmoke 除外，仍只在手动 dispatch 时跑）。2026-11-25
  默认分支改成 develop 之前，定时任务只能跑在落后的 main 上，靠一个 `nightly-develop` 派发器
  转发到 develop，现已删除。
- 改某个平台 job 让它多读一个目录 / 脚本时，同步把它加进对应正则。守卫
  `fushi/test/build/multiplatform_pr_gating_guard_test.dart` 对账「job 正文里调用到的
  `native/` `packages/` `tool/` `tools/` `ci/` `third_party/` `.github/` 路径都被该 job 的路由覆盖」，
  并按样例路径回放路由；它也钉死 Linux app 构建不回来、服务端随包冒烟留在 `linux-server`。
- `fushi/pubspec.yaml` 故意不在路由里：原生插件的增删一定改 `pubspec.lock`；09-20 以来单改它的
  5 条 PR 全是 `+build`、资产目录与纯 Dart 依赖。
- fushidicts 的 gcc-14 ctest 原挂在 Linux app job 上，已搬到 `native-fushidicts-gate.yml` 的
  `ctest-gcc`（与 `ctest-msvc` 并列），只在 `native/fushidicts/**` 或它读的
  `fushi/assets/transforms/**` 变化时跑。

## vendored 二进制

预编译第三方二进制**不入 git**（2026-11-01 起；此前每次重编 libmpv / FFmpeg 都往历史里塞
20–45 MB）。它们放在 `hajisensai/Fushi` 的 GitHub release **`vendored-binaries`** 里，按原路径
gitignore，消费方（Windows CMake 的 MD5 校验、Gradle、podspec / Makefile、galgame / Mihon 脚本、
单测）一行不改：

- **清单** `tool/vendored_binaries.json`：每项 `path / group / size / sha256 / url`。资产名按内容寻址
  `<sha256 前 16 位>-<basename>`，同一路径的每个版本各占一个资产，旧提交照样取到自己那份字节。
  group：`windows`（mpv-dev 7z、ANGLE.7z、libplacebo DLL）、`galgame`（LunaHook/LunaHost DLL）、
  `mihon`（jogamp 离线 Maven 的两个 jar）、`mihon-build` + `mihon-jdk-{linux-x64,linux-arm64,macos-arm64,windows-x64}`
  （Mihon runtime 离线构建包：Gradle 发行包、Gradle 只读依赖缓存、JDK 归档，见下文「发版构建不现场联网」）、`android`（ffmpeg-kit-next.aar、bluray-menu jar）、
  `ios`（iOS libmpv tar.gz、FFmpegKit xcframework 里的 22 个 Mach-O）、`macos`（两个 tar.gz）。
- **取回** `python3 tool/vendored_binaries.py fetch [--group G ...]`（纯标准库，Windows 入口
  `tool/vendored_binaries.ps1`）：已对上的文件只算一遍 sha256；缺的 / 不一致的先查本机缓存
  （`FUSHI_VENDORED_CACHE`，默认 `%LOCALAPPDATA%\fushi\vendored-binaries` / `~/.cache/fushi/vendored-binaries`，
  所有 worktree 共用），再经 `HTTPS_PROXY` 下载；大小或 sha256 不符直接失败，不落盘。只校验不写用 `check`。
  不带 `--group` 时取 `FUSHI_VENDORED_GROUPS`（空格分隔）里的组，没设才取全部：Linux bundle 容器
  （`tool/linux/build_bundle.sh`）设成 `mihon`，否则 bootstrap 会把它用不到的 ~150 MB iOS / Android /
  Windows 件全拉一遍（2026-11-27 正是其中一个 iOS framework 的 HTTP 500 打红了 Linux 发版）。
  - **网络重试（外部 CDN，允许的有界例外）**：只重试传输层失败——连不上 / 超时 / body 比自己的
    `Content-Length` 短（断流）/ HTTP 5xx，共 `DOWNLOAD_ATTEMPTS = 3` 次、退避 2 s × 次数，**每次失败都打一行**
    `<path>: download attempt N/3 failed (...); retrying in Ns`，用完报错退出。HTTP 4xx 与「完整收到但 size /
    sha256 不符」**一次都不重试**：那是错的资产或错的清单，立刻红。
  - **共享缓存并发**：缓存在同一台机器的所有进程间共享（并行 worktree bootstrap、dist_test 的多个 slot），
    每个缓存项 `<sha256>` 由同目录 `<sha256>.lock` 上的 OS 文件锁（`fcntl.flock` / `msvcrt.locking`，持有者
    进程退出即由 OS 释放，不会留下死锁）保护：持锁者下载到唯一临时名再 `os.replace` 进位，读者也在锁内把缓存
    复制成目标旁的唯一临时名，再原子 `os.replace` 到目标——Windows 上不会再有「一边 replace 一边 copy」的
    共享冲突。等锁超过 `LOCK_TIMEOUT_SECONDS`（30 min）直接报错并点名锁文件，不无限等。`.lock` 文件留在缓存里，
    别删（删掉正被等待的锁文件会让两个进程各锁一个文件）。回归：`tool/vendored_binaries_test.py`（由
    `vendored_binaries_manifest_guard_test.dart` 调起：identity 只出 LF、重试策略、多进程同取只下载一次、等锁超时）。
- **谁会调它**：`tool/bootstrap.ps1` / `tool/bootstrap.sh`（`setup_worktree.ps1 -SkipBootstrap` 不取，
  之后要构建 / 测试先跑 bootstrap 或 `tool/vendored_binaries.ps1`）；dist_test worker 的
  `fushi/tool/dist_test/worker_prepare.sh`；CI 用 composite action `.github/actions/fetch-vendored-binaries`
  （`groups:` 输入），紧跟 checkout：`main.yml` build / unit-tests、`release.yml` build / tests、
  `build-multiplatform.yml` android / macos / ios / windows、`release-desktop.yml` windows / macos / ios、
  `ci-config-gate.yml` guards、`native-galgame-gate.yml` guards、`release-desktop.yml` linux（`mihon`）。
  新 job 读这些文件就照抄这一步。不挂 `actions/cache`：配额约一小时换一轮（见上节）。
  **发版 job 加 `durable: 'true'`**（`release-desktop.yml` windows / macos / ios / linux、`release.yml` build，
  守卫钉住）：同一份字节再按内容地址 `vendored-<组>-<digest>`（`vendored_binaries.py digest`）存进原生产物
  持久库，restore 命中就把下载缓存填满、fetch 一个字节都不下；未命中且在 develop / main 上才 save。release 资产
  的 CDN 与 workflow artifact 是 GitHub 的两套后端，一边抖（2026-11-27 release CDN 连续 HTTP 500）另一边还在。
  fetch 仍逐个对清单校验，库里的件喂不进清单没钉的字节。要 `actions: read`。
  native artifact store 的 Mihon / galgame 名字经 `names.sh` 的 `vendored_identity` 折入清单 sha256
  （`git ls-tree` 已看不到这些字节）。
- **从旧分支切回来**：切到仍跟踪这些文件的旧提交再切回，git 会删掉它们，重跑 `fetch` 即可（走缓存，秒级）。
- **release 规则**：`vendored-binaries` 是 prerelease、**永不 Latest**，tag 指向一个只含 README 的无父提交
  （不拖住任何历史，历史重写后仍有效）；发布 workflow 的 `release` 触发只认 `v<数字>` tag，
  `mirror-releases.yml` 不镜像 prerelease。**资产只增不删、不覆盖**——旧提交靠它们构建。

**升级一个二进制**（以 libmpv 为例）：

1. 按原流程构建产物，放到原路径（同时照旧更新它自己的钉值：CMake `LIBMPV` / `LIBMPV_MD5`、
   `SHA256SUMS`、`VERSION.json`、`sha256.json`、`provenance.json` 等）。
2. `python3 tool/vendored_binaries.py register --group windows <新路径>`：写入 sha256 / size / url。
   路径变了（新文件名）就删掉旧条目，并把 `.gitignore` 末尾那段里的旧路径换成新路径。
3. `python3 tool/vendored_binaries.py publish`（需要 `gh` 已登录、对仓库有写权限）：上传 release 里还没有的
   资产，再逐个下载回来比 sha256。
4. 提交清单 + `.gitignore` + 钉值文件，**不提交二进制本身**。守卫
   `fushi/test/build/vendored_binaries_manifest_guard_test.dart` 会把清单与各消费方钉值逐一对账、要求每条路径
   被 `.gitignore` 精确排除且不被跟踪、`third_party/` 与 `native/**/third_party/` 下不得再跟踪 >1 MiB 的文件
   （白名单只有 `m_extension_server/upstream_src` 的上游字体），并钉住上面每个 CI job 的取回步骤。

### 发版构建不现场联网（2026-11-27）

发版构建只依赖 GitHub（跑构建的平台本身）与 Apple（签名 / 公证 / TestFlight），其余第三方服务器不在构建路径上：

- **Mihon runtime**：三端都先按输入哈希从原生产物持久库取（`names.sh` windows / macos / flatpak 分支的
  `mihon` 键；输入含 `third_party/mihon_build`），命中连 JDK 都不碰；未命中才 `fetch-vendored-binaries`
  `mihon-build mihon-jdk-<平台>`（durable）再由 `tool/mihon/build_desktop_runtime.{sh,ps1}` 离线构建：
  解开 vendored Gradle 发行包直接跑（不走 `gradlew`）、vendored 依赖缓存作 `GRADLE_RO_DEP_CACHE`、全新
  `GRADLE_USER_HOME`、`--offline`，缺坐标当场红。依赖变了按 `third_party/mihon_build/README.md` 重新打包。
  守卫 `fushi/test/build/mihon_offline_build_guard_test.dart`。
- **iOS pod**：trunk pod 只允许从 GitHub 取源码、且不带指向别处的子模块；`onnxruntime-*`（`third_party/onnxruntime_pods`）
  与 `UniversalDetector2`（源码收在 `third_party/universal_detector2_pod`，原先子模块在 gitlab.freedesktop.org）
  已本地化。新增 trunk pod 先审 podspec `source`，守卫 `fushi/test/build/apple_pods_offline_guard_test.dart`。
  仍在路径上的第三方：CocoaPods 的 spec CDN（cdn.cocoapods.org → jsDelivr），只在 Pods 缓存未命中时解析 spec 用。
- **vendored 二进制**：release 资产 + 持久库两个来源（见上）。

## 依赖补丁

Flutter 3.50.0 下部分上游依赖未适配，两种补法并存（对个别包**有重叠**）：

- **vendored**：`network_to_file_image` / `carousel_slider` / `fading_edge_scrollview` / `flutter_inappwebview_android`（在 `third_party/`）与 `flutter_inappwebview_windows` / `gamepads_android_stub`（在 `packages/`），经 `dependency_overrides` 的 `path:` 从仓库内解析。`third_party/` 的 fork 必须整包入库（`.gitignore` 用 `!third_party/**/*.xml` 豁免 res/manifest）；新增时把其 pubspec 的 SDK 上界 bump 到 `<4.0.0`。
- **pub-cache 补丁**：`ci/apply-patches.sh` 把 `ci/patches/{hosted,git}/<包-版本>/` 覆盖到 pub cache，按精确版本号命名；版本漂移就跳过并警告（HBK-AUDIT-005）。每次清 cache 或 `pub get` 后要重跑（bootstrap 已含）。
- **Flutter SDK 框架补丁**：同一脚本还把 `ci/patches/flutter-sdk/<frameworkVersion>/*.patch`（`-p1` unified diff）打进当前 SDK（`FLUTTER_ROOT` 或 PATH 上的 flutter）。框架 Dart 会编进 app 快照，不用重编引擎。与 pub-cache 补丁不同，**版本不符直接失败**：升 Flutter 时必须回移或删除这些补丁，否则它修的崩溃会悄悄回来。补丁是幂等的（已打过就跳过），而且改的是本机全局 SDK。来历和删除条件见 `ci/patches/flutter-sdk/README.md`（当前一条：BUG-2839 语义孤儿节点）。

- **Flutter 引擎补丁（仅 Windows）**：`ci/patches/flutter-engine/<版本>/` 是 `flutter_windows.dll` 的源码补丁（flutter 仓库八份按序叠加：`engine-hdr-output` → `engine-underlay-composition` → `engine-impeller-hdr` → `engine-d3d-keyed-mutex`（BUG-3888：外部视频纹理按 keyed mutex 同步，插件见 `FlutterDesktopGpuSurfaceSupportsKeyedMutex` 导出才启用）→ `engine-a11y-tree-hardening`（BUG-4380：无障碍桥从保留的语义数据推出 AXTree、拒收即整树重建，修 Windows UIA 失步崩溃）→ `engine-program-binary-cache`（ANGLE 链好的着色器程序经 `EGL_ANDROID_blob_cache` 落盘，冷启动不再每次把 Impeller 全部管线重编一遍；目录由 runner 经 `FlutterDesktopSetProgramBinaryCacheDirectory` 导出给，`FUSHI_TEST_ROOT` 下落进测试根、否则 `<exe>.ShaderCache` / `%LOCALAPPDATA%\Fushi\ShaderCache\<exe 哈希>`，原版引擎没有该导出就照常编译；守卫 `fushi/test/build/program_binary_cache_engine_guard_test.dart`）→ `engine-resize-before-first-frame`（还没呈现过任何一帧时改窗口尺寸不再在平台线程上干等 100 ms 的 resize 同步超时，冷启动恢复窗口几何 / 最大化就是这条路径；尺寸仍由随后第一帧在 raster 线程落到 surface 上；守卫 `fushi/test/build/resize_before_first_frame_engine_guard_test.dart`）→ `engine-texture-frame-raster-thread`（BUG-5200：外部视频纹理的新帧在生产方线程上直接交给 raster 线程 mark + 重画上一棵层树，不再经平台 / Dart UI 线程和 Animator，主线程忙时视频帧不再被下一帧覆盖丢掉；守卫 `fushi/test/build/texture_frame_raster_thread_engine_guard_test.dart`），外加 ANGLE 一份），让 HDR 视频画在 Flutter 自己的 FP16 scRGB 交换链里（合成器内 HDR，Windows 唯一的 HDR 路径；原版引擎下只能 SDR）。app 全线 Impeller（runner 钉 `ImpellerSwitch::Enabled`），HDR 走的是 Impeller 路径，所以补丁产物必须包含 `engine-impeller-hdr.patch`，否则 HDR 静默退回 SDR。它**不能**像框架补丁那样打进本机 SDK——要重编引擎：`tool/flutter_engine/build_patched_engine.ps1 -Root <工作目录> -PatchVersion <名>`（sync → patch → build → stage → pack；gclient 同步几十 GB、三种模式各编一遍）。产物用 `tool/engine_overlay.ps1 -ArtifactDir <目录>`（或 `-Manifest <artifacts.json>` 下载并校验 SHA-256）装进 SDK 缓存，`-Restore` 还原原版。CI 的 Windows app 构建经 `.github/actions/flutter-engine-overlay` 安装；`artifacts.json` 不存在时用原版引擎构建并打 warning——app 照常跑，runner 运行期报告「合成器 HDR 不可用」、HDR 视频只能 SDR 输出（mpv 色调映射；宿主窗已于 2026-10-18 删除）。**本机日常开发不装也行**，同理回退。升级 Flutter 时补丁要重新对齐基线（守卫 `fushi/test/build/compositor_hdr_engine_guard_test.dart` 要求补丁目录与 `.fvmrc` 同版本），细节见该目录 `README.md`。

> `carousel_slider` / `fading_edge_scrollview` / `network_to_file_image` 两边都有：`dependency_overrides` 生效，pub-cache 同名补丁因版本对不上被自动跳过，以 vendored 为准。

移动端 / Apple 的 libmpv（jar / xcframework 归档；字节在 `vendored-binaries` release，见「vendored 二进制」）在两个 fork 里构建，**CI 都跑在私有镜像仓**：Android `hajisensai/libmpv-android-video-build` → `hajisensai/libmpv-android-build-fushi`（原 fork 的 Actions 被 GitHub 停用，任何触发回 422），Darwin `hajisensai/libmpv-darwin-build` → `hajisensai/libmpv-darwin-build-fushi`（2026-10-24 DVD 重编起，同一做法）。fork 仓保留源码分支与统一 FFmpeg 的 Release（`unified-ffmpeg-9.0.1-r<N>`），构建在镜像仓手动 dispatch；产物来源记在各自 `provenance.json`，当前 fork 补丁与顺序见 `tool/dvd/forks/README.md`。

第三种（native 依赖）：**vcpkg overlay ports**。`native/fushi_torrent/vcpkg-ports/` 是 libtorrent 2.0.11 port 的原样拷贝 + 本仓补丁（DHT 混合代理豁免，P2P 代理混合档依赖它），三个构建脚本（`build_windows_dll.ps1` / `build_android_so.ps1` / `build_android_so.sh`，含 CI）都用 `-DVCPKG_OVERLAY_PORTS` 挂上；overlay 无条件优先于 registry。补丁存在性/引用/挂载由 `fushi/test/torrent/download_http_client_proxy_test.dart` E 组守卫钉住，动机与清理条件见 `native/fushi_torrent/vcpkg-ports/README.md`。

## galgame 引擎-hook 注入器 helper（同仓源码，隔离二进制随 Windows 主包）

galgame 一键制卡的引擎-hook 注入器（injector.exe + hook.dll + vendored LunaHook/Host DLL）含
`CreateRemoteThread`/`WriteProcessMemory`。**源码在本仓 `native/galgame_hook/`**（与
`native/fushidicts/`、`native/fushi_torrent/` 同级）。helper 绝不链接进 `fushi.exe`，运行时仍是
隔离子进程/DLL；但两架构产物在**构建期**就解压进 Windows 主包的 `voice_hook/<arch>/`（BUG-1449），
从而离线首装可用、运行期零网络。

> 历史：这套组件曾整体迁到独立仓库 `hajisensai/hibiki-hook`。迁出的真正根因是 CI——主仓库那份
> workflow 不在默认分支，GitHub 不暴露 `workflow_dispatch` 入口，release 从没被产出过；合仓后
> workflow 就在默认分支 `develop` 上，该问题不复存在。另一条写在红线里的理由「必被杀软报毒」
> 自 C.1 起从未被验证过，**实测已证伪**：Windows Defender（签名 1.455.357.0、实时保护开启、
> runner 全盘排除项已解除）对 helper 全部 13 个文件与两个 zip 零检出，同一轮 EICAR 阳性对照
> 正常报出 `Virus:DOS/EICAR_Test_File`，证明扫描器确实在工作（hibiki-hook#8 的 av-selfscan；证据留在
> `native/galgame_hook/docs/av-selfscan-evidence.md`，该 workflow 已于 2026-08-11 删除，不再复跑）。
> 国产杀软（360/火绒等）未验证，若被拦按误报处理。

- **没有独立的 helper 发布通道了**（2026-08-11 起）：helper 只由 Windows 主包的两个 workflow
  顺带构建并随包落地，不再单独发 release。原先的 `.github/workflows/voice-hook-helper.yml`
  （upsert 固定 tag `voice-hook-helper` 的 prerelease）与 `av-selfscan.yml`（Defender 实扫该
  release 资产）**已一并删除**，`voice-hook-helper` release 本体也已删除。删除的前提是
  `8cd11846fe`（helper/Magpie 全部随包零网络）+ `fb2e2ed685`（BUG-1449 构建期解压随包）之后
  app 侧**再无任何联网取 helper 的代码路径**——`galgame_helper_installer.dart` 里一个 http 都没有。
  - ⚠️ **代价是已知且被接受的**：2026-07-20（`3eb73c880c` 引入按需下载）到 2026-07-26 之间
    发布的 Windows debug 包既没有随包 helper（离线随包 `a3d741778c` 是 07-27 才落地），又把
    `kGalgameHelperRepo = 'hajisensai/hibiki'` 编进了常量（该仓已改名，URL 重定向到
    `hajisensai/Fushi`）。这批包里**没更新过的**用户开 galgame 会撞 404「引擎组件下载失败」，
    症状同 BUG-961，唯一恢复手段是更新到新版。用户 2026-08-11 明确拍板接受此破坏。
  - 更早的一批客户端把 `hajisensai/hibiki-hook` 编进常量，**那个仓库早已不存在**，与本次删除无关。
- **构建入口**：`native/galgame_hook/tools/build_distribution.ps1 -RunTests` 是唯一组包入口，
  cmake 编 x64（`-A x64`）+ x86（`-A Win32`），每架构打 `voice_hook_<arch>.zip`（injector/hook/
  LunaHook/LunaHost，x86 另带 Locale Emulator）+ `.sha256` 侧车，并写入当前 helper 构建输入的
  `voice_hook_source.sha256` 指纹。`build-multiplatform.yml` 与
  `release-desktop.yml` 的 windows job 都调它（`pull_request`/`push` + paths 含 `native/**`），
  所以**双架构编译与 ctest 是 PR 门**；`native-galgame-gate.yml` 另跑那 7 条平台无关的静态守卫。
  产物由 `tools/install_into_bundle.ps1` 校验 archive SHA 与源码指纹后，在构建期解压进 bundle 的
  `voice_hook/<arch>/`，
  Inno Setup 的 `recursesubdirs` 将其纳入安装器。`check_release_policy.ps1` 守卫这条链，禁止
  后续“构建仍绿但安装器漏带 helper”。
- **app 端运行**：正式 Windows 主包已经直接携带 exe 同级 `voice_hook/<arch>/` 普通文件，
  `GalgameHelperInstaller`（`fushi/lib/src/mining/galgame_helper_installer.dart`）只校验必需文件是否齐全；
  注入前 `GalgameHookRuntimeStage` 再按文件内容分版复制到 app data 下的 `voice_hook_runtime/`，避免游戏
  长期持有安装目录 DLL。开发构建若没有当前源码对应的 dist，会在 CMake 安装阶段主动清掉增量 bundle
  中的旧 helper 并明确提示不可用，**不回退网络，也不继续注入旧件**；已安装版本没有后台自更新。
- **Magpie 同样随包唯一来源**（BUG-1292）：两个 Windows workflow 用
  `tools/build_magpie_slim.ps1` 生成 `Magpie-hibiki-slim-x64.zip` + `.sha256`，放进
  `magpie_bundle/`。`MagpieInstaller` 校验后换入 `magpie/`；ARM64 Windows 走系统 x64 模拟。
  缺包、损坏和旧构建会直接报告“安装包不完整/内置组件校验失败”，没有下载确认、镜像兜底
  或后台自更新；正式 Windows 包出现该错误即属于打包或安装损坏。
  与 helper 同款，`fushi/windows/CMakeLists.txt` 有一条 `install(FILES ... OPTIONAL)`
  从仓库根 `dist/` 把归档拷进 bundle，**开发构建也能拿到**（先跑一次
  `pwsh -File tools/build_magpie_slim.ps1`）；`tool/check_release_policy.ps1` 守住两个
  Windows workflow 的组包步骤、`magpie_bundle/` 载荷目录和 sha256 侧车。
