## BUG-519 · 书架编辑 SRT 书名不生效 + 长按无封面

- **报告**：2026-07-02（用户：）
- **真实性**：✅ 真 bug（两处独立根因）
  - Bug1（编辑书名不生效）：编辑保存 `executeSave`
    (`hibiki/lib/src/pages/implementations/media_item_edit_dialog_page.dart:169`)
    → `setOverrideTitleFromMediaItem`
    (`hibiki/lib/src/media/media_source.dart:482`) 只写一条 preference override
    (`override_title://<src>/<uniqueKey>`)，**从不 UPDATE `srtBooks.title`**。长按对话框走
    `getDisplayTitleFromMediaItem`（`media_source.dart:344`，应用 override → 显示新名），
    但书架 SRT 网格卡直接读 DB 原始列 `book.title`
    (`hibiki/lib/src/pages/implementations/reader_history/books.part.dart:52`，旧
    `_bookCardLayout(title: book.title)`)，忽略 override → 网格仍显示旧名。EPUB 卡两处
    都走 `getDisplayTitleFromMediaItem` 故一致，问题只在 SRT/字幕卡。
  - Bug2（长按无封面）：`_hasCover` 门
    (`hibiki/lib/src/pages/implementations/media_item_dialog_page.dart:139`) 在 override
    缩略图 / imageUrl / base64Image / extraUrl 全空时整块不渲染封面区。SRT 的
    `_srtBookMediaItem`（`books.part.dart:89`）`imageUrl` 仅在自带 `coverPath` 或
    `_epubCoverUrisByBookKey[bookKey]` 命中时非空。SRT 无自选封面且未关联 EPUB → 长按空白，
    网格却走 fallback 图标 `_buildSrtCover`（`books.part.dart:69`），两者显示不一致。
- **[x] ① 已修复** —
  - Bug1：`books.part.dart` `_buildSrtCard` 改为
    `mediaSource.getDisplayTitleFromMediaItem(_srtBookMediaItem(book))` 求书名，与长按对话框同源
    （同一 MediaItem + 同一 override 应用逻辑）。override 落 in-memory preference，`executeSave`
    末尾 `refreshTab()` → `setState` 重建即刻反映新名，无需额外 provider invalidate（DB `title` 未变）。
  - Bug2：`MediaItemDialogPage` 新增可选 `IconData? coverFallbackIcon`；无真实封面且传入时渲染
    `_buildFallbackCover`（居中占位图标，size 40 / onSurfaceVariant，与网格 `_coverPlaceholderIcon`
    一致），否则保持既有「无封面则不渲染封面块」行为（其它来源不传，向后兼容）。SRT 长按对话框按
    `isEpubBackedAudiobookSrt` 传耳机/字幕图标，与网格 `_buildSrtCover` 占位判据统一。
  - 提交：见本轮 commit 哈希。
- **[x] ② 已加自动化测试** —
  `hibiki/test/pages/shelf_srt_card_override_title_guard_test.dart`：
  ① 源码扫描守卫网格卡书名经 `getDisplayTitleFromMediaItem(srtItem)` / `_bookCardLayout(title: displayTitle)`；
  ② 守卫 SRT 长按对话框传 `coverFallbackIcon` 且对话框有 `_buildFallbackCover`；
  ③ widget 测试断言 `MediaItemDialogFrame` 传入占位封面 widget 时渲染封面块（不隐藏）。
- **备注**：`_srtBookMediaItem` 仍以 `title: book.title` 作 MediaItem 的原始 title 是正确的——
  override 在 `getDisplayTitleFromMediaItem` 层叠加，非直读原始列即为 fix。
