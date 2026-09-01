import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_input_bridge.dart';
import 'package:fushi/src/utils/misc/lookup_dismiss_barrier.dart';

/// BUG-1995 复盘守卫：**页面根 [Listener] 在词典浮层可见时收不到指针事件**。
///
/// 本轮修「视频页鼠标侧键关不掉词典」时，第一版在页面根 Listener 的 `onPointerDown`
/// 里写了「浮层可见 → 关顶层浮层」。那段代码**永远不会执行**：
///
/// 浮层可见（或查词搜索中）时，`_buildPopupOverlay` 会往**根 Overlay**
/// （`Overlay.maybeOf(context, rootOverlay: true)`）插一层 `Positioned.fill` 的
/// [LookupDismissBarrier]。barrier 最外面两层确实是 `HitTestBehavior.translucent`，
/// 但它的叶子是 `ColoredBox` —— `_RenderColoredBox` 的命中行为是 **opaque**
/// （颜色 transparent ≠ 命中 transparent）。于是 barrier 子树的 `hitTest` 返回 true，
/// Overlay 的 Stack 就此**停止**向下测试，页面那一层根本不在命中路径上。
///
/// 这条守卫把该几何事实钉死，用的是与真实结构同形的最小复刻（真页面要起
/// AppModel/WebView，跑不动）。它同时是一条**设计约束**：视频页那个入口只服务
/// 「浮层不可见」的表面，关浮层必须走弹窗表面自己的回传路。
void main() {
  testWidgets(
    'GUARD: 根 Overlay 的 dismiss barrier 会吞掉指针，页面根 Listener 不可达',
    (WidgetTester tester) async {
      int pageDowns = 0;
      int barrierDowns = 0;

      // 页面层：等价于 video_fushi_page 的 `_wrapVideoGamepadControls` 根 Listener。
      final OverlayEntry pageEntry = OverlayEntry(
        builder: (BuildContext context) => Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (PointerDownEvent _) => pageDowns++,
          child: const SizedBox.expand(),
        ),
      );
      // 浮层层：等价于 `_buildPopupOverlay` 里那层 barrier。
      final OverlayEntry barrierEntry = OverlayEntry(
        builder: (BuildContext context) => Stack(
          children: <Widget>[
            Positioned.fill(
              child: Listener(
                behavior: HitTestBehavior.translucent,
                onPointerDown: (PointerDownEvent _) => barrierDowns++,
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTapUp: (TapUpDetails _) {},
                  child: const ColoredBox(color: Colors.transparent),
                ),
              ),
            ),
          ],
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Overlay(
            initialEntries: <OverlayEntry>[pageEntry, barrierEntry],
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

      expect(barrierDowns, 1, reason: 'barrier 自己收得到（否则这条守卫测错了对象）');
      expect(
        pageDowns,
        0,
        reason: '页面根 Listener 必须收不到 —— 所以那里不能写任何「关浮层」逻辑',
      );
    },
  );

  test(
    'GUARD: 视频页的鼠标入口里不得出现关浮层调用（它在那儿不可达）',
    () {
      final File page = File(
        'lib/src/pages/implementations/video_fushi_page.dart',
      );
      expect(page.existsSync(), isTrue, reason: '路径过期请更新守卫');
      final String source = page.readAsStringSync();

      const String anchor = 'void _handleVideoPointerDown(';
      final int start = source.indexOf(anchor);
      expect(start, greaterThan(-1), reason: '入口改名了？同步更新本守卫');

      // 取该方法体：从签名后的第一个 '{' 起做花括号配对。
      final int braceOpen = source.indexOf('{', start + anchor.length);
      expect(braceOpen, greaterThan(-1));
      int depth = 0;
      int end = braceOpen;
      for (int i = braceOpen; i < source.length; i++) {
        final String ch = source[i];
        if (ch == '{') depth++;
        if (ch == '}') {
          depth--;
          if (depth == 0) {
            end = i;
            break;
          }
        }
      }
      final String body = source.substring(braceOpen, end + 1);

      expect(
        body.contains('_dismissTopVisiblePopup'),
        isFalse,
        reason: '浮层可见时本入口收不到事件（见上一条守卫），关浮层写在这里是死代码；'
            '该语义由弹窗表面的 onDictionaryPopupInputToken 承担',
      );
      expect(
        body.contains('_hasVisiblePopup'),
        isFalse,
        reason: '同上：本入口只在浮层不可见时可达，不需要也不该判这个',
      );
    },
  );

  // ── BUG-1995 的另一半：浮窗**之外**的那片表面 ───────────────────────────────
  //
  // 上面两条只证明了「页面根 Listener 不可达」，并没有让侧键在浮窗之外真的生效。
  // 症状原话是「侧键压在浮窗上能关，把鼠标移开一点就关不掉」——移开之后指针落在
  // barrier 上，而 barrier 此前对非主键**什么都不做**。下面三条钉住补上的那条通道。

  testWidgets(
    'BUG-1995: barrier 上按侧键会把 buttons 交回宿主（浮窗之外那半边的唯一入口）',
    (WidgetTester tester) async {
      final List<int> seen = <int>[];
      await tester.pumpWidget(
        MaterialApp(
          home: LookupDismissBarrier(
            onTapDismiss: (Offset _) {},
            onSwipeDismiss: () {},
            swipeEnabled: true,
            sensitivity: 0.5,
            onNonPrimaryButtonDown: seen.add,
          ),
        ),
      );

      final TestGesture back = await tester.startGesture(
        const Offset(200, 200),
        buttons: kBackMouseButton,
        kind: PointerDeviceKind.mouse,
      );
      await back.up();
      await tester.pump();

      expect(
        seen,
        <int>[kBackMouseButton],
        reason: '后退键（DOM 3）必须到达宿主 —— 这正是用户绑「关词典」最常用的那个键',
      );
    },
  );

  testWidgets(
    'BUG-1995: barrier 的主键 / 触摸不进这条通道（点击关窗与滑关语义零变化）',
    (WidgetTester tester) async {
      final List<int> seen = <int>[];
      int taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: LookupDismissBarrier(
            onTapDismiss: (Offset _) => taps++,
            onSwipeDismiss: () {},
            swipeEnabled: true,
            sensitivity: 0.5,
            onNonPrimaryButtonDown: seen.add,
          ),
        ),
      );

      // 鼠标左键。
      final TestGesture primary = await tester.startGesture(
        const Offset(200, 200),
        buttons: kPrimaryMouseButton,
        kind: PointerDeviceKind.mouse,
      );
      await primary.up();
      await tester.pump();
      // 触摸。
      final TestGesture touch = await tester.startGesture(const Offset(210, 210));
      await touch.up();
      await tester.pump();

      expect(seen, isEmpty, reason: '主键/触摸恒不进非主键通道，否则正常点击会被当成绑定');
      expect(taps, 2, reason: '两次点击仍照常走 onTapDismiss 关窗（never break userspace）');
    },
  );

  testWidgets(
    'BUG-1995: 关掉「滑动关闭」偏好后，侧键通道照样活着',
    (WidgetTester tester) async {
      // 回归闸门：滑关状态机的第一行就是 `if (!_swipeActive) return;`。侧键分发若写在
      // 它后面，桌面用户（默认可能关掉滑关）会得到一个「设置里绑得上、按下去没反应」
      // 的死绑定 —— 与本 bug 同型。
      final List<int> seen = <int>[];
      await tester.pumpWidget(
        MaterialApp(
          home: LookupDismissBarrier(
            onTapDismiss: (Offset _) {},
            onSwipeDismiss: () {},
            swipeEnabled: false,
            sensitivity: 0.5,
            onNonPrimaryButtonDown: seen.add,
          ),
        ),
      );

      final TestGesture back = await tester.startGesture(
        const Offset(200, 200),
        buttons: kBackMouseButton,
        kind: PointerDeviceKind.mouse,
      );
      await back.up();
      await tester.pump();

      expect(seen, <int>[kBackMouseButton]);
    },
  );

  test(
    'BUG-1995: barrier 与弹窗表面共用同一份 token 判据（不许各判各的）',
    () {
      // 宿主两侧都调 dictionaryPopupPointerToken(buttons:, spec:)：spec 里有的按钮
      // 才折出 token，没有的一律 null。这是「浮窗上能用、浮窗外也能用」的根据。
      const DictionaryPopupInputSpec spec =
          DictionaryPopupInputSpec(mouseButtons: <int>[3]);
      expect(
        dictionaryPopupPointerToken(buttons: kBackMouseButton, spec: spec),
        'Mouse3',
      );
      expect(
        dictionaryPopupPointerToken(buttons: kForwardMouseButton, spec: spec),
        isNull,
        reason: '没绑的按钮在 barrier 上必须无效，不能变成「点哪都关」',
      );

      // 源码守卫：视频页真的把 barrier 的非主键接到了那个入口。
      final File page = File(
        'lib/src/pages/implementations/video_fushi_page.dart',
      );
      final String source = page.readAsStringSync();
      expect(
        source.contains('onNonPrimaryButtonDown: _onDismissBarrierButtonDown'),
        isTrue,
        reason: 'barrier 不接这条通道 = 浮窗之外按侧键原症状复现',
      );
      expect(
        RegExp(
          r'void _onDismissBarrierButtonDown\(int buttons\) \{[^}]*'
          r'dictionaryPopupPointerToken\(',
          dotAll: true,
        ).hasMatch(source),
        isTrue,
        reason: '必须复用弹窗表面同一个折 token 函数，不许在这里另写一套判据',
      );
    },
  );
}
