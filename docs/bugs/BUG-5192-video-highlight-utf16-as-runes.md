## BUG-5192 · 视频字幕查词高亮把 UTF-16 匹配长度当码点折算
- **报告**：2026-11-22（手柄查词统一 PR 的子代理顺带发现，未单独复现）
- **真实性**：⚠️ 待验。`lookupHighlightGraphemeCount`（`fushi/lib/src/pages/implementations/video_fushi_page.dart:794`）注释称引擎匹配长度是**码点**数，按 `term.runes.take(matchedRunes)` 折成字素；但 `global_lookup_controller.dart:137` 与 `gal_ingame_lookup_controller.dart:1610` 都把同一个 `bestLength` 记为 **UTF-16 code unit**。若后者为真，查询串含代理对字符（emoji、CJK 扩展 B 汉字如「𠮟」）时视频字幕高亮会多盖字。先沿 FFI `matched` → `bestLength` → `getFinalHighlightLength` 确认单位。
- **[ ] ① 未修复** —
- **[ ] ② 未加自动化测试** — 应加：含代理对字符的查询串，断言高亮字素数。
- **备注**：手柄查词统一（2026-11-22）中阅读器 / 漫画已把命中长度统一换成字素（`fushi/lib/src/lookup/lookup_match_measure.dart`）；视频这条链路超出那次范围，未动。
