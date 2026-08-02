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

- **[x] ① 已修复** — 正确语义是「override 跟着**书**走，不跟着阅读器走」，
  故键里不该有源键。**取读取期回退、不做迁移**（对象只是 preferences 键与缩略图
  文件名 hash，读取期回退能完全规避 schema 迁移风险）。

  施工时发现规划描述漏了一半：源键不只烧在 key 字符串里，还烧在**存储命名空间**
  里——偏好落 `src:<sourceId>:<key>`（`media_source.dart` 的 `dbSourcePrefKey` +
  `MediaSource._dbPrefKey`/`_loadPreferencesFromDb`），每个源一份独立缓存。所以
  只把源键从 key 字符串里拿掉**并不能**让三源互相读到。

  落地（`hibiki/lib/src/media/media_source.dart`）：
  - `overrideStore`（默认 `this`）= override 的存储归属源；`ReaderMediaSource`
    覆盖为 `ReaderHibikiSource.instance`，书族三源统一存一处。
  - `legacyOverrideStores`（默认 `[this]`）= 读取期回退位置；`ReaderMediaSource`
    覆盖为 EPUB / 漫画 / PDF 三源，每个元素同时提供旧命名空间宿主与旧键里的源键。
  - 规范键 `override_title://<mediaIdentifier>`；规范封面文件名
    `'<mediaIdentifier>/override_thumbnail'.hashCode`。
  - 读书名 `getOverrideTitleFromMediaItem` 未命中即 `_adoptLegacyOverrideTitle`
    回退，命中后就地重写进规范键并删旧键。读封面统一走新入口
    `resolveOverrideThumbnailFile`，命中旧文件名即 `renameSync` 成规范名。
  - 写 / 清除侧对称：`setOverrideTitleFromMediaItem` 与 `clearOverrideValues` 走
    `clearOverrideTitle`（规范 + 全部旧位置），`setOverrideThumbnailFromMediaItem`
    每次变更都 `_deleteLegacyOverrideThumbnails`——否则「清除」会被回退层复活。
  - 消费点改走迁移感知入口：`reader_history/books.part.dart`（SRT 卡封面）、
    `reader_hibiki_history_page.dart`（批量刮削「已有封面则跳过」判据）。

  清理条件：一个版本后（存量已被读取期迁走）删掉 `legacyOverrideStores` 与全部
  `legacy*` helper。

- **[x] ② 已加自动化测试** — `hibiki/test/media/override_identity_test.dart` 新增
  两个 group（共 10 例，全部经变异实测确认能转红）：
  - 书名侧：规范键不含源键 / 新键写入读出三源互见 / 三个旧源键各自回退并就地重写
    成新键 / epub↔manga 转化后不丢 / 清除后旧位置不复活 /
    书架·首页·统计·通知栏四个消费面同值。
  - 封面侧：三源规范文件名同名 / 三个旧文件名各自回退并 rename 成规范名 /
    转化后不丢 / 清除后旧文件名不复活。
  另更新既有源码扫描守卫 `test/pages/booklongpress_floating_lyric_toggle_test.dart`
  的锚点（SRT 卡封面必须走 `resolveOverrideThumbnailFile`）。

- **备注**：`ReaderHibikiSource._overrideTitleForIdentifier` 恒填 `reader_ttu` 的
  自洽问题一并消解——override 身份不再含源键，`legacyOverrideStores` 取自 `this`
  （书族三源全在内），所以合成 item 填哪个源键都读到同一个值；已在该方法上加注释
  说明。`reader_ttu` 等持久化 key 本身未动。
