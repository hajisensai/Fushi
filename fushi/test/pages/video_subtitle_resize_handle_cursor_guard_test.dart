import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'video_fushi_page_source_corpus.dart';

/// BUG-930：视频字幕列表左边缘的宽度拖拽把手（[_subtitleListResizeHandle]，BUG-877）在桌面
/// hover 时不显 `resizeLeftRight`（左右箭头）光标——用户看不到「可调宽」的提示。
///
/// 根因：字幕列表侧栏整列被 [_withSubtitleListCursorReveal] 包裹，其 `onHover` **每帧无条件**
/// 经 [_forceRevealOsCursorForPanel] 走 `SystemChannels.mouseCursor.activateSystemCursor`
/// **原生强设** OS 光标为 `basic`（箭头，BUG-391 对「跨列残留隐藏光标」的推测性缓解）。这个
/// 原生 SetCursor 绕过框架 MouseTracker，即便指针在把手上、框架已为把手 MouseRegion 解析出
/// `resizeLeftRight`，也会被每帧的原生「强设 basic」立刻盖回箭头 → 调宽光标永远出不来。
///
/// 根因修：把手进 / 出时翻 [_pointerOverSubtitleResizeHandle]；[_forceRevealOsCursorForPanel]
/// 在该标志为真时**提前返回、不再原生强设 basic**，把光标让位给把手 MouseRegion 声明的 resize。
/// BUG-391 在面板其余区域的缓解**保持不变**（把手区域本就「已明确要什么光标」，无需残留唤回）。
///
/// **诚实标注**：#84039 的原生 `SetCursor` 竞态 headless 永远复现不了，故「原生强设是否真被
/// 让位」的最终有效性仍需 Windows 真机验证。源码守卫只锁「让位门控 + 把手 enter/exit 接线」这一
/// 结构前提；下方行为测试只在同构布局里证「框架层把手 MouseRegion 能解析出 resizeLeftRight」。
void main() {
  group('源码守卫：字幕列表宽度把手光标不被原生唤回盖掉（BUG-930）', () {
    late String src;
    setUpAll(() {
      src = readVideoFushiSource();
    });

    test('主壳声明 _pointerOverSubtitleResizeHandle 标志', () {
      expect(src.contains('bool _pointerOverSubtitleResizeHandle = false;'),
          isTrue,
          reason: '需有「指针是否在把手上」的标志，供 _forceRevealOsCursorForPanel 让位');
    });

    test('_forceRevealOsCursorForPanel 悬在把手上时提前返回（不原生强设 basic）', () {
      final int start =
          src.indexOf('void _forceRevealOsCursorForPanel(int device) {');
      expect(start, greaterThanOrEqualTo(0), reason: '应有直发 OS 光标通道的 helper');
      final int end = src.indexOf('\n  }', start) + 4;
      expect(end, greaterThan(start));
      final String body = src.substring(start, end);

      final int guardIdx =
          body.indexOf('if (_pointerOverSubtitleResizeHandle) return;');
      expect(guardIdx, greaterThanOrEqualTo(0),
          reason: '把手上必须让位：提前 return，不再原生强设 basic');
      final int invokeIdx =
          body.indexOf('SystemChannels.mouseCursor.invokeMethod');
      expect(invokeIdx, greaterThan(guardIdx),
          reason: '让位门控必须在原生 activateSystemCursor 之前（否则仍会先盖掉 resize 光标）');
    });

    test('_subtitleListResizeHandle 保留 resize 光标且 enter/exit 翻标志', () {
      final int start = src.indexOf('Widget _subtitleListResizeHandle({');
      expect(start, greaterThanOrEqualTo(0), reason: '应有字幕列表宽度拖拽把手');
      final int end = src.indexOf('\n  Widget ', start + 1);
      final String body = src.substring(start, end > start ? end : src.length);

      expect(
          body.contains('cursor: SystemMouseCursors.resizeLeftRight'), isTrue,
          reason: '把手 MouseRegion 必须声明 resizeLeftRight（左右箭头）光标');
      expect(body.contains('_pointerOverSubtitleResizeHandle = true'), isTrue,
          reason: 'onEnter 必须置标志真，让 _forceRevealOsCursorForPanel 让位');
      expect(body.contains('_pointerOverSubtitleResizeHandle = false'), isTrue,
          reason: 'onExit 必须复位标志，面板其余区域仍走 basic 唤回缓解');
      expect(body.contains('onEnter:'), isTrue, reason: '需接线 onEnter 置标志');
      expect(body.contains('onExit:'), isTrue, reason: '需接线 onExit 复位标志');
    });
  });

  // 诚实标注：headless 复现不了 #84039 原生 SetCursor 竞态，本行为测试只证**框架层**结构前提
  // ——把手 MouseRegion（叠在面板之上、声明 resizeLeftRight）能在 MouseTracker 解析中胜过外层
  // 声明式 basic 包裹层。真正被质疑的「原生每帧强设 basic 是否已让位」仅 Windows 真机可验。
  group('行为：同构布局下把手上光标解析为 resizeLeftRight（BUG-930·headless 对真机零增益）', () {
    testWidgets('把手叠在面板左缘、外层声明 basic：把手上光标 = resizeLeftRight',
        (WidgetTester tester) async {
      const double panelWidth = 300;
      bool overHandle = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                const Expanded(child: ColoredBox(color: Color(0xFF000000))),
                SizedBox(
                  width: panelWidth,
                  // 同构外层：_withSidePanelOpaqueCursor 声明式 opaque basic。
                  child: MouseRegion(
                    opaque: true,
                    cursor: SystemMouseCursors.basic,
                    // 同构救场层：_withSubtitleListCursorReveal（opaque:false，onHover 唤回）。
                    child: MouseRegion(
                      opaque: false,
                      onHover: (PointerHoverEvent _) {},
                      child: Stack(
                        children: <Widget>[
                          const Positioned.fill(
                            child: ColoredBox(color: Color(0xEE112233)),
                          ),
                          Positioned(
                            left: 0,
                            top: 0,
                            bottom: 0,
                            // 同构把手：叠在面板左缘、声明 resizeLeftRight + enter/exit 翻标志。
                            child: MouseRegion(
                              cursor: SystemMouseCursors.resizeLeftRight,
                              onEnter: (PointerEnterEvent _) =>
                                  overHandle = true,
                              onExit: (PointerExitEvent _) =>
                                  overHandle = false,
                              child: const SizedBox(width: 8),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );

      final TestGesture gesture =
          await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(gesture.removePointer);

      String kind(MouseCursor c) =>
          c is SystemMouseCursor ? c.kind : c.toString();
      MouseCursor active() =>
          RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1)!;

      // 面板本体（把手右侧）：外层声明式 basic 胜出。
      await tester.pump();
      final Size size = tester.getSize(find.byType(MaterialApp));
      final double panelLeft = size.width - panelWidth;
      await gesture.moveTo(Offset(panelLeft + 150, size.height / 2));
      await tester.pump();
      expect(kind(active()), 'basic', reason: '面板本体上光标为 basic（外层声明式胜出）');
      expect(overHandle, isFalse, reason: '尚未进把手');

      // 把手上（面板左缘 8px 内）：把手 MouseRegion（更靠前）解析出 resizeLeftRight。
      await gesture.moveTo(Offset(panelLeft + 4, size.height / 2));
      await tester.pump();
      expect(overHandle, isTrue,
          reason: '进把手应翻标志（真码据此让 _forceRevealOsCursorForPanel 让位）');
      expect(kind(active()), 'resizeLeftRight',
          reason: '把手上框架层光标必须解析为 resizeLeftRight（叠在面板之上、胜过外层 basic）');

      // 收尾：移出所有 region，复位 cursor session 防跨测试泄漏。
      await gesture.moveTo(const Offset(-100, -100));
      await tester.pump();
    });
  });
}
