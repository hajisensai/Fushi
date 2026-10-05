import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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
      // Apple 对话框面板（FushiAppleDialogPanel：近实色面板 + 发丝描边 +
      // 柔和阴影，背后整屏模糊），不是 Material Dialog 表面。
      expect(
        find.ancestor(
          of: find.text('Body'),
          matching: find.byType(FushiAppleDialogPanel),
        ),
        findsOneWidget,
      );
      expect(find.text('Title'), findsOneWidget);
      // iOS 26 alert：两个动作并排、等宽、48 高胶囊；取消是中性玻璃胶囊
      // （主操作在这里 onPressed 为空，是禁用的灰胶囊）。
      final Rect cancel = tester.getRect(
        find.ancestor(
          of: find.text('Cancel'),
          matching: find.byType(GlassButton),
        ),
      );
      final Rect ok = tester.getRect(
        find.ancestor(of: find.text('OK'), matching: find.byType(GlassButton)),
      );
      expect(cancel.top, ok.top);
      expect(cancel.width, moreOrLessEquals(ok.width, epsilon: 0.5));
      expect(ok.height, 48);
      expect(
        tester
            .widget<GlassButton>(
              find.ancestor(
                of: find.text('Cancel'),
                matching: find.byType(GlassButton),
              ),
            )
            .style,
        GlassButtonStyle.filled,
      );
      // 纯文字 alert 宽度收在 iOS 的 270–320。
      final double width = tester
          .getSize(
            find
                .ancestor(
                  of: find.text('Body'),
                  matching: find.byType(FushiAppleDialogPanel),
                )
                .first,
          )
          .width;
      expect(width, inInclusiveRange(270, 320));
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

    testWidgets('glass SimpleDialog option is an iOS row and fires', (
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
      expect(find.byType(GlassButton), findsNothing);
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
      final Finder panel = find.ancestor(
        of: find.text('full'),
        matching: find.byType(FushiAppleDialogPanel),
      );
      expect(panel, findsOneWidget);
      expect(tester.widget<FushiAppleDialogPanel>(panel).radius, 0);
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

    testWidgets('glass: plain ellipsis trigger + glass menu surface', (
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
      expect(find.byType(GlassButton), findsNothing);
      expect(find.byIcon(CupertinoIcons.ellipsis), findsOneWidget);
      await tester.tap(find.byIcon(CupertinoIcons.ellipsis));
      await settle(tester);
      // 玻璃面板由菜单路由单独画在内容背后（随展开变形缩放），不是菜单行的
      // 祖先：断言唯一一块玻璃面板盖住全部菜单行。
      final Finder glassPanel = find.byType(GlassContainer);
      expect(glassPanel, findsOneWidget);
      final Rect panelRect = tester.getRect(glassPanel);
      for (final String label in <String>['one', 'two', 'three']) {
        expect(panelRect.contains(tester.getCenter(find.text(label))), isTrue);
      }
      // 菜单行高 44（iOS），initialValue 对应项行尾打勾。
      expect(find.byIcon(CupertinoIcons.checkmark), findsOneWidget);
      expect(
        tester.getCenter(find.byIcon(CupertinoIcons.checkmark)).dy,
        moreOrLessEquals(tester.getCenter(find.text('two')).dy, epsilon: 1),
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
        // 焦点只在「键盘 / 手柄打开」时落进菜单项（鼠标 / 触摸打开不预先
        // 高亮某项，与 macOS / iOS 原生菜单一致）：Tab 到触发器再 Enter 打开。
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await settle(tester);
        final FocusNode? initial = FocusManager.instance.primaryFocus;
        expect(initial, isNotNull);
        expect(initial, isNot(isA<FocusScopeNode>()));
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
      await tester.tap(find.byIcon(CupertinoIcons.ellipsis));
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
      expect(find.byType(GlassButton), findsNothing);
      expect(
        find.byIcon(CupertinoIcons.chevron_up_chevron_down),
        findsOneWidget,
      );
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

    testWidgets('glass: round glass back button pops, bar is transparent', (
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
      // 顶栏本身透明（不是一整块玻璃），玻璃只在那枚圆形返回钮上。
      expect(
        tester.widget<AppBar>(find.byType(AppBar).last).backgroundColor,
        Colors.transparent,
      );
      final Size circle = tester.getSize(
        find.descendant(
          of: find.byType(AppBar).last,
          matching: find.byType(GlassContainer),
        ),
      );
      expect(circle.width, circle.height);
      await tester.tap(find.byType(FushiIconButtonControl));
      await settle(tester);
      expect(find.text('Second'), findsNothing);
      expect(find.text('Home'), findsOneWidget);
    });

    testWidgets('glass: actions share one glass capsule and still fire', (
      WidgetTester tester,
    ) async {
      int a = 0;
      int b = 0;
      await tester.pumpWidget(
        app(
          glass: true,
          home: Scaffold(
            appBar: FushiAppBar(
              title: const Text('Bar'),
              actions: <Widget>[
                FushiIconButtonControl(
                  icon: const Icon(Icons.search),
                  onPressed: () => a++,
                ),
                FushiIconButtonControl(
                  icon: const Icon(Icons.more_horiz),
                  onPressed: () => b++,
                ),
              ],
            ),
          ),
        ),
      );
      await settle(tester);
      final Finder capsule = find.descendant(
        of: find.byType(AppBar),
        matching: find.byType(GlassContainer),
      );
      expect(capsule, findsOneWidget);
      expect(
        find.descendant(
          of: capsule,
          matching: find.byType(FushiIconButtonControl),
        ),
        findsNWidgets(2),
      );
      await tester.tap(find.byIcon(Icons.search));
      await tester.tap(find.byIcon(Icons.more_horiz));
      await settle(tester);
      expect(a, 1);
      expect(b, 1);
    });

    testWidgets('MD3 actions are not wrapped', (WidgetTester tester) async {
      await tester.pumpWidget(
        app(
          glass: false,
          home: Scaffold(
            appBar: FushiAppBar(
              actions: <Widget>[
                FushiIconButtonControl(
                  icon: const Icon(Icons.search),
                  onPressed: () {},
                ),
              ],
            ),
          ),
        ),
      );
      expect(find.byType(IconButton), findsOneWidget);
      expect(find.byType(GlassContainer), findsNothing);
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

      // Apple 文字页签：选中 = 强调色 semibold（+ 滑动下划线），未选中 =
      // secondaryLabel w500；选中态同时挂在语义上。
      FontWeight? weightOf(String label) => tester
          .renderObject<RenderParagraph>(find.text(label))
          .text
          .style
          ?.fontWeight;

      // 点按 → controller。
      await tester.tap(find.text('Gamma'));
      await settle(tester);
      expect(controller.index, 2);
      expect(weightOf('Gamma'), FontWeight.w600);
      expect(weightOf('Alpha'), FontWeight.w500);
      // controller → 选中态。
      controller.animateTo(1);
      await settle(tester);
      expect(weightOf('Beta'), FontWeight.w600);
      expect(weightOf('Gamma'), FontWeight.w500);
      final SemanticsHandle handle = tester.ensureSemantics();
      expect(
        tester.getSemantics(find.text('Beta')),
        isSemantics(isSelected: true, isButton: true),
      );
      handle.dispose();
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
      // 第三个页签的焦点节点：包住它文字的最近一个 Focus（页签自身的
      // FocusableActionDetector），须是可 Tab 到达的停靠点。
      final FocusNode node = Focus.of(tester.element(find.text('Gamma')));
      expect(node.canRequestFocus, isTrue);
      expect(node.skipTraversal, isFalse);
      node.requestFocus();
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
