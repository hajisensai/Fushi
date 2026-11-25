import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/media_item_dialog_page.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_history_page.dart'
    show bookCardAudioWorkbenchActions;
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart'
    show FushiGlassMaterial;
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:material_ui/material_ui.dart';

/// 拍板 Ew0AxAgycu 方案 a（设计稿 a-import-first）：书卡菜单的有声入口「导入在上、
/// 制作紧随」，同为工作台级、都不进「更多」；漫画卡同理（「导入漫画有声」直达入口
/// 在上，「有声漫画工作台」紧随）。合集详情页成员卡复用同一份书卡菜单（BUG-2969，
/// 见 collection_member_menu_parity_test.dart），这里钉住菜单构建本身。
void main() {
  late List<String> fired;

  setUp(() {
    fired = <String>[];
    // 中文文案短，测试字体（每字一个字号宽）下菜单行不溢出。
    LocaleSettings.setLocale(AppLocale.zhCn);
  });

  List<String> labels(List<DialogWorkbenchAction> actions) => <String>[
    for (final DialogWorkbenchAction a in actions) a.label,
  ];

  List<bool> emphasis(List<DialogWorkbenchAction> actions) => <bool>[
    for (final DialogWorkbenchAction a in actions) a.emphasized,
  ];

  group('bookCardAudioWorkbenchActions', () {
    test('小说（EPUB）：导入有声书在上（主色），制作有声书紧随（同级、中性色）', () {
      final List<DialogWorkbenchAction> actions = bookCardAudioWorkbenchActions(
        importAudiobook: () => fired.add('import'),
        makeAudiobook: () => fired.add('make'),
      );
      expect(labels(actions), <String>[
        t.audiobook_import,
        t.audiobook_studio_title,
      ]);
      expect(emphasis(actions), <bool>[true, false]);
      // 两项都在工作台落点（不进「更多」）、同一内容组。
      for (final DialogWorkbenchAction a in actions) {
        expect(a.menuSlot, ItemMenuSlot.workbench);
        expect(a.group, DialogActionGroup.content);
      }
      actions[0].onPressed();
      actions[1].onPressed();
      expect(fired, <String>['import', 'make']);
    });

    test('小说（PDF，只能挂有声书、不能 TTS 制作）：只有导入，且是主色', () {
      final List<DialogWorkbenchAction> actions = bookCardAudioWorkbenchActions(
        importAudiobook: () => fired.add('import'),
      );
      expect(labels(actions), <String>[t.audiobook_import]);
      expect(emphasis(actions), <bool>[true]);
    });

    test('漫画：导入漫画有声在上（主色），有声漫画工作台紧随（同级，带进度副行）', () async {
      final List<DialogWorkbenchAction> actions = bookCardAudioWorkbenchActions(
        importMangaAudio: () => fired.add('import'),
        openMangaWorkbench: () => fired.add('workbench'),
        mangaWorkbenchStatus: () async => '已识别 12 句',
      );
      expect(labels(actions), <String>[
        t.manga_audio_import,
        t.manga_audio_workbench_title,
      ]);
      expect(emphasis(actions), <bool>[true, false]);
      expect(actions[0].subtitle, isNull);
      expect(actions[1].subtitle, t.manga_audio_workbench_not_started);
      expect(await actions[1].loadStatus!(), '已识别 12 句');
      for (final DialogWorkbenchAction a in actions) {
        expect(a.menuSlot, ItemMenuSlot.workbench);
      }
      actions[0].onPressed();
      actions[1].onPressed();
      expect(fired, <String>['import', 'workbench']);
    });

    test('漫画、听书模块关闭（没有导入入口）：只剩工作台，仍是主色', () {
      final List<DialogWorkbenchAction> actions = bookCardAudioWorkbenchActions(
        openMangaWorkbench: () => fired.add('workbench'),
      );
      expect(labels(actions), <String>[t.manga_audio_workbench_title]);
      expect(emphasis(actions), <bool>[true]);
    });

    test('都不可用：一项都不出', () {
      expect(bookCardAudioWorkbenchActions(), isEmpty);
    });
  });

  group('右键菜单渲染', () {
    Future<void> openMenu(
      WidgetTester tester,
      List<DialogListAction> audio,
    ) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildFushiThemeData(
            scheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
            textTheme: Typography.material2021().black,
            glass: FushiGlassMaterial.off,
            glassDesign: false,
          ),
          home: FushiGlassScope(
            child: Scaffold(
              body: Builder(
                builder: (BuildContext context) => Align(
                  alignment: Alignment.topLeft,
                  child: TextButton(
                    onPressed: () => showMediaItemActions<void>(
                      context: context,
                      anchor: const Offset(400, 120),
                      builder: (_) => MediaItemDialogFrame(
                        title: '本好きの下剋上 1',
                        launchLabel: '继续阅读',
                        onLaunch: () => fired.add('launch'),
                        listActions: <DialogListAction>[
                          DialogListAction(
                            label: '详情',
                            icon: Icons.info_outline,
                            slot: ItemMenuSlot.primary,
                            onPressed: () => fired.add('详情'),
                          ),
                          ...audio,
                          DialogListAction(
                            label: '加入合集',
                            icon: Icons.label_outline,
                            onPressed: () => fired.add('加入合集'),
                          ),
                          DialogListAction(
                            label: '查看插画',
                            icon: Icons.image_outlined,
                            group: DialogActionGroup.content,
                            onPressed: () => fired.add('查看插画'),
                          ),
                        ],
                        dangerActions: <DialogDangerAction>[
                          DialogDangerAction(
                            label: '删除',
                            onPressed: () => fired.add('删除'),
                          ),
                        ],
                      ),
                    ),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    Color tileColor(WidgetTester tester, String label) => tester
        .widget<Material>(
          find
              .ancestor(of: find.text(label), matching: find.byType(Material))
              .first,
        )
        .color!;

    testWidgets('小说卡：两项有声入口都在菜单第一层，导入在制作之上、都在「更多」之前；'
        '导入主色、制作中性色', (WidgetTester tester) async {
      await openMenu(
        tester,
        bookCardAudioWorkbenchActions(
          importAudiobook: () => fired.add('import'),
          makeAudiobook: () => fired.add('make'),
        ),
      );
      final Finder import = find.text(t.audiobook_import);
      final Finder make = find.text(t.audiobook_studio_title);
      expect(import, findsOne);
      expect(make, findsOne);
      final Rect importRect = tester.getRect(import);
      final Rect makeRect = tester.getRect(make);
      final Rect launch = tester.getRect(
        find.byKey(const ValueKey<String>('item_menu_launch')),
      );
      final Rect organize = tester.getRect(
        find.text(t.item_actions_group_organize),
      );
      expect(launch.bottom, lessThanOrEqualTo(importRect.top));
      expect(importRect.bottom, lessThanOrEqualTo(makeRect.top));
      expect(makeRect.bottom, lessThanOrEqualTo(organize.top));
      // 有声入口不在「更多」里：「更多」行的副行摘要只列收进去的项（「查看插画」），
      // 两个有声标签各只出现一次（就是工作台行本身）。
      expect(find.textContaining('查看插画'), findsOne);
      expect(find.textContaining(t.audiobook_import), findsOne);
      expect(find.textContaining(t.audiobook_studio_title), findsOne);

      final ColorScheme scheme = Theme.of(tester.element(import)).colorScheme;
      expect(tileColor(tester, t.audiobook_import), scheme.primaryContainer);
      expect(
        tileColor(tester, t.audiobook_studio_title),
        scheme.surfaceContainerHighest,
      );

      await tester.tap(import);
      expect(fired, <String>['import']);
      expect(tester.takeException(), isNull);
    });

    testWidgets('漫画卡：导入漫画有声在有声漫画工作台之上，同在第一层', (WidgetTester tester) async {
      await openMenu(
        tester,
        bookCardAudioWorkbenchActions(
          importMangaAudio: () => fired.add('import'),
          openMangaWorkbench: () => fired.add('workbench'),
          mangaWorkbenchStatus: () async => '已识别 12 句',
        ),
      );
      final Rect importRect = tester.getRect(find.text(t.manga_audio_import));
      final Rect workbenchRect = tester.getRect(
        find.text(t.manga_audio_workbench_title),
      );
      expect(importRect.bottom, lessThanOrEqualTo(workbenchRect.top));
      expect(find.text('已识别 12 句'), findsOne);
      await tester.tap(find.text(t.manga_audio_workbench_title));
      expect(fired, <String>['workbench']);
      expect(tester.takeException(), isNull);
    });
  });

  test('书卡菜单的有声入口只由 bookCardAudioWorkbenchActions 构建（源码守卫）', () {
    final String shelf = File(
      'lib/src/pages/implementations/reader_fushi_history_page.dart',
    ).readAsStringSync();
    final int start = shelf.indexOf('List<DialogAction> _epubExtraActions(');
    expect(start, isNonNegative);
    final String menu = shelf.substring(start);
    expect(
      RegExp(r'\.\.\.bookCardAudioWorkbenchActions\(').allMatches(menu).length,
      1,
    );
    // 不在书卡菜单里另起一份同名入口（旧的「导入有声书」普通行 / 工作台行）。
    for (final String label in <String>[
      't.audiobook_import',
      't.audiobook_studio_title',
      't.manga_audio_workbench_title',
      't.manga_audio_import',
    ]) {
      expect(
        RegExp('label: ${RegExp.escape(label)},').hasMatch(menu),
        isFalse,
        reason: '$label 只能由 bookCardAudioWorkbenchActions 排',
      );
    }
  });
}
