import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/lookup/effective_lookup_size.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_layer.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_webview.dart';

import '../widgets/widget_test_helpers.dart';

/// BUG-823：查词弹窗顶栏（Flutter chrome）在窄宽时按钮重叠。
///
/// 旧实现把左端 A−/A+、**全宽居中**的 [headerWidget]（音频控制）、右端关闭三组用 [Stack]
/// 各自 [Align] 叠在同一水平带上——弹窗收窄到 [kLookupPopupMinWidth](250) 或 UI 缩放放大
/// 时，居中的音频行向两侧张开压到 A−/A+ 与关闭按钮上（重叠即设计）。修复分两处：
/// - [DictionaryPopupLayer] 顶栏改成一条 [Row]：左右按钮簇钉两端，header 夹在中段
///   [Expanded]/[Center] 的**有界宽度**里居中，Row 顺序排布天然不重叠；
/// - 音频行内部用 [FittedBox]`(scaleDown)` + `mainAxisSize.min`，窄宽下等比缩小不裁切。
void main() {
  // 模拟 reader 音频行：固定尺寸按钮 + 内部 FittedBox 收缩（与生产 header 同结构）。
  Widget shrinkableHeader() => const FittedBox(
        fit: BoxFit.scaleDown,
        child: SizedBox(
          key: Key('test-popup-header'),
          height: 40,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              SizedBox(width: 48, child: Icon(Icons.star_border)),
              SizedBox(width: 48, child: Icon(Icons.replay)),
              SizedBox(width: 48, child: Icon(Icons.play_arrow)),
              SizedBox(width: 48, child: Icon(Icons.play_circle_outline)),
            ],
          ),
        ),
      );

  Future<void> pumpLayer(WidgetTester tester, double width) async {
    await tester.pumpWidget(
      buildTestApp(
        Align(
          // 左上钉死，让 widget 屏幕坐标从 (0,0) 起，绝对边界断言可用。
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            height: 240,
            child: DictionaryPopupLayer(
              result: null,
              isSearching: false,
              webViewKey: GlobalKey<DictionaryPopupWebViewState>(),
              headerWidget: shrinkableHeader(),
              onClose: () {},
              onDismiss: () {},
              onTextSelected: (text, rect) {},
              onLinkClick: (query, rect) {},
              onMineEntry: (fields) async => const MinePopupResult(),
              onDuplicateCheck: (expression, reading) async => false,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets(
      'narrow popup top bar keeps font buttons, header and close from '
      'overlapping (BUG-823)', (WidgetTester tester) async {
    // 最窄合法宽度（弹窗尺寸下限）——旧 Stack 在此宽必重叠。
    await pumpLayer(tester, kLookupPopupMinWidth);

    // header 内部 FittedBox 收缩，绝不横向溢出/裁切（无 RenderFlex overflow）。
    expect(tester.takeException(), isNull);

    Rect rectOf(Finder finder) {
      expect(finder, findsOneWidget, reason: '守卫需要唯一命中：$finder');
      return tester.getRect(finder);
    }

    final Rect zoomOut = rectOf(find.byIcon(Icons.text_decrease));
    final Rect zoomIn = rectOf(find.byIcon(Icons.text_increase));
    final Rect close = rectOf(find.byIcon(Icons.close));
    final Rect header = rectOf(find.byKey(const Key('test-popup-header')));

    // 左簇（A−/A+）整体在 header 左侧、右端关闭在 header 右侧——三者不水平重叠。
    final double leftClusterRight =
        zoomOut.right > zoomIn.right ? zoomOut.right : zoomIn.right;
    expect(
      leftClusterRight,
      lessThanOrEqualTo(header.left + 0.5),
      reason: 'A−/A+ 字号按钮不得压到居中 header（BUG-823 重叠）。',
    );
    expect(
      header.right,
      lessThanOrEqualTo(close.left + 0.5),
      reason: '居中 header 不得压到右端关闭按钮（BUG-823 重叠）。',
    );

    // header 收缩后仍在弹窗宽度内（未越界）。
    expect(header.left, greaterThanOrEqualTo(-0.5));
    expect(header.right, lessThanOrEqualTo(kLookupPopupMinWidth + 0.5));
  });

  test(
      'reader audio header shrinks to fit instead of clipping/overlapping '
      '(BUG-823)', () {
    // 源码守卫：reader 音频行必须内部 FittedBox(scaleDown) + mainAxisSize.min，窄宽等比
    // 缩小而非裁切/溢出。弹窗跑真 WebView 无法 headless 全量挂，故锁源码契约。
    final String src = File(
      'lib/src/pages/implementations/reader_hibiki_page.dart',
    ).readAsStringSync();
    final int start = src.indexOf('Widget? buildPopupAudioControls()');
    expect(start, isNonNegative,
        reason: 'buildPopupAudioControls 必须存在（顶栏 header 构建入口）。');
    final int end = src.indexOf('// ── Helpers', start);
    expect(end, greaterThan(start));
    final String fn = src.substring(start, end);

    expect(
      fn.contains('FittedBox('),
      isTrue,
      reason: '音频行须用 FittedBox 在窄宽下等比缩小（BUG-823）。',
    );
    expect(
      fn.contains('fit: BoxFit.scaleDown'),
      isTrue,
      reason: 'FittedBox 须 scaleDown：够宽不放大、太窄才缩（BUG-823）。',
    );
    expect(
      fn.contains('mainAxisSize: MainAxisSize.min'),
      isTrue,
      reason: '音频行须 mainAxisSize.min，FittedBox 才能量到有限内在宽（BUG-823）。',
    );
  });
}
