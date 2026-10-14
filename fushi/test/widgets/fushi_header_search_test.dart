import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/utils/components/fushi_header_search.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/test_platform_services.dart';

/// 库页「可展开搜索的单行页头」（2026-10-14 用户定案）的交互契约：
/// 🔍 展开整行搜索栏、← 清空并收起、Esc 两段（先清空再收起）、库页搜索快捷键
/// （[ShortcutAction.librarySearch]）读用户绑定、裸 `/` 在输入框里不触发。
void main() {
  const ValueKey<String> buttonKey = ValueKey<String>(
    'fushi-header-search-button',
  );
  const ValueKey<String> barKey = ValueKey<String>('fushi-header-search-bar');
  const ValueKey<String> fieldKey = ValueKey<String>('test-header-search');
  const ValueKey<String> otherFieldKey = ValueKey<String>('other-field');

  late TextEditingController text;
  late FushiHeaderSearchController search;
  late List<String> queries;
  late FocusNode parkingNode;

  setUp(() {
    text = TextEditingController();
    queries = <String>[];
    search = FushiHeaderSearchController(
      textController: text,
      buttonFocusId: const FushiFocusId('test-header-search-button'),
      onQueryChanged: queries.add,
      hintText: 'Search library',
      fieldKey: fieldKey,
    );
    parkingNode = FocusNode(debugLabel: 'parking');
  });

  tearDown(() {
    search.dispose();
    text.dispose();
    parkingNode.dispose();
  });

  Widget page() {
    return MaterialApp(
      theme: ThemeData.light(
        useMaterial3: true,
      ).copyWith(splashFactory: NoSplash.splashFactory),
      home: Scaffold(
        body: FushiHeaderSearchKeys(
          resolve: () => search,
          child: Column(
            children: <Widget>[
              SizedBox(
                width: 600,
                child: FushiPageHeader(
                  title: 'Library',
                  search: search,
                  actions: <Widget>[
                    FushiIconButton(
                      icon: Icons.star_border,
                      tooltip: 'star',
                      onTap: () {},
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 300, child: TextField(key: otherFieldKey)),
              Focus(focusNode: parkingNode, child: const SizedBox(height: 10)),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> pumpPage(WidgetTester tester, {Widget? wrap}) async {
    await tester.pumpWidget(wrap ?? page());
    await tester.pump();
    await tester.pump();
  }

  bool fieldFocused() => search.fieldFocusNode.hasFocus;

  Future<void> parkFocus(WidgetTester tester) async {
    parkingNode.requestFocus();
    await tester.pump();
  }

  Future<void> pressCtrl(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(key);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    await tester.pump();
  }

  testWidgets('点 🔍 整行换成搜索栏并聚焦输入框', (WidgetTester tester) async {
    await pumpPage(tester);
    expect(find.text('Library'), findsOneWidget);
    expect(find.byKey(barKey), findsNothing);

    await tester.tap(find.byKey(buttonKey));
    await tester.pump();
    await tester.pump();

    expect(search.expanded, isTrue);
    expect(find.byKey(barKey), findsOneWidget);
    expect(find.text('Library'), findsNothing, reason: '展开后标题行整行让给搜索栏');
    expect(find.byKey(buttonKey), findsNothing);
    expect(fieldFocused(), isTrue);

    await tester.enterText(find.byKey(fieldKey), 'abc');
    await tester.pump();
    expect(queries, <String>['abc']);
  });

  testWidgets('← 退出搜索：清空搜索词、收起、🔍 回来', (WidgetTester tester) async {
    await pumpPage(tester);
    await tester.tap(find.byKey(buttonKey));
    await tester.pump();
    await tester.pump();
    await tester.enterText(find.byKey(fieldKey), 'abc');
    await tester.pump();

    await tester.tap(find.byTooltip('Back'));
    await tester.pump();
    await tester.pump();

    expect(search.expanded, isFalse);
    expect(text.text, isEmpty);
    expect(queries.last, '', reason: '收起即清空，页面要拿到空查询恢复全量');
    expect(find.byKey(barKey), findsNothing);
    expect(find.byKey(buttonKey), findsOneWidget);
    expect(find.text('Library'), findsOneWidget);
  });

  testWidgets('Esc 两段：有内容先清空、空框再收起', (WidgetTester tester) async {
    await pumpPage(tester);
    await tester.tap(find.byKey(buttonKey));
    await tester.pump();
    await tester.pump();
    await tester.enterText(find.byKey(fieldKey), 'abc');
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(text.text, isEmpty, reason: '第一次 Esc 只清空');
    expect(search.expanded, isTrue, reason: '第一次 Esc 不收起');

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.pump();
    expect(search.expanded, isFalse, reason: '空框再 Esc 收起');
    expect(find.byKey(buttonKey), findsOneWidget);
  });

  testWidgets('焦点在页面别处时 Esc 同样两段', (WidgetTester tester) async {
    await pumpPage(tester);
    search.expand();
    await tester.pump();
    await tester.pump();
    await tester.enterText(find.byKey(fieldKey), 'abc');
    await tester.pump();
    await parkFocus(tester);
    expect(fieldFocused(), isFalse);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(text.text, isEmpty);
    expect(search.expanded, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.pump();
    expect(search.expanded, isFalse);
  });

  testWidgets('默认绑定（无 ProviderScope 回落平台默认）：Ctrl+F 与 `/` 都展开', (
    WidgetTester tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await pumpPage(tester);

    await parkFocus(tester);
    await pressCtrl(tester, LogicalKeyboardKey.keyF);
    expect(search.expanded, isTrue);
    expect(fieldFocused(), isTrue);

    search.collapse(tester.element(find.byType(Scaffold)));
    await tester.pump();
    await tester.pump();
    expect(search.expanded, isFalse);

    await parkFocus(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.slash);
    await tester.pump();
    await tester.pump();
    expect(search.expanded, isTrue);
    expect(text.text, isEmpty, reason: '触发展开的 `/` 不应打进搜索框');
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('焦点在别的输入框里：裸 `/` 放行打字，Ctrl+F 仍展开', (WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await pumpPage(tester);

    await tester.tap(find.byKey(otherFieldKey));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.slash);
    await tester.pump();
    expect(search.expanded, isFalse, reason: '输入框里的 `/` 是要打进去的字符');

    await pressCtrl(tester, LogicalKeyboardKey.keyF);
    expect(search.expanded, isTrue, reason: '带修饰键的绑定在输入框里照常生效');
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('读用户绑定：librarySearch 改绑 Ctrl+E 后 Ctrl+F 不再展开', (
    WidgetTester tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final AppModel app = AppModel(testPlatformServices());
    app.shortcutRegistry
      ..loadDefaults(TargetPlatform.windows)
      ..updateBinding(
        ShortcutAction.librarySearch,
        const ShortcutBindingSet(
          keyboardBindings: <InputBinding>[
            InputBinding(
              key: LogicalKeyboardKey.keyE,
              modifiers: <ModifierKey>{ModifierKey.ctrl},
            ),
          ],
        ),
      );
    await pumpPage(
      tester,
      wrap: ProviderScope(
        overrides: <Override>[appProvider.overrideWith((Ref ref) => app)],
        child: page(),
      ),
    );

    await parkFocus(tester);
    await pressCtrl(tester, LogicalKeyboardKey.keyF);
    expect(search.expanded, isFalse, reason: '默认键已被用户换掉');
    await tester.sendKeyEvent(LogicalKeyboardKey.slash);
    await tester.pump();
    expect(search.expanded, isFalse, reason: '`/` 也不在用户绑定里');

    await pressCtrl(tester, LogicalKeyboardKey.keyE);
    expect(search.expanded, isTrue);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('resolve 返回 null（当前视图没有搜索）时全部放行', (WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final List<LogicalKeyboardKey> bubbled = <LogicalKeyboardKey>[];
    final FocusNode inner = FocusNode(debugLabel: 'inner');
    addTearDown(inner.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Focus(
          onKeyEvent: (FocusNode _, KeyEvent event) {
            if (event is KeyDownEvent) bubbled.add(event.logicalKey);
            return KeyEventResult.ignored;
          },
          child: FushiHeaderSearchKeys(
            resolve: () => null,
            child: Focus(focusNode: inner, child: const SizedBox()),
          ),
        ),
      ),
    );
    inner.requestFocus();
    await tester.pump();
    await pressCtrl(tester, LogicalKeyboardKey.keyF);
    expect(bubbled, contains(LogicalKeyboardKey.keyF));
    debugDefaultTargetPlatformOverride = null;
  });
}
