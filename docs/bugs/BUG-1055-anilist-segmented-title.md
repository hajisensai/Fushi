## BUG-1055 · AniList 罗马字分词差异导致番剧误报无结果
- **报告**：2026-07-24（用户：`Watashi o Tabetai, Hito de Nashi` 显示“无结果”）
- **真实性**：✅ 真 bug。修前 `hibiki/lib/src/media/video/anilist_client.dart:166` 只把完整输入向 AniList 请求一次；实网验证用户输入返回 0 条，而 `Watashi o Tabetai` 与规范写法 `Watashi wo Tabetai, Hitodenashi` 均命中 AniList #183385。逗号后 `Hito de Nashi` / `Hitodenashi` 的分写差异使整串模糊检索失败。
- **[x] ① 已修复** — `anilist_client.dart:90` 生成保守候选：先搜完整标题，仅空结果时再搜逗号前主标题；命中后下载页继续使用 AniList 返回的规范 romaji 搜 Nyaa，不维护脆弱的作品别名字典。
- **[x] ② 已加自动化测试** — `hibiki/test/media/video/anilist_client_test.dart` 用 MockClient 固化“完整串空 → 主标题命中 #183385”及请求顺序。
- **备注**：网络请求仍需可用直连/代理，网络失败与“真无结果”继续使用不同 UI 状态。
