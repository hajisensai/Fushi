## BUG-798 · 特殊多声道音频布局(6.1 FLC)无声
- **报告**：2026-07-14（用户：4K FLAC 片源「千与千寻」视频有画面无声，附 `hibiki_error_log (3).txt`）
- **真实性**：✅ 真 bug。根因 `hibiki/lib/src/media/video/video_mpv_config.dart:455`（原 `out['audio-channels'] = config.audioChannels;` 默认透传 `auto-safe`）。
  - 片源 FLAC 音轨为 6.1 布局 `FL+FR+FC+LFE+BL+BR+FLC`（含罕见 `FLC`＝前左中央声道）。
  - mpv 默认 `audio-channels=auto-safe`（media_kit 未覆盖，见 pub-cache `media_kit-1.2.6/.../player/real.dart:2389-2416`）把该源布局**原样当输出目标**透传给 AO；libswresample **无法为含 FLC 的输出布局建重采样矩阵**（FFmpeg 已知限制：FLC/FRC 可在下混输入端处理，不能作输出目标）→ `swr_init` 失败 → 整条音频滤镜链建不起来 → 彻底无声，画面正常。
  - 日志实证：`SWR: Output channel layout '7 channels (FL+FR+FC+LFE+BL+BR+FLC)' is not supported` / `libswresample failed to initialize` / `[af] Cannot convert decoder/filter output to any format supported by the output`。
- **[x] ① 已修复** — `hibiki/lib/src/media/video/video_mpv_config.dart` 新增纯函数 `resolveAudioChannels`：`auto-safe` 不再透传源布局，改下发标准布局白名单 `7.1,5.1,stereo`（高→低有序，末位 stereo 永远兜底）。对齐 mpv 桌面「给标准布局清单、按 AO 实际能力挑最匹配并自动转换（下混/上混）」的做法——环绕设备仍拿到环绕（源 6.1-FLC → 标准 7.1/5.1 重采样，FLC 只在输入端 swr 支持），普通立体声设备下混到 stereo；FLC 奇异布局永不作输出目标 → 不再无声。`stereo`/`mono`（用户显式强制）原样透传，不破坏环绕（Never break userspace）。`buildMpvProperties` 第 486 行改用该解析。提交：<pending>
- **[x] ② 已加自动化测试** — `hibiki/test/media/video/video_mpv_config_test.dart` 新增 `resolveAudioChannels (BUG-798 exotic layout silence)` group（4 例）：auto-safe→白名单、白名单末位 stereo 且不含 FLC/FRC、stereo/mono 透传、buildMpvProperties 显式 stereo 保留；并更新默认断言 `audio-channels == '7.1,5.1,stereo'`。`flutter test test/media/video/video_mpv_config_test.dart` 全绿（54 例）。提交：<pending>
- **备注**：桌面 libmpv（Windows/macOS/Linux）实测受益；音频输出真机验证需用户在原片源上确认声音回来（playback 类改动，本机无法可靠验证音频输出）。回避策略：视频设置→「声道布局」手动切 `立体声` 亦可即时恢复。
