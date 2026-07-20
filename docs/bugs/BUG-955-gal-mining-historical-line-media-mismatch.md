## BUG-955 · 历史行制卡错配当前语音与当前画面且无降级标记
- **报告**：2026-07-21（PR#295 落地审查 M1+M2，fable5）
- **真实性**：✅ 真 bug（代码路径核验）。根因两处：① `hibiki/lib/src/mining/gal_hook_session_controller.dart:761-788` + `galgame_audio_source.dart`（`_findPairedVoiceFile` 的 `textTsMs<=0` 分支）时间戳缺失时兜底取「本会话 mtime 最新语音」，对历史行制卡把当前语音配给旧台词并标 `game_resource` 成功配对，静默错卡；② `gal_hook_mining_coordinator.dart:167-180` 截图抓 mine 时刻当前帧、不绑 lineId，历史行产出「旧台词 + 当前画面」且 `degradedToStill` 不覆盖此情形。
- **[ ] ① 未修复** — 修法方向：历史行禁用「最新语音」兜底（缺配对即警告/留空），截图路径带 lineId 或对历史行显式标注降级。
- **[ ] ② 未加自动化测试** — coordinator/audio_source 单测：历史行 + 无精确配对断言不借用当前媒体。
- **备注**：与 PR#295 设计目标（避免串句/借音）直接相悖，优先级高于一般 M。
