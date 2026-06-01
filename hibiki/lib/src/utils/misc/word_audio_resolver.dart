import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/models/audio_source_config.dart';
import 'package:hibiki/src/utils/misc/error_log_service.dart';

typedef LocalAudioQuery = Future<Map<String, dynamic>?> Function(
    String expression, String reading);
typedef IndexedLocalAudioQuery = Future<Map<String, dynamic>?> Function(
    String expression, String reading, int dbIndex);
typedef LocalAudioExtractor = Future<String?>
    Function(String file, String source, {int dbIndex});
typedef AudioSourceListFetcher = Future<List<String>> Function(String url);
typedef RemoteAudioQuery = Future<String?> Function(
    String expression, String reading);

class WordAudioResolver {
  WordAudioResolver({
    required this.queryLocalAudio,
    required this.extractLocalAudio,
    IndexedLocalAudioQuery? queryLocalAudioByDbIndex,
    this.queryRemoteAudio,
    AudioSourceListFetcher? fetchAudioSourceList,
  })  : queryLocalAudioByDbIndex = queryLocalAudioByDbIndex ??
            ((String expression, String reading, int _) =>
                queryLocalAudio(expression, reading)),
        fetchAudioSourceList = fetchAudioSourceList ??
            WordAudioResolver.defaultFetchAudioSourceList;

  static const String localAudioUrl =
      'http://localhost:8765/localaudio/get/?term={term}&reading={reading}';
  static const String hibikiRemoteAudioUrl = 'hibiki://remote-audio';

  final LocalAudioQuery queryLocalAudio;
  final IndexedLocalAudioQuery queryLocalAudioByDbIndex;
  final LocalAudioExtractor extractLocalAudio;
  final RemoteAudioQuery? queryRemoteAudio;
  final AudioSourceListFetcher fetchAudioSourceList;

  Future<String?> resolve({
    required String expression,
    required String reading,
    required List<String> sources,
  }) async {
    for (final String template in sources) {
      if (template == localAudioUrl) {
        final String? path = await _resolveLocal(expression, reading);
        if (path != null && path.isNotEmpty) return path;
        final String? remote = await queryRemoteAudio?.call(
          expression,
          reading,
        );
        if (remote != null && remote.isNotEmpty) return remote;
        continue;
      }
      if (template == hibikiRemoteAudioUrl) {
        final String? remote = await queryRemoteAudio?.call(
          expression,
          reading,
        );
        if (remote != null && remote.isNotEmpty) return remote;
        continue;
      }

      final String url = expandTemplate(
        template: template,
        expression: expression,
        reading: reading,
      );
      final List<String> urls = await fetchAudioSourceList(url);
      if (urls.isNotEmpty) return urls.first;
    }

    return null;
  }

  Future<String?> resolveConfigured({
    required String expression,
    required String reading,
    required List<AudioSourceConfig> sources,
  }) async {
    int localDbIndex = 0;
    for (final AudioSourceConfig source in sources) {
      if (!source.enabled) {
        continue;
      }

      switch (source.kind) {
        case AudioSourceKind.hibikiRemote:
          final String? remote = await queryRemoteAudio?.call(
            expression,
            reading,
          );
          if (remote != null && remote.isNotEmpty) return remote;
        case AudioSourceKind.localAudio:
          final int dbIndex = localDbIndex;
          localDbIndex++;
          final String? path = await _resolveLocalAt(
            expression,
            reading,
            dbIndex,
          );
          if (path != null && path.isNotEmpty) return path;
        case AudioSourceKind.remoteAudio:
          final String? template = source.url;
          if (template == null || template.isEmpty) continue;
          final String url = expandTemplate(
            template: template,
            expression: expression,
            reading: reading,
          );
          final List<String> urls = await fetchAudioSourceList(url);
          if (urls.isNotEmpty) return urls.first;
      }
    }
    return null;
  }

  Future<String?> _resolveLocal(String expression, String reading) async {
    final Map<String, dynamic>? info =
        await queryLocalAudio(expression, reading);
    return _extractLocal(info);
  }

  Future<String?> _resolveLocalAt(
    String expression,
    String reading,
    int dbIndex,
  ) async {
    final Map<String, dynamic>? info =
        await queryLocalAudioByDbIndex(expression, reading, dbIndex);
    return _extractLocal(info, fallbackDbIndex: dbIndex);
  }

  Future<String?> _extractLocal(
    Map<String, dynamic>? info, {
    int fallbackDbIndex = 0,
  }) async {
    if (info == null) return null;

    final String? file = info['file'] as String?;
    final String? source = info['source'] as String?;
    if (file == null || source == null) return null;

    final int dbIndex = (info['dbIndex'] as int?) ?? fallbackDbIndex;
    return extractLocalAudio(file, source, dbIndex: dbIndex);
  }

  static String expandTemplate({
    required String template,
    required String expression,
    required String reading,
  }) {
    return template
        .replaceAll('{term}', Uri.encodeComponent(expression))
        .replaceAll('{reading}', Uri.encodeComponent(reading));
  }

  static final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 5),
    receiveTimeout: const Duration(seconds: 10),
  ));

  static Future<List<String>> defaultFetchAudioSourceList(String url) async {
    try {
      final Response<dynamic> response = await _dio.get<dynamic>(url);
      final dynamic body = response.data is String
          ? jsonDecode(response.data as String)
          : response.data;
      if (body is! Map) return const <String>[];

      final dynamic sources = body['audioSources'];
      if (body['type'] != 'audioSourceList' || sources is! List) {
        return const <String>[];
      }

      return sources
          .whereType<Map>()
          .map((source) => source['url']?.toString() ?? '')
          .where((value) => value.isNotEmpty)
          .toList(growable: false);
    } catch (e, stack) {
      final host = Uri.tryParse(url)?.host ?? url;
      final String detail;
      if (e is DioError) {
        final inner = e.error;
        if (inner is SocketException) {
          detail = t.audio_source_dns_error(host: host);
        } else if (e.type == DioErrorType.connectionTimeout) {
          detail = t.audio_source_timeout(host: host);
        } else {
          detail =
              t.audio_source_request_error(detail: e.message ?? e.type.name);
        }
      } else {
        detail = t.audio_source_error(detail: '$e');
      }
      ErrorLogService.instance.log(detail, e, stack);
      return const <String>[];
    }
  }
}
