## BUG-2523 · 搜索资源丢集：nyaa 带评论的条目标题被抓成「1 comment」
- **报告**：2026-09-13（用户：详情页「搜索资源」搜 `Yani Neko`，Erai-raws 1080p 版本卡只显示「共 8 集 (EP2–EP9)」；Nyaa 站上同一查询有 EP01–EP10 共 18 条）
- **真实性**：✅ 真 bug。对照截图，丢的三条（EP10 AVC、EP01 AVC、EP01 HEVC）恰好是 Nyaa 上仅有的三条带评论条目。抓真实搜索页确认：nyaa 模板在标题单元格里先写 `<a href="/view/<id>#comments" class="comments" title="1 comment">`（CSS 右浮，DOM 顺序在前）再写标题链接；`packages/fushi_engine/lib/media/torrent/nyaa_client.dart:719`（`_parseNyaaHtmlSearch`）取详情链接只按 `path.startsWith('/view/')` 用 `firstWhere`，带评论的行命中评论链接，`title` 属性 `1 comment` / `5 comments` 成了发布标题，之后按系列名/集号匹配整行被丢；`pageUrl` 也带上了 `#comments`。用单测直接跑旧解析器复现出 `['1 comment', '5 comments', …]`。
- **[x] ① 已修复** — 详情链接判据加「无 URL fragment」（评论链接恒带 `#comments`，详情链接永远没有），同文件同位置；提交见本 PR。
- **[x] ② 已加自动化测试** — `fushi/test/torrent/nyaa_html_fixture.dart` 给 `NyaaHtmlRow` 加 `commentCount`，按真实模板顺序生成评论链接；`fushi/test/torrent/nyaa_client_test.dart`「BUG-2523：带评论的行跳过前置的 #comments 链接」断言 1 条 / 5 条评论的行标题、集号、`pageUrl` 均取真实发布（修复前该测试在 `[0]` 处报 `'1 comment'`）。
- **备注**：同一 PR 顺带把资源/订阅/设置里的「默认受管视频来源」标签（`video_download_target_source_title`）改成「默认文件夹」（17 语言只改值不改 key）——它是下载落地的本地目录，旧名读起来像「搜索用的源」（BUG-1713 已加 helperText 缓解，这次直接改名）。
