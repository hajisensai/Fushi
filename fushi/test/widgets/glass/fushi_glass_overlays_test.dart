import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_bars.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

// 浮层 / 顶栏玻璃包装的契约：
// ① MD3 设计系统下就是原 Material 控件（像素零变化的前提）；
// ② 玻璃设计系统下渲染玻璃组件，且不再出现原 Material 外观控件；
// ③ 交互骨架不变：对话框 Esc 关闭 / 初始焦点 + Enter 激活；菜单打开后焦点
//    落在初始项、方向键移动、Enter 选中触发 onSelected；TabBar 与
//    TabController 双向同步；SnackBar 显示且动作可用。
void main() {
  ThemeData theme({required bool glass}) => buildFushiThemeData(
    scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
    textTheme: Typography.material2021().black,
    glass: glass ? FushiGlassMaterial.liquid : FushiGlassMaterial.off,
    glassDesign: glass,
  );

  Widget app({required bool glass, required Widget home}) => MaterialApp(
    theme: theme(glass: glass),
    builder: (BuildContext context, Widget? child) =>
        FushiGlassScope(child: child!),
    home: home,
  );

  Future<void> settle(WidgetTester tester) async {
    for (int i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> pumpOpener(
    WidgetTester tester, {
    required bool glass,
    required void Function(BuildContext context) onOpen,
  }) async {
    await tester.pumpWidget(
      app(
        glass: glass,
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) => Center(
              child: ElevatedButton(
                onPressed: () => onOpen(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await settle(tester);
  }

  group('FushiAlertDialog', () {
    Widget dialog({VoidCallback? onOk}) => FushiAlertDialog(
      title: const Text('Title'),
      content: const Text('Body'),
      actions: <Widget>[
        FushiTextButton(onPressed: () {}, child: const Text('Cancel')),
        FushiFilledButton(
          autofocus: true,
          onPressed: onOk,
          child: const Text('OK'),
        ),
      ],
    );

    testWidgets('MD3 renders the Material AlertDialog', (
      WidgetTester tester,
    ) async {
      await pumpOpener(
        tester,
        glass: false,
        onOpen: (BuildContext c) =>
            showDialog<void>(context: c, builder: (_) => dialog()),
      );
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.byType(GlassContainer), findsNothing);
    });

    testWidgets('glass renders a glass card, no Material dialog surface', (
      WidgetTester tester,
    ) async {
      await pumpOpener(
        tester,
        glass: true,
        onOpen: (BuildContext c) =>
            showDialog<void>(context: c, builder: (_) => dialog()),
      );
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(Dialog), findsNothing);
      expect(find.byType(FilledButton), findsNothing);
      expect(find.byType(TextButton), findsNothing);
      expect(
        find.ancestor(
          of: find.text('Body'),
          matching: find.byType(GlassContainer),
        ),
        findsWidgets,
      );
      expect(find.text('Title'), findsOneWidget);
    });

    testWidgets('glass: initial focus + Enter activates, Esc dismisses', (
      WidgetTester tester,
    ) async {
      int ok = 0;
      await pumpOpener(
        tester,
        glass: true,
        onOpen: (BuildContext c) => showDialog<void>(
          context: c,
          builder: (_) => dialog(onOk: () => ok++),
        ),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(ok, 1);
      expect(find.text('Body'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      expect(find.text('Body'), findsNothing);
    });
  });

  group('FushiSimpleDialog / FushiDialog', () {
    testWidgets('MD3 keeps SimpleDialog and Dialog', (
      WidgetTester tester,
    ) async {
      await pumpOpener(
        tester,
        glass: false,
        onOpen: (BuildContext c) => showDialog<void>(
          context: c,
          builder: (_) => FushiSimpleDialog(
            title: const Text('Pick'),
            children: <Widget>[
              FushiSimpleDialogOption(onPressed: () {}, child: const Text('A')),
            ],
          ),
        ),
      );
      expect(find.byType(SimpleDialog), findsOneWidget);
      expect(find.byType(SimpleDialogOption), findsOneWidget);
    });

    testWidgets('glass SimpleDialog option is a glass row and fires', (
      WidgetTester tester,
    ) async {
      int picked = 0;
      await pumpOpener(
        tester,
        glass: true,
        onOpen: (BuildContext c) => showDialog<void>(
          context: c,
          builder: (_) => FushiSimpleDialog(
            title: const Text('Pick'),
            children: <Widget>[
              FushiSimpleDialogOption(
                onPressed: () => picked++,
                child: const Text('A'),
              ),
            ],
          ),
        ),
      );
      expect(find.byType(SimpleDialog), findsNothing);
      expect(find.byType(SimpleDialogOption), findsNothing);
      expect(find.byType(GlassButton), findsOneWidget);
      await tester.tap(find.text('A'));
      await tester.pump();
      expect(picked, 1);
    });

    testWidgets('glass Dialog has no Material Dialog and reopens after Esc', (
      WidgetTester tester,
    ) async {
      await pumpOpener(
        tester,
        glass: true,
        onOpen: (BuildContext c) => showDialog<void>(
          context: c,
          builder: (_) => const FushiDialog(child: Text('plain')),
        ),
      );
      expect(find.text('plain'), findsOneWidget);
      expect(find.byType(Dialog), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);

      await tester.tap(find.text('open'));
      await settle(tester);
    });

    testWidgets('MD3 Dialog.fullscreen forwards', (WidgetTester tester) async {
      await pumpOpener(
        tester,
        glass: false,
        onOpen: (BuildContext c) => showDialog<void>(
          context: c,
          builder: (_) => const FushiDialog.fullscreen(child: Text('full')),
        ),
      );
      expect(find.byType(Dialog), findsOneWidget);
    });

    testWidgets('glass Dialog.fullscreen is glass', (
      WidgetTester tester,
    ) async {
      await pumpOpener(
        tester,
        glass: true,
        onOpen: (BuildContext c) => showDialog<void>(
          context: c,
          builder: (_) => const FushiDialog.fullscreen(child: Text('full')),
        ),
      );
      expect(find.byType(Dialog), findsNothing);
      expect(
        find.ancestor(
          of: find.text('full'),
          matching: find.byType(GlassContainer),
        ),
        findsWidgets,
      );
    });
  });

  group('FushiPopupMenuButton / showFushiMenu', () {
    Widget menuButton({
      required ValueChanged<int> onSelected,
      GlobalKey<PopupMenuButtonState<int>>? key,
    }) => FushiPopupMenuButton<int>(
      key: key,
      tooltip: 'more',
      initialValue: 2,
      onSelected: onSelected,
      itemBuilder: (_) => const <PopupMenuEntry<int>>[
        PopupMenuItem<int>(value: 1, child: Text('one')),
        PopupMenuItem<int>(value: 2, child: Text('two')),
        PopupMenuItem<int>(value: 3, child: Text('three')),
      ],
    );

    testWidgets('MD3 keeps the Material IconButton + popup', (
      WidgetTester tester,
    ) async {
      int? selected;
      await tester.pumpWidget(
        app(
          glass: false,
          home: Scaffold(
            body: Center(
              child: menuButton(onSelected: (int v) => selected = v),
            ),
          ),
        ),
      );
      expect(find.byType(IconButton), findsOneWidget);
      await tester.tap(find.byType(IconButton));
      await settle(tester);
      expect(find.byType(GlassContainer), findsNothing);
      await tester.tap(find.text('three'));
      await settle(tester);
      expect(selected, 3);
    });

    testWidgets('glass: glass trigger + glass menu surface', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        app(
          glass: true,
          home: Scaffold(
            body: Center(child: menuButton(onSelected: (_) {})),
          ),
        ),
      );
      expect(find.byType(IconButton), findsNothing);
      expect(find.byType(GlassButton), findsOneWidget);
      await tester.tap(find.byType(GlassButton));
      await settle(tester);
      expect(
        find.ancestor(
          of: find.text('one'),
          matching: find.byType(GlassContainer),
        ),
        findsWidgets,
      );
      // Material 自己的菜单面（_PopupMenu）不出现。
      expect(
        find.byWidgetPredicate(
          (Widget w) => w.runtimeType.toString().startsWith('_PopupMenu<'),
        ),
        findsNothing,
      );
    });

    testWidgets(
      'glass: focus lands on initialValue, arrows move, Enter picks',
      (WidgetTester tester) async {
        int? selected;
        await tester.pumpWidget(
          app(
            glass: true,
            home: Scaffold(
              body: Center(
                child: menuButton(onSelected: (int v) => selected = v),
              ),
            ),
          ),
        );
        await tester.tap(find.byType(GlassButton));
        await settle(tester);
        final FocusNode? initial = FocusManager.instance.primaryFocus;
        expect(initial, isNotNull);
        expect(
          find.descendant(
            of: find.byElementPredicate((Element e) => e == initial!.context),
            matching: find.text('two'),
          ),
          findsOneWidget,
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await settle(tester);
        expect(selected, 3);
        expect(find.text('three'), findsNothing);
      },
    );

    testWidgets('glass: Esc closes without selecting', (
      WidgetTester tester,
    ) async {
      int? selected;
      await tester.pumpWidget(
        app(
          glass: true,
          home: Scaffold(
            body: Center(
              child: menuButton(onSelected: (int v) => selected = v),
            ),
          ),
        ),
      );
      await tester.tap(find.byType(GlassButton));
      await settle(tester);
      expect(find.text('one'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      expect(find.text('one'), findsNothing);
      expect(selected, isNull);
    });

    testWidgets('GlobalKey<PopupMenuButtonState>.showButtonMenu still works', (
      WidgetTester tester,
    ) async {
      final GlobalKey<PopupMenuButtonState<int>> key =
          GlobalKey<PopupMenuButtonState<int>>();
      await tester.pumpWidget(
        app(
          glass: true,
          home: Scaffold(
            body: Center(
              child: menuButton(key: key, onSelected: (_) {}),
            ),
          ),
        ),
      );
      key.currentState!.showButtonMenu();
      await settle(tester);
      expect(find.text('one'), findsOneWidget);
    });

    testWidgets('showFushiMenu: glass route returns the picked value', (
      WidgetTester tester,
    ) async {
      Future<int?>? result;
      await pumpOpener(
        tester,
        glass: true,
        onOpen: (BuildContext c) => result = showFushiMenu<int>(
          context: c,
          position: const RelativeRect.fromLTRB(10, 10, 10, 10),
          items: const <PopupMenuEntry<int>>[
            PopupMenuItem<int>(value: 7, child: Text('seven')),
            PopupMenuDivider(),
            PopupMenuItem<int>(value: 8, child: Text('eight')),
          ],
        ),
      );
      expect(find.byType(GlassContainer), findsWidgets);
      await tester.tap(find.text('eight'));
      await settle(tester);
      expect(await result, 8);
    });
  });

  group('FushiMenuAnchor', () {
    Widget anchor({required VoidCallback onPick}) => FushiMenuAnchor(
      menuChildren: <Widget>[
        MenuItemButton(onPressed: onPick, child: const Text('item')),
      ],
      builder: (BuildContext c, MenuController m, Widget? _) =>
          ElevatedButton(onPressed: m.open, child: const Text('anchor')),
    );

    testWidgets('glass puts the items on a glass panel', (
      WidgetTester tester,
    ) async {
      int picks = 0;
      await tester.pumpWidget(
        app(
          glass: true,
          home: Scaffold(
            body: Center(child: anchor(onPick: () => picks++)),
          ),
        ),
      );
      await tester.tap(find.text('anchor'));
      await settle(tester);
      expect(
        find.ancestor(
          of: find.text('item'),
          matching: find.byType(GlassContainer),
        ),
        findsWidgets,
      );
      await tester.tap(find.text('item'));
      await settle(tester);
      expect(picks, 1);
    });

    testWidgets('MD3 has no glass panel', (WidgetTester tester) async {
      await tester.pumpWidget(
        app(
          glass: false,
          home: Scaffold(
            body: Center(child: anchor(onPick: () {})),
          ),
        ),
      );
      await tester.tap(find.text('anchor'));
      await settle(tester);
      expect(find.text('item'), findsOneWidget);
      expect(find.byType(GlassContainer), findsNothing);
    });
  });

  group('FushiDropdownButton / FushiDropdownMenu', () {
    Widget dropdown({
      required bool glass,
      required ValueChanged<int?> onChanged,
    }) => app(
      glass: glass,
      home: Scaffold(
        body: Center(
          child: FushiDropdownButton<int>(
            value: 1,
            onChanged: onChanged,
            items: const <DropdownMenuItem<int>>[
              DropdownMenuItem<int>(value: 1, child: Text('first')),
              DropdownMenuItem<int>(value: 2, child: Text('second')),
            ],
          ),
        ),
      ),
    );

    testWidgets('MD3 is the Material DropdownButton', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(dropdown(glass: false, onChanged: (_) {}));
      expect(find.byType(DropdownButton<int>), findsOneWidget);
    });

    testWidgets('glass field opens a glass menu and reports the pick', (
      WidgetTester tester,
    ) async {
      int? changed;
      await tester.pumpWidget(
        dropdown(glass: true, onChanged: (int? v) => changed = v),
      );
      expect(find.byType(DropdownButton<int>), findsNothing);
      expect(find.byType(GlassButton), findsOneWidget);
      await tester.tap(find.text('first'));
      await settle(tester);
      expect(find.text('second'), findsOneWidget);
      await tester.tap(find.text('second'));
      await settle(tester);
      expect(changed, 2);
    });

    Widget dropdownMenu({
      required bool glass,
      required ValueChanged<String?> onSelected,
    }) => app(
      glass: glass,
      home: Scaffold(
        body: Center(
          child: FushiDropdownMenu<String>(
            label: const Text('Label'),
            initialSelection: 'a',
            onSelected: onSelected,
            dropdownMenuEntries: const <DropdownMenuEntry<String>>[
              DropdownMenuEntry<String>(value: 'a', label: 'Alpha'),
              DropdownMenuEntry<String>(value: 'b', label: 'Beta'),
            ],
          ),
        ),
      ),
    );

    testWidgets('MD3 is the Material DropdownMenu', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(dropdownMenu(glass: false, onSelected: (_) {}));
      expect(find.byType(DropdownMenu<String>), findsOneWidget);
    });

    testWidgets('glass DropdownMenu selects through the glass menu', (
      WidgetTester tester,
    ) async {
      String? picked;
      await tester.pumpWidget(
        dropdownMenu(glass: true, onSelected: (String? v) => picked = v),
      );
      expect(find.byType(DropdownMenu<String>), findsNothing);
      expect(find.byType(TextField), findsNothing);
      expect(find.text('Alpha'), findsOneWidget);
      await tester.tap(find.text('Alpha'));
      await settle(tester);
      await tester.tap(find.text('Beta').last);
      await settle(tester);
      expect(picked, 'b');
      expect(find.text('Beta'), findsOneWidget);
    });
  });

  group('FushiSnackBar', () {
    Future<void> show(
      WidgetTester tester, {
      required bool glass,
      VoidCallback? onUndo,
    }) async {
      await pumpOpener(
        tester,
        glass: glass,
        onOpen: (BuildContext c) => ScaffoldMessenger.of(c).showSnackBar(
          FushiSnackBar(
            content: const Text('saved'),
            action: SnackBarAction(label: 'undo', onPressed: onUndo ?? () {}),
          ),
        ),
      );
    }

    test('is still a SnackBar', () {
      const SnackBar bar = FushiSnackBar(content: Text('x'));
      expect(bar, isA<SnackBar>());
      expect(bar.persist, isFalse);
    });

    testWidgets('MD3 shows the stock SnackBar action', (
      WidgetTester tester,
    ) async {
      await show(tester, glass: false);
      expect(find.text('saved'), findsOneWidget);
      expect(find.byType(TextButton), findsOneWidget);
      expect(find.byType(GlassContainer), findsNothing);
    });

    testWidgets('glass shows a glass capsule with a glass action', (
      WidgetTester tester,
    ) async {
      int undone = 0;
      await show(tester, glass: true, onUndo: () => undone++);
      expect(find.text('saved'), findsOneWidget);
      expect(find.byType(TextButton), findsNothing);
      expect(
        find.ancestor(
          of: find.text('saved'),
          matching: find.byType(GlassContainer),
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('undo'));
      await settle(tester);
      expect(undone, 1);
      expect(find.text('saved'), findsNothing);
    });
  });

  group('FushiAppBar', () {
    Future<void> pushSecond(WidgetTester tester, {required bool glass}) async {
      await tester.pumpWidget(
        app(
          glass: glass,
          home: Builder(
            builder: (BuildContext context) => Scaffold(
              appBar: FushiAppBar(title: const Text('Home')),
              body: Center(
                child: ElevatedButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => Scaffold(
                        appBar: FushiAppBar(title: const Text('Second')),
                      ),
                    ),
                  ),
                  child: const Text('go'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await settle(tester);
    }

    testWidgets('MD3 keeps the Material BackButton', (
      WidgetTester tester,
    ) async {
      await pushSecond(tester, glass: false);
      expect(find.byType(BackButton), findsOneWidget);
      expect(find.byType(GlassContainer), findsNothing);
    });

    testWidgets('glass: glass back button pops, glass backdrop', (
      WidgetTester tester,
    ) async {
      await pushSecond(tester, glass: true);
      expect(find.byType(BackButton), findsNothing);
      expect(find.byType(IconButton), findsNothing);
      expect(find.byType(FushiIconButtonControl), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(AppBar).last,
          matching: find.byType(GlassContainer),
        ),
        findsOneWidget,
      );
      await tester.tap(find.byType(FushiIconButtonControl));
      await settle(tester);
      expect(find.text('Second'), findsNothing);
      expect(find.text('Home'), findsOneWidget);
    });

    test('preferredSize matches AppBar', () {
      final FushiTabBar bottom = FushiTabBar(
        tabs: const <Widget>[Tab(text: 'a')],
      );
      expect(
        FushiAppBar(bottom: bottom).preferredSize,
        AppBar(bottom: bottom).preferredSize,
      );
    });
  });

  group('FushiTabBar', () {
    Widget bar({required bool glass, required TabController controller}) => app(
      glass: glass,
      home: Scaffold(
        appBar: FushiAppBar(
          title: const Text('Tabs'),
          bottom: FushiTabBar(
            controller: controller,
            tabs: const <Widget>[
              Tab(text: 'Alpha'),
              Tab(text: 'Beta'),
              Tab(text: 'Gamma'),
            ],
          ),
        ),
      ),
    );

    testWidgets('MD3 is the Material TabBar', (WidgetTester tester) async {
      final TabController controller = TabController(
        length: 3,
        vsync: const TestVSync(),
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(bar(glass: false, controller: controller));
      expect(find.byType(TabBar), findsOneWidget);
    });

    testWidgets('glass: segments sync both ways with TabController', (
      WidgetTester tester,
    ) async {
      final TabController controller = TabController(
        length: 3,
        vsync: const TestVSync(),
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(bar(glass: true, controller: controller));
      expect(find.byType(TabBar), findsNothing);

      // 点按 → controller。
      await tester.tap(find.text('Gamma'));
      await settle(tester);
      expect(controller.index, 2);
      expect(
        tester
            .widget<GlassButton>(
              find.ancestor(
                of: find.text('Gamma'),
                matching: find.byType(GlassButton),
              ),
            )
            .style,
        GlassButtonStyle.filled,
      );
      // controller → 选中态。
      controller.animateTo(1);
      await settle(tester);
      expect(
        tester
            .widget<GlassButton>(
              find.ancestor(
                of: find.text('Beta'),
                matching: find.byType(GlassButton),
              ),
            )
            .style,
        GlassButtonStyle.filled,
      );
      expect(
        tester
            .widget<GlassButton>(
              find.ancestor(
                of: find.text('Gamma'),
                matching: find.byType(GlassButton),
              ),
            )
            .style,
        GlassButtonStyle.transparent,
      );
    });

    testWidgets('glass: keyboard focus + Enter selects a tab', (
      WidgetTester tester,
    ) async {
      final TabController controller = TabController(
        length: 3,
        vsync: const TestVSync(),
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(bar(glass: true, controller: controller));
      final Iterable<Element> buttons = find.byType(GlassButton).evaluate();
      // 第三个页签的焦点节点：从 GlassButton 子树里找可聚焦的 Focus。
      final Element third = buttons.elementAt(2);
      FocusNode? node;
      void visit(Element e) {
        final Widget w = e.widget;
        if (node == null && w is Focus && w.focusNode != null) {
          if (w.focusNode!.canRequestFocus && !w.focusNode!.skipTraversal) {
            node = w.focusNode;
          }
        }
        e.visitChildren(visit);
      }

      visit(third);
      expect(node, isNotNull);
      node!.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await settle(tester);
      expect(controller.index, 2);
    });

    test('preferredSize equals the Material TabBar', () {
      const List<Widget> tabs = <Widget>[Tab(text: 'a'), Tab(text: 'b')];
      expect(
        const FushiTabBar(tabs: tabs).preferredSize,
        const TabBar(tabs: tabs).preferredSize,
      );
      expect(
        const FushiTabBar.secondary(tabs: tabs).preferredSize,
        const TabBar.secondary(tabs: tabs).preferredSize,
      );
    });

    testWidgets(
      'glass DefaultTabController works without explicit controller',
      (WidgetTester tester) async {
        await tester.pumpWidget(
          app(
            glass: true,
            home: DefaultTabController(
              length: 2,
              child: Builder(
                builder: (BuildContext context) => Scaffold(
                  appBar: FushiAppBar(
                    bottom: const FushiTabBar(
                      isScrollable: true,
                      tabs: <Widget>[
                        Tab(text: 'One'),
                        Tab(text: 'Two'),
                      ],
                    ),
                  ),
                  body: const TabBarView(
                    children: <Widget>[Text('page1'), Text('page2')],
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Two'));
        await settle(tester);
        expect(find.text('page2'), findsOneWidget);
        expect(isGlassDesign(tester.element(find.text('Two'))), isTrue);
      },
    );
  });
}
