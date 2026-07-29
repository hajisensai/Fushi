## BUG-1251 · 手动搜索封面仍按原路径标题评分
- **报告**：2026-07-29（用户：截图中的标准罗马字标题候选仍全部显示“低匹配”）
- **真实性**：✅ 真 bug。`hibiki/lib/src/media/video/cover_ui/cover_match_dialog.dart:314` 的置信度原先始终使用从视频路径解析出的 `_parsed`，搜索框里的用户显式纠正只用于请求，不参与评分。
- **[x] ① 已修复** — `hibiki/lib/src/media/video/cover_ui/cover_match_dialog.dart:179` 记录实际搜索词，评分时用它替换标题，同时保留路径解析出的年/季/集等结构化线索。（提交：待本次提交后回填）
- **[x] ② 已加自动化测试** — `hibiki/test/media/video/scraper/cover_match_dialog_test.dart:262` 覆盖“路径带播放列表噪音、手动输入标准标题后必须显示高匹配”。（提交：待本次提交后回填）
- **备注**：条目 URL/ID 直连仍是用户显式选择路径；本修复只纠正手动关键词搜索的置信度口径。
