# DVD 原生依赖（libdvdcss / libdvdread / libdvdnav）

设计依据：`docs/specs/2026-10-24-dvd-original-menu.md`（D6：libdvdcss 随包，五端一致）。

| 文件 | 作用 |
| --- | --- |
| `recipe.env` | 三个库的版本、VideoLAN tarball URL 与 SHA256（唯一真相源，守卫 `fushi/test/build/ffmpeg_unified_dvd_guard_test.dart`） |
| `build_dvd_libs.sh` | 按配方下载、校验散列、meson 构建 libdvdcss → libdvdread（`-Dlibdvdcss=enabled`，即旧 `--with-libdvdcss`）→ libdvdnav，装进一个前缀；构建后用 `config.h` 证明 libdvdread 真链了 libdvdcss |
| `platforms/build_cross.sh` | Android（三个 ABI）/ iOS（真机、模拟器）/ macOS arm64 的交叉构建，产出 `dvd-dev-<target>.tar.gz` |
| `make_test_dvd.py` | 用 dvdauthor + spumux + FFmpeg 从零编一张**无加密**菜单 DVD（VMGM 标题菜单 3 个按钮、VTSM 根菜单、2 个标题），供探测与菜单渲染对拍 |

许可：三个库都是 GPL-2.0-or-later（源码头 "either version 2 ... or (at your option) any later version"），
与 Fushi 的 GPL-3.0 兼容；登记在 `native/third_party_licenses/manifest.json`，原文在
`native/third_party_licenses/texts/dvd/`。

## 只此一份

播放器（libmpv `-Ddvdnav=enabled`，`dvd://` 菜单导航）与统一 FFmpeg
（`--enable-libdvdnav --enable-libdvdread`，`dvdvideo` demuxer，供片段导出 / 截图 /
字幕提取经 `DvdFfmpegBackend` 使用）链接同一组共享库：

- Windows：`tool/ffmpeg-unified/windows/build_ffmpeg_msys2.sh` 先把 DVD 库装进统一 FFmpeg
  的私有前缀，再 configure FFmpeg；`tool/bluray/build_libmpv.ps1` 用同一个前缀的 pkg-config；
  `package_libmpv.py` 要求三个 DLL 各从该前缀解析一次（改名为 `fbddvd*.dll`），并写
  `fushi-dvd` 来源记录与许可原文。
- 移动端 / macOS：`tool/ffmpeg-unified/mobile/build_{android,ios,macos}.sh` 先用
  `platforms/build_cross.sh` 编出每个目标的共享库前缀，再以 `FUSHI_DVD_ROOT` 交给
  FFmpegKitNext；kit 补丁 `tool/ffmpeg-unified/patches/ffmpeg-kit-next/0003-*` 让 FFmpeg 对这些
  共享库 configure `--enable-libdvdnav --enable-libdvdread`，并把它们放到 libav* 旁边：
  Android 的 `.so`（meson 对 Android 宿主不带版本号，`DT_SONAME` 就是 `libdvdnav.so`）由
  ndk-build 打进 AAR；Apple 的 dylib install name 是 `@rpath/<lib>.framework/<lib>`，
  `platforms/make_xcframeworks.sh` 组装 `libdvd*.xcframework` 一起放进 xcframework zip /
  macOS 布局。libmpv fork 链接的就是这同一份（`forks/`）。

`dvdvideo` 目前登记在 `tool/ffmpeg-unified/capabilities.json` 的 `staged` 区：新构建
（`build_libmpv.ps1`、`build_macos.sh` 调 `verify_ffmpeg_capabilities.py --require-staged`，
移动端 CI 调 `verify_mobile_outputs.py --require-staged`）必须带；已随包（vendored-binaries 清单钉住）的产物不被它判红。
**提升条件**：Windows（2026-10-24 已带，`…-dvd1.7z`）、Android AAR、iOS xcframework、macOS
`ffmpeg-unified-macos.tar.gz` 四份 vendored 产物**全部**带上 `dvdvideo` 后，才把它挪进 `demuxers`
下限并删掉 `staged` 里的这一项（Linux 用系统 FFmpeg，不在 vendored 产物之列）。

## 运行时探测

`tool/bluray/probe_libmpv.py <libmpv> [--dvd <VIDEO_TS 或 .iso>]`：报告 `dvd://` 协议与
随 libmpv 一起映射进进程的 libdvdnav / libdvdread / libdvdcss 模块；**缺任何一个直接失败**
（缺 libdvdcss = 只能读无加密盘，不降级）。`--dvd` 另外打开一张盘，记录 v2 导航快照
（`disc-navigation-state-json` 的 `dvd-state`）。

`tool/bluray/verify_menu_render.py --dvd <盘> --min-highlight 0.9`：ANGLE 离屏渲染，每张
截图按快照里的按钮矩形（经 `osd-dimensions` 换算，DVD 像素是变形的）与选中态调色板核对
高亮确实画出来了。

## 实测（2026-10-24，Windows x64）

- `build_dvd_libs.sh`（MSYS2 MINGW64）：libdvdcss 1.6.0 / libdvdread 7.1.1（+libdvdcss）/
  libdvdnav 7.0.0；`libdvdread-8.dll` 导入 `libdvdcss-2.dll`，`libdvdnav-4.dll` 导入
  `libdvdread-8.dll`。
- 统一 FFmpeg 9.0.1 重编（`--enable-libdvdnav --enable-libdvdread`）：`ffmpeg -demuxers` 出现
  `dvdvideo`；`verify_ffmpeg_capabilities.py --require-staged` 通过。
- libmpv（`-Ddvdnav=enabled -Ddvda=disabled` + 本次 `disc-navigation-state.patch`）：
  `build_libmpv.ps1` 全部校验通过（能力下限、probe、mkv lace/dts、DV P5）；`probe_libmpv.py`
  的 DVD 段 `errors: []`，模块 `fbddvdnav-4.dll` / `fbddvdread-8.dll` / `fbddvdcss-2.dll`。
- `make_test_dvd.py` 编出的测试盘：`dvd://menu` 打开后 v2 快照为 `disc-type: dvd`、
  `domain: VMGM`、`still: true`、按钮 1/3、矩形 80,360–240,400、选中色 0xFFFFDF00；
  `verify_menu_render.py --dvd` 中 `discnav right` / `left` 让高亮在按钮 1 → 2 → 1 之间移动，
  截图中按钮区域按调色板着色。
- `dvdvideo`：`ffprobe -f dvdvideo -title 1` 读出 6 s、3 个章节（0 / 1.8 / 4.2 s）；
  `-chapter_start 2 -chapter_end 2` 只读第 2 章（`packages/fushi_engine/test/media/video/dvd_ffmpeg_input_test.dart`
  的真实用例）。
- 目录形态的盘上 libdvdread 每次打开都会以 error 级别打出 "Could not open ... with libdvdcss /
  CSS authentication not available"：它先按设备试 libdvdcss、失败后回退到文件读取，盘照常
  打开。这几行在 mpv 里的前缀是 `dvdnav/libdvdnav`，不是打开失败（Dart 的
  `isVideoDiscOpenFailureLog` 只认 `bd` / `dvdnav` / `stream`）。

- 菜单闭环（`verify_menu_render.py --dvd --min-highlight 0.9`，动作 right → select →
  title-menu）：VMGM 菜单 generation 1 → 选中按钮 2 进入 `VTS` title 1 第 2 章（generation 2，
  其后换到第 3 章 generation 不变）→ 片尾 post 命令回到 VMGM（generation 3）；四张带高亮的
  截图里按钮矩形内 100% 是选中色。

- 蓝光回归（换入库归档前，README 要求）：`verify_menu_render.py --disc` 对本机可读的
  Kaguya Disc 2 测试副本，新旧两份 libmpv 的快照序列一致（first-play → playlist 1001 的 HDMV
  IG 菜单，`right` 把焦点移到「チャプター」，截图同一菜单）；另一张 BD（響け！特別編）在隔离
  探针里新旧都打不开（没有 app 侧的 AACS），表现一致。通过后已换入库归档：
  `mpv-dev-…-fushi-discnav2-hwcrop1-lua1-mkvlace1-mkvdts1-dovi1-ffu2-dvd1.7z`。

没有测过：加密商业 DVD（本机无样本）、ISO 形态、多角度、真实商业 DVD 菜单的高亮对拍。

### Apple（2026-10-24，SSH 到本机 Mac，Xcode 26.6，pip 装的 meson 1.12.1 / ninja）

`platforms/build_cross.sh` 的 `macos-arm64` / `ios-arm64` / `ios-simulator-arm64` 三个目标都编过：
dylib 的 install name 与 libdvdnav → libdvdread → libdvdcss 的引用全是 `@rpath/…`，`vtool`
报 `platform IOS`；macOS 上 `dlopen(libdvdnav.4.dylib)` + `dlsym(dvdnav_open)` 成功。iOS 版
libdvdcss 1.6.0 原样编不过（`ioctl.c` 在没有 IOKit DVD 客户端的系统上 `#error`），由
`patches/libdvdcss/0001-no-drive-ioctls.patch` 在 `FUSHI_DVDCSS_NO_DRIVE`（只有 iOS 目标定义）
下让 ioctl 报失败——iOS 只读镜像文件，镜像的 CSS 走密钥破解、不经 ioctl。**iOS 上加密 ISO 的
实际解密没有测过。** App Store 不收裸 `.dylib`，iOS 随包时要由 libmpv / FFmpegKitNext 的打包步骤
包成 framework。

**FFmpegKitNext 实编（同一台 Mac，工具链全部装在 /tmp，未动 brew）**：`build_macos.sh`
（293 s）与 `build_ios.sh`（693 s）在 kit 补丁 0003 下都编过。macOS 布局里 `libavformat`
链 `@rpath/libdvdnav.framework/libdvdnav` 与 `@rpath/libdvdread.framework/libdvdread`，
`libdvd*.framework` 与 libav* 并列；`verify_ffmpeg_capabilities.py --require-staged`
（`staged=dvdvideo`）、`smoke-test.sh`、`https_trust_smoke.sh` 全部 PASS；布局里的 ffprobe 用
`-f dvdvideo -title 1` 读自制盘得到 6 s / 3 章，ffmpeg 抽出第 2 章一帧。iOS 的 xcframework zip
带 `libdvd{css,read,nav}.xcframework`（ios-arm64 + ios-arm64_x86_64-simulator，含 Headers），
`verify_mobile_outputs.py ios --require-staged` OK。

### Android（2026-10-24，Mac 上，NDK r27d 解压到 /tmp，无 sudo）

`build_cross.sh` 三个 ABI（arm64-v8a / armeabi-v7a / x86_64）都编过：`DT_SONAME` 为
`libdvdcss.so` / `libdvdread.so` / `libdvdnav.so`，`libdvdnav.so` NEED `libdvdread.so`、
`libdvdread.so` NEED `libdvdcss.so`，LOAD 段按 16 KB（0x4000）对齐。Windows 宿主上的 meson 拒绝给
Android（POSIX）宿主用 `C:/` 前缀，所以脚本只在 Linux / macOS 宿主跑。FFmpegKitNext 的
Android 整包（Gradle + AAR）没在本机编，留给 CI。

## 已完成：移动端 / Apple 产物（2026-10-24）

- **移动端 CI**：`ffmpeg-unified-mobile.yml` run `40064825841`（三平台先编 DVD 库，
  `verify_mobile_outputs.py --require-staged` 通过），发布为统一 FFmpeg `unified-ffmpeg-9.0.1-r2`。
  入库：`third_party/ffmpeg_kit_next_flutter/android/libs/ffmpeg-kit-next.aar`（每 ABI 带
  `libdvd{css,read,nav}.so`）、iOS `Frameworks/libdvd{css,read,nav}.xcframework`（podspec
  `vendored_frameworks` 已登记）、`media_kit_libs_macos_video/native/ffmpeg-unified-macos.tar.gz`
  （`Frameworks/libdvd*.framework` 与 libav* 并列，Makefile `UNIFIED_FFMPEG_SHA256SUM` 已换）。
- **libmpv fork**（`-Dgpl=true -Ddvdnav=enabled`）：Android `fushi/dvd` @ `96ac8a5`，私有镜像
  `hajisensai/libmpv-android-build-fushi` run `40068054506`；Darwin `fushi/dvd` @ `95d986e`，私有镜像
  `hajisensai/libmpv-darwin-build-fushi` run `40067864441`。入库产物的 libmpv.so NEED
  `libdvdnav.so`、Mpv.framework 链 `@rpath/libdvdnav.framework/libdvdnav`，配置串含
  `-Dgpl=true … -Ddvdnav=enabled`，带 `dvd-state`；来源记录在各自 `provenance.json`，细节见 `forks/README.md`。
- **`dvdvideo` 提升条件已满足**：Windows / Android 三 ABI / iOS 两片 / macOS 布局的 libavformat
  都带 `dvdvideo`（2026-10-24 逐份核对）。挪进下限需另定 `staged.configure` 的去处，未在本轮改。

## 未完成（未验证）

- **真机 / 模拟器**：Android / iOS / macOS 上 DVD 菜单的实际播放没有跑过（入库产物只做了结构、
  链接与字符串校验；Darwin 的 host probe 不含 DVD 段）。
- **Linux**：用系统 libmpv / FFmpeg（Debian 的 libmpv2 已带 dvdnav）；加密盘需要系统装
  libdvdcss（Debian 走 contrib 的 `libdvd-pkg`）。以 `probe_libmpv.py` 的探测结果为准。
- **iOS 上架风险**：判据预留在 `fushi/lib/src/models/store_compliance.dart` 的
  `dvdCssDecryptionAvailableOn`（现为五端 true）。
