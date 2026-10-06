## BUG-2865 · macOS 下载的内置 torrent 引擎不可用
- **报告**：2026-10-02（用户：「mac 的下载内置引擎不可用」）
- **真实性**：✅ 真 bug。macOS 从来没编过、也没随包过 `libfushi_torrent_ffi.dylib`：
  app 侧把 macOS 算作支持内置引擎的平台（`fushi/lib/src/models/app_model.dart` 的
  `_supportsEmbeddedTorrent`、`anime_download_service.dart` 的同名判据），但
  `EmbeddedTorrentEngine.open`（`packages/fushi_torrent/lib/src/embedded_torrent_engine.dart`
  `_openByPlatformDefault`）在包里找不到库 → `EmbeddedTorrentHost.probeAvailable` 恒 false，
  内置引擎判不可用、只能退外接 qBittorrent。`native/fushi_torrent/README.md` 「尚未做」一节
  早就记着「macOS 桌面版……另起 job」；构建脚本、Runner 构建阶段、CI 步骤三样都不存在，
  `build-multiplatform.yml` 的路由注释还写着「Apple 没有内置 torrent 引擎」。
- **[x] ① 已修复** — 与 Android / Linux 同一决策（vcpkg manifest 静态链）：
  `native/fushi_torrent/build_macos_dylib.sh` + overlay triplet `{arm64,x64}-osx-fushi`
  （部署目标 13.4）出 universal 静态 dylib，CMake Apple 分支只导出 `_ht_*`；Runner 构建阶段
  `fushi/macos/bundle_fushi_torrent.sh` copy-if-present 进 `Contents/Frameworks`；加载器在
  macOS 先按 `<exe>/../Frameworks/` 绝对路径加载；`build-multiplatform.yml` /
  `release-desktop.yml` macos job 构建、出包核对（文件在、universal 两片、无非系统依赖、
  C ABI 齐全）并共用持久库 `torrent` 名；`verify_torrent_abi.sh` 认 Mach-O。
- **[x] ② 已加自动化测试** — `packages/fushi_torrent/test/default_library_candidates_test.dart`
  钉 macOS 加载候选；CI macos job 的「Verify macOS fushi_torrent dylib bundle」核对包内产物，
  并用包里那份 dylib 跑 `packages/fushi_torrent` 全套真 FFI 测试（本地 rig 下载管线）。
- **备注**：iOS 仍无内置引擎（不变）。无头服务端的 macOS 版不在本次范围。
