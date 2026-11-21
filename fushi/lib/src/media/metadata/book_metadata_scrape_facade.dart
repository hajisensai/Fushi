import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/item_scrape/item_scrape_store.dart';
import 'package:fushi_engine/media/metadata/books/anilist_novels.dart'
    show parseAniListMediaUrl;
import 'package:fushi_engine/media/metadata/books/itunes_music.dart'
    show parseItunesUrl;
import 'package:fushi_engine/media/metadata/books/rakuten_books.dart';
import 'package:fushi_engine/media/metadata/dlsite/dlsite_client.dart';
import 'package:fushi_engine/media/metadata/image_download.dart';
import 'package:fushi_engine/privacy/media_nsfw.dart' show isMediaNsfwEffective;
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

/// 一次搜索的结果：给用户看的候选 + 因作品没标 NSFW 而藏起来的 NSFW 候选条数
/// （弹窗据此提示「标为 NSFW 后显示」）。AniList 在服务端就过滤掉了成人向条目，
/// 那部分不计入 [hiddenNsfw]。
typedef BookScrapeSearchResult = ({
  List<BookScrapeCandidate> candidates,
  int hiddenNsfw,
});

/// 书在 NSFW 标记表（`media_nsfw_flags`）里的宿主身份：EPUB / 漫画 / PDF =
/// `(epub, bookKey)`，独立字幕书 = `(srt, uid)`，与书架菜单的「NSFW」开关同一口径。
typedef BookNsfwHost = ({TagHostKind kind, String entryKey});

/// 书的元数据写回会碰到的字段。
enum BookMetadataField {
  /// 显示名覆盖（`override_title://`，不改 `epub_books.title`）。
  title,

  /// 作者列（`epub_books.author` / `srt_books.author`）。
  author,

  /// override 封面文件。
  cover,

  /// 条目刮削资料（简介 / 日期 / 评分 / 标签 / 横版背景，v161 `item_scrape_meta`
  /// + `item_images`）——书架系列色块的数据源。
  details;

  static BookMetadataField? tryParse(String raw) {
    for (final BookMetadataField f in values) {
      if (f.name == raw) return f;
    }
    return null;
  }
}

/// 一本书当前的元数据（显示名覆盖 / 作者 / override 封面内容摘要）。可 JSON 往返。
class BookMetadataState {
  const BookMetadataState({
    this.overrideTitle,
    this.author,
    this.coverSha,
    this.details,
  });

  factory BookMetadataState.fromJson(Map<String, Object?> json) =>
      BookMetadataState(
        overrideTitle: json['overrideTitle'] as String?,
        author: json['author'] as String?,
        coverSha: json['coverSha'] as String?,
        details: json['details'] == null
            ? null
            : Map<String, Object?>.from(json['details']! as Map),
      );

  /// 显示名覆盖；null = 没改过名（显示原始书名）。
  final String? overrideTitle;
  final String? author;

  /// override 封面文件的 sha256；null = 没有 override 封面（显示源默认封面）。
  final String? coverSha;

  /// 条目刮削资料（[itemScrapeDetailsToJson] 形状，不含写入时刻）；null = 没有。
  final Map<String, Object?>? details;

  /// 只取 [fields] 那几项（判「之后被手动改过」时只比这次动过的字段）。
  Map<String, Object?> project(Iterable<BookMetadataField> fields) =>
      <String, Object?>{
        for (final BookMetadataField f in fields)
          f.name: switch (f) {
            BookMetadataField.title => overrideTitle,
            BookMetadataField.author => author,
            BookMetadataField.cover => coverSha,
            BookMetadataField.details => details,
          },
      };

  Map<String, Object?> toJson() => <String, Object?>{
    'overrideTitle': overrideTitle,
    'author': author,
    'coverSha': coverSha,
    'details': details,
  };
}

/// 写回前的快照：[state] + 被替换前那张 override 封面的备份文件（可恢复）。
class BookMetadataSnapshot {
  const BookMetadataSnapshot({
    required this.state,
    this.coverBackupPath,
    this.hadBackdrop = false,
  });

  factory BookMetadataSnapshot.fromJson(Map<String, Object?> json) =>
      BookMetadataSnapshot(
        state: BookMetadataState.fromJson(
          Map<String, Object?>.from(json['state'] as Map? ?? const {}),
        ),
        coverBackupPath: json['coverBackupPath'] as String?,
        hadBackdrop: json['hadBackdrop'] == true,
      );

  final BookMetadataState state;

  /// 执行前有 override 封面且要求留备份时，那张图的备份路径。
  final String? coverBackupPath;

  /// 执行前条目已有横版背景（有则撤销不清背景——旧图已被同路径覆盖，无从恢复；
  /// 没有则撤销连这次写入的背景一起清掉）。
  final bool hadBackdrop;

  Map<String, Object?> toJson() => <String, Object?>{
    'state': state.toJson(),
    'coverBackupPath': coverBackupPath,
    'hadBackdrop': hadBackdrop,
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
/// - [searchDetailed] / [fetchById]：候选；
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

  /// [item] 的 NSFW 宿主身份（认不出为 null）。
  static BookNsfwHost? nsfwHostForItem(MediaItem item) {
    final String? bookKey = ReaderFushiSource.parseBookKey(
      item.mediaIdentifier,
    );
    if (bookKey != null) return (kind: TagHostKind.epub, entryKey: bookKey);
    final String? srtUid = ReaderFushiSource.parseSrtBookUid(
      item.mediaIdentifier,
    );
    if (srtUid != null && srtUid.isNotEmpty) {
      return (kind: TagHostKind.srt, entryKey: srtUid);
    }
    return null;
  }

  /// [host] 的**有效** NSFW（自己被标，或在 NSFW 合集里）。刮削搜索据此决定显不显示
  /// NSFW 候选；null（认不出的书）按没标处理。
  static Future<bool> isNsfwHost(FushiDatabase db, BookNsfwHost? host) async =>
      host != null && await isMediaNsfwEffective(db, host.kind, host.entryKey);

  /// [item] 是不是「以有声书导入的歌曲」：同步文件是 LRC 歌词（字幕书的字幕文件，或
  /// EPUB 有声书的对齐文件）。是的话刮削弹窗默认选音乐封面源（[BookScrapeSource.itunes]），
  /// 不再先去 Bangumi 搜出一堆动画 / 漫画条目（应用内反馈 T_KdsLEY9l）。
  static Future<bool> isSongForItem(FushiDatabase db, MediaItem item) async {
    final String? srtUid = ReaderFushiSource.parseSrtBookUid(
      item.mediaIdentifier,
    );
    if (srtUid != null) {
      final SrtBookRow? row = await db.getSrtBookByUid(srtUid);
      return row != null && isLyricsSyncPath(row.srtPath);
    }
    final String? bookKey = ReaderFushiSource.parseBookKey(
      item.mediaIdentifier,
    );
    if (bookKey == null) return false;
    final AudiobookRow? audiobook = await db.getAudiobookByBookKey(bookKey);
    if (audiobook == null) return false;
    return audiobook.alignmentFormat.trim().toLowerCase() == 'lrc' ||
        isLyricsSyncPath(audiobook.alignmentPath);
  }

  /// 同步文件路径是不是 LRC 歌词（按扩展名，大小写不敏感）。
  static bool isLyricsSyncPath(String path) =>
      p.extension(path.trim()).toLowerCase() == '.lrc';

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
  /// ISBN 按 ISBN，否则按书名。iTunes：贴 Apple Music 链接 / 数字 id = 按 id 直取（数字直取
  /// 不中再当歌名搜），其余按歌名 / 歌手搜歌曲。失败抛 [BookScrapeException]。
  ///
  /// NSFW 候选（[BookScrapeCandidate.isAdult]）只在 [includeNsfw] 时返回——这是对**所有
  /// 源**统一的一条规则，跟随作品自己的 NSFW 标记（拍板台 pr3497）；不再靠「把 DLsite
  /// 单独做成一个源、默认不选」来把成人向结果挡在普通书搜索外；另报因 [includeNsfw] 为 false
  /// 而藏起来的 NSFW 候选条数（弹窗据此给「标为 NSFW」，ctl 回 `hiddenNsfw`）。
  ///
  /// 只有这一个搜索入口：弹窗与 ctl `book.scrape.search` 都调它，UI 能搜的 CLI 都能搜
  /// （`ctl_ui_action_facade_coverage_guard_test`）。
  Future<BookScrapeSearchResult> searchDetailed({
    required BookScrapeSource source,
    required String query,
    bool includeNsfw = false,
  }) async {
    final List<BookScrapeCandidate> all = await _searchAll(
      source,
      query.trim(),
      includeNsfw: includeNsfw,
    );
    if (includeNsfw) return (candidates: all, hiddenNsfw: 0);
    final List<BookScrapeCandidate> shown = <BookScrapeCandidate>[
      for (final BookScrapeCandidate c in all)
        if (!c.isAdult) c,
    ];
    return (candidates: shown, hiddenNsfw: all.length - shown.length);
  }

  Future<List<BookScrapeCandidate>> _searchAll(
    BookScrapeSource source,
    String keyword, {
    required bool includeNsfw,
  }) async {
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
        return _scraper.searchAniList(keyword, includeNsfw: includeNsfw);
      case BookScrapeSource.openbd:
        return _scraper.searchOpenBd(keyword);
      case BookScrapeSource.ndl:
        return _scraper.searchNdl(keyword);
      case BookScrapeSource.rakuten:
        return _scraper.searchRakuten(keyword);
      case BookScrapeSource.itunes:
        // 贴 Apple Music / iTunes 链接（或纯数字 id）= 按 id 直取。
        final String? itunesId = parseItunesUrl(keyword);
        if (itunesId != null) {
          final BookScrapeCandidate? c = await _scraper.fetchCatalogById(
            source,
            itunesId,
          );
          if (c != null) return <BookScrapeCandidate>[c];
          // 纯数字也可能是歌名（「1984」「22」）：直取不中再按关键词搜。
          if (itunesId != keyword) return const <BookScrapeCandidate>[];
        }
        return _scraper.searchItunes(keyword);
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
    BookScrapeSource.rakuten ||
    BookScrapeSource.itunes => _scraper.fetchCatalogById(source, id.trim()),
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
    BookScrapeCandidate? details,
    File? backdrop,
    bool keepBackup = false,
  }) async {
    final MediaSource source = item.getMediaSource(appModel: appModel);
    final BookMetadataState beforeState = await currentState(
      appModel: appModel,
      item: item,
    );
    final ItemScrapeKey? itemKey = await itemScrapeKeyForBook(
      appModel.database,
      item,
    );
    final bool hadBackdrop =
        itemKey != null &&
        (await appModel.database.getItemImages(
          itemKey.mediaType,
          itemKey.entryKey,
        )).any((ItemImageRow r) => r.kind == MediaImageKind.backdrop.dbValue);
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
    if (details != null && itemKey != null) {
      // 资料先落（简介 / 评分 / 标签本身就够画系列色块）；横版图下载失败只记日志，
      // 不让整次写回失败——封面 / 书名已经写进去了。
      final ItemScrapeStore store = _itemStore(appModel.database);
      await store.writeMeta(itemKey, itemScrapeDetailsOfCandidate(details));
      try {
        if (backdrop != null) {
          await store.setImageFromFile(
            itemKey,
            MediaImageKind.backdrop,
            backdrop,
            sourceUrl: details.backdropUrl,
          );
        } else if (details.backdropUrl != null) {
          await store.setImageFromUrl(
            itemKey,
            MediaImageKind.backdrop,
            details.backdropUrl!,
          );
        }
      } catch (e, stack) {
        ErrorLogService.instance.log(
          'BookMetadataScrapeFacade.backdrop',
          e,
          stack,
        );
      }
      applied.add(BookMetadataField.details);
    }
    return BookMetadataApplyResult(
      before: BookMetadataSnapshot(
        state: beforeState,
        coverBackupPath: backupPath,
        hadBackdrop: hadBackdrop,
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
    final ItemScrapeKey? itemKey = await itemScrapeKeyForBook(
      appModel.database,
      item,
    );
    final ItemScrapeMetaRow? meta = itemKey == null
        ? null
        : await appModel.database.getItemScrapeMeta(
            itemKey.mediaType,
            itemKey.entryKey,
          );
    return BookMetadataState(
      overrideTitle: source.getOverrideTitleFromMediaItem(item),
      author: await _author(appModel.database, item),
      coverSha: cover == null ? null : await _sha(cover),
      details: meta == null
          ? null
          : itemScrapeDetailsToJson(ItemScrapeDetails.fromRow(meta)),
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
    if (fields.contains(BookMetadataField.details)) {
      final ItemScrapeKey? itemKey = await itemScrapeKeyForBook(
        appModel.database,
        item,
      );
      if (itemKey != null) {
        final Map<String, Object?>? previous = snapshot.state.details;
        if (previous == null) {
          await appModel.database.deleteItemScrapeMeta(
            itemKey.mediaType,
            itemKey.entryKey,
          );
        } else {
          await _itemStore(
            appModel.database,
          ).writeMeta(itemKey, itemScrapeDetailsFromJson(previous));
        }
        if (!snapshot.hadBackdrop) {
          await _itemStore(
            appModel.database,
          ).clearImage(itemKey, MediaImageKind.backdrop);
        }
      }
    }
  }

  ItemScrapeStore _itemStore(FushiDatabase db) =>
      ItemScrapeStore(db, downloadImage: _download, now: _now);

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

/// 书架条目（[MediaItem]）在 `item_scrape_meta` / `item_images` 里的身份：EPUB /
/// 漫画 / PDF = `(epub, EpubBooks.uid)`，独立字幕书 = `(srt, SrtBooks.uid)`（与合集
/// 成员同一口径）。认不出（书行已删 / uid 为空）为 null。
Future<ItemScrapeKey?> itemScrapeKeyForBook(
  FushiDatabase db,
  MediaItem item,
) async {
  final String? bookKey = ReaderFushiSource.parseBookKey(item.mediaIdentifier);
  if (bookKey != null) {
    final String? uid = await db.resolveEpubBookUid(bookKey);
    return uid == null || uid.isEmpty
        ? null
        : ItemScrapeKey(MediaKind.epub, uid);
  }
  final String? srtUid = ReaderFushiSource.parseSrtBookUid(
    item.mediaIdentifier,
  );
  if (srtUid != null && srtUid.isNotEmpty) {
    return ItemScrapeKey(MediaKind.srt, srtUid);
  }
  return null;
}

/// 书籍刮削候选 → 与媒体无关的条目资料（日期优先源侧原文，退回年份）。
ItemScrapeDetails itemScrapeDetailsOfCandidate(BookScrapeCandidate c) =>
    ItemScrapeDetails(
      source: c.source.name,
      subjectId: c.subjectId,
      title: c.title,
      originalTitle: c.originalTitle,
      summary: c.summary,
      airDate: c.date ?? c.year?.toString(),
      rating: c.rating,
      ratingCount: c.ratingCount,
      tags: c.tags,
      detailUrl: c.detailUrl,
    );

/// [ItemScrapeDetails] ↔ JSON（撤销快照用；不含写入时刻）。
Map<String, Object?> itemScrapeDetailsToJson(ItemScrapeDetails d) =>
    <String, Object?>{
      'source': d.source,
      'subjectId': d.subjectId,
      'title': d.title,
      'originalTitle': d.originalTitle,
      'summary': d.summary,
      'airDate': d.airDate,
      'rating': d.rating,
      'ratingCount': d.ratingCount,
      'tags': d.tags,
      'detailUrl': d.detailUrl,
    };

ItemScrapeDetails itemScrapeDetailsFromJson(Map<String, Object?> json) =>
    ItemScrapeDetails(
      source: json['source'] as String? ?? ItemScrapeStore.manualSource,
      subjectId: json['subjectId'] as String?,
      title: json['title'] as String?,
      originalTitle: json['originalTitle'] as String?,
      summary: json['summary'] as String?,
      airDate: json['airDate'] as String?,
      rating: (json['rating'] as num?)?.toDouble(),
      ratingCount: (json['ratingCount'] as num?)?.toInt(),
      tags: <String>[
        for (final Object? t
            in (json['tags'] as List<Object?>? ?? const <Object?>[]))
          if (t is String) t,
      ],
      detailUrl: json['detailUrl'] as String?,
    );
