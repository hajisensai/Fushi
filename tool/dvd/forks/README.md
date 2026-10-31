# libmpv fork 的 DVD 改动（已推送、已构建、已 vendor，2026-10-24）

Android / Apple 的 libmpv 在两个 fork 里构建，本仓只放**可直接应用的补丁**和说明：

| fork（CI 所在仓） | 基线 | DVD 分支 `fushi/dvd` 头 | 构建 run | 补丁 |
| --- | --- | --- | --- | --- |
| `hajisensai/libmpv-android-video-build`（CI 跑在私有镜像 `hajisensai/libmpv-android-build-fushi`，原 fork 的 Actions 已被停用） | `fushi/unified-ffmpeg` @ `452510d169c847cbc5bd59ed72602ecc2eb163ce` | `96ac8a57d35c27b1ad2913198aa835046f188726` | 镜像仓 run `40068054506` | `libmpv-android-video-build.patch` |
| `hajisensai/libmpv-darwin-build`（CI 跑在私有镜像 `hajisensai/libmpv-darwin-build-fushi`，与 Android 同一做法） | `fushi/unified-ffmpeg` @ `0f29c43057bbc4faa8f884cce4dd871926129b6e` | `95d986ea08751fd97871defbadb5df9a4ccb189f` | 镜像仓 run `40067864441` | `libmpv-darwin-build.patch` |

两个补丁与 fork 头一一对应：对 fork 头的检出 `patch -p1 -R --dry-run` 干净回退（2026-10-24 实测）。
补丁之外 fork 头还多两样不属于补丁的东西：锁文件指向统一 FFmpeg `unified-ffmpeg-9.0.1-r2`
（Android `buildscripts/unified-ffmpeg.lock`、Darwin `packages.lock.nix` 的 `ffmpeg-unified`），
以及 Darwin 镜像仓需要的 workflow 触发项。

本地应用（只改工作区，不提交、不推送、不触发 workflow）：

```sh
bash tool/dvd/forks/apply.sh android <fork 检出目录>
bash tool/dvd/forks/apply.sh darwin  <fork 检出目录>
```

`apply.sh` 先打补丁，再把本仓 `third_party/media_kit_libs_windows_video/patches/disc-navigation-state.patch`
（v2，带 `dvd-state`，sha256 `6095b222…`）复制进 fork 自己那份补丁的位置。

## 改了什么

**Android**

- `scripts/mpv.sh`：`-Dgpl=true -Ddvdnav=enabled -Ddvda=disabled`。
- `scripts/unified_ffmpeg.sh`：要求 ffmpeg-dev 前缀里有 `libdvdcss.so` / `libdvdread.so` /
  `libdvdnav.so` 及其 `.pc`，并把 `dvdread.pc` / `dvdnav.pc` 按 FFmpeg 的方式改写前缀。这些 `.so`
  就是 AAR 里 libavformat.so 旁边那几份（FFmpegKitNext 补丁 0003），libmpv 只 NEED、不自带。
- `bundle_unified.sh`：libmpv.so 必须 NEED `libdvdnav.so`（**不要求** `libdvdread.so`：mpv 只调
  dvdnav API，`--as-needed` 去掉了直接依赖，libdvdread 经 libdvdnav 的 NEEDED 加载——fork 头
  `96ac8a5` 的修正），配置串含 `-Ddvdnav=enabled`，带 `dvd-state` 字符串，且不能自己定义
  `dvdnav_open`（不许私带一份）。

**Darwin**

- `mk-pkg-ffmpeg-external`：跳过 zip 里的 `libdvd*.xcframework`（不按 FFmpeg 的版本头处理），
  另外为它们生成 `libdvdcss` / `dvdread` / `dvdnav` 的 pkg-config 模块（`-F … -framework libdvd*`），
  头文件取自 framework 的 `Headers`。
- `mk-pkg-mpv/video.nix`：`-Dgpl=true -Ddvdnav=enabled -Ddvda=disabled`。

## 许可

`-Dgpl=true` 是 DVD 菜单的硬前提（mpv 的 `stream_dvdnav.c` 只在 GPL 构建里编译，meson 的
`dvdnav` 要求 `gpl`）。应用本身是 GPL-3.0、统一 FFmpeg 也已是 GPL，分发许可不变；
`native/third_party_licenses/manifest.json` 里 Android / iOS / macOS 的 mpv 条目已随本次 vendor
改为 GPL-2.0-or-later，三个 DVD 库另有 android / ios / macos 条目。

## 已完成的顺序（run id 留档）

1. 本仓 `ffmpeg-unified-mobile.yml` run `40064825841`：三个平台先编 DVD 库，再用补丁 0003 让
   FFmpeg 链接它们；产物发布为 `unified-ffmpeg-9.0.1-r2`（Android 挂在
   `libmpv-android-video-build`、Apple 挂在 `libmpv-darwin-build` 的 Release）。
2. fork 锁文件指到 r2，应用本目录补丁，跑镜像仓构建（Android `40068054506`、Darwin `40067864441`）。
3. 重新 vendor：Android `full-<abi>.jar` 进 `third_party/media_kit_libs_android_video/android/native/bluray-menu-v1/`，
   Darwin 归档进 `third_party/media_kit_libs_{ios,macos}_video/native/`（`verify_darwin_archive.py`
   已要求 Mpv 链 `@rpath/libdvdnav.framework` 且归档里不私带 `libdvd*`），新 AAR / iOS
   xcframework（含 `libdvd{css,read,nav}.xcframework`，podspec 已登记）/ macOS 布局一起换；
   `fushi/test/build` 下按补丁散列钉住产物的 6 条用例转绿。这些二进制**不入 git**（2026-11-01 起）：
   放到原路径后 `python3 tool/vendored_binaries.py register --group <android|ios|macos> <路径>...`
   → `publish`，只提交 `tool/vendored_binaries.json` 与各自钉值（见 `docs/agent/build.md`「vendored 二进制」）。
4. **待定**：四份入库产物（Windows / Android / iOS / macOS）现在都带 `dvdvideo`，满足
   `tool/ffmpeg-unified/capabilities.json` 的提升条件；挪进 `demuxers` 下限需要同时决定
   `staged.configure`（下限没有 configure 槽位）与守卫 `ffmpeg_unified_dvd_guard_test` 的写法，
   未在本轮改。
