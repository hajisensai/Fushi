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
///
/// BUG-530：可选 [themeColorsProvider] 返回当前 app 主题的 CSS 变量 Map（`--md-*` /
/// `--hibiki-popup-*` / `--dict-columns`），随响应放进 `theme` 字段下发。浏览器扩展
/// content.js 读 `resp.data.theme` 并 `setProperty` 到弹窗容器 → 弹窗实时跟随用户主题
/// （改主题下次查词即变），无需重装扩展。null（未注入）时不带 `theme` 字段（向后兼容）。
Future<Map<String, dynamic>> buildRemoteDictionaryLookupResponse(
  Map<String, dynamic> body, {
  required HibikiRemoteLookupService lookup,
  HibikiRemoteHistoryService? history,
  Map<String, String> Function()? themeColorsProvider,
  List<String> Function()? audioSourcesProvider,
}) async {
  final Map<String, String>? theme = themeColorsProvider?.call();
  // 单词音频：把 app 当前已启用的音频源随查词响应下发，扩展 content.js 据此设
  // window.audioSources（非空 → popup.js 渲染 ♪ 按钮）。null（未注入，如 sync host）
  // 时不带该字段（向后兼容）。
  final List<String>? audioSources = audioSourcesProvider?.call();
  final String term = body['term']?.toString() ?? '';
  if (term.trim().isEmpty) {
    return <String, dynamic>{
      'type': 'dictionaryResult',
      'result': null,
      'popupJson': null,
      if (theme != null) 'theme': theme,
      if (audioSources != null) 'audioSources': audioSources,
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
    if (theme != null) 'theme': theme,
    if (audioSources != null) 'audioSources': audioSources,
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
  // TODO-1303：结果不再是裸字符串——摊开诊断（失败原因 / 音频落空警告）到响应体，
  // 让扩展 content.js 能 toast 显因、区分「真成功」与「卡建了但没音频」。返回类型仍是
  // Map（未改契约），只是多了可选 message/detail 字段（向后兼容：旧扩展忽略即可）。
  final RemoteMineResult r = payload.isImmersion
      ? await mining.mineImmersion(payload)
      : await mining.mineEntry(
          fields: payload.fields, sentence: payload.sentence);
  return <String, dynamic>{
    'result': r.result,
    if (r.message != null) 'message': r.message,
    if (r.detail != null) 'detail': r.detail,
  };
}

/// TODO-1176：`POST /api/duplicate` 的响应体。[body] 需含 `expression`（+可选 `reading`）。
/// 浏览器扩展查词弹窗渲染时调它，把制卡按钮从恒「+」变成与 app 一致的 `+`（未添加）/
/// `✓`（Anki 已有）两态。空 expression → 直接返回 `false`（不算错误，与查词空 term 一致）。
/// 经注入的 [mining].isDuplicate 复用 app 内同一 Anki 查重后端，单一真相源。
Future<Map<String, dynamic>> buildRemoteDuplicateResponse(
  Map<String, dynamic> body, {
  required HibikiRemoteMiningService mining,
}) async {
  final String expression = body['expression']?.toString() ?? '';
  final String reading = body['reading']?.toString() ?? '';
  if (expression.trim().isEmpty) {
    return <String, dynamic>{'duplicate': false};
  }
  final bool duplicate =
      await mining.isDuplicate(expression: expression, reading: reading);
  return <String, dynamic>{'duplicate': duplicate};
}
