import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' show Value;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi_engine/sync/remote_collection_adoption_service.dart';

import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/library/online_manga_shelf_sidecar.dart';

/// 在线漫画书架行的身份与建行口（**与运行时无关**的下层模块）。
///
/// 「入库」（`OnlineMangaLibraryService.add`）与「重新入库」（`OnlineMangaReshelf`）
/// 都经 [insertOnlineMangaShelfRow] 建行，建行的全部副作用（侧车、互联对端墓碑、
/// 远端合集认领）只在这里写一次。本文件只依赖描述符 / 侧车 / 数据库 / 引擎层，
/// 不进 AppModel 所在的 import 环。

/// 身份串的分隔符：NUL。
///
/// 写成 `String.fromCharCode(0)` 而不是源码里的裸字节，有两个理由：裸 NUL 会
/// 让 git 把这个 .dart 判成 binary（diff/merge 直接丢改动）；而这个值一旦变
/// 化，**全部存量书架条目的 bookKey 都会变** —— 主键失配 + 磁盘目录对不上 =
/// 用户的在线漫画整片消失。让它显式、独立、难被顺手"清理"掉。
final String _identitySeparator = String.fromCharCode(0);

/// 书架身份。
///
/// 摘要而不是明文拼接：作品 URL 会进文件路径，长度和字符集都不可控。
///
/// **v88 前的推导必须逐字节保持**：`packageName NUL sourceId NUL seriesKey`，
/// 前缀 `mihon-`。这串既是 `epub_books` 主键**也是**磁盘目录名，改一个字符就
/// 等于把所有已入库的在线漫画变成找不到的孤儿。所以 runtime 刻意**不进**
/// 摘要，只做前缀——`OnlineMangaRuntimeKind.mihon.wireValue == 'mihon'`，
/// 于是 Mihon 条目的键与 v88 完全一致，而 Aidoku 用 `aidoku-` 前缀天然不与
/// 它撞键空间。
String onlineMangaBookKeyFor({
  required OnlineMangaRuntimeKind runtime,
  required String extensionPackage,
  required String sourceId,
  required String seriesKey,
}) {
  final String identity = <String>[
    extensionPackage,
    sourceId,
    seriesKey,
  ].join(_identitySeparator);
  final String digest = sha256.convert(utf8.encode(identity)).toString();
  return '${runtime.wireValue}-${digest.substring(0, 32)}';
}

/// [entry] 的书架身份（[onlineMangaBookKeyFor]）。
String onlineMangaBookKeyOf(OnlineMangaLibraryEntry entry) =>
    onlineMangaBookKeyFor(
      runtime: entry.runtime,
      extensionPackage: entry.extensionPackage,
      sourceId: entry.sourceId,
      seriesKey: entry.series.key,
    );

/// `epub_books.chapters_json` 的派生。
String onlineMangaChaptersJson(List<OnlineMangaChapter> chapters) =>
    jsonEncode(<Map<String, Object?>>[
      for (final OnlineMangaChapter chapter in chapters) chapter.toJson(),
    ]);

/// 建一条在线漫画书架行（调用方已确认该 bookKey 不在库），返回新行。
///
/// 书目录 [extractDir] 由调用方准备好（占位 `manga.json` 等）。建行之后依次：
///  1. 写书架侧车（删书保留章节后重新入库只认它）；
///  2. 清互联对端键的删除墓碑（[clearOnlineMangaPeerDeletionTombstone]）；
///  3. 认领远端合集成员关系（[adoptOnlineMangaRemoteCollection]）。
///
/// [uid] 空串 = 新生成（重新入库时侧车里有就原样还原，卡片来源靠它重新连上）；
/// [sourceMetadata] null = `entry.encode()`（重新入库传侧车里的原文）。
Future<EpubBookRow> insertOnlineMangaShelfRow(
  FushiDatabase database, {
  required OnlineMangaLibraryEntry entry,
  required String title,
  required String? author,
  required String? coverPath,
  required String epubPath,
  required String extractDir,
  required int importedAt,
  String uid = '',
  String? sourceMetadata,
}) async {
  final String bookKey = onlineMangaBookKeyOf(entry);
  await database.insertEpubBook(
    EpubBooksCompanion.insert(
      bookKey: bookKey,
      uid: uid.isEmpty ? const Value<String>.absent() : Value<String>(uid),
      title: title,
      author: Value<String?>(author),
      coverPath: Value<String?>(coverPath),
      epubPath: epubPath,
      extractDir: extractDir,
      chapterCount: entry.chapters.length,
      chaptersJson: onlineMangaChaptersJson(entry.chapters),
      sourceMetadata: Value<String?>(sourceMetadata ?? entry.encode()),
      importedAt: importedAt,
      format: const Value<String>('manga'),
    ),
  );
  final EpubBookRow row = (await database.getEpubBook(bookKey))!;
  await writeOnlineMangaShelfSidecar(row);
  await clearOnlineMangaPeerDeletionTombstone(database, entry);
  await adoptOnlineMangaRemoteCollection(database, entry, row);
  return row;
}

/// 重新收下经互联来的漫画 = 撤销本机此前对它的「从所有设备删除」。
///
/// 那次删除的墓碑写的是**对端键**（`ReaderFushiSource.deleteBook` 经
/// `InterconnectMangaCatalog.peerBookKeyOf`，本机 `interconnect-…` 键对端认不出），
/// 而 [FushiDatabase.insertEpubBook] 只按本机键清墓碑。不在这里补清，删了又收下
/// 时那条还没推出去的墓碑会在下一轮推给 host，把用户刚重新要回来的书从 host 删掉。
Future<void> clearOnlineMangaPeerDeletionTombstone(
  FushiDatabase database,
  OnlineMangaLibraryEntry entry,
) async {
  if (entry.runtime != OnlineMangaRuntimeKind.interconnect) return;
  final String peerKey = entry.series.key;
  if (peerKey.isEmpty) return;
  await database.clearSyncDeletionTombstone(
    SyncTombstoneKind.book.dbValue,
    peerKey,
  );
}

/// 互联漫画：按描述符里带的远端合集成员关系，把本机行认领进对应合集。
Future<void> adoptOnlineMangaRemoteCollection(
  FushiDatabase database,
  OnlineMangaLibraryEntry entry,
  EpubBookRow row,
) async {
  if (entry.runtime != OnlineMangaRuntimeKind.interconnect) return;
  await RemoteCollectionAdoptionService(database).adoptMembership(
    membership: RemoteCollectionMembership.fromJson(
      entry.series.raw['collection'],
    ),
    mediaType: MediaKind.epub,
    remoteEntryKey: entry.series.key,
    localEntryKey: row.uid,
  );
}
