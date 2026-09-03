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
- **备注**：既有守卫「真人剧合集不再写死 anime 分类」原来断言「恰好一轮请求」（`hasLength(1)`），
  自动首搜后一度放宽成 `isNotEmpty`——那会丢掉请求条数**上界**，同一次交互重复发搜再也不会变红。
  已恢复为精确 `hasLength(2)`（自动首搜 1 次 + 显式点「查找字幕」1 次），同时保留
  「**每一轮**请求都带同一套规范身份」的逐条断言；
  「快速切系列时迟到旧响应不覆盖新来源」的第一轮改由自动首搜发起。
- **合入前审查追加修复（自动首搜静默改写合集身份）**：首版自动首搜走
  `_resolveSeries() → _selectSeries(outcome.media.first)`，而 `_selectSeries` 会
  `setMediaCollectionAnilistId` 落库。这条路径的**前提**就是 `collection.anilistId == null`，
  所以 `anilistId != media.id` 恒真、**写必然发生**：用户只是打开一次工作台，合集就被 AniList
  模糊搜索的第一条命中粘性绑定，下次开面板走 `seedId` 分支再也不重搜；合集详情页的下载对话框
  （`media_collection_detail_page.dart:855-869`，TODO-2485）也跟着按这个 id 去找番剧种子。
  真人剧合集最致命——它在 AniList 上没有条目，模糊搜索照样返回一部最像的动画。
  当时零测试覆盖：新增用例与既有 BUG-1694 用例的 mock 都返回**空** media 列表，双双绕开
  `_selectSeries`。**根因修复**是把「搜」和「绑」拆成两个原语而不是加一个 bool 参数：
  `_applySeries`（只设 UI 选中 + 检索，类型上够不着写库）/ `_selectSeries`（先落库再委托
  `_applySeries`，唯一调用方是系列 ChoiceChip 的 `onSelected`）。
  测试：「自动首搜只搜不绑：模糊命中首条不写 media_collections.anilistId」
  + 「用户显式点选系列 → anilistId 才写进合集」，mock 返回**非空** media 列表。
  变异实测：在 `_applySeries` 里加回 `setMediaCollectionAnilistId` → 这两条同时红
  （`Expected: null Actual: <777>` / `<11>`），其余 12 条绿。
  **线上无受害者**：这条路径从未合入 `develop`，`setMediaCollectionAnilistId` 在 `develop` 上
  的另外两个调用点是 `anime_download_importer.dart:110`（种子导入时身份已知）和用户显式点选，
  都不是模糊猜测。
