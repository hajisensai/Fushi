import 'dart:convert';

import 'package:hibiki_dictionary/hibiki_dictionary.dart';

import 'package:hibiki/src/sync/hibiki_remote_lookup_service.dart';
import 'package:hibiki/src/sync/immersion_mine_payload.dart';

/// TODO-1000（BUG-530）：浏览器扩展 / 外部工具的两个远端 API（查词 `/api/lookup/dictionary`
/// + 制卡 `/api/mine`）的**共享 handler 逻辑**。HibikiSyncServer（互联/同步 host）与
/// YomitanApiServer（外部工具 API surface）都复用这里，保证扩展契约是**单一真相源**——
/// 历史 bug 正是两个 server 契约分裂：扩展被自动配置指向 YomitanApiServer（19633），但
/// 这两个端点当时只在 HibikiSyncServer 实现，导致 Netflix 查词/制卡全断。
///
/// 纯逻辑（已解析的 body Map → 调注入的窄接口 service → 返回响应 Map），不碰 shelf/HTTP，
/// 便于单测、便于两个 server 各自套自己的路由/鉴权外壳。

/// `POST /api/lookup/dictionary` 的响应体。[body] 是已解析的 JSON Map。
/// term 为空 → 返回空结果（与既有契约一致，不算错误）。
Future<Map<String, dynamic>> buildRemoteDictionaryLookupResponse(
  Map<String, dynamic> body, {
  required HibikiRemoteLookupService lookup,
  HibikiRemoteHistoryService? history,
}) async {
  final String term = body['term']?.toString() ?? '';
  if (term.trim().isEmpty) {
    return <String, dynamic>{
      'type': 'dictionaryResult',
      'result': null,
      'popupJson': null,
    };
  }
  final bool wildcards = body['wildcards'] as bool? ?? false;
  final int maximumTerms = (body['maximumTerms'] as num?)?.toInt() ?? 10;
  final DictionarySearchResult? result = await lookup.searchDictionary(
    term: term,
    wildcards: wildcards,
    maximumTerms: maximumTerms,
  );
  if (result != null && history != null && (body['record'] as bool? ?? false)) {
    history.recordHistory(result);
  }
  return <String, dynamic>{
    'type': 'dictionaryResult',
    'result': result == null ? null : jsonDecode(result.toJson()),
    'popupJson': result?.popupJson,
  };
}

/// `POST /api/mine` 的响应体。[body] 是已解析的 JSON Map，必须含 `fields`（Map）。
/// 带截图/时间戳/clip 的沉浸挖词走 [HibikiRemoteMiningService.mineImmersion]（引擎在实现方，
/// 这里只转发解析好的 payload）；纯 `{fields,sentence}` 走 [HibikiRemoteMiningService.mineEntry]
/// 回落（向后兼容浏览器扩展纯文本挖词 + 移动端）。
/// fields 缺失/类型错时 [ImmersionMinePayload.fromJson] 抛 [FormatException]，由调用方转 400。
Future<Map<String, dynamic>> buildRemoteMineResponse(
  Map<String, dynamic> body, {
  required HibikiRemoteMiningService mining,
}) async {
  final ImmersionMinePayload payload = ImmersionMinePayload.fromJson(body);
  final String result = payload.isImmersion
      ? await mining.mineImmersion(payload)
      : await mining.mineEntry(
          fields: payload.fields, sentence: payload.sentence);
  return <String, dynamic>{'result': result};
}
