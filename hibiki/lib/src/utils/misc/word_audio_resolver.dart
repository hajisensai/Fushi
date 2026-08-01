import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/models/audio_source_config.dart';
import 'package:hibiki/src/sync/hibiki_remote_lookup_client.dart'
    show RemoteLookupUnreachableError;
import 'package:hibiki/src/utils/misc/error_log_service.dart';
import 'package:hibiki/src/utils/misc/local_audio_db.dart'
    show LocalAudioUnavailableError;

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

  /// hibikiRemote（互联配对）源在失败冷却表里的固定 key：配对候选是一组设备
  /// 地址、整体成败一体，不按单个候选 host 拆分冷却。
  static const String hibikiRemoteCooldownKey = 'hibiki-remote';

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
        final String? remote = await _queryRemoteLegacy(expression, reading);
        if (remote != null && remote.isNotEmpty) return remote;
        continue;
      }
      if (template == hibikiRemoteAudioUrl) {
        final String? remote = await _queryRemoteLegacy(expression, reading);
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
          final RemoteAudioQuery? query = queryRemoteAudio;
          if (query == null) continue;
          // 与 remoteAudio 源同一套失败冷却（TODO-1057/BUG-488）：配对设备上次
          // 全部不可达且仍在冷却窗内则直接短路——不发请求、不再记日志，也不让
          // 死配对每次查词硬等 N 个候选 × 超时。
          if (isRemoteSourceInCooldown(hibikiRemoteCooldownKey)) {
            continue;
          }
          final String? remote;
          try {
            remote = await query(expression, reading);
          } on RemoteLookupUnreachableError {
            // 传输层确认全部候选不可达（AppModel 已记过一次日志）：计入冷却并
            // 跳到下一源；「可达但无音频」返回 null，不走这里。
            _markRemoteSourceFailed(hibikiRemoteCooldownKey);
            continue;
          }
          // 成功抵达（含合法「无音频」null）：清除冷却，恢复其优先级。
          _markRemoteSourceOk(hibikiRemoteCooldownKey);
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

  /// 传统 [resolve] 路径的远端查询：保持既有「失败即跳过」语义——配对设备不可
  /// 达（[RemoteLookupUnreachableError]）吞成 null 继续下一源，不记冷却（冷却
  /// 只由 [resolveConfigured] 管理，与 remoteAudio 源的既有分工一致）。
  Future<String?> _queryRemoteLegacy(String expression, String reading) async {
    try {
      return await queryRemoteAudio?.call(expression, reading);
    } on RemoteLookupUnreachableError {
      return null;
    }
  }

  Future<String?> _resolveLocal(String expression, String reading) async {
    try {
      final Map<String, dynamic>? info =
          await queryLocalAudio(expression, reading);
      return await _extractLocal(info);
    } on LocalAudioUnavailableError catch (e, stack) {
      _logLocalAudioUnavailable(e, stack, expression);
      return null;
    }
  }

  Future<String?> _resolveLocalAt(
    String expression,
    String reading,
    int dbIndex,
  ) async {
    try {
      final Map<String, dynamic>? info =
          await queryLocalAudioByDbIndex(expression, reading, dbIndex);
      return await _extractLocal(info, fallbackDbIndex: dbIndex);
    } on LocalAudioUnavailableError catch (e, stack) {
      _logLocalAudioUnavailable(e, stack, expression);
      return null;
    }
  }

  /// 本地库这次**没答上**（撞锁 / 查询预算耗尽）：与「库里真没这个词」是两回事。
  ///
  /// BUG-1413：旧实现下这两件事都是一个裸 `null`，`resolveConfigured` 只能一视同仁
  /// 跳到下一源，最终用户看到「暂无发音」，且**整条链一条日志都没有**（500ms 预算
  /// 先于库自己的 3s `busy_timeout` 到点，sqlite 的异常压根没机会抛出来）。现在记一条
  /// 用户可见的错误日志（设置 → 诊断 → 错误日志），再跳下一源。
  ///
  /// 刻意**不**做重试、**不**计入 [_markRemoteSourceFailed] 那套失败冷却：冷却是给
  /// 「连不上的死源」设计的，而本地库忙是瞬态的（绑定期建索引结束就恢复）——把一个
  /// 马上就能用的库额外禁用 45s，等于把小问题放大成「这段时间该库全哑」。
  static void _logLocalAudioUnavailable(
    LocalAudioUnavailableError e,
    StackTrace stack,
    String expression,
  ) {
    ErrorLogService.instance.log(
      'WordAudioResolver.localAudio 本地音频库未能应答'
      '（$expression / ${e.reason.name}）：本次跳过该库，'
      '这不代表库里没有这个词的发音',
      e,
      stack,
    );
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

  /// 测试钩子：读/换 [defaultFetchAudioSourceList] 底层 [_dio] 的 HTTP 适配器，
  /// 以便用例注入可控 HTTP 响应（如 404）验证 badResponse 归一为空结果（TODO-1265）。
  /// 生产代码从不调用；用例须在 tearDown 里还原原适配器，避免串味。
  @visibleForTesting
  static HttpClientAdapter get debugHttpClientAdapter => _dio.httpClientAdapter;

  @visibleForTesting
  static set debugHttpClientAdapter(HttpClientAdapter adapter) {
    _dio.httpClientAdapter = adapter;
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
      // TODO-1265 根因修：`badResponse`＝服务器**可达**并回了一个非 2xx（最典型是 404
      // ——「这个源没有这个词的发音」），与 200 空 audioSources 语义完全相同，只是端点
      // 用 HTTP 状态而非空列表表达「没有」。**绝不能把它当死源失败**：BUG-488 的冷却
      // 是为「连不上的死源」（连接拒绝/超时/DNS）设计的；把可达源因某个词缺音频而
      // host 级冷却 45s，会让**这个源有音频的其它词也一起没声音**（回归：查一个源没有
      // 的词后，整段时间里该源全哑）。故 badResponse 直接当空结果返回：不记错误日志、
      // 不 rethrow → resolveConfigured 不冷却、继续下一源、该源对下个词仍可用。
      if (e is DioError && e.type == DioErrorType.badResponse) {
        return const <String>[];
      }
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
      // 仅剩连接级失败（不可达/超时/DNS）走到这里——正是 BUG-488 要冷却的死源。
      rethrow;
    }
  }
}
