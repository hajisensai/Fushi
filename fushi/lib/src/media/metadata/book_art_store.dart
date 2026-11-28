/// 书 / 漫画「已获取的每卷封面 + 横幅」的本机存储与内存索引。
///
/// **刮削层与用户 override 分开存**：用户手选 / 弹窗选中的封面仍是 override 缩略图
/// （`<thumbnails>/<hash>`），本层是另一份文件，取图链顺序是
/// override → 刮削层 → 内嵌封面（[ReaderMediaSource] 接到 [MediaSource] 的钩子上）。
///
/// 布局（全部在 `<thumbnails>/` 下，是可重建的本机缓存，不进同步 / 备份）：
/// - `scraped/<sha1(bookKey)>`：这本书的卷封面（无扩展名，与 override 同口径）；
/// - `scraped/<sha1(bookKey)>.json`：来源元数据（[BookArtRecord]：匹配源、系列、
///   卷号、各图 URL 与尺寸、是否用户钉死、被否决的 URL；署名、重刮沿用钉死的系列、
///   不降清晰度都靠它）；
/// - `undo_backups/book_art/`：写入 / 清除前的旧刮削层（卷封面 + 本层贴上的横幅；
///   撤销用，保留 30 天，按文件名里的时间戳判过期）。
///
/// **横幅不在本层存**（BUG-5609）：系列横幅就是书的横版背景图，与书籍刮削写的背景图
/// 同一份真相——`item_images` 的 backdrop，只经 [ItemScrapeStore] 写（文件按横幅 URL
/// 在同系列各卷间共用一份）。书详情页、首页卡片（单本与系列合并卡）、书架系列块、
/// 合集页都只读那一份。记录里的 [BookArtRecord.bannerKey] / [BookArtRecord.bannerUrl]
/// 只记「获取」把哪张横幅贴到了这本书上：书当前背景图的 `source_url` 等于
/// bannerUrl 才算本层写的（[bannerStateOf]），清除 / 否决 / 撤销只撤这种，别的来源
/// （书籍刮削、手选）的背景图一律不碰，获取也不覆盖它们（[applyBanner]）。
/// 旧版的 `scraped_banners/` 目录由 [migrateLegacyBanners] 一次性搬进去后删除。
///
/// 卷封面没有新表：元数据跟着文件走，文件在则元数据在，不会出现「行在、图没了」的
/// 两份真相；删书时 [ReaderMediaSource.clearOverrideValues] 一并删除。
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/foundation/engine_platform_hooks.dart'
    show evictImageCacheForFile;
import 'package:fushi_engine/media/cover_file_writer.dart'
    show CoverImageInvalidException, writeCoverBytesAtomically;
import 'package:fushi_engine/media/item_scrape/item_scrape_store.dart';
import 'package:fushi_engine/media/metadata/book_art/book_art_plan.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/metadata/undo_backup_retention.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// 一本书的刮削来源元数据。可 JSON 往返。
@immutable
class BookArtRecord {
  const BookArtRecord({
    required this.bookKey,
    required this.source,
    required this.seriesId,
    required this.seriesTitle,
    required this.scrapedAt,
    this.seriesUrl,
    this.volume,
    this.coverSource,
    this.coverUrl,
    this.coverWidth,
    this.coverHeight,
    this.bannerKey,
    this.bannerUrl,
    this.bannerWidth,
    this.bannerHeight,
    this.matchScore,
    this.pinned = false,
    this.rejectedCoverUrls = const <String>[],
    this.originalEditionCovers = false,
    this.coverFromOriginalEdition = false,
  });

  /// 用户单本移除了贴错的封面：只留否决记录（没有系列、没有卷封面），重刮时不再
  /// 选这些 URL。
  factory BookArtRecord.rejection({
    required String bookKey,
    required List<String> rejectedCoverUrls,
    required int scrapedAt,
  }) => BookArtRecord(
    bookKey: bookKey,
    source: '',
    seriesId: '',
    seriesTitle: '',
    scrapedAt: scrapedAt,
    rejectedCoverUrls: rejectedCoverUrls,
  );

  factory BookArtRecord.fromJson(Map<String, Object?> json) => BookArtRecord(
    bookKey: json['bookKey'] as String? ?? '',
    source: json['source'] as String? ?? '',
    seriesId: json['seriesId'] as String? ?? '',
    seriesTitle: json['seriesTitle'] as String? ?? '',
    seriesUrl: json['seriesUrl'] as String?,
    volume: json['volume'] as num?,
    coverSource: json['coverSource'] as String?,
    coverUrl: json['coverUrl'] as String?,
    coverWidth: (json['coverWidth'] as num?)?.toInt(),
    coverHeight: (json['coverHeight'] as num?)?.toInt(),
    bannerKey: json['bannerKey'] as String?,
    bannerUrl: json['bannerUrl'] as String?,
    bannerWidth: (json['bannerWidth'] as num?)?.toInt(),
    bannerHeight: (json['bannerHeight'] as num?)?.toInt(),
    matchScore: (json['matchScore'] as num?)?.toDouble(),
    scrapedAt: (json['scrapedAt'] as num?)?.toInt() ?? 0,
    pinned: json['pinned'] == true,
    originalEditionCovers: json['originalEditionCovers'] == true,
    coverFromOriginalEdition: json['coverFromOriginalEdition'] == true,
    rejectedCoverUrls: <String>[
      if (json['rejectedCoverUrls'] is List)
        for (final Object? u in json['rejectedCoverUrls'] as List)
          if (u is String) u,
    ],
  );

  final String bookKey;

  /// 系列匹配源（`mangabaka` / `bangumi`，[BookArtSource.wire]）。
  final String source;
  final String seriesId;
  final String seriesTitle;

  /// 系列页（署名 / 查看条目）。
  final String? seriesUrl;

  /// 对齐的本地卷号。
  final num? volume;

  /// 卷封面实际来自哪个源；null = 没写卷封面（本地更清晰 / 两边都没有）。
  final String? coverSource;
  final String? coverUrl;
  final int? coverWidth;
  final int? coverHeight;

  /// 系列横幅键（`<source>_<seriesId>`）；null = 获取没有往这本书的背景图上贴横幅
  /// （系列没有横幅，或书已有别处来的背景图、按覆盖策略不动它）。
  final String? bannerKey;

  /// 贴上去的那张横幅的 URL = 书背景图行（`item_images`）的 `source_url`：两者相等
  /// 才算这张背景图是获取写的（[BookArtStore.bannerStateOf]）。
  final String? bannerUrl;
  final int? bannerWidth;
  final int? bannerHeight;
  final double? matchScore;

  /// 毫秒时间戳。
  final int scrapedAt;

  /// 系列是用户在待确认面板 / ops 里钉死的：之后重刮沿用，不再自动匹配覆盖。
  final bool pinned;

  /// 用户移除过的卷封面 URL（贴错了）：重刮不再选它们。
  final List<String> rejectedCoverUrls;

  /// 非日文版的系列，用户在结果面板选了「用 MangaBaka 封面」：本版本语言没有的卷
  /// 用原版（日文版）卷封面。默认 false = 保留书里的封面（BUG-5287）。按系列记，
  /// 同组每本的记录都带着，重刮沿用。
  final bool originalEditionCovers;

  /// 这本的卷封面是按 [originalEditionCovers] 取的原版（日文版）封面：改回「保留
  /// 书里的封面」时据此删掉它，有了本语言的封面时据此替换（不按清晰度保留它）。
  final bool coverFromOriginalEdition;

  /// 有匹配到的系列（否决记录没有）。
  bool get hasSeries => source.isNotEmpty && seriesId.isNotEmpty;

  /// 封面或横幅有任何一项来自 MangaBaka（要可见署名）。
  bool get usesMangaBaka =>
      coverSource == BookArtSource.mangabaka.wire ||
      (bannerKey?.startsWith('${BookArtSource.mangabaka.wire}_') ?? false);

  /// 本层贴在书背景图上的横幅 URL（[bannerKey] 为 null 时不算，旧记录可能只剩 URL）。
  String? get appliedBannerUrl => bannerKey == null ? null : bannerUrl;

  /// 横幅四项换成 [from] 的（null = 清掉），其余不变。
  BookArtRecord withBannerOf(BookArtRecord? from) => BookArtRecord(
    bookKey: bookKey,
    source: source,
    seriesId: seriesId,
    seriesTitle: seriesTitle,
    scrapedAt: scrapedAt,
    seriesUrl: seriesUrl,
    volume: volume,
    coverSource: coverSource,
    coverUrl: coverUrl,
    coverWidth: coverWidth,
    coverHeight: coverHeight,
    bannerKey: from?.bannerKey,
    bannerUrl: from?.bannerUrl,
    bannerWidth: from?.bannerWidth,
    bannerHeight: from?.bannerHeight,
    matchScore: matchScore,
    pinned: pinned,
    rejectedCoverUrls: rejectedCoverUrls,
    originalEditionCovers: originalEditionCovers,
    coverFromOriginalEdition: coverFromOriginalEdition,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'bookKey': bookKey,
    'source': source,
    'seriesId': seriesId,
    'seriesTitle': seriesTitle,
    'seriesUrl': ?seriesUrl,
    'volume': ?volume,
    'coverSource': ?coverSource,
    'coverUrl': ?coverUrl,
    'coverWidth': ?coverWidth,
    'coverHeight': ?coverHeight,
    'bannerKey': ?bannerKey,
    'bannerUrl': ?bannerUrl,
    'bannerWidth': ?bannerWidth,
    'bannerHeight': ?bannerHeight,
    'matchScore': ?matchScore,
    'scrapedAt': scrapedAt,
    if (pinned) 'pinned': true,
    if (rejectedCoverUrls.isNotEmpty) 'rejectedCoverUrls': rejectedCoverUrls,
    if (originalEditionCovers) 'originalEditionCovers': true,
    if (coverFromOriginalEdition) 'coverFromOriginalEdition': true,
  };
}

/// 写入 / 清除前的旧刮削层快照（撤销用）。可 JSON 往返。
class BookArtSnapshot {
  const BookArtSnapshot({
    required this.bookKey,
    this.record,
    this.coverBackupPath,
    this.bannerBackupPath,
  });

  factory BookArtSnapshot.fromJson(Map<String, Object?> json) =>
      BookArtSnapshot(
        bookKey: json['bookKey'] as String? ?? '',
        record: json['record'] is Map
            ? BookArtRecord.fromJson(
                Map<String, Object?>.from(json['record'] as Map),
              )
            : null,
        coverBackupPath: json['coverBackupPath'] as String?,
        bannerBackupPath: json['bannerBackupPath'] as String?,
      );

  final String bookKey;

  /// 之前的元数据；null = 之前没有刮削层。
  final BookArtRecord? record;

  /// 之前那张卷封面的备份；null = 之前没有卷封面文件。
  final String? coverBackupPath;

  /// 之前本层贴在书背景图上的那张横幅的备份（清除时它随最后一行被回收，撤销要能
  /// 拿回来）；null = 之前没有本层贴的横幅。
  final String? bannerBackupPath;

  Map<String, Object?> toJson() => <String, Object?>{
    'bookKey': bookKey,
    'record': record?.toJson(),
    'coverBackupPath': coverBackupPath,
    'bannerBackupPath': ?bannerBackupPath,
  };
}

/// 一本书的横版背景图（`item_images` backdrop）相对「获取各卷封面与横幅」的归属。
enum BookArtBannerState {
  /// 没有背景图（或书已不在库）：获取可以贴横幅。
  none,

  /// 背景图是获取贴上去的（`source_url` == 记录里的 bannerUrl）：重新获取可以换，
  /// 清除 / 否决 / 撤销可以撤。
  fetched,

  /// 背景图来自别处（书籍刮削、手选）：获取不覆盖，清除不删。
  other,
}

/// 刮削层的存储 + 内存索引。按缩略图目录取单例（[of]），渲染期只查内存。
class BookArtStore extends ChangeNotifier {
  BookArtStore._(this.thumbnailsDirectory, this._now);

  /// 缩略图目录 → 存储（生产只有一个；测试各用临时目录）。
  static final Map<String, BookArtStore> _instances = <String, BookArtStore>{};

  /// [thumbnailsDirectory] 对应的存储。横幅读写走 [database] 的 `item_images`
  /// （[itemScrape] 缺省按 [database] 新建；测试注入临时附加图目录）：会动横幅的
  /// 调用方（获取、清除、否决、撤销、搬家）必须传 [database]，没绑过库时这些方法
  /// 抛 [StateError]，不静默跳过。只查卷封面的渲染路径（取图链）可以不传。同一
  /// 目录换了库（数据根迁移后重开）时改绑到新库。
  static BookArtStore of(
    Directory thumbnailsDirectory, {
    FushiDatabase? database,
    ItemScrapeStore? itemScrape,
    DateTime Function() now = DateTime.now,
  }) {
    final BookArtStore store = _instances.putIfAbsent(
      p.normalize(thumbnailsDirectory.absolute.path),
      () => BookArtStore._(thumbnailsDirectory, now),
    );
    if (database != null) store._bind(database, itemScrape);
    return store;
  }

  /// 测试接缝：丢掉全部单例（换临时目录后重读）。
  @visibleForTesting
  static void resetForTesting() => _instances.clear();

  final Directory thumbnailsDirectory;
  final DateTime Function() _now;
  FushiDatabase? _boundDatabase;
  ItemScrapeStore? _boundItemScrape;

  void _bind(FushiDatabase database, ItemScrapeStore? itemScrape) {
    if (itemScrape != null) {
      _boundDatabase = database;
      _boundItemScrape = itemScrape;
    } else if (!identical(database, _boundDatabase)) {
      _boundDatabase = database;
      _boundItemScrape = ItemScrapeStore(database);
      _legacyMigration = null;
    }
  }

  FushiDatabase get _database =>
      _boundDatabase ??
      (throw StateError('BookArtStore.of(…) 没传 database：横幅在 item_images 里'));

  ItemScrapeStore get _itemScrape =>
      _boundItemScrape ??
      (throw StateError('BookArtStore.of(…) 没传 database：横幅在 item_images 里'));

  /// 撤销备份保留多久（与书元数据写回同口径）。
  static const Duration backupRetention = Duration(days: 30);

  Directory get _coverDir =>
      Directory(p.join(thumbnailsDirectory.path, 'scraped'));

  /// 旧版横幅目录（BUG-5609 前横幅单独存在这里）；只有 [migrateLegacyBanners] 读。
  Directory get _legacyBannerDir =>
      Directory(p.join(thumbnailsDirectory.path, 'scraped_banners'));
  Directory get _backupDir =>
      Directory(p.join(thumbnailsDirectory.path, 'undo_backups', 'book_art'));

  /// 有卷封面文件的 bookKey 哈希；null = 还没扫目录。
  Set<String>? _coverHashes;

  /// 已读过的元数据（键是 bookKey 哈希；值 null = 没有元数据文件）。
  final Map<String, BookArtRecord?> _records = <String, BookArtRecord?>{};

  /// bookKey → 文件名（sha1 十六进制，避开超长 / 特殊字符）。
  static String fileKeyFor(String bookKey) =>
      sha1.convert(utf8.encode(bookKey)).toString();

  /// 卷封面文件路径（不论存在与否）。
  String coverPathFor(String bookKey) =>
      p.join(_coverDir.path, fileKeyFor(bookKey));

  String _recordPathFor(String bookKey) => '${coverPathFor(bookKey)}.json';

  static String _safeName(String key) =>
      key.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');

  Set<String> _scanCovers() {
    final Set<String>? cached = _coverHashes;
    if (cached != null) return cached;
    final Set<String> found = <String>{};
    final Directory dir = _coverDir;
    if (dir.existsSync()) {
      for (final FileSystemEntity e in dir.listSync(followLinks: false)) {
        if (e is! File) continue;
        final String name = p.basename(e.path);
        if (name.contains('.')) continue; // 元数据 / 临时文件
        found.add(name);
      }
    }
    return _coverHashes = found;
  }

  /// 这本书有没有刮削卷封面（只查内存；首次调用扫一次目录）。
  bool hasCover(String bookKey) => _scanCovers().contains(fileKeyFor(bookKey));

  /// 这本书的刮削卷封面文件；没有为 null。不逐次 stat。
  File? coverFileFor(String bookKey) =>
      hasCover(bookKey) ? File(coverPathFor(bookKey)) : null;

  /// 这本书的来源元数据（读一次后缓存）。
  BookArtRecord? recordFor(String bookKey) {
    final String hash = fileKeyFor(bookKey);
    if (_records.containsKey(hash)) return _records[hash];
    BookArtRecord? record;
    final File file = File(_recordPathFor(bookKey));
    if (file.existsSync()) record = _readRecordFile(file);
    return _records[hash] = record;
  }

  static BookArtRecord? _readRecordFile(File file) {
    try {
      final Object? json = jsonDecode(file.readAsStringSync());
      if (json is Map) {
        return BookArtRecord.fromJson(Map<String, Object?>.from(json));
      }
    } on FormatException catch (e) {
      ErrorLogService.instance.logDiagnostic('BookArtStore.recordFor', '$e');
    } on FileSystemException catch (e) {
      ErrorLogService.instance.logDiagnostic('BookArtStore.recordFor', '$e');
    }
    return null;
  }

  /// 编辑弹窗要展示「封面取自 X / 署名 / 移除」的那份记录：有卷封面、或只有横幅
  /// （本地更清晰时只写了横幅）都算；只剩否决记录 / 没有刮削层为 null。
  BookArtRecord? displayableRecordFor(String bookKey) {
    final BookArtRecord? record = recordFor(bookKey);
    if (hasCover(bookKey) || record?.bannerKey != null) return record;
    return null;
  }

  /// [bookKeys] 里有没有任何一本的刮削层来自 MangaBaka（署名用）。
  bool anyFromMangaBaka(Iterable<String> bookKeys) =>
      bookKeys.any((String k) => recordFor(k)?.usesMangaBaka ?? false);

  // ── 横幅 = 书的背景图（item_images backdrop，经 ItemScrapeStore）──

  /// 书在 `item_images` 里的身份（epub = `EpubBooks.uid`）；书不在库为 null。
  Future<ItemScrapeKey?> _itemKeyOf(String bookKey) async {
    final String? uid = await _database.resolveEpubBookUid(bookKey);
    return uid == null ? null : ItemScrapeKey(MediaKind.epub, uid);
  }

  Future<ItemImageRow?> _backdropOf(ItemScrapeKey key) =>
      _itemScrape.firstImage(key, MediaImageKind.backdrop);

  static BookArtBannerState _stateOf(ItemImageRow? row, String? appliedUrl) {
    if (row == null) return BookArtBannerState.none;
    return appliedUrl != null && row.sourceUrl == appliedUrl
        ? BookArtBannerState.fetched
        : BookArtBannerState.other;
  }

  /// 这本书现在的背景图相对本层（按当前记录）的归属。书不在库为 none。
  Future<BookArtBannerState> bannerStateOf(String bookKey) async {
    final ItemScrapeKey? key = await _itemKeyOf(bookKey);
    if (key == null) return BookArtBannerState.none;
    return _stateOf(
      await _backdropOf(key),
      recordFor(bookKey)?.appliedBannerUrl,
    );
  }

  /// 把横幅 [banner]（来自 [url]）贴成这本书的背景图（同 URL 的文件各卷共用）。
  ///
  /// **覆盖策略**（BUG-5609）：只在书没有背景图、或现在那张就是本层贴的
  /// （`source_url` 是 [ownedUrl]——调用方传更新记录前的
  /// [BookArtRecord.appliedBannerUrl]——或已经是 [url]）时写；书籍刮削 / 手选来的
  /// 背景图不覆盖，返回 false。「获取各卷封面与横幅」是整套系列的批量动作，单本
  /// 已有的背景图更具体，也是用户自己刮 / 选来的。书不在库也返回 false。写入只经
  /// [ItemScrapeStore]（之后的「用户手选背景图上锁」随之生效）。
  Future<bool> applyBanner(
    String bookKey,
    File banner, {
    required String url,
    String? ownedUrl,
  }) async {
    final ItemScrapeKey? key = await _itemKeyOf(bookKey);
    if (key == null) return false;
    final ItemImageRow? row = await _backdropOf(key);
    if (row != null && row.sourceUrl != url && row.sourceUrl != ownedUrl) {
      return false;
    }
    if (row != null && row.sourceUrl == url && File(row.path).existsSync()) {
      return true;
    }
    await _itemScrape.setSharedImageFromFile(
      key,
      MediaImageKind.backdrop,
      banner,
      sourceUrl: url,
    );
    notifyListeners();
    return true;
  }

  /// 撤掉这本书背景图——只在它就是来自 [url] 的那张（本层贴的）时；别的来源不动。
  /// 返回是否撤了。
  Future<bool> clearBannerFrom(String bookKey, {required String url}) async {
    final ItemScrapeKey? key = await _itemKeyOf(bookKey);
    if (key == null) return false;
    final ItemImageRow? row = await _backdropOf(key);
    if (row == null || row.sourceUrl != url) return false;
    await _itemScrape.clearImage(key, MediaImageKind.backdrop);
    notifyListeners();
    return true;
  }

  /// 撤掉当前记录说本层贴上去的那张横幅（还是那张时）。
  Future<void> _clearAppliedBanner(String bookKey) async {
    final String? url = recordFor(bookKey)?.appliedBannerUrl;
    if (url != null) await clearBannerFrom(bookKey, url: url);
  }

  /// 本层贴在这本书背景图上、文件还在的那张横幅；没有为 null。
  Future<File?> _appliedBannerFile(String bookKey) async {
    final ItemScrapeKey? key = await _itemKeyOf(bookKey);
    if (key == null) return null;
    final ItemImageRow? row = await _backdropOf(key);
    if (_stateOf(row, recordFor(bookKey)?.appliedBannerUrl) !=
        BookArtBannerState.fetched) {
      return null;
    }
    final File file = File(row!.path);
    return file.existsSync() ? file : null;
  }

  Future<void>? _legacyMigration;

  /// 一次性把旧版 `scraped_banners/` 里的横幅搬进书的背景图（BUG-5609），搬完删掉
  /// 旧目录。旧目录在就是标记：没有它直接返回；中途失败下次再跑（逐条幂等）。
  ///
  /// 每条带横幅的记录按与获取相同的覆盖策略处理：书没有背景图 → 贴上（文件同 URL
  /// 共用）；背景图已经是那张（上次搬到一半）→ 保留；书已有别处来的背景图、旧横幅
  /// 文件不在 / 坏了、书已不在库 → 记录去掉横幅（本层没有贴上任何东西）。
  ///
  /// 启动时由 `AppModel` 初始化收尾触发一次（与其它按数据幂等的启动搬家同处）；
  /// 本层所有会动横幅的写入口（获取、清除、否决、撤销）也先等它跑完。
  Future<void> migrateLegacyBanners() =>
      _legacyMigration ??= _migrateLegacyBanners();

  Future<void> _migrateLegacyBanners() async {
    final Directory legacy = _legacyBannerDir;
    if (!legacy.existsSync()) return;
    try {
      bool changed = false;
      final Directory covers = _coverDir;
      if (covers.existsSync()) {
        for (final FileSystemEntity e in covers.listSync(followLinks: false)) {
          if (e is! File || !e.path.endsWith('.json')) continue;
          final BookArtRecord? record = _readRecordFile(e);
          final String? bannerKey = record?.bannerKey;
          if (record == null || bannerKey == null) continue;
          final bool kept = await _migrateLegacyBanner(
            record,
            File(p.join(legacy.path, _safeName(bannerKey))),
          );
          if (!kept) await write(record: record.withBannerOf(null));
          changed = true;
        }
      }
      await legacy.delete(recursive: true);
      if (changed) notifyListeners();
    } catch (e, stack) {
      // 文件还被占着 / 库忙：旧目录留着，下一次调用重跑（已搬的条目幂等跳过）。
      _legacyMigration = null;
      ErrorLogService.instance.log('BookArtStore.migrateLegacy', e, stack);
    }
  }

  /// 一条旧记录的横幅：贴上 / 已贴着返回 true；按覆盖策略或文件问题贴不上返回 false。
  Future<bool> _migrateLegacyBanner(BookArtRecord record, File legacy) async {
    final String? url = record.bannerUrl;
    final ItemScrapeKey? key = await _itemKeyOf(record.bookKey);
    if (url == null || key == null) return false;
    final ItemImageRow? row = await _backdropOf(key);
    if (row != null) return row.sourceUrl == url;
    if (!legacy.existsSync()) return false;
    try {
      await _itemScrape.setSharedImageFromFile(
        key,
        MediaImageKind.backdrop,
        legacy,
        sourceUrl: url,
      );
      return true;
    } on CoverImageInvalidException catch (e) {
      ErrorLogService.instance.logDiagnostic(
        'BookArtStore.migrateLegacy',
        '$e',
      );
      return false;
    }
  }

  // ── 卷封面 + 记录 ──

  /// 写入一本书的刮削层：[coverBytes] 非空时写卷封面（原子写 + 解码缓存驱逐），
  /// 元数据整份替换。[coverBytes] 为 null 时保留已有卷封面文件不动（只更新元数据，
  /// 例如只拿到了横幅）；[removeCover] 时删掉已有卷封面（换了系列，旧图不属于它）。
  /// 只写本层文件；横幅（书背景图）由 [applyBanner] / [clearBannerFrom] 写。
  Future<void> write({
    required BookArtRecord record,
    List<int>? coverBytes,
    bool removeCover = false,
  }) async {
    final String bookKey = record.bookKey;
    await _coverDir.create(recursive: true);
    if (coverBytes == null && removeCover) {
      await _deleteCover(bookKey);
    } else if (coverBytes != null) {
      await writeCoverBytesAtomically(
        bytes: coverBytes,
        destPath: coverPathFor(bookKey),
      );
      _scanCovers().add(fileKeyFor(bookKey));
    }
    final File meta = File(_recordPathFor(bookKey));
    final File tmp = File('${meta.path}.tmp');
    await tmp.writeAsString(jsonEncode(record.toJson()), flush: true);
    if (meta.existsSync()) await meta.delete();
    await tmp.rename(meta.path);
    _records[fileKeyFor(bookKey)] = record;
    notifyListeners();
  }

  Future<void> _deleteCover(String bookKey) async {
    final File cover = File(coverPathFor(bookKey));
    if (cover.existsSync()) {
      await cover.delete();
      await evictImageCacheForFile(cover);
    }
    _scanCovers().remove(fileKeyFor(bookKey));
  }

  /// 删除一本书的刮削层（卷封面 + 元数据 + 本层贴上的横幅；别处来的背景图不动）。
  Future<void> remove(String bookKey) async {
    await migrateLegacyBanners();
    await _clearAppliedBanner(bookKey);
    final String hash = fileKeyFor(bookKey);
    final File meta = File(_recordPathFor(bookKey));
    await _deleteCover(bookKey);
    if (meta.existsSync()) await meta.delete();
    _records[hash] = null;
    notifyListeners();
  }

  /// 用户判定这本书的刮削封面贴错了：删掉卷封面与本层贴上的横幅，只留否决记录
  /// （把这张图的 URL 记进 [BookArtRecord.rejectedCoverUrls]），重刮不会再把它写回来。
  Future<void> rejectCover(String bookKey) async {
    await migrateLegacyBanners();
    final BookArtRecord? previous = recordFor(bookKey);
    final String? url = previous?.coverUrl;
    final List<String> rejected = <String>[
      ...?previous?.rejectedCoverUrls,
      if (url != null && !(previous!.rejectedCoverUrls.contains(url))) url,
    ];
    if (rejected.isEmpty) {
      await remove(bookKey);
      return;
    }
    await _clearAppliedBanner(bookKey);
    await write(
      record: BookArtRecord.rejection(
        bookKey: bookKey,
        rejectedCoverUrls: rejected,
        scrapedAt: _now().millisecondsSinceEpoch,
      ),
      removeCover: true,
    );
  }

  // ── 撤销快照 ──

  /// 写入 / 清除前调用：把旧刮削层（卷封面、本层贴上的横幅、元数据）备份出来，返回
  /// 可撤销的快照。横幅也备份：清除时它随最后一行被回收，撤销要能把它拿回来。
  Future<BookArtSnapshot> snapshot(String bookKey) async {
    await migrateLegacyBanners();
    final BookArtRecord? record = recordFor(bookKey);
    final File cover = File(coverPathFor(bookKey));
    final File? banner = await _appliedBannerFile(bookKey);
    if (!cover.existsSync() && banner == null) {
      return BookArtSnapshot(bookKey: bookKey, record: record);
    }
    await _backupDir.create(recursive: true);
    await _pruneBackups();
    final int stamp = _now().microsecondsSinceEpoch;
    String? coverBackup;
    if (cover.existsSync()) {
      coverBackup = p.join(_backupDir.path, '${stamp}_${fileKeyFor(bookKey)}');
      await cover.copy(coverBackup);
    }
    String? bannerBackup;
    if (banner != null) {
      bannerBackup = p.join(
        _backupDir.path,
        '${stamp}_${fileKeyFor(bookKey)}_banner',
      );
      await banner.copy(bannerBackup);
    }
    return BookArtSnapshot(
      bookKey: bookKey,
      record: record,
      coverBackupPath: coverBackup,
      bannerBackupPath: bannerBackup,
    );
  }

  /// 丢弃一份没用上的快照（写入失败时），删掉它的备份文件。
  Future<void> discardSnapshot(BookArtSnapshot snapshot) async {
    for (final String? path in <String?>[
      snapshot.coverBackupPath,
      snapshot.bannerBackupPath,
    ]) {
      if (path == null) continue;
      try {
        final File f = File(path);
        if (f.existsSync()) await f.delete();
      } on FileSystemException catch (e) {
        ErrorLogService.instance.logDiagnostic('BookArtStore.discard', '$e');
      }
    }
  }

  /// [snapshot] 还能不能完整恢复（卷封面备份在；要恢复的横幅已经贴在书上或其备份
  /// 在）。撤销多本前先逐本检查，避免恢复到一半才发现缺备份。
  Future<bool> canRestore(BookArtSnapshot snapshot) async {
    final String? cover = snapshot.coverBackupPath;
    if (cover != null && !File(cover).existsSync()) return false;
    final String? url = snapshot.record?.appliedBannerUrl;
    final String? bannerBackup = snapshot.bannerBackupPath;
    if (url != null &&
        bannerBackup != null &&
        !File(bannerBackup).existsSync()) {
      final ItemScrapeKey? key = await _itemKeyOf(snapshot.bookKey);
      final ItemImageRow? row = key == null ? null : await _backdropOf(key);
      if (row?.sourceUrl != url) return false;
    }
    return true;
  }

  /// 把刮削层恢复成 [snapshot]（之前没有 → 清除）。备份已不在时抛 [StateError]
  /// （不拿别的图凑数）；调用方应先用 [canRestore] 逐本检查。
  Future<void> restore(BookArtSnapshot snapshot) async {
    await migrateLegacyBanners();
    final BookArtRecord? record = snapshot.record;
    final String? backup = snapshot.coverBackupPath;
    if (record == null && backup == null) {
      await remove(snapshot.bookKey);
      return;
    }
    if (!await canRestore(snapshot)) {
      throw StateError('封面备份已不在（超过 ${backupRetention.inDays} 天会被清理）');
    }
    await _restoreBanner(snapshot);
    final List<int>? bytes = backup == null
        ? null
        : await File(backup).readAsBytes();
    await write(
      record:
          record ??
          BookArtRecord(
            bookKey: snapshot.bookKey,
            source: '',
            seriesId: '',
            seriesTitle: '',
            scrapedAt: _now().millisecondsSinceEpoch,
          ),
      coverBytes: bytes,
      // 之前只有元数据、没有卷封面文件：删掉现在的卷封面。
      removeCover: backup == null,
    );
    await discardSnapshot(snapshot);
  }

  /// 书背景图恢复到快照时本层贴的那张：现在贴着的本层横幅（按当前记录）与快照不同
  /// 就先撤掉，快照有横幅且书上没有别处来的背景图时用备份贴回去。
  Future<void> _restoreBanner(BookArtSnapshot snapshot) async {
    final ItemScrapeKey? key = await _itemKeyOf(snapshot.bookKey);
    if (key == null) return;
    final String? want = snapshot.record?.appliedBannerUrl;
    final String? current = recordFor(snapshot.bookKey)?.appliedBannerUrl;
    final ItemImageRow? row = await _backdropOf(key);
    if (row != null && want != null && row.sourceUrl == want) return;
    bool occupied = row != null;
    if (row != null && current != null && row.sourceUrl == current) {
      await _itemScrape.clearImage(key, MediaImageKind.backdrop);
      occupied = false;
    }
    final String? bannerBackup = snapshot.bannerBackupPath;
    if (want == null || occupied || bannerBackup == null) return;
    await _itemScrape.setSharedImageFromFile(
      key,
      MediaImageKind.backdrop,
      File(bannerBackup),
      sourceUrl: want,
    );
  }

  /// 当前状态摘要（撤销前判「之后又被改过」）：卷封面文件 sha256 + 元数据时间戳 +
  /// 书背景图的来源（别处换了背景图也算改过）。
  Future<Map<String, Object?>> fingerprint(String bookKey) async {
    final File cover = File(coverPathFor(bookKey));
    final ItemScrapeKey? key = await _itemKeyOf(bookKey);
    final ItemImageRow? backdrop = key == null ? null : await _backdropOf(key);
    return <String, Object?>{
      'coverSha': cover.existsSync()
          ? sha256.convert(await cover.readAsBytes()).toString()
          : null,
      'scrapedAt': recordFor(bookKey)?.scrapedAt,
      'bannerKey': recordFor(bookKey)?.bannerKey,
      'backdrop': backdrop == null ? null : (backdrop.sourceUrl ?? ''),
    };
  }

  Future<void> _pruneBackups() => pruneUndoBackups(
    _backupDir,
    cutoff: _now().subtract(backupRetention),
    logTag: 'BookArtStore.prune',
  );
}
