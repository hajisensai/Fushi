## BUG-2101 · 漫画阅读器加载失败时返回键一起消失：iOS 上无系统返回键 = 只能杀进程
- **报告**：2026-09-03（用户：截图 MangaFire 章节列表页 + 原话「找不到书。然后没有出口。ios 没有系统返回键」）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/media/manga/reader/manga_fushi_page.dart:4159`（修前）——左上返回键的渲染条件写成 `_bookRow != null && !_loadFailed && _chromeVisible`，**出口跟着内容一起消失**。

  三件事叠加才成死锁，缺一不可：
  1. 加载失败（`_loadFailed`）或迟迟未就绪（`_bookRow == null`）时，正文区只剩一行「找不到书籍文件」，返回键与顶栏被同一个条件一起摘掉；
  2. 漫画正文是原生 WebView，空白点击手势全在注入的 JS 里且**已被翻页占用**，页内没有第二条退出通道；
  3. 本页 `PopScope(canPop: false)`（同文件 4100 行）顺手也关掉了 iOS 的侧滑返回，而 iOS 没有系统返回键。

  同一条件也挂在「隐藏界面后的唤回按钮」上（修前 4182 行），于是「先隐藏界面、内容再加载失败」会把唤回按钮一并抹掉，返回键再也叫不回来。

  横向核对：PDF 阅读器有常驻 `AppBar`（`automaticallyImplyLeading` 默认给返回键），不受影响；小说阅读器在书文件缺失时**直接 pop**（`reader_fushi_page.dart:2143`），也不会困住用户。只有漫画页把出口挂在了内容状态上。

- **[x] ① 已修复** — 出口不是内容的一部分，不随内容存亡：返回键的门控收成只由用户意图 `_chromeVisible` 决定，唤回按钮只由 `!_chromeVisible` 决定。顶栏（页码 / 框选 OCR / 单双页）**继续**挂内容门控——那些控件没有内容时确实无意义，这个区分是有意的。
  - 提交：`ffdaa2a3f4`
- **[x] ② 已加自动化测试** —
  - 行为断言（强）：`fushi/test/pages/manga_fushi_page_test.dart` 的「加载失败（无书行）时 chrome 不构建 → 无按钮」用例补上 `manga_reader_back_button` **必须在场**。
  - 源码守卫（改写而非放松）：`fushi/test/pages/manga_toggle_chrome_test.dart` 原先钉的是 `_bookRow != null && !_loadFailed && _chromeVisible` 出现 ≥2 次（即「返回键也要挂内容门控」——把 bug 钉成了契约）。改为断言内容门控**只剩顶栏那一处**、且唤回分支不得带内容门控。守卫先经 `maskComments` 剥注释再判（本次修复在源码注释里逐字引用了旧条件用于解释它为什么错，不剥会被自己数进去而恒红）。
  - 变异实测：把返回键条件改回旧写法，两条断言（源码守卫 + 行为断言）**都变红**；还原后文件 sha256 与变异前逐字节一致（`1a6f233ed7ceb7005ba0e29f924599ed69d0d165ce23e205cbb3bb29f6d1ae7d`）。
  - `test/pages/` 整目录 3309 条通过。
- **备注**：与 BUG-2100 是同一次用户报告的两端——BUG-2100 是「书为什么找不到」（iOS 容器漂移），本条是「找不到之后为什么退不出去」。真机 iOS 复测未做（本机无 iOS 设备）。

  **未做的相邻项**：`_loadFailed` 仍是个裸 bool，三个置位点里有一个是「在线章节打开抛出任何异常」（同文件 `_loadOnlineBookFromShelf` 的 catch），界面照样渲染成「找不到书籍文件」——对在线源来说这句话是**说谎**（书文件本来就不在磁盘上，真实原因是网络/扩展失败），且原始异常只进 ErrorLogService、界面上不可见、无重试、无诊断。`MangaSeriesPage._buildLoadError` 已经确立了正确范式（原因可见 + 诊断入口 + 重试，BUG-1767）。这是同族的第三个缺陷，本轮未动。
