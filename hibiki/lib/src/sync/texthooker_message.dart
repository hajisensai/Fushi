import 'dart:convert';

/// 解析 texthooker WS 消息。生态事实标准（Renji-XD/texthooker-ui socket.ts）：
/// `JSON.parse(d).sentence || d` —— 对象含 string 型 sentence 时取之，
/// 否则（裸文本 / 非法 JSON / 无 sentence / sentence 非字符串）原样返回。
String parseTexthookerMessage(String raw) {
  try {
    final dynamic decoded = jsonDecode(raw);
    if (decoded is Map) {
      final dynamic sentence = decoded['sentence'];
      if (sentence is String) return sentence;
    }
  } catch (_) {
    // 非法 JSON：当作裸文本原样返回。
  }
  return raw;
}
