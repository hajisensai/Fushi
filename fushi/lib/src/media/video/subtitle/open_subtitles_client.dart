import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'package:fushi/src/media/external_provider.dart';
import 'package:fushi/src/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_models.dart';
import 'package:fushi/src/media/video/subtitle/video_subtitle_provider.dart';
import 'package:fushi/src/utils/net/app_http.dart';
import 'package:fushi/src/utils/net/app_user_agent.dart';

const int kMaximumSubtitleDownloadBytes = 64 * 1024 * 1024;

class OpenSubtitlesConfig {
  OpenSubtitlesConfig({
    required this.apiKey,
    this.username,
    this.password,
    String? userAgent,
    Uri? baseUrl,
    this.enabled = true,
    this.priority = 200,
    this.allowInsecureHttp = false,
  })  : userAgent = _resolveUserAgent(userAgent),
        baseUrl =
            baseUrl ?? Uri.parse('https://api.opensubtitles.com/api/v1') {
    if (this.baseUrl.host.isEmpty ||
        this.baseUrl.hasQuery ||
        this.baseUrl.userInfo.isNotEmpty ||
        this.baseUrl.hasFragment) {
      throw ArgumentError(
        'OpenSubtitles base URL must have a host and no query, user info, or '
        'fragment',
      );
    }
    if (this.baseUrl.scheme != 'https' &&
        !(this.baseUrl.scheme == 'http' &&
            (allowInsecureHttp || _isLoopback(this.baseUrl.host)))) {
      throw ArgumentError(
        'OpenSubtitles base URL must use HTTPS unless insecure HTTP is '
        'explicitly allowed or the host is loopback',
      );
    }
  }

  factory OpenSubtitlesConfig.fromJson(Map<String, Object?> json) {
    final String? rawBaseUrl = json['baseUrl'] as String?;
    return OpenSubtitlesConfig(
      apiKey: json['apiKey'] as String? ?? '',
      username: json['username'] as String?,
      password: json['password'] as String?,
      userAgent: json['userAgent'] as String?,
      baseUrl: rawBaseUrl == null || rawBaseUrl.trim().isEmpty
          ? null
          : Uri.parse(rawBaseUrl),
      enabled: json['enabled'] is bool ? json['enabled']! as bool : true,
      priority: json['priority'] is int ? json['priority']! as int : 200,
      allowInsecureHttp: json['allowInsecureHttp'] is bool
          ? json['allowInsecureHttp']! as bool
          : false,
    );
  }

  /// 缺省 / 存量旧默认值都归一到当前 app 身份；用户自填的 UA 原样保留。
  ///
  /// `video_subtitle_opensubtitles_config` 是把整个配置序列化成 JSON 存的，所以
  /// 光改构造默认值改不动已落盘的 `Hibiki v1`——那条 UA 会一直发出去。
  static String _resolveUserAgent(String? raw) {
    final String trimmed = raw?.trim() ?? '';
    if (trimmed.isEmpty || trimmed == kLegacyOpenSubtitlesUserAgent) {
      return fushiUserAgent('opensubtitles');
    }
    return raw!;
  }

  final String apiKey;
  final String? username;
  final String? password;
  final String userAgent;
  final Uri baseUrl;
  final bool enabled;
  final int priority;
  final bool allowInsecureHttp;

  bool get hasLoginCredentials =>
      username?.trim().isNotEmpty == true && password?.isNotEmpty == true;

  Map<String, Object?> toJson({bool includeSecrets = true}) =>
      <String, Object?>{
        if (includeSecrets) 'apiKey': apiKey,
        if (includeSecrets) 'username': username,
        if (includeSecrets) 'password': password,
        'userAgent': userAgent,
        'baseUrl': baseUrl.toString(),
        'enabled': enabled,
        'priority': priority,
        'allowInsecureHttp': allowInsecureHttp,
      };

  @override
  String toString() =>
      'OpenSubtitlesConfig(baseUrlHost=${baseUrl.host}, enabled=$enabled, '
      'priority=$priority, loginConfigured=$hasLoginCredentials)';
}

class OpenSubtitlesSearchRecord {
  const OpenSubtitlesSearchRecord({
    required this.fileId,
    required this.fileName,
    required this.language,
    this.releaseName,
    this.season,
    this.episode,
    this.downloadCount = 0,
    this.hearingImpaired = false,
    this.fps,
  });

  final int fileId;
  final String fileName;
  final String language;
  final String? releaseName;
  final int? season;
  final int? episode;
  final int downloadCount;
  final bool hearingImpaired;
  final double? fps;
}

List<OpenSubtitlesSearchRecord> parseOpenSubtitlesSearchResponse(String body) {
  final Object? decoded = jsonDecode(body);
  if (decoded is! Map) {
    throw const FormatException('OpenSubtitles response must be an object');
  }
  final Object? rawData = decoded['data'];
  if (rawData is! List) {
    throw const FormatException('OpenSubtitles response data must be an array');
  }
  final List<OpenSubtitlesSearchRecord> records = <OpenSubtitlesSearchRecord>[];
  for (final Object? rawEntry in rawData) {
    if (rawEntry is! Map) continue;
    final Map<Object?, Object?> attributes = rawEntry['attributes'] is Map
        ? rawEntry['attributes']! as Map<Object?, Object?>
        : const <Object?, Object?>{};
    final Object? rawFiles = attributes['files'];
    if (rawFiles is! List) continue;
    final Map<Object?, Object?> feature = attributes['feature_details'] is Map
        ? attributes['feature_details']! as Map<Object?, Object?>
        : const <Object?, Object?>{};
    final String language = _string(attributes['language']) ?? '';
    for (final Object? rawFile in rawFiles) {
      if (rawFile is! Map) continue;
      final int? fileId = _int(rawFile['file_id']);
      final String? fileName = _string(rawFile['file_name']);
      if (fileId == null || fileName == null || fileName.isEmpty) continue;
      records.add(
        OpenSubtitlesSearchRecord(
          fileId: fileId,
          fileName: fileName,
          language: language,
          releaseName: _string(attributes['release']),
          season: _int(feature['season_number']),
          episode: _int(feature['episode_number']),
          downloadCount: _int(attributes['download_count']) ?? 0,
          hearingImpaired: attributes['hearing_impaired'] == true,
          fps: _double(attributes['fps']),
        ),
      );
    }
  }
  return records;
}

class OpenSubtitlesClient implements VideoSubtitleProvider {
  OpenSubtitlesClient({
    required this.config,
    http.Client? client,
    this.requestTimeout = const Duration(seconds: 20),
    bool closesClient = true,
  })  : _client = client ?? createAppHttpIoClient(),
        _closesClient = client == null || closesClient;

  final OpenSubtitlesConfig config;
  final http.Client _client;
  final bool _closesClient;
  final Duration requestTimeout;
  String? _token;
  Uri? _downloadApiBase;

  int? get quotaRemaining => _quotaRemaining;
  int? _quotaRemaining;

  @override
  String get id => 'opensubtitles';

  @override
  int get priority => config.priority;

  Future<void> login() async {
    if (!config.hasLoginCredentials) {
      throw const ExternalProviderFailure(
        providerId: 'opensubtitles',
        operation: 'login',
        kind: ExternalProviderFailureKind.unauthorized,
        message: 'login credentials are not configured',
      );
    }
    final http.Response response = await _client
        .post(
          _apiUri(config.baseUrl, 'login'),
          headers: _headers(includeAuthorization: false, jsonBody: true),
          body: jsonEncode(<String, String>{
            'username': config.username!.trim(),
            'password': config.password!,
          }),
        )
        .timeout(requestTimeout);
    _requireSuccess('login', response);
    final Object? decoded = jsonDecode(response.body);
    if (decoded is! Map || _string(decoded['token']) == null) {
      throw const ExternalProviderFailure(
        providerId: 'opensubtitles',
        operation: 'login',
        kind: ExternalProviderFailureKind.invalidResponse,
        message: 'login response did not include a token',
      );
    }
    _token = _string(decoded['token']);
    final String? rawBase = _string(decoded['base_url']);
    if (rawBase != null) {
      final Uri? candidate = Uri.tryParse(rawBase);
      if (candidate == null || !_isTrustedDownloadApiBase(candidate)) {
        throw const ExternalProviderFailure(
          providerId: 'opensubtitles',
          operation: 'login',
          kind: ExternalProviderFailureKind.invalidResponse,
          message: 'login response included an untrusted API base URL',
        );
      }
      _downloadApiBase = candidate;
    }
  }

  @override
  Future<ProviderBatchResult<VideoSubtitleCandidate>> search(
    VideoSubtitleSearchRequest request,
  ) async {
    if (!config.enabled) {
      return ProviderBatchResult<VideoSubtitleCandidate>.failure(
        const ExternalProviderFailure(
          providerId: 'opensubtitles',
          operation: 'search',
          kind: ExternalProviderFailureKind.unavailable,
          message: 'provider is disabled',
        ),
      );
    }
    if (config.apiKey.trim().isEmpty) {
      return ProviderBatchResult<VideoSubtitleCandidate>.failure(
        const ExternalProviderFailure(
          providerId: 'opensubtitles',
          operation: 'search',
          kind: ExternalProviderFailureKind.unauthorized,
          message: 'OpenSubtitles API key is not configured',
        ),
      );
    }
    try {
      final List<Map<String, String>> queries = _searchQueries(request);
      if (queries.isEmpty) {
        throw const ExternalProviderFailure(
          providerId: 'opensubtitles',
          operation: 'search',
          kind: ExternalProviderFailureKind.unsupported,
          message: 'a title, external id, or file hash is required',
        );
      }
      if (config.hasLoginCredentials && _token == null) await login();
      for (final Map<String, String> query in queries) {
        final List<OpenSubtitlesSearchRecord> records =
            await _requestSearch(query);
        if (records.isEmpty) continue;
        return ProviderBatchResult<VideoSubtitleCandidate>.success(
          records.map(
            (OpenSubtitlesSearchRecord record) =>
                _OpenSubtitlesCandidate(record, priority),
          ),
        );
      }
      return ProviderBatchResult<VideoSubtitleCandidate>.success(
        const <VideoSubtitleCandidate>[],
      );
    } on Object catch (error) {
      return ProviderBatchResult<VideoSubtitleCandidate>.failure(
        ExternalProviderFailure.fromException(
          providerId: id,
          operation: 'search',
          error: error,
        ),
      );
    }
  }

  @override
  Future<VideoSubtitleDownload> download(
    VideoSubtitleCandidate candidate,
  ) async {
    if (!config.enabled || config.apiKey.trim().isEmpty) {
      throw const ExternalProviderFailure(
        providerId: 'opensubtitles',
        operation: 'download',
        kind: ExternalProviderFailureKind.unavailable,
        message: 'provider is not configured',
      );
    }
    if (candidate is! _OpenSubtitlesCandidate) {
      throw const ExternalProviderFailure(
        providerId: 'opensubtitles',
        operation: 'download',
        kind: ExternalProviderFailureKind.unsupported,
        message: 'candidate belongs to another provider',
      );
    }
    try {
      if (config.hasLoginCredentials && _token == null) await login();
      http.Response response =
          await _requestDownloadLink(candidate.record.fileId);
      if (response.statusCode == 401 && config.hasLoginCredentials) {
        _token = null;
        await login();
        response = await _requestDownloadLink(candidate.record.fileId);
      }
      _requireSuccess('download-link', response);
      final Object? decoded = jsonDecode(response.body);
      if (decoded is! Map) {
        throw const FormatException('download link response must be an object');
      }
      _quotaRemaining = _int(decoded['remaining']) ?? _quotaRemaining;
      final Uri? temporaryLink = Uri.tryParse(_string(decoded['link']) ?? '');
      if (temporaryLink == null || !_isSafeTemporaryLink(temporaryLink)) {
        throw const ExternalProviderFailure(
          providerId: 'opensubtitles',
          operation: 'download-link',
          kind: ExternalProviderFailureKind.invalidResponse,
          message: 'provider returned an invalid temporary download link',
        );
      }
      final Uint8List subtitleBytes =
          await _downloadTemporaryFile(temporaryLink);
      final String fileName =
          _string(decoded['file_name']) ?? candidate.record.fileName;
      return VideoSubtitleDownload(
        bytes: subtitleBytes,
        fileName: fileName,
        language: candidate.language,
      );
    } on Object catch (error) {
      throw ExternalProviderFailure.fromException(
        providerId: id,
        operation: 'download',
        error: error,
      );
    }
  }

  Future<Uint8List> _downloadTemporaryFile(Uri initialUri) async {
    Uri current = initialUri.replace(fragment: '');
    final Set<String> visited = <String>{};
    for (int redirectCount = 0; redirectCount <= 5; redirectCount++) {
      if (!_isSafeTemporaryLink(current) || !visited.add(current.toString())) {
        throw const ExternalProviderFailure(
          providerId: 'opensubtitles',
          operation: 'download-file',
          kind: ExternalProviderFailureKind.invalidResponse,
          message: 'subtitle download redirect was unsafe',
        );
      }
      // Temporary-link requests deliberately carry no OpenSubtitles API key,
      // bearer token, cookie, or referrer. A cross-origin redirect therefore
      // cannot inherit credentials from an authenticated API request.
      final http.Request request = http.Request('GET', current)
        ..followRedirects = false
        ..maxRedirects = 0;
      final http.StreamedResponse response =
          await _client.send(request).timeout(requestTimeout);
      if (_isRedirectStatus(response.statusCode)) {
        final String? rawLocation = response.headers['location'];
        await _cancelStream(response.stream);
        if (redirectCount == 5 || rawLocation == null) {
          throw const ExternalProviderFailure(
            providerId: 'opensubtitles',
            operation: 'download-file',
            kind: ExternalProviderFailureKind.invalidResponse,
            message: 'subtitle download redirect was invalid',
          );
        }
        final Uri? location = Uri.tryParse(rawLocation);
        final Uri? next = location == null
            ? null
            : current.resolveUri(location).replace(fragment: '');
        if (next == null || !_isSafeTemporaryLink(next)) {
          throw const ExternalProviderFailure(
            providerId: 'opensubtitles',
            operation: 'download-file',
            kind: ExternalProviderFailureKind.invalidResponse,
            message: 'subtitle download redirect was unsafe',
          );
        }
        current = next;
        continue;
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        await _cancelStream(response.stream);
        _requireSuccess(
          'download-file',
          http.Response('', response.statusCode, headers: response.headers),
        );
      }
      if ((response.contentLength ?? 0) > kMaximumSubtitleDownloadBytes) {
        await _cancelStream(response.stream);
        throw const ExternalProviderFailure(
          providerId: 'opensubtitles',
          operation: 'download-file',
          kind: ExternalProviderFailureKind.invalidResponse,
          message: 'subtitle download exceeded the size limit',
        );
      }
      return _readLimitedSubtitleBody(
        response.stream.timeout(requestTimeout),
      );
    }
    throw StateError('unreachable OpenSubtitles redirect loop');
  }

  Future<Uint8List> _readLimitedSubtitleBody(
    Stream<List<int>> stream,
  ) async {
    final BytesBuilder body = BytesBuilder(copy: false);
    int length = 0;
    await for (final List<int> chunk in stream) {
      length += chunk.length;
      if (length > kMaximumSubtitleDownloadBytes) {
        throw const ExternalProviderFailure(
          providerId: 'opensubtitles',
          operation: 'download-file',
          kind: ExternalProviderFailureKind.invalidResponse,
          message: 'subtitle download exceeded the size limit',
        );
      }
      body.add(chunk);
    }
    return body.takeBytes();
  }

  Future<void> _cancelStream(Stream<List<int>> stream) async {
    final StreamSubscription<List<int>> subscription = stream.listen(
      (_) {},
      onError: (_) {},
    );
    await subscription.cancel();
  }

  Future<http.Response> _requestDownloadLink(int fileId) => _client
      .post(
        _apiUri(_downloadApiBase ?? config.baseUrl, 'download'),
        headers: _headers(jsonBody: true),
        body: jsonEncode(<String, int>{'file_id': fileId}),
      )
      .timeout(requestTimeout);

  Future<List<OpenSubtitlesSearchRecord>> _requestSearch(
    Map<String, String> query,
  ) async {
    http.Response response = await _client
        .get(
          _apiUri(config.baseUrl, 'subtitles').replace(
            queryParameters: query,
          ),
          headers: _headers(),
        )
        .timeout(requestTimeout);
    if (response.statusCode == 401 && config.hasLoginCredentials) {
      _token = null;
      await login();
      response = await _client
          .get(
            _apiUri(config.baseUrl, 'subtitles').replace(
              queryParameters: query,
            ),
            headers: _headers(),
          )
          .timeout(requestTimeout);
    }
    // A failed precise lookup is not evidence that a broader query is safe.
    // In particular, authentication, rate-limit and quota failures must be
    // surfaced exactly and may never be hidden by a title fallback.
    _requireSuccess('search', response);
    return parseOpenSubtitlesSearchResponse(utf8.decode(response.bodyBytes));
  }

  List<Map<String, String>> _searchQueries(
    VideoSubtitleSearchRequest request,
  ) {
    final VideoMediaReference? media = request.media;
    final LocalVideoFingerprint? fingerprint = request.fingerprint;
    final String? imdb = media?.imdbId?.replaceFirst(
      RegExp(r'^tt', caseSensitive: false),
      '',
    );
    final Map<String, String> common = <String, String>{
      'page': '${request.page}',
      if (request.languages.isNotEmpty)
        'languages': request.languages.join(','),
    };
    final Map<String, String> episode = <String, String>{
      if (request.effectiveSeason != null)
        'season_number': '${request.effectiveSeason}',
      if (request.effectiveEpisode != null)
        'episode_number': '${request.effectiveEpisode}',
    };
    final List<Map<String, String>> queries = <Map<String, String>>[];

    // OpenSubtitles' file hash is only well-defined together with the byte
    // size. Never mix it with IDs or titles: an empty result advances to the
    // next identity tier in a separate request.
    if (fingerprint?.openSubtitlesMovieHash?.trim().isNotEmpty == true &&
        fingerprint!.fileSize > 0) {
      queries.add(<String, String>{
        ...common,
        'moviehash': fingerprint.openSubtitlesMovieHash!.trim(),
        'moviebytesize': '${fingerprint.fileSize}',
      });
    }
    if (imdb?.trim().isNotEmpty == true && media != null) {
      queries.add(<String, String>{
        ...common,
        if (media.mediaKind == VideoMetadataMediaKind.movie)
          'imdb_id': imdb!.trim()
        else
          'parent_imdb_id': imdb!.trim(),
        ...episode,
      });
    }
    if (media?.tmdbId != null) {
      queries.add(<String, String>{
        ...common,
        if (media!.mediaKind == VideoMetadataMediaKind.movie)
          'tmdb_id': '${media.tmdbId}'
        else
          'parent_tmdb_id': '${media.tmdbId}',
        ...episode,
      });
    }
    if (request.effectiveQuery.isNotEmpty) {
      queries.add(<String, String>{
        ...common,
        'query': request.effectiveQuery,
        if (media?.year != null && media!.year! > 0) 'year': '${media.year}',
        ...episode,
      });
    }
    return queries;
  }

  Map<String, String> _headers({
    bool includeAuthorization = true,
    bool jsonBody = false,
  }) =>
      <String, String>{
        'Api-Key': config.apiKey,
        'User-Agent': config.userAgent,
        'Accept': 'application/json',
        if (jsonBody) 'Content-Type': 'application/json',
        if (includeAuthorization && _token != null)
          'Authorization': 'Bearer $_token',
      };

  void _requireSuccess(String operation, http.Response response) {
    if (response.statusCode >= 200 && response.statusCode < 300) return;
    final int status = response.statusCode;
    final int? remaining = _responseRemaining(response);
    _quotaRemaining = remaining ?? _quotaRemaining;
    throw ExternalProviderFailure(
      providerId: 'opensubtitles',
      operation: operation,
      kind: switch (status) {
        401 => ExternalProviderFailureKind.unauthorized,
        403 => ExternalProviderFailureKind.forbidden,
        406 => ExternalProviderFailureKind.quotaExceeded,
        429 when remaining == 0 => ExternalProviderFailureKind.quotaExceeded,
        429 => ExternalProviderFailureKind.rateLimited,
        404 => ExternalProviderFailureKind.notFound,
        _ => ExternalProviderFailureKind.unavailable,
      },
      message: switch (status) {
        401 => 'OpenSubtitles authorization failed',
        406 => 'OpenSubtitles download quota was exhausted',
        429 => 'OpenSubtitles request limit was reached',
        _ => 'OpenSubtitles returned HTTP $status',
      },
      statusCode: status,
      quotaRemaining: remaining,
      retryAfter: _retryAfter(response.headers['retry-after']),
      retryable: status == 429 || status >= 500,
    );
  }

  bool _isTrustedDownloadApiBase(Uri candidate) {
    if (candidate.scheme != 'https' &&
        !(candidate.scheme == 'http' &&
            (config.allowInsecureHttp || _isLoopback(candidate.host)))) {
      return false;
    }
    if (candidate.host == config.baseUrl.host) return true;
    return candidate.host.toLowerCase().endsWith('.opensubtitles.com');
  }

  bool _isSafeTemporaryLink(Uri candidate) {
    if (candidate.userInfo.isNotEmpty) return false;
    if (candidate.scheme == 'https') return candidate.host.isNotEmpty;
    return candidate.scheme == 'http' &&
        candidate.host.isNotEmpty &&
        _isLoopback(candidate.host);
  }

  @override
  void close() {
    if (_closesClient) _client.close();
  }
}

class _OpenSubtitlesCandidate extends VideoSubtitleCandidate {
  _OpenSubtitlesCandidate(this.record, int providerPriority)
      : super(
          providerId: 'opensubtitles',
          remoteId: '${record.fileId}',
          fileName: record.fileName,
          language: record.language,
          providerPriority: providerPriority,
          releaseName: record.releaseName,
          season: record.season,
          episode: record.episode,
          downloadCount: record.downloadCount,
          hearingImpaired: record.hearingImpaired,
          fps: record.fps,
        );

  final OpenSubtitlesSearchRecord record;
}

Uri _apiUri(Uri base, String operation) {
  final String prefix = base.path.endsWith('/')
      ? base.path.substring(0, base.path.length - 1)
      : base.path;
  return base.replace(path: '$prefix/$operation', query: '');
}

String? _string(Object? value) => value is String ? value : null;

int? _int(Object? value) => value is int
    ? value
    : value is num
        ? value.toInt()
        : int.tryParse(value?.toString() ?? '');

double? _double(Object? value) =>
    value is num ? value.toDouble() : double.tryParse(value?.toString() ?? '');

int? _responseRemaining(http.Response response) {
  final int? header = int.tryParse(
    response.headers['ratelimit-remaining'] ??
        response.headers['x-ratelimit-remaining'] ??
        '',
  );
  if (header != null) return header;
  try {
    final Object? decoded = jsonDecode(response.body);
    return decoded is Map ? _int(decoded['remaining']) : null;
  } on FormatException {
    return null;
  }
}

Duration? _retryAfter(String? raw) {
  final int? seconds = int.tryParse(raw?.trim() ?? '');
  return seconds == null || seconds < 0 ? null : Duration(seconds: seconds);
}

bool _isLoopback(String host) {
  final String normalized = host.toLowerCase();
  if (normalized == 'localhost' || normalized == '::1') return true;
  final List<String> parts = normalized.split('.');
  return parts.length == 4 && parts.first == '127';
}

bool _isRedirectStatus(int statusCode) =>
    statusCode == 301 ||
    statusCode == 302 ||
    statusCode == 303 ||
    statusCode == 307 ||
    statusCode == 308;
