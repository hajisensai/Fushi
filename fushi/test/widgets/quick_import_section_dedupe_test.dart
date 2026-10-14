import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/import/quick_import_section.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 库页「导入」视图：所有导入入口都并进拖放区的一排按钮，页面上每个入口只
/// 出现一次（用户 2026-10-14：原先下方另有「导入方式」卡片网格，视频页的
/// 「导入视频」「导入文件夹」各出现两次；随后拍板把 IPTV / 网络也并进按钮行）。
void main() {
  QuickImportAction action(String label, {String? description}) =>
      QuickImportAction(
        icon: FushiIcons.folder,
        label: label,
        description: description,
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

  /// 按钮行里各按钮标签的从左到右顺序。
  List<String> buttonOrder(WidgetTester tester, List<String> labels) {
    final List<String> sorted = List<String>.of(labels)
      ..sort(
        (String a, String b) => tester
            .getTopLeft(find.text(a))
            .dx
            .compareTo(tester.getTopLeft(find.text(b)).dx),
      );
    return sorted;
  }

  testWidgets('视频：四个入口都在按钮行里，各出现一次，文件夹紧跟主按钮', (WidgetTester tester) async {
    await pump(
      tester,
      actions: <QuickImportAction>[
        action('import-video'),
        action('import-iptv'),
        action('import-folder'),
      ],
      extraActions: <QuickImportAction>[
        action('network', description: 'webdav-remote'),
      ],
    );

    const List<String> labels = <String>[
      'import-video',
      'import-iptv',
      'import-folder',
      'network',
    ];
    for (final String label in labels) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    expect(buttonOrder(tester, labels), <String>[
      'import-video',
      'import-folder',
      'import-iptv',
      'network',
    ]);
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
    // 「导入方式」卡片网格已整体移除：每个入口都只是按钮行里的按钮。
    for (final String label in labels) {
      expect(
        find.descendant(
          of: find.byType(FushiFilledButton),
          matching: find.text(label),
        ),
        findsOneWidget,
        reason: label,
      );
    }
    // 原卡片上的说明挂成按钮提示，不再画成正文。
    expect(find.text('webdav-remote'), findsNothing);
    expect(find.byTooltip('webdav-remote'), findsOneWidget);
  });

  testWidgets('书 / 漫画：导入 → 导入文件夹 → 网络', (WidgetTester tester) async {
    await pump(
      tester,
      actions: <QuickImportAction>[action('import-file'), action('folder')],
      extraActions: <QuickImportAction>[action('network')],
    );

    const List<String> labels = <String>['import-file', 'folder', 'network'];
    for (final String label in labels) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    expect(buttonOrder(tester, labels), labels);
  });

  testWidgets('没有入口时整块不画', (WidgetTester tester) async {
    await pump(tester, actions: const <QuickImportAction>[]);

    expect(find.text(t.import_drop_zone_title), findsNothing);
  });
}
