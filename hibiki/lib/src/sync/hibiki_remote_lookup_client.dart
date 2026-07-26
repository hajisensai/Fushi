import 'dart:convert';

import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki/src/sync/tls/hibiki_pinning_http.dart';
import 'package:hibiki/src/sync/webdav_ops.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';
import 'package:http/http.dart' as http;

/// 互联配对查询：本次调用尝试了至少一个已启用候选地址，但**没有任何一个候选
/// 返回过 HTTP 响应**（连接拒绝 / 超时 / DNS 解析失败等传输层失败）——即
/// 「配对设备不可达」。与「设备可达但没有这个词的结果」（返回 null，含
/// 404/405/非 2xx/正常空结果）在传输层严格区分，供上层（WordAudioResolver）
/// 对 hibiki-remote 音频源做失败冷却（对齐 remoteAudio 源的 TODO-1057/BUG-488
/// 机制）。目前只有音频路径 [HibikiRemoteLookupClient.lookupAudioUrl] 抛出；
/// 词典路径 [HibikiRemoteLookupClient.searchDictionary] 行为零变化。
class RemoteLookupUnreachableError implements Exception {
  RemoteLookupUnreachableError(this.message);

  final String message;

  @override
  String toString() => 'RemoteLookupUnreachableError: $message';
}

/// [HibikiRemoteLookupClient._postLookup] 的结局：`json` 为拿到并解析成功的响应
/// 体；`allUnreachable` 仅当「至少发起过一次请求且所有候选都没拿到任何 HTTP
/// 响应」时为 true——未配对/无 token/候选 URL 全畸形都不算不可达。
typedef _PostLookupOutcome = ({
  Map<String, dynamic>? json,
  bool allUnreachable
});

class HibikiRemoteLookupClient {
  HibikiRemoteLookupClient({
    required SyncRepository repo,
    http.Client? httpClient,
    http.Client Function(String expectedFingerprint)? pinnedClientFactory,
    Duration timeout = const Duration(seconds: 3),
  })  : _repo = repo,
        _httpClient = httpClient ?? http.Client(),
        _pinnedClientFactory = pinnedClientFactory ?? _defaultPinnedClient,
        _timeout = timeout;

  final SyncRepository _repo;

  /// 明文 http 候选共用的 client（生产由 AppModel 注入 keep-alive client 复用连接，
  /// TODO-744）。**绝不**用于带指纹的 https 候选——那必须走钉扎 client
  /// （TODO-961 gap①：注入生产 client 不得旁路证书钉扎）。
  final http.Client _httpClient;

  /// https 候选的钉扎 client 工厂（每候选一个、用完即关）。默认真钉扎
  /// [createPinnedHttpPackageClient]；测试注入 MockClient 工厂即可拦截。
  final http.Client Function(String expectedFingerprint) _pinnedClientFactory;
  final Duration _timeout;

  static http.Client _defaultPinnedClient(String expectedFingerprint) =>
      createPinnedHttpPackageClient(expectedFingerprint: expectedFingerprint);

  Future<DictionarySearchResult?> searchDictionary({
    required String term,
    required bool wildcards,
    required int maximumTerms,
  }) async {
    final _PostLookupOutcome outcome = await _postLookup(
      path: '/api/lookup/dictionary',
      body: <String, dynamic>{
        'term': term,
        'wildcards': wildcards,
        'maximumTerms': maximumTerms,
      },
    );
    // 词典路径不消费 allUnreachable：失败面维持原样（返回 null），零行为变化。
    final Map<String, dynamic>? json = outcome.json;
    if (json == null || json['type'] != 'dictionaryResult') return null;
    final dynamic resultJson = json['result'];
    if (resultJson is! Map) return null;
    final DictionarySearchResult result =
        _parseDictionaryResult(Map<String, dynamic>.from(resultJson));
    result.popupJson = json['popupJson']?.toString();
    return result.entries.isEmpty ? null : result;
  }

  DictionarySearchResult _parseDictionaryResult(Map<String, dynamic> json) {
    final List<DictionaryEntry> entries = <DictionaryEntry>[];
    final dynamic entriesJson = json['entries'];
    if (entriesJson is List) {
      for (final dynamic entry in entriesJson) {
        if (entry is String) {
          entries.add(DictionaryEntry.fromJson(entry));
        } else if (entry is Map) {
          entries.add(DictionaryEntry.fromJson(jsonEncode(entry)));
        }
      }
    }
    return DictionarySearchResult(
      searchTerm: json['searchTerm']?.toString() ?? '',
      bestLength: (json['bestLength'] as num?)?.toInt() ?? 0,
      scrollPosition: (json['scrollPosition'] as num?)?.toInt() ?? 0,
      entries: entries,
    );
  }

  /// 查远端单词音频。三种结局：
  /// - 返回 URL：某候选可达且有音频；
  /// - 返回 null：可达但无音频（含 404/405/非 2xx/正常空结果），或根本未配对；
  /// - 抛 [RemoteLookupUnreachableError]：所有已启用候选全部传输层失败
  ///   （连接拒绝/超时/DNS）——「配对设备死了」，供上层计入失败冷却。
  Future<String?> lookupAudioUrl({
    required String expression,
    required String reading,
  }) async {
    final _PostLookupOutcome outcome = await _postLookup(
      path: '/api/lookup/audio',
      body: <String, dynamic>{
        'expression': expression,
        'reading': reading,
      },
    );
    if (outcome.allUnreachable) {
      throw RemoteLookupUnreachableError(
        'all enabled paired candidates failed at the transport layer '
        '(connection refused / timeout / DNS) for /api/lookup/audio',
      );
    }
    final Map<String, dynamic>? json = outcome.json;
    if (json == null || json['type'] != 'audioResult') return null;
    final String? url = json['url'] as String?;
    return (url == null || url.isEmpty) ? null : url;
  }

  Future<_PostLookupOutcome> _postLookup({
    required String path,
    required Map<String, dynamic> body,
  }) async {
    final List<HibikiClientUrl> candidates = (await _repo.getHibikiClientUrls())
        .where((HibikiClientUrl u) => u.enabled)
        .toList(growable: false);
    final String? token = await _repo.getHibikiClientToken();
    if (candidates.isEmpty || token == null || token.isEmpty) {
      // 未配对/未启用/无 token：不是「设备不可达」，按「无结果」处理。
      return (json: null, allUnreachable: false);
    }

    bool attempted = false;
    bool anyResponse = false;
    for (final HibikiClientUrl candidate in candidates) {
      final Uri? uri = _lookupUri(candidate.url, path);
      if (uri == null) continue;
      // TODO-961 M1/gap①: https 带指纹的候选**始终**走钉扎 client，与是否注入了
      // 外部 client 无关（注入的 keep-alive client 只服务明文 http 候选，行为零变化）。
      final String? fp = candidate.fingerprintSha256;
      final bool usePinned =
          uri.isScheme('https') && fp != null && fp.isNotEmpty;
      final http.Client client =
          usePinned ? _pinnedClientFactory(fp) : _httpClient;
      attempted = true;
      try {
        final http.Response response = await client
            .post(
              uri,
              headers: <String, String>{
                'Authorization':
                    'Basic ${base64Encode(utf8.encode('hibiki:$token'))}',
                'Content-Type': 'application/json',
              },
              body: jsonEncode(body),
            )
            .timeout(_timeout);
        // 拿到任何 HTTP 响应（含 401/404/405/非 2xx/坏 JSON 体）都算「可达」；
        // 传输层失败（连接拒绝/超时/DNS）根本走不到这一行，落在 catch 里。
        anyResponse = true;
        if (response.statusCode == 401) {
          throw SyncAuthError('Hibiki server rejected remote lookup token');
        }
        if (response.statusCode == 404 || response.statusCode == 405) {
          continue;
        }
        if (response.statusCode < 200 || response.statusCode >= 300) {
          continue;
        }
        final dynamic decoded = jsonDecode(response.body);
        if (decoded is Map<String, dynamic>) {
          return (json: decoded, allUnreachable: false);
        }
        if (decoded is Map) {
          return (
            json: Map<String, dynamic>.from(decoded),
            allUnreachable: false,
          );
        }
      } on SyncAuthError {
        rethrow;
      } catch (_) {
        continue;
      } finally {
        // 每候选独立 pinned client 用完即关，所有出口（return/continue/throw）统一
        // 经 finally 回收，不泄漏 socket；共享 _httpClient 绝不在此关闭。
        if (usePinned) client.close();
      }
    }
    // 走到这里没有任何候选给出可用结果；只有「试过且一个响应都没拿到」才算
    // 全部不可达（传输层失败），可达但无结果仍是普通 null。
    return (json: null, allUnreachable: attempted && !anyResponse);
  }

  Uri? _lookupUri(String baseUrl, String path) {
    try {
      final Uri base = Uri.parse(WebDavOps.normalizeUrl(baseUrl));
      return base
          .replace(path: path, queryParameters: const <String, String>{});
    } catch (_) {
      return null;
    }
  }
}
