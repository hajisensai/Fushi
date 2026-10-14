import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/import/quick_import_section.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 库页「导入」视图：拖放区已画成按钮的入口（`actions` 的第一个与最后一个）
/// 不再在下方「导入方式」网格里重复出现（用户 2026-10-14 截图：视频页
/// 「导入视频」「导入文件夹」各出现两次）。
void main() {
  QuickImportAction action(String label) => QuickImportAction(
    icon: FushiIcons.folder,
    label: label,
    onTap: () async {},
  );

  Future<void> pump(
    WidgetTester tester, {
    required List<QuickImportAction> actions,
    List<QuickImportAction> extraActions = const <QuickImportAction>[],
  }) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: QuickImportSection(
              actions: actions,
              extraActions: extraActions,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('视频：拖放区两个按钮不进网格，网格只剩 IPTV 与网络', (WidgetTester tester) async {
    await pump(
      tester,
      actions: <QuickImportAction>[
        action('import-video'),
        action('import-iptv'),
        action('import-folder'),
      ],
      extraActions: <QuickImportAction>[action('network')],
    );

    for (final String label in <String>[
      'import-video',
      'import-iptv',
      'import-folder',
      'network',
    ]) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('quick-import-primary')),
        matching: find.text('import-video'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('quick-import-secondary')),
        matching: find.text('import-folder'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('书 / 漫画：只有两个入口时网格只放网络来源', (WidgetTester tester) async {
    await pump(
      tester,
      actions: <QuickImportAction>[action('import-file'), action('folder')],
      extraActions: <QuickImportAction>[action('network')],
    );

    expect(find.text('import-file'), findsOneWidget);
    expect(find.text('folder'), findsOneWidget);
    expect(find.text('network'), findsOneWidget);
    expect(find.text(t.import_methods_title), findsOneWidget);
  });

  testWidgets('没有剩余入口时整个「导入方式」区不出现', (WidgetTester tester) async {
    await pump(
      tester,
      actions: <QuickImportAction>[action('import-file'), action('folder')],
    );

    expect(find.text('import-file'), findsOneWidget);
    expect(find.text('folder'), findsOneWidget);
    expect(find.text(t.import_methods_title), findsNothing);
  });
}
