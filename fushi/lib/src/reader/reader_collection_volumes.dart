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
import 'package:fushi_engine/epub/epub_image_index_cache.dart';
import 'package:fushi_engine/epub/epub_parser.dart';
import 'package:fushi_engine/media/collections/book_series_key.dart';
import 'package:fushi_engine/media/collections/shelf_sort.dart'
    show naturalCompare;
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

  /// 卷号序（见 [readerVolumeOrder]）：同系列分卷按书名卷号升序，其余成员按合集
  /// 内顺序（`sortIndex` 升序）殿后。
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
  final MediaCollectionRow? collection = await db.getMediaCollectionById(
    collectionId,
  );
  if (collection == null) return null;
  final List<ReaderVolume> volumes = <ReaderVolume>[];
  for (final MediaCollectionItemRow item in await db.getCollectionItems(
    collectionId,
  )) {
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
  final List<ReaderVolume> ordered = <ReaderVolume>[
    for (final int i in readerVolumeOrder(<String>[
      for (final ReaderVolume v in volumes) v.title,
    ]))
      volumes[i],
  ];
  final int currentIndex = ordered.indexWhere(
    (ReaderVolume v) => v.uid == bookUid,
  );
  if (currentIndex < 0) return null;
  return ReaderVolumeContext(
    collectionId: collectionId,
    collectionName: collection.name,
    volumes: ordered,
    currentIndex: currentIndex,
  );
}

/// 卷切换（目录卷 chip 行 / 插图画廊卷 chip 行）的展示顺序：返回 [titles] 下标的
/// 一个排列。
///
/// 用户实报（《安達としまむら》合集）：chip 行第一个是 5、接着 8……当前的 3 卷
/// 排在最后面。根因是这里原样沿用合集成员的 `sortIndex`：手动「建系列 / 并入合集」
/// 按选择顺序尾插，而归组时的卷序自愈（`BookSeriesGrouper._healSeriesOrder`）要求
/// 合集**完整**可定序——混进一本「安達としまむらSS」这类番外（系列键不同）就整张
/// 合集不排，存下来的乱序就原样进了阅读器。
///
/// 规则（纯函数，与 `BookSeriesGrouper` 同一卷号判据 [parseBookSeriesKey]）：
/// - 取成员最多的那个系列键（并列取先出现的）；它至少要有 2 卷，否则原序返回
///   （主题合集不按书名尾数乱排：「Fahrenheit 451」不是第 451 卷）。
/// - 该系列的卷按卷号升序；书名里没有卷号的（通常就是第 1 卷「安達としまむら」）
///   当第 0 卷排最前——与归组排序 `_compareMembers` 同一约定；同卷号按 natural 书名，
///   再按原位（稳定）。
/// - 其余成员（番外 / 别的系列 / 解析不出系列名的）按原相对顺序排在后面。
List<int> readerVolumeOrder(List<String> titles) {
  final List<BookSeriesKey?> keys = <BookSeriesKey?>[
    for (final String title in titles) parseBookSeriesKey(title),
  ];
  final Map<String, int> counts = <String, int>{};
  for (final BookSeriesKey? k in keys) {
    if (k != null) counts[k.key] = (counts[k.key] ?? 0) + 1;
  }
  String? series;
  int best = 1;
  for (final BookSeriesKey? k in keys) {
    if (k == null) continue;
    final int n = counts[k.key]!;
    if (n > best) {
      best = n;
      series = k.key;
    }
  }
  final List<int> identity = List<int>.generate(titles.length, (int i) => i);
  if (series == null) return identity;
  final List<int> members = <int>[
    for (final int i in identity)
      if (keys[i]?.key == series) i,
  ];
  final List<int> others = <int>[
    for (final int i in identity)
      if (keys[i]?.key != series) i,
  ];
  members.sort((int a, int b) {
    final int c = (keys[a]!.volume ?? 0).compareTo(keys[b]!.volume ?? 0);
    if (c != 0) return c;
    final int t = naturalCompare(titles[a], titles[b]);
    return t != 0 ? t : a.compareTo(b);
  });
  return <int>[...members, ...others];
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
///
/// 缓存读写失败随结果带回（后台 isolate 没有日志装配点），由
/// [parseVolumeBookForPeekOffUi] 在根 isolate 记日志。
VolumePeekParse parseVolumeBookForPeek(
  ({String extractDir, String? cacheFile}) args,
) {
  final EpubBook book = EpubParser.parseFromExtracted(args.extractDir);
  // 触发并缓存；优先读盘上插图表缓存（BUG-3433），与阅读器共用同一份。
  final String? cacheFile = args.cacheFile;
  if (cacheFile == null) {
    book.images;
    return (book: book, cacheFailures: const <EpubImageIndexCacheFailure>[]);
  }
  final EpubImageIndexLoad load = loadEpubImagesWithCache(
    book,
    File(cacheFile),
  );
  return (book: book, cacheFailures: load.failures);
}

/// [parseVolumeBookForPeek] 的结果：解析好的书 + 插图表缓存读写失败。
typedef VolumePeekParse = ({
  EpubBook book,
  List<EpubImageIndexCacheFailure> cacheFailures,
});

/// 在后台 isolate 跑 [parseVolumeBookForPeek]。插图表缓存路径读全局装配点，只能在
/// 根 isolate 解析，所以在这里算好再传进去；带回的缓存失败也在这里记日志。
Future<EpubBook> parseVolumeBookForPeekOffUi(String extractDir) async {
  final File? cacheFile = await epubImageIndexCacheFileFor(extractDir);
  final VolumePeekParse parsed = await compute(parseVolumeBookForPeek, (
    extractDir: extractDir,
    cacheFile: cacheFile?.path,
  ));
  reportEpubImageIndexCacheFailures(
    'parseVolumeBookForPeek',
    parsed.cacheFailures,
  );
  return parsed.book;
}

/// 兄弟卷 EPUB 结构缓存：同一卷只解析一次，失败不缓存（下次再试）。
class ReaderVolumeBookCache {
  final Map<String, Future<EpubBook>> _pending = <String, Future<EpubBook>>{};

  Future<EpubBook> bookFor(ReaderVolume volume) {
    return _pending.putIfAbsent(volume.uid, () {
      final Future<EpubBook> parsed = parseVolumeBookForPeekOffUi(
        volume.extractDir,
      );
      unawaited(
        parsed.then<void>(
          (_) {},
          onError: (Object _) {
            _pending.remove(volume.uid);
          },
        ),
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
File? volumeImageFile(ReaderVolume volume, EpubImageRef ref) =>
    epubImageFileFor(volume.extractDir, ref);

/// 按解压目录 [extractDir] 解析 [ref] 指向的插图文件：canonicalize 后必须落在
/// 目录内、且文件真实存在，否则 null。兄弟卷与书架端插图册共用。
File? epubImageFileFor(String extractDir, EpubImageRef ref) {
  if (extractDir.isEmpty) return null;
  final String joined = p.join(extractDir, ref.src);
  if (!p.isWithin(p.canonicalize(extractDir), p.canonicalize(joined))) {
    return null;
  }
  final File file = File(p.normalize(joined));
  return file.existsSync() ? file : null;
}
