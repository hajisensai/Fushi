import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/copy_feedback.dart';

/// [CopyFeedback]：复制按钮的就地 ✓ 反馈状态。
///
/// 行为契约：初始 `copied == false`；`markCopied()` 后立刻 true；到时自动回落 false；
/// 期间再次 `markCopied()` 重新计时（不会在旧定时器到点时提前回落）；卸载时取消定时器
/// （不然到点 setState 打到已 dispose 的 State）。
///
/// 最后一条曾经钉不住任何东西：实现里同时有 `dispose` 的 `cancel()` 和定时器回调里的
/// `if (!mounted) return`，两道门互为冗余，删掉任意一道测试照样绿。现在只剩 `dispose`
/// 里那一道（定时器的生命周期本就归 State），这条用例才成了它的真钉子。
void main() {
  Widget host({Duration duration = kCopyFeedbackDuration}) {
    return MaterialApp(
      home: CopyFeedback(
        duration: duration,
        builder: (BuildContext _, bool copied, VoidCallback markCopied) {
          return TextButton(
            onPressed: markCopied,
            child: Text(copied ? 'copied' : 'copy'),
          );
        },
      ),
    );
  }

  testWidgets('markCopied 后立刻 copied，时长到自动回落', (WidgetTester tester) async {
    await tester.pumpWidget(host());
    expect(find.text('copy'), findsOneWidget);

    await tester.tap(find.text('copy'));
    await tester.pump();
    expect(find.text('copied'), findsOneWidget);

    await tester.pump(kCopyFeedbackDuration - const Duration(milliseconds: 1));
    expect(find.text('copied'), findsOneWidget, reason: '未到时不回落');

    await tester.pump(const Duration(milliseconds: 1));
    expect(find.text('copy'), findsOneWidget, reason: '到时回落');
  });

  testWidgets('维持期内再点重新计时，不被旧定时器提前打回', (WidgetTester tester) async {
    await tester.pumpWidget(host(duration: const Duration(seconds: 1)));
    await tester.tap(find.text('copy'));
    await tester.pump();

    await tester.pump(const Duration(milliseconds: 800));
    await tester.tap(find.text('copied'));
    await tester.pump();

    // 旧定时器原本在 1000ms 到点；重新计时后 1000ms 处仍应是 copied。
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('copied'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 700));
    expect(find.text('copy'), findsOneWidget);
  });

  testWidgets('维持期内卸载不抛：dispose 取消定时器（删掉那句 cancel 即红）',
      (WidgetTester tester) async {
    await tester.pumpWidget(host());
    await tester.tap(find.text('copy'));
    await tester.pump();

    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await tester.pump(kCopyFeedbackDuration + const Duration(milliseconds: 10));
    expect(tester.takeException(), isNull);
  });
}
