// BUG-1347 / PR#672 的 Windows 实机复测。
//
// 与 widget 层守卫 `test/pages/dictionary_popup_pointer_input_test.dart` 的分工：
// 那份用 `debugHostOwnsPointer` **显式注入**判据、用回调计数当断言终点，在任何平台
// 都跑同一条分支；本文件只在真 Windows runner 上跑（`tool/run_windows_itest.ps1`），
// 因此三件 widget 层测不到的事在这里才成立：
//   1. `hostOwnsDictionaryPopupPointerInput` 取的是**运行平台真值**（无注入）；
//   2. 浮层挂在**真的根 Overlay**（`Overlay.of(context, rootOverlay: true)`），宿主页面
//      的 `Focus(onKeyEvent:)` 真的不是它的祖先 —— 断链是真实拓扑造成的，不是摆拍；
//   3. 断言落在**真实 UI 效果**：弹窗从树里消失（`findsNothing`），不是「回调收到了
//      一个字符串」。
//
// token 表也不是手写的：走真注册表 `loadDefaults(windows)` → 用户改键（给关词典补一个
// 侧键绑定）→ 真 `dictionaryPopupInputSpecFor` 导出 → 真 `resolveDictionaryPopupInputToken`
// 反解 → 真动作 → 真关闭。链路上任何一环漂移，这条测试就红。
//
// 运行：
//   .\hibiki\tool\run_windows_itest.ps1 integration_test\dismiss_dict_popup_input_windows_itest.dart

import 'package:flutter/gestures.dart' show PointerDeviceKind, kBackMouseButton;
import 'package:flutter/material.dart';
// `show` 限定：services 自己也有一个同名 ModifierKey，全量导入会与注册表的
// ModifierKey（input_binding.dart）撞名。
import 'package:flutter/services.dart'
    show KeyDownEvent, KeyEvent, LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:fushi/src/pages/implementations/dictionary_popup_input_bridge.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_layer.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_webview.dart'
    show MinePopupResult;
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_registry.dart';

import 'helpers/focus_driver.dart';

/// 本轮观察到的事实。宿主页面收到的键单独记，用来证明「断链」是真的。
class _HostLog {
  final List<String> tokens = <String>[];
  final List<LogicalKeyboardKey> hostPageKeys = <LogicalKeyboardKey>[];
  final FocusNode pageNode = FocusNode(debugLabel: 'hostPageTarget');
  final FocusNode popupInnerNode = FocusNode(debugLabel: 'popupPlatformView');
  int closeCount = 0;

  void dispose() {
    pageNode.dispose();
    popupInnerNode.dispose();
  }
}

/// 真注册表 + 用户改键：关词典 = `Escape`（默认）+ 侧键后退 `Mouse3`（用户加的，
/// BUG-1347 报告里正是这条绑定在弹窗表面永远无效）。
FushiShortcutRegistry _registryWithSideButtonDismiss() {
  final FushiShortcutRegistry registry = FushiShortcutRegistry();
  registry.loadDefaults(TargetPlatform.windows);
  final Map<String, dynamic> json = registry.toJson();
  json[ShortcutAction.readerDismissDict.key] = <String, dynamic>{
    'keyboard': <String>['Escape'],
    'gamepad': <String>[],
    'mouse': <String>['Mouse3'],
    'wheel': <String>[],
  };
  registry.loadFromJson(json);
  return registry;
}

/// 复刻真实拓扑：宿主页面（带 `Focus(onKeyEvent:)` 快捷键入口）在路由里，查词浮层
/// 插进**根 Overlay**（视频/首页查词就是这么挂的，为了盖过 media_kit 全屏路由）。
class _HostShell extends StatefulWidget {
  const _HostShell({
    required this.registry,
    required this.spec,
    required this.log,
  });

  final FushiShortcutRegistry registry;
  final DictionaryPopupInputSpec spec;
  final _HostLog log;

  @override
  State<_HostShell> createState() => _HostShellState();
}

class _HostShellState extends State<_HostShell> {
  OverlayEntry? _entry;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _insertPopup());
  }

  @override
  void dispose() {
    _entry?.remove();
    _entry = null;
    super.dispose();
  }

  void _insertPopup() {
    if (!mounted || _entry != null) return;
    final OverlayEntry entry = OverlayEntry(
      builder: (BuildContext _) => Center(
        child: SizedBox(
          width: 320,
          height: 220,
          child: DictionaryPopupLayer(
            // result=null 且非搜索态 → 走 Flutter 占位分支，不挂载 WebView。
            // 输入通道包在整层最外面，与是否挂载 WebView 无关，所以这条测试不需要
            // 真 WebView2（那在离屏 runner 里也取不到证据）。
            result: null,
            webViewKey: GlobalKey(),
            onDismiss: _closePopup,
            onTextSelected: (_, __) {},
            onLinkClick: (_, __) {},
            onMineEntry: (_) async => const MinePopupResult(),
            onDuplicateCheck: (_, __) async => false,
            inputSpec: widget.spec,
            onHostInputToken: _onHostInputToken,
            // 平台视图（WebView）在弹窗里持有的那个 Flutter 焦点节点：真实产品路径是
            // `custom_platform_view` 的 onPointerDown → requestFocus 把焦点抢过去。
            overlayWidget: Focus(
              focusNode: widget.log.popupInnerNode,
              child: const SizedBox(width: 48, height: 24),
            ),
          ),
        ),
      ),
    );
    _entry = entry;
    Overlay.of(context, rootOverlay: true).insert(entry);
  }

  void _closePopup() {
    if (_entry == null) return;
    _entry!.remove();
    _entry = null;
    widget.log.closeCount++;
  }

  /// 弹窗交回来的 token → 真 resolve → 真动作。与宿主页面那条链**同一个**落地入口。
  void _onHostInputToken(String token) {
    widget.log.tokens.add(token);
    final ShortcutAction? action = resolveDictionaryPopupInputToken(
      registry: widget.registry,
      token: token,
      scope: ShortcutScope.reader,
    );
    if (action == ShortcutAction.readerDismissDict) _closePopup();
  }

  /// 宿主页面自己那层快捷键入口（就是 BUG-1347 里「永远收不到」的那个 Focus）。
  KeyEventResult _onHostPageKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    widget.log.hostPageKeys.add(event.logicalKey);
    final ShortcutAction? action = widget.registry.resolveKeyboard(
      event.logicalKey,
      modifiers: activeModifierKeys(),
      scope: ShortcutScope.reader,
    );
    if (action == ShortcutAction.readerDismissDict) {
      _closePopup();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      onKeyEvent: _onHostPageKey,
      child: Scaffold(
        body: Center(
          child: Focus(
            focusNode: widget.log.pageNode,
            child: const SizedBox(width: 120, height: 48),
          ),
        ),
      ),
    );
  }
}

Future<_HostLog> _pumpHost(
  WidgetTester tester,
  FushiShortcutRegistry registry,
  DictionaryPopupInputSpec spec,
) async {
  final _HostLog log = _HostLog();
  addTearDown(log.dispose);
  await tester.pumpWidget(
    MaterialApp(home: _HostShell(registry: registry, spec: spec, log: log)),
  );
  // 有界 pump（live UI 禁 pumpAndSettle）：等 post-frame 把浮层插进根 Overlay。
  for (int i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(find.byType(DictionaryPopupLayer), findsOneWidget,
      reason: '前提：浮层必须真的挂进根 Overlay，否则后面测的不是断链场景');
  return log;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late FushiShortcutRegistry registry;
  late DictionaryPopupInputSpec spec;

  setUp(() {
    registry = _registryWithSideButtonDismiss();
    spec = dictionaryPopupInputSpecFor(
      registry: registry,
      actions: const <ShortcutAction>[ShortcutAction.readerDismissDict],
    );
  });

  testWidgets('前提：真注册表导出的 spec 同时含关词典的键与侧键', (WidgetTester tester) async {
    expect(spec.keyTokens, contains('Escape'));
    expect(spec.mouseButtons, contains(3));
  });

  testWidgets('Windows 运行时真值：指针归宿主，注入脚本不装鼠标监听也不下发按钮表',
      (WidgetTester tester) async {
    // 无 debug 注入 —— 这是本机真平台判据。
    expect(hostOwnsDictionaryPopupPointerInput, isTrue,
        reason: 'Windows 的无窗口 WebView2 由 Flutter 第一手拿指针');

    // 同样不传 hostOwnsPointer：取运行平台默认，验的是真正会注进 WebView 的那份脚本。
    final String js = dictionaryPopupInputBridgeScript(spec);
    expect(js.contains("addEventListener('mousedown'"), isFalse,
        reason: '装了就是第二条指针路径 → 同一次按下双触发');
    expect(js.contains("addEventListener('auxclick'"), isFalse);
    expect(RegExp(r'Buttons_hostInputToken.\] = \[\];').hasMatch(js), isTrue,
        reason: '热槽 WebView 长期存活，表必须被清空覆盖而不只是「这次没装」');
    // 键表照常下发：键盘那条路不受指针所有权影响（JS 桥与 Flutter 焦点互斥）。
    expect(js.contains("'Escape'"), isTrue);
  });

  testWidgets('嵌套弹窗（焦点在浮层内）按关词典键 → 弹窗真的关掉，且宿主页面 Focus 全程没收到键',
      (WidgetTester tester) async {
    final _HostLog log = await _pumpHost(tester, registry, spec);
    final FocusDriver driver = FocusDriver(tester);

    // 焦点驱动（无坐标点击）：走 FocusDriver 认可的 requestFocusInside，它复刻的正是
    // 产品路径 —— 平台视图 onPointerDown → requestFocus 把焦点请求进浮层子树。
    final bool landed =
        await driver.requestFocusInside(find.byType(DictionaryPopupLayer));
    expect(landed, isTrue, reason: '焦点必须真的落进浮层子树，否则测的不是嵌套场景');
    expect(log.popupInnerNode.hasPrimaryFocus, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(milliseconds: 250));

    // ① 真实效果：弹窗从树里消失（原始失败路径是「按了没反应」）。
    expect(find.byType(DictionaryPopupLayer), findsNothing);
    expect(log.closeCount, 1);
    // ② token 走的是弹窗层交回宿主这条新链。
    expect(log.tokens, <String>['Escape']);
    // ③ 断链是真的：宿主页面那层 Focus 一个键都没收到 —— 修复不是靠冒泡碰运气。
    expect(log.hostPageKeys, isEmpty,
        reason: '根 Overlay → Navigator → App 的冒泡链本来就不经过宿主页面 Focus');
  });

  testWidgets('第一层（焦点在宿主页面上）同一键仍走宿主原链关闭 —— 无回归', (WidgetTester tester) async {
    final _HostLog log = await _pumpHost(tester, registry, spec);
    final FocusDriver driver = FocusDriver(tester);

    // Tab 遍历落到页面控件上（纯焦点驱动）。
    final bool onPage =
        await driver.focusUntil(() => log.pageNode.hasPrimaryFocus);
    expect(onPage, isTrue, reason: 'Tab 必须能落到宿主页面的可聚焦控件上');

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.byType(DictionaryPopupLayer), findsNothing);
    expect(log.closeCount, 1);
    // 这条走的是宿主页面自己的 Focus，弹窗层不该插手（否则就是双触发）。
    // 只断言 Escape **到过**宿主这层：驱动焦点用的 Tab 同样会经过宿主 Focus 被记下
    // 来，写死整个键序列等于把 FocusDriver 的遍历实现细节钉进断言（实测红在这里，
    // actual = [Tab, Escape]），而它与本用例要证明的「第一层没回归」无关。
    expect(log.hostPageKeys, contains(LogicalKeyboardKey.escape));
    expect(log.tokens, isEmpty);
  });

  testWidgets('弹窗表面按鼠标侧键 → 真的关掉，且只触发一次（无双触发）', (WidgetTester tester) async {
    final _HostLog log = await _pumpHost(tester, registry, spec);

    // 指针本身就是被测对象（这条路径不可能靠焦点驱动复现），故必须发真指针事件；
    // 它不是「用坐标点击代替焦点导航」。
    final Offset surface = tester.getCenter(find.byType(DictionaryPopupLayer));
    final TestGesture gesture = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
      buttons: kBackMouseButton,
    );
    await gesture.downWithCustomEvent(
      surface,
      PointerDownEvent(
        position: surface,
        kind: PointerDeviceKind.mouse,
        buttons: kBackMouseButton,
      ),
    );
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.byType(DictionaryPopupLayer), findsNothing,
        reason: '原始失败：侧键在弹窗表面永远无反应');
    // 只关一次、只回传一个 token —— 宿主 Listener 与 JS 桥互斥的可观测证据。
    expect(log.closeCount, 1);
    expect(log.tokens, <String>['Mouse3']);
  });
}
