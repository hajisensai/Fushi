## BUG-3735 · macos-coreaudio-no-sound
- **报告**：2026-10-23（用户：mac 播放互联的视频没声音）
- **真实性**：✅ 真 bug，且**与互联无关**——macOS 上 Fushi 播放任何视频都没声音。用户 Mac 为 macOS 27.2（26B5086k）、输出设备 MacBook Air 扬声器。
  - 真 app 开视频诊断日志（`video_mpv_log.txt`）：`--aid=1` AAC 2ch 48 kHz 选上、解码器正常，然后
    `[ao/coreaudio] unable to set the input channel layout on the audio unit ([206][255][255][255]/-50)` →
    `Failed to initialize audio driver 'coreaudio'` → `Could not open/initialize audio device -> no sound`，mpv 停用音轨，只剩画面。经控制通道手动切到音轨 1 也一样。
  - 同一台 Mac 上 Homebrew 原版 mpv 0.41 播本地生成的 H.264 + AAC 立体声测试片同样报 `-50`，`--audio-channels=stereo` / `auto` 都一样；它有声音只是因为自动退到了 `avfoundation`（`AO: [avfoundation] 48000Hz stereo 2ch float`）。
  - 根因：随包 libmpv 的构建配方 `hajisensai/libmpv-darwin-build` `nix/packages/mk-pkg-mpv/video.nix`（`-Dauto_features=disabled`，macOS 只开 `-Dcoreaudio=enabled`）没有编进任何备用音频输出，coreaudio 一失败就无声。产物钉在 `third_party/media_kit_libs_macos_video/macos/Makefile`（`MPV_XCFRAMEWORKS_SHA256SUM`），本仓同款叠加在 `tool/bluray/platforms/patches/darwin-build.patch`。coreaudio 本身的 `-50` 是 mpv / 系统侧的，本仓不可控。
- **[x] ① 已修复** — macOS libmpv 多编 `avfoundation` 音频输出（`-Davfoundation=enabled`）。mpv 默认输出顺序里它紧跟 `coreaudio`，coreaudio 正常的机器行为不变，失败时自动退到 AVSampleBufferAudioRenderer。iOS 仍是 `audiounit`（`ao_avfoundation` 依赖只有 macOS 才有的 CoreAudio 属性代码），不受影响。
  - 构建：`W1ght/libmpv-darwin-build@b2c41c6`（分支 `fushi/avfoundation-ao`，run 39908685651；上游 PR hajisensai/libmpv-darwin-build#3），CI 探针新增要求库里带 avfoundation 输出。
  - 本仓：重新 vendor `third_party/media_kit_libs_macos_video/native/libmpv-xcframeworks-bluray.tar.gz`，同步 `Makefile` 钉的哈希、`provenance.json`、`native/README.md` 与 `darwin-build.patch`。与旧包相比只有 `Mpv` 多链接了系统 AVFoundation / CoreMedia，其余框架依赖与运行时探测（蓝光 / TrueHD / 菜单导航 / render API）一致。
  - 真机验证（用户 Mac）：直接加载新 / 旧 libmpv、按 Fushi 的音频参数播测试片——旧包 `current-ao` 为空、无声；新包 coreaudio 照样 `-50`，随后 `AO: [avfoundation] 48000Hz stereo 2ch float`、`aid=1`。把装机 `fushi.app` 的 `Mpv` 换成新构建（装机 `Mpv` 去签名后与旧包逐字节一致，是干净的 A/B）后播放原互联视频，用户确认有声音。
- **[x] ② 已加自动化测试** — `fushi/test/build/libmpv_macos_avfoundation_ao_guard_test.dart`：解开 vendored 的 macOS 归档，逐个 CPU slice 要求同时有 `AVFoundation AVSampleBufferAudioRenderer` 与 `CoreAudio AudioUnit` 两个 AO 描述串，并要求本仓 Darwin 构建叠加开启 `-Davfoundation=enabled`。红→绿已验（旧包：`desktop:arm64: avfoundation AO missing`；新包通过）。
- **备注**：macOS 构建暂时出自 fork 的提交；上游 PR 合入后可在上游分支重跑同一 workflow 再 vendor 一次，把 provenance 指回 `hajisensai/libmpv-darwin-build`（产物内容应一致）。
