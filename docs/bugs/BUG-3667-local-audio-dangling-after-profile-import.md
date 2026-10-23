## BUG-3667 · 导入别的设备的配置方案后，本地发音库成了悬空引用，互联同步也修不好
- **报告**：2026-10-23（应用内反馈 -5lhI1miwl，Android vivo 3.0.0：互联同步词典与书籍后导入电脑端的配置方案，手机点词朗读无声、制卡无单词发音）
- **真实性**：✅ 真 bug（部分）。
  - 原假设「配置方案把桌面专属 TTS 引擎 / 声音带到 Android」不成立：`tts_voice_presets` / `tts_active_preset_id` / `mining_tts_fallback_voice` 都在 `SyncRepository.deviceLocalPrefKeys`（`fushi/lib/src/sync/sync_repository.dart:1868-1871`），经 `PrefRedactionPolicy.isDeviceLocalOrCredential` 被 Profile 快照与分享 JSON 剔除。
  - 实际：配置方案带走的是 `audio_source_configs` + `local_audio_dbs`（不在剔除名单），它们引用电脑上的发音库内部副本 `local_audio_<数字>.db`；配置方案文件不带 `.db` 本身。手机按文件名归一到本机库目录后找不到文件（截图「发音库文件不可用」），查词发音只走已配置音源（`lookup_audio_playback.dart` 无 TTS 兜底，与 Hoshi 一致），于是无声；制卡第 1、2 步同样落空。
  - 真缺陷：这条悬空引用**挡死了互联同步的修复路径**。发音库按 displayName 跨设备对齐，而
    1. `fushi/lib/src/sync/sync_orchestrator/local_audio.part.dart:23`（live）与 `fushi/lib/src/sync/sync_orchestrator.dart:1551`（包路径）把同名悬空条目算作「本端有」→ 远端那份永不进 toPull；
    2. 即使拉下来，`AppModel.importSyncedLocalAudioDb`（`fushi/lib/src/models/app_model.dart:9890` 起）见同名就跳过；
    3. host 侧 `LocalLibraryHostService.listLocalAudio` 会把本机没有文件的库列给对端，对端来拉时 `exportLocalAudio` 必然 StateError；推送路径用的是存储 path（可能是源机绝对前缀）判存在。
- **[x] ① 已修复** — 同步侧统一认「本机真实落点」：`LocalAudioManager.entriesOnThisDevice` / `AppModel.localAudioDbsOnThisDevice`（path 经 `resolveInternalPath` 归一）喂给 orchestrator 与 host；两条同步路径的 localNames 只收文件在本机的条目；host 清单只列文件在本机的库；`importSyncedLocalAudioDb` 遇到同名但本机不可用的条目时落库并**原位改指**（保留列表位置、开关、子来源偏好），不追加同名新源。提交见本分支 `fix(audio): let sync repair local audio refs imported from another device`。
- **[x] ② 已加自动化测试** — `fushi/test/models/app_model_synced_local_audio_test.dart`（悬空同名条目原位改指）、`fushi/test/sync/sync_orchestrator_live_audio_test.dart`（悬空同名条目不挡 pull）。两条均做过变异实测：还原旧判据后分别红在「目录仍是源机路径」「localAudioImported 0 ≠ 1」。
- **备注**：
  - 没改：Android 系统语音兜底（`TtsChannelHandler.java:69` 初始化只认日语、`TtsChannel.ttsToFile` 默认 `ja-JP`）在没装日语语音数据的 ROM 上整段返回 null 且不留日志——反馈人看起来在学英语（发音库名 `android_english…`、Edge 声音 `en-US-AriaNeural`），这会让「制卡发音兜底=系统语音」也落空。语言怎么定（无全局目标语言）需决策，已回报。
  - 没改：配置方案导入时把本机已有的同名发音库直接接上（避免一次重复下载）。现在的修复路径是「再跑一次互联发音库同步」。
  - 未做真机复测。
