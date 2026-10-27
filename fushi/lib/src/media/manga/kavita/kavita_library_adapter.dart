import 'dart:typed_data';

import 'package:fushi/src/media/kavita/kavita_api_registry.dart';
import 'package:fushi/src/media/kavita/kavita_server_config.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_service.dart';
import 'package:fushi/src/media/manga/library/online_manga_runtime_adapter.dart';
import 'package:fushi_engine/media/kavita/kavita_api.dart';
import 'package:fushi_engine/media/kavita/kavita_models.dart';
import 'package:fushi_engine/media/metadata/credential_redaction.dart'
    show redactCredentialsInText;

/// Kavita 漫画源在书架身份里占的「扩展包」位。
///
/// 与 [kInterconnectMangaPackage] 同理：[OnlineMangaLibraryService.bookKeyFor] 的
/// 身份三元组（包 / 源 / 作品）形状不能改，Kavita 没有扩展包，给一个固定占位。
/// 身份由 `sourceId`（服务器配置 id）+ `seriesKey`（Kavita seriesId）决定——稳定、
/// 不随标题改名漂移，也不会让两台服务器上同名的作品撞键。
///
/// ⚠️ 值已进用户库的 `epub_books.bookKey` 与磁盘目录名，**永不可改**。
const String kKavitaMangaPackage = 'fushi.kavita';

/// 封面在描述符里的占位 URL 前缀。
///
/// 描述符（`sourceMetadata`）约定**不含任何敏感信息**，而 Kavita 的封面 URL 带
/// `apiKey` 查询参数，所以这里只存 `kavita-cover:<seriesId>`，取图时
/// [KavitaLibraryAdapter.fetchCover] 再经服务器配置现取字节。
const String kKavitaCoverScheme = 'kavita-cover:';

/// 取一台服务器配置的协议层客户端（测试缝）。
typedef KavitaApiFactory = KavitaApi Function(KavitaServerConfig config);

/// 把用户自配的 Kavita 服务器接进书架 / 作品页 / 阅读器的在线漫画运行时。
///
/// 一个 Kavita chapter 就是 Fushi 的一章（章 key = Kavita chapterId 的十进制串）；
/// 只收图片归档（CBZ / 图片目录）系列，EPUB / PDF 系列走书籍那条路。
class KavitaLibraryAdapter implements OnlineMangaRuntimeAdapter {
  KavitaLibraryAdapter({
    required List<KavitaServerConfig> Function() servers,
    KavitaApiFactory? apiFor,
  }) : _servers = servers,
       _apiFor = apiFor ?? KavitaApiRegistry.instance.apiFor;

  final List<KavitaServerConfig> Function() _servers;
  final KavitaApiFactory _apiFor;

  @override
  OnlineMangaRuntimeKind get kind => OnlineMangaRuntimeKind.kavita;

  /// 纯 Dart HTTP，五端可用；服务器在不在线是运行时问题。
  @override
  bool get isSupportedOnThisPlatform => true;

  @override
  Future<String?> sourceLabel(OnlineMangaLibraryEntry entry) async =>
      _serverOrNull(entry.sourceId)?.displayName;

  // ── 身份 / 描述符 ──────────────────────────────────────────────────────

  /// 浏览页上的一部 Kavita 系列 → 书架 seed（章节留空，作品页进页后刷新）。
  static OnlineMangaLibraryEntry entryFor({
    required KavitaServerConfig server,
    required KavitaSeries series,
  }) => OnlineMangaLibraryEntry(
    runtime: OnlineMangaRuntimeKind.kavita,
    extensionPackage: kKavitaMangaPackage,
    sourceId: server.id,
    series: _seriesFrom(series),
    chapters: const <OnlineMangaChapter>[],
  );

  /// 本机书架键：只由服务器配置 id + seriesId 推导。
  static String localBookKeyFor({
    required String serverConfigId,
    required int seriesId,
  }) => OnlineMangaLibraryService.bookKeyFor(
    runtime: OnlineMangaRuntimeKind.kavita,
    extensionPackage: kKavitaMangaPackage,
    sourceId: serverConfigId,
    seriesKey: '$seriesId',
  );

  static String coverMarker(int seriesId) => '$kKavitaCoverScheme$seriesId';

  static OnlineMangaSeries _seriesFrom(KavitaSeries series) =>
      OnlineMangaSeries(
        key: '${series.id}',
        title: series.displayName,
        coverUrl: coverMarker(series.id),
        raw: <String, Object?>{
          'seriesId': series.id,
          'libraryId': series.libraryId,
          'format': series.format,
          'name': series.name,
        },
      );

  /// Kavita 用这个章号表示「整卷文件、卷内无章号」（loose-leaf volume）。
  static const double _kLooseLeafNumber = -100000;

  static bool _isLooseLeaf(KavitaChapter chapter) =>
      (chapter.minNumber ?? 0) <= _kLooseLeafNumber ||
      chapter.range.trim() == '-100000';

  /// 系列详情 → 书架章节列表。
  ///
  /// 存储顺序与 Mihon 一致：**最新在前**（作品页「最旧在前」时整体反转）。
  /// [KavitaSeriesDetail.allChapters] 已按 Kavita `sortOrder` 升序摊平去重，这里
  /// 反转即可。
  static List<OnlineMangaChapter> chaptersFrom(KavitaSeriesDetail detail) {
    final Map<int, KavitaVolume> volumes = <int, KavitaVolume>{
      for (final KavitaVolume volume in detail.volumes) volume.id: volume,
    };
    final List<OnlineMangaChapter> ascending = <OnlineMangaChapter>[
      for (final KavitaChapter chapter in detail.allChapters)
        _chapterFrom(chapter, volumes[chapter.volumeId]),
    ];
    return List<OnlineMangaChapter>.unmodifiable(ascending.reversed);
  }

  static OnlineMangaChapter _chapterFrom(
    KavitaChapter chapter,
    KavitaVolume? volume,
  ) {
    final bool looseLeaf = _isLooseLeaf(chapter);
    final String volumeName = volume?.name.trim() ?? '';
    double? number;
    if (!chapter.isSpecial) {
      number = looseLeaf ? volume?.minNumber : chapter.minNumber;
      if (number != null && number <= _kLooseLeafNumber) number = null;
    }
    return OnlineMangaChapter(
      key: '${chapter.id}',
      name: _chapterName(chapter, looseLeaf: looseLeaf, volumeName: volumeName),
      number: number,
      raw: <String, Object?>{
        'chapterId': chapter.id,
        'volumeId': chapter.volumeId,
        'pages': chapter.pages,
        if (chapter.isSpecial) 'isSpecial': true,
      },
    );
  }

  static String _chapterName(
    KavitaChapter chapter, {
    required bool looseLeaf,
    required String volumeName,
  }) {
    final String titleName = chapter.titleName.trim();
    if (titleName.isNotEmpty) return titleName;
    if (chapter.isSpecial) return chapter.displayName;
    if (looseLeaf) {
      if (volumeName.isNotEmpty && volumeName != '-100000') {
        return 'Vol. $volumeName';
      }
      return chapter.displayName;
    }
    final String range = chapter.range.trim();
    return range.isEmpty ? chapter.displayName : 'Ch. $range';
  }

  // ── 运行时 ──────────────────────────────────────────────────────────

  @override
  Future<OnlineMangaRefreshResult> refresh(
    OnlineMangaLibraryEntry entry,
  ) async {
    final KavitaServerConfig server = _server(entry.sourceId);
    final int seriesId = _seriesId(entry);
    final KavitaApi api = _apiFor(server);
    final KavitaSeries series = await _guarded(
      server,
      'details',
      () => api.getSeries(seriesId),
    );
    if (!series.isArchive) {
      throw OnlineMangaUnavailable(
        OnlineMangaUnavailableReason.platformUnsupported,
        'This Kavita series is not an image archive (format ${series.format}); '
        'EPUB and PDF series are read as books',
        stage: 'details',
        sourceLabel: server.displayName,
      );
    }
    final KavitaSeriesDetail detail = await _guarded(
      server,
      'chapters',
      () => api.getSeriesDetail(seriesId),
    );
    return OnlineMangaRefreshResult(
      series: _seriesFrom(series),
      chapters: chaptersFrom(detail),
    );
  }

  @override
  Future<List<OnlineMangaPageRef>> resolveChapterPages({
    required OnlineMangaLibraryEntry entry,
    required OnlineMangaChapter chapter,
  }) async {
    final KavitaServerConfig server = _server(entry.sourceId);
    final int? chapterId = int.tryParse(chapter.key);
    if (chapterId == null) {
      throw OnlineMangaUnavailable(
        OnlineMangaUnavailableReason.runtimeFailure,
        'Invalid Kavita chapter key',
        stage: 'pages',
        sourceLabel: server.displayName,
      );
    }
    final KavitaChapterInfo info = await _guarded(
      server,
      'pages',
      () => _apiFor(server).getChapterInfo(chapterId),
    );
    if (info.pages <= 0) {
      throw OnlineMangaUnavailable(
        OnlineMangaUnavailableReason.runtimeFailure,
        'The Kavita server returned a chapter with no pages',
        stage: 'pages',
        sourceLabel: server.displayName,
      );
    }
    return <OnlineMangaPageRef>[
      for (int index = 0; index < info.pages; index++)
        KavitaMangaPageRef(
          index: index,
          serverConfigId: server.id,
          chapterId: chapterId,
          page: index,
        ),
    ];
  }

  @override
  Future<Uint8List> fetchChapterPage(OnlineMangaPageRef page) async {
    if (page is! KavitaMangaPageRef) {
      throw ArgumentError.value(page, 'page', 'not a Kavita page reference');
    }
    final KavitaServerConfig server = _server(page.serverConfigId);
    final Uint8List bytes = await _guarded(
      server,
      'pages',
      () => _apiFor(server).fetchPageBytes(page.chapterId, page.page),
    );
    if (bytes.isEmpty) {
      throw OnlineMangaUnavailable(
        OnlineMangaUnavailableReason.runtimeFailure,
        'The Kavita server returned an empty page',
        stage: 'pages',
        sourceLabel: server.displayName,
      );
    }
    return bytes;
  }

  /// [url] 是描述符里的 [kKavitaCoverScheme] 占位；真正的取图走 seriesId。
  @override
  Future<List<int>> fetchCover(
    OnlineMangaLibraryEntry entry,
    String url,
  ) async {
    final KavitaServerConfig server = _server(entry.sourceId);
    final int seriesId = url.startsWith(kKavitaCoverScheme)
        ? int.tryParse(url.substring(kKavitaCoverScheme.length)) ??
              _seriesId(entry)
        : _seriesId(entry);
    return _guarded(
      server,
      'cover',
      () => _apiFor(server).fetchSeriesCoverBytes(seriesId),
    );
  }

  // ── 内部 ──────────────────────────────────────────────────────────

  KavitaServerConfig? _serverOrNull(String id) {
    for (final KavitaServerConfig config in _servers()) {
      if (config.id == id) return config;
    }
    return null;
  }

  KavitaServerConfig _server(String id) {
    final KavitaServerConfig? config = _serverOrNull(id);
    if (config == null || !config.isUsable) {
      throw const OnlineMangaUnavailable(
        OnlineMangaUnavailableReason.sourceDisabled,
        'The Kavita server is missing, disabled or has no API key',
      );
    }
    return config;
  }

  static int _seriesId(OnlineMangaLibraryEntry entry) {
    final int? id = int.tryParse(entry.series.key);
    if (id == null) {
      throw const OnlineMangaUnavailable(
        OnlineMangaUnavailableReason.runtimeFailure,
        'Invalid Kavita series key',
      );
    }
    return id;
  }

  /// 把协议层 / 网络错误收成 [OnlineMangaUnavailable]。
  ///
  /// 错误文本一律先过 [redactCredentialsInText]，再把 API key 原文兜底替换掉——
  /// 它会进作品页诊断框（可复制）、错误日志与日志上传。文本被改写过时连 `cause`
  /// 都不保留（原异常的 `toString` 仍带着密钥）。
  Future<T> _guarded<T>(
    KavitaServerConfig server,
    String stage,
    Future<T> Function() request,
  ) async {
    try {
      return await request();
    } on OnlineMangaUnavailable {
      rethrow;
    } on KavitaApiException catch (error) {
      if (error.isUnauthorized || error.isForbidden) {
        throw OnlineMangaUnavailable(
          OnlineMangaUnavailableReason.runtimeFailure,
          'The Kavita server rejected the API key (HTTP ${error.statusCode})',
          stage: stage,
          sourceLabel: server.displayName,
        );
      }
      throw OnlineMangaUnavailable(
        OnlineMangaUnavailableReason.runtimeFailure,
        redactKavitaErrorText('$error', server.apiKey),
        cause: error,
        stage: stage,
        sourceLabel: server.displayName,
      );
    } on Object catch (error) {
      final String raw = '$error';
      final String text = redactKavitaErrorText(raw, server.apiKey);
      throw OnlineMangaUnavailable(
        OnlineMangaUnavailableReason.runtimeFailure,
        text,
        cause: text == raw ? error : null,
        stage: stage,
        sourceLabel: server.displayName,
      );
    }
  }
}

/// 错误文本脱敏：query 凭据参数 + API key 原文。
String redactKavitaErrorText(String text, String apiKey) {
  String out = redactCredentialsInText(text);
  final String key = apiKey.trim();
  if (key.isNotEmpty) out = out.replaceAll(key, kRedactedKavitaKey);
  return out;
}

/// API key 原文的替换占位。
const String kRedactedKavitaKey = '<redacted>';
