import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/models/audio_source_config.dart';
import 'package:hibiki/src/utils/misc/error_log_service.dart';

/// 弱网下的连接超时上限：从 5s 放宽到 8s，减少慢握手被误判为失败（TODO-1057）。
const Duration kRemoteAudioConnectTimeout = Duration(seconds: 8);

/// 远端音源列表响应读取超时上限（保持既有 10s，仅常量化便于统一维护）。
const Duration kRemoteAudioReceiveTimeout = Duration(seconds: 10);

/// 单个远端音源 host 一次失败后进入的冷却窗口：窗口内不再对同一 host 发起请求，
/// 避免死源（如用户配置的 localhost:41440）在连续查词时刷屏 + 串行拖累后续可用源
/// （TODO-1057）。窗口过后自动放行重试一次。
const Duration kRemoteAudioFailureCooldown = Duration(seconds: 45);

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
      List<String> urls;
      try {
        urls = await fetchAudioSourceList(url);
      } catch (_) {
        // 传统 resolve() 保持“失败即跳过”语义；冷却只由 resolveConfigured 管理。
        continue;
      }
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
          // 失败冷却：该 host 仍在冷却窗内则直接短路——不发请求、不再记日志，
          // 也不让死源阻塞后续可用源（TODO-1057）。
          if (isRemoteSourceInCooldown(url)) {
            continue;
          }
          List<String> urls;
          try {
            urls = await fetchAudioSourceList(url);
          } catch (_) {
            // fetcher 抛出=网络失败（defaultFetchAudioSourceList 记一次日志后 rethrow）：
            // 记录冷却并跳到下一源，绝不吞掉可诊断性。
            _markRemoteSourceFailed(url);
            continue;
          }
          // 成功抵达（含合法“无音频”空列表）：清除该 host 冷却，恢复其优先级。
          _markRemoteSourceOk(url);
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
    connectTimeout: kRemoteAudioConnectTimeout,
    receiveTimeout: kRemoteAudioReceiveTimeout,
  ));

  /// 远端音源失败冷却表：host -> 冷却截止时间。窗口内命中的 host 直接短路跳过，
  /// 不发请求、不再记日志（TODO-1057）。成功时清除该 host 的条目。
  static final Map<String, DateTime> _remoteFailureCooldownUntil =
      <String, DateTime>{};

  /// 可注入的“当前时间”来源，默认 [DateTime.now]。仅供测试用极短窗 + 手动推进时钟
  /// 断言冷却行为，无需真实 sleep。生产代码永远走 [DateTime.now]。
  static DateTime Function() _nowProvider = DateTime.now;

  /// 归一化冷却 key：优先按 host 归并（同一 host 的多源/重复失败命中同一冷却项）；
  /// host 为空（相对/畸形 URL）时退回整条 url 作 key。
  static String remoteFailureCooldownKey(String url) {
    final String host = Uri.tryParse(url)?.host ?? '';
    return host.isNotEmpty ? host : url;
  }

  /// 该 url 对应的 host 是否仍处于失败冷却窗内。
  static bool isRemoteSourceInCooldown(String url) {
    final String key = remoteFailureCooldownKey(url);
    final DateTime? until = _remoteFailureCooldownUntil[key];
    if (until == null) return false;
    if (!_nowProvider().isBefore(until)) {
      // 冷却已过：清除条目，放行下一次尝试。
      _remoteFailureCooldownUntil.remove(key);
      return false;
    }
    return true;
  }

  /// 记录一次失败：把该 host 的冷却截止时间设为 now + [kRemoteAudioFailureCooldown]。
  static void _markRemoteSourceFailed(String url) {
    final String key = remoteFailureCooldownKey(url);
    _remoteFailureCooldownUntil[key] =
        _nowProvider().add(kRemoteAudioFailureCooldown);
  }

  /// 记录一次成功：清除该 host 的冷却条目，让它立即恢复优先级。
  static void _markRemoteSourceOk(String url) {
    _remoteFailureCooldownUntil.remove(remoteFailureCooldownKey(url));
  }

  /// 测试钩子：注入自定义时钟。传 null 恢复 [DateTime.now]。
  @visibleForTesting
  static void debugSetNowProvider(DateTime Function()? nowProvider) {
    _nowProvider = nowProvider ?? DateTime.now;
  }

  /// 测试钩子：清空冷却表，隔离用例之间的静态状态。
  @visibleForTesting
  static void debugResetRemoteFailureCooldown() {
    _remoteFailureCooldownUntil.clear();
  }

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
      // rethrow 让上层 resolveConfigured 把这次失败计入 host 冷却（TODO-1057）；
      // 日志已在此记过一次，冷却窗内 resolveConfigured 会短路不再重入此处，故不刷屏。
      rethrow;
    }
  }
}
