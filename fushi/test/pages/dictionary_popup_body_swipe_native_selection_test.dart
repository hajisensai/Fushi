import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_layer.dart';
import 'package:material_ui/material_ui.dart';

/// BUG-4911（反馈 DrV7fPpWD2）：触屏在查词弹窗正文里拖选文字时，本体横滑关闭检测器
/// 把「长按选字后横拖扩选 / 拖选区把手」判成滑关，弹窗一选字就没了。
///
/// 检测器是不进手势竞技场的 raw Listener，WebView 赢下竞技场也挡不住它收到指针；
/// 修法是判滑关前问选区探针。这里直接挂检测器、注入假探针锁契约（widget 测试挂不了
/// 真平台 WebView）。
Widget _host({
  required VoidCallback onDismiss,
  FutureOr<bool> Function(Offset globalStart)? probe,
}) {
  return MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: 360,
          height: 360,
          child: debugPopupBodySwipeDismissDetector(
            enableSwipeToClose: true,
            onDismiss: onDismiss,
            touchOnNativeSelection: probe,
            child: const ColoredBox(color: Color(0xFFFFFFFF)),
          ),
        ),
      ),
    ),
  );
}

const Offset _start = Offset(400, 300);

/// 模拟「长按后横拖」：先按住（超过弹窗 WebView 的 250ms 长按选字阈值），再横向
/// 拖 200px（远超默认灵敏度 ~94px 的滑关阈值）后抬手。
Future<void> _longPressThenDrag(WidgetTester tester) async {
  final TestGesture gesture = await tester.startGesture(
    _start,
    kind: PointerDeviceKind.touch,
  );
  await tester.pump(const Duration(milliseconds: 400));
  for (int i = 0; i < 10; i++) {
    await gesture.moveBy(const Offset(20, 0));
    await tester.pump();
  }
  await gesture.up();
  await tester.pump();
}

void main() {
  setUp(() async {
    await ReaderFushiSource.instance.setDismissSwipeSensitivity(0.6);
  });

  testWidgets('拖选原生选区（同步探针为真）抬手不关窗', (WidgetTester tester) async {
    int dismissed = 0;
    final List<Offset> asked = <Offset>[];
    await tester.pumpWidget(
      _host(
        onDismiss: () => dismissed++,
        probe: (Offset start) {
          asked.add(start);
          return true;
        },
      ),
    );
    await _longPressThenDrag(tester);
    expect(dismissed, 0);
    expect(asked, <Offset>[_start], reason: '探针按起手点的全局坐标问');
  });

  testWidgets('拖选原生选区（异步探针为真）抬手不关窗', (WidgetTester tester) async {
    int dismissed = 0;
    await tester.pumpWidget(
      _host(
        onDismiss: () => dismissed++,
        probe: (Offset _) => Future<bool>.value(true),
      ),
    );
    await _longPressThenDrag(tester);
    await tester.pump();
    expect(dismissed, 0);
  });

  testWidgets('无选区时横滑过阈照常关窗（异步探针为假）', (WidgetTester tester) async {
    int dismissed = 0;
    await tester.pumpWidget(
      _host(
        onDismiss: () => dismissed++,
        probe: (Offset _) => Future<bool>.value(false),
      ),
    );
    await _longPressThenDrag(tester);
    await tester.pump();
    expect(dismissed, 1);
  });

  testWidgets('没有 WebView（探针缺省）横滑当帧关窗', (WidgetTester tester) async {
    int dismissed = 0;
    await tester.pumpWidget(_host(onDismiss: () => dismissed++));
    await _longPressThenDrag(tester);
    expect(dismissed, 1);
  });

  testWidgets('未过阈值的横拖不问探针', (WidgetTester tester) async {
    int asked = 0;
    int dismissed = 0;
    await tester.pumpWidget(
      _host(
        onDismiss: () => dismissed++,
        probe: (Offset _) {
          asked++;
          return false;
        },
      ),
    );
    final TestGesture gesture = await tester.startGesture(
      _start,
      kind: PointerDeviceKind.touch,
    );
    await gesture.moveBy(const Offset(40, 0));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    expect(asked, 0);
    expect(dismissed, 0);
  });

  testWidgets('选区真值回来前本层已卸载 → 不再关窗', (WidgetTester tester) async {
    int dismissed = 0;
    final Completer<bool> pending = Completer<bool>();
    await tester.pumpWidget(
      _host(onDismiss: () => dismissed++, probe: (Offset _) => pending.future),
    );
    await _longPressThenDrag(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    pending.complete(false);
    await tester.pump();
    expect(dismissed, 0);
  });

  test('DictionaryPopupLayer 把选区探针接到本体横滑检测器上', () {
    final String source = File(
      'lib/src/pages/implementations/dictionary_popup_layer.dart',
    ).readAsStringSync();
    expect(
      source,
      contains('touchOnNativeSelection: _touchOnNativeSelection,'),
      reason: '没接探针，触屏拖选又会被判成滑关（BUG-4911）',
    );
    expect(source, contains('return webView.hasNativeSelection();'));
  });
}
