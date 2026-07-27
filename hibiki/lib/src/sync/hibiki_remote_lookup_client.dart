import 'dart:convert';

import 'package:hibiki/src/sync/interconnect_post_transport.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
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

class HibikiRemoteLookupClient {
  HibikiRemoteLookupClient({
    required SyncRepository repo,
    http.Client? httpClient,
    http.Client Function(String expectedFingerprint)? pinnedClientFactory,
    Duration timeout = const Duration(seconds: 3),
  })  : _transport = InterconnectPostTransport(
          repo: repo,
          httpClient: httpClient,
          pinnedClientFactory: pinnedClientFactory,
        ),
        _timeout = timeout;

  /// 候选轮询 / 鉴权 / 指纹钉扎 / socket 回收统一由 [InterconnectPostTransport]
  /// 承担——本类只管端点、超时与响应体的语义解析。
  final InterconnectPostTransport _transport;
  final Duration _timeout;

  Future<DictionarySearchResult?> searchDictionary({
    required String term,
    required bool wildcards,
    required int maximumTerms,
  }) async {
    final InterconnectPostOutcome outcome = await _postLookup(
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
    final InterconnectPostOutcome outcome = await _postLookup(
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

  Future<InterconnectPostOutcome> _postLookup({
    required String path,
    required Map<String, dynamic> body,
  }) {
    return _transport.post(
      path: path,
      body: body,
      timeout: _timeout,
      authErrorMessage: 'Hibiki server rejected remote lookup token',
    );
  }
}
