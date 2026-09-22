/// AniDB canonical anime metadata provider.
///
/// Search is always served by the official daily title catalog. The AniDB HTTP
/// API is only contacted when the caller supplies its own registered client
/// name and a positive client version; Shoko's `animeplugin` / `ommserver`
/// identities are explicitly rejected.
library;

import 'dart:async';
import 'dart:io';

import 'package:fushi_engine/media/video/metadata/anidb_title_catalog.dart';
import 'package:fushi_engine/media/video/metadata/anidb_udp_file_client.dart'
    show AnidbEpisodeInfo;
import 'package:fushi_engine/media/video/metadata/video_metadata_json.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_languages.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_transport.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

/// AniDB 明确下发的封禁（HTTP 200 + `<error>banned</error>`）。
///
/// 与普通网络故障分开的理由：普通故障重试是对的，封禁期间的每一次请求都在延长
/// 封禁。调用方靠类型分流，而不是靠解析 message。
class AniDbBannedException extends VideoMetadataNetworkException {
  const AniDbBannedException(super.message);
}

typedef AniDbProviderNow = DateTime Function();
typedef AniDbProviderSleep = Future<void> Function(Duration duration);

/// anime XML 的磁盘缓存目录（Shoko `AnimeDoc_{aid}.xml` + `MinimumHoursToRedownloadAnimeInfo`
/// 24h）：进程重启不重拉、封禁期间还能读旧 XML。
typedef AniDbXmlCacheDirectory = Future<Directory> Function();

class AniDbVideoMetadataProvider
    implements
        VideoMetadataProvider,
        VideoMetadataEpisodeAliasProvider,
        VideoMetadataRelationsProvider {
  AniDbVideoMetadataProvider({
    String clientName = '',
    int? clientVersion,
    this.language = kFallbackVideoMetadataLocale,
    http.Client? client,
    VideoMetadataHttpClient? transport,
    AniDbTitleCatalog? titleCatalog,
    this.apiUrl = 'http://api.anidb.net:9001/httpapi',
    this.imageBaseUrl = 'https://cdn.anidb.net/images/main',
    AniDbProviderNow? now,
    AniDbProviderSleep? sleep,
    Duration apiRequestInterval = const Duration(seconds: 3),
    bool? shareRequestGate,
    AniDbXmlCacheDirectory? xmlCacheDirectory,
  })  : assert(client == null || transport == null),
        _xmlCacheDirectory = xmlCacheDirectory,
        _clientName = clientName.trim().toLowerCase(),
        _clientVersion = clientVersion,
        // AniDB forbids rapid retries. Every real retry must re-enter this
        // provider's 2s+ queue instead of happening inside the transport.
        _transport = transport ??
            VideoMetadataHttpClient(client: client, maxAttempts: 1),
        _ownsTransport = transport == null,
        _titleCatalog = titleCatalog ?? _sharedTitleCatalog,
        _now = now ?? DateTime.now,
        _sleep = sleep ?? Future<void>.delayed,
        _requestGate = (shareRequestGate ??
                (client == null &&
                    transport == null &&
                    titleCatalog == null &&
                    now == null &&
                    sleep == null))
            ? _sharedRequestGates.putIfAbsent(
                apiUrl,
                _AniDbRequestGate.new,
              )
            : _AniDbRequestGate(),
        apiRequestInterval = apiRequestInterval < _minimumRequestInterval
            ? _minimumRequestInterval
            : apiRequestInterval;

  static const Set<String> _reservedShokoClientNames = <String>{
    'animeplugin',
    'ommserver',
  };
  static const int _maxAnimeXmlLength = 24 * 1024 * 1024;
  static const Duration _minimumRequestInterval = Duration(seconds: 2);

  /// AniDB 文档里的封禁时长。到点自动解闩，长驻的桌面进程不必重启才能恢复。
  static const Duration _banCooldown = Duration(hours: 24);
  static const Duration _animeCacheTtl = Duration(hours: 24);
  static const String catalogOnlyPayloadKey = 'anidbCatalogOnly';
  static final AniDbTitleCatalog _sharedTitleCatalog = AniDbTitleCatalog();
  // AniDB throttling belongs to the endpoint, not to one configured client
  // identity. Old/new settings can briefly coexist during a coordinator swap;
  // sharing by endpoint keeps those instances inside one process-wide queue.
  static final Map<String, _AniDbRequestGate> _sharedRequestGates =
      <String, _AniDbRequestGate>{};

  final String _clientName;
  final int? _clientVersion;
  final VideoMetadataHttpClient _transport;
  final bool _ownsTransport;
  final AniDbTitleCatalog _titleCatalog;
  final String apiUrl;
  final String imageBaseUrl;
  final String language;
  final AniDbProviderNow _now;
  final AniDbProviderSleep _sleep;
  final _AniDbRequestGate _requestGate;
  final Duration apiRequestInterval;
  final AniDbXmlCacheDirectory? _xmlCacheDirectory;
  final Map<int, _AniDbAnimeCacheEntry> _animeCache =
      <int, _AniDbAnimeCacheEntry>{};
  bool _closed = false;

  @override
  VideoMetadataProviderKind get providerKind => VideoMetadataProviderKind.anidb;

  /// The title catalog makes AniDB search usable even without HTTP API access.
  @override
  bool get isAvailable => !_closed;

  bool get isHttpApiAvailable => _hasHttpClientIdentity && !isBanned;

  /// 本地配置层面是否有一对可用的 HTTP 客户端身份（名 + 正版本号、非 Shoko 保留名、
  /// 且没被 AniDB 明确拒绝过）。不看封禁——封禁是另一种「暂时不可用」。
  bool get _hasHttpClientIdentity {
    final int? version = _clientVersion;
    return !_closed &&
        _clientName.isNotEmpty &&
        version != null &&
        version > 0 &&
        !_reservedShokoClientNames.contains(_clientName.toLowerCase()) &&
        httpIdentityRejection == null;
  }

  String get _httpIdentityKey => '$_clientName/${_clientVersion ?? ''}';

  /// AniDB HTTP API 明确拒绝过当前客户端身份时的服务端原话（`<error code="302">
  /// client version missing or invalid</error>`）；没拒绝过为 null。
  ///
  /// 闩按「身份」记在 endpoint 级请求闸上（BUG-2623）：同一进程里换 provider 实例
  /// 不重发注定失败的请求（一批 60 个作品就是 60 次 × 3s 限流），用户改成别的
  /// 自定义 client 后键不同、自然解闩。
  String? get httpIdentityRejection =>
      _requestGate.identityRejection(_httpIdentityKey);

  /// 为什么 HTTP anime XML 详情拿不到——给刮削日志用的一句人话。调用方在
  /// 拿到 catalog-only 作品时问这里，而不是把每条网络异常都吞成同一句固定文案。
  String get httpDetailUnavailableReason {
    final String? rejection = httpIdentityRejection;
    if (rejection != null) {
      return 'AniDB 拒绝了客户端身份 $_httpIdentityKey：$rejection'
          '（HTTP API 客户端未登记或版本无效，与 UDP 客户端是两条登记）';
    }
    final Duration? ban = banRemaining;
    if (ban != null) {
      return 'AniDB 已封禁本客户端，约 ${ban.inMinutes} 分钟后解除';
    }
    if (!_hasHttpClientIdentity) {
      return '未配置已登记的 AniDB HTTP 客户端身份';
    }
    final String? lastError = _lastAnimeXmlError;
    return lastError == null ? 'anime XML 未取到' : 'anime XML 请求失败：$lastError';
  }

  /// 最近一次 anime XML 远程请求失败的原因（传输 / 服务端错误），成功后清空。
  String? _lastAnimeXmlError;

  /// AniDB 是否正处在它自己下发的封禁窗口内。
  ///
  /// 闩住的是 endpoint（与限流队列共用同一个 [_AniDbRequestGate]），不是本实例：
  /// 配置指纹一变协调器就换一个 provider 实例，实例级的闩一换就没了，而封禁是按
  /// 客户端 IP 记在服务端的。批量调用方据此整批停手，而不是逐条撞墙。
  bool get isBanned => _requestGate.isBannedAt(_now());

  /// 距封禁窗口结束还有多久；未封禁为 null。
  Duration? get banRemaining => _requestGate.banRemainingAt(_now());

  @override
  Future<List<VideoMetadataWork>> search(
    VideoMetadataSearchRequest request,
  ) async {
    _ensureOpen();
    final List<AniDbTitleSearchResult> matches;
    try {
      matches = await _titleCatalog.search(request.title, limit: request.limit);
    } on AniDbTitleCatalogException catch (error) {
      // 目录拿不到（首次下载失败 / 24h 冷却 / anidb.net 不可达）是传输层故障，
      // 不是「没搜到」：折成网络异常，resolver 才会记 providerUnavailable 并
      // 继续问链上的 TMDB 兜底，而不是整批作品 failed（AniDB 成默认主源后这条
      // 是升级即触发的退化）。
      throw VideoMetadataNetworkException(
        'AniDB 标题目录不可用：${error.message}',
      );
    }
    return <VideoMetadataWork>[
      for (final AniDbTitleSearchResult match in matches)
        _catalogWork(
          match.record,
          request.mediaKind,
          matchedTitle: match.matchedTitle,
        ),
    ];
  }

  @override
  Future<VideoMetadataWork?> fetchWork(VideoMetadataLookup lookup) async {
    final int animeId = _validateLookup(lookup);
    final AniDbTitleRecord? catalogRecord = await _catalogRecordOrNull(animeId);
    _AniDbAnime? anime;
    try {
      anime = await _anime(animeId);
    } on VideoMetadataNetworkException {
      if (catalogRecord == null) rethrow;
    }
    if (anime != null) {
      return _mapAnime(anime, catalogRecord, lookup.mediaKind);
    }
    return catalogRecord == null
        ? null
        : _catalogWork(catalogRecord, lookup.mediaKind);
  }

  @override
  Future<List<VideoMetadataSeason>> fetchSeasons(
    VideoMetadataLookup lookup,
  ) async {
    final int animeId = _validateLookup(lookup);
    if (lookup.mediaKind == VideoMetadataMediaKind.movie) {
      return const <VideoMetadataSeason>[];
    }
    final AniDbTitleRecord? catalogRecord = await _catalogRecordOrNull(animeId);
    _AniDbAnime? anime;
    try {
      anime = await _anime(animeId);
    } on VideoMetadataNetworkException {
      if (catalogRecord == null) rethrow;
    }
    if (anime == null) {
      if (catalogRecord == null) return const <VideoMetadataSeason>[];
      final VideoMetadataWork fallback = _catalogWork(
        catalogRecord,
        lookup.mediaKind,
      );
      return <VideoMetadataSeason>[
        VideoMetadataSeason(
          seasonNumber: 1,
          title: fallback.title,
          ids: fallback.ids,
        ),
      ];
    }
    return <VideoMetadataSeason>[
      _mapSeason(
        anime,
        _mergedTitles(anime.titles, catalogRecord, animeId: anime.animeId),
      ),
      if (anime.specials.isNotEmpty) _mapSpecials(anime),
    ];
  }

  @override
  Future<List<VideoMetadataEpisode>> fetchEpisodes(
    VideoMetadataLookup lookup, {
    required int seasonNumber,
  }) async {
    final int animeId = _validateLookup(lookup);
    if (lookup.mediaKind == VideoMetadataMediaKind.movie ||
        (seasonNumber != 1 && seasonNumber != 0)) {
      return const <VideoMetadataEpisode>[];
    }
    if (isBanned) {
      throw const AniDbBannedException(
        'AniDB has temporarily banned this client; episode hydration is '
        'suspended until the ban expires',
      );
    }
    if (!isHttpApiAvailable) {
      throw const VideoMetadataNetworkException(
        'AniDB episode hydration requires a registered HTTP client identity',
      );
    }
    final _AniDbAnime? anime = await _anime(animeId);
    if (anime == null) {
      throw const VideoMetadataNetworkException(
        'AniDB episode metadata is unavailable',
      );
    }
    return List<VideoMetadataEpisode>.unmodifiable(
        seasonNumber == 0 ? anime.specials : anime.episodes);
  }

  Future<_AniDbAnime?> _anime(int animeId) async {
    _ensureOpen();
    if (!isHttpApiAvailable && _xmlCacheDirectory == null) return null;
    final DateTime now = _now();
    final _AniDbAnimeCacheEntry? cached = _animeCache[animeId];
    if (cached != null && now.isBefore(cached.expiresAt)) {
      return cached.value;
    }
    _animeCache.remove(animeId);
    final Future<_AniDbAnime?> loading = _loadAnime(animeId);
    final _AniDbAnimeCacheEntry entry = _AniDbAnimeCacheEntry(
      value: loading,
      expiresAt: now.add(_animeCacheTtl),
    );
    _animeCache[animeId] = entry;
    try {
      return await loading;
    } catch (_) {
      if (identical(_animeCache[animeId], entry)) {
        _animeCache.remove(animeId);
      }
      rethrow;
    }
  }

  /// Shoko `AnidbService.GetAnime` 的取数顺序：磁盘 XML 未过 24h 直接用；过期
  /// 才远程；远程失败（含封禁）回旧 XML；都没有才空。
  Future<_AniDbAnime?> _loadAnime(int animeId) async {
    final File? cacheFile = await _xmlCacheFile(animeId);
    _AniDbAnime? stale;
    if (cacheFile != null && await cacheFile.exists()) {
      try {
        final bool fresh =
            _now().difference((await cacheFile.stat()).modified) <
                _animeCacheTtl;
        final _AniDbAnime? parsed =
            _parseAnime(animeId, await cacheFile.readAsString());
        if (parsed != null && (fresh || !isHttpApiAvailable)) return parsed;
        stale = parsed;
      } on Object {
        // 坏缓存当没有：下面照常远程。
      }
    }
    if (!isHttpApiAvailable) return stale;
    final String? xml;
    try {
      xml = await _downloadAnimeXml(animeId);
    } on VideoMetadataNetworkException catch (error) {
      _lastAnimeXmlError = error.message;
      if (stale != null) return stale;
      rethrow;
    }
    if (xml == null) return null;
    final _AniDbAnime? anime;
    try {
      anime = _parseAnime(animeId, xml);
    } on AniDbBannedException catch (error) {
      _lastAnimeXmlError = error.message;
      if (stale != null) return stale;
      rethrow;
    } on VideoMetadataNetworkException catch (error) {
      _lastAnimeXmlError = error.message;
      rethrow;
    }
    _lastAnimeXmlError = null;
    if (anime != null && cacheFile != null) {
      try {
        await cacheFile.parent.create(recursive: true);
        await cacheFile.writeAsString(xml, flush: true);
      } on FileSystemException {
        // 缓存写不进去不影响本次结果。
      }
    }
    return anime;
  }

  Future<File?> _xmlCacheFile(int animeId) async {
    final AniDbXmlCacheDirectory? directory = _xmlCacheDirectory;
    if (directory == null) return null;
    try {
      return File(p.join((await directory()).path, 'AnimeDoc_$animeId.xml'));
    } on Object {
      return null;
    }
  }

  Future<String?> _downloadAnimeXml(int animeId) async {
    // Keep this check adjacent to the request as a fail-closed guard. Neither
    // an empty/incomplete identity nor Shoko's identities may reach httpapi.
    final int? clientVersion = _clientVersion;
    if (!isHttpApiAvailable || clientVersion == null) return null;
    final Uri uri = Uri.parse(apiUrl).replace(
      queryParameters: <String, String>{
        'client': _clientName,
        'clientver': '$clientVersion',
        'protover': '1',
        'request': 'anime',
        'aid': '$animeId',
      },
    );
    final VideoMetadataHttpResponse response;
    try {
      response = await _runRateLimitedRequest(
        () => _transport.get(
          uri,
          headers: <String, String>{
            'Accept': 'application/xml, text/xml;q=0.9',
            'User-Agent': '$_clientName/$clientVersion',
          },
          operation: 'AniDB anime $animeId',
        ),
      );
    } on VideoMetadataNetworkException catch (error) {
      if (error.statusCode == 404) return null;
      rethrow;
    }
    return response.body;
  }

  // ── Shoko 式补充能力：集名别名 / 前传关系 / 按 eid 的集信息 ─────────────

  /// 每集的全部语言标题（en / x-jat / ja / 资料语言…），喂 TMDB 逐集链接的来源
  /// 集与候选别名。季 0 = `S` 型特典。
  @override
  Future<Map<int, List<String>>> fetchEpisodeTitleAliases(
    VideoMetadataLookup lookup, {
    required int seasonNumber,
  }) async {
    final int animeId = _validateLookup(lookup);
    if (seasonNumber != 0 && seasonNumber != 1) {
      return const <int, List<String>>{};
    }
    final _AniDbAnime? anime = await _anime(animeId);
    if (anime == null) return const <int, List<String>>{};
    final List<VideoMetadataEpisode> episodes =
        seasonNumber == 0 ? anime.specials : anime.episodes;
    return <int, List<String>>{
      for (final VideoMetadataEpisode episode in episodes)
        if (_episodeIdOf(episode) case final int eid)
          if (anime.episodeTitles[eid] case final List<AniDbTitle> titles
              when titles.isNotEmpty)
            episode.episodeNumber: metadataUniqueStrings(<String?>[
              for (final AniDbTitle title in titles) title.value,
            ]),
    };
  }

  /// `<relatedanime type="Prequel">`（Shoko `TmdbSearchService` 沿前传链回溯到
  /// 根作品再搜 TMDB 剧）。
  @override
  Future<List<VideoMetadataLookup>> fetchPrequels(
    VideoMetadataLookup lookup,
  ) async {
    final int animeId = _validateLookup(lookup);
    final _AniDbAnime? anime = await _anime(animeId);
    if (anime == null) return const <VideoMetadataLookup>[];
    return <VideoMetadataLookup>[
      for (final int prequel in anime.prequelIds)
        VideoMetadataLookup(
          provider: providerKind,
          externalId: '$prequel',
          mediaKind: lookup.mediaKind,
        ),
    ];
  }

  /// anime XML 里某一集（Episode / Special）的信息：集号、播出日、三语集名——与
  /// UDP `EPISODE` 同形，供哈希身份服务优先从 XML 取、拿不到再走 UDP。
  /// 集不在这部作品里 / XML 拿不到 → null。
  Future<AnidbEpisodeInfo?> episodeInfo({
    required int animeId,
    required int episodeId,
  }) async {
    if (animeId <= 0 || episodeId <= 0) return null;
    final _AniDbAnime? anime;
    try {
      anime = await _anime(animeId);
    } on VideoMetadataNetworkException {
      return null;
    }
    if (anime == null) return null;
    for (final VideoMetadataEpisode episode in <VideoMetadataEpisode>[
      ...anime.episodes,
      ...anime.specials,
    ]) {
      if (_episodeIdOf(episode) != episodeId) continue;
      final List<AniDbTitle> titles =
          anime.episodeTitles[episodeId] ?? const <AniDbTitle>[];
      String pick(String language) => titles
          .where((AniDbTitle t) => t.language.toLowerCase() == language)
          .map((AniDbTitle t) => t.value)
          .firstWhere((String v) => v.trim().isNotEmpty, orElse: () => '');
      return AnidbEpisodeInfo(
        episodeId: episodeId,
        animeId: animeId,
        episodeNumber: episode.seasonNumber == 0
            ? 'S${episode.episodeNumber}'
            : '${episode.episodeNumber}',
        airedAt: episode.airDate == null
            ? null
            : DateTime.tryParse('${episode.airDate}T00:00:00Z'),
        englishTitle: pick('en'),
        romajiTitle: pick('x-jat'),
        kanjiTitle: pick('ja'),
      );
    }
    return null;
  }

  static int? _episodeIdOf(VideoMetadataEpisode episode) {
    for (final VideoMetadataId id in episode.ids) {
      if (id.type == 'anidb') return int.tryParse(id.value);
    }
    return null;
  }

  /// Serializes all AniDB HTTP calls and spaces their actual start times.
  /// `_animeCache` sits outside this method, so a provider cache hit never
  /// sleeps or enters the queue.
  Future<T> _runRateLimitedRequest<T>(Future<T> Function() request) {
    return _requestGate.run(
      request,
      interval: apiRequestInterval,
      now: _now,
      sleep: _sleep,
      ensureOpen: _ensureOpen,
    );
  }

  _AniDbAnime? _parseAnime(int requestedAnimeId, String xml) {
    if (xml.length > _maxAnimeXmlLength) {
      throw const VideoMetadataNetworkException(
        'AniDB anime response is too large',
      );
    }
    if (RegExp(
      r'<!\s*(?:DOCTYPE|ENTITY)\b',
      caseSensitive: false,
    ).hasMatch(xml)) {
      throw const VideoMetadataNetworkException(
        'AniDB anime response contains a forbidden declaration',
      );
    }

    final XmlDocument document;
    try {
      document = XmlDocument.parse(xml);
    } on XmlParserException catch (error) {
      throw VideoMetadataNetworkException(
        'AniDB anime response contains invalid XML: $error',
      );
    }
    final XmlElement root = document.rootElement;
    if (root.name.local == 'error') {
      final String message = root.innerText.trim();
      final String normalized = message.toLowerCase();
      if (normalized.contains('not found')) return null;
      // 封禁是 HTTP 200 + `<error>banned</error>`，传输层看不出异常。不闩住它，批量刮削
      // 会按 3s 一条把整个库打完，而每一条都在延长封禁。
      if (normalized.contains('banned')) {
        _requestGate.latchBan(_now().add(_banCooldown));
        throw AniDbBannedException(
          message.isEmpty ? 'AniDB has banned this client' : message,
        );
      }
      // `<error code="302">client version missing or invalid</error>`：这对
      // 身份在 AniDB 那边不是 HTTP API 客户端。换 aid 再问一万次答案也一样，闩住
      // 这对身份，本进程后续都走 catalog-only + UDP，别再占限流闸（BUG-2623）。
      final String code = (root.getAttribute('code') ?? '').trim();
      if (code == '302' || normalized.contains('client version')) {
        final String detail = message.isEmpty
            ? 'client version missing or invalid'
            : '$message${code.isEmpty ? '' : '（code $code）'}';
        _requestGate.latchIdentityRejection(_httpIdentityKey, detail);
        throw VideoMetadataNetworkException(
          'AniDB rejected client identity $_httpIdentityKey: $detail',
        );
      }
      throw VideoMetadataNetworkException(
        message.isEmpty
            ? 'AniDB anime request returned an error'
            : 'AniDB anime request failed: $message',
      );
    }
    if (root.name.local != 'anime') {
      throw const VideoMetadataNetworkException(
        'AniDB anime response has an unexpected root element',
      );
    }
    final int? animeId = int.tryParse(root.getAttribute('id') ?? '');
    if (animeId == null || animeId != requestedAnimeId) {
      throw const VideoMetadataNetworkException(
        'AniDB anime response has a mismatched anime id',
      );
    }

    final List<AniDbTitle> titles = _parseTitles(root.getElement('titles'));
    if (titles.isEmpty) {
      throw const VideoMetadataNetworkException(
        'AniDB anime response contains no usable titles',
      );
    }
    final String type = _text(root.getElement('type')) ?? '';
    final String? premiered = _date(_text(root.getElement('startdate')));
    final String? endDate = _date(_text(root.getElement('enddate')));
    final int? declaredEpisodeCount = _positiveInt(
      _text(root.getElement('episodecount')),
    );
    final _AniDbRating rating = _parseRating(root.getElement('ratings'));
    final Map<int, List<AniDbTitle>> episodeTitles = <int, List<AniDbTitle>>{};
    final List<VideoMetadataEpisode> episodes = _parseEpisodes(
      root.getElement('episodes'),
      episodeTitles: episodeTitles,
    );
    final List<VideoMetadataEpisode> specials = _parseEpisodes(
      root.getElement('episodes'),
      specials: true,
      episodeTitles: episodeTitles,
    );
    // Shoko `CrossRef_AniDB_MAL`：AniDB 自己登记的 MAL 条目（resources type 2）。
    final List<int> malIds = <int>[
      for (final XmlElement resource
          in root.getElement('resources')?.findElements('resource') ??
              const <XmlElement>[])
        if ((resource.getAttribute('type') ?? '').trim() == '2')
          for (final XmlElement entity
              in resource.findElements('externalentity'))
            for (final XmlElement identifier
                in entity.findElements('identifier'))
              if (int.tryParse(identifier.innerText.trim()) case final int id
                  when id > 0)
                id,
    ];
    final List<int> prequelIds = <int>[
      for (final XmlElement related
          in root.getElement('relatedanime')?.findElements('anime') ??
              const <XmlElement>[])
        if ((related.getAttribute('type') ?? '').trim().toLowerCase() ==
            'prequel')
          if (int.tryParse((related.getAttribute('id') ?? '').trim())
              case final int id when id > 0)
            id,
    ];
    final List<_AniDbCreator> creators = _parseCreators(
      root.getElement('creators'),
    );
    final List<VideoMetadataCredit> credits = <VideoMetadataCredit>[
      ..._mapStaffCredits(creators),
      ..._parseCharacterCredits(root.getElement('characters')),
    ];
    final List<String> tags = <String>[
      for (final XmlElement tag
          in root.getElement('tags')?.findElements('tag') ??
              const <XmlElement>[])
        if (_text(tag.getElement('name')) case final String name) name,
    ];
    final String restricted =
        (root.getAttribute('restricted') ?? '').trim().toLowerCase();
    return _AniDbAnime(
      animeId: animeId,
      animeType: type.trim(),
      titles: titles,
      premiered: premiered,
      endDate: endDate,
      plot: _text(root.getElement('description')),
      rating: rating.value,
      ratingVotes: rating.votes,
      picture: _text(root.getElement('picture')),
      homepage: _text(root.getElement('url')),
      restricted: restricted == 'true' || restricted == '1',
      declaredEpisodeCount: declaredEpisodeCount,
      tags: metadataUniqueStrings(tags),
      studios: metadataUniqueStrings(<String?>[
        for (final _AniDbCreator creator in creators)
          if (_isStudioRole(creator.type)) creator.name,
      ]),
      credits: credits,
      episodes: episodes,
      specials: specials,
      malIds: malIds.toSet().toList(growable: false),
      prequelIds: prequelIds.toSet().toList(growable: false),
      episodeTitles: episodeTitles,
    );
  }

  VideoMetadataWork _mapAnime(
    _AniDbAnime anime,
    AniDbTitleRecord? catalogRecord,
    VideoMetadataMediaKind requestedKind,
  ) {
    final VideoMetadataMediaKind kind = _mediaKindForAnime(
      anime.animeType,
      requestedKind,
    );
    final AniDbTitleRecord titles = _mergedTitles(
      anime.titles,
      catalogRecord,
      animeId: anime.animeId,
    );
    final _SelectedTitles selected = _selectTitles(titles);
    final List<VideoMetadataSeason> seasons = kind == VideoMetadataMediaKind.tv
        ? <VideoMetadataSeason>[
            _mapSeason(anime, titles),
            if (anime.specials.isNotEmpty) _mapSpecials(anime),
          ]
        : const <VideoMetadataSeason>[];
    return VideoMetadataWork(
      provider: providerKind,
      kind: kind,
      title: selected.title,
      originalTitle: selected.originalTitle,
      aliases: selected.aliases,
      year: metadataYear(anime.premiered),
      premiered: anime.premiered,
      endDate: anime.endDate,
      plot: anime.plot,
      rating: anime.rating,
      ratingVotes: anime.ratingVotes,
      runtimeMinutes:
          kind == VideoMetadataMediaKind.movie && anime.episodes.isNotEmpty
              ? anime.episodes.first.runtimeMinutes
              : null,
      contentRating: anime.restricted ? 'R18+' : null,
      originalLanguage: 'ja',
      homepage: anime.homepage ?? 'https://anidb.net/anime/${anime.animeId}',
      seasonCount: kind == VideoMetadataMediaKind.tv ? 1 : null,
      episodeCount: kind == VideoMetadataMediaKind.tv
          ? (anime.declaredEpisodeCount ?? anime.episodes.length)
          : null,
      studios: anime.studios,
      keywords: anime.tags,
      ids: <VideoMetadataId>[
        VideoMetadataId(
          type: 'anidb',
          value: '${anime.animeId}',
          isDefault: true,
        ),
        // MAL 只作交叉引用（Shoko CrossRef_AniDB_MAL），不是资料源。
        for (final int malId in anime.malIds)
          VideoMetadataId(type: 'mal', value: '$malId'),
      ],
      credits: anime.credits,
      images: <VideoMetadataImage>[
        if (_imageUrl(anime.picture) case final String url)
          VideoMetadataImage(
            kind: VideoMetadataImageKind.cover,
            url: url,
            provider: providerKind,
          ),
      ],
      seasons: seasons,
      rawPayload: <String, Object?>{
        'aid': anime.animeId,
        'type': anime.animeType,
        'restricted': anime.restricted,
      },
    );
  }

  VideoMetadataSeason _mapSeason(_AniDbAnime anime, AniDbTitleRecord titles) {
    final _SelectedTitles selected = _selectTitles(titles);
    return VideoMetadataSeason(
      seasonNumber: 1,
      title: selected.title,
      plot: anime.plot,
      airDate: anime.premiered,
      year: metadataYear(anime.premiered),
      episodeCount: anime.declaredEpisodeCount ?? anime.episodes.length,
      rating: anime.rating,
      ids: <VideoMetadataId>[
        VideoMetadataId(type: 'anidb', value: '${anime.animeId}'),
      ],
      images: <VideoMetadataImage>[
        if (_imageUrl(anime.picture) case final String url)
          VideoMetadataImage(
            kind: VideoMetadataImageKind.cover,
            url: url,
            provider: providerKind,
            seasonNumber: 1,
          ),
      ],
      episodes: anime.episodes,
    );
  }

  /// AniDB `S` 型特典 → 第 0 季（TMDB 的 Specials 同一位置）。
  VideoMetadataSeason _mapSpecials(_AniDbAnime anime) => VideoMetadataSeason(
        seasonNumber: 0,
        title: 'Specials',
        episodeCount: anime.specials.length,
        ids: <VideoMetadataId>[
          VideoMetadataId(type: 'anidb', value: '${anime.animeId}'),
        ],
        episodes: anime.specials,
      );

  VideoMetadataWork _catalogWork(
    AniDbTitleRecord record,
    VideoMetadataMediaKind kind, {
    AniDbTitle? matchedTitle,
  }) {
    final _SelectedTitles selected = _selectTitles(record);
    final List<String> aliases = metadataUniqueStrings(<String?>[
      ...selected.aliases,
      if (matchedTitle?.value != selected.title) matchedTitle?.value,
    ]);
    return VideoMetadataWork(
      provider: providerKind,
      kind: kind,
      title: selected.title,
      originalTitle: selected.originalTitle,
      aliases: aliases,
      homepage: 'https://anidb.net/anime/${record.animeId}',
      seasonCount: kind == VideoMetadataMediaKind.tv ? 1 : null,
      ids: <VideoMetadataId>[
        VideoMetadataId(
          type: 'anidb',
          value: '${record.animeId}',
          isDefault: true,
        ),
      ],
      rawPayload: const <String, Object?>{catalogOnlyPayloadKey: true},
    );
  }

  List<AniDbTitle> _parseTitles(
    XmlElement? parent, {
    bool allowMissingType = false,
  }) =>
      <AniDbTitle>[
        for (final XmlElement element
            in parent?.findElements('title') ?? const <XmlElement>[])
          if (_text(element) case final String value)
            AniDbTitle(
              value: value,
              type: (element.getAttribute('type') ??
                      (allowMissingType ? 'none' : ''))
                  .trim()
                  .toLowerCase(),
              language: _xmlLanguage(element),
            ),
      ]
          .where(
            (AniDbTitle title) =>
                title.type.isNotEmpty && title.language.isNotEmpty,
          )
          .toList();

  /// [specials] = false：正片（epno 纯数字）；true：`S` 型特典（Shoko
  /// `EpisodeType.Special`），落第 0 季、集号取 `S` 后的序号。C/T/P/O（片头
  /// 片尾 / 预告 / 恶搞 / 其它）两边都不取——Shoko 也只把 Episode + Special
  /// 拿去和 TMDB 对。
  List<VideoMetadataEpisode> _parseEpisodes(
    XmlElement? parent, {
    bool specials = false,
    Map<int, List<AniDbTitle>>? episodeTitles,
  }) {
    final Map<int, VideoMetadataEpisode> episodes =
        <int, VideoMetadataEpisode>{};
    final RegExp shape = specials ? RegExp(r'^S(\d+)$') : RegExp(r'^(\d+)$');
    final int seasonNumber = specials ? 0 : 1;
    for (final XmlElement element
        in parent?.findElements('episode') ?? const <XmlElement>[]) {
      final String epno = (_text(element.getElement('epno')) ?? '').trim();
      final RegExpMatch? numberMatch = shape.firstMatch(epno);
      if (numberMatch == null) continue;
      final int? episodeNumber = int.tryParse(numberMatch.group(1)!);
      if (episodeNumber == null || episodeNumber <= 0) continue;
      final int? episodeId = int.tryParse(
        (element.getAttribute('id') ?? '').trim(),
      );
      final List<AniDbTitle> directTitles = _parseTitles(
        element,
        allowMissingType: true,
      );
      // The official AniDB HTTP response places episode <title> elements
      // directly under <episode>. Accept the old wrapper shape only as a
      // compatibility fallback for cached/test fixtures.
      final List<AniDbTitle> titles = directTitles.isNotEmpty
          ? directTitles
          : _parseTitles(
              element.getElement('titles'),
              allowMissingType: true,
            );
      final AniDbTitleRecord record = AniDbTitleRecord(
        animeId: episodeId ?? episodeNumber,
        titles: titles.isEmpty
            ? <AniDbTitle>[
                AniDbTitle(
                  value: 'Episode $episodeNumber',
                  type: 'main',
                  language: 'x-other',
                ),
              ]
            : titles,
      );
      final String? airDate = _date(_text(element.getElement('airdate')));
      final XmlElement? ratingElement = element.getElement('rating');
      if (episodeId != null && episodeTitles != null) {
        episodeTitles.putIfAbsent(episodeId, () => titles);
      }
      episodes.putIfAbsent(
        episodeNumber,
        () => VideoMetadataEpisode(
          seasonNumber: seasonNumber,
          episodeNumber: episodeNumber,
          title: _selectTitles(record).title,
          plot: _text(element.getElement('summary')),
          airDate: airDate,
          year: metadataYear(airDate),
          absoluteNumber: specials ? null : episodeNumber,
          rating: _positiveDouble(_text(ratingElement)),
          ratingVotes: _positiveInt(ratingElement?.getAttribute('votes')),
          runtimeMinutes: _positiveInt(_text(element.getElement('length'))),
          ids: <VideoMetadataId>[
            if (episodeId != null)
              VideoMetadataId(
                type: 'anidb',
                value: '$episodeId',
                isDefault: true,
              ),
          ],
        ),
      );
    }
    final List<VideoMetadataEpisode> result = episodes.values.toList()
      ..sort(
        (VideoMetadataEpisode left, VideoMetadataEpisode right) =>
            left.episodeNumber.compareTo(right.episodeNumber),
      );
    return result;
  }

  List<_AniDbCreator> _parseCreators(XmlElement? parent) => <_AniDbCreator>[
        for (final XmlElement element
            in parent?.findElements('name') ?? const <XmlElement>[])
          if (_text(element) case final String name)
            _AniDbCreator(
              id: int.tryParse(element.getAttribute('id') ?? ''),
              name: name,
              type: (element.getAttribute('type') ?? '').trim(),
            ),
      ];

  List<VideoMetadataCredit> _mapStaffCredits(List<_AniDbCreator> creators) {
    final List<VideoMetadataCredit> credits = <VideoMetadataCredit>[];
    for (final _AniDbCreator creator in creators) {
      final VideoMetadataCreditKind? kind = _staffKind(creator.type);
      if (kind == null) continue;
      credits.add(
        VideoMetadataCredit(
          kind: kind,
          person: VideoMetadataPerson(
            id: creator.id?.toString(),
            name: creator.name,
            ids: <VideoMetadataId>[
              if (creator.id != null)
                VideoMetadataId(type: 'anidb', value: '${creator.id}'),
            ],
          ),
          job: creator.type,
          order: credits.length,
        ),
      );
    }
    return credits;
  }

  List<VideoMetadataCredit> _parseCharacterCredits(XmlElement? parent) {
    final List<VideoMetadataCredit> credits = <VideoMetadataCredit>[];
    for (final XmlElement element
        in parent?.findElements('character') ?? const <XmlElement>[]) {
      final String? characterName = _text(element.getElement('name'));
      if (characterName == null) continue;
      final int? characterId = int.tryParse(element.getAttribute('id') ?? '');
      final VideoMetadataCharacter character = VideoMetadataCharacter(
        id: characterId?.toString(),
        name: characterName,
        description: _text(element.getElement('description')),
        imageUrl: _imageUrl(_text(element.getElement('picture'))),
        ids: <VideoMetadataId>[
          if (characterId != null)
            VideoMetadataId(type: 'anidb', value: '$characterId'),
        ],
      );
      for (final XmlElement seiyuu in element.findElements('seiyuu')) {
        final String? personName = _text(seiyuu);
        if (personName == null) continue;
        final int? personId = int.tryParse(seiyuu.getAttribute('id') ?? '');
        credits.add(
          VideoMetadataCredit(
            kind: VideoMetadataCreditKind.voiceActor,
            person: VideoMetadataPerson(
              id: personId?.toString(),
              name: personName,
              profileUrl: _imageUrl(seiyuu.getAttribute('picture')),
              ids: <VideoMetadataId>[
                if (personId != null)
                  VideoMetadataId(type: 'anidb', value: '$personId'),
              ],
            ),
            character: character,
            language: 'ja',
            roleName: characterName,
            order: credits.length,
          ),
        );
      }
    }
    return credits;
  }

  _AniDbRating _parseRating(XmlElement? parent) {
    for (final String name in const <String>[
      'permanent',
      'temporary',
      'review',
    ]) {
      final XmlElement? element = parent?.getElement(name);
      final double? value = _positiveDouble(_text(element));
      if (element != null && value != null) {
        return _AniDbRating(
          value: value,
          votes: _positiveInt(element.getAttribute('count')),
        );
      }
    }
    return const _AniDbRating();
  }

  AniDbTitleRecord _mergedTitles(
    List<AniDbTitle> apiTitles,
    AniDbTitleRecord? catalogRecord, {
    required int animeId,
  }) {
    final List<AniDbTitle> titles = <AniDbTitle>[];
    for (final AniDbTitle title in <AniDbTitle>[
      ...apiTitles,
      ...?catalogRecord?.titles,
    ]) {
      final bool duplicate = titles.any(
        (AniDbTitle existing) =>
            existing.value == title.value &&
            existing.type == title.type &&
            existing.language == title.language,
      );
      if (!duplicate) titles.add(title);
    }
    return AniDbTitleRecord(animeId: animeId, titles: titles);
  }

  _SelectedTitles _selectTitles(AniDbTitleRecord record) {
    final List<String> preferredLanguages = _preferredLanguages(language);
    AniDbTitle? selected;
    for (final String preferred in preferredLanguages) {
      selected ??= _findTitle(record.titles, preferred, 'main');
      selected ??= _findTitle(record.titles, preferred, 'official');
      selected ??= _findTitle(record.titles, preferred, null);
      if (selected != null) break;
    }
    selected ??= record.mainTitle;
    selected ??= _findTitle(record.titles, 'en', 'official');
    selected ??= record.titles.isEmpty ? null : record.titles.first;
    if (selected == null) {
      throw StateError('AniDB title record contains no usable titles');
    }
    final String title = selected.value;
    final AniDbTitle? japanese = _findTitle(record.titles, 'ja', 'main') ??
        _findTitle(record.titles, 'ja', 'official') ??
        _findTitle(record.titles, 'ja', null);
    final String? originalTitle =
        japanese == null || japanese.value == title ? null : japanese.value;
    return _SelectedTitles(
      title: title,
      originalTitle: originalTitle,
      aliases: metadataUniqueStrings(<String?>[
        for (final AniDbTitle value in record.titles)
          if (value.value != title) value.value,
      ]),
    );
  }

  AniDbTitle? _findTitle(
    List<AniDbTitle> titles,
    String languageCode,
    String? type,
  ) {
    final String expected = languageCode.toLowerCase();
    for (final AniDbTitle title in titles) {
      final String actual = title.language.toLowerCase();
      if ((actual == expected || actual.startsWith('$expected-')) &&
          (type == null || title.type == type)) {
        return title;
      }
    }
    return null;
  }

  List<String> _preferredLanguages(String locale) {
    final String normalized = locale.trim().replaceAll('_', '-').toLowerCase();
    final List<String> result = <String>[];
    void add(String value) {
      if (value.isNotEmpty && !result.contains(value)) result.add(value);
    }

    if (normalized.startsWith('zh')) {
      if (normalized.contains('tw') ||
          normalized.contains('hk') ||
          normalized.contains('hant')) {
        add('zh-hant');
      } else {
        add('zh-hans');
      }
      add(normalized);
      add('zh');
    } else {
      add(normalized);
      if (normalized.contains('-')) add(normalized.split('-').first);
    }
    add('en');
    add('x-jat');
    return result;
  }

  Future<AniDbTitleRecord?> _catalogRecordOrNull(int animeId) async {
    try {
      return await _titleCatalog.findByAnimeId(animeId);
    } on AniDbTitleCatalogException {
      return null;
    }
  }

  String? _imageUrl(String? filename) {
    final String value = filename?.trim() ?? '';
    if (value.isEmpty) return null;
    final String base = imageBaseUrl.endsWith('/')
        ? imageBaseUrl.substring(0, imageBaseUrl.length - 1)
        : imageBaseUrl;
    return '$base/${Uri.encodeComponent(value)}';
  }

  int _validateLookup(VideoMetadataLookup lookup) {
    _ensureOpen();
    if (lookup.provider != providerKind) {
      throw ArgumentError.value(lookup, 'lookup', 'Not an AniDB lookup');
    }
    final String externalId = lookup.externalId.trim();
    final int? animeId = int.tryParse(externalId);
    if (animeId == null || animeId <= 0) {
      throw ArgumentError.value(
        lookup.externalId,
        'lookup.externalId',
        'AniDB anime id must be a positive integer',
      );
    }
    return animeId;
  }

  void _ensureOpen() {
    if (_closed) throw StateError('AniDbVideoMetadataProvider is closed');
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _animeCache.clear();
    if (_ownsTransport) _transport.close();
  }
}

class _AniDbRequestGate {
  Future<void> _queue = Future<void>.value();
  DateTime? _lastStartedAt;
  DateTime? _bannedUntil;

  /// 被 AniDB 明确拒绝的客户端身份（`name/version` → 服务端原话）。按身份而不是
  /// 按闸整体记：闸按 endpoint 共享，用户换一对自定义 client 后不该继承旧拒绝。
  final Map<String, String> _rejectedIdentities = <String, String>{};

  void latchBan(DateTime until) {
    final DateTime? current = _bannedUntil;
    if (current == null || until.isAfter(current)) _bannedUntil = until;
  }

  void latchIdentityRejection(String identity, String reason) {
    _rejectedIdentities[identity] = reason;
  }

  String? identityRejection(String identity) => _rejectedIdentities[identity];

  bool isBannedAt(DateTime now) => banRemainingAt(now) != null;

  Duration? banRemainingAt(DateTime now) {
    final DateTime? until = _bannedUntil;
    if (until == null) return null;
    final Duration remaining = until.difference(now);
    if (remaining <= Duration.zero) {
      _bannedUntil = null;
      return null;
    }
    return remaining;
  }

  Future<T> run<T>(
    Future<T> Function() request, {
    required Duration interval,
    required AniDbProviderNow now,
    required AniDbProviderSleep sleep,
    required void Function() ensureOpen,
  }) {
    final Completer<T> result = Completer<T>();
    final Future<void> previous = _queue;
    _queue = () async {
      try {
        await previous;
        ensureOpen();
        final DateTime current = now();
        final DateTime? lastStartedAt = _lastStartedAt;
        if (lastStartedAt != null) {
          final Duration elapsed = current.difference(lastStartedAt);
          final Duration remaining = interval - elapsed;
          if (remaining > Duration.zero) await sleep(remaining);
        }
        ensureOpen();
        _lastStartedAt = now();
        result.complete(await request());
      } catch (error, stackTrace) {
        result.completeError(error, stackTrace);
      }
    }();
    return result.future;
  }
}

String? _text(XmlElement? element) {
  final String value = element?.innerText.trim() ?? '';
  return value.isEmpty ? null : value;
}

String _xmlLanguage(XmlElement element) => (element.getAttribute('xml:lang') ??
        element.getAttribute(
          'lang',
          namespace: 'http://www.w3.org/XML/1998/namespace',
        ) ??
        '')
    .trim();

String? _date(String? value) {
  final String text = value?.trim() ?? '';
  if (text == '1970-01-01') return null;
  return RegExp(r'^\d{4}(?:-\d{2}(?:-\d{2})?)?$').hasMatch(text) ? text : null;
}

int? _positiveInt(Object? value) {
  final int? parsed = metadataInt(value);
  return parsed != null && parsed > 0 ? parsed : null;
}

double? _positiveDouble(Object? value) {
  final double? parsed = metadataDouble(value);
  return parsed != null && parsed > 0 ? parsed : null;
}

VideoMetadataMediaKind _mediaKindForAnime(
  String animeType,
  VideoMetadataMediaKind requestedKind,
) {
  switch (animeType.trim().toLowerCase()) {
    case 'movie':
      return VideoMetadataMediaKind.movie;
    case 'tv series':
      return VideoMetadataMediaKind.tv;
    default:
      // AniDB types such as OVA, Web and TV Special describe release format,
      // not whether the user's library represents the work as one movie file
      // or an episodic series. Preserve the lookup's local media shape.
      return requestedKind;
  }
}

VideoMetadataCreditKind? _staffKind(String role) {
  final String value = role.toLowerCase();
  if (value.contains('director') || value.contains('direction')) {
    return VideoMetadataCreditKind.director;
  }
  if (value.contains('script') ||
      value.contains('screenplay') ||
      value.contains('series composition') ||
      value.contains('scenario')) {
    return VideoMetadataCreditKind.writer;
  }
  return null;
}

bool _isStudioRole(String role) {
  final String value = role.toLowerCase();
  return value.contains('animation work') ||
      value.contains('animation production') ||
      value == 'production' ||
      value.contains('studio');
}

class _AniDbAnime {
  const _AniDbAnime({
    required this.animeId,
    required this.animeType,
    required this.titles,
    required this.premiered,
    required this.endDate,
    required this.plot,
    required this.rating,
    required this.ratingVotes,
    required this.picture,
    required this.homepage,
    required this.restricted,
    required this.declaredEpisodeCount,
    required this.tags,
    required this.studios,
    required this.credits,
    required this.episodes,
    this.specials = const <VideoMetadataEpisode>[],
    this.malIds = const <int>[],
    this.prequelIds = const <int>[],
    this.episodeTitles = const <int, List<AniDbTitle>>{},
  });

  /// AniDB `<resources type="2">` 登记的 MAL 条目（交叉引用）。
  final List<int> malIds;

  /// `<relatedanime type="Prequel">` 的 aid。
  final List<int> prequelIds;

  /// eid → 该集全部语言标题（逐集链接与 UDP 兜底用）。
  final Map<int, List<AniDbTitle>> episodeTitles;

  final int animeId;
  final String animeType;
  final List<AniDbTitle> titles;
  final String? premiered;
  final String? endDate;
  final String? plot;
  final double? rating;
  final int? ratingVotes;
  final String? picture;
  final String? homepage;
  final bool restricted;
  final int? declaredEpisodeCount;
  final List<String> tags;
  final List<String> studios;
  final List<VideoMetadataCredit> credits;
  final List<VideoMetadataEpisode> episodes;

  /// `S` 型特典（第 0 季）。
  final List<VideoMetadataEpisode> specials;
}

class _AniDbAnimeCacheEntry {
  const _AniDbAnimeCacheEntry({required this.value, required this.expiresAt});

  final Future<_AniDbAnime?> value;
  final DateTime expiresAt;
}

class _AniDbCreator {
  const _AniDbCreator({
    required this.id,
    required this.name,
    required this.type,
  });

  final int? id;
  final String name;
  final String type;
}

class _AniDbRating {
  const _AniDbRating({this.value, this.votes});

  final double? value;
  final int? votes;
}

class _SelectedTitles {
  const _SelectedTitles({
    required this.title,
    required this.originalTitle,
    required this.aliases,
  });

  final String title;
  final String? originalTitle;
  final List<String> aliases;
}
