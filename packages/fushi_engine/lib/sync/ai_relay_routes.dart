/// `/api/ai/relay/*` 的 shelf 路由 + 主机开关（「允许已配对设备使用本机 AI」）。
///
/// wire 形状与语义见 `package:fushi_engine/ai/ai_relay.dart` 文件头。鉴权由
/// `FushiSyncServer` 的 middleware 统一做（与其它 `/api/*` 同一道门）。
library;

import 'dart:convert';

import 'package:fushi_engine/ai/ai_relay.dart';
import 'package:fushi_engine/foundation/pref_store.dart';
import 'package:shelf/shelf.dart' as shelf;

/// 主机开关的偏好键（设备本地，不随备份跨设备：「这台机器的 AI 额度给不给别的设备
/// 用」是这台机器主人的决定）。
const String kInterconnectAiRelayEnabledPref = 'interconnect_ai_relay_enabled';

/// 读主机开关。默认**开**：与「AI 下视频 / AI 助手整场交给主机办」同一口径——那两条
/// 路已经默认让已配对设备花本机的 AI 额度，这里只是把同一份能力开放给其余 AI 功能；
/// 对端不发请求就一次也不会调。不想分享的主人显式关掉。
bool readInterconnectAiRelayEnabled(PrefStore? prefs) {
  if (prefs == null) return true;
  final Object? raw = prefs.getPref(
    kInterconnectAiRelayEnabledPref,
    defaultValue: true,
  );
  if (raw is bool) return raw;
  // `preferences` 表存过字符串化的 bool（不同写入路径），读侧一并认。
  if (raw is String) return raw.toLowerCase() != 'false';
  return true;
}

shelf.Response _json(Map<String, Object?> body) => shelf.Response.ok(
  jsonEncode(body),
  headers: const <String, String>{'Content-Type': 'application/json'},
);

/// 处理一次 `/api/ai/relay/*` 请求。[enabled] 是此刻的主机开关（每个请求现读）。
Future<shelf.Response> handleAiRelayRequest(
  AiRelayHostService service,
  shelf.Request request,
  String method,
  String reqPath, {
  required bool enabled,
}) async {
  if (reqPath != kAiRelayProvidersPath && reqPath != kAiRelayChatPath) {
    return shelf.Response.notFound('Unknown AI relay route');
  }
  if (method != 'POST') return shelf.Response(405);
  if (!enabled) {
    return _json(const <String, Object?>{
      'ok': false,
      'error': kAiRelayDisabled,
    });
  }
  final Map<String, Object?> body;
  try {
    final String text = await request.readAsString();
    final Object? decoded = text.trim().isEmpty
        ? <String, Object?>{}
        : jsonDecode(text);
    if (decoded is! Map) throw const FormatException('object body required');
    body = decoded.cast<String, Object?>();
  } on FormatException {
    return _json(const <String, Object?>{
      'ok': false,
      'error': kAiRelayBadRequest,
    });
  }
  if (reqPath == kAiRelayProvidersPath) {
    return _json(service.providersReply());
  }
  try {
    return _json(await service.chatReply(body));
  } on FormatException {
    return _json(const <String, Object?>{
      'ok': false,
      'error': kAiRelayBadRequest,
    });
  }
}
