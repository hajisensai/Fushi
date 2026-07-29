## BUG-1234 · 封面匹配切换来源会自动重搜并保留旧来源结果
- **报告**：2026-07-29（用户：在线匹配封面切换来源会重新加载并报错；TMDB 无 key
  但下方仍有数据）
- **真实性**：✅ 真 bug。`hibiki/lib/src/media/video/cover_ui/cover_match_dialog.dart:511`
  的来源切换回调原先直接调用 `_search()`，且切换时不清空 `_results`；因此切到 TMDB
  会立即请求，缺 key/请求失败时还可能展示上一来源候选。
- **[x] ① 已修复** — 来源切换只更新目标来源，作废在途请求并清空候选/失败状态；显式
  点「搜索」或保存 key 才请求。TMDB 无 key 展示专属空态，候选行同时标出来源与条目
  ID；单集批量应用保持默认关闭并解释其覆盖语义。
- **[x] ② 已加自动化测试** —
  `hibiki/test/media/video/scraper/cover_match_dialog_test.dart` 覆盖切换不自动请求、旧
  Bangumi 候选不混入 TMDB、手动搜索恢复结果、来源标识与默认关闭；另钉住保存 TMDB
  key 尚未完成时切换来源的竞态，迟到 continuation 不得搜索新来源。
- **修复提交**：`37b101471`
- **备注**：定向测试使用已缓存的 `pdfium.dll` 与仅测试期间启用的系统
  `winsqlite3` 完成 55/55；临时 pubspec 配置已在提交前移除。`flutter analyze
  --no-pub` 通过。
