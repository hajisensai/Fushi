import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

const int kMaximumAidokuRepositoryBytes = 8 * 1024 * 1024;
const int kMaximumAidokuRepositorySources = 5000;
const int kMaximumAidokuDownloadBytes = 128 * 1024 * 1024;

class AidokuRepositoryException implements Exception {
  const AidokuRepositoryException(this.code, this.message, {this.cause});

  final String code;
  final String message;
  final Object? cause;

  @override
  String toString() => 'AidokuRepositoryException($code): $message';
}

class AidokuRepositorySource {
  const AidokuRepositorySource({
    required this.id,
    required this.name,
    required this.version,
    required this.languages,
    required this.downloadUri,
    this.iconUri,
    this.baseUrl,
    this.minimumAppVersion,
    this.contentRating,
  });

  final String id;
  final String name;
  final int version;
  final List<String> languages;
  final Uri downloadUri;
  final Uri? iconUri;
  final String? baseUrl;
  final String? minimumAppVersion;
  final int? contentRating;
}

class AidokuRepositoryIndex {
  const AidokuRepositoryIndex({
    required this.name,
    required this.indexUri,
    required this.sources,
  });

  final String name;
  final Uri indexUri;
  final List<AidokuRepositorySource> sources;
}

class AidokuRepositoryClient {
  AidokuRepositoryClient({
    http.Client? client,
    this.timeout = const Duration(seconds: 30),
  }) : _client = client ?? http.Client();

  final http.Client _client;
  final Duration timeout;

  static Uri normalizeRepositoryUri(String value) {
    final String input = value.trim();
    if (input.isEmpty || input.length > 2048) {
      throw const AidokuRepositoryException(
        'INVALID_URL',
        'Enter a valid Aidoku repository URL',
      );
    }
    final Uri? parsed = Uri.tryParse(
      input.contains('://') ? input : 'https://$input',
    );
    if (parsed == null || !parsed.hasAuthority || parsed.userInfo.isNotEmpty) {
      throw const AidokuRepositoryException(
        'INVALID_URL',
        'Enter a valid Aidoku repository URL',
      );
    }
    _requireHttps(parsed);

    final List<String> segments = parsed.pathSegments
        .where((String segment) => segment.isNotEmpty)
        .toList(growable: false);
    if (parsed.host.toLowerCase() == 'github.com' && segments.length >= 2) {
      return Uri.https(
        '${segments[0].toLowerCase()}.github.io',
        '/${segments[1]}/index.min.json',
      );
    }
    if (parsed.path.toLowerCase().endsWith('.json')) {
      return parsed.replace(fragment: null);
    }
    final String directoryPath =
        parsed.path.endsWith('/') ? parsed.path : '${parsed.path}/';
    return parsed
        .replace(path: directoryPath, query: null, fragment: null)
        .resolve('index.min.json');
  }

  Future<AidokuRepositoryIndex> fetch(String repositoryUrl) async {
    final Uri requestedUri = normalizeRepositoryUri(repositoryUrl);
    final ({http.StreamedResponse response, Uri uri}) opened =
        await _open(requestedUri);
    final Uint8List body = await _readBounded(
      opened.response,
      kMaximumAidokuRepositoryBytes,
      'REPOSITORY_TOO_LARGE',
    );
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(body));
    } on Object catch (error) {
      throw AidokuRepositoryException(
        'INVALID_INDEX',
        'The repository did not return a valid Aidoku JSON index',
        cause: error,
      );
    }
    return _parseIndex(decoded, opened.uri);
  }

  Future<File> download(
    AidokuRepositorySource source,
    File destination,
  ) async {
    _requireHttps(source.downloadUri);
    final ({http.StreamedResponse response, Uri uri}) opened =
        await _open(source.downloadUri);
    final int? contentLength = opened.response.contentLength;
    if (contentLength != null &&
        (contentLength <= 0 || contentLength > kMaximumAidokuDownloadBytes)) {
      throw const AidokuRepositoryException(
        'PACKAGE_SIZE',
        'Aidoku package is empty or exceeds the 128 MiB limit',
      );
    }
    await destination.parent.create(recursive: true);
    final IOSink sink = destination.openWrite();
    int length = 0;
    try {
      await opened.response.stream.timeout(timeout).forEach((List<int> chunk) {
        length += chunk.length;
        if (length > kMaximumAidokuDownloadBytes) {
          throw const AidokuRepositoryException(
            'PACKAGE_SIZE',
            'Aidoku package is empty or exceeds the 128 MiB limit',
          );
        }
        sink.add(chunk);
      });
      await sink.flush();
      await sink.close();
      if (length == 0) {
        throw const AidokuRepositoryException(
          'PACKAGE_SIZE',
          'Aidoku package is empty or exceeds the 128 MiB limit',
        );
      }
      return destination;
    } on Object {
      await sink.close();
      if (await destination.exists()) await destination.delete();
      rethrow;
    }
  }

  void close() => _client.close();

  Future<({http.StreamedResponse response, Uri uri})> _open(
    Uri initialUri,
  ) async {
    Uri current = initialUri;
    for (int redirects = 0; redirects <= 5; redirects++) {
      _requireHttps(current);
      final http.Request request = http.Request('GET', current)
        ..followRedirects = false
        ..headers['accept'] = 'application/json, application/octet-stream';
      final http.StreamedResponse response;
      try {
        response = await _client.send(request).timeout(timeout);
      } on Object catch (error) {
        throw AidokuRepositoryException(
          'NETWORK',
          'Unable to load the Aidoku repository',
          cause: error,
        );
      }
      if (_isRedirect(response.statusCode)) {
        final String? location = response.headers['location'];
        await response.stream.drain<void>().timeout(timeout);
        if (location == null || redirects == 5) {
          throw const AidokuRepositoryException(
            'REDIRECT',
            'The Aidoku repository returned an invalid redirect',
          );
        }
        current = current.resolve(location);
        continue;
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        await response.stream.drain<void>().timeout(timeout);
        throw AidokuRepositoryException(
          'HTTP_${response.statusCode}',
          'The Aidoku repository returned HTTP ${response.statusCode}',
        );
      }
      return (response: response, uri: current);
    }
    throw const AidokuRepositoryException(
      'REDIRECT',
      'The Aidoku repository redirected too many times',
    );
  }

  Future<Uint8List> _readBounded(
    http.StreamedResponse response,
    int maximumBytes,
    String errorCode,
  ) async {
    final int? contentLength = response.contentLength;
    if (contentLength != null && contentLength > maximumBytes) {
      throw AidokuRepositoryException(
        errorCode,
        'The Aidoku repository index exceeds the 8 MiB limit',
      );
    }
    final BytesBuilder bytes = BytesBuilder(copy: false);
    int length = 0;
    await response.stream.timeout(timeout).forEach((List<int> chunk) {
      length += chunk.length;
      if (length > maximumBytes) {
        throw AidokuRepositoryException(
          errorCode,
          'The Aidoku repository index exceeds the 8 MiB limit',
        );
      }
      bytes.add(chunk);
    });
    return bytes.takeBytes();
  }

  static AidokuRepositoryIndex _parseIndex(Object? decoded, Uri indexUri) {
    final String repositoryName;
    final List<Object?> rawSources;
    if (decoded is Map<Object?, Object?>) {
      repositoryName = decoded['name']?.toString().trim() ?? '';
      rawSources = decoded['sources'] is List<Object?>
          ? decoded['sources']! as List<Object?>
          : const <Object?>[];
    } else if (decoded is List<Object?>) {
      repositoryName = indexUri.host;
      rawSources = decoded;
    } else {
      throw const AidokuRepositoryException(
        'INVALID_INDEX',
        'The repository index has an unsupported structure',
      );
    }
    if (rawSources.isEmpty ||
        rawSources.length > kMaximumAidokuRepositorySources) {
      throw const AidokuRepositoryException(
        'INVALID_INDEX',
        'The repository index is empty or contains too many sources',
      );
    }
    final Map<String, AidokuRepositorySource> sources =
        <String, AidokuRepositorySource>{};
    for (final Object? rawSource in rawSources) {
      if (rawSource is! Map<Object?, Object?>) continue;
      final Map<String, Object?> json = rawSource.cast<String, Object?>();
      final String id = json['id']?.toString().trim() ?? '';
      final String name = json['name']?.toString().trim() ?? '';
      final Object? versionValue = json['version'];
      final String download =
          (json['downloadURL'] ?? json['file'])?.toString().trim() ?? '';
      if (id.isEmpty ||
          name.isEmpty ||
          versionValue is! num ||
          download.isEmpty) {
        continue;
      }
      final Uri downloadUri = indexUri.resolve(download);
      _requireHttps(downloadUri);
      final Object? languagesValue = json['languages'] ?? json['lang'];
      final List<String> languages = switch (languagesValue) {
        List<Object?> values => values
            .map((Object? value) => value.toString())
            .toList(growable: false),
        String value when value.isNotEmpty => <String>[value],
        _ => const <String>[],
      };
      final String? icon = json['iconURL']?.toString().trim();
      final AidokuRepositorySource source = AidokuRepositorySource(
        id: id,
        name: name,
        version: versionValue.toInt(),
        languages: languages,
        downloadUri: downloadUri,
        iconUri: icon == null || icon.isEmpty ? null : indexUri.resolve(icon),
        baseUrl: json['baseURL']?.toString(),
        minimumAppVersion: json['minAppVersion']?.toString(),
        contentRating: (json['contentRating'] as num?)?.toInt(),
      );
      final AidokuRepositorySource? previous = sources[id];
      if (previous == null || previous.version < source.version) {
        sources[id] = source;
      }
    }
    if (sources.isEmpty) {
      throw const AidokuRepositoryException(
        'INVALID_INDEX',
        'The repository does not contain any installable Aidoku sources',
      );
    }
    final List<AidokuRepositorySource> sorted = sources.values.toList()
      ..sort(
        (AidokuRepositorySource a, AidokuRepositorySource b) =>
            a.name.toLowerCase().compareTo(b.name.toLowerCase()),
      );
    return AidokuRepositoryIndex(
      name: repositoryName.isEmpty ? indexUri.host : repositoryName,
      indexUri: indexUri,
      sources: sorted,
    );
  }

  static bool _isRedirect(int statusCode) =>
      statusCode == 301 ||
      statusCode == 302 ||
      statusCode == 303 ||
      statusCode == 307 ||
      statusCode == 308;

  static void _requireHttps(Uri uri) {
    if (uri.scheme.toLowerCase() != 'https' || !uri.hasAuthority) {
      throw const AidokuRepositoryException(
        'INSECURE_URL',
        'Aidoku repositories and downloads must use HTTPS',
      );
    }
  }
}
