## BUG-4919 · 已移除的曲目等音乐二级页正文顶端被页头盖住
- **报告**：2026-11-20（用户：应用内反馈 wRNmmoL4lT）
- **真实性**：✅ 真 bug。`fushi/lib/src/pages/implementations/music/music_track_selection.part.dart:390`（`MusicHiddenTracksPage.build`）把 StreamBuilder 的 context（在页头脚手架之上）传给 `_body`，`_body` 里 `musicBrowsePagePadding(context)`（`music_server_pages.dart` 的 `musicBrowsePagePadding`）读 `MediaQuery.paddingOf(context).top`。页头大字外壳只在正文子树里把页头高度注入 `MediaQuery` 顶部 padding（`fushi_masthead_scaffold.dart:547-549`），脚手架之上读到的只有状态栏（测试里为 0），提示文字与第一行曲目被页头压住（实测提示顶 8px，页头下沿 98px）。
  结构原因：`musicBrowseScaffold` 的 `body` 是现成 `Widget`，调用方一律在脚手架之上的 context 里搭正文，量留白要靠各处自觉包 `Builder`；同一漏洞还在 Apple Music 歌曲列表 / 艺人页（`music_apple_music_pages.dart` 的 `_buildPage` 两处）、服务器歌单页（`music_server_pages.dart` `_MusicServerPlaylistPageState._buildPage`）；另有几页（插件管理、来源、服务器搜索、专辑 / 曲目详情）早先各自手包 `Builder` 绕过。
- **[x] ① 已修复** — `musicBrowseScaffold` 的 `body` 改为 `WidgetBuilder`，由外壳在脚手架之下（`Builder`）构建，正文拿到的 `context` 结构上就是能读到页头让位的那个；22 处调用点全部改成构建器，插件管理 / 来源 / 服务器浏览与搜索 / 插件浏览等页正文最外层手包的 `Builder` 去掉；服务器歌单页的预算正文改成预算构建器。
- **[x] ② 已加自动化测试** — `fushi/test/pages/music/music_hidden_tracks_masthead_test.dart`：真 `MusicHiddenTracksPage` + 内存库两首墓碑曲目，断言提示与第一行曲目都在 `FushiMastheadHeader` 下沿之下；把正文改回用脚手架之上的 context 时该测试红（Expected ≥98.32，Actual 8.0）。
- **备注**：布局类修复，未做设备肉眼复测。
