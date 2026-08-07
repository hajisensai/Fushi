import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
// `show` 限定：services 自己也有一个同名的 ModifierKey，全量导入会与注册表的
// ModifierKey（input_binding.dart）撞名。
import 'package:flutter/services.dart'
    show KeyDownEvent, KeyEvent, LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_input_bridge.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_layer.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_webview.dart'
    show MinePopupResult;
import 'package:fushi/src/shortcuts/input_binding.dart';

/// BUG-1269 复诉「关词典的鼠标键无效」的守卫。
///
/// 根因不在 JS 桥的逻辑，而在**指针根本没到过弹窗 DOM**：Windows 的
/// `flutter_inappwebview_windows` 用无窗口 WebView2，指针先到 Flutter 再由 fork
/// 转发，而它的 `PointerButton` 枚举没有侧键——后退/前进在转发前被折成 `none` 丢掉。
/// 所以绑到侧键的「关闭词典」在弹窗表面永远收不到 `mousedown`。修法是让指针的第一手
/// 拥有者（那个平台上就是 Flutter 宿主）就地消费，并且两条路径**互斥**，否则中键/右键
/// 会被各触发一次。
void main() {
  group('dictionaryPopupPointerToken', () {
    const DictionaryPopupInputSpec spec = DictionaryPopupInputSpec(
      keyTokens: <String>['Escape'],
      mouseButtons: <int>[3],
    );

    test('侧键(后退)命中 spec 时折成与 JS 桥同形的 token', () {
      expect(
        dictionaryPopupPointerToken(buttons: kBackMouseButton, spec: spec),
        'Mouse3',
      );
    });

    test('token 能被与键盘路径同一个 resolve 反解回按钮号', () {
      final String? token =
          dictionaryPopupPointerToken(buttons: kBackMouseButton, spec: spec);
      expect(MouseBinding.deserialize(token!)?.button, 3);
    });

    test('未绑定的按钮(前进/中键)不产生 token', () {
      expect(
        dictionaryPopupPointerToken(buttons: kForwardMouseButton, spec: spec),
        isNull,
      );
      expect(
        dictionaryPopupPointerToken(buttons: kMiddleMouseButton, spec: spec),
        isNull,
      );
    });

    test('左键永不可绑，即便 spec 里写了也不触发', () {
      expect(
        dictionaryPopupPointerToken(
          buttons: kPrimaryMouseButton,
          spec: const DictionaryPopupInputSpec(mouseButtons: <int>[0]),
        ),
        isNull,
      );
    });

    test('空 spec 不产生 token', () {
      expect(
        dictionaryPopupPointerToken(
          buttons: kBackMouseButton,
          spec: const DictionaryPopupInputSpec(),
        ),
        isNull,
      );
    });
  });

  group('注入脚本与宿主指针所有权互斥', () {
    const DictionaryPopupInputSpec spec = DictionaryPopupInputSpec(
      keyTokens: <String>['Escape'],
      mouseButtons: <int>[2, 3],
    );

    test('宿主拥有指针时，脚本既不装鼠标监听、表也是空的', () {
      final String js =
          dictionaryPopupInputBridgeScript(spec, hostOwnsPointer: true);
      expect(js.contains("addEventListener('mousedown'"), isFalse);
      expect(js.contains("addEventListener('auxclick'"), isFalse);
      // 键表照常下发（键盘那条路不受指针所有权影响）。
      expect(js.contains("'Escape'"), isTrue);
      // 按钮表为空：热槽 WebView 上万一有历史遗留的监听也永不命中。
      expect(js.contains('__hoshiKeyBridgeButtons_hostInputToken'), isTrue);
      expect(RegExp(r'Buttons_hostInputToken.\] = \[\];').hasMatch(js), isTrue);
    });

    test('WebView 拥有指针时，鼠标监听与按钮表都在', () {
      final String js =
          dictionaryPopupInputBridgeScript(spec, hostOwnsPointer: false);
      expect(js.contains("addEventListener('mousedown'"), isTrue);
      expect(RegExp(r'Buttons_hostInputToken.\] = \[2, 3\];').hasMatch(js),
          isTrue);
    });

    test('空 spec 仍生成清表脚本，不触发断言', () {
      final String js = dictionaryPopupInputBridgeScript(
        const DictionaryPopupInputSpec(),
        hostOwnsPointer: true,
      );
      expect(RegExp(r'Keys_hostInputToken.\] = \[\];').hasMatch(js), isTrue);
    });
  });

  group('DictionaryPopupLayer 宿主指针通道', () {
    /// 无结果 + 非搜索态 → 走 Flutter 占位分支，不挂载 WebView（widget 测试里没有
    /// 平台视图）。指针通道包在整层最外面，与是否挂载 WebView 无关。
    Future<List<String>> pumpAndPress(
      WidgetTester tester, {
      required bool hostOwnsPointer,
      required int buttons,
      DictionaryPopupInputSpec spec =
          const DictionaryPopupInputSpec(mouseButtons: <int>[3]),
    }) async {
      final List<String> tokens = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 300,
                height: 200,
                child: DictionaryPopupLayer(
                  result: null,
                  webViewKey: GlobalKey(),
                  onDismiss: () {},
                  onTextSelected: (_, __) {},
                  onLinkClick: (_, __) {},
                  onMineEntry: (_) async => const MinePopupResult(),
                  onDuplicateCheck: (_, __) async => false,
                  inputSpec: spec,
                  onHostInputToken: tokens.add,
                  debugHostOwnsPointer: hostOwnsPointer,
                ),
              ),
            ),
          ),
        ),
      );

      final TestGesture gesture = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
        buttons: buttons,
      );
      await gesture.downWithCustomEvent(
        tester.getCenter(find.byType(DictionaryPopupLayer)),
        PointerDownEvent(
          position: tester.getCenter(find.byType(DictionaryPopupLayer)),
          kind: PointerDeviceKind.mouse,
          buttons: buttons,
        ),
      );
      await gesture.up();
      await tester.pump();
      return tokens;
    }

    testWidgets('宿主拥有指针：弹窗表面按侧键交回宿主', (WidgetTester tester) async {
      final List<String> tokens = await pumpAndPress(
        tester,
        hostOwnsPointer: true,
        buttons: kBackMouseButton,
      );
      expect(tokens, <String>['Mouse3']);
    });

    testWidgets('WebView 拥有指针：宿主不抢，交给弹窗内的 JS 桥', (WidgetTester tester) async {
      final List<String> tokens = await pumpAndPress(
        tester,
        hostOwnsPointer: false,
        buttons: kBackMouseButton,
      );
      expect(tokens, isEmpty);
    });

    testWidgets('未绑定的按钮不打扰宿主', (WidgetTester tester) async {
      final List<String> tokens = await pumpAndPress(
        tester,
        hostOwnsPointer: true,
        buttons: kForwardMouseButton,
      );
      expect(tokens, isEmpty);
    });

    testWidgets('左键照常留给弹窗自身交互', (WidgetTester tester) async {
      final List<String> tokens = await pumpAndPress(
        tester,
        hostOwnsPointer: true,
        buttons: kPrimaryMouseButton,
      );
      expect(tokens, isEmpty);
    });
  });

  group('dictionaryPopupKeyToken', () {
    const DictionaryPopupInputSpec spec = DictionaryPopupInputSpec(
      keyTokens: <String>['Escape', 'Ctrl+KeyD'],
    );

    test('裸键命中', () {
      expect(
        dictionaryPopupKeyToken(
          key: LogicalKeyboardKey.escape,
          modifiers: const <ModifierKey>{},
          spec: spec,
        ),
        'Escape',
      );
    });

    test('组合键按 serialize 的修饰序命中', () {
      expect(
        dictionaryPopupKeyToken(
          key: LogicalKeyboardKey.keyD,
          modifiers: const <ModifierKey>{ModifierKey.ctrl},
          spec: spec,
        ),
        'Ctrl+KeyD',
      );
    });

    test('裸键绑定不被带修饰键的按下命中（与 JS 桥同语义）', () {
      expect(
        dictionaryPopupKeyToken(
          key: LogicalKeyboardKey.escape,
          modifiers: const <ModifierKey>{ModifierKey.shift},
          spec: spec,
        ),
        isNull,
      );
    });

    test('未绑定的键不产生 token', () {
      expect(
        dictionaryPopupKeyToken(
          key: LogicalKeyboardKey.keyQ,
          modifiers: const <ModifierKey>{},
          spec: spec,
        ),
        isNull,
      );
    });
  });

  group('DictionaryPopupLayer 宿主键盘通道（嵌套层焦点断链）', () {
    /// 复刻真实断链：视频/首页查词把整棵浮层挂在**根 Overlay**，宿主页面的
    /// `Focus(onKeyEvent:)` 不是它的祖先。用户点弹窗里的词唤出嵌套层时，平台视图把
    /// Flutter 焦点请求过去 —— 此后按键沿 根 Overlay → Navigator → App 冒泡，永远
    /// 到不了宿主那层 Focus。这里用「页面 Focus 在浮层子树**之外**」+「焦点在浮层
    /// 子树内的节点上」精确重建这个拓扑。
    Future<({List<String> tokens, List<LogicalKeyboardKey> pageKeys})>
        pumpAndKey(
      WidgetTester tester, {
      required LogicalKeyboardKey key,
      DictionaryPopupInputSpec spec =
          const DictionaryPopupInputSpec(keyTokens: <String>['Escape']),
    }) async {
      final List<String> tokens = <String>[];
      final List<LogicalKeyboardKey> pageKeys = <LogicalKeyboardKey>[];
      final FocusNode insidePopup = FocusNode(debugLabel: 'webViewFocusNode');
      addTearDown(insidePopup.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Stack(
            children: <Widget>[
              // 宿主页面：它的快捷键入口在这里，浮层**不在**它的子树内。
              Focus(
                onKeyEvent: (FocusNode node, KeyEvent event) {
                  if (event is KeyDownEvent) pageKeys.add(event.logicalKey);
                  return KeyEventResult.ignored;
                },
                child: const SizedBox.expand(),
              ),
              // 「根 Overlay」侧的浮层子树。
              Center(
                child: SizedBox(
                  width: 300,
                  height: 200,
                  child: DictionaryPopupLayer(
                    result: null,
                    webViewKey: GlobalKey(),
                    onDismiss: () {},
                    onTextSelected: (_, __) {},
                    onLinkClick: (_, __) {},
                    onMineEntry: (_) async => const MinePopupResult(),
                    onDuplicateCheck: (_, __) async => false,
                    inputSpec: spec,
                    onHostInputToken: tokens.add,
                    // 平台视图（WebView）在弹窗里持有的那个 Flutter 焦点节点。
                    overlayWidget: Focus(
                      focusNode: insidePopup,
                      child: const SizedBox.shrink(),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );

      insidePopup.requestFocus();
      await tester.pump();
      expect(insidePopup.hasPrimaryFocus, isTrue,
          reason: '前提：焦点必须真的落在浮层子树里，否则这条守卫测的不是断链场景');

      await tester.sendKeyEvent(key);
      await tester.pump();
      return (tokens: tokens, pageKeys: pageKeys);
    }

    testWidgets('焦点在浮层内按关词典键 → 交回宿主', (WidgetTester tester) async {
      final result = await pumpAndKey(tester, key: LogicalKeyboardKey.escape);
      expect(result.tokens, <String>['Escape']);
      // 宿主页面那层 Focus 确实收不到（这正是原 bug 的现场）——修复靠的是浮层
      // 自己把键交回去，而不是指望冒泡。
      expect(result.pageKeys, isEmpty);
    });

    testWidgets('未绑定的键不消费，照常继续冒泡', (WidgetTester tester) async {
      final result = await pumpAndKey(tester, key: LogicalKeyboardKey.keyQ);
      expect(result.tokens, isEmpty);
    });
  });
}
