## BUG-1317 · 漫画/PDF 书改名后首页与统计仍显示旧名：override 键读写不同源
- **报告**：2026-08-01（用户：BUG-1316 调查旁支）
- **真实性**：✅ 真 bug（今天可复现，与「书↔漫画转化」无关，但转化会新增一种触发路径）。

  override 书名的偏好键把**阅读器源键**烧进去了：
  `hibiki/lib/src/media/media_source.dart:439-441`
  ```dart
  String getOverrideTitleKey(MediaItem item) =>
      'override_title://${item.mediaSourceIdentifier}/${item.uniqueKey}';
  ```
  （`MediaItem.uniqueKey` 本身又是 `'<源键>/<mediaIdentifier>'`，
  `hibiki/lib/src/media/media_item.dart:49`，所以源键在键里出现两次。）
  自定义封面同理：`media_source.dart:444-454` 的
  `getOverrideThumbnailFilename` 用 `'<mediaIdentifier>/<源键>/override_thumbnail'`
  的 hashCode 当文件名。

  **写**：编辑弹窗按条目真实的源解析
  （`hibiki/lib/src/pages/implementations/media_item_edit_dialog_page.dart:28`
  的 `widget.item.getMediaSource(appModel: appModel)`）→ 漫画书写进
  `override_title://reader_manga/...`。

  **读**：`hibiki/lib/src/media/sources/reader_hibiki_source.dart` 的
  `_overrideTitleForIdentifier` 合成一个**恒为 EPUB 源**的临时 `MediaItem`
  （`mediaSourceIdentifier: uniqueKey`，即 `reader_ttu`）去取键 →
  读的是 `override_title://reader_ttu/...`。

  两侧键不同 → 消费 `overrideTitleForBookKey` 的界面全部读不到用户改的名字：
  `hibiki/lib/src/media/display_title.dart:67`（首页「继续阅读」/ 活动流 / 阅读统计）
  与 `hibiki/lib/src/media/audiobook/audiobook_session_launcher.dart:64,105`
  （有声书通知栏标题）。书架页因为 item 来自 `_bookToMediaItem`、源键正确，
  显示的是新名 —— 于是同一本漫画在书架叫新名、在首页叫旧名。

  转化新增的触发路径：一本 EPUB 书改过名后转成漫画，键从 `reader_ttu` 变成
  `reader_manga`，**书架侧也读不到了**，用户自定义书名与封面静默丢失。

- **[ ] ① 未修复** — 正确语义是「override 跟着**书**走，不跟着阅读器走」，
  故键里不该有源键。但 `override_title://...` 与缩略图 hashCode 文件名都是**存量
  持久化键**，直接改会让所有既有 override 读不回来，需要迁移或读取期回退（读新
  规范键 → 回退依次尝试三个旧源键）。属独立改动，不并进 BUG-1316。

- **[ ] ② 未加自动化测试** —

- **备注**：`ReaderHibikiSource` 一侧还有个更小的自洽问题：`_overrideTitleForIdentifier`
  即使不改键规范，也应按 bookKey 现查 format 后合成正确的源键，而不是恒 `reader_ttu`。
