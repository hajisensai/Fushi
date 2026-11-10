import 'package:flutter/rendering.dart';

/// [paragraph] 实际排出的行数。
///
/// `RenderParagraph` 不公开行度量（`computeLineMetrics` 只在 [TextPainter] 上），所以
/// 这里用与它**同一组排版输入**（文本、方向、缩放、行数上限、strut、宽度基准、行高
/// 行为、locale）在它拿到的同一最大宽度上重排一次，读出行数。换行判定只取决于这些
/// 输入与最大宽度，与 render object 自己的排版逐行一致。
int renderedLineCount(RenderParagraph paragraph) {
  final TextPainter painter = TextPainter(
    text: paragraph.text,
    textAlign: paragraph.textAlign,
    textDirection: paragraph.textDirection,
    textScaler: paragraph.textScaler,
    maxLines: paragraph.maxLines,
    ellipsis: paragraph.overflow == TextOverflow.ellipsis ? '…' : null,
    locale: paragraph.locale,
    strutStyle: paragraph.strutStyle,
    textWidthBasis: paragraph.textWidthBasis,
    textHeightBehavior: paragraph.textHeightBehavior,
  );
  try {
    painter.layout(
      maxWidth: paragraph.softWrap
          ? paragraph.constraints.maxWidth
          : double.infinity,
    );
    return painter.computeLineMetrics().length;
  } finally {
    painter.dispose();
  }
}
