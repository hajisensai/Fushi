import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/metadata/books/anilist_novels.dart'
    show parseAniListMediaUrl;
import 'package:fushi_engine/media/metadata/books/rakuten_books.dart';
import 'package:fushi_engine/media/metadata/dlsite/dlsite_client.dart';
import 'package:fushi_engine/media/metadata/image_download.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/media_cover_service.dart';
import 'package:fushi/src/media/media_item.dart';
import 'package:fushi/src/media/media_source.dart';
import 'package:fushi/src/media/metadata/bangumi_api_client.dart'
    show parseBangumiSubjectUrl;
import 'package:fushi/src/media/metadata/book_metadata_scraper.dart';
import 'package:fushi/src/media/metadata/undo_backup_retention.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// 封面下载器（测试注入桩）；[headers] 是源要求的额外请求头。
typedef BookCoverDownloader =
    Future<File> Function(String url, {Map<String, String>? headers});

/// 书的元数据写回会碰到的字段。
enum BookMetadataField {
  /// 显示名覆盖（`override_title://`，不改 `epub_books.title`）。
  title,

  /// 作者列（`epub_books.author` / `srt_books.author`）。
  author,

  /// override 封面文件。
  cover;

  static BookMetadataField? tryParse(String raw) {
    for (final BookMetadataField f in values) {
      if (f.name == raw) return f;
    }
    return null;
  }
}

/// 一本书当前的元数据（显示名覆盖 / 作者 / override 封面内容摘要）。可 JSON 往返。
class BookMetadataState {
  const BookMetadataState({this.overrideTitle, this.author, this.coverSha});

  factory BookMetadataState.fromJson(Map<String, Object?> json) =>
      BookMetadataState(
        overrideTitle: json['overrideTitle'] as String?,
        author: json['author'] as String?,
        coverSha: json['coverSha'] as String?,
      );

  /// 显示名覆盖；null = 没改过名（显示原始书名）。
  final String? overrideTitle;
  final String? author;

  /// override 封面文件的 sha256；null = 没有 override 封面（显示源默认封面）。
  final String? coverSha;

  /// 只取 [fields] 那几项（判「之后被手动改过」时只比这次动过的字段）。
  Map<String, Object?> project(Iterable<BookMetadataField> fields) =>
      <String, Object?>{
        for (final BookMetadataField f in fields)
          f.name: switch (f) {
            BookMetadataField.title => overrideTitle,
            BookMetadataField.author => author,
            BookMetadataField.cover => coverSha,
          },
      };

  Map<String, Object?> toJson() => <String, Object?>{
    'overrideTitle': overrideTitle,
    'author': author,
    'coverSha': coverSha,
  };
}

/// 写回前的快照：[state] + 被替换前那张 override 封面的备份文件（可恢复）。
class BookMetadataSnapshot {
  const BookMetadataSnapshot({required this.state, this.coverBackupPath});

  factory BookMetadataSnapshot.fromJson(Map<String, Object?> json) =>
      BookMetadataSnapshot(
        state: BookMetadataState.fromJson(
          Map<String, Object?>.from(json['state'] as Map? ?? const {}),
        ),
        coverBackupPath: json['coverBackupPath'] as String?,
      );

  final BookMetadataState state;

  /// 执行前有 override 封面且要求留备份时，那张图的备份路径。
  final String? coverBackupPath;

  Map<String, Object?> toJson() => <String, Object?>{
    'state': state.toJson(),
    'coverBackupPath': coverBackupPath,
  };
}

/// 一次写回的结果。
class BookMetadataApplyResult {
  const BookMetadataApplyResult({
    required this.before,
    required this.after,
    required this.applied,
  });

  final BookMetadataSnapshot before;
  final BookMetadataState after;

  /// 真落盘了的字段（封面图校验不过会被静默拒写，见
  /// [MediaSource.setOverrideThumbnailFromMediaItem]；不支持改作者的源不写作者）。
  final Set<BookMetadataField> applied;
}

/// 书 / 漫画 / 有声书「在线匹配封面」的业务门面（统一刮削 P1b）。
///
/// 此前候选解析（贴 Bangumi URL 直取、纯数字关键词「搜索 + id 直取」并列、DLsite
/// 编号直取）与封面下载写在弹窗 State 里、写回写在书架页里，控制通道 / AI 助手没法调
/// 「同一个方法」。现在弹窗、书架页、`fushi_cli book …` 都只经本门面：
/// - [search] / [fetchById]：候选；
/// - [downloadCover]：选中候选后下载封面到临时文件（编辑信息弹窗拿它先预览、保存时
///   再落地，所以下载与写回分两步）；
/// - [applyToBook]：写回显示名 / 作者 / 封面。`keepBackup` 时先把将被替换的 override
///   封面复制到备份目录再换——override 封面是「同路径原子覆盖写」，不留备份旧图就
///   没了，撤销无从谈起；
/// - [currentState] / [restore]：AI 撤销用（执行前快照写回）。
class BookMetadataScrapeFacade {
  /// [scraper] 注入时门面不负责关闭它；不注入则按需自建（带上 [rakuten] 凭据）、
  /// [close] 时关闭。
  BookMetadataScrapeFacade({
    BookMetadataScraper? scraper,
    BookCoverDownloader? downloadImage,
    DateTime Function() now = DateTime.now,
    RakutenBooksCredentials? rakuten,
  }) : _injected = scraper,
       _download = downloadImage ?? _defaultDownload,
       _now = now,
       _rakuten = rakuten;

  final BookMetadataScraper? _injected;
  final BookCoverDownloader _download;
  final DateTime Function() _now;
  final RakutenBooksCredentials? _rakuten;
  BookMetadataScraper? _owned;

  BookMetadataScraper get _scraper =>
      _injected ?? (_owned ??= BookMetadataScraper(rakuten: _rakuten));

  static Future<File> _defaultDownload(
    String url, {
    Map<String, String>? headers,
  }) => downloadImageToTempFile(url, headers: headers);

  /// [source] 在当前凭据下能不能用（楽天要 applicationId + accessKey）。
  bool isSourceAvailable(BookScrapeSource source) =>
      !source.needsCredentials || _scraper.rakutenAvailable;

  /// [item] 的 ISBN-13（EPUB 导入时从 OPF `dc:identifier` 规范化写进
  /// `epub_books.isbn`；字幕书 / 漫画 / 没有 ISBN 的书返回 null）。openBD 等按 ISBN
  /// 查的源用它预填。
  static Future<String?> isbnForItem(FushiDatabase db, MediaItem item) async {
    final String? bookKey = ReaderFushiSource.parseBookKey(
      item.mediaIdentifier,
    );
    if (bookKey == null) return null;
    return (await db.getEpubBook(bookKey))?.isbn;
  }

  /// 备份保留多久（与回收站同口径）；之后的撤销报失败（封面备份已过期）。
  static const Duration backupRetention = Duration(days: 30);

  /// 关键词 → 候选。Bangumi：贴条目 URL = 按 id 直取（跳过关键词搜索）；纯数字既
  /// 可能是 id 也可能是书名（如《1984》）——搜索 + id 直取并列，直取命中置顶、按
  /// subjectId 去重；其余走关键词搜索。DLsite：贴作品页 URL / 编号 → 直取；其余按名
  /// 搜音声 / 漫画 / 小说。AniList：贴 `anilist.co/manga/<id>` = 按 id 直取，其余按名搜
  /// 轻小说。openBD：只按输入里的 ISBN 查（没有 ISBN → 空表）。NDL / 楽天：输入里有
  /// ISBN 按 ISBN，否则按书名。失败抛 [BookScrapeException]。
  Future<List<BookScrapeCandidate>> search({
    required BookScrapeSource source,
    required String query,
  }) async {
    final String keyword = query.trim();
    if (keyword.isEmpty) return const <BookScrapeCandidate>[];
    switch (source) {
      case BookScrapeSource.dlsite:
        return _searchDlsite(keyword);
      case BookScrapeSource.anilist:
        final String? id = parseAniListMediaUrl(keyword);
        if (id != null) {
          final BookScrapeCandidate? c = await _scraper.fetchCatalogById(
            source,
            id,
          );
          return c == null
              ? const <BookScrapeCandidate>[]
              : <BookScrapeCandidate>[c];
        }
        return _scraper.searchAniList(keyword);
      case BookScrapeSource.openbd:
        return _scraper.searchOpenBd(keyword);
      case BookScrapeSource.ndl:
        return _scraper.searchNdl(keyword);
      case BookScrapeSource.rakuten:
        return _scraper.searchRakuten(keyword);
      case BookScrapeSource.mangabaka:
        return _searchMangaBaka(keyword);
      case BookScrapeSource.bangumi:
        break;
    }
    final String? mappedSubjectId = parseBangumiSubjectUrl(keyword);
    if (mappedSubjectId != null) {
      final BookScrapeCandidate? candidate = await _scraper.fetchById(
        mappedSubjectId,
      );
      return candidate == null
          ? const <BookScrapeCandidate>[]
          : <BookScrapeCandidate>[candidate];
    }
    if (RegExp(r'^\d+$').hasMatch(keyword)) {
      final List<BookScrapeCandidate> searched = await _scraper.search(keyword);
      BookScrapeCandidate? direct;
      try {
        direct = await _scraper.fetchById(keyword);
      } catch (e) {
        // 尽力而为的第二路：上方那次关键词搜索（未 guard）失败才会冒泡成可见失败，
        // 这里吞掉不会让任何真失败消失。仍落诊断日志，否则「数字关键词结果时多时少」
        // 无从查起。
        direct = null;
        ErrorLogService.instance.logDiagnostic(
          'BookMetadataScrapeFacade.fetchById',
          'numeric keyword direct fetch failed: $e',
        );
      }
      if (direct == null) return searched;
      final String directId = direct.subjectId;
      return <BookScrapeCandidate>[
        direct,
        ...searched.where((BookScrapeCandidate c) => c.subjectId != directId),
      ];
    }
    return _scraper.search(keyword);
  }

  Future<List<BookScrapeCandidate>> _searchDlsite(String keyword) async {
    final DlsiteWorkId? id =
        DlsiteWorkId.tryParse(keyword) ??
        (keyword.contains('dlsite.com') ? DlsiteWorkId.findIn(keyword) : null);
    if (id != null) {
      final BookScrapeCandidate? candidate = await _scraper.fetchDlsiteById(
        id.value,
      );
      return candidate == null
          ? const <BookScrapeCandidate>[]
          : <BookScrapeCandidate>[candidate];
    }
    return _scraper.searchDlsite(keyword);
  }

  /// MangaBaka：贴系列页 URL → 直取；纯数字既可能是 id 也可能是书名（《86》）——
  /// 搜索 + id 直取并列，直取命中置顶；其余按名搜。
  Future<List<BookScrapeCandidate>> _searchMangaBaka(String keyword) async {
    final String? id = parseMangaBakaSeriesId(keyword);
    final bool numeric = RegExp(r'^\d+$').hasMatch(keyword);
    if (id != null && !numeric) {
      final BookScrapeCandidate? c = await _scraper.fetchMangaBakaById(id);
      return c == null
          ? const <BookScrapeCandidate>[]
          : <BookScrapeCandidate>[c];
    }
    final List<BookScrapeCandidate> searched = await _scraper.searchMangaBaka(
      keyword,
    );
    if (id == null) return searched;
    BookScrapeCandidate? direct;
    try {
      direct = await _scraper.fetchMangaBakaById(id);
    } on BookScrapeException catch (e) {
      // 与 Bangumi 数字关键词同口径：第二路尽力而为，主搜索失败仍会冒泡。
      ErrorLogService.instance.logDiagnostic(
        'BookMetadataScrapeFacade.fetchMangaBakaById',
        'numeric keyword direct fetch failed: $e',
      );
    }
    if (direct == null) return searched;
    final String directId = direct.subjectId;
    return <BookScrapeCandidate>[
      direct,
      ...searched.where((BookScrapeCandidate c) => c.subjectId != directId),
    ];
  }

  /// MangaBaka 系列 [seriesId] 的每卷封面（弹窗的卷网格）。
  Future<List<BookVolumeCover>> volumeCovers(String seriesId) =>
      _scraper.fetchMangaBakaVolumeCovers(seriesId);

  /// 下载某卷封面到临时文件（失败抛 [ImageDownloadException]）。
  Future<File> downloadVolumeCover(BookVolumeCover cover) =>
      _download(cover.url);

  /// 按源内 id 直取一个候选（Bangumi subject id / DLsite 作品编号 / MangaBaka 系列 id /
  /// AniList media id / openBD·NDL·楽天的 ISBN）。查无此条 / 无封面返回 null；失败抛
  /// [BookScrapeException]。
  Future<BookScrapeCandidate?> fetchById({
    required BookScrapeSource source,
    required String id,
  }) => switch (source) {
    BookScrapeSource.bangumi => _scraper.fetchById(id.trim()),
    BookScrapeSource.dlsite => _scraper.fetchDlsiteById(id.trim()),
    BookScrapeSource.mangabaka => _scraper.fetchMangaBakaById(id.trim()),
    BookScrapeSource.anilist ||
    BookScrapeSource.openbd ||
    BookScrapeSource.ndl ||
    BookScrapeSource.rakuten => _scraper.fetchCatalogById(source, id.trim()),
  };

  /// 选中候选后把封面下到临时文件（失败抛 [ImageDownloadException]）。源要求的请求头
  /// （NDL 缩略图的 Referer）一并带上。
  Future<File> downloadCover(BookScrapeCandidate candidate) =>
      _download(candidate.coverUrl, headers: candidate.coverHeaders);

  /// 把选中的元数据写回 [item]：[title] 非空 → 显示名覆盖；[author] 非 null → 作者
  /// （源不支持改作者时跳过）；[cover] 非 null → override 封面。全部走书架 / 编辑
  /// 信息弹窗同一组 [MediaSource] 写入方法。
  ///
  /// [keepBackup]：替换 override 封面前先把旧图复制到 `<thumbnails>/undo_backups/`，
  /// 快照里记下备份路径，供 [restore] 写回。
  Future<BookMetadataApplyResult> applyToBook({
    required AppModel appModel,
    required MediaItem item,
    File? cover,
    String? title,
    String? author,
    bool keepBackup = false,
  }) async {
    final MediaSource source = item.getMediaSource(appModel: appModel);
    final BookMetadataState beforeState = await currentState(
      appModel: appModel,
      item: item,
    );
    String? backupPath;
    if (cover != null && keepBackup && beforeState.coverSha != null) {
      backupPath = await _backupCover(appModel, source, item);
    }
    final Set<BookMetadataField> applied = <BookMetadataField>{};
    final String? trimmedTitle = title?.trim();
    if (trimmedTitle != null && trimmedTitle.isNotEmpty) {
      await source.setOverrideTitleFromMediaItem(
        item: item,
        title: trimmedTitle,
      );
      applied.add(BookMetadataField.title);
    }
    if (author != null && source.supportsAuthorEdit) {
      await source.setAuthorFromMediaItem(item: item, author: author);
      applied.add(BookMetadataField.author);
    }
    if (cover != null) {
      final String expected = await _sha(cover);
      await MediaCoverService.applyBookCoverOverride(
        appModel: appModel,
        mediaSource: source,
        item: item,
        file: cover,
        clearOverrideImage: false,
      );
      final File? landed = source.resolveOverrideThumbnailFile(
        appModel: appModel,
        item: item,
      );
      if (landed != null && await _sha(landed) == expected) {
        applied.add(BookMetadataField.cover);
      } else if (backupPath != null) {
        // 新图被校验拒写、旧图原样未动：备份用不上了。
        await _deleteQuietly(backupPath);
        backupPath = null;
      }
    }
    return BookMetadataApplyResult(
      before: BookMetadataSnapshot(
        state: beforeState,
        coverBackupPath: backupPath,
      ),
      after: await currentState(appModel: appModel, item: item),
      applied: applied,
    );
  }

  /// [item] 当前的显示名覆盖、作者（读库真值，不读 [item] 上可能过期的缓存）与
  /// override 封面摘要。
  Future<BookMetadataState> currentState({
    required AppModel appModel,
    required MediaItem item,
  }) async {
    final MediaSource source = item.getMediaSource(appModel: appModel);
    final File? cover = source.resolveOverrideThumbnailFile(
      appModel: appModel,
      item: item,
    );
    return BookMetadataState(
      overrideTitle: source.getOverrideTitleFromMediaItem(item),
      author: await _author(appModel.database, item),
      coverSha: cover == null ? null : await _sha(cover),
    );
  }

  /// 把 [fields] 写回成 [snapshot] 的值：显示名（null = 清除改名）、作者、封面（有
  /// 备份 → 拷回并删备份；执行前没有 override 封面 → 清除）。执行前有封面但备份
  /// 已不在时抛 [StateError]（不拿别的图凑数）。
  Future<void> restore({
    required AppModel appModel,
    required MediaItem item,
    required BookMetadataSnapshot snapshot,
    required Set<BookMetadataField> fields,
  }) async {
    final MediaSource source = item.getMediaSource(appModel: appModel);
    if (fields.contains(BookMetadataField.cover)) {
      final String? backup = snapshot.coverBackupPath;
      if (snapshot.state.coverSha == null) {
        await MediaCoverService.applyBookCoverOverride(
          appModel: appModel,
          mediaSource: source,
          item: item,
          file: null,
          clearOverrideImage: true,
        );
      } else if (backup != null && File(backup).existsSync()) {
        await MediaCoverService.applyBookCoverOverride(
          appModel: appModel,
          mediaSource: source,
          item: item,
          file: File(backup),
          clearOverrideImage: false,
        );
        await _deleteQuietly(backup);
      } else {
        throw StateError('封面备份已不在（超过 ${backupRetention.inDays} 天会被清理）');
      }
    }
    if (fields.contains(BookMetadataField.title)) {
      await source.setOverrideTitleFromMediaItem(
        item: item,
        title: snapshot.state.overrideTitle,
      );
    }
    if (fields.contains(BookMetadataField.author) &&
        source.supportsAuthorEdit) {
      await source.setAuthorFromMediaItem(
        item: item,
        author: snapshot.state.author,
      );
    }
  }

  /// 关闭自建的 scraper（注入的不关）。
  void close() {
    _owned?.close();
    _owned = null;
  }

  Future<String?> _author(FushiDatabase db, MediaItem item) async {
    final String? bookKey = ReaderFushiSource.parseBookKey(
      item.mediaIdentifier,
    );
    if (bookKey != null) return (await db.getEpubBook(bookKey))?.author;
    final String? srtUid = ReaderFushiSource.parseSrtBookUid(
      item.mediaIdentifier,
    );
    if (srtUid != null) {
      return (await SrtBookRepository(db).findByUid(srtUid))?.author;
    }
    return item.author;
  }

  Future<String> _backupCover(
    AppModel appModel,
    MediaSource source,
    MediaItem item,
  ) async {
    final File current = source.resolveOverrideThumbnailFile(
      appModel: appModel,
      item: item,
    )!;
    final Directory dir = Directory(
      p.join(appModel.thumbnailsDirectory.path, 'undo_backups'),
    );
    await dir.create(recursive: true);
    await _pruneBackups(dir);
    final DateTime now = _now();
    final String path = p.join(
      dir.path,
      '${now.microsecondsSinceEpoch}_${item.mediaIdentifier.hashCode.toUnsigned(32)}',
    );
    final File backup = await current.copy(path);
    // 复制会沿用源文件的修改时间；保留期按「备份建立时刻」算，所以这里改成现在，
    // 否则一张 30 天前就在用的旧封面，备份刚建好就会被下一次清理删掉。
    await backup.setLastModified(now);
    return path;
  }

  Future<void> _pruneBackups(Directory dir) => pruneUndoBackups(
    dir,
    cutoff: _now().subtract(backupRetention),
    logTag: 'BookMetadataScrapeFacade.prune',
  );

  static Future<void> _deleteQuietly(String path) async {
    try {
      final File f = File(path);
      if (f.existsSync()) await f.delete();
    } on FileSystemException catch (e) {
      ErrorLogService.instance.logDiagnostic(
        'BookMetadataScrapeFacade.deleteBackup',
        '$e',
      );
    }
  }

  static Future<String> _sha(File file) async =>
      sha256.convert(await file.readAsBytes()).toString();
}
