## BUG-4243 · AYN Thor: game stream audio near silent while Fushi has a window on the bottom screen
- **报告**：2026-11-08（用户：Thor 上「Fushi Dual」串流无声；同一游戏串流到不带副屏面板的 `app.fushi.reader` 3.3.0-debug.23080 有声但小）
- **真实性**：✅ 真问题，根因在设备 ROM（外部不可控），不在接收端代码：
  - 接收端音频路径在用户那版（develop `a22b42685a`，release seq 23080）、本分支基线 `1060c38945` 与 HEAD 完全一致（`fushi/lib/src/sync/game_stream_receiver.dart` `prepareGameStreamMediaAudio` / `_applyAudioEnabled`，flutter_webrtc 钉 1.6.2+hotfix.3）；两包的 AudioTrack 创建参数相同（usage MEDIA / content SPEECH / flags 0x900、单声道 48 kHz、frameCount 3844，`dumpsys media.metrics`），WebRTC 输出音量 1.0（logcat `WRVMC::SetOutputVolume ... 1.00`）、播放电平非零。
  - 差别只在 AudioFlinger 的最终增益：Dual 的串流轨 `deviceVolume` 0 ~ 1.7e-3（`G db` -inf / -51 / -37 / -13），用户包 0.88。`STREAM_MUSIC`=15/15、音量组 0 dB、L/R 与 VolumeShaper 0 dB；关掉 Odin 均衡器无变化；主副屏焦点来回切换无变化。
  - 用户点副屏后按音量加：系统设置 `secondary_screen_volume_level` 8 → 10，Dual 串流轨 G -13 → -7.4 dB，主音量不变 → ROM 对「在副屏有窗口的应用」整体套用副屏音量。该设置由 `/system/app/GameAssistant`、`/system/app/OdinSettings` 读写，增益在系统下层施加；develop 自从有串流副屏面板起（`a22b4268` 之后）、本分支伴屏常驻都会触发。
  - 另一半「声音小」与本条无关：解码后的流本身只有约 -31 ~ -44 dBFS（WebRTC playout level 200-900 / 32767，主机游戏会话峰值 0.02-0.14）；Windows process loopback 取的是端点音量之前的游戏混音，主机端换算无误（`application_loopback_capturer.h` float→int16 `v*32767`、`(L+R)/2` 下混、loopback 源关 AEC/AGC/NS `flutter_screen_capture.cc`）。
- **[ ] ① 未修复** — 应用侧无法退出 ROM 的副屏分类；用户解法：点一下副屏再调大音量。文档：`docs/agent/second-screen.md`「已知限制」。响度另需接收端增益（见备注）。
- **[ ] ② 未加自动化测试** — ROM 行为，无可落地的自动化层；真机证据见双屏进度日志「Game stream audio/controller」。
- **备注**：响度改进方向（待用户拍板）：接收端对远端音轨施加增益（flutter_webrtc `Helper.setVolume(gain, track)`，原生侧 0..10），做成串流设置或自动电平；或主机端按端点音量补偿采集电平。
