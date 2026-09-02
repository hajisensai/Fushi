import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/mouse_binding_dispatch.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_registry.dart';

/// 鼠标绑定通道的**共享落地件**行为测试：解析阶梯 + 「一次按下只派发一次」的仲裁。
///
/// 这两件事是本轮把鼠标通道从「只有阅读器的 3 个硬编码动作」推广到全表面的地基。
/// 它们必须能纯测：真实页面要起 AppModel / WebView / media_kit，跑不动，而仲裁的
/// 关键性质（内层先、外层后；解析到但没执行的一层不得挡住外层）恰恰只跟 Flutter 的
/// 指针派发次序有关，与页面内容无关。
void main() {
  setUp(MouseBindingDispatch.resetForTest);
  tearDown(MouseBindingDispatch.resetForTest);

  FushiShortcutRegistry registryWith(Map<ShortcutAction, int> mouseByAction) {
    final FushiShortcutRegistry registry = FushiShortcutRegistry()
      ..loadDefaults(TargetPlatform.windows);
    for (final MapEntry<ShortcutAction, int> e in mouseByAction.entries) {
      registry.updateBinding(
        e.key,
        ShortcutBindingSet(
          mouseBindings: <MouseBinding>[MouseBinding(e.value)],
        ),
      );
    }
    return registry;
  }

  group('resolveMouseBindingAction', () {
    test('按阶梯顺序解析，第一个命中的 scope 赢', () {
      // 同一个按钮同时绑在页面 scope 与 universal 上：阶梯在前的那个必须赢，
      // 与键盘「页面专属键优先」逐字同构。
      final FushiShortcutRegistry registry = registryWith(<ShortcutAction, int>{
        ShortcutAction.videoTogglePlayPause: 3,
        ShortcutAction.globalBack: 3,
      });

      expect(
        resolveMouseBindingAction(
          registry: registry,
          buttons: kBackMouseButton,
          ladder: const <ShortcutScope>[
            ShortcutScope.video,
            ShortcutScope.universal,
          ],
        ),
        ShortcutAction.videoTogglePlayPause,
      );
      expect(
        resolveMouseBindingAction(
          registry: registry,
          buttons: kBackMouseButton,
          ladder: const <ShortcutScope>[
            ShortcutScope.universal,
            ShortcutScope.video,
          ],
        ),
        ShortcutAction.globalBack,
        reason: '换个阶梯顺序就换个结果 —— 证明它真的按顺序走，不是碰巧命中',
      );
    });

    test('左键与触摸永远折不出按钮号，故不可绑', () {
      final FushiShortcutRegistry registry = registryWith(<ShortcutAction, int>{
        ShortcutAction.globalBack: 3,
      });
      for (final int buttons in <int>[kPrimaryMouseButton, 0]) {
        expect(
          resolveMouseBindingAction(
            registry: registry,
            buttons: buttons,
            ladder: const <ShortcutScope>[ShortcutScope.universal],
          ),
          isNull,
          reason: '左键是主交互键，绑它会吞掉正常点击 / 划词选区',
        );
      }
    });

    test('WebView 侧入口收的是 DOM button，不再折一次位掩码', () {
      // 页内 JS 给的是 `e.button`（1=中键）。若误当成 Flutter 的 `buttons` 位掩码，
      // 1 就是 kPrimaryMouseButton，会被判成左键而整条丢弃——中键绑定当场失效。
      final FushiShortcutRegistry registry = registryWith(<ShortcutAction, int>{
        ShortcutAction.readerPageForward: 1,
      });
      expect(
        resolveMouseBindingActionForButton(
          registry: registry,
          button: 1,
          ladder: const <ShortcutScope>[ShortcutScope.reader],
        ),
        ShortcutAction.readerPageForward,
      );
      expect(
        resolveMouseBindingAction(
          registry: registry,
          buttons: 1, // = kPrimaryMouseButton
          ladder: const <ShortcutScope>[ShortcutScope.reader],
        ),
        isNull,
        reason: '两个入口的入参语义不同，这条钉住它们没被混用',
      );
    });
  });

  group('MouseBindingDispatch 仲裁', () {
    /// 页面层 [Listener] 套在 app 根层 [Listener] 里，复刻真实结构。
    /// [innerExecutes] = 内层「解析到动作后是否真的执行了它」。
    Future<List<String>> pumpNested(
      WidgetTester tester, {
      required bool innerExecutes,
    }) async {
      final List<String> fired = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: (PointerDownEvent event) {
              // 外层（app 根兜底）
              dispatchClaimedMouseAction(event, () {
                fired.add('outer');
                return true;
              });
            },
            child: Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: (PointerDownEvent event) {
                // 内层（页面）
                dispatchClaimedMouseAction(event, () {
                  if (!innerExecutes) return false; // 解析到了但本页没消费
                  fired.add('inner');
                  return true;
                });
              },
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );
      final TestGesture gesture = await tester.startGesture(
        const Offset(200, 200),
        buttons: kBackMouseButton,
        kind: PointerDeviceKind.mouse,
      );
      await gesture.up();
      await tester.pump();
      return fired;
    }

    testWidgets('内层执行后外层让路：同一次按下只派发一次', (WidgetTester tester) async {
      expect(
        await pumpNested(tester, innerExecutes: true),
        <String>['inner'],
        reason: '没有仲裁的话这里是 [inner, outer] —— 绑「返回上一级」的侧键一键退两级',
      );
    });

    testWidgets('内层解析到却没执行时，外层照常接手', (WidgetTester tester) async {
      expect(
        await pumpNested(tester, innerExecutes: false),
        <String>['outer'],
        reason: '等价于键盘的「ignored 继续冒泡」；抢先认领会让外层合法绑定被白白吃掉',
      );
    });

    testWidgets('两次独立按下互不影响（认领按 pointer id，不是全局一次性）', (
      WidgetTester tester,
    ) async {
      final List<String> fired = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: (PointerDownEvent event) {
              dispatchClaimedMouseAction(event, () {
                fired.add('down');
                return true;
              });
            },
            child: const SizedBox.expand(),
          ),
        ),
      );
      for (int i = 0; i < 2; i++) {
        final TestGesture g = await tester.startGesture(
          const Offset(100, 100),
          buttons: kBackMouseButton,
          kind: PointerDeviceKind.mouse,
        );
        await g.up();
        await tester.pump();
      }
      expect(fired, <String>['down', 'down']);
    });
  });
}
