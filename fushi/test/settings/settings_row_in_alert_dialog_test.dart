import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart'
    show FushiAlertDialog;
import 'package:fushi/src/utils/components/settings_shared.dart';
import 'package:material_ui/material_ui.dart';

/// BUG-3501：设置行直接当 AlertDialog 正文。
///
/// 两处根因：① AlertDialog 的 IntrinsicWidth 问到行里的 LayoutBuilder（release 答 0、
/// debug 抛错），对话框被量成只有标题 / 按钮那么宽；② 行内 trailing 的 Align 不给
/// heightFactor，在有界高度（对话框正文的 Flexible）里撑满，对话框被撑到窗口那么高、
/// 标题孤零零居中。
/// 对话框的 Material 面（AlertDialog 本身占满路由区，量它没有意义）。
final Finder _dialogSurface = find
    .descendant(of: find.byType(Dialog), matching: find.byType(Material))
    .first;

void main() {
  Future<void> pump(WidgetTester tester, Widget child) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(body: Center(child: child)),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('开关行直接当对话框正文：不抛 intrinsic 错、宽度够、高度按内容', (
    WidgetTester tester,
  ) async {
    await pump(
      tester,
      FushiAlertDialog(
        title: const Text('Import'),
        content: AdaptiveSettingsSwitchRow(
          key: const ValueKey<String>('row'),
          title: 'Update existing notes with imported content',
          subtitle: 'When off, notes that already exist keep your changes',
          value: false,
          onChanged: (_) {},
        ),
        actions: <Widget>[
          TextButton(onPressed: () {}, child: const Text('Cancel')),
        ],
      ),
    );
    expect(tester.takeException(), isNull);
    final Rect dialog = tester.getRect(_dialogSurface);
    expect(dialog.width, greaterThanOrEqualTo(400));
    expect(dialog.width, lessThanOrEqualTo(560));
    expect(dialog.height, lessThan(320));
    final Rect row = tester.getRect(find.byKey(const ValueKey<String>('row')));
    // 标题 + 说明各可能折两行（≈134）；撑满时会是数百像素。
    expect(row.height, lessThan(200));
  });

  testWidgets('有界高度里行不撑满（trailing 的 Align 收高）', (WidgetTester tester) async {
    await pump(
      tester,
      SizedBox(
        width: 480,
        height: 600,
        child: Column(
          children: <Widget>[
            Flexible(
              child: AdaptiveSettingsSwitchRow(
                key: const ValueKey<String>('row'),
                title: 'Switch',
                value: true,
                onChanged: (_) {},
              ),
            ),
          ],
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(
      tester.getSize(find.byKey(const ValueKey<String>('row'))).height,
      lessThan(120),
    );
  });

  testWidgets('有界高度 + 窄到堆叠布局：同样按内容收高', (WidgetTester tester) async {
    await pump(
      tester,
      SizedBox(
        width: 200,
        height: 600,
        child: Column(
          children: <Widget>[
            Flexible(
              child: AdaptiveSettingsSwitchRow(
                key: const ValueKey<String>('row'),
                title: 'Switch',
                value: true,
                onChanged: (_) {},
              ),
            ),
          ],
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(
      tester.getSize(find.byKey(const ValueKey<String>('row'))).height,
      lessThan(160),
    );
  });

  testWidgets('IntrinsicHeight / IntrinsicWidth 包裹下也不抛错', (
    WidgetTester tester,
  ) async {
    await pump(
      tester,
      IntrinsicWidth(
        child: IntrinsicHeight(
          child: Column(
            children: <Widget>[
              AdaptiveSettingsSwitchRow(
                title: 'Switch',
                value: true,
                onChanged: (_) {},
              ),
            ],
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
  });
}
