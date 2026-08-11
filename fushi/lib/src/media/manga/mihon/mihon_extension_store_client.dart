import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'package:fushi/src/media/manga/mihon/mihon_models.dart';
import 'package:fushi/src/utils/net/app_http.dart';

const int mihonStoreMaxBytes = 10 * 1024 * 1024;
const int mihonExtensionApkMaxBytes = 100 * 1024 * 1024;

enum MihonStoreFormat { currentJson, currentProtobuf, legacy }

@immutable
class MihonStore {
  const MihonStore({
    required this.indexUrl,
    required this.name,
    required this.badgeLabel,
    required this.signingKey,
    required this.contact,
    required this.format,
    required this.extensionListUrl,
    this.embeddedExtensions = const <MihonAvailableExtension>[],
  });

  final String indexUrl;
  final String name;
  final String badgeLabel;
  final String signingKey;
  final Map<String, String?> contact;
  final MihonStoreFormat format;
  final String? extensionListUrl;
  final List<MihonAvailableExtension> embeddedExtensions;
}

@immutable
class MihonAvailableSource {
  const MihonAvailableSource({
    required this.id,
    required this.name,
    required this.language,
    required this.baseUrl,
  });

  final String id;
  final String name;
  final String language;
  final String baseUrl;
}

@immutable
class MihonAvailableExtension {
  const MihonAvailableExtension({
    required this.storeUrl,
    required this.name,
    required this.packageName,
    required this.apkUrl,
    required this.iconUrl,
    required this.libVersion,
    required this.versionCode,
    required this.versionName,
    required this.language,
    required this.contentWarning,
    required this.sources,
  });

  final String storeUrl;
  final String name;
  final String packageName;
  final String apkUrl;
  final String iconUrl;
  final String libVersion;
  final int versionCode;
  final String versionName;
  final String language;
  final int contentWarning;
  final List<MihonAvailableSource> sources;
}

@immutable
class MihonStoreFetchResult {
  const MihonStoreFetchResult({
    required this.store,
    required this.etag,
    required this.lastModified,
    this.notModified = false,
  });

  final MihonStore? store;
  final String? etag;
  final String? lastModified;
  final bool notModified;
}

class MihonExtensionStoreClient {
  MihonExtensionStoreClient({http.Client? client})
      : _client = client ?? createAppHttpIoClient();

  final http.Client _client;

  Future<MihonStoreFetchResult> fetchStore(
    String rawUrl, {
    String? etag,
    String? lastModified,
    bool allowInsecure = false,
  }) async {
    final Uri indexUrl = _validatedUri(rawUrl, allowInsecure: allowInsecure);
    final _NetworkBytes response = await _get(
      indexUrl,
      etag: etag,
      lastModified: lastModified,
      allowNotModified: true,
      allowInsecure: allowInsecure,
    );
    if (response.notModified) {
      return MihonStoreFetchResult(
        store: null,
        etag: response.etag ?? etag,
        lastModified: response.lastModified ?? lastModified,
        notModified: true,
      );
    }
    final Uint8List bytes = _decodeGzip(
      response.bytes,
      maxBytes: mihonStoreMaxBytes,
    );
    final int first = _firstNonWhitespace(bytes);
    MihonStore store;
    if (first == 0x5b) {
      if (!indexUrl.path.endsWith('/index.min.json')) {
        throw const MihonRuntimeException(
          'INVALID_LEGACY_STORE',
          'Legacy extension list URL must end with /index.min.json',
        );
      }
      final Uri metadataUrl = indexUrl.replace(
          path: indexUrl.path.replaceFirst(
        RegExp(r'/index\.min\.json$'),
        '/repo.json',
      ));
      final _NetworkBytes metadata = await _get(
        metadataUrl,
        allowInsecure: allowInsecure,
      );
      store = _parseLegacyStore(
        metadataUrl,
        _jsonObject(
          _decodeGzip(metadata.bytes, maxBytes: mihonStoreMaxBytes),
        ),
      );
    } else if (first == 0x7b) {
      final Map<String, Object?> json = _jsonObject(bytes);
      if (json.containsKey('meta')) {
        final MihonStore legacy = _parseLegacyStore(indexUrl, json);
        final Object? indexV2 = json['index_v2'];
        if (indexV2 is String && indexV2.trim().isNotEmpty) {
          return fetchStore(
            indexUrl.resolve(indexV2).toString(),
            allowInsecure: allowInsecure,
          );
        }
        store = legacy;
      } else {
        store = _parseCurrentStoreJson(indexUrl, json);
      }
    } else {
      store = _parseCurrentStoreProto(indexUrl, bytes);
    }
    return MihonStoreFetchResult(
      store: store,
      etag: response.etag,
      lastModified: response.lastModified,
    );
  }

  Future<List<MihonAvailableExtension>> fetchExtensions(
    MihonStore store, {
    bool allowInsecure = false,
  }) async {
    if (store.embeddedExtensions.isNotEmpty) {
      return store.embeddedExtensions;
    }
    final Uri indexUrl = Uri.parse(store.indexUrl);
    if (store.format == MihonStoreFormat.legacy) {
      final Uri listUrl = indexUrl.replace(
        path: indexUrl.path.replaceFirst(
          RegExp(r'/repo\.json$'),
          '/index.min.json',
        ),
      );
      final _NetworkBytes response = await _get(
        listUrl,
        allowInsecure: allowInsecure,
      );
      final Object? decoded = jsonDecode(utf8.decode(_decodeGzip(
        response.bytes,
        maxBytes: mihonStoreMaxBytes,
      )));
      if (decoded is! List<Object?>) {
        throw const MihonRuntimeException(
          'INVALID_STORE',
          'Legacy extension index is not a JSON array',
        );
      }
      final Uri base = indexUrl.resolve('.');
      return decoded
          .whereType<Map<Object?, Object?>>()
          .map((Map<Object?, Object?> item) => _parseLegacyExtension(
                store,
                base,
                item.cast<String, Object?>(),
              ))
          .toList(growable: false);
    }
    final String? rawListUrl = store.extensionListUrl;
    if (rawListUrl == null || rawListUrl.isEmpty) return const [];
    final Uri listUrl = _validatedUri(
      indexUrl.resolve(rawListUrl).toString(),
      allowInsecure: allowInsecure,
    );
    final _NetworkBytes response = await _get(
      listUrl,
      allowInsecure: allowInsecure,
    );
    final Uint8List bytes = _decodeGzip(
      response.bytes,
      maxBytes: mihonStoreMaxBytes,
    );
    if (_firstNonWhitespace(bytes) == 0x7b) {
      final Map<String, Object?> json = _jsonObject(bytes);
      final List<Object?> values =
          json['extensions'] as List<Object?>? ?? const <Object?>[];
      return values
          .whereType<Map<Object?, Object?>>()
          .map((Map<Object?, Object?> item) => _parseCurrentExtensionJson(
                store,
                listUrl,
                item.cast<String, Object?>(),
              ))
          .toList(growable: false);
    }
    return _parseExtensionListProto(store, listUrl, bytes);
  }

  Future<Uint8List> downloadApk(
    String rawUrl, {
    bool allowInsecure = false,
  }) async {
    final Uri url = _validatedUri(rawUrl, allowInsecure: allowInsecure);
    final _NetworkBytes response = await _get(
      url,
      maxBytes: mihonExtensionApkMaxBytes,
      allowInsecure: allowInsecure,
    );
    return response.bytes;
  }

  void close() => _client.close();

  Future<_NetworkBytes> _get(
    Uri url, {
    int maxBytes = mihonStoreMaxBytes,
    String? etag,
    String? lastModified,
    bool allowNotModified = false,
    bool allowInsecure = false,
    int redirectCount = 0,
  }) async {
    final http.Request request = http.Request('GET', url);
    request.followRedirects = false;
    if (etag != null && etag.isNotEmpty) {
      request.headers[HttpHeaders.ifNoneMatchHeader] = etag;
    }
    if (lastModified != null && lastModified.isNotEmpty) {
      request.headers[HttpHeaders.ifModifiedSinceHeader] = lastModified;
    }
    final http.StreamedResponse response =
        await _client.send(request).timeout(const Duration(seconds: 30));
    if (<int>{
      HttpStatus.movedPermanently,
      HttpStatus.found,
      HttpStatus.seeOther,
      HttpStatus.temporaryRedirect,
      HttpStatus.permanentRedirect,
    }.contains(response.statusCode)) {
      if (redirectCount >= 5) {
        await response.stream.drain<void>();
        throw const MihonRuntimeException(
          'TOO_MANY_REDIRECTS',
          'Extension store redirected too many times',
        );
      }
      final String? location = response.headers[HttpHeaders.locationHeader];
      if (location == null || location.isEmpty) {
        await response.stream.drain<void>();
        throw const MihonRuntimeException(
          'INVALID_REDIRECT',
          'Extension store redirect has no destination',
        );
      }
      final Uri redirected = _validatedUri(
        url.resolve(location).toString(),
        allowInsecure: allowInsecure,
      );
      await response.stream.drain<void>();
      return _get(
        redirected,
        maxBytes: maxBytes,
        etag: etag,
        lastModified: lastModified,
        allowNotModified: allowNotModified,
        allowInsecure: allowInsecure,
        redirectCount: redirectCount + 1,
      );
    }
    _validatedUri(
      (response.request?.url ?? url).toString(),
      allowInsecure: allowInsecure,
    );
    if (allowNotModified && response.statusCode == HttpStatus.notModified) {
      return _NetworkBytes(
        Uint8List(0),
        etag: response.headers[HttpHeaders.etagHeader],
        lastModified: response.headers[HttpHeaders.lastModifiedHeader],
        notModified: true,
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      await response.stream.drain<void>();
      throw MihonRuntimeException(
        'STORE_HTTP_${response.statusCode}',
        'Extension store request failed',
      );
    }
    final int? declared = int.tryParse(
      response.headers[HttpHeaders.contentLengthHeader] ?? '',
    );
    if (declared != null && declared > maxBytes) {
      await response.stream.drain<void>();
      throw MihonRuntimeException(
        'DOWNLOAD_TOO_LARGE',
        'Download exceeds the ${maxBytes ~/ (1024 * 1024)} MiB limit',
      );
    }
    final BytesBuilder builder = BytesBuilder(copy: false);
    int length = 0;
    await for (final List<int> chunk in response.stream) {
      length += chunk.length;
      if (length > maxBytes) {
        throw MihonRuntimeException(
          'DOWNLOAD_TOO_LARGE',
          'Download exceeds the ${maxBytes ~/ (1024 * 1024)} MiB limit',
        );
      }
      builder.add(chunk);
    }
    return _NetworkBytes(
      builder.takeBytes(),
      etag: response.headers[HttpHeaders.etagHeader],
      lastModified: response.headers[HttpHeaders.lastModifiedHeader],
    );
  }

  static Uri _validatedUri(
    String rawUrl, {
    required bool allowInsecure,
  }) {
    final Uri? uri = Uri.tryParse(rawUrl.trim());
    if (uri == null || !uri.hasAuthority) {
      throw const MihonRuntimeException(
        'INVALID_URL',
        'Extension store URL is invalid',
      );
    }
    if (uri.scheme != 'https' && !(allowInsecure && uri.scheme == 'http')) {
      throw const MihonRuntimeException(
        'INSECURE_URL',
        'Extension stores require HTTPS unless insecure HTTP was explicitly approved',
      );
    }
    return uri;
  }

  static MihonStore _parseLegacyStore(
    Uri indexUrl,
    Map<String, Object?> json,
  ) {
    final Map<String, Object?> meta =
        (json['meta'] as Map<Object?, Object?>? ?? const <Object?, Object?>{})
            .cast<String, Object?>();
    final String name = meta['name']?.toString() ?? '';
    if (name.isEmpty) {
      throw const MihonRuntimeException(
        'INVALID_STORE',
        'Legacy store metadata has no name',
      );
    }
    return MihonStore(
      indexUrl: indexUrl.toString(),
      name: name,
      badgeLabel: meta['shortName']?.toString() ?? name,
      signingKey: meta['signingKeyFingerprint']?.toString() ?? '',
      contact: <String, String?>{
        'website': meta['website']?.toString(),
        'discord': null,
      },
      format: MihonStoreFormat.legacy,
      extensionListUrl: null,
    );
  }

  static MihonStore _parseCurrentStoreJson(
    Uri indexUrl,
    Map<String, Object?> json,
  ) {
    final Map<String, Object?> contact =
        (json['contact'] as Map<Object?, Object?>? ??
                const <Object?, Object?>{})
            .cast<String, Object?>();
    final MihonStore shell = _validateCurrentStore(MihonStore(
      indexUrl: indexUrl.toString(),
      name: json['name']?.toString() ?? '',
      badgeLabel: json['badgeLabel']?.toString() ?? '',
      signingKey: json['signingKey']?.toString() ?? '',
      contact: <String, String?>{
        'website': contact['website']?.toString(),
        'discord': contact['discord']?.toString(),
      },
      format: MihonStoreFormat.currentJson,
      extensionListUrl: json['extensionListUrl']?.toString(),
    ));
    final Map<String, Object?>? list =
        (json['extensionList'] as Map<Object?, Object?>?)
            ?.cast<String, Object?>();
    final List<MihonAvailableExtension> extensions =
        (list?['extensions'] as List<Object?>? ?? const <Object?>[])
            .whereType<Map<Object?, Object?>>()
            .map((Map<Object?, Object?> item) => _parseCurrentExtensionJson(
                  shell,
                  indexUrl,
                  item.cast<String, Object?>(),
                ))
            .toList(growable: false);
    return MihonStore(
      indexUrl: shell.indexUrl,
      name: shell.name,
      badgeLabel: shell.badgeLabel,
      signingKey: shell.signingKey,
      contact: shell.contact,
      format: shell.format,
      extensionListUrl: shell.extensionListUrl,
      embeddedExtensions: extensions,
    );
  }

  static MihonAvailableExtension _parseCurrentExtensionJson(
    MihonStore store,
    Uri documentUrl,
    Map<String, Object?> json,
  ) {
    final Map<String, Object?> resources =
        (json['resources'] as Map<Object?, Object?>? ??
                const <Object?, Object?>{})
            .cast<String, Object?>();
    final List<MihonAvailableSource> sources =
        (json['sources'] as List<Object?>? ?? const <Object?>[])
            .whereType<Map<Object?, Object?>>()
            .map((Map<Object?, Object?> item) {
      final Map<String, Object?> source = item.cast<String, Object?>();
      return MihonAvailableSource(
        id: source['id'].toString(),
        name: source['name']?.toString() ?? '',
        language: source['language']?.toString() ?? '',
        baseUrl: source['homeUrl']?.toString() ?? '',
      );
    }).toList(growable: false);
    final Object? warning = json['contentWarning'];
    return MihonAvailableExtension(
      storeUrl: store.indexUrl,
      name: json['name']?.toString() ?? '',
      packageName: json['packageName']?.toString() ?? '',
      apkUrl:
          documentUrl.resolve(resources['apkUrl']?.toString() ?? '').toString(),
      iconUrl: documentUrl
          .resolve(resources['iconUrl']?.toString() ?? '')
          .toString(),
      libVersion: json['extensionLib']?.toString() ?? '',
      versionCode: (json['versionCode'] as num?)?.toInt() ?? 0,
      versionName: json['versionName']?.toString() ?? '',
      language:
          sources.map((MihonAvailableSource s) => s.language).toSet().length ==
                  1
              ? sources.first.language
              : 'all',
      contentWarning: warning is num
          ? warning.toInt()
          : switch (warning?.toString()) {
              'CONTENT_WARNING_SAFE' || 'SAFE' => 1,
              'CONTENT_WARNING_MIXED' || 'MIXED' => 2,
              'CONTENT_WARNING_NSFW' || 'NSFW' => 3,
              _ => 0,
            },
      sources: sources,
    );
  }

  static MihonAvailableExtension _parseLegacyExtension(
    MihonStore store,
    Uri base,
    Map<String, Object?> json,
  ) {
    final String packageName = json['pkg']?.toString() ?? '';
    final String versionName = json['version']?.toString() ?? '';
    final List<MihonAvailableSource> sources =
        (json['sources'] as List<Object?>? ?? const <Object?>[])
            .whereType<Map<Object?, Object?>>()
            .map((Map<Object?, Object?> item) {
      final Map<String, Object?> source = item.cast<String, Object?>();
      return MihonAvailableSource(
        id: source['id'].toString(),
        name: source['name']?.toString() ?? '',
        language: source['lang']?.toString() ?? '',
        baseUrl: source['baseUrl']?.toString() ?? '',
      );
    }).toList(growable: false);
    final String language = json['lang']?.toString() ?? '';
    return MihonAvailableExtension(
      storeUrl: store.indexUrl,
      name: (json['name']?.toString() ?? '').replaceFirst('Tachiyomi: ', ''),
      packageName: packageName,
      apkUrl: base.resolve('apk/${json['apk']}').toString(),
      iconUrl: base.resolve('icon/$packageName.png').toString(),
      libVersion: versionName.contains('.')
          ? versionName.substring(0, versionName.lastIndexOf('.'))
          : versionName,
      versionCode: (json['code'] as num?)?.toInt() ?? 0,
      versionName: versionName,
      language: language,
      contentWarning: (json['nsfw'] as num?)?.toInt() == 1 ? 3 : 1,
      sources: sources.isNotEmpty
          ? sources
          : <MihonAvailableSource>[
              MihonAvailableSource(
                id: '0',
                name: json['name']?.toString() ?? '',
                language: language,
                baseUrl: '',
              ),
            ],
    );
  }

  static MihonStore _parseCurrentStoreProto(Uri indexUrl, Uint8List bytes) {
    final _ProtoReader reader = _ProtoReader(bytes);
    String name = '';
    String badgeLabel = '';
    String signingKey = '';
    Map<String, String?> contact = const <String, String?>{};
    String? extensionListUrl;
    Uint8List? extensionList;
    while (!reader.isDone) {
      final _ProtoField field = reader.readField();
      switch (field.number) {
        case 1:
          name = field.stringValue;
        case 2:
          badgeLabel = field.stringValue;
        case 3:
          signingKey = field.stringValue;
        case 4:
          contact = _parseContactProto(field.bytesValue);
        case 101:
          extensionList = field.bytesValue;
        case 102:
          extensionListUrl = field.stringValue;
      }
    }
    final MihonStore shell = _validateCurrentStore(MihonStore(
      indexUrl: indexUrl.toString(),
      name: name,
      badgeLabel: badgeLabel,
      signingKey: signingKey,
      contact: contact,
      format: MihonStoreFormat.currentProtobuf,
      extensionListUrl: extensionListUrl,
    ));
    return MihonStore(
      indexUrl: shell.indexUrl,
      name: shell.name,
      badgeLabel: shell.badgeLabel,
      signingKey: shell.signingKey,
      contact: shell.contact,
      format: shell.format,
      extensionListUrl: shell.extensionListUrl,
      embeddedExtensions: extensionList == null
          ? const <MihonAvailableExtension>[]
          : _parseExtensionListProto(shell, indexUrl, extensionList),
    );
  }

  static List<MihonAvailableExtension> _parseExtensionListProto(
    MihonStore store,
    Uri documentUrl,
    Uint8List bytes,
  ) {
    final _ProtoReader reader = _ProtoReader(bytes);
    final List<MihonAvailableExtension> result = <MihonAvailableExtension>[];
    while (!reader.isDone) {
      final _ProtoField field = reader.readField();
      if (field.number == 1) {
        result.add(_parseExtensionProto(store, documentUrl, field.bytesValue));
      }
    }
    return result;
  }

  static MihonAvailableExtension _parseExtensionProto(
    MihonStore store,
    Uri documentUrl,
    Uint8List bytes,
  ) {
    final _ProtoReader reader = _ProtoReader(bytes);
    String name = '';
    String packageName = '';
    String apkUrl = '';
    String iconUrl = '';
    String libVersion = '';
    int versionCode = 0;
    String versionName = '';
    int warning = 0;
    final List<MihonAvailableSource> sources = <MihonAvailableSource>[];
    while (!reader.isDone) {
      final _ProtoField field = reader.readField();
      switch (field.number) {
        case 1:
          name = field.stringValue;
        case 2:
          packageName = field.stringValue;
        case 3:
          final List<String> resources = _parseResourcesProto(field.bytesValue);
          apkUrl = resources[0];
          iconUrl = resources[1];
        case 4:
          libVersion = field.stringValue;
        case 5:
          versionCode = field.signedInt64Value;
        case 6:
          versionName = field.stringValue;
        case 7:
          warning = field.varintValue;
        case 8:
          sources.add(_parseSourceProto(field.bytesValue));
      }
    }
    final Set<String> languages =
        sources.map((MihonAvailableSource source) => source.language).toSet();
    return MihonAvailableExtension(
      storeUrl: store.indexUrl,
      name: name,
      packageName: packageName,
      apkUrl: documentUrl.resolve(apkUrl).toString(),
      iconUrl: documentUrl.resolve(iconUrl).toString(),
      libVersion: libVersion,
      versionCode: versionCode,
      versionName: versionName,
      language: languages.length == 1 ? languages.first : 'all',
      contentWarning: warning,
      sources: sources,
    );
  }

  static Map<String, String?> _parseContactProto(Uint8List bytes) {
    final _ProtoReader reader = _ProtoReader(bytes);
    String? website;
    String? discord;
    while (!reader.isDone) {
      final _ProtoField field = reader.readField();
      if (field.number == 1) website = field.stringValue;
      if (field.number == 2) discord = field.stringValue;
    }
    return <String, String?>{'website': website, 'discord': discord};
  }

  static List<String> _parseResourcesProto(Uint8List bytes) {
    final _ProtoReader reader = _ProtoReader(bytes);
    String apk = '';
    String icon = '';
    while (!reader.isDone) {
      final _ProtoField field = reader.readField();
      if (field.number == 1) apk = field.stringValue;
      if (field.number == 2) icon = field.stringValue;
    }
    return <String>[apk, icon];
  }

  static MihonAvailableSource _parseSourceProto(Uint8List bytes) {
    final _ProtoReader reader = _ProtoReader(bytes);
    int id = 0;
    String name = '';
    String language = '';
    String baseUrl = '';
    while (!reader.isDone) {
      final _ProtoField field = reader.readField();
      switch (field.number) {
        case 1:
          id = field.signedInt64Value;
        case 2:
          name = field.stringValue;
        case 3:
          language = field.stringValue;
        case 4:
          baseUrl = field.stringValue;
      }
    }
    return MihonAvailableSource(
      id: '$id',
      name: name,
      language: language,
      baseUrl: baseUrl,
    );
  }

  static Map<String, Object?> _jsonObject(Uint8List bytes) {
    final Object? decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map<Object?, Object?>) {
      throw const MihonRuntimeException(
        'INVALID_STORE',
        'Extension store metadata is not a JSON object',
      );
    }
    return decoded.cast<String, Object?>();
  }

  static int _firstNonWhitespace(Uint8List bytes) {
    for (final int byte in bytes) {
      if (byte != 0x20 && byte != 0x09 && byte != 0x0a && byte != 0x0d) {
        return byte;
      }
    }
    throw const MihonRuntimeException(
      'EMPTY_STORE',
      'Extension store returned an empty response',
    );
  }

  static MihonStore _validateCurrentStore(MihonStore store) {
    if (store.name.trim().isEmpty ||
        store.badgeLabel.trim().isEmpty ||
        store.signingKey.trim().isEmpty) {
      throw const MihonRuntimeException(
        'INVALID_STORE',
        'Current extension stores require name, badgeLabel, and signingKey',
      );
    }
    return store;
  }

  static Uint8List _decodeGzip(
    Uint8List bytes, {
    required int maxBytes,
  }) {
    Uint8List decoded = bytes;
    if (bytes.length >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b) {
      final _LimitedByteSink sink = _LimitedByteSink(maxBytes);
      final ByteConversionSink decoder =
          gzip.decoder.startChunkedConversion(sink);
      try {
        decoder
          ..add(bytes)
          ..close();
        decoded = sink.takeBytes();
      } on MihonRuntimeException {
        rethrow;
      } on Object catch (error) {
        throw MihonRuntimeException(
          'INVALID_GZIP',
          'Extension store returned invalid gzip data',
          cause: error,
        );
      }
    }
    if (decoded.length > maxBytes) {
      throw MihonRuntimeException(
        'DOWNLOAD_TOO_LARGE',
        'Decoded download exceeds the ${maxBytes ~/ (1024 * 1024)} MiB limit',
      );
    }
    return decoded;
  }
}

class _LimitedByteSink extends ByteConversionSink {
  _LimitedByteSink(this.maxBytes);

  final int maxBytes;
  final BytesBuilder _builder = BytesBuilder(copy: false);
  int _length = 0;
  bool _closed = false;

  @override
  void add(List<int> chunk) {
    if (_closed) throw StateError('Cannot add bytes after close');
    _length += chunk.length;
    if (_length > maxBytes) {
      throw MihonRuntimeException(
        'DOWNLOAD_TOO_LARGE',
        'Decoded download exceeds the ${maxBytes ~/ (1024 * 1024)} MiB limit',
      );
    }
    _builder.add(chunk);
  }

  @override
  void close() {
    _closed = true;
  }

  Uint8List takeBytes() {
    if (!_closed) throw StateError('Gzip decoder has not been closed');
    return _builder.takeBytes();
  }
}

class _NetworkBytes {
  const _NetworkBytes(
    this.bytes, {
    this.etag,
    this.lastModified,
    this.notModified = false,
  });

  final Uint8List bytes;
  final String? etag;
  final String? lastModified;
  final bool notModified;
}

class _ProtoReader {
  _ProtoReader(this.bytes);

  final Uint8List bytes;
  int _offset = 0;

  bool get isDone => _offset >= bytes.length;

  _ProtoField readField() {
    final int tag = _readVarint();
    final int number = tag >> 3;
    final int wireType = tag & 7;
    switch (wireType) {
      case 0:
        return _ProtoField(number, varintValue: _readVarint());
      case 1:
        _skip(8);
        return _ProtoField(number);
      case 2:
        final int length = _readVarint();
        if (length < 0 || _offset + length > bytes.length) {
          throw const MihonRuntimeException(
            'INVALID_PROTOBUF',
            'Truncated protobuf field',
          );
        }
        final Uint8List value =
            Uint8List.sublistView(bytes, _offset, _offset + length);
        _offset += length;
        return _ProtoField(number, bytesValue: value);
      case 5:
        _skip(4);
        return _ProtoField(number);
      default:
        throw MihonRuntimeException(
          'INVALID_PROTOBUF',
          'Unsupported protobuf wire type $wireType',
        );
    }
  }

  int _readVarint() {
    int value = 0;
    int shift = 0;
    while (_offset < bytes.length && shift <= 63) {
      final int byte = bytes[_offset++];
      value |= (byte & 0x7f) << shift;
      if (byte & 0x80 == 0) return value;
      shift += 7;
    }
    throw const MihonRuntimeException(
      'INVALID_PROTOBUF',
      'Malformed protobuf varint',
    );
  }

  void _skip(int count) {
    if (_offset + count > bytes.length) {
      throw const MihonRuntimeException(
        'INVALID_PROTOBUF',
        'Truncated protobuf field',
      );
    }
    _offset += count;
  }
}

class _ProtoField {
  _ProtoField(
    this.number, {
    this.varintValue = 0,
    Uint8List? bytesValue,
  }) : bytesValue = bytesValue ?? Uint8List(0);

  final int number;
  final int varintValue;
  final Uint8List bytesValue;

  String get stringValue => utf8.decode(bytesValue);

  int get signedInt64Value => varintValue.toSigned(64);
}
