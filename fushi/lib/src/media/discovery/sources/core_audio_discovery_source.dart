library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'package:fushi/src/media/discovery/discovery_models.dart';
import 'package:fushi/src/media/discovery/media_discovery_source.dart';
import 'package:fushi/src/media/external_provider.dart';
import 'package:fushi/src/media/media_search_text.dart';
import 'package:fushi/src/media/torrent/torrent_metainfo.dart';
import 'package:fushi/src/utils/net/app_http.dart';

const int kMaximumCoreAudioCatalogBytes = 24 * 1024 * 1024;
const Duration kCoreAudioCatalogTimeout = Duration(seconds: 60);
const Duration kCoreAudioTorrentTimeout = Duration(seconds: 30);

/// CoreAudio 页面把 source id 映射成 `TMW Part x` 的当前公开契约。source id
/// 本身就是 Nyaa torrent id；未知的新数字 source 仍可直接解析，只是展示时退回
/// torrent id，避免因页面新增 Part 而完全不可用。
const Map<String, int> kCoreAudioTmwPartBySource = <String, int>{
  '1616763': 1,
  '1616764': 2,
  '1616765': 3,
  '1616766': 4,
  '2000110': 5,
  '2001461': 6,
  '2003063': 7,
  '2004606': 8,
  '2005562': 9,
  '2006488': 10,
  '2008190': 11,
  '2090741': 12,
  '2091197': 13,
};

typedef CoreAudioHttpClientFactory = Future<http.Client> Function();

class CoreAudioVolume {
  const CoreAudioVolume({
    required this.id,
    required this.title,
    required this.author,
    required this.series,
    required this.order,
    required this.myFileName,
    required this.originalFileName,
    required this.sourceTorrentId,
    required this.fileSizeKiB,
    required this.coverUrl,
    required this.releaseDate,
    required this.amazonId,
  });

  final String id;
  final String title;
  final String author;
  final String series;
  final String order;
  final String myFileName;
  final String originalFileName;
  final String sourceTorrentId;
  final int? fileSizeKiB;
  final String? coverUrl;
  final String? releaseDate;
  final String? amazonId;

  String get sourceLabel {
    final int? part = kCoreAudioTmwPartBySource[sourceTorrentId];
    if (part != null) return 'TMW Part $part';
    if (isTmwTorrent) return 'TMW ($sourceTorrentId)';
    return sourceTorrentId.isEmpty ? 'Source unavailable' : sourceTorrentId;
  }

  bool get isTmwTorrent => RegExp(r'^\d+$').hasMatch(sourceTorrentId);
}

class CoreAudioSeries {
  CoreAudioSeries({
    required this.key,
    required this.title,
    required this.author,
    required Iterable<CoreAudioVolume> volumes,
  }) : volumes = List<CoreAudioVolume>.unmodifiable(volumes);

  final String key;
  final String title;
  final String author;
  final List<CoreAudioVolume> volumes;
}

class CoreAudioCatalog {
  CoreAudioCatalog._(this.series);

  final List<CoreAudioSeries> series;

  factory CoreAudioCatalog.parse(Uint8List bytes) {
    if (bytes.isEmpty || bytes.length > kMaximumCoreAudioCatalogBytes) {
      throw const FormatException('CoreAudio catalog size is invalid');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes));
    } on Object catch (error) {
      throw FormatException('CoreAudio catalog is invalid JSON: $error');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('CoreAudio catalog root must be an object');
    }

    final Map<String, List<CoreAudioVolume>> grouped =
        <String, List<CoreAudioVolume>>{};
    for (final MapEntry<String, dynamic> entry in decoded.entries) {
      final Object? raw = entry.value;
      if (raw is! Map<String, dynamic>) continue;
      final String source = _string(raw['source']);
      final String title = _string(raw['title']);
      final String series = _string(raw['series']).isEmpty
          ? title
          : _string(raw['series']);
      if (entry.key.trim().isEmpty || title.isEmpty || series.isEmpty) continue;
      final String author = _string(raw['author']);
      final String key = '$author\u0000$series';
      grouped
          .putIfAbsent(key, () => <CoreAudioVolume>[])
          .add(
            CoreAudioVolume(
              id: entry.key.trim(),
              title: title,
              author: author,
              series: series,
              order: _string(raw['order']),
              myFileName: _string(raw['my_filename']),
              originalFileName: _string(raw['original_filename']),
              sourceTorrentId: source,
              fileSizeKiB: int.tryParse(_string(raw['filesize'])),
              coverUrl: _nullableString(raw['cover']),
              releaseDate: _nullableString(raw['release_date']),
              amazonId: _nullableString(raw['amazon_id']),
            ),
          );
    }

    final List<CoreAudioSeries> output =
        <CoreAudioSeries>[
          for (final MapEntry<String, List<CoreAudioVolume>> entry
              in grouped.entries)
            CoreAudioSeries(
              key: entry.key,
              title: entry.value.first.series,
              author: entry.value.first.author,
              volumes: entry.value
                ..sort((CoreAudioVolume a, CoreAudioVolume b) {
                  final int byOrder = _compareOrder(a.order, b.order);
                  return byOrder != 0 ? byOrder : a.title.compareTo(b.title);
                }),
            ),
        ]..sort((CoreAudioSeries a, CoreAudioSeries b) {
          final int byTitle = a.title.compareTo(b.title);
          return byTitle != 0 ? byTitle : a.author.compareTo(b.author);
        });
    return CoreAudioCatalog._(List<CoreAudioSeries>.unmodifiable(output));
  }

  CoreAudioSeries? seriesByKey(String key) {
    for (final CoreAudioSeries value in series) {
      if (value.key == key) return value;
    }
    return null;
  }

  CoreAudioVolume? volumeById(String id) {
    for (final CoreAudioSeries value in series) {
      for (final CoreAudioVolume volume in value.volumes) {
        if (volume.id == id) return volume;
      }
    }
    return null;
  }

  List<CoreAudioSeries> search(String query) =>
      filterByMediaSearch<CoreAudioSeries>(
        series,
        query,
        (CoreAudioSeries value) => <String>[
          value.title,
          value.author,
          for (final CoreAudioVolume volume in value.volumes) ...<String>[
            volume.title,
            volume.id,
            if (volume.amazonId != null) volume.amazonId!,
          ],
        ],
      );
}

class CoreAudioFileMatchException extends FormatException {
  const CoreAudioFileMatchException(super.message);
}

/// 用 CoreAudio 的两套真实文件名、Audible id、标题和 KiB 体积，唯一匹配 TMW
/// 合集中的目标文件。无法唯一确定时 fail closed，绝不退化成整包下载。
InspectedTorrentFile matchCoreAudioTorrentFile(
  CoreAudioVolume volume,
  InspectedTorrentMetainfo metainfo,
) {
  final List<({InspectedTorrentFile file, int score})> candidates =
      <({InspectedTorrentFile file, int score})>[];
  final String normalizedTitle = normalizeMediaSearchText(volume.title);
  for (final InspectedTorrentFile file in metainfo.files) {
    final String base = _baseName(file.path);
    if (!_isAudioFile(base)) continue;
    final String lower = base.toLowerCase();
    int score = 0;
    if (volume.myFileName.isNotEmpty &&
        lower == volume.myFileName.toLowerCase()) {
      score = 1000;
    } else if (volume.originalFileName.isNotEmpty &&
        lower == volume.originalFileName.toLowerCase()) {
      score = 980;
    } else if (lower.contains(volume.id.toLowerCase())) {
      score = 900;
    } else if (normalizedTitle.isNotEmpty &&
        normalizeMediaSearchText(_stem(base)).contains(normalizedTitle)) {
      score = 700;
    }
    if (volume.fileSizeKiB != null &&
        file.length ~/ 1024 == volume.fileSizeKiB) {
      score += 100;
    }
    if (score > 0) candidates.add((file: file, score: score));
  }
  if (candidates.isEmpty) {
    throw CoreAudioFileMatchException(
      'No torrent file matches CoreAudio volume ${volume.id}',
    );
  }
  candidates.sort((a, b) => b.score.compareTo(a.score));
  if (candidates.length > 1 && candidates[0].score == candidates[1].score) {
    throw CoreAudioFileMatchException(
      'Multiple torrent files match CoreAudio volume ${volume.id}',
    );
  }
  return candidates.first.file;
}

class CoreAudioDiscoverySource extends MediaDiscoverySource {
  CoreAudioDiscoverySource({
    http.Client? client,
    CoreAudioHttpClientFactory? httpClientFactory,
    Uri? catalogUri,
    Uri? nyaaBaseUri,
    this.priority = 5,
  }) : assert(client == null || httpClientFactory == null),
       _providedClient = client,
       _httpClientFactory =
           httpClientFactory ?? (() async => createAppHttpIoClient()),
       _ownsClient = client == null,
       catalogUri =
           catalogUri ?? Uri.parse('https://coreaudio.netlify.app/data.json'),
       nyaaBaseUri = nyaaBaseUri ?? Uri.parse('https://nyaa.si');

  final http.Client? _providedClient;
  final CoreAudioHttpClientFactory _httpClientFactory;
  final bool _ownsClient;
  final Uri catalogUri;
  final Uri nyaaBaseUri;

  Future<http.Client>? _clientFuture;
  Future<CoreAudioCatalog>? _catalogFuture;
  bool _closed = false;

  @override
  String get id => 'coreaudio';

  @override
  String get displayName => 'CoreAudio';

  @override
  final int priority;

  @override
  DiscoveryCapabilities get capabilities => DiscoveryCapabilities(
    kinds: const <DiscoveryMediaKind>{DiscoveryMediaKind.audiobook},
    supportsBrowse: true,
    supportsPaging: true,
  );

  Future<http.Client> _client() {
    if (_closed) throw StateError('CoreAudio source is closed');
    return _clientFuture ??= _providedClient == null
        ? _httpClientFactory()
        : Future<http.Client>.value(_providedClient);
  }

  Future<CoreAudioCatalog> _catalog() {
    if (_closed) throw StateError('CoreAudio source is closed');
    final Future<CoreAudioCatalog>? cached = _catalogFuture;
    if (cached != null) return cached;
    final Future<CoreAudioCatalog> loading = _loadCatalogWithReset();
    _catalogFuture = loading;
    return loading;
  }

  Future<CoreAudioCatalog> _loadCatalogWithReset() async {
    try {
      return await _loadCatalog();
    } on Object {
      _catalogFuture = null;
      rethrow;
    }
  }

  Future<CoreAudioCatalog> _loadCatalog() async {
    final http.Response response = await (await _client())
        .get(catalogUri)
        .timeout(kCoreAudioCatalogTimeout);
    if (response.statusCode != 200) {
      throw http.ClientException('HTTP ${response.statusCode}', catalogUri);
    }
    if (response.bodyBytes.length > kMaximumCoreAudioCatalogBytes) {
      throw const FormatException('CoreAudio catalog exceeds the size limit');
    }
    return CoreAudioCatalog.parse(response.bodyBytes);
  }

  @override
  Future<ProviderBatchResult<DiscoveryResultPage>> search(
    DiscoveryRequest request,
  ) async {
    final List<CoreAudioSeries> matches = (await _catalog()).search(
      request.query ?? '',
    );
    final int start = (request.page - 1) * request.pageSize;
    final int end = (start + request.pageSize).clamp(0, matches.length);
    final List<CoreAudioSeries> page = start >= matches.length
        ? const <CoreAudioSeries>[]
        : matches.sublist(start, end);
    return ProviderBatchResult<DiscoveryResultPage>.success(
      <DiscoveryResultPage>[
        DiscoveryResultPage(
          entries: <DiscoveryEntry>[
            for (final CoreAudioSeries value in page)
              DiscoveryFolder(
                sourceId: id,
                title: value.title,
                path: value.key,
                note: value.author.isEmpty ? null : value.author,
                itemCount: value.volumes.length,
              ),
          ],
          page: request.page,
          hasMore: end < matches.length,
        ),
      ],
    );
  }

  @override
  Future<ProviderBatchResult<DiscoveryResultPage>> browse(
    DiscoveryRequest request,
  ) async {
    final CoreAudioCatalog catalog = await _catalog();
    if (request.path == null || request.path!.isEmpty) {
      return ProviderBatchResult<DiscoveryResultPage>.success(
        <DiscoveryResultPage>[
          _seriesPage(catalog.series, request),
        ],
      );
    }
    final CoreAudioSeries? value = catalog.seriesByKey(request.path!);
    if (value == null) {
      return ProviderBatchResult<DiscoveryResultPage>.success(
        <DiscoveryResultPage>[
          DiscoveryResultPage(
            entries: const <DiscoveryEntry>[],
            page: request.page,
            hasMore: false,
          ),
        ],
      );
    }
    final int start = (request.page - 1) * request.pageSize;
    final int end = (start + request.pageSize).clamp(0, value.volumes.length);
    final List<CoreAudioVolume> volumes = start >= value.volumes.length
        ? const <CoreAudioVolume>[]
        : value.volumes.sublist(start, end);
    return ProviderBatchResult<DiscoveryResultPage>.success(
      <DiscoveryResultPage>[
        DiscoveryResultPage(
          entries: <DiscoveryEntry>[
            for (final CoreAudioVolume volume in volumes)
              DiscoveryResourceItem(
                sourceId: id,
                id: volume.id,
                title: volume.title,
                kind: DiscoveryMediaKind.audiobook,
                payloadKind: DiscoveryPayloadKind.torrent,
                sizeBytes: volume.fileSizeKiB == null
                    ? null
                    : volume.fileSizeKiB! * 1024,
                dateText: volume.releaseDate,
                coverUrl: volume.coverUrl,
                detailUrl: 'https://www.audible.co.jp/pd/${volume.id}',
                note: volume.sourceLabel,
                isDownloadable: volume.isTmwTorrent,
              ),
          ],
          page: request.page,
          hasMore: end < value.volumes.length,
        ),
      ],
    );
  }

  @override
  Future<DiscoveryPayload> resolvePayload(DiscoveryResourceItem item) async {
    final CoreAudioVolume? volume = (await _catalog()).volumeById(item.id);
    if (volume == null) {
      throw StateError('CoreAudio volume no longer exists: ${item.id}');
    }
    if (!volume.isTmwTorrent) {
      throw StateError('CoreAudio volume is not backed by a TMW torrent');
    }
    final Uri torrentUri = nyaaBaseUri.resolve(
      '/download/${volume.sourceTorrentId}.torrent',
    );
    final http.Response response = await (await _client())
        .get(torrentUri)
        .timeout(kCoreAudioTorrentTimeout);
    if (response.statusCode != 200) {
      throw http.ClientException('HTTP ${response.statusCode}', torrentUri);
    }
    final Uint8List bytes = response.bodyBytes;
    if (bytes.isEmpty || bytes.length > kMaximumTorrentMetainfoBytes) {
      throw const FormatException('Nyaa torrent response size is invalid');
    }
    final InspectedTorrentMetainfo metainfo = inspectTorrentMetainfo(bytes);
    final InspectedTorrentFile selected = matchCoreAudioTorrentFile(
      volume,
      metainfo,
    );
    return DiscoverySelectedTorrentPayload(
      metainfo: metainfo,
      selectedFileIndexes: <int>{selected.index},
      resourceTitle: volume.sourceLabel,
      // TMW 单卷通常只有 m4b，没有正文/字幕；完成下载即可，不能冒充已对齐入库。
      importAfterDownload: false,
    );
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    final Future<http.Client>? client = _clientFuture;
    if (_ownsClient && client != null) {
      client.then((http.Client value) => value.close());
    }
    _catalogFuture = null;
  }
}

DiscoveryResultPage _seriesPage(
  List<CoreAudioSeries> values,
  DiscoveryRequest request,
) {
  final int start = (request.page - 1) * request.pageSize;
  final int end = (start + request.pageSize).clamp(0, values.length);
  final List<CoreAudioSeries> page = start >= values.length
      ? const <CoreAudioSeries>[]
      : values.sublist(start, end);
  return DiscoveryResultPage(
    entries: <DiscoveryEntry>[
      for (final CoreAudioSeries value in page)
        DiscoveryFolder(
          sourceId: 'coreaudio',
          title: value.title,
          path: value.key,
          note: value.author.isEmpty ? null : value.author,
          itemCount: value.volumes.length,
        ),
    ],
    page: request.page,
    hasMore: end < values.length,
  );
}

String _string(Object? value) => value?.toString().trim() ?? '';

String? _nullableString(Object? value) {
  final String text = _string(value);
  return text.isEmpty ? null : text;
}

int _compareOrder(String a, String b) {
  final num? aNumber = num.tryParse(a);
  final num? bNumber = num.tryParse(b);
  if (aNumber != null && bNumber != null) return aNumber.compareTo(bNumber);
  return a.compareTo(b);
}

String _baseName(String path) {
  final String normalized = path.replaceAll('\\', '/');
  final int slash = normalized.lastIndexOf('/');
  return slash < 0 ? normalized : normalized.substring(slash + 1);
}

String _stem(String path) {
  final int dot = path.lastIndexOf('.');
  return dot <= 0 ? path : path.substring(0, dot);
}

bool _isAudioFile(String path) {
  final String lower = path.toLowerCase();
  return const <String>{
    '.m4b',
    '.m4a',
    '.mp3',
    '.aac',
    '.flac',
    '.ogg',
    '.opus',
    '.wav',
  }.any(lower.endsWith);
}
