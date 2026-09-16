## BUG-2530 · 阅读器顶栏/读数按固定窗宽阈值折叠：横屏手机顶部还空着大半条，按钮却已折进 ⋮、读数被踢出播放条
- **报告**：2026-09-14（用户：「顶部有空间的时候应该把顶栏收起的按钮放出来而不是默认折叠」「横屏应该同层进度显示」，附横屏截图：顶栏只剩 ← / 目录 / 书名 / 设置 / ⋮，插图·统计·有声书都在 ⋮ 里；底部播放条之下另起一行画着 ⏱ 10:32 ——— 5.5%）
- **真实性**：✅ 真 bug。根因是一条**与内容无关**的固定窗宽阈值 `kReaderDesktopHeaderCompactWidth = 760`（`fushi/lib/src/reader/reader_desktop_chrome.dart:77`），被两处共用：
  - 顶栏折叠：`ReaderDesktopHeader.build` 的 `readerHeaderCompact(constraints.maxWidth)`（同文件 :163）——只看窗宽，不看这一栏此刻有几颗按钮。截图那台横屏手机是 1920 物理 / dpr 2.75 ≈ **698 逻辑 px**：六颗按钮 288 + 两端内边距 16 = 304，书名两侧还空着 394，却因为 698 < 760 整栏进紧凑形态。
  - 读数并进播放条：`_playbackStatusInline`（`fushi/lib/src/pages/implementations/reader_fushi_page.dart:2138`）直接复用同一个判据。那个数是为**顶栏按钮数**定的，拿来判「播放条这一行塞不塞得下一串读数」本就不是同一件事；同样的 698 px 放得下五颗传输键加读数，却被判成窄屏，读数被踢到播放条之下单独占一行（底部因此凭空多出一层，另见 BUG-2531）。
- **[x] ① 已修复** — 判据改成**按实际内容算**：新增 `readerHeaderCompactForActions`（按钮数 × 48 + 两端 16 之后，留给书名的不足 120 才折叠）供 EPUB 顶栏用；读数并层改用 `readerPlaybackStatusInline`（横屏 + 宽度下限 480，竖屏一律分层）。漫画顶栏（`manga_reader_chrome.dart`）继续用旧的固定阈值——那一栏要按组夹分隔线、还要塞 OCR 进度胶囊，所需宽度算不准，本次不动。
- **[x] ② 已加自动化测试** — `fushi/test/reader/reader_desktop_chrome_test.dart`：`readerHeaderCompactForActions` 三条纯函数用例（698 px 六颗按钮不折叠 / 424 px 是分界 / 不显示书名时的边界）+ widget 用例「横屏手机宽度：六颗按钮全部直接画，没有 ⋮ 溢出菜单」（698×350 真 pump，逐颗断言图标在栏里、overflow key 不存在）。`fushi/test/reader/reader_status_footer_test.dart`：`inline: 横屏且够宽才并进底栏那一行；竖屏一律分层`。
- **备注**：设备肉眼复测原始横屏路径待补（本轮只有 widget 层证据）。
