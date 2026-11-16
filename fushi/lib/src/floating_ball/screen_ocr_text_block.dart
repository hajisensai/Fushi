/// 只有行框的截屏识字结果（Windows.Media.Ocr / Vision / 本机模型 / Google Lens）里，
/// 被点那一行所在的**文本块**：卡图裁哪块（反馈 Gz7z6Y6Mbr）、查词串与制卡句子跨到
/// 哪几行（BUG-4707）都按这里的同一套聚合规则，规则只写一处。
///
/// Android 截屏识字有 ML Kit 的 text block，块由原生给（`ScreenOcrLayout.blockText`），
/// 不走这里；块全文的格式（块内各行按 `\n` 拼接）两边一致，后续截句 / 拼续文都交给
/// `ocr_block_sentence.dart`。
library;

import 'dart:math' as math;
import 'dart:ui' show Rect;

import 'package:fushi/src/lookup/ocr_block_sentence.dart';
import 'package:fushi/src/ocr/system_ocr_channel.dart' show SystemOcrTextLine;

/// 一行 OCR 结果在聚合规则眼里的样子（像素框 + 是否竖排）。
typedef ScreenOcrLineBox = ({Rect rect, bool vertical});

/// 把被点行 [hitIndex] 和与它同一段文字的行并成文本块，返回块内各行下标（按阅读
/// 顺序：横排从上到下，竖排从右到左）：同向、粗细相近（0.6~1.6 倍）、在排列方向上
/// 相邻（行距不超过一个行粗）、在阅读方向上有重叠。逐步扩张，直到没有新行加入。
List<int> screenOcrTextBlockMembers({
  required List<ScreenOcrLineBox> lines,
  required int hitIndex,
}) {
  final ScreenOcrLineBox hit = lines[hitIndex];
  final bool vertical = hit.vertical;
  double thickness(Rect r) => vertical ? r.width : r.height;
  final double base = thickness(hit.rect);
  final Set<int> members = <int>{hitIndex};
  Rect block = hit.rect;
  bool grew = true;
  while (grew) {
    grew = false;
    for (int i = 0; i < lines.length; i++) {
      if (members.contains(i)) continue;
      final ScreenOcrLineBox line = lines[i];
      if (line.vertical != vertical) continue;
      final double t = thickness(line.rect);
      if (base <= 0 || t < base * 0.6 || t > base * 1.6) continue;
      final Rect r = line.rect;
      // 排列方向上的间隙（横排看上下，竖排看左右）。
      final double gap = vertical
          ? math.max(r.left - block.right, block.left - r.right)
          : math.max(r.top - block.bottom, block.top - r.bottom);
      if (gap > base) continue;
      // 阅读方向上要有重叠（横排看左右，竖排看上下）。
      final double overlap = vertical
          ? math.min(r.bottom, block.bottom) - math.max(r.top, block.top)
          : math.min(r.right, block.right) - math.max(r.left, block.left);
      if (overlap <= 0) continue;
      members.add(i);
      block = block.expandToInclude(r);
      grew = true;
    }
  }
  final List<int> ordered = members.toList()
    ..sort((int a, int b) {
      final Rect ra = lines[a].rect;
      final Rect rb = lines[b].rect;
      final int byFlow = vertical
          ? rb.center.dx.compareTo(ra.center.dx)
          : ra.center.dy.compareTo(rb.center.dy);
      return byFlow != 0 ? byFlow : a.compareTo(b);
    });
  return ordered;
}

/// [screenOcrTextBlockMembers] 那几行的包围盒（像素）。
Rect screenOcrTextBlockRect({
  required List<ScreenOcrLineBox> lines,
  required int hitIndex,
}) {
  Rect? block;
  for (final int i in screenOcrTextBlockMembers(
    lines: lines,
    hitIndex: hitIndex,
  )) {
    block = block?.expandToInclude(lines[i].rect) ?? lines[i].rect;
  }
  return block ?? lines[hitIndex].rect;
}

/// 点中 [hit] 这一行第 [charIndex] 个 UTF-16 码元时交给查词的文字（BUG-4707）。
class ScreenOcrBlockLookup {
  const ScreenOcrBlockLookup({required this.text, required this.sentence});

  /// 被点行原文 + 块内后续行拼好的续文（[ocrBlockContinuationAfterLine]）。行原文是
  /// 它的前缀，所以行内的 UTF-16 下标（`charIndex`）在这里原样有效：从被点字起的
  /// 后缀可以跨过 OCR 折行，词不会在行尾被截断。
  final String text;

  /// 制卡 `{sentence}`：块里含被点字的整句（[ocrBlockSentenceAt]）；块太长截不出时
  /// 回落为被点行里的那一句（[ocrSentenceInLine]）。
  final String sentence;
}

/// 只有行框的平台点中 [lines] 里的 [hit] 行、行内 UTF-16 下标 [charIndex] 时，按
/// [screenOcrTextBlockMembers] 把它所在的文本块拼成块全文（块内各行按 `\n` 拼接，与
/// Android ML Kit 块同一格式），再交给 `ocr_block_sentence.dart` 拼续文、截整句。
ScreenOcrBlockLookup screenOcrBlockLookupForHit({
  required List<SystemOcrTextLine> lines,
  required SystemOcrTextLine hit,
  required int charIndex,
}) {
  final int hitIndex = lines.indexOf(hit);
  final List<SystemOcrTextLine> members = hitIndex < 0
      ? <SystemOcrTextLine>[hit]
      : <SystemOcrTextLine>[
          for (final int i in screenOcrTextBlockMembers(
            lines: <ScreenOcrLineBox>[
              for (final SystemOcrTextLine line in lines)
                (rect: line.rect, vertical: line.isVertical),
            ],
            hitIndex: hitIndex,
          ))
            lines[i],
        ];
  final StringBuffer block = StringBuffer();
  int offset = 0;
  for (final SystemOcrTextLine line in members) {
    if (block.isNotEmpty) block.write('\n');
    if (identical(line, hit)) offset = block.length;
    block.write(line.text);
  }
  final String blockText = block.toString();
  final String continuation = ocrBlockContinuationAfterLine(
    blockText,
    lineEnd: offset + hit.text.length,
  );
  return ScreenOcrBlockLookup(
    text: hit.text + continuation,
    sentence:
        ocrBlockSentenceAt(blockText, offset + charIndex) ??
        ocrSentenceInLine(hit.text, charIndex),
  );
}
