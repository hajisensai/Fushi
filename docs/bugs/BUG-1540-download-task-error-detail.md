## BUG-1540 · 下载任务卡错误展示：英文裸串整句铺开、无点击详情、chip 未本地化
- **报告**：2026-08-11（用户：下载页-任务 tab 截图，TODO-2793）
- **真实性**：✅ 真 bug。任务卡直接把持久化的原始英文诊断串整句渲染进卡片：
  `fushi/lib/src/pages/implementations/video_download_jobs_panel.dart:451-467`（旧行号）
  把 `job.lastError` 原文以 maxLines:3 铺开，无本地化、无点击详情；同文件
  chip 兜底 `lifecycleLabel?.call(job.lifecycle) ?? job.lifecycle` 让
  `needsAttention` / `scrape` / `download` 等英文枚举值裸串上屏（downloads_page
  调用处未传 lifecycleLabel/stageLabel）。错误串来源是持久化诊断（wire 值，
  冻结不改）：`fushi/lib/src/media/video/download/video_download_pipeline_service.dart:1854`
  （"The managed video source no longer exists"）与
  `fushi/lib/src/media/torrent/video_download_legacy_importer.dart:288,315`
  （"needsAttention: backend torrent was not confirmed by hash, title, and
  category; legacy subtitle selection was unavailable"）。
- **[x] ① 已修复** — `4cae691ebe`。UI 层新增分类器
  `fushi/lib/src/media/video/download/video_download_error_presentation.dart`
  （`classifyVideoDownloadError` / `videoDownloadErrorSummary`，7 类：受管来源
  不存在 / 种子未按哈希·标题·分类确认 / 字幕不可用 / 后端不可用 / 种子身份缺失 /
  旧版导入 / 未知走通用摘要）；任务卡错误区改为一行本地化摘要（maxLines:1 +
  ellipsis）+「查看详情」，点击弹 AlertDialog 展示完整原文（SelectableText，
  可复制按钮）；lifecycle/stage chip 增加本地化默认标签。持久化 lastError 与
  后端诊断原文不动，详情对话框保留原文——摘要层本地化、原文层透传。
  i18n 走 `tool/i18n_sync.dart --add`（21 key × 17 语言）+ `dart run slang`。
- **[x] ② 已加自动化测试** — `4cae691ebe`，
  `fushi/test/pages/video_download_jobs_panel_test.dart`：
  纯函数分类映射（含复合原因主因归类）；360px 窄屏下长错误只渲染单行摘要、
  原文不上屏、无溢出异常；点击错误行弹出详情对话框且原文完整可见可复制；
  未知错误回退通用摘要；chip 断言改锚本地化标签。
- **备注**：错误串是 DB 持久化诊断值（`VideoDownloadJobs.lastError`），按
  「存量持久化名冻结」原则不改写库内容，只在展示层分类本地化。
