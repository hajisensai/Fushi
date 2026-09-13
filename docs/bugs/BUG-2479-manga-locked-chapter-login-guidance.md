## BUG-2479 · 锁定章节无登录引导；Android 无登录入口；登录页无前进后退；源列表无搜索
- **报告**：2026-09-12（用户：BookWalker 作品页截图——章节带 🔒，「带锁的怎么登录下载呢」；「现在作品页那些带锁章节点了没任何提示会引导你去登录 加一下」；「登录按钮只在桌面显示……能优化就优化」；「这里漫画源要能搜索」；「登录页面缺少前进后退等基本功能」）
- **真实性**：✅ 产品缺口四项，同一条链路。
  1. Mihon 没有「锁」字段，keiyoushi 扩展把 `🔒 ` 拼在章名前、取页时抛 `Log in via WebView and rent or purchase this chapter to read.`（`BookWalkerJp.kt:223/334`）；宿主把锁章当普通章入队 → 必败，失败行只写「下载失败」四个字，原因藏起来了。
  2. `mihonLoginTarget` 只认 `HostCookieMihonRuntime`（桌面 sidecar）；Android 扩展经 `AndroidCookieJar` 读系统 `CookieManager`，app 内 `InAppWebView` 写的正是同一份，登录完什么都不用导出——却没有入口。
  3. 登录页只有关闭/完成，登录流程跨页（登录 → 选账号 → 回跳）没法回退。
  4. 源管理页第 4 节（已安装在线源）无搜索，扩展装多了找不到要登录的那一行。
- **[x] ① 已修复** —
  - `OnlineMangaChapter.locked`（`online_manga_library_entry.dart`，Mihon = 章名前缀约定 `isLockedChapterName` 唯一判据；Aidoku = `raw['locked']`；v3 描述符往返、v1 旧描述符按前缀推）。作品页点未下载锁章弹「章节已锁定」：登录该源 / 仍然下载 / 取消（`manga_series_page.dart` `_promptLockedChapter`）；登录成功后自动 `_refreshFromSource` 让锁位刷新；「下载全部」跳过锁章并 toast 跳过数；失败行副标题带 `last_error` 原文（`manga_chapter_list.dart`）。适配器侧新增能力接口 `OnlineMangaLoginCapable.loginTarget`，只 `MihonLibraryAdapter` 实现。
  - `BrowserCookieMihonRuntime`（`mihon_runtime.dart`），`AndroidMihonRuntime` 实现；`mihonLoginTarget` 两种能力都认；登录页 `jar` 可空，空则点「完成」直接关页。作品页与源管理页共用 `openMihonWebLogin`。
  - 登录页加后退/前进/刷新 + 当前地址；Android 返回键先回退网页（`PopScope`）。
  - 源管理页已安装源列表加搜索框（`mihon_sources_search_field`，`filterByMediaSearch` 按名称/语言/包名），筛选中隐藏排序按钮。
- **[x] ② 已加自动化测试** — `fushi/test/media/manga/manga_series_page_locked_chapter_test.dart`（弹窗/取消/仍然下载/登录按钮有无/下载全部跳过）、`manga_locked_chapter_and_web_env_test.dart`（锁判据 + 描述符往返）、`mihon_web_login_page_test.dart`（Android 运行时给入口、jar 为空直接 pop、导航条三键）。
- **备注**：锁判据依赖扩展约定（emoji 前缀），换一家不遵守约定的扩展就退化成「入队后失败、失败行露原因」——不会更糟。
