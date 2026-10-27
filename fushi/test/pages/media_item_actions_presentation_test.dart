import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/media_item_dialog_page.dart';
import 'package:fushi/src/shortcuts/context_menu_trigger.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// 2026-10-25 条目菜单重设计（用户拍板「手机 B + 桌面 D + E」）。同一份分组
/// 动作由承载容器决定排法，本文件钉住三种呈现的可观察行为：
/// * 窄屏 → 底部抽屉：主动作大色块 + 4 列图标宫格 + 删除描边按钮；
/// * 宽屏 → 双栏对话框：左栏封面 / 标题 / 主动作 / 删除，右栏按组分节；
/// * 鼠标右键（有锚点）→ 指针处菜单，「设置」组收进子菜单。
void main() {
  const Key coverKey = ValueKey<String>('item-cover');

  Future<ImageProvider> preparedCover(
    WidgetTester tester,
    int width,
    int height,
  ) async {
    late ImageProvider provider;
    await tester.runAsync(() async {
      final ui.PictureRecorder recorder = ui.PictureRecorder();
      Canvas(recorder).drawRect(
        Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
        Paint()..color = const Color(0xFF3366CC),
      );
      final ui.Image image = await recorder.endRecording().toImage(
        width,
        height,
      );
      final ByteData? png = await image.toByteData(
        format: ui.ImageByteFormat.png,
      );
      image.dispose();
      provider = MemoryImage(png!.buffer.asUint8List());
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await precacheImage(
        ResizeImage.resizeIfNeeded(64, null, provider),
        tester.element(find.byType(SizedBox)),
      );
    });
    return provider;
  }

  late List<String> fired;

  MediaItemDialogFrame buildFrame({
    ImageProvider? backdrop,
    bool withLaunch = false,
    int quickCount = 2,
  }) {
    DialogListAction list(
      String label, {
      DialogActionGroup group = DialogActionGroup.organize,
      bool selected = false,
    }) => DialogListAction(
      label: label,
      icon: Icons.label_outline,
      group: group,
      selected: selected,
      onPressed: () => fired.add(label),
    );
    return MediaItemDialogFrame(
      cover: backdrop == null ? null : const SizedBox.expand(key: coverKey),
      coverBackdrop: backdrop,
      title: 'Item title',
      author: 'Item author',
      showLaunchAction: withLaunch,
      launchLabel: 'READ',
      onLaunch: () => fired.add('READ'),
      quickActions: <DialogQuickAction>[
        for (int i = 0; i < quickCount; i++)
          DialogQuickAction(
            label: 'Quick $i',
            icon: Icons.image_outlined,
            onPressed: () => fired.add('Quick $i'),
          ),
      ],
      listActions: <DialogListAction>[
        list('Rename'),
        list('Add to collection'),
        list('Tags'),
        list(
          'Mark as finished',
          group: DialogActionGroup.progress,
          selected: true,
        ),
        list('Reset progress', group: DialogActionGroup.progress),
        list('Content language', group: DialogActionGroup.settings),
        list('Edit CSS', group: DialogActionGroup.settings),
      ],
      dangerActions: <DialogDangerAction>[
        DialogDangerAction(
          label: 'Delete',
          onPressed: () => fired.add('Delete'),
        ),
      ],
    );
  }

  /// 用真实入口 [showMediaItemActions] 弹出，[anchor] 非空走右键菜单。
  Future<void> open(
    WidgetTester tester, {
    required Size screen,
    ImageProvider? backdrop,
    bool withLaunch = false,
    int quickCount = 2,
    Offset? anchor,
  }) async {
    fired = <String>[];
    tester.view.physicalSize = screen;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) => TextButton(
              onPressed: () => showMediaItemActions<void>(
                context: context,
                anchor: anchor,
                builder: (_) => buildFrame(
                  backdrop: backdrop,
                  withLaunch: withLaunch,
                  quickCount: quickCount,
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  group('phone: bottom sheet with icon grid (B)', () {
    testWidgets('quick actions are hero tiles, the rest a 4-column grid', (
      WidgetTester tester,
    ) async {
      await open(tester, screen: const Size(390, 844));

      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.byType(Dialog), findsNothing);
      // 前四个宫格同一行、等距排开。
      final List<double> ys = <String>[
        'Rename',
        'Add to collection',
        'Tags',
        'Mark as finished',
      ].map((String l) => tester.getTopLeft(find.text(l)).dy).toList();
      expect(ys.toSet().length, 1, reason: '前 4 个动作同一行');
      expect(
        tester.getTopLeft(find.text('Reset progress')).dy,
        greaterThan(ys.first),
        reason: '第 5 个换到下一行',
      );
      // 主动作大色块在宫格之上。
      expect(tester.getTopLeft(find.text('Quick 0')).dy, lessThan(ys.first));
      // 设置组也在宫格里（抽屉不收子菜单）。
      expect(find.text('Edit CSS'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Delete'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('tapping a tile fires its action', (WidgetTester tester) async {
      await open(tester, screen: const Size(390, 844));
      await tester.tap(find.text('Tags'));
      await tester.pumpAndSettle();
      expect(fired, <String>['Tags']);
    });

    testWidgets('a tile is reachable by keyboard and activates with Enter', (
      WidgetTester tester,
    ) async {
      await open(tester, screen: const Size(390, 844));
      final Element tile = tester.element(find.text('Rename'));
      Focus.of(tile).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(fired, <String>['Rename']);
    });

    testWidgets('more than three quick actions join the grid', (
      WidgetTester tester,
    ) async {
      await open(tester, screen: const Size(390, 844), quickCount: 5);
      // 不再有大色块：Quick 0 与普通动作同为宫格格子，排在最前（content 组
      // 在 organize 之后，所以按组排序后跟在整理组后面）。
      expect(find.text('Quick 4'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('desktop: two-pane dialog (D)', () {
    testWidgets('cover and title on the left, grouped sections on the right', (
      WidgetTester tester,
    ) async {
      final ImageProvider cover = await preparedCover(tester, 200, 300);
      await open(
        tester,
        screen: const Size(1280, 800),
        backdrop: cover,
        withLaunch: true,
      );

      expect(find.byType(Dialog), findsOneWidget);
      final Rect coverRect = tester.getRect(find.byKey(coverKey));
      // 封面卡按自身 2:3 比例。
      expect(coverRect.width / coverRect.height, closeTo(2 / 3, 0.02));
      // 标题在封面下方（左栏纵排）。
      expect(
        tester.getTopLeft(find.text('Item title')).dy,
        greaterThan(coverRect.bottom),
      );
      // 分组标题与行在左栏右侧。
      final double sectionX = tester
          .getTopLeft(find.text(t.item_actions_group_organize))
          .dx;
      expect(sectionX, greaterThan(coverRect.right));
      expect(find.text(t.item_actions_group_progress), findsOneWidget);
      expect(find.text(t.item_actions_group_settings), findsOneWidget);
      // 宽屏右栏两列：设置节与整理节不在同一列。
      expect(
        tester.getTopLeft(find.text(t.item_actions_group_settings)).dx,
        isNot(closeTo(sectionX, 1)),
      );
      // 开着的开关类动作行尾打勾。
      expect(
        find.descendant(
          of: find
              .ancestor(
                of: find.text('Mark as finished'),
                matching: find.byType(Row),
              )
              .first,
          matching: find.byIcon(FushiIcons.check),
        ),
        findsOneWidget,
      );
      // 不垫封面模糊。
      expect(find.byType(ImageFiltered), findsNothing);
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('READ'));
      await tester.pumpAndSettle();
      expect(fired, <String>['READ']);
    });

    testWidgets('landscape covers stay inside the left pane', (
      WidgetTester tester,
    ) async {
      final ImageProvider cover = await preparedCover(tester, 1600, 900);
      await open(tester, screen: const Size(1280, 800), backdrop: cover);
      final Rect coverRect = tester.getRect(find.byKey(coverKey));
      expect(coverRect.width / coverRect.height, closeTo(16 / 9, 0.05));
      expect(
        tester.getTopLeft(find.text(t.item_actions_group_organize)).dx,
        greaterThan(coverRect.right),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('the close button dismisses the dialog', (
      WidgetTester tester,
    ) async {
      await open(tester, screen: const Size(1280, 800));
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(find.byType(MediaItemDialogFrame), findsNothing);
    });
  });

  group('desktop right-click: context menu (E)', () {
    testWidgets('opens at the pointer with settings tucked in a submenu', (
      WidgetTester tester,
    ) async {
      await open(
        tester,
        screen: const Size(1280, 800),
        anchor: const Offset(300, 200),
      );

      expect(find.byType(Dialog), findsNothing);
      expect(find.byType(BottomSheet), findsNothing);
      final Offset titleTopLeft = tester.getTopLeft(find.text('Item title'));
      expect(titleTopLeft.dx, greaterThan(300));
      expect(titleTopLeft.dx, lessThan(380));
      expect(titleTopLeft.dy, greaterThan(200));
      expect(titleTopLeft.dy, lessThan(260));
      // 快捷动作只剩图标（文字进 tooltip）。
      expect(find.text('Quick 0'), findsNothing);
      expect(find.byTooltip('Quick 0'), findsOneWidget);
      // 设置组默认收起。
      expect(find.text('Edit CSS'), findsNothing);
      await tester.tap(find.text(t.item_actions_group_settings));
      await tester.pumpAndSettle();
      expect(find.text('Edit CSS'), findsOneWidget);
      // 子菜单在主菜单右侧。
      expect(
        tester.getTopLeft(find.text('Edit CSS')).dx,
        greaterThan(tester.getTopRight(find.text('Rename')).dx),
      );
      await tester.tap(find.text('Edit CSS'));
      await tester.pumpAndSettle();
      expect(fired, <String>['Edit CSS']);
    });

    testWidgets('flips to stay on screen near the bottom-right corner', (
      WidgetTester tester,
    ) async {
      await open(
        tester,
        screen: const Size(1280, 800),
        anchor: const Offset(1270, 790),
      );
      final Rect panel = tester.getRect(
        find
            .ancestor(
              of: find.text('Item title'),
              matching: find.byType(Material),
            )
            .last,
      );
      expect(panel.right, lessThanOrEqualTo(1280));
      expect(panel.bottom, lessThanOrEqualTo(800));
      expect(panel.left, greaterThanOrEqualTo(0));
      expect(panel.top, greaterThanOrEqualTo(0));
      expect(tester.takeException(), isNull);
    });

    Rect menuPanel(WidgetTester tester) => tester.getRect(
      find
          .ancestor(
            of: find.text('Item title'),
            matching: find.byType(Material),
          )
          .last,
    );

    testWidgets('flipped near the bottom-right, the bottom-right corner sits '
        'on the pointer', (WidgetTester tester) async {
      await open(
        tester,
        screen: const Size(1280, 800),
        anchor: const Offset(1100, 700),
      );
      final Rect panel = menuPanel(tester);
      expect(panel.right, moreOrLessEquals(1100, epsilon: 0.5));
      expect(panel.bottom, moreOrLessEquals(700, epsilon: 0.5));
    });

    testWidgets(
      'too tall for either side: opens toward the roomier side with a '
      'corner on the pointer instead of straddling it',
      (WidgetTester tester) async {
        await open(
          tester,
          screen: const Size(1280, 360),
          anchor: const Offset(300, 150),
        );
        final Rect panel = menuPanel(tester);
        // 上方 142、下方 202：菜单放不下任何一侧，取下方、左上角贴指针并限高。
        expect(panel.left, moreOrLessEquals(300, epsilon: 0.5));
        expect(panel.top, moreOrLessEquals(150, epsilon: 0.5));
        expect(panel.bottom, lessThanOrEqualTo(360 - 8 + 0.5));
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('the entrance grows out of the pointer corner, not the screen '
        'corner', (WidgetTester tester) async {
      fired = <String>[];
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (BuildContext context) => TextButton(
                onPressed: () => showMediaItemActions<void>(
                  context: context,
                  anchor: const Offset(900, 120),
                  builder: (_) => buildFrame(),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      // 进场缩放中途：左上角已在指针上，而不是从屏幕左上方向滑过来。
      final Rect mid = menuPanel(tester);
      expect(mid.left, moreOrLessEquals(900, epsilon: 0.5));
      expect(mid.top, moreOrLessEquals(120, epsilon: 0.5));
      await tester.pumpAndSettle();
      final Rect done = menuPanel(tester);
      expect(done.left, moreOrLessEquals(900, epsilon: 0.5));
      expect(done.top, moreOrLessEquals(120, epsilon: 0.5));
    });

    testWidgets('a right-click dispatched through contextMenuInvoker anchors '
        'the menu without the caller passing a position', (
      WidgetTester tester,
    ) async {
      fired = <String>[];
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      late BuildContext host;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (BuildContext context) {
                host = context;
                return const SizedBox.expand();
              },
            ),
          ),
        ),
      );
      final void Function(Offset)? invoke = contextMenuInvoker(
        () => showMediaItemActions<void>(
          context: host,
          builder: (_) => buildFrame(),
        ),
      );
      invoke!(const Offset(500, 300));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);
      final Offset title = tester.getTopLeft(find.text('Item title'));
      expect(title.dx, greaterThan(500));
      expect(title.dy, greaterThan(300));
      expect(activeContextMenuAnchor, isNull, reason: '锚点只在同步派发期间可见');
    });
  });

  testWidgets('without a host the frame keeps the dialog presentation', (
    WidgetTester tester,
  ) async {
    fired = <String>[];
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: Center(child: buildFrame())),
      ),
    );
    expect(find.byType(Dialog), findsOneWidget);
    expect(find.text(t.item_actions_group_organize), findsOneWidget);
  });
}
