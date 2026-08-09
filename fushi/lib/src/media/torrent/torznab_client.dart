import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

import 'package:fushi/src/media/external_provider.dart';
import 'package:fushi/src/media/torrent/magnet_utils.dart';
import 'package:fushi/src/media/torrent/nyaa_client.dart';
import 'package:fushi/src/media/torrent/torrent_backend.dart';
import 'package:fushi/src/media/torrent/torrent_metainfo.dart';
import 'package:fushi/src/media/torrent/video_resource_provider.dart';
import 'package:fushi/src/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_models.dart';

enum TorznabSearchMode { search, movie, tv }

class TorznabIndexerConfig {
  TorznabIndexerConfig({
    required this.id,
    required this.name,
    required this.endpoint,
    required this.apiKey,
    this.enabled = true,
    this.priority = 100,
    this.allowInsecureHttp = false,
    Iterable<int> categories = const <int>[],
  }) : categories = List<int>.unmodifiable(categories) {
    if (id.trim().isEmpty) throw ArgumentError.value(id, 'id');
    if (endpoint.scheme != 'http' && endpoint.scheme != 'https') {
      throw ArgumentError('Torznab endpoint must use HTTP or HTTPS');
    }
    if (endpoint.host.isEmpty ||
        endpoint.hasQuery ||
        endpoint.userInfo.isNotEmpty ||
        endpoint.hasFragment) {
      throw ArgumentError(
        'Torznab endpoint must have a host and no query, user info, or fragment',
      );
    }
    if (!isSafeExternalProviderEndpoint(
      endpoint,
      allowInsecureHttp: allowInsecureHttp,
    )) {
      throw ArgumentError(
        'Torznab endpoint must use HTTPS unless insecure HTTP is explicitly '
        'allowed or the host is loopback',
      );
    }
  }

  factory TorznabIndexerConfig.fromJson(Map<String, Object?> json) {
    final TorznabEndpointParts parts = splitTorznabEndpointCredentials(
      json['endpoint'] as String? ?? '',
      apiKey: json['apiKey'] as String?,
    );
    final Object? rawCategories = json['categories'];
    return TorznabIndexerConfig(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      endpoint: parts.endpoint,
      apiKey: parts.apiKey,
      enabled: json['enabled'] is bool ? json['enabled']! as bool : true,
      priority: json['priority'] is int ? json['priority']! as int : 100,
      allowInsecureHttp: json['allowInsecureHttp'] is bool
          ? json['allowInsecureHttp']! as bool
          : false,
      categories: rawCategories is List
          ? rawCategories.whereType<int>()
          : const <int>[],
    );
  }

  final String id;
  final String name;
  final Uri endpoint;
  final String apiKey;
  final bool enabled;

  /// Lower values are searched first and win duplicate info hashes.
  final int priority;
  final bool allowInsecureHttp;
  final List<int> categories;

  Map<String, Object?> toJson({bool includeSecrets = true}) =>
      <String, Object?>{
        'id': id,
        'name': name,
        'endpoint': endpoint.toString(),
        if (includeSecrets) 'apiKey': apiKey,
        'enabled': enabled,
        'priority': priority,
        'allowInsecureHttp': allowInsecureHttp,
        'categories': categories,
      };

  @override
  String toString() =>
      'TorznabIndexerConfig(id=$id, name=$name, endpointHost=${endpoint.host}, '
      'enabled=$enabled, priority=$priority, categories=$categories)';
}

class TorznabEndpointParts {
  const TorznabEndpointParts({required this.endpoint, required this.apiKey});

  final Uri endpoint;
  final String apiKey;
}

/// Splits legacy Jackett/Prowlarr URLs such as `.../api?apikey=secret` so the
/// credential can be stored in the secret field and never logged with a URI.
TorznabEndpointParts splitTorznabEndpointCredentials(
  String raw, {
  String? apiKey,
}) {
  final Uri uri = Uri.parse(raw.trim());
  const Set<String> credentialKeys = <String>{'apikey', 'api_key'};
  String extracted = apiKey?.trim() ?? '';
  final Map<String, String> remaining = <String, String>{};
  for (final MapEntry<String, String> entry in uri.queryParameters.entries) {
    if (credentialKeys.contains(entry.key.toLowerCase())) {
      if (extracted.isEmpty) extracted = entry.value;
    } else {
      remaining[entry.key] = entry.value;
    }
  }
  if (remaining.isNotEmpty) {
    throw const FormatException(
      'Torznab endpoint cannot contain non-credential query parameters',
    );
  }
  if (uri.userInfo.isNotEmpty || uri.hasFragment) {
    throw const FormatException(
      'Torznab endpoint cannot contain user info or a fragment',
    );
  }
  return TorznabEndpointParts(
    endpoint: Uri(
      scheme: uri.scheme,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
      path: uri.path,
    ),
    apiKey: extracted,
  );
}

List<TorznabIndexerConfig> decodeTorznabIndexerConfigs(Object? value) {
  if (value is! List) return const <TorznabIndexerConfig>[];
  final List<TorznabIndexerConfig> configs = <TorznabIndexerConfig>[];
  for (final Object? entry in value) {
    if (entry is! Map) continue;
    try {
      configs.add(
        TorznabIndexerConfig.fromJson(
          entry.map(
            (Object? key, Object? value) =>
                MapEntry<String, Object?>(key.toString(), value),
          ),
        ),
      );
    } on Object {
      // Preferences are user-editable and synced from older versions. Keep
      // valid instances usable when one row is malformed.
    }
  }
  return List<TorznabIndexerConfig>.unmodifiable(configs);
}

List<Map<String, Object?>> encodeTorznabIndexerConfigs(
  Iterable<TorznabIndexerConfig> configs, {
  bool includeSecrets = true,
}) =>
    configs
        .map(
          (TorznabIndexerConfig config) =>
              config.toJson(includeSecrets: includeSecrets),
        )
        .toList(growable: false);

bool isLoopbackProviderHost(String host) {
  final String normalized = host.toLowerCase();
  if (normalized == 'localhost' || normalized == '::1') return true;
  final List<String> parts = normalized.split('.');
  return parts.length == 4 && parts.first == '127';
}

/// HTTPS is always accepted. Plain HTTP requires loopback, or an explicit
/// opt-in suitable for a trusted LAN indexer configured by the user.
bool isSafeExternalProviderEndpoint(
  Uri endpoint, {
  bool allowInsecureHttp = false,
}) =>
    endpoint.scheme == 'https' ||
    (endpoint.scheme == 'http' &&
        (allowInsecureHttp || isLoopbackProviderHost(endpoint.host)));

class TorznabCapabilities {
  TorznabCapabilities({
    required Iterable<TorznabSearchMode> modes,
    Map<TorznabSearchMode, Set<String>> supportedParameters =
        const <TorznabSearchMode, Set<String>>{},
    Map<int, String> categories = const <int, String>{},
    this.maximumPageSize = 100,
    this.defaultPageSize = 100,
  })  : modes = Set<TorznabSearchMode>.unmodifiable(modes),
        supportedParameters = Map<TorznabSearchMode, Set<String>>.unmodifiable(
          <TorznabSearchMode, Set<String>>{
            for (final MapEntry<TorznabSearchMode, Set<String>> entry
                in supportedParameters.entries)
              entry.key: Set<String>.unmodifiable(entry.value),
          },
        ),
        categories = Map<int, String>.unmodifiable(categories) {
    if (maximumPageSize <= 0 || defaultPageSize <= 0) {
      throw ArgumentError('Torznab page sizes must be positive');
    }
  }

  final Set<TorznabSearchMode> modes;
  final Map<TorznabSearchMode, Set<String>> supportedParameters;
  final Map<int, String> categories;
  final int maximumPageSize;
  final int defaultPageSize;
}

class TorznabSearchItem {
  const TorznabSearchItem({
    required this.title,
    required this.remoteId,
    this.downloadUri,
    this.magnetUri,
    this.detailsUrl,
    this.infoHash,
    this.sizeBytes,
    this.seeders = 0,
    this.leechers = 0,
    this.completed = 0,
    this.publishedAt,
    this.category,
  });

  final String title;
  final String remoteId;
  final Uri? downloadUri;
  final String? magnetUri;
  final String? detailsUrl;
  final String? infoHash;
  final int? sizeBytes;
  final int seeders;
  final int leechers;
  final int completed;
  final DateTime? publishedAt;
  final String? category;
}

TorznabCapabilities parseTorznabCapabilities(String body) {
  try {
    return _parseTorznabCapabilities(body);
  } on XmlException {
    throw const FormatException('Torznab caps response is not valid XML');
  }
}

TorznabCapabilities _parseTorznabCapabilities(String body) {
  final XmlDocument document = XmlDocument.parse(body);
  final XmlElement root = document.rootElement;
  if (root.name.local != 'caps') {
    throw const FormatException('Torznab caps root must be <caps>');
  }
  final Set<TorznabSearchMode> modes = <TorznabSearchMode>{};
  final Map<TorznabSearchMode, Set<String>> parameters =
      <TorznabSearchMode, Set<String>>{};
  final XmlElement? searching = _firstDescendant(root, 'searching');
  if (searching != null) {
    for (final XmlElement element in searching.childElements) {
      final TorznabSearchMode? mode = switch (element.name.local) {
        'search' => TorznabSearchMode.search,
        'movie-search' => TorznabSearchMode.movie,
        'tv-search' => TorznabSearchMode.tv,
        _ => null,
      };
      if (mode == null || _attribute(element, 'available') == 'no') continue;
      modes.add(mode);
      parameters[mode] = (_attribute(element, 'supportedParams') ?? '')
          .split(',')
          .map((String value) => value.trim().toLowerCase())
          .where((String value) => value.isNotEmpty)
          .toSet();
    }
  }
  final Map<int, String> categories = <int, String>{};
  final XmlElement? categoryRoot = _firstDescendant(root, 'categories');
  if (categoryRoot != null) {
    for (final XmlElement element
        in categoryRoot.descendants.whereType<XmlElement>()) {
      if (element.name.local != 'category' && element.name.local != 'subcat') {
        continue;
      }
      final int? id = int.tryParse(_attribute(element, 'id') ?? '');
      if (id != null) categories[id] = _attribute(element, 'name') ?? '$id';
    }
  }
  final XmlElement? limits = _firstDescendant(root, 'limits');
  final int maximumPageSize = _positiveIntAttribute(limits, 'max') ?? 100;
  final int defaultPageSize =
      (_positiveIntAttribute(limits, 'default') ?? maximumPageSize)
          .clamp(1, maximumPageSize);
  if (modes.isEmpty) modes.add(TorznabSearchMode.search);
  return TorznabCapabilities(
    modes: modes,
    supportedParameters: parameters,
    categories: categories,
    maximumPageSize: maximumPageSize,
    defaultPageSize: defaultPageSize,
  );
}

List<TorznabSearchItem> parseTorznabSearchResponse(String body) {
  try {
    return _parseTorznabSearchResponse(body);
  } on XmlException {
    throw const FormatException('Torznab search response is not valid XML');
  }
}

List<TorznabSearchItem> _parseTorznabSearchResponse(String body) {
  final XmlDocument document = XmlDocument.parse(body);
  if (document.rootElement.name.local != 'rss') {
    throw const FormatException('Torznab response root must be <rss>');
  }
  final List<TorznabSearchItem> output = <TorznabSearchItem>[];
  for (final XmlElement item in document.findAllElements('item')) {
    final String title = _childText(item, 'title');
    if (title.isEmpty) continue;
    final Map<String, String> attributes = <String, String>{};
    for (final XmlElement element in item.childElements) {
      if (element.name.local != 'attr') continue;
      final String? name = _attribute(element, 'name')?.toLowerCase();
      final String? value = _attribute(element, 'value');
      if (name != null && value != null) attributes[name] = value;
    }
    final String? magnet = _firstNonEmpty(<String?>[
      attributes['magneturl'],
      attributes['magnet'],
      _childText(item, 'magneturl'),
    ]);
    final XmlElement? enclosure = item.childElements
        .where((XmlElement element) => element.name.local == 'enclosure')
        .firstOrNull;
    final String? rawDownload = _firstNonEmpty(<String?>[
      enclosure == null ? null : _attribute(enclosure, 'url'),
      _childText(item, 'link'),
    ]);
    final Uri? downloadUri =
        rawDownload == null ? null : Uri.tryParse(rawDownload.trim());
    final String? rawHash = _firstNonEmpty(<String?>[
      attributes['infohash'],
      attributes['torrenthash'],
      magnet == null ? null : parseMagnetInfoHash(magnet),
    ]);
    final String? infoHash = _normalizeHash(rawHash);
    final String guid = _childText(item, 'guid');
    final String opaqueSeed = guid.isNotEmpty
        ? guid
        : infoHash ?? rawDownload ?? '$title:${output.length}';
    final String remoteId =
        crypto.sha1.convert(utf8.encode(opaqueSeed)).toString();
    final String sizeText = _firstNonEmpty(<String?>[
          attributes['size'],
          _childText(item, 'size'),
          enclosure == null ? null : _attribute(enclosure, 'length'),
        ]) ??
        '';
    output.add(
      TorznabSearchItem(
        title: title,
        remoteId: remoteId,
        downloadUri: downloadUri,
        magnetUri: magnet,
        detailsUrl: _safePublicDetailsUrl(guid),
        infoHash: infoHash,
        sizeBytes: int.tryParse(sizeText),
        seeders: int.tryParse(attributes['seeders'] ?? '') ?? 0,
        leechers:
            int.tryParse(attributes['peers'] ?? attributes['leechers'] ?? '') ??
                0,
        completed: int.tryParse(attributes['grabs'] ?? '') ?? 0,
        publishedAt: parseNyaaPubDate(_childText(item, 'pubDate')),
        category: _firstNonEmpty(<String?>[
          attributes['category'],
          _childText(item, 'category'),
        ]),
      ),
    );
  }
  return output;
}

/// A multi-indexer Torznab/Newznab provider.
class TorznabClient implements VideoResourceProvider {
  TorznabClient({
    required Iterable<TorznabIndexerConfig> indexers,
    http.Client? client,
    this.requestTimeout = const Duration(seconds: 20),
    this.priorityOffset = 0,
    bool closesClient = true,
  })  : indexers = List<TorznabIndexerConfig>.unmodifiable(indexers),
        _client = client ?? http.Client(),
        _closesClient = client == null || closesClient;

  final List<TorznabIndexerConfig> indexers;
  final http.Client _client;
  final bool _closesClient;
  final Duration requestTimeout;
  final int priorityOffset;
  final Map<String, TorznabCapabilities> _capsCache =
      <String, TorznabCapabilities>{};

  @override
  int get priority {
    int? lowest;
    for (final TorznabIndexerConfig config in indexers) {
      if (!config.enabled) continue;
      if (lowest == null || config.priority < lowest) lowest = config.priority;
    }
    return priorityOffset + (lowest ?? 100);
  }

  @override
  String get id => 'torznab';

  Future<TorznabCapabilities> fetchCapabilities(String indexerId) async {
    final TorznabCapabilities? cached = _capsCache[indexerId];
    if (cached != null) return cached;
    final TorznabIndexerConfig config = indexers.firstWhere(
      (TorznabIndexerConfig value) => value.id == indexerId,
      orElse: () => throw StateError('unknown Torznab indexer'),
    );
    final Uri uri = _buildUri(config, <String, String>{'t': 'caps'});
    final http.Response response =
        await _client.get(uri).timeout(requestTimeout);
    _requireSuccess(config.id, 'capabilities', response);
    final TorznabCapabilities capabilities =
        parseTorznabCapabilities(utf8.decode(response.bodyBytes));
    _capsCache[config.id] = capabilities;
    return capabilities;
  }

  @override
  Future<ProviderBatchResult<VideoResourceCandidate>> search(
    VideoResourceSearchRequest request,
  ) async {
    if (request.effectiveQuery.isEmpty) {
      return ProviderBatchResult<VideoResourceCandidate>.failure(
        const ExternalProviderFailure(
          providerId: 'torznab',
          operation: 'search',
          kind: ExternalProviderFailureKind.unsupported,
          message: 'a search query is required',
        ),
      );
    }
    final List<TorznabIndexerConfig> enabled =
        indexers.where((TorznabIndexerConfig value) => value.enabled).toList()
          ..sort(
            (TorznabIndexerConfig a, TorznabIndexerConfig b) =>
                a.priority.compareTo(b.priority),
          );
    final List<ProviderBatchResult<VideoResourceCandidate>> batches =
        await Future.wait(
      enabled.map(
        (TorznabIndexerConfig config) => _searchIndexer(config, request),
      ),
    );
    final ProviderBatchResult<VideoResourceCandidate> merged =
        ProviderBatchResult.merge<VideoResourceCandidate>(batches);
    final int globalOffset = (request.page - 1) * request.limit;
    return ProviderBatchResult<VideoResourceCandidate>(
      items: deduplicateVideoResources(merged.items)
          .skip(globalOffset)
          .take(request.limit),
      failures: merged.failures,
      successfulProviderCount: merged.successfulProviderCount,
    );
  }

  Future<ProviderBatchResult<VideoResourceCandidate>> _searchIndexer(
    TorznabIndexerConfig config,
    VideoResourceSearchRequest request,
  ) async {
    try {
      final TorznabCapabilities capabilities =
          await fetchCapabilities(config.id);
      final TorznabSearchMode preferred = request.media == null
          ? TorznabSearchMode.search
          : request.media!.mediaKind == VideoMetadataMediaKind.movie
              ? TorznabSearchMode.movie
              : TorznabSearchMode.tv;
      final List<TorznabSearchMode> modes = <TorznabSearchMode>[
        if (capabilities.modes.contains(preferred)) preferred,
        if (preferred != TorznabSearchMode.search &&
            capabilities.modes.contains(TorznabSearchMode.search))
          TorznabSearchMode.search,
      ];
      if (modes.isEmpty) modes.add(TorznabSearchMode.search);

      List<TorznabSearchItem> items = const <TorznabSearchItem>[];
      ExternalProviderFailure? windowFailure;
      for (final TorznabSearchMode mode in modes) {
        final _TorznabSearchWindow window = await _requestSearchWindow(
          config,
          capabilities,
          mode,
          request,
        );
        items = window.items;
        windowFailure = window.failure;
        if (items.isNotEmpty || windowFailure != null) break;
      }
      final Iterable<VideoResourceCandidate> candidates = items.map(
        (TorznabSearchItem item) => _TorznabResourceCandidate(
          config: config,
          item: item,
          providerPriority: priorityOffset + config.priority,
        ),
      );
      if (windowFailure != null) {
        return ProviderBatchResult<VideoResourceCandidate>(
          items: candidates,
          failures: <ExternalProviderFailure>[windowFailure],
          successfulProviderCount: items.isEmpty ? 0 : 1,
        );
      }
      return ProviderBatchResult<VideoResourceCandidate>.success(
        candidates,
      );
    } on Object catch (error) {
      return ProviderBatchResult<VideoResourceCandidate>.failure(
        ExternalProviderFailure.fromException(
          providerId: 'torznab:${config.id}',
          operation: 'search',
          error: error,
        ),
      );
    }
  }

  Future<_TorznabSearchWindow> _requestSearchWindow(
    TorznabIndexerConfig config,
    TorznabCapabilities capabilities,
    TorznabSearchMode mode,
    VideoResourceSearchRequest request,
  ) async {
    final int targetLength = request.page * request.limit;
    final int pageSize = request.limit.clamp(
      1,
      capabilities.maximumPageSize,
    );
    final List<TorznabSearchItem> items = <TorznabSearchItem>[];
    final Set<String> seen = <String>{};
    for (int offset = 0; items.length < targetLength; offset += pageSize) {
      try {
        final List<TorznabSearchItem> page = await _requestSearchPage(
          config,
          capabilities,
          mode,
          request,
          offset: offset,
          limit: pageSize,
        );
        if (page.isEmpty) break;
        int added = 0;
        for (final TorznabSearchItem item in page) {
          if (seen.add(item.remoteId)) {
            items.add(item);
            added++;
          }
        }
        if (added == 0 || page.length < pageSize) break;
      } on Object catch (error) {
        return _TorznabSearchWindow(
          items: items,
          failure: ExternalProviderFailure.fromException(
            providerId: 'torznab:${config.id}',
            operation: 'search',
            error: error,
          ),
        );
      }
    }
    return _TorznabSearchWindow(items: items);
  }

  Future<List<TorznabSearchItem>> _requestSearchPage(
    TorznabIndexerConfig config,
    TorznabCapabilities capabilities,
    TorznabSearchMode mode,
    VideoResourceSearchRequest request, {
    required int offset,
    required int limit,
  }) async {
    final Set<String> supported =
        capabilities.supportedParameters[mode] ?? const <String>{};
    bool supports(String parameter) =>
        supported.isEmpty || supported.contains(parameter);
    final VideoMediaReference? media = request.media;
    final Map<String, String> parameters = <String, String>{
      't': switch (mode) {
        TorznabSearchMode.search => 'search',
        TorznabSearchMode.movie => 'movie',
        TorznabSearchMode.tv => 'tvsearch',
      },
      'q': request.effectiveQuery,
      'extended': '1',
      'offset': '$offset',
      'limit': '$limit',
      if (config.categories.isNotEmpty) 'cat': config.categories.join(','),
      if (request.effectiveSeason != null && supports('season'))
        'season': '${request.effectiveSeason}',
      if (request.effectiveEpisode != null && supports('ep'))
        'ep': '${request.effectiveEpisode}',
      if (media?.imdbId != null && supports('imdbid')) 'imdbid': media!.imdbId!,
      if (media?.tmdbId != null && supports('tmdbid'))
        'tmdbid': '${media!.tmdbId}',
      if (media?.tvdbId != null && supports('tvdbid'))
        'tvdbid': '${media!.tvdbId}',
    };
    final http.Response response = await _client
        .get(_buildUri(config, parameters))
        .timeout(requestTimeout);
    _requireSuccess(config.id, 'search', response);
    return parseTorznabSearchResponse(utf8.decode(response.bodyBytes));
  }

  @override
  Future<TorrentAddPayload> resolve(VideoResourceCandidate candidate) async {
    if (candidate is! _TorznabResourceCandidate) {
      throw const ExternalProviderFailure(
        providerId: 'torznab',
        operation: 'resolve',
        kind: ExternalProviderFailureKind.unsupported,
        message: 'candidate belongs to another provider',
      );
    }
    final String? magnet = candidate.item.magnetUri;
    if (magnet != null && magnet.toLowerCase().startsWith('magnet:')) {
      final String? parsedHash = parseMagnetInfoHash(magnet);
      if (parsedHash != null &&
          candidate.infoHash != null &&
          parsedHash != candidate.infoHash) {
        throw ExternalProviderFailure(
          providerId: 'torznab:${candidate.config.id}',
          operation: 'resolve',
          kind: ExternalProviderFailureKind.integrity,
          message: 'magnet info hash does not match search result',
        );
      }
      return TorrentMagnetPayload(
        magnetUri: magnet,
        torrentId: parsedHash ?? _backendId(candidate.infoHash),
      );
    }
    final Uri? downloadUri = candidate.item.downloadUri;
    if (downloadUri == null ||
        downloadUri.userInfo.isNotEmpty ||
        !isSafeExternalProviderEndpoint(
          downloadUri,
          allowInsecureHttp: candidate.config.allowInsecureHttp,
        )) {
      throw ExternalProviderFailure(
        providerId: 'torznab:${candidate.config.id}',
        operation: 'resolve',
        kind: ExternalProviderFailureKind.invalidResponse,
        message: 'search result has no supported download locator',
      );
    }
    try {
      final Uint8List responseBytes = await _fetchTorrentBytes(
        candidate.config,
        downloadUri,
      );
      final String body =
          utf8.decode(responseBytes, allowMalformed: true).trim();
      if (body.toLowerCase().startsWith('magnet:')) {
        final String? hash = parseMagnetInfoHash(body);
        if (hash != null &&
            candidate.infoHash != null &&
            hash != candidate.infoHash) {
          throw TorrentMetainfoException(
            TorrentMetainfoErrorCode.hashMismatch,
            'downloaded magnet hash mismatch',
          );
        }
        return TorrentMagnetPayload(
          magnetUri: body,
          torrentId: hash ?? _backendId(candidate.infoHash),
        );
      }
      final InspectedTorrentMetainfo inspected = inspectTorrentMetainfo(
        responseBytes,
        expectedInfoHash: candidate.infoHash,
      );
      return inspected.toPayload(fileName: '${inspected.torrentId}.torrent');
    } on TorrentMetainfoException catch (error) {
      throw ExternalProviderFailure(
        providerId: 'torznab:${candidate.config.id}',
        operation: 'resolve',
        kind: error.code == TorrentMetainfoErrorCode.hashMismatch
            ? ExternalProviderFailureKind.integrity
            : ExternalProviderFailureKind.invalidResponse,
        message: error.code == TorrentMetainfoErrorCode.hashMismatch
            ? 'downloaded metainfo hash does not match search result'
            : 'downloaded file is not valid torrent metainfo',
      );
    } on Object catch (error) {
      throw ExternalProviderFailure.fromException(
        providerId: 'torznab:${candidate.config.id}',
        operation: 'resolve',
        error: error,
      );
    }
  }

  Future<Uint8List> _fetchTorrentBytes(
    TorznabIndexerConfig config,
    Uri initialUri,
  ) async {
    Uri current = initialUri;
    for (int redirectCount = 0; redirectCount <= 5; redirectCount++) {
      final http.Request request = http.Request('GET', current)
        ..followRedirects = false
        ..maxRedirects = 0;
      final http.StreamedResponse response =
          await _client.send(request).timeout(requestTimeout);
      if (_isRedirectStatus(response.statusCode)) {
        final String? rawLocation = response.headers['location'];
        await _cancelStream(response.stream);
        if (redirectCount == 5 || rawLocation == null) {
          throw ExternalProviderFailure(
            providerId: 'torznab:${config.id}',
            operation: 'resolve',
            kind: ExternalProviderFailureKind.invalidResponse,
            message: 'torrent download redirect was invalid',
          );
        }
        final Uri? location = Uri.tryParse(rawLocation);
        final Uri? next =
            location == null ? null : current.resolveUri(location);
        if (next == null ||
            next.host.isEmpty ||
            next.userInfo.isNotEmpty ||
            !isSafeExternalProviderEndpoint(
              next,
              allowInsecureHttp: config.allowInsecureHttp,
            )) {
          throw ExternalProviderFailure(
            providerId: 'torznab:${config.id}',
            operation: 'resolve',
            kind: ExternalProviderFailureKind.invalidResponse,
            message: 'torrent download redirect was unsafe',
          );
        }
        current = next.replace(fragment: '');
        continue;
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        await _cancelStream(response.stream);
        _requireStatus(
          config.id,
          'resolve',
          response.statusCode,
          response.headers,
        );
      }
      if ((response.contentLength ?? 0) > kMaximumTorrentMetainfoBytes) {
        await _cancelStream(response.stream);
        throw TorrentMetainfoException(
          TorrentMetainfoErrorCode.tooLarge,
          'download exceeded size limit',
        );
      }
      return _readLimitedTorrentBody(response.stream.timeout(requestTimeout));
    }
    throw StateError('unreachable Torznab redirect loop');
  }

  Future<Uint8List> _readLimitedTorrentBody(
    Stream<List<int>> stream,
  ) async {
    final BytesBuilder body = BytesBuilder(copy: false);
    int length = 0;
    await for (final List<int> chunk in stream) {
      length += chunk.length;
      if (length > kMaximumTorrentMetainfoBytes) {
        throw TorrentMetainfoException(
          TorrentMetainfoErrorCode.tooLarge,
          'download exceeded size limit',
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

  Uri _buildUri(
    TorznabIndexerConfig config,
    Map<String, String> parameters,
  ) =>
      config.endpoint.replace(
        queryParameters: <String, String>{
          ...parameters,
          if (config.apiKey.isNotEmpty) 'apikey': config.apiKey,
        },
      );

  void _requireSuccess(
    String indexerId,
    String operation,
    http.Response response,
  ) =>
      _requireStatus(
        indexerId,
        operation,
        response.statusCode,
        response.headers,
      );

  void _requireStatus(
    String indexerId,
    String operation,
    int status,
    Map<String, String> headers,
  ) {
    if (status >= 200 && status < 300) return;
    throw ExternalProviderFailure(
      providerId: 'torznab:$indexerId',
      operation: operation,
      kind: switch (status) {
        401 => ExternalProviderFailureKind.unauthorized,
        403 => ExternalProviderFailureKind.forbidden,
        404 => ExternalProviderFailureKind.notFound,
        429 => ExternalProviderFailureKind.rateLimited,
        _ => ExternalProviderFailureKind.unavailable,
      },
      message: 'provider returned HTTP $status',
      statusCode: status,
      retryAfter: _retryAfter(headers['retry-after']),
      retryable: status == 429 || status >= 500,
    );
  }

  @override
  void close() {
    if (_closesClient) _client.close();
  }
}

class _TorznabResourceCandidate extends VideoResourceCandidate {
  _TorznabResourceCandidate({
    required this.config,
    required this.item,
    required int providerPriority,
  }) : super(
          providerId: 'torznab',
          providerInstanceId: config.id,
          remoteId: item.remoteId,
          title: item.title,
          providerPriority: providerPriority,
          infoHash: item.infoHash,
          sizeBytes: item.sizeBytes,
          seeders: item.seeders,
          leechers: item.leechers,
          completed: item.completed,
          publishedAt: item.publishedAt,
          category: item.category,
          detailsUrl: item.detailsUrl,
        );

  final TorznabIndexerConfig config;
  final TorznabSearchItem item;
}

class _TorznabSearchWindow {
  _TorznabSearchWindow({
    required Iterable<TorznabSearchItem> items,
    this.failure,
  }) : items = List<TorznabSearchItem>.unmodifiable(items);

  final List<TorznabSearchItem> items;
  final ExternalProviderFailure? failure;
}

XmlElement? _firstDescendant(XmlElement root, String localName) {
  for (final XmlElement element in root.descendants.whereType<XmlElement>()) {
    if (element.name.local == localName) return element;
  }
  return null;
}

String? _attribute(XmlElement element, String localName) {
  for (final XmlAttribute attribute in element.attributes) {
    if (attribute.name.local == localName) return attribute.value.trim();
  }
  return null;
}

int? _positiveIntAttribute(XmlElement? element, String localName) {
  if (element == null) return null;
  final int? value = int.tryParse(_attribute(element, localName) ?? '');
  return value != null && value > 0 ? value : null;
}

String _childText(XmlElement element, String localName) {
  for (final XmlElement child in element.childElements) {
    if (child.name.local == localName) return child.innerText.trim();
  }
  return '';
}

String? _firstNonEmpty(Iterable<String?> values) {
  for (final String? value in values) {
    if (value != null && value.trim().isNotEmpty) return value.trim();
  }
  return null;
}

String? _normalizeHash(String? raw) {
  if (raw == null) return null;
  final String value = raw.trim().toLowerCase();
  if (RegExp(r'^[0-9a-f]{40}$').hasMatch(value) ||
      RegExp(r'^[0-9a-f]{64}$').hasMatch(value)) {
    return value;
  }
  return null;
}

bool _isRedirectStatus(int statusCode) =>
    statusCode == 301 ||
    statusCode == 302 ||
    statusCode == 303 ||
    statusCode == 307 ||
    statusCode == 308;

String? _backendId(String? hash) {
  if (hash == null) return null;
  return hash.length == 64 ? hash.substring(0, 40) : hash;
}

String? _safePublicDetailsUrl(String raw) {
  final Uri? uri = Uri.tryParse(raw);
  if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
    return null;
  }
  const Set<String> secretKeys = <String>{
    'apikey',
    'api_key',
    'jackett_apikey',
    'token',
    'key',
    'passkey',
    'auth',
    'authkey',
    'rsskey',
    'signature',
    'sig',
  };
  if (uri.queryParameters.keys
      .any((String key) => secretKeys.contains(key.toLowerCase()))) {
    return null;
  }
  return uri.toString();
}

Duration? _retryAfter(String? raw) {
  final int? seconds = int.tryParse(raw?.trim() ?? '');
  return seconds == null || seconds < 0 ? null : Duration(seconds: seconds);
}
