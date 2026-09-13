/// 阅读器的「同合集卷」上下文（BUG-2521）：当前书所属主合集里的兄弟书，供章节
/// 列表 / 插图画廊出卷切换。
///
/// 数据只读、一次装载：合集归属与成员顺序都来自 `media_collection_items`（书域
/// entryKey = `EpubBooks.uid`，与书架折叠归属同口径），不另起持久化。兄弟卷的
/// EPUB 结构在需要「查看」（列目录 / 看插图）时才在 isolate 里解析，按卷缓存。
library;

import 'dart:async' show unawaited;
import 'dart:io';

import 'package:flutter/foundation.dart' show compute;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_book.dart';
import 'package:fushi_engine/epub/epub_parser.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/audiobook/audiobook_bridge.dart'
    show TtuTocEntry;
import 'package:fushi/src/reader/ttu_toc_flatten.dart';

/// 合集里的一卷（一本书）。
class ReaderVolume {
  const ReaderVolume({
    required this.bookKey,
    required this.uid,
    required this.title,
    required this.extractDir,
    required this.format,
  });

  final String bookKey;
  final String uid;
  final String title;
  final String extractDir;
  final BookFormat format;

  /// 只有 EPUB 卷能在本阅读器里「无感查看」（解析目录 / 插图）；PDF / 漫画卷
  /// 只能整卷切过去（由各自阅读器打开）。
  bool get canPeek => format == BookFormat.epub;
}

/// 当前书的同合集卷上下文：≥2 卷才成立（单卷合集 / 不在合集里 → null）。
class ReaderVolumeContext {
  const ReaderVolumeContext({
    required this.collectionId,
    required this.collectionName,
    required this.volumes,
    required this.currentIndex,
  });

  final int collectionId;
  final String collectionName;

  /// 合集内顺序（`sortIndex` 升序，与合集详情页 / 书架卡片同序）。
  final List<ReaderVolume> volumes;

  /// 当前书在 [volumes] 里的下标。
  final int currentIndex;

  ReaderVolume get current => volumes[currentIndex];
}

/// 装载当前书（[bookUid]）的同合集卷上下文。归属取**最小 collectionId**（与书架
/// 折叠归属 `getPrimaryCollectionIdByEntry` 同一判据）；成员里只收书行仍在库的
/// epub 域条目。
Future<ReaderVolumeContext?> loadReaderVolumeContext(
  FushiDatabase db, {
  required String bookUid,
}) async {
  if (bookUid.isEmpty) return null;
  final Map<String, int> primary = await db.getPrimaryCollectionIdByEntry();
  final int? collectionId = primary['${MediaKind.epub.dbValue}|$bookUid'];
  if (collectionId == null) return null;
  final MediaCollectionRow? collection =
      await db.getMediaCollectionById(collectionId);
  if (collection == null) return null;
  final List<ReaderVolume> volumes = <ReaderVolume>[];
  for (final MediaCollectionItemRow item
      in await db.getCollectionItems(collectionId)) {
    if (item.mediaType != MediaKind.epub.dbValue) continue;
    final EpubBookRow? row = await db.getEpubBookByUid(item.entryKey);
    if (row == null) continue; // 孤儿成员（书已删）→ 读取期过滤。
    volumes.add(
      ReaderVolume(
        bookKey: row.bookKey,
        uid: row.uid,
        title: row.title,
        extractDir: row.extractDir,
        format: BookFormat.parseOrEpub(row.format),
      ),
    );
  }
  if (volumes.length < 2) return null;
  final int currentIndex =
      volumes.indexWhere((ReaderVolume v) => v.uid == bookUid);
  if (currentIndex < 0) return null;
  return ReaderVolumeContext(
    collectionId: collectionId,
    collectionName: collection.name,
    volumes: volumes,
    currentIndex: currentIndex,
  );
}

/// 由解析好的 [EpubBook] 建章节列表（与阅读器自己的 `_buildTtuToc` 同一规则：
/// 无 TOC 的书按章序号自动命名）。[autoLabel] 接 i18n 的 `auto_chapter`。
List<TtuTocEntry> buildTtuTocForBook(
  EpubBook book, {
  required String Function(int n) autoLabel,
}) {
  if (book.toc.isEmpty) {
    return List<TtuTocEntry>.generate(
      book.chapters.length,
      (int i) => TtuTocEntry(index: i, label: autoLabel(i + 1)),
    );
  }
  return flattenTtuTocEntries(book.toc, book.chapterIndexForHref);
}

/// isolate 入口：解析兄弟卷并把插图表也在 isolate 里算好（`EpubBook.images`
/// 惰性解析整本章节 HTML，放主 isolate 会卡 UI；算过的缓存随对象一起传回）。
EpubBook parseVolumeBookForPeek(String extractDir) {
  final EpubBook book = EpubParser.parseFromExtracted(extractDir);
  book.images; // 触发并缓存。
  return book;
}

/// 兄弟卷 EPUB 结构缓存：同一卷只解析一次，失败不缓存（下次再试）。
class ReaderVolumeBookCache {
  final Map<String, Future<EpubBook>> _pending = <String, Future<EpubBook>>{};

  Future<EpubBook> bookFor(ReaderVolume volume) {
    return _pending.putIfAbsent(volume.uid, () {
      final Future<EpubBook> parsed =
          compute(parseVolumeBookForPeek, volume.extractDir);
      unawaited(
        parsed.then<void>((_) {}, onError: (Object _) {
          _pending.remove(volume.uid);
        }),
      );
      return parsed;
    });
  }

  /// 把当前书已解析好的结构直接登记进来（当前卷不重复解析）。
  void seed(ReaderVolume volume, EpubBook book) {
    _pending[volume.uid] = Future<EpubBook>.value(book);
  }
}

/// 兄弟卷的插图文件解析：与阅读器 `_readerImageFileForUrl` 同一越界判据
/// （canonicalize 后必须落在该卷解压目录内），只是根目录换成该卷的。
File? volumeImageFile(ReaderVolume volume, EpubImageRef ref) {
  final String root = volume.extractDir;
  if (root.isEmpty) return null;
  final String joined = p.join(root, ref.src);
  if (!p.isWithin(p.canonicalize(root), p.canonicalize(joined))) return null;
  final File file = File(p.normalize(joined));
  return file.existsSync() ? file : null;
}
