import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi_engine/utils/net/app_http.dart';

typedef MangaDownloadSidecarFetcher =
    Future<String?> Function(
      OnlineMangaLibraryEntry entry,
      OnlineMangaChapter chapter,
    );

const int kMokuroSidecarMaximumBytes = 32 * 1024 * 1024;
const Duration kMokuroSidecarTimeout = Duration(seconds: 20);

/// Fetching is deliberately best-effort. The chapter images remain usable when
/// Mokuro is unavailable or returns an invalid document.
Future<String?> fetchMokuroSidecar(
  OnlineMangaLibraryEntry entry,
  OnlineMangaChapter chapter, {
  String? sourceName,
  String? sourceBaseUrl,
}) async {
  if (!isMokuroSource(
    entry,
    sourceName: sourceName,
    sourceBaseUrl: sourceBaseUrl,
  )) {
    return null;
  }
  final MokuroSidecarIdentity? identity = mokuroSidecarIdentity(entry, chapter);
  if (identity == null) {
    return null;
  }
  final Uri uri = mokuroSidecarUri(identity.seriesPath, identity.volumeName);
  final HttpClient client = createAppHttpClient();
  try {
    final HttpClientRequest request = await client
        .getUrl(uri)
        .timeout(kMokuroSidecarTimeout);
    request.headers
      ..set(HttpHeaders.refererHeader, 'https://mokuro.moe/catalog')
      ..set(HttpHeaders.acceptHeader, 'application/json');
    final HttpClientResponse response = await request.close().timeout(
      kMokuroSidecarTimeout,
    );
    if (response.statusCode < 200 || response.statusCode >= 300) return null;
    final BytesBuilder bytes = BytesBuilder(copy: false);
    int length = 0;
    await for (final List<int> chunk in response.timeout(
      kMokuroSidecarTimeout,
    )) {
      length += chunk.length;
      if (length > kMokuroSidecarMaximumBytes) return null;
      bytes.add(chunk);
    }
    final String body = utf8.decode(bytes.takeBytes(), allowMalformed: false);
    return looksLikeMokuroSidecarResponse(body) ? body : null;
  } on Object {
    return null;
  } finally {
    client.close(force: true);
  }
}

/// Stable identifiers for the sidecar endpoint. Mihon chapter keys are source
/// URLs, so the key must not be treated as a synthetic `series|volume` value.
/// Prefer explicit source metadata, then parse the source's own
/// `/mokuro-reader/<series>/<volume>.cbz` URL, and finally use the chapter name
/// only when a trusted series path is available.
class MokuroSidecarIdentity {
  const MokuroSidecarIdentity({
    required this.seriesPath,
    required this.volumeName,
  });

  final String seriesPath;
  final String volumeName;
}

MokuroSidecarIdentity? mokuroSidecarIdentity(
  OnlineMangaLibraryEntry entry,
  OnlineMangaChapter chapter,
) {
  final Map<String, Object?> series = entry.series.raw;
  final Map<String, Object?> chapterRaw = chapter.raw;
  final MokuroSidecarIdentity? fromChapterUrl =
      _identityFromMokuroReaderUrl(chapter.key) ??
      _identityFromMokuroReaderUrl(_string(chapterRaw['url']));
  final String? seriesPath = _firstNonEmpty(<String?>[
    _string(series['mokuro_series_path']),
    _string(series['seriesPath']),
    _string(series['series_path']),
    _string(series['mokuroSeriesPath']),
    fromChapterUrl?.seriesPath,
    _pathFromMokuroReaderUrl(_string(series['url'])),
  ]);
  if (seriesPath == null) return fromChapterUrl;
  final String? volumeName = _firstNonEmpty(<String?>[
    _string(chapterRaw['mokuro_volume_name']),
    _string(chapterRaw['volumeName']),
    _string(chapterRaw['volume_name']),
    _string(chapterRaw['mokuroVolumeName']),
    _string(chapterRaw['volume']),
    fromChapterUrl?.volumeName,
    _string(chapter.name),
  ]);
  if (volumeName == null) return null;
  return MokuroSidecarIdentity(seriesPath: seriesPath, volumeName: volumeName);
}

Uri mokuroSidecarUri(String seriesPath, String volumeName) {
  final String encodedSeries = seriesPath
      .split('/')
      .where((String s) => s.isNotEmpty)
      .map(Uri.encodeComponent)
      .join('/');
  final String encodedVolume = Uri.encodeComponent(volumeName);
  return Uri.parse(
    'https://mokuro.moe/mokuro-reader/$encodedSeries/$encodedVolume.mokuro',
  );
}

/// Require both the registered source identity and its host. This prevents a
/// random chapter containing `|` from causing an unsolicited Mokuro request.
bool isMokuroSource(
  OnlineMangaLibraryEntry entry, {
  String? sourceName,
  String? sourceBaseUrl,
}) {
  final Map<String, Object?> raw = entry.series.raw;
  final String name = <Object?>[
    sourceName,
    raw['source_name'],
    raw['sourceName'],
    raw['source'],
    raw['sourceLabel'],
  ].whereType<String>().join(' ').trim().toLowerCase();
  final String host =
      <Object?>[
            sourceBaseUrl,
            raw['source_base_url'],
            raw['sourceBaseUrl'],
            raw['baseUrl'],
            raw['url'],
          ]
          .whereType<String>()
          .map(_hostOf)
          .firstWhere((String value) => value.isNotEmpty, orElse: () => '');
  return name.contains('mokuro') &&
      (host == 'mokuro.moe' || host.endsWith('.mokuro.moe'));
}

String _hostOf(String value) => Uri.tryParse(value)?.host.toLowerCase() ?? '';

String? _string(Object? value) {
  if (value is! String) return null;
  final String trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

String? _firstNonEmpty(Iterable<String?> values) {
  for (final String? value in values) {
    if (value != null && value.isNotEmpty) return value;
  }
  return null;
}

MokuroSidecarIdentity? _identityFromMokuroReaderUrl(String? value) {
  final String? path = value == null ? null : _pathFromMokuroReaderUrl(value);
  if (path == null) return null;
  final Uri? uri = Uri.tryParse(value!);
  final List<String> segments = uri?.pathSegments ?? const <String>[];
  final int marker = segments.indexOf('mokuro-reader');
  if (marker < 0 || marker + 2 > segments.length) return null;
  final List<String> series = segments.sublist(marker + 1, segments.length - 1);
  final String last = segments.last;
  final String volume = last.replaceFirst(
    RegExp(r'\.(?:cbz|mokuro)$', caseSensitive: false),
    '',
  );
  if (series.isEmpty || volume.trim().isEmpty) return null;
  return MokuroSidecarIdentity(
    seriesPath: series.join('/'),
    volumeName: Uri.decodeComponent(volume),
  );
}

String? _pathFromMokuroReaderUrl(String? value) {
  if (value == null) return null;
  final Uri? uri = Uri.tryParse(value);
  if (uri == null) return null;
  final List<String> segments = uri.pathSegments;
  final int marker = segments.indexOf('mokuro-reader');
  if (marker < 0 || marker + 1 >= segments.length) return null;
  final int end = segments.length - 1;
  if (end <= marker + 1) return null;
  return segments.sublist(marker + 1, end).join('/');
}

bool looksLikeMokuroSidecarResponse(String body) {
  try {
    final Object? value = jsonDecode(body);
    return value is Map &&
        value['pages'] is List &&
        (value['pages'] as List).isNotEmpty;
  } on Object {
    return false;
  }
}
