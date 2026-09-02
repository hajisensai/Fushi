## BUG-2060 · 「整个合集」字幕面板无法选取字幕：未绑 AniList 的合集不发首搜，来源选择区整块隐藏
- **报告**：2026-09-03（用户：截图 QQ_1788367091057.png，「这里怎么选取字幕？」）
- **真实性**：✅ 真 bug。两条叠加：
  - `fushi/lib/src/pages/implementations/subtitle_collection_panel.dart:274`（修复前行号，
    `_loadCanonicalIdentity` 末尾）只在 `seedId != null`（合集绑了 AniList id 或刮出 anilist 身份）
    时发首搜；没绑的合集**一次检索都不发**。
  - 同文件 `:739`（修复前）`_buildSourcePicker` 在 `_sources.isEmpty` 时 `return const SizedBox.shrink()`，
    来源选择区连标题一起消失。
  结果：用户看到的是一排 `_statusIcon` 的 `Icons.remove` 占位横杠（像没渲染出来的复选框）、
  静态的「各集按文件名里的集号匹配」副标题、和永远灰着的「下载全部」，界面上没有任何字说明
  还要先点右上「查找字幕」。
- **[x] ① 已修复** — `_loadCanonicalIdentity` 在 `seedId == null` 且已配置字幕来源时补发一次
  `_resolveSeries()`（与用户点「查找字幕」同一条路径），消除「绑了才搜、没绑不搜」这个特殊情况；
  `_buildSourcePicker` 空态不再整块隐藏，按 搜索中 / 没搜过 / 搜过没有 三态各给一句话
  （新 i18n key `video_subtitle_source_search_hint`）。一个来源都没配时仍不自动发，
  免得一进面板就弹红色的「缺 API key」。
- **[x] ② 已加自动化测试** — `fushi/test/pages/subtitle_collection_panel_test.dart`：
  「没绑 AniList 的合集也自动首搜：来源直接可选」/「首搜没结果：来源区说「没找到」而不是整块消失」/
  「一个字幕来源都没配：不自动发搜，来源区给引导」。变异实测：去掉自动首搜分支 → 3 条红。
- **备注**：既有守卫「真人剧合集不再写死 anime 分类」原来断言「恰好一轮请求」，
  自动首搜后改为断言**每一轮**请求都带同一套规范身份（覆盖面更大，没削弱）；
  「快速切系列时迟到旧响应不覆盖新来源」的第一轮改由自动首搜发起。
