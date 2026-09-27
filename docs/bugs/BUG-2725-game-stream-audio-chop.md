## BUG-2725 · 串流音频断续：回环音频喂送线程长期落后实时
- **报告**：2026-09-26（用户：「现在很卡音频都传不稳」）
- **真实性**：✅ 真 bug。上游 flutter_webrtc `windows/application_loopback_capturer.cc` 的 `FeederThread` 每个 10 ms 周期定时器 tick 只喂 WebRTC 一块 10 ms 音频，只在「超前」时跳过、从不追赶。周期定时器只会慢不会快：本机前台控制台实测 10.3 ms/跳（=实时的 97%），后台 GUI 进程的精度请求被 Windows 忽略时是 15.6 ms/跳（=64%）。欠账让环形缓冲顶到 200 ms 上限，此后每一跳都削掉最老的若干采样——持续的爆音/断续。
- **[x] ① 已修复** — `49376c844bc`：整文件覆盖 `ci/patches/hosted/flutter_webrtc-1.6.2+hotfix.3/windows/application_loopback_capturer.cc`，改为 5 ms 高精度定时器唤醒、按流逝时间欠多少补多少（`fushi/windows/runner/game_stream_audio_feed_clock.h`，单次上限 8 块、欠账超 300 ms 重锚）；预缓冲 160→100 ms（音视频同一 MediaStream，唇同步会把画面一起延后）。真机：串流 trace 的音频包率稳定 50 pps（20 ms/包 = 实时）。
- **[x] ② 已加自动化测试** — `fushi/windows/runner/tests/game_stream_audio_feed_clock_test.cpp`（5/10/10.3/15.6/33 ms 定时器下 10 秒都交付 997～1000 块、不超前、突发上限、长停顿重锚），由 `tool/run_game_stream_capture_test.ps1` 构建运行。
- **备注**：补丁机制是整文件覆盖，升级 flutter_webrtc 时须随版本目录一起迁移或删除。
