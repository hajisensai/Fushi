# libmpv fork 的 DVD 改动（待所有者批准后再推）

Android / Apple 的 libmpv 在两个 fork 里构建，本仓只放**可直接应用的补丁**和说明：

| fork | 基线 | 补丁 |
| --- | --- | --- |
| `hajisensai/libmpv-android-video-build`（CI 跑在私有镜像 `libmpv-android-build-fushi`，原 fork 的 Actions 已被停用） | `fushi/unified-ffmpeg` @ `452510d169c847cbc5bd59ed72602ecc2eb163ce` | `libmpv-android-video-build.patch` |
| `hajisensai/libmpv-darwin-build` | `fushi/unified-ffmpeg` @ `0f29c43057bbc4faa8f884cce4dd871926129b6e` | `libmpv-darwin-build.patch` |

本地应用（只改工作区，不提交、不推送、不触发 workflow）：

```sh
bash tool/dvd/forks/apply.sh android <fork 检出目录>
bash tool/dvd/forks/apply.sh darwin  <fork 检出目录>
```

`apply.sh` 先打补丁，再把本仓 `third_party/media_kit_libs_windows_video/patches/disc-navigation-state.patch`
（v2，带 `dvd-state`）复制进 fork 自己那份补丁的位置。两个补丁都对上面的基线做过
`patch --dry-run`，干净应用。

## 改了什么

**Android**

- `scripts/mpv.sh`：`-Dgpl=true -Ddvdnav=enabled -Ddvda=disabled`。
- `scripts/unified_ffmpeg.sh`：要求 ffmpeg-dev 前缀里有 `libdvdcss.so` / `libdvdread.so` /
  `libdvdnav.so` 及其 `.pc`，并把 `dvdread.pc` / `dvdnav.pc` 按 FFmpeg 的方式改写前缀。这些 `.so`
  就是 AAR 里 libavformat.so 旁边那几份（FFmpegKitNext 补丁 0003），libmpv 只 NEED、不自带。
- `bundle_unified.sh`：libmpv.so 必须 NEED `libdvdnav.so` / `libdvdread.so`，配置串含
  `-Ddvdnav=enabled`，带 `dvd-state` 字符串，且不能自己定义 `dvdnav_open`（不许私带一份）。

**Darwin**

- `mk-pkg-ffmpeg-external`：跳过 zip 里的 `libdvd*.xcframework`（不按 FFmpeg 的版本头处理），
  另外为它们生成 `libdvdcss` / `dvdread` / `dvdnav` 的 pkg-config 模块（`-F … -framework libdvd*`），
  头文件取自 framework 的 `Headers`。
- `mk-pkg-mpv/video.nix`：`-Dgpl=true -Ddvdnav=enabled -Ddvda=disabled`。

## 需要所有者拍板的点

1. **`-Dgpl=true`**：mpv 的 `stream_dvdnav.c` 只在 GPL 构建里编译（meson：`dvdnav` 要求
   `gpl`），两端 libmpv 现在是 `-Dgpl=false`（LGPL）。开 DVD 菜单必须改成 GPL 构建。应用本身
   是 GPL-3.0、统一 FFmpeg 也已是 GPL，所以分发许可不变；但
   `native/third_party_licenses/manifest.json` 里 Android / iOS / macOS 的 mpv 条目
   （现写 LGPL-2.1-or-later）要在重新 vendor 时改成 GPL-2.0-or-later。
2. 推送与远端构建：fork 提交、推送，Android 走私有镜像仓手动 dispatch，Darwin 跑 fork workflow。

## 推送后的顺序

1. 跑本仓 `ffmpeg-unified-mobile.yml`（现在三个平台都会先编 DVD 库，再用补丁 0003 让
   FFmpeg 链接它们；`verify_mobile_outputs.py --require-staged` 把关），产物 vendor 进
   `third_party/ffmpeg_kit_next_flutter` / `media_kit_libs_macos_video`，并在
   podspec / Gradle 侧把 `libdvd*.xcframework` / `.so` 一起带上。
2. 把新的 ffmpeg-dev / xcframeworks 产物挂到 fork 的锁文件（Android `unified-ffmpeg.lock`、
   Darwin `packages.lock.nix` 的 `ffmpeg-unified`），应用本目录补丁，跑 fork 构建。
3. 用新 jar / tar.gz 重新 vendor，更新 `provenance.json` 里的补丁散列——
   `fushi/test/build` 下按补丁散列钉住 Android / Darwin 产物的 6 条用例（android_libmpv_lua、
   dolby_vision_bundled 两条、libmpv_mkv_laced_audio 的 Android 一条、libmpv_truehd 两条）
   此时才会转绿。
4. 五端产物都带 `dvdvideo` 之后，把它从 `tool/ffmpeg-unified/capabilities.json` 的 `staged`
   挪进 `demuxers` 下限。
