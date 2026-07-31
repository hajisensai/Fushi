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
/// 机制）。音频路径 [HibikiRemoteLookupClient.lookupAudioUrl] 与词典路径
/// [HibikiRemoteLookupClient.searchDictionary] 现在**对称**抛出：词典路径此前是
/// 全仓唯一不消费 `allUnreachable` 的调用点，导致配对设备离线时每次查词都要把
/// 「3s × 候选数」重付一遍（BUG-1302）。
class RemoteLookupUnreachableError implements Exception {
  RemoteLookupUnreachableError(this.message);

  final String message;

  @override
  String toString() => 'RemoteLookupUnreachableError: $message';
}

/// 远端**词典**查询在「全部配对候选传输层不可达」后的失败冷却窗（BUG-1302）。
///
/// 与音频源的 `kRemoteAudioFailureCooldown`（45s，`word_audio_resolver.dart`）同
/// 量级同语义：设备被证实死了之后，冷却窗内不再重复付「3s × 候选数」的连接超时。
/// 设备活着时行为完全不变——冷却只由 [RemoteLookupUnreachableError] 触发，
/// 「可达但无结果」不进冷却。
const Duration kRemoteDictionaryFailureCooldown = Duration(seconds: 45);

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

  /// 查远端词典。三种结局（与 [lookupAudioUrl] 对称）：
  /// - 返回结果：某候选可达且有词条；
  /// - 返回 null：可达但无结果（含 404/405/非 2xx/空结果），或根本未配对；
  /// - 抛 [RemoteLookupUnreachableError]：所有已启用候选全部传输层失败
  ///   （连接拒绝/超时/DNS）——「配对设备死了」，供上层计入失败冷却。
  ///
  /// 为什么词典路径也必须抛（BUG-1302）：远端查词排在本地缓存**之前**
  /// （`AppModel.searchDictionary` 的 remote-first 语义），配对设备离线/换网/
  /// 休眠时每次查词都要把「3s × 候选数」全额付一遍，且因为短路在缓存之前，
  /// 重复查同一个词也不例外——这正是用户报的「某些机器上查词要 4-5 秒」。
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
    if (outcome.allUnreachable) {
      throw RemoteLookupUnreachableError(
        'all enabled paired candidates failed at the transport layer '
        '(connection refused / timeout / DNS) for /api/lookup/dictionary',
      );
    }
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
