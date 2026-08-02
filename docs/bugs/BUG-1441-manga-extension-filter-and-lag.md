## BUG-1441 · 漫画扩展列表筛选不生效 + 语言下拉卡顿
- **报告**：2026-08-02（用户：截图，「来源」页装了 keiyoushi 仓库后，语言选 JA、搜索框输入 `raw`，列表纹丝不动；下拉框很卡）
- **真实性**：✅ 真 bug，三个独立根因叠在一起
  1. **搜索被仓库级字段打成全命中** —— `hibiki/lib/src/media/manga/mihon/mihon_extensions_page.dart:363`（改前）把 `extension.storeUrl` 塞进可搜字段。同一仓库里每个扩展的 `storeUrl` 完全一样，keiyoushi 的索引地址是
     `https://github.com/keiyoushi/extensions/raw/repo/index.pb`，经 `normalizeMediaSearchText` 丢掉标点后是
     `httpsgithubcomkeiyoushiextensionsrawrepoindexpb` —— 含 `raw`、`github`、`repo`、`index`。搜这几个词里的任何一个，该仓库 1900+ 个扩展一个不漏地留下来，用户看到的就是「筛选完全不生效」。同一行还塞了 `extension.language`（低基数共享值，且已有专门的语言下拉）。
  2. **语言过滤强行放行 `all`** —— 同文件 `:360`（改前）`extension.language.toLowerCase() == 'all'` 是个无条件通行分支：选 JA 时所有多语言扩展照旧全列出来。keiyoushi 的 `all` 大多是聚合站，于是「选了日语，整屏还是 all」。
  3. **列表非懒建（下拉卡顿的真正来源）** —— `MihonExtensionsPage(embedded: true)` 返回裸 `Column`，宿主 `MangaSourcesPage` 是 `ListView` + 单个巨型 child。`Column` 没有视口裁剪，1900+ 个 `_AvailableExtensionTile` 全部实体化成 RenderObject 并每帧参与布局/绘制；下拉菜单一展开就是连续动画帧，于是卡死。改一次筛选还要连带重建整棵树。
- **[x] ① 已修复** —
  - 可搜字段只留**条目自身**标识：扩展名 / 包名 / 其提供的源名与域名；剔除 `storeUrl` 与 `language`。
  - `all` 降级为语言下拉里的一个普通选项（显示 `ALL`，与条目副标题里的 `all · 1.6.4 · lib 1.6` 同词），消掉无条件通行分支；本地独有扩展也一并跟随语言过滤。
  - 内嵌形态改为返回 sliver（`SliverMainAxisGroup` + `SliverList.builder`），`MangaSourcesPage` 的滚动容器从 `ListView` 换成 `CustomScrollView`，只建视口内的十几行。
- **[x] ② 已加自动化测试** — `hibiki/test/media/manga/mihon_extensions_page_test.dart`
  - 「搜索不吃仓库 URL：搜 raw 只留名字里真有 raw 的扩展」（三个扩展共用 keiyoushi 索引地址）；
  - 「语言选 JA 不再混进 all 语言的扩展」；
  - 「内嵌节懒建：视口外的扩展不进 widget 树」（300 条，末条必须 `findsNothing`）；
  - 既有 embedded 用例改为在 `CustomScrollView` 里 pump，反向锚 `find.byType(ListView) findsNothing`。
  - 三条守卫均已变异实测：把 `storeUrl` 加回可搜字段 / 把 `== 'all'` 分支加回来 / 把内嵌节换回 `Column`，对应用例分别变红。
- **备注**：搜索仍是每次按键全量过滤（1900 条 × 数个字段），实测在懒建之后不再是瓶颈，故未加 debounce——加了只是把症状推后。
