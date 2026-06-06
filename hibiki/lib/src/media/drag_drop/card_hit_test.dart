import 'package:flutter/widgets.dart' show Rect, Offset;

/// 一张卡片的屏幕矩形 + 其元数据。
class CardRect<T> {
  const CardRect({required this.rect, required this.meta});
  final Rect rect;
  final T meta;
}

/// 返回首个包含 [point] 的卡片 meta；都不包含返回 null。纯函数。
T? hitTestCards<T>(List<CardRect<T>> cards, Offset point) {
  for (final CardRect<T> card in cards) {
    if (card.rect.contains(point)) return card.meta;
  }
  return null;
}
