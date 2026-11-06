import 'package:flutter/foundation.dart' show Key;

/// `LibrarySectionTabs` 的一段：值 + 用户可读标签。
class LibrarySectionTab<T> {
  const LibrarySectionTab({
    required this.value,
    required this.label,
    this.labelKey,
    this.orderId,
  });

  final T value;
  final String label;

  /// 用户自定义顺序里这一段的稳定身份（见 `LibrarySectionTabs.orderKey`）。值
  /// 会随状态变的段（如「在线源」组页签的值是组内上次停留的分区）必须给；
  /// null = 用 `value.toString()`。
  final String? orderId;

  /// 挂在这一段文字上的稳定 key（测试 / 焦点驱动按 id 命中某段，不依赖文案）；
  /// null 不挂。
  final Key? labelKey;
}
