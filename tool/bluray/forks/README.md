# libmpv fork 的远端原盘改动（`rdisc1`，2026-10-24，**未推送、未构建**）

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
的随包 libmpv 仍是旧补丁编的**：它们不认 URL 设备，app 在打开前查不到
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
