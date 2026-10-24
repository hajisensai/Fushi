# 音频 CD：第 6 个 mpv 补丁 `cdda-seek-sector-offset.patch`（`cdda1`，2026-10-25）

## 补丁说明

`third_party/media_kit_libs_windows_video/patches/cdda-seek-sector-offset.patch` 只改 mpv
`stream/stream_cdda.c`（基线 `36abaa32`，上游 master 至 2026-10-25 未修）：

- **问题**：`seek()` 只取 `sec = newpos / 2352`，把扇区内余下的字节偏移丢了，并且没有丢掉
  seek 前那一扇区没读完的数据。原始音频解复用器按 `samplerate / 8` 帧的包对齐 seek
  （`demux_raw.c`），所以 seek 目标几乎总不在扇区边界上：例如盘上第 2 轨起点 17446 扇区
  （232.613 s），解复用器 seek 到 41031328 字节，余 688 字节（172 帧），stream 却从扇区头读，
  之后每个样本都比它的时间戳早 172 帧；mpv 精确 seek 再按时间戳裁边，结果整轨提前 172 帧、
  长度不变——和 cd-paranoia 直读逐样本比对才看得出来（最多 587 帧）。
- **修法**：`seek()` 清掉旧扇区（`data = NULL`），把扇区内偏移记进 `data_pos`；
  `fill_buffer()` 读下一扇区时，seek 之后的第一扇区从 `data_pos` 开始，其余照旧从 0 开始。
  越界 seek 也清掉旧扇区。加了一行 `MP_DBG`（`Seek to sector %d, byte %d within the
  sector.`），既是诊断日志，也是各平台产物里可查的补丁特征串（`verify_darwin_archive.py`）。
- **验收**（真光驱、真盘，`fushi/test/media/music/disc/music_cdda_playback_real_test.dart`）：
  第 2 轨与 `cd-paranoia -r 2` 逐字节相同（偏移 0，未打补丁的 libmpv 提前 172 帧）；轨中 seek 后偏移 0（未打补丁提前 580 帧）；第 2 → 3 轨连播与两轨
  直读首尾相接、逐字节相同。

## 各平台

| 平台 | 状态 | 做法 |
|---|---|---|
| Windows | 已实现、已实测 | `tool/bluray/build_libmpv.ps1` 第 6 个补丁 + `-Dcdda=enabled`；libcdio / paranoia 来自 `tool/cdda/recipe.env` 钉版本与 sha256 的 MSYS2 包，`tool/cdda/fetch_cdio_msys2.py` 解到私有前缀（不往 MSYS2 装包）；随包 `fbdcdio-19.dll` / `fbdcdio_cdda-2.dll` / `fbdcdio_paranoia-2.dll`，许可在 `licenses/fushi-cdda/`（GPL-3.0-or-later，含 `SOURCE.txt`）。归档见 `NATIVE_BUILD.md` 的 `cdda1`。 |
| macOS | 已实现、**未构建** | Darwin fork 本地分支 `fushi/cdda`（基于 `fushi/rdisc` 568c907）：libcdio 2.3.0 / libcdio-paranoia 10.2+2.0.2 的 Nix 配方（只给 macOS）、`patches/mpv-cdda-seek-sector-offset.patch`、macOS `-Dcdda=enabled`。要所有者推到 `hajisensai/libmpv-darwin-build-fushi` 并手动派发 `unified-ffmpeg.yml`，再按下面「重新 vendor」换产物；`verify_darwin_archive.py` 已要求 macOS 产物带 cdda（换产物前用当前随包归档跑它会红，这是预期）。 |
| iOS | 不做 | 没有光驱，也没有可用的 libcdio 设备驱动；`-Dcdda=disabled`，`verify_darwin_archive.py` 拒绝带 libcdio 的 iOS 归档。 |
| Android | 不做 | 没有光驱。Android 构建按名字逐个复制补丁（`tool/bluray/platforms/build_android.sh`、`libmpv-android-video-build.patch`、`apply.sh android` 都不整目录应用），新补丁不进 Android 构建；即使进了，`-Dcdda=disabled` 下 `stream_cdda.c` 不编译。 |
| Linux | 系统 mpv | 源码构建用发行版 `libmpv2`，要带 cdda（`docs/agent/build.md`「Linux 桌面」）；发行版 mpv 没有这个补丁，seek 后会整段提前。 |

`bash tool/bluray/forks/apply.sh darwin <checkout>` 现在也复制 cdda 补丁。

# libmpv fork 的远端原盘改动（`rdisc1`，2026-10-24，**已推送、已构建、已 vendor**）

## 状态（2026-10-24）

| 平台 | 分支 | 提交 | 镜像仓 run | 产物 sha256 |
|---|---|---|---|---|
| Android（三 ABI jar） | `fushi/rdisc` | `faab8d9ac9d8bfd744334b54cbd06db3787f3cac` | `hajisensai/libmpv-android-build-fushi` `40085844759` | arm64-v8a `015524c5…` / armeabi-v7a `e3107aeb…` / x86_64 `3c16b97a…` |
| iOS | `fushi/rdisc` | `568c90717bcf3ba6f0ae65134159790d8d4fcd0d` | `hajisensai/libmpv-darwin-build-fushi` `40085846799` | `3d26e14b…` |
| macOS（arm64） | `fushi/rdisc` | 同上 | 同上 | `cf6b9d66…` |

补丁 sha256 `5edcd0de27d14793204b89754dd18c3d1b3c18e29a6edd19c594ef60c72d2b00`（旧 `6095b222…`）；
产物已 vendor 进 `third_party/media_kit_libs_{android,ios,macos}_video`，provenance / Makefile 钉值已更新；
三端 `disc-remote-access` 字符串已核对，Darwin 归档过 `verify_darwin_archive.py`。真机验证（下面第 4 点）仍未做。
以下是当时的改动说明与步骤，留作复现参考。

远端原盘（`docs/specs/2026-10-24-disc-interaction-handoff.md` 第二期）改了
`third_party/media_kit_libs_windows_video/patches/disc-navigation-state.patch`：

- `bluray-device` 是 `http(s)://` URL 时，它是已配对 host 的盘目录共享根
  （`packages/fushi_engine/lib/sync/disc_share_routes.dart`）；libbluray 用
  `bd_open_files()` 打开——每个文件是一个 mpv stream（HTTP Range，走 app 设置的
  `http-proxy` 中继，TLS 钉扎仍只在 Dart 侧），目录从共享的 `manifest.json` 列出；
- `dvd-device` 是 URL 时，它是共享里的 DVD 镜像，libdvdnav 经 `dvdnav_open_stream2()`
  按块读（VIDEO_TS 文件夹形态无法流式：libdvdnav 7.0 没有文件访问入口）；
- 只读属性 `disc-remote-access`（值 `1`）：app 据此判断这份运行时能不能读远端盘。

导航快照仍是 v2（`native_menu_schema` 不变），Dart 侧 v1 / v2 解析不受影响。
Windows 已按本仓 `tool/bluray/build_libmpv.ps1` 重编并 vendor（`…-dvd1-rdisc1.7z`，
见 `third_party/media_kit_libs_windows_video/NATIVE_BUILD.md`）。**Android / iOS / macOS
的随包 libmpv 已用新补丁重编并 vendor（见上表）**；旧产物不认 URL 设备时 app 在打开前查不到
`disc-remote-access`，会明确提示「本机播放组件暂不支持经网络读取原盘」，不会静默失败。

## 补丁散列一改，哪些守卫会红

`fushi/test/helpers/android_vendored_libmpv.dart` / `darwin_vendored_libmpv.dart` 把随包
产物的 `native_navigation_patch_sha256` 与本仓补丁文件比对（`provenance.json`）。补丁换了、
产物没重编，`fushi/test/build` 下按补丁散列钉住产物的用例必红——这是设计如此，提醒三端
产物必须一起重编。新补丁 sha256 见 `third_party/media_kit_libs_windows_video/native-source-provenance.json`
的 `patch_sha256`。

## 要在 fork 上做的事（需所有者授权，本任务未执行）

起点是两个 fork 的 DVD 头（`tool/dvd/forks/README.md` 表里的 `fushi/dvd` 头：Android
`96ac8a57d35c27b1ad2913198aa835046f188726`、Darwin `95d986ea08751fd97871defbadb5df9a4ccb189f`）。

1. 本地检出 fork 的 `fushi/dvd` 头，跑
   `bash tool/bluray/forks/apply.sh android <检出目录>` /
   `bash tool/bluray/forks/apply.sh darwin <检出目录>`（只改工作区）。
   - Android：复制新补丁到 `buildscripts/patches/mpv/disc-navigation-state.patch`，并让
     `buildscripts/bundle_unified.sh` 要求 `disc-remote-access` 字符串
     （`libmpv-android-video-build.patch`，2026-10-24 对 fork 头 `patch --dry-run` 干净）。
   - Darwin：只复制补丁到 `patches/disc-navigation-state.patch`；产物在本仓
     `tool/bluray/platforms/verify_darwin_archive.py` 验收，它已要求 `disc-remote-access`。
2. 在 fork 上新建分支（建议 `fushi/rdisc`）提交，推到私有镜像仓
   （Android `hajisensai/libmpv-android-build-fushi`、Darwin `hajisensai/libmpv-darwin-build-fushi`），
   手动 dispatch 镜像仓的构建。
3. 重新 vendor：Android `full-<abi>.jar` 进 `third_party/media_kit_libs_android_video/android/native/bluray-menu-v1/`，
   Darwin 归档进 `third_party/media_kit_libs_{ios,macos}_video/native/`，同时更新各自
   `provenance.json` 的 `native_navigation_patch_sha256`、归档散列与 Makefile / Gradle 钉值；
   `fushi/test/build` 下按补丁散列钉住产物的用例转绿即完成。
4. 真机验：Android / Mac 上用 `packages/fushi_engine/tool/disc_share_host_probe.dart` 起一台
   只共享一张盘的 host（或真实互联 host），在 app 里从远端原盘详情页「播放原盘」进菜单。
