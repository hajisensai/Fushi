## BUG-5597 · tts-srs-modules-in-max-import-cycle
- **报告**：2026-11-27（批量合并 PR #4578 / #4580 时发现，非用户报告）
- **真实性**：✅ 结构性隐患。`fushi/lib/` 最大 import 环（`import_cycle_guard_test.dart`，上限 617）里整块挂着两个模块，都是因为模块里的页面直接 import `AppModel`：
  - 有声书 TTS：`fushi/lib/src/media/audiobook/tts/gpt_sovits_local_page.dart`、`irodori_local_page.dart`、`voicevox_local_page.dart`、`irodori_voice_pack_page.dart` 直接 import `src/models/app_model.dart`，`tts_voice_settings_page.dart` 又 import 这些部署页，于是朗读声音页、制作台、未配音页、角色台词页等 11 个文件都在环里。PR #4578 新拆的「添加声音」流程文件因此一进来就让环 617→618，合并时只能折回 `tts_voice_settings_page.dart`。
  - 复习：`fushi/lib/src/srs/srs_providers.dart:40` 直接 import `app_model`，复习首页及捐赠三件（`srs/donation/srs_donation_{banner,page,providers}.dart`）全在环里（PR #4580 审查结论）。
- **[ ] ① 未修复** — 方向：部署页 / `srs_providers` 改为依赖窄接口（照 PR #4580 的 `AiringCalendarHost`、`LibrarySubtitleFillOcrPrepare` 做法），AppModel 只在装配处出现；拆完把 `kMaxCycleFiles` 按实测下调。
- **[ ] ② 未加自动化测试** — 现有 `import_cycle_guard_test.dart` 棘轮即判据；拆完下调上限。
- **备注**：不是 bug 行为，是新文件一进这两个模块就被算进大环、逼着把代码塞回大文件的结构问题。
