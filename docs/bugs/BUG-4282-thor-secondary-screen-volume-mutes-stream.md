## BUG-4282 · AYN Thor: game stream audio near silent while Fushi has a window on the bottom screen
- **报告**：2026-11-08（用户：Thor 上「Fushi Dual」串流无声；同一游戏串流到不带副屏面板的 `app.fushi.reader` 3.3.0-debug.23080 有声但小）
- **真实性**：✅ 真问题，根因在设备 ROM（外部不可控），不在接收端代码：
  - 接收端音频路径在用户那版（develop `a22b42685a`，release seq 23080）、本分支基线 `1060c38945` 与 HEAD 完全一致（`fushi/lib/src/sync/game_stream_receiver.dart` `prepareGameStreamMediaAudio` / `_applyAudioEnabled`，flutter_webrtc 钉 1.6.2+hotfix.3）；两包的 AudioTrack 创建参数相同（usage MEDIA / content SPEECH / flags 0x900、单声道 48 kHz、frameCount 3844，`dumpsys media.metrics`），WebRTC 输出音量 1.0（logcat `WRVMC::SetOutputVolume ... 1.00`）、播放电平非零。
  - 差别只在 AudioFlinger 的最终增益：Dual 的串流轨 `deviceVolume` 0 ~ 1.7e-3（`G db` -inf / -51 / -37 / -13），用户包 0.88。`STREAM_MUSIC`=15/15、音量组 0 dB、L/R 与 VolumeShaper 0 dB；关掉 Odin 均衡器无变化；主副屏焦点来回切换无变化。
  - 用户点副屏后按音量加：系统设置 `secondary_screen_volume_level` 8 → 10，Dual 串流轨 G -13 → -7.4 dB，主音量不变 → ROM 对「在副屏有窗口的应用」整体套用副屏音量。该设置由 `/system/app/GameAssistant`、`/system/app/OdinSettings` 读写，增益在系统下层施加；develop 自从有串流副屏面板起（`a22b4268` 之后）、本分支伴屏常驻都会触发。
  - 另一半「声音小」与本条无关：解码后的流本身只有约 -31 ~ -44 dBFS（WebRTC playout level 200-900 / 32767，主机游戏会话峰值 0.02-0.14）；Windows process loopback 取的是端点音量之前的游戏混音，主机端换算无误（`application_loopback_capturer.h` float→int16 `v*32767`、`(L+R)/2` 下混、loopback 源关 AEC/AGC/NS `flutter_screen_capture.cc`）。
- **ROM 判定规则（2026-11-08 反编译 + 真机核实）**：
  - 施加点在 AudioFlinger（ROM 改过的 `libaudioflinger.so`，字符串 `sys.audio.uids` / `persist.sys.audio.value` /
    `updateSecondDisplayAppUids`）：uid 在系统属性 `sys.audio.uids` 名单里的所有轨，最终增益乘
    `persist.sys.audio.value`（OdinSettings 按 `secondary_screen_volume_level` 写，15 档 = 1000000 = 1.0）。与 usage /
    AudioAttributes / 播放器类型无关，按 uid 整体生效。
  - 名单由 `GameAssistant` 的 `com.ro.gameassistant.service.MultiDisplayVolumeControl` 写（`c(List,String[])` →
    `SystemProperties.set("sys.audio.uids", …)`，随后 `setStreamVolume(3, 当前值, 0)` 让 AF 重读）。重算时机：
    AudioService 每次 requestAudioFocus / abandonAudioFocus 成功后 `notifyAppFocusChange(0x401/0x402)` 经 binder
    服务 `MultiDisplayVolumeControl` 通知；以及 `ForegroundAppMonitorV4Service` 前台变化。
  - 名单内容 = ① `getAllRootTaskInfos()` 里 `displayId == 副屏` 的根任务顶部 Activity 的 uid（`m1.a.a`，排除
    systemui / launcher3）；② 再按**焦点栈顶持有者**修正（`d(List)`，读 ROM 加的隐藏
    `IAudioService.getCurrAudioFocusInfo()` = `"包名,displayId,uid"`）：displayId == 副屏 → 加入；displayId == 0 →
    **移出**；没有 displayId（字符串无逗号）→ 不动。
  - 焦点持有者的 displayId 在**请求焦点那一刻**定格（services.jar `MediaFocusControl.requestAudioFocus` 里，
    `mCurrWMFocusActivityInfo.second.packageName` 等于请求包名时 `updateFocusRequesterActivityInfo`）。
    `mCurrWMFocusActivityInfo` 来自 WM `DisplayContent.setFocusedApp` → `reportFocusedDisplayIdToAudio` →
    `AudioService.reportFocusedDisplayId(displayId, ActivityInfo)`，即**全系统最近一次「某块屏的 focused app 变了」**，
    不是触摸焦点（所以来回点两块屏不改变结果，`setFocusedApp` 同一 Activity 直接 return）。
  - 本应用触发条件：`SecondScreenDisplay` 在宿主每次 onStart 都重新 `startActivity` 面板（stop 时 finish），伴屏 /
    串流面板换模式也是新 ActivityRecord，所以面板永远是「最近一次 focused app 变化」→ 之后的媒体焦点请求定格为
    `(4, SecondScreenActivity)` → uid 留在名单里。
  - 真机验证：translucent 的系统 chooser 盖到主屏再 Back（宿主只 pause 不 stop，面板不重启）后，
    `reportFocusedDisplayId` 最近一次变为 `(0, MainActivityDefault)`；随后的串流焦点请求让 `sys.audio.uids` 由
    `10132` 变为空，串流轨不再受副屏音量影响。
  - 本地视频（media_kit / OpenSL ES 播放器）播放时焦点栈为空（不申请音频焦点），只剩规则 ①，所以有副屏面板时
    视频永远被衰减；串流（flutter_webrtc `AudioSwitchManager` 申请 GAIN）则取决于申请时刻的顺序，正常流程下也被衰减。
- **[ ] ① 未修复（无干净的应用层修法）**：规则是 ROM 私有的时序判定，没有公开 API / 清单开关 / 白名单可退出。
  候选方案与代价：(a) 副屏面板改用 `Presentation`（不在副屏建任务）——按上面规则可彻底避开，但要放弃面板的独立
  Activity + `:second_screen` 进程（词典 WebView 与 AppModel 隔离依赖它），是大改，需拍板；(b) 每次请求媒体焦点前
  用透明跳板 Activity 把主屏 focused app 刷新一次——依赖 ROM 内部时序的特例 hack，宿主会走 pause/resume（Flutter
  inactive），不做；(c) 读 `sys.audio.uids` / `persist.sys.audio.value` 自行补偿——Thor 专用硬编码，且 AF 轨音量上限
  1.0，不做。用户解法：点一下副屏把副屏音量调到最大（15 档 = 增益 1.0，等同不衰减）。文档：
  `docs/agent/second-screen.md`「已知限制」。响度另需接收端增益（见备注）。
- **[ ] ② 未加自动化测试** — ROM 行为，无可落地的自动化层；真机证据见双屏进度日志「Game stream audio/controller」。
- **备注**：副屏音量 15 档时 ROM 增益为 1.0，实测不再衰减；串流仍偏小是**源电平**问题：同一游戏同一场景下 Thor 与 Galaxy S23 Ultra 的 WebRTC playout 电平相同（约 200–230 / 32767），S23 听感大是其机内音效 / 功放链路放大。用户拍板（2026-11-08）：本分支保留接收端「串流音量」滑块（100–500%，默认 100%，`Helper.setVolume`），只在双屏设备（`SecondScreenHost.available`）上显示，单屏设备增益恒为 1.0；记为已知限制（`docs/agent/second-screen.md`「已知限制」：每台接收端都偏小，滑块是当前缓解）。主机端按端点音量补偿采集电平与 Windows 前台输入「input was rejected」修复未做（用户叫停）；不做焦点跳板 hack。
