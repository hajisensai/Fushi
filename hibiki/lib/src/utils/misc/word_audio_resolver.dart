import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/utils/misc/error_log_service.dart';

typedef LocalAudioQuery = Future<Map<String, dynamic>?> Function(
    String expression, String reading);
typedef LocalAudioExtractor = Future<String?>
    Function(String file, String source, {int dbIndex});
typedef AudioSourceListFetcher = Future<List<String>> Function(String url);

class WordAudioResolver {
  WordAudioResolver({
    required this.queryLocalAudio,
    required this.extractLocalAudio,
    AudioSourceListFetcher? fetchAudioSourceList,
  }) : fetchAudioSourceList = fetchAudioSourceList ??
            WordAudioResolver.defaultFetchAudioSourceList;

  static const String localAudioUrl =
      'http://localhost:8765/localaudio/get/?term={term}&reading={reading}';

  final LocalAudioQuery queryLocalAudio;
  final LocalAudioExtractor extractLocalAudio;
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

  Future<String?> _resolveLocal(String expression, String reading) async {
    final Map<String, dynamic>? info =
        await queryLocalAudio(expression, reading);
    if (info == null) return null;

    final String? file = info['file'] as String?;
    final String? source = info['source'] as String?;
    if (file == null || source == null) return null;

    final int dbIndex = (info['dbIndex'] as int?) ?? 0;
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
