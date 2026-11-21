import 'dart:convert';
import 'dart:io';

import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';

/// 在线漫画书目录里的书架侧车文件名。
///
/// 书目录（`<下载根>/manga/<bookKey>`）里本来只有页图、章节 `manga.json` 与封面，
/// 而重建书架行需要的源身份（运行时 / 扩展包 / 源 ID / 作品 key）、标题、章节列表
/// 只活在 `epub_books.source_metadata` 里——行一删，`bookKey`（单向摘要）就再也
/// 还原不出它们。侧车就是这些字段的磁盘副本，「重新入库」只认它。**文件名冻结。**
const String kOnlineMangaShelfSidecarFileName = 'fushi_shelf.json';

/// 侧车格式版本（向后兼容：只增字段）。
const int kOnlineMangaShelfSidecarVersion = 1;

/// [bookDir] 下的侧车文件。
File onlineMangaShelfSidecarFile(String bookDir) =>
    File(p.join(bookDir, kOnlineMangaShelfSidecarFileName));

/// 侧车内容：重建一条在线漫画书架行所需的全部字段。
class OnlineMangaShelfSidecar {
  const OnlineMangaShelfSidecar({
    required this.bookKey,
    required this.uid,
    required this.title,
    required this.author,
    required this.coverPath,
    required this.sourceMetadata,
    required this.importedAt,
  });

  /// 从书架行取（非在线漫画行返回 null）。
  static OnlineMangaShelfSidecar? fromRow(EpubBookRow row) {
    final String? metadata = row.sourceMetadata;
    if (OnlineMangaLibraryEntry.tryParse(metadata) == null) return null;
    return OnlineMangaShelfSidecar(
      bookKey: row.bookKey,
      uid: row.uid,
      title: row.title,
      author: row.author,
      coverPath: row.coverPath,
      sourceMetadata: metadata!,
      importedAt: row.importedAt,
    );
  }

  /// 读侧车；文件缺失 / 畸形 / 描述符解析不出 → null（调用方当「无法重建」）。
  static Future<OnlineMangaShelfSidecar?> read(String bookDir) async {
    final File file = onlineMangaShelfSidecarFile(bookDir);
    if (!await file.exists()) return null;
    try {
      final Object? decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, Object?>) return null;
      final Object? bookKey = decoded['bookKey'];
      final Object? title = decoded['title'];
      final Object? metadata = decoded['sourceMetadata'];
      if (bookKey is! String || bookKey.isEmpty) return null;
      if (title is! String || metadata is! String) return null;
      if (OnlineMangaLibraryEntry.tryParse(metadata) == null) return null;
      final Object? uid = decoded['uid'];
      final Object? author = decoded['author'];
      final Object? cover = decoded['coverPath'];
      final Object? importedAt = decoded['importedAt'];
      return OnlineMangaShelfSidecar(
        bookKey: bookKey,
        uid: uid is String ? uid : '',
        title: title,
        author: author is String ? author : null,
        coverPath: cover is String ? cover : null,
        sourceMetadata: metadata,
        importedAt: importedAt is int
            ? importedAt
            : DateTime.now().millisecondsSinceEpoch,
      );
    } on FormatException {
      return null;
    } on FileSystemException {
      return null;
    }
  }

  final String bookKey;

  /// 本机稳定 uid（卡片来源链接先按它找书）；空串 = 未知，重建时新生成。
  final String uid;
  final String title;
  final String? author;

  /// 书目录内的封面文件名（与 `epub_books.cover_path` 同形：相对名）。
  final String? coverPath;

  /// `OnlineMangaLibraryEntry.encode()` 原文。
  final String sourceMetadata;
  final int importedAt;

  /// 描述符（[read] 已校验过可解析）。
  OnlineMangaLibraryEntry get entry =>
      OnlineMangaLibraryEntry.tryParse(sourceMetadata)!;

  Map<String, Object?> toJson() => <String, Object?>{
    'version': kOnlineMangaShelfSidecarVersion,
    'bookKey': bookKey,
    'uid': uid,
    'title': title,
    'author': author,
    'coverPath': coverPath,
    'sourceMetadata': sourceMetadata,
    'importedAt': importedAt,
  };
}

/// 把 [row] 的书架字段写进它书目录里的侧车（原子写）。
///
/// 非在线漫画行、书目录不存在时什么都不做（不为写侧车凭空建目录）。写失败抛
/// [FileSystemException]，由调用方决定是报错（删书保留文件）还是记日志（刷新）。
Future<void> writeOnlineMangaShelfSidecar(EpubBookRow row) async {
  final OnlineMangaShelfSidecar? sidecar = OnlineMangaShelfSidecar.fromRow(row);
  if (sidecar == null) return;
  if (row.extractDir.isEmpty || !await Directory(row.extractDir).exists()) {
    return;
  }
  final File target = onlineMangaShelfSidecarFile(row.extractDir);
  final File temporary = File('${target.path}.tmp');
  await temporary.writeAsString(jsonEncode(sidecar.toJson()), flush: true);
  if (await target.exists()) await target.delete();
  await temporary.rename(target.path);
}
