/// 网页经 JS handler 投给 Dart 的载荷的统一长度上限。
///
/// 这些载荷来自站点页面（不可信）：一个恶意 / 出错的页面可以投几百 MB 的字符串或
/// 极深的嵌套，Dart 侧的解析、落库、交给 Rust 都会被它拖垮。每个 handler 按自己
/// 正常载荷的量级给一个上限，统一在注册处经 [limitWebPayload] 包一层：超限的整条
/// 丢弃（返回 null、记一行日志），不截断——截半的载荷比没有更糟。
library;

import 'package:fushi/src/utils/misc/error_log_service.dart';

/// 按键令牌等小信令。
const int kWebPayloadTinyMaxChars = 1024;

/// URL、选区文本、cosmetic 请求这类单条文本。
const int kWebPayloadSmallMaxChars = 256 * 1024;

/// adblock 的 classes / ids 整批、扫图结果（图片 URL 列表）。
const int kWebPayloadMediumMaxChars = 2 * 1024 * 1024;

/// 网页视频：整集字幕轨、Netflix 剧集 metadata 原文。
const int kWebPayloadLargeMaxChars = 16 * 1024 * 1024;

/// 嵌套深度上限（正常载荷不超过 4 层）。
const int kWebPayloadMaxDepth = 32;

/// [value] 的近似体积（字符数）是否不超过 [maxChars]，且嵌套不超过 [maxDepth]。
///
/// 字符串按长度、数字 / 布尔按 8、map 的键值都计入；超限立即返回，不把整棵树走完。
bool webPayloadWithinLimit(
  Object? value, {
  required int maxChars,
  int maxDepth = kWebPayloadMaxDepth,
}) {
  int budget = maxChars;
  bool visit(Object? node, int depth) {
    if (depth > maxDepth) return false;
    if (node is String) {
      budget -= node.length;
    } else if (node is Map) {
      for (final MapEntry<Object?, Object?> e in node.entries) {
        if (!visit(e.key, depth + 1) || !visit(e.value, depth + 1)) {
          return false;
        }
      }
      budget -= 2;
    } else if (node is Iterable) {
      for (final Object? item in node) {
        if (!visit(item, depth + 1)) return false;
      }
      budget -= 2;
    } else {
      budget -= 8;
    }
    return budget >= 0;
  }

  return visit(value, 0);
}

/// 给一个 JS handler 回调套上长度上限：超限的调用不进 [callback]，直接回 null。
dynamic Function(List<dynamic>) limitWebPayload(
  String handlerName,
  int maxChars,
  dynamic Function(List<dynamic> args) callback,
) => (List<dynamic> args) {
  if (!webPayloadWithinLimit(args, maxChars: maxChars)) {
    ErrorLogService.instance.log(
      'WebPayloadLimit.$handlerName',
      'dropped an oversized web payload (limit $maxChars chars)',
      StackTrace.current,
    );
    return null;
  }
  return callback(args);
};
