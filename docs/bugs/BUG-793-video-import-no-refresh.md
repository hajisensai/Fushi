## BUG-793 · 视频导入后库页不自动刷新(外部打开等路径)

- **报告**：2026-07-14（用户：wrds）
- **现象**：从系统「用 Hibiki 打开」导入单个 `.mkv`（如 `[IrizaRaws] Adachi to Shimamura - 01.mkv`）后，进「视频」页看不到它；用户问「没刷新机制吗」。经查生产库该文件其实已落库（甚至因反复重试落了带 ` (2)` 后缀的重复行），全库 506 条——**东西进库了，只是列表不自动重查**。
- **真实性**：✅ 真 bug（纯刷新/响应式缺失，非导入失败）。
  - 列表一次性 `.get()`：`packages/hibiki_core/lib/src/database/database.dart` `allVideoBooks() => select(videoBooks).get()`。
  - `home_video_page.dart` 在 `initState` 只设一次 `_future = repo.listForShelf()`（`hibiki/lib/src/pages/implementations/home_video_page.dart:168`）；视频 tab 被 `IndexedStack` 保活，`initState` 不再跑。
  - **全仓库对 `videoBooks` 表零 `.watch()`** —— 列表对 DB 变更毫无自动感知，刷新全靠各调用点手动 `_refresh()`。
  - 根因命中路径：外部「用 Hibiki 打开」`hibiki/lib/main.dart:916 _openExternalVideo()` 落库（`:946`）后直接 push 播放器，**既不 `_refresh()` 也不 invalidate**（`main.dart:912` 注释还错误断言「书架自动出现」）。页内顶栏导入按钮那条会刷（`home_video_page.dart:659`），故 bug 复现于非本页发起的导入路径。

- **[x] ① 已修复** — 根因修：给库页加对 `videoBooks` uid 集合的 Drift `.watch()` 订阅，任意导入路径（页内/拖拽/外部打开/远端下载）落库后自动 `_refresh()`，无需每个调用点各自记得刷新。按集合去重（仅插入/删除触发刷新，封面自愈/进度回写等纯列更新不触发），避免写回→重刷环。
  - `packages/hibiki_core/lib/src/database/database.dart`：新增 `watchVideoBookUids()`（`select(videoBooks).map((r)=>r.bookUid).watch()`）。
  - `hibiki/lib/src/media/video/video_book_repository.dart`：新增 `watchVideoBookUids()` 委托 `_db`。
  - `hibiki/lib/src/pages/implementations/home_video_page.dart`：`initState` 订阅、`dispose` 取消、`_onVideoUidsChanged` 集合去重后 `_refresh()`。
  - 提交：74ca7bdb2
- **[x] ② 已加自动化测试** —
  - DB 层行为：`hibiki/test/database/video_books_test.dart` 新增 `watchVideoBookUids` 组（插入发出更新集合；纯进度更新集合不变）。
  - 源码守卫：`hibiki/test/pages/home_video_page_watch_guard_test.dart`（断言库页在 initState 订阅 `watchVideoBookUids` 且 dispose 取消，防回归删订阅）。
  - 测试文件：见上；提交：74ca7bdb2
- **书架（书籍/有声书）一并根因修**（用户追问「一样处理不好吗」）：`reader_hibiki_source.dart` 的 `hibikiBooksProvider`/`srtBooksProvider` 同属「`FutureProvider` 不 `.watch()`、靠每个导入点各自 `ref.invalidate`」的脆弱模式。改为各 `ref.watch` 一个监听 DB 行集的 StreamProvider（`_epubBookKeysProvider`/`_srtBookUidsProvider`，底层 `watchEpubBookKeys()`/`watchSrtBookUids()` + `.distinct(listEquals)` 按集合去重），任意导入路径落库自动重算；现存 invalidate 保留为即时刷新兜底。DB 层新增 `watchEpubBookKeys()`/`watchSrtBookUids()`；测试见 `epub_books_test.dart`/`srt_books_test.dart` 的 watch 组 + `test/media/reader_hibiki_source_watch_guard_test.dart`。
- **备注**：真机验收——① 外部「用 Hibiki 打开」一个新 mkv → 不重启不下拉，视频页应自动出现；② 用不触发 invalidate 的路径加一本 EPUB/有声书 → 书架应自动出现。BUG-790 已被 PR#94（草稿，合集行头 0 集）占用，与 develop BUG-791（popup-empty-reading-split）撞号，已 renumber 到 793。
