## BUG-1710 · 漫画库两个 tab 都叫「发现」
- **报告**：2026-08-18（用户：漫画的发现有两个）
- **真实性**：✅ 真 bug。漫画库页的 tab 栏里第 2、3 两个视图的**显示文案字面完全相同**，
  用户点哪个都叫「发现」。

  根因是两条 PR 各自正确、合到一起就撞车：
  1. `fushi/lib/src/media/manga/manga_library_page.dart:48-53`（PR#883，`40f611bc46`）
     新增 `MediaLibraryViewKind.discover` 视图，label 用新 key `library_view_discover`
     （值 "Discover" / 「发现」）。
  2. `fushi/lib/src/media/manga/manga_library_page.dart:54-59` 的存量视图 label 是
     `library_view_browse`，原值 "Browse" / 「浏览」；PR#886 的收尾 commit `c64f4af171`
     为了「发现视图跨域统一叫发现」把这个 key 的**值**改成了 "Discover" / 「发现」。
     那次改动的 diff 只碰了 `game_shared.dart` 与 `video_library_shell.dart`，没人检查
     漫画库页同时挂着 `library_view_discover` 和 `library_view_browse` 两个 key。
  3. i18n 侧没有任何守卫会发现这件事：key 名不同、17 份 json 都完整，`fushi/test/i18n/`
     下没有一条断言「同一个 tab 栏内 label 不得重复」。

  能力上两页是互补而不是重复（`MangaDiscoveryPage` = AniList 推荐流 + 来源热门行，
  无搜索无来源筛选；`MangaBrowsePage` = 在线来源清单卡片 + 一个跳去全源搜索的图标按钮），
  但对用户就是两个同名入口。用户同一轮还报了「发现页缺搜索栏、缺来源筛选」——这两件事
  同一个修法：合并成一个发现页，头部统一成「来源筛选下拉 + 搜索栏」。

- **[x] ① 已修复**（commit `237fac6d2a`）— 不是给其中一个 tab 改名，而是把两个页面合并成漫画唯一的发现入口
  （用户同一轮还报了「发现页缺搜索栏、缺来源筛选」，同一个修法一起解决）：
  1. `MangaDiscoveryPage` 保留为骨架，头部接上与书 / galgame 发现页同形的共享组件
     `DiscoveryHeaderControls`（来源筛选下拉 + 搜索框，新建
     `fushi/lib/src/pages/implementations/discovery_header.dart`）。
  2. 原「浏览」tab 的在线来源清单整体搬进发现页正文末尾的「浏览来源」一节
     （新建 `fushi/lib/src/media/manga/discovery/manga_source_catalog_section.dart`，
     含 mokuro.moe / Aidoku 包 / Mihon 源三类卡片、`aidokuError` 提示与
     `mihon_source_empty` 空态，跳转逻辑与平台门原样搬）。
  3. 原来藏在 `travel_explore` 图标里的全源聚合搜索改由头部搜索框提交，并按下拉选择
     收窄参与搜索的源（`MangaGlobalSearchPage(initialQuery:)`）。
  4. `manga_library_page.dart` 删掉 `MediaLibraryViewKind.browse` 那条视图声明，漫画库
     从五视图变四视图；`MediaLibraryViewKind.browse` 枚举值保留（书 tab 仍在用）。
  能力一条没丢：AniList 四行、来源热门行、刷新/重试、来源清单、全源搜索、Aidoku/Mihon
  监听与平台门全部在新页面里，逐条对照见 PR 说明。顺带一处改善：AniList 的加载/失败态
  从「顶替整页」降级为「列表里的一项」，AniList 挂了不再把来源清单一起带走。
- **[x] ② 已加自动化测试** —
  `fushi/test/pages/library_view_labels_unique_test.dart`（新，目录枚举型守卫）：
  `listSync(recursive: true)` 扫 `lib/` 全树抓每个 `MediaLibraryViewSpec(` 的 `label:`，
  强制必须是 `t.<key>` 直引用（防拼接绕过），再断言同一文件内 ① key 不重复
  ② **en 与 zh-CN 两个 locale 下的文案不重复**——本次事故里两个 key 本来就不同，只有
  比对用户真正看到的那串字才抓得住。另有「扫描面非空」用例防守卫空转。
  变异实测三轮：把某 tab 的 label 换成「不同 key、同文案」（事故形状）→ locale 两条用例
  红而 key 用例正确保持绿；换成同 key → 三条全红；换成裸字符串 → 四条全红；还原后
  sha256 逐字节一致。
  另更新 `fushi/test/media/manga/discovery/manga_discovery_page_test.dart`（新增头部下拉/
  搜索框/「浏览来源」节存在，以及从真实 `DropdownMenu` 选中来源后 AniList 行收起）、
  `fushi/test/pages/manga_library_page_split_test.dart`（视图列表 + `isNot(contains(browse))`
  反向锚）、`fushi/test/pages/manga_sources_view_composition_test.dart`（原「浏览」视图的
  6 条源码扫描断言全部搬家，一条没放宽，另加 3 条）。
- **备注**：与 BUG-1711（发现页「全部源」透出单源目录）同一轮发现页整合（TODO-2931）。
