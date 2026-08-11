import 'package:fushi/src/media/media_item.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/mining/galgame_library.dart';
import 'package:fushi_core/fushi_core.dart';

/// 媒体统一路线 P4：display-title 统一解析门面。
///
/// # 身份 vs 显示红线契约
///
/// - **身份（恒用 raw title）**：落库列、统计聚合键（`reading_statistics.title` /
///   `addMineCountPerBook.title` / `lookupBookIdentity.title`）、文件名派生
///   （`bookKey = sanitizeTtuFilename(title)`）、同步/备份资产键
///   （`sync_manager` / `backup` 系）、收藏句 / 制卡句的 `bookTitle` /
///   `documentTitle` **落库快照**。这些键一旦经 override 改写，历史聚合会分叉、
///   跨端身份会漂移——绝不过本门面。
/// - **显示（恒过本门面）**：一切给人看的地方——列表 / 弹窗 / 页标题 / 统计明细行 /
///   通知 / 给人看的导出（分组标题、导出文件名等，不被任何程序 re-parse 回身份）。
///
/// # 三套存储机制（保留不动，本门面只做只读薄委托）
///
/// - **书**：偏好 override 层（[MediaSource.getDisplayTitleFromMediaItem] /
///   [ReaderFushiSource.overrideTitleForBookKey] /
///   [ReaderFushiSource.overrideTitleForSrtUid]，全同步零 IO），raw 真值在
///   `epub_books.title` / `srt_books.title`。
/// - **视频**：直改 `video_books.title` 列——**无覆盖层是正确设计**，raw 即显示名。
/// - **游戏**：[GalgameEntry.displayName]（customData.name > nameCn > name）。
///
/// # 跨端下发（BUG-1488 已拍板：显示名跟着书走）
///
/// 「母设备改过名的书，同步到子设备仍显示原书名」——因为改名只落本机偏好，
/// 而三条出境通道全把它当设备设置。现在三条都通了，且**只搬显示名，绝不搬身份**：
///
/// - 互联清单：`AppModelLibraryHostService.listBooks` 填 `RemoteBookInfo.displayTitle`
///   （additive wire 键，与 raw title 相同时不写；旧 host/旧 peer 天然回落 raw）。
///   消费恒走 `RemoteBookInfo.displayName`；`downloadId` / `bookKey` 仍是 raw。
/// - 下载落地：peer 导入后把 host 的显示名写成本机 override（本机已有 override
///   则保留本机的）。
/// - 备份：`override_title://` 行改归「内容」——备份导出的 settings 谓词不再 strip
///   它，合并导入 `BackupMergeEngine._mergeOverrideTitlePrefs` 按 insert-if-absent 并入。
///
/// 仍存的能力缺口：override 偏好**没有时刻列**，做不了 LWW ⇒ 对端**第二次**改名
/// 无法覆盖本机已有的 override。补它需要给 override 一个 `updatedAt` 载体
/// （对照 `book_custom_css`），属独立 schema 变更。

/// 书（EPUB / SRT / 有声书）的显示名解析。
///
/// 三通道按序取一（与既有身份规则一致，零新逻辑，全部委托
/// [ReaderFushiSource] 既有 API）：
///
/// 1. [item]：已持有完整 [MediaItem] 的调用方（书架卡 / 长按弹窗同源）。
///    ⚠️ 坑：[MediaSource.getOverrideTitleFromMediaItem] 在 `!item.canEdit` 时
///    **静默返 null**——合成 [MediaItem] 必须 `canEdit: true`（参照
///    `reader_fushi_source.dart` `_overrideTitleForIdentifier` 的合成方式），
///    否则 override 永远失效且无任何报错。
/// 2. [bookKey]：EPUB 身份（含 EPUB 配对的 SRT/有声书行——它们与 EPUB 卡共享
///    `hoshi://book/<bookKey>` 身份，见 BUG-1018 A3）。空串视同未提供。
/// 3. [srtUid]：standalone SRT 书（bookKey 空串哨兵）的身份
///    `hoshi://srtbook/<uid>`。
///
/// SRT 书可同时传 [bookKey]（`book.bookKey`）与 [srtUid]（`book.uid`）：
/// bookKey 非空走 EPUB 身份，否则回落 srtUid——与 `_srtBookMediaItem` 的
/// 身份分派完全一致。
///
/// 查不到 override 时回退 [rawTitle]。
String displayTitleForBook({
  MediaItem? item,
  String? bookKey,
  String? srtUid,
  required String rawTitle,
}) {
  final ReaderFushiSource source = ReaderFushiSource.instance;
  if (item != null) {
    // getDisplayTitleFromMediaItem = override ?? item.title；item 通道下
    // item.title 就是 raw，语义与其余通道一致。
    return source.getDisplayTitleFromMediaItem(item);
  }
  if (bookKey != null && bookKey.isNotEmpty) {
    return source.overrideTitleForBookKey(bookKey) ?? rawTitle;
  }
  if (srtUid != null && srtUid.isNotEmpty) {
    return source.overrideTitleForSrtUid(srtUid) ?? rawTitle;
  }
  return rawTitle;
}

/// 视频的显示名解析：显式 no-op。
///
/// 视频改名直写 `video_books.title` 列（无覆盖层是正确设计），raw 即显示名。
/// 本函数存在是为了让面级守卫知道「这里想过」——视频上屏面统一走本入口，
/// 将来若引入覆盖层只改这一处。
String displayTitleForVideo(VideoBookRow row) => row.title;

/// 游戏的显示名解析：委托 [GalgameEntry.displayName]
/// （customData.name > nameCn > name > 本地默认名）。
///
/// [entry] 查不到（已删游戏 / 活动行按旧名无法匹配库内条目）时回退 [rawTitle]
/// （活动事件落库时的标题快照）。
String displayTitleForGame({
  GalgameEntry? entry,
  required String rawTitle,
}) {
  final String? name = entry?.displayName;
  if (name == null || name.isEmpty) {
    return rawTitle;
  }
  return name;
}

/// 统计 / 活动行「只有 raw title」语境的显示名解析。
///
/// `reading_statistics` 等统计行只存 title（聚合键，恒 raw）：上屏前先经
/// [bookKeyByTitle]（`epub_books.title -> bookKey` 反查表，调用页已有）拿回
/// 书身份，再走 [displayTitleForBook] 的 bookKey 通道。反查不到（视频字幕书 /
/// 已删书等）原样返回 [rawTitle]。
String displayTitleForStatRow({
  required String rawTitle,
  required Map<String, String> bookKeyByTitle,
}) {
  final String? bookKey = bookKeyByTitle[rawTitle];
  if (bookKey == null) {
    return rawTitle;
  }
  return displayTitleForBook(bookKey: bookKey, rawTitle: rawTitle);
}
