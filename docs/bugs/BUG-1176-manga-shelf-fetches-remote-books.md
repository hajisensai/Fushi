## BUG-1176 · 漫画书架实例误拉远端书，切到书架触发双倍网络

- **报告**：2026-07-28（用户：互联切页面重新拉取，排查时发现）
- **真实性**：✅ 真 bug。漫画书架就是 `ReaderHibikiHistoryPage(mangaOnly: true)`
  （`hibiki/lib/src/media/manga/manga_shelf_page.dart:14`）——与书架**同一个 State 类**，
  且 manga 也在保活 tab 列表里（`home_page.dart:935-940`），常驻挂载。

  两个实例都在 `initState` 注册了同一个监听器
  （`hibiki/lib/src/pages/implementations/reader_hibiki_history_page.dart:331`），而回调
  判的是 `homeShellTabNotifier.value == HomeTab.books`（同文件 `:358`），**不是判自己的
  tab**。`_refreshRemoteBooks`（`reader_history/remote.part.dart:72`）又不对 `_mangaOnly`
  早退。

  于是用户每切到书架一次，远端书清单被完整拉**两遍**；漫画那一遍的结果在
  `reader_hibiki_history_page.dart:1130` 被 `showRemote = !_mangaOnly && ...` 直接丢掉。
  纯浪费一整轮网络往返。

  （首帧不受影响——`:467` 的 `??=` 那里原本就有 `_mangaOnly ? null : ...` 短路，
  漏的只是 tab 信号这条路径。）

- **[x] ① 已修复** — 两道闸：
  1. `reader_hibiki_history_page.dart` 的 `initState` 只在 `!_mangaOnly` 时才订阅
     `homeShellTabNotifier`（漫画实例根本不消费远端书，不必订阅）。
  2. `reader_history/remote.part.dart` 新增 `_shouldLoadRemoteBooks` 门控，
     `_loadRemoteBooks` 开头即早退——任何**其它**触发路径（`_refreshSrtBooks` 等）
     经过漫画实例时同样不联网，不依赖调用方自觉。

- **[x] ② 已加自动化测试** — `hibiki/test/pages/reader_remote_interconnect_test.dart`
  的「BUG-1176: 漫画书架实例从不拉远端书（它根本不消费）」：以 `mangaOnly: true` 挂载，
  断言首帧 `listRemoteBooksCalls == 0`，再把 `homeShellTabNotifier` 切到 `HomeTab.books`
  后仍为 0。

- **备注**：与 [BUG-1175](BUG-1175-interconnect-remote-list-no-cache.md) 同一轮排查发现；
  即便有了 TTL 缓存，这条也该修——漫画实例连缓存都不该去读。
