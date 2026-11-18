// 字幕工作台是 root navigator 上的整页；视频页在它下面起的面板（转录、生成字幕）
// 必须也开在 root 上，否则被整页挡住——移动端此前因此只能「先关工作台再跑」。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  Future<void> pump(WidgetTester tester, {required bool? useRoot}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Navigator(
          key: const ValueKey<String>('nested'),
          onGenerateRoute: (RouteSettings settings) => MaterialPageRoute<void>(
            builder: (BuildContext context) => Scaffold(
              body: Center(
                child: FilledButton(
                  key: const ValueKey<String>('open'),
                  onPressed: () => adaptiveModalSheet<void>(
                    context: context,
                    useRootNavigator: useRoot,
                    builder: (BuildContext _) =>
                        const SizedBox(height: 120, child: Text('sheet')),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey<String>('open')));
    await tester.pumpAndSettle();
  }

  NavigatorState nested(WidgetTester tester) => tester.state<NavigatorState>(
    find.byKey(const ValueKey<String>('nested')),
  );

  testWidgets('useRootNavigator: true opens the sheet above a nested '
      'navigator', (WidgetTester tester) async {
    await pump(tester, useRoot: true);
    final NavigatorState owner = Navigator.of(
      tester.element(find.text('sheet')),
    );
    expect(owner, isNot(same(nested(tester))));
    expect(
      owner,
      same(Navigator.of(nested(tester).context, rootNavigator: true)),
    );
  });

  testWidgets('by default a Material sheet stays on the nearest navigator', (
    WidgetTester tester,
  ) async {
    await pump(tester, useRoot: null);
    expect(
      Navigator.of(tester.element(find.text('sheet'))),
      same(nested(tester)),
    );
  });
}
