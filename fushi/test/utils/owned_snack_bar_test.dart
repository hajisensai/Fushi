import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/misc/owned_snack_bar.dart';

const String _hintText = 'owned hint';

/// 拥有一条挂在根 ScaffoldMessenger 上的提示条的页面；dispose 时收掉它
/// （与阅读器专注模式提示条同一形状）。
class _OwnerPage extends StatefulWidget {
  const _OwnerPage();

  @override
  State<_OwnerPage> createState() => _OwnerPageState();
}

class _OwnerPageState extends State<_OwnerPage> {
  OwnedSnackBar? hint;

  void showHint() {
    hint = OwnedSnackBar.show(
      ScaffoldMessenger.of(context),
      SnackBar(
        content: const Text(_hintText),
        duration: const Duration(minutes: 1),
        persist: false,
        action: SnackBarAction(label: 'act', onPressed: () {}),
      ),
    );
  }

  @override
  void dispose() {
    hint?.closeAfterOwnerDisposed();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const Scaffold(body: SizedBox.expand());
}

void main() {
  final GlobalKey<NavigatorState> navigator = GlobalKey<NavigatorState>();

  void accessibleNavigation(WidgetTester tester, bool enabled) {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        FakeAccessibilityFeatures(accessibleNavigation: enabled);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
  }

  /// 根页 + 推上 [_OwnerPage]，返回它的 State。
  Future<_OwnerPageState> pushOwner(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: const Scaffold(body: SizedBox.expand()),
      ),
    );
    unawaited(
      navigator.currentState!.push(
        MaterialPageRoute<void>(builder: (_) => const _OwnerPage()),
      ),
    );
    await tester.pumpAndSettle();
    return tester.state<_OwnerPageState>(find.byType(_OwnerPage));
  }

  for (final bool a11y in <bool>[true, false]) {
    testWidgets('页面 dispose 时收掉自己的提示条，不在锁树期间 setState（读屏=$a11y）', (
      WidgetTester tester,
    ) async {
      accessibleNavigation(tester, a11y);
      final _OwnerPageState owner = await pushOwner(tester);
      owner.showHint();
      await tester.pumpAndSettle();
      expect(find.text(_hintText), findsOneWidget);
      SnackBarClosedReason? reason;
      owner.hint!.closed.then((SnackBarClosedReason r) => reason = r);

      navigator.currentState!.pop();
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text(_hintText), findsNothing);
      expect(reason, SnackBarClosedReason.hide);
    });
  }

  testWidgets('提示条已先结束时，dispose 不会收掉别人后来弹的提示条', (WidgetTester tester) async {
    accessibleNavigation(tester, true);
    final _OwnerPageState owner = await pushOwner(tester);
    owner.showHint();
    await tester.pumpAndSettle();
    owner.hint!.close();
    await tester.pumpAndSettle();
    expect(find.text(_hintText), findsNothing);

    // 别处弹的提示条（如同步报告）：页面离场后仍应留着。
    ScaffoldMessenger.of(
      tester.element(find.byType(_OwnerPage)),
    ).showSnackBar(const SnackBar(content: Text('other')));
    await tester.pumpAndSettle();
    navigator.currentState!.pop();
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('other'), findsOneWidget);
    // 让它按自己的 4 秒走完，不留挂起计时器。
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });
}
