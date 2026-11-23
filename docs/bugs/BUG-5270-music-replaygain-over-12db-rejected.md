## BUG-5270 · ReplayGain 超过 +12 dB 的曲目按 0 dB 播
- **报告**：2026-11-22（Jellyfin 服务器曲目响度后备的 Windows 集成测试取证时发现：离线副本测得 +14.3 dB，mpv 回读 `volume-gain` 为 0）
- **真实性**：✅ 真 bug。`fushi/lib/src/media/music/mpv_music_output_backend.dart` `musicMpvProperties`（修前）没设 `volume-gain-max`，mpv 默认只准 +12 dB；`_applyGain` 下发的 `volume-gain` 超过上限时 mpv 整个拒掉这次设置（属性的受限类型 `max = volume-gain-max`），停在上一个值 / 0 dB。录得轻的曲目（-30 LUFS 量级的人声、老录音）按 ReplayGain 2.0 的 -18 LUFS 需要 +12 dB 以上，于是本地曲库、服务器曲目与客户端测量后备都会静默不施加增益。
- **[x] ① 已修复** — `musicMpvProperties` 下发 `volume-gain-max=150`（mpv 选项允许的上限）；防削波仍由 `musicReplayGainDb` 按峰值封顶，不靠 mpv 的上限；没有峰值的增益（Jellyfin `NormalizationGain`）正向封顶 +12 dB（`kMusicReplayGainNoPeakMaxDb`，与 mpv 原默认上限相同），免得放开上限后无峰值的大增益削波。
- **[x] ② 已加自动化测试** — `fushi/test/media/music/music_player_engine_test.dart` 断言输出属性带 `volume-gain-max=150`；真 libmpv 端到端由 `fushi/integration_test/music_server_offline_itest.dart`（离线副本按 +14.3 dB 的测量值回读 `volume-gain`）覆盖。
- **备注**：设计文档 §7.3 同步。
