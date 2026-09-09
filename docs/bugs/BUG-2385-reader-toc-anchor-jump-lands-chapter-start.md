## BUG-2385 · 目录里同一章的多个锚点条目全跳章首（章节跳转不准）
- **报告**：2026-09-09（用户：移动端「章节跳转不准」）
- **真实性**：✅ 真 bug，且与平台无关（桌面端同样中招，只是移动端更常被用到）。根因是
  目录压平时把条目 href 的 `#fragment` 整个丢掉：
  - `fushi/lib/src/reader/ttu_toc_flatten.dart:26-34`（修前）只取
    `hrefToChapterIndex(item.href)` 建 `TtuTocEntry`，`TtuTocEntry`
    （`fushi/lib/src/media/audiobook/audiobook_bridge.dart:799`）本身也没有 fragment 字段。
  - `EpubBook.chapterIndexForHref` → `normalizeHref`（`fushi/lib/src/epub/epub_book.dart:348`）
    **先把 `#…` 切掉**再匹配 spine，所以 `vol1.xhtml#sec1` / `#sec2` / `#sec3`
    解析出来是**同一个章号**。
  - 于是 `chrome.part.dart:1904`（修前）`onJumpSection: (index) => _navigateToChapter(index)`
    只拿得到章号 → 每一条都落章首。
  「一个 xhtml 装整卷、目录靠锚点分节」在日文 EPUB 里是常见结构，这类书的整份目录
  除了第一条以外**没有一条跳得准**。
  对照组：**书内超链接**（`_handleInternalLinkUrl` → `EpubBook.resolveInternalLink`）
  一直是带 fragment 的，同章原地跳、跨章随章落锚——能力早就在，只是目录这条路径没接上。
- **[x] ① 已修复** — 让锚点一路活到跳转，两条路径合流：
  - `TtuTocEntry.fragment` 新字段；`flattenTtuTocEntries` 用新的纯函数
    `tocHrefFragment`（同文件）填它，口径与 `resolveInternalLink` 的 `Uri.fragment`
    一致（percent 解码；坏转义退回原文，绝不因此丢掉整条目录项）。
  - `onJumpSection` 签名带上 fragment，目录行（`reader_quick_settings_sheet.dart`）
    与有声书面板章节行（`reader_audiobook_panel.dart`）各自把自己的锚交出去。
  - navigation 侧新增**唯一落地口** `_jumpToChapterAnchor`
    （`navigation.part.dart`）：无锚 → `_navigateToChapter(manual: true)`（与修复前
    逐字相同）；同章带锚 → `_jumpToFragmentInPlace`（不重载章节，不闪、不丢滚动位置）；
    跨章带锚 → `_navigateToChapterWithFragment`。`_handleInternalLinkUrl` 改为复用它，
    删掉自己那份重复的同章/跨章判断——两条路径从此不可能再分叉。
  提交：本提交。
- **[x] ② 已加自动化测试** — `fushi/test/reader/reader_toc_anchor_jump_bug2383_test.dart`（本提交）：
  - `tocHrefFragment` 的取值 / 解码 / 无锚 / 坏转义四组；
  - 纯函数行为：同一章的三条目录项压平后 `index` 全相同、`fragment` 各不相同
    （**修复前红**，实测 `flatten keeps a distinct anchor…` 一条）；
  - 源码守卫：目录点击与内链走同一个 `_jumpToChapterAnchor`，目录行把
    `toc[i].fragment` 交了出去。
  另更新两条既有守卫到新结构（不变式未变，只是判据搬了家）：
  `fushi/test/pages/reader_internal_link_guard_static_test.dart`（内链三分支现在钉在
  `_jumpToChapterAnchor` 体内）、
  `fushi/test/media/audiobook/reader_manual_navigation_follow_guard_test.dart`
  （「内链/目录跳转是用户发起的 `manual: true`」现在钉入口 + helper 两侧）。
- **验证**（按退出码判绿）：
  - `flutter analyze`（fushi，含 test / integration_test）→ No issues found。
  - `flutter test test/reader` → 1593 例通过；红的两条是
    `reader_audio_cue_identity` / `reader_favorite_coordinates`（headless Chrome 探针，
    `chrome exited early`）——**已把本次全部 lib 改动 `git checkout` 掉在同一 worktree
    复跑，基线同样红**，与本改动无关。
  - `flutter test test/epub test/media/audiobook` → 1318 例全绿，exit=0。
  - `flutter test test/pages test/epub` → 3806 例通过（内链守卫更新后）。
- **备注**：本机无可用 Android 模拟器 / 真机，移动端原始路径的肉眼复测未做。
  另发现一条**独立**缺陷（本次未改，避免扩大范围）：`_navigateToVirtualPage`
  在 spread 分支丢弃 `progress` 参数（`navigation.part.dart`，`_navigateToSpread`
  硬编码 `progress: 0.0`），跨页模式下往回翻章会落到跨页开头而非结尾。
