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
/// - `scraped_banners/<source>_<seriesId>`：系列横幅，同系列各卷共用一份；
/// - `undo_backups/book_art/`：写入 / 清除前的旧刮削层（卷封面 + 横幅；撤销用，保留
///   30 天，按文件名里的时间戳判过期）。
///
/// 没有新表：元数据跟着文件走，文件在则元数据在，不会出现「行在、图没了」的两份真相；
/// 删书时 [ReaderMediaSource.clearOverrideValues] 一并删除。
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:fushi_engine/foundation/engine_platform_hooks.dart'
    show evictImageCacheForFile;
import 'package:fushi_engine/media/cover_file_writer.dart'
    show writeCoverBytesAtomically;
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

  /// 横幅文件键（`<source>_<seriesId>`）；null = 没有横幅。
  final String? bannerKey;
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

  /// 之前那份横幅文件的备份（清除时横幅可能因无人引用被回收）；null = 没有横幅。
  final String? bannerBackupPath;

  Map<String, Object?> toJson() => <String, Object?>{
    'bookKey': bookKey,
    'record': record?.toJson(),
    'coverBackupPath': coverBackupPath,
    'bannerBackupPath': ?bannerBackupPath,
  };
}

/// 刮削层的存储 + 内存索引。按缩略图目录取单例（[of]），渲染期只查内存。
class BookArtStore extends ChangeNotifier {
  BookArtStore._(this.thumbnailsDirectory, this._now);

  /// 缩略图目录 → 存储（生产只有一个；测试各用临时目录）。
  static final Map<String, BookArtStore> _instances = <String, BookArtStore>{};

  /// [thumbnailsDirectory] 对应的存储。
  static BookArtStore of(
    Directory thumbnailsDirectory, {
    DateTime Function() now = DateTime.now,
  }) => _instances.putIfAbsent(
    p.normalize(thumbnailsDirectory.absolute.path),
    () => BookArtStore._(thumbnailsDirectory, now),
  );

  /// 测试接缝：丢掉全部单例（换临时目录后重读）。
  @visibleForTesting
  static void resetForTesting() => _instances.clear();

  final Directory thumbnailsDirectory;
  final DateTime Function() _now;

  /// 撤销备份保留多久（与书元数据写回同口径）。
  static const Duration backupRetention = Duration(days: 30);

  Directory get _coverDir =>
      Directory(p.join(thumbnailsDirectory.path, 'scraped'));
  Directory get _bannerDir =>
      Directory(p.join(thumbnailsDirectory.path, 'scraped_banners'));
  Directory get _backupDir =>
      Directory(p.join(thumbnailsDirectory.path, 'undo_backups', 'book_art'));

  /// 有卷封面文件的 bookKey 哈希；null = 还没扫目录。
  Set<String>? _coverHashes;

  /// 已读过的元数据（键是 bookKey 哈希；值 null = 没有元数据文件）。
  final Map<String, BookArtRecord?> _records = <String, BookArtRecord?>{};

  /// 正在写入、记录还没落盘的横幅（键是 [_safeName]）→ 持有数。回收时跳过它们：
  /// 刮削先写横幅、卷封面下完才写记录，期间别处的删除触发回收不能把它删掉。
  final Map<String, int> _bannerHolds = <String, int>{};

  /// bookKey → 文件名（sha1 十六进制，避开超长 / 特殊字符）。
  static String fileKeyFor(String bookKey) =>
      sha1.convert(utf8.encode(bookKey)).toString();

  /// 卷封面文件路径（不论存在与否）。
  String coverPathFor(String bookKey) =>
      p.join(_coverDir.path, fileKeyFor(bookKey));

  String _recordPathFor(String bookKey) => '${coverPathFor(bookKey)}.json';

  /// 横幅文件路径。
  String bannerPathFor(String bannerKey) =>
      p.join(_bannerDir.path, _safeName(bannerKey));

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
    if (file.existsSync()) {
      try {
        final Object? json = jsonDecode(file.readAsStringSync());
        if (json is Map) {
          record = BookArtRecord.fromJson(Map<String, Object?>.from(json));
        }
      } on FormatException catch (e) {
        ErrorLogService.instance.logDiagnostic('BookArtStore.recordFor', '$e');
      } on FileSystemException catch (e) {
        ErrorLogService.instance.logDiagnostic('BookArtStore.recordFor', '$e');
      }
    }
    return _records[hash] = record;
  }

  /// 编辑弹窗要展示「封面取自 X / 署名 / 移除」的那份记录：有卷封面、或只有横幅
  /// （本地更清晰时只写了横幅）都算；只剩否决记录 / 没有刮削层为 null。
  BookArtRecord? displayableRecordFor(String bookKey) {
    final BookArtRecord? record = recordFor(bookKey);
    if (hasCover(bookKey) || record?.bannerKey != null) return record;
    return null;
  }

  /// 单本书的横幅；没有为 null。
  File? backdropForBook(String bookKey) {
    final String? key = recordFor(bookKey)?.bannerKey;
    if (key == null) return null;
    final File file = File(bannerPathFor(key));
    return file.existsSync() ? file : null;
  }

  /// 合集横幅：成员里出现最多的那份横幅（同票取先出现的）；没有为 null。
  File? backdropForCollection(Iterable<String> memberBookKeys) {
    final Map<String, int> votes = <String, int>{};
    for (final String bookKey in memberBookKeys) {
      final String? key = recordFor(bookKey)?.bannerKey;
      if (key != null) votes[key] = (votes[key] ?? 0) + 1;
    }
    String? best;
    votes.forEach((String key, int n) {
      if (best == null || n > votes[best]!) best = key;
    });
    final String? chosen = best;
    if (chosen == null) return null;
    final File file = File(bannerPathFor(chosen));
    return file.existsSync() ? file : null;
  }

  /// [bookKeys] 里有没有任何一本的刮削层来自 MangaBaka（署名用）。
  bool anyFromMangaBaka(Iterable<String> bookKeys) =>
      bookKeys.any((String k) => recordFor(k)?.usesMangaBaka ?? false);

  /// 写入一本书的刮削层：[coverBytes] 非空时写卷封面（原子写 + 解码缓存驱逐），
  /// 元数据整份替换。[coverBytes] 为 null 时保留已有卷封面文件不动（只更新元数据，
  /// 例如只拿到了横幅）；[removeCover] 时删掉已有卷封面（换了系列，旧图不属于它）。
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

  /// 持有横幅 [bannerKey]：返回的回调释放。持有期间 [collectOrphanBanners] 不删它。
  void Function() holdBanner(String bannerKey) {
    final String name = _safeName(bannerKey);
    _bannerHolds[name] = (_bannerHolds[name] ?? 0) + 1;
    bool released = false;
    return () {
      if (released) return;
      released = true;
      final int left = (_bannerHolds[name] ?? 1) - 1;
      if (left <= 0) {
        _bannerHolds.remove(name);
      } else {
        _bannerHolds[name] = left;
      }
    };
  }

  /// 写横幅文件（同系列共用）。调用方应先 [holdBanner]，记录落盘后再释放。
  Future<void> writeBanner(String bannerKey, List<int> bytes) async {
    await _bannerDir.create(recursive: true);
    await writeCoverBytesAtomically(
      bytes: bytes,
      destPath: bannerPathFor(bannerKey),
    );
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

  /// 删除一本书的刮削层（卷封面 + 元数据），并回收不再被引用的横幅。
  Future<void> remove(String bookKey) async {
    final String hash = fileKeyFor(bookKey);
    final File meta = File(_recordPathFor(bookKey));
    await _deleteCover(bookKey);
    if (meta.existsSync()) await meta.delete();
    _records[hash] = null;
    await collectOrphanBanners();
    notifyListeners();
  }

  /// 用户判定这本书的刮削封面贴错了：删掉卷封面与横幅引用，只留否决记录（把这张
  /// 图的 URL 记进 [BookArtRecord.rejectedCoverUrls]），重刮不会再把它写回来。
  Future<void> rejectCover(String bookKey) async {
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
    await write(
      record: BookArtRecord.rejection(
        bookKey: bookKey,
        rejectedCoverUrls: rejected,
        scrapedAt: _now().millisecondsSinceEpoch,
      ),
      removeCover: true,
    );
    await collectOrphanBanners();
  }

  /// 回收没有任何书引用的横幅文件。
  Future<int> collectOrphanBanners() async {
    final Directory dir = _bannerDir;
    if (!dir.existsSync()) return 0;
    final Set<String> referenced = <String>{};
    final Directory covers = _coverDir;
    if (covers.existsSync()) {
      for (final FileSystemEntity e in covers.listSync(followLinks: false)) {
        if (e is! File || !e.path.endsWith('.json')) continue;
        try {
          final Object? json = jsonDecode(await e.readAsString());
          final Object? key = json is Map ? json['bannerKey'] : null;
          if (key is String) referenced.add(_safeName(key));
        } on FormatException catch (err) {
          ErrorLogService.instance.logDiagnostic('BookArtStore.gc', '$err');
        }
      }
    }
    int removed = 0;
    for (final FileSystemEntity e in dir.listSync(followLinks: false)) {
      if (e is! File) continue;
      final String name = p.basename(e.path);
      if (referenced.contains(name) || _bannerHolds.containsKey(name)) {
        continue;
      }
      try {
        await e.delete();
      } on FileSystemException catch (err) {
        // 文件还被占着（Windows 上背景带的图片正在读它）：回收是尽力而为，这张留到
        // 下一次回收（每次刮削收尾 / 清除 / 否决都会跑）再删。记录此时已一致，
        // 不让它中断调用方——清除逐本删，曾因此中途抛出、后面的书一本都没清。
        ErrorLogService.instance.logDiagnostic('BookArtStore.gc', '$err');
        continue;
      }
      await evictImageCacheForFile(e);
      removed++;
    }
    return removed;
  }

  /// 写入 / 清除前调用：把旧刮削层（卷封面、横幅、元数据）备份出来，返回可撤销的
  /// 快照。横幅也备份：清除时它可能因无人引用被回收，撤销要能把它拿回来。
  Future<BookArtSnapshot> snapshot(String bookKey) async {
    final BookArtRecord? record = recordFor(bookKey);
    final File cover = File(coverPathFor(bookKey));
    final String? bannerKey = record?.bannerKey;
    final File? banner = bannerKey == null
        ? null
        : File(bannerPathFor(bannerKey));
    final bool hasBanner = banner != null && banner.existsSync();
    if (!cover.existsSync() && !hasBanner) {
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
    if (hasBanner) {
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

  /// [snapshot] 还能不能完整恢复（卷封面备份在；需要恢复的横幅文件或其备份在）。
  /// 撤销多本前先逐本检查，避免恢复到一半才发现缺备份。
  bool canRestore(BookArtSnapshot snapshot) {
    final String? cover = snapshot.coverBackupPath;
    if (cover != null && !File(cover).existsSync()) return false;
    final String? bannerKey = snapshot.record?.bannerKey;
    final String? bannerBackup = snapshot.bannerBackupPath;
    if (bannerKey != null &&
        bannerBackup != null &&
        !File(bannerPathFor(bannerKey)).existsSync() &&
        !File(bannerBackup).existsSync()) {
      return false;
    }
    return true;
  }

  /// 把刮削层恢复成 [snapshot]（之前没有 → 清除）。备份已不在时抛 [StateError]
  /// （不拿别的图凑数）；调用方应先用 [canRestore] 逐本检查。
  Future<void> restore(BookArtSnapshot snapshot) async {
    final BookArtRecord? record = snapshot.record;
    final String? backup = snapshot.coverBackupPath;
    if (record == null && backup == null) {
      await remove(snapshot.bookKey);
      return;
    }
    if (!canRestore(snapshot)) {
      throw StateError('封面备份已不在（超过 ${backupRetention.inDays} 天会被清理）');
    }
    final String? bannerKey = record?.bannerKey;
    final String? bannerBackup = snapshot.bannerBackupPath;
    if (bannerKey != null &&
        bannerBackup != null &&
        !File(bannerPathFor(bannerKey)).existsSync()) {
      await _bannerDir.create(recursive: true);
      await File(bannerBackup).copy(bannerPathFor(bannerKey));
    }
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

  /// 当前状态摘要（撤销前判「之后又被改过」）：卷封面文件 sha256 + 元数据时间戳。
  Future<Map<String, Object?>> fingerprint(String bookKey) async {
    final File cover = File(coverPathFor(bookKey));
    return <String, Object?>{
      'coverSha': cover.existsSync()
          ? sha256.convert(await cover.readAsBytes()).toString()
          : null,
      'scrapedAt': recordFor(bookKey)?.scrapedAt,
      'bannerKey': recordFor(bookKey)?.bannerKey,
    };
  }

  Future<void> _pruneBackups() => pruneUndoBackups(
    _backupDir,
    cutoff: _now().subtract(backupRetention),
    logTag: 'BookArtStore.prune',
  );
}
