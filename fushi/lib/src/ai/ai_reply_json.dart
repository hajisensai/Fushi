/// 从模型回复里抠 JSON 的共享工具。
///
/// 每个 AI 功能都让模型「只回一个 JSON 对象」，但模型常见的两种不听话——整段裹在
/// ```json 围栏里、JSON 前后带解释性散文——所有功能都得容忍。抽到这里避免每个
/// 助手各抄一份平衡括号扫描器。
library;

import 'dart:convert';

/// 从回复里抠出第一个平衡的 JSON 对象文本；找不到返回 null。
///
/// 字符串字面量内的花括号不计数（`"{"` 之类），转义引号也处理。
String? extractAiJsonObject(String reply) {
  final int start = reply.indexOf('{');
  if (start < 0) {
    return null;
  }
  int depth = 0;
  bool inString = false;
  bool escaped = false;
  for (int i = start; i < reply.length; i += 1) {
    final String ch = reply[i];
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (ch == r'\') {
        escaped = true;
      } else if (ch == '"') {
        inString = false;
      }
      continue;
    }
    if (ch == '"') {
      inString = true;
    } else if (ch == '{') {
      depth += 1;
    } else if (ch == '}') {
      depth -= 1;
      if (depth == 0) {
        return reply.substring(start, i + 1);
      }
    }
  }
  return null;
}

/// [extractAiJsonObject] + `jsonDecode`，任何一步失败或结果不是对象都返回 null。
///
/// 调用方拿到的永远是 `Map<String, Object?>`，不用再各自 `is! Map` 一遍。
Map<String, Object?>? decodeAiJsonObject(String reply) {
  final String? text = extractAiJsonObject(reply);
  if (text == null) {
    return null;
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException {
    return null;
  }
  if (decoded is! Map) {
    return null;
  }
  return decoded.map<String, Object?>(
    (Object? key, Object? value) => MapEntry<String, Object?>('$key', value),
  );
}
