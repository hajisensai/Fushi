import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/sentence_context_dialog.dart';

/// BUG-922：「制卡·选择句子上下文」原生对话框在**横屏矮窗**下句子预览塌陷、只剩选项。
///
/// 根因：AlertDialog 正文 Column 竖向空间不足时，`Flexible(SingleChildScrollView)`
/// 把全部空间让给固定的计数/按钮区、塌成 0 高——句子预览整段消失（用户报「手机上
/// 看不见句子，只有选项」），同时 RenderFlex 溢出。修复改为 `AlertDialog(scrollable: true)`
/// + 正文直接铺卡，任何朝向/尺寸下句子预览都保有真实高度、按需滚动、不再塌陷或溢出。
void main() {
  Map<String, Object?> preview() => <String, Object?>{
        'prev': const <String>[],
        'current': '俺に対する同情。',
        'currentOffset': 2, // 「対する」在偏移 2
        'next': const <String>[],
        'total': 0,
      };

  Widget harness() => MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (BuildContext ctx) => Center(
              child: ElevatedButton(
                onPressed: () => showDialog<void>(
                  context: ctx,
                  builder: (_) => SentenceContextDialog(
                    matched: '対する',
                    fetchPreview: () async => preview(),
                    setContext: (int p, int n) async => p + n,
                    onConfirm: () {},
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );

  Finder currentSentence() => find.byWidgetPredicate(
        (Widget w) =>
            w is RichText &&
            w.text is TextSpan &&
            (w.text as TextSpan).toPlainText().contains('俺に対する同情。'),
      );

  testWidgets('横屏矮窗下句子预览不塌陷、可见、且不溢出', (WidgetTester tester) async {
    // 手机横屏：2340x1080 物理 / dpr 3 => 780x360 逻辑（用户截图正是横向）。
    tester.view.physicalSize = const Size(2340, 1080);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(harness());
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // 无 RenderFlex 溢出（修复前会「A RenderFlex overflowed」）。
    expect(tester.takeException(), isNull, reason: '横屏矮窗对话框不得溢出');

    // 当前句必须真正渲染出来、且有可见高度（修复前塌成 0 高不可见）。
    final Finder sentence = currentSentence();
    expect(sentence, findsOneWidget, reason: '当前句必须存在于对话框');
    final Rect rect = tester.getRect(sentence);
    expect(rect.height, greaterThan(4), reason: '当前句必须有真实渲染高度（塌陷时为 0）');

    // 句子必须落在屏幕可视范围内（顶部可见），不是被挤出屏外。
    final Size screen = tester.view.physicalSize / tester.view.devicePixelRatio;
    expect(rect.top, greaterThanOrEqualTo(0.0));
    expect(rect.top, lessThan(screen.height), reason: '当前句顶必须落在屏幕内、用户看得见');
  });

  testWidgets('竖屏窄窗下句子预览同样可见、不溢出', (WidgetTester tester) async {
    // 手机竖屏：1080x2340 物理 / dpr 3 => 360x780 逻辑。
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(harness());
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull, reason: '竖屏窄窗对话框不得溢出');
    final Finder sentence = currentSentence();
    expect(sentence, findsOneWidget);
    expect(tester.getRect(sentence).height, greaterThan(4));
  });
}
