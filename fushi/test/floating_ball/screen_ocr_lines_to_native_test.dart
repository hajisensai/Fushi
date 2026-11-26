import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/floating_ball/floating_ball_channel.dart';
import 'package:fushi/src/ocr/system_ocr_channel.dart';

/// BUG-5494：Android 应用外截屏识字走本机模型 / Google Lens 时，行从 Dart 回原生选取层。
/// 此前只下发行框、不带块，原生每行自成一块，查词窗没有续文，词在 OCR 折行处被截断
/// （反馈 XDdY8NuGkk：「見破れ / る…！？」）。现在按与桌面同一条行框聚合规则把块全文、
/// 偏移、块框随行下发。
void main() {
  SystemOcrTextLine h(String text, double l, double t, double r, double b) =>
      SystemOcrTextLine(
        text: text,
        rect: Rect.fromLTRB(l, t, r, b),
        isVertical: false,
      );

  test('wrapped lines carry the shared block text, offset and box', () {
    // 行头禁则把「る…！？」推到下一行，上一行行尾留白：行框比下一行短。
    final List<Map<String, Object?>> wire =
        screenOcrLinesToNative(<SystemOcrTextLine>[
          h('……っ、まさか見破れ', 40, 300, 800, 350),
          h('る…！？　そんな', 40, 360, 1000, 410),
          h('別の段落', 40, 900, 400, 950),
        ]);
    expect(wire, hasLength(3));
    const String block = '……っ、まさか見破れ\nる…！？　そんな';
    expect(wire[0]['blockText'], block);
    expect(wire[0]['blockOffset'], 0);
    expect(wire[0]['blockRect'], <int>[40, 300, 1000, 410]);
    expect(wire[1]['blockText'], block);
    expect(wire[1]['blockOffset'], '……っ、まさか見破れ\n'.length);
    expect(wire[2]['blockText'], '別の段落');
    expect(wire[2]['blockOffset'], 0);
    expect(wire[2]['blockRect'], <int>[40, 900, 400, 950]);
    // 下发的块全文在偏移处就是本行原文（原生据此校验）。
    for (final Map<String, Object?> line in wire) {
      final String text = line['text']! as String;
      final String blockText = line['blockText']! as String;
      expect(blockText.startsWith(text, line['blockOffset']! as int), isTrue);
    }
  });

  test('dropped lines never join a block', () {
    final List<Map<String, Object?>> wire = screenOcrLinesToNative(
      <SystemOcrTextLine>[
        h('上の行', 40, 300, 400, 350),
        h('', 40, 360, 400, 410),
        h('無面積', 40, 360, 40, 410),
      ],
    );
    expect(wire, hasLength(1));
    expect(wire[0]['blockText'], '上の行');
  });
}
