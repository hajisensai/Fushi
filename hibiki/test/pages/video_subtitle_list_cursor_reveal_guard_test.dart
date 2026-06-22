import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'video_hibiki_page_source_corpus.dart';

/// BUG-391：视频字幕列表侧栏鼠标光标消失。
///
/// 根因：字幕列表是 push-aside 侧栏（[_videoWithSubtitlePanel] 的 Row 兄弟列），几何上
/// 不在视频区 controls 的 cursor:none 胜出层内；但鼠标从画面区（控制条 2s 淡出后
/// media_kit `hideMouseOnControlsRemoval` + 顶层 [_buildCursorOverlay] 把 OS 光标置
/// none）移进侧栏时，侧栏没有任何 region 主动唤回光标 / 续命 media_kit 控制条 → 桌面
/// OS 光标残留隐藏态（与画面字幕盒 BUG-283 同根：cursor:none 胜出 + 缺 hover 唤回）。
///
/// 修复：给字幕列表侧栏内容包一层 [_withSubtitleListCursorReveal]——hover 时调字幕盒
/// 同款救场 [_handleSubtitleHover]（_setCursorHidden(false) + _pokeControlsVisible），
/// 鼠标进侧栏即唤回光标 + 续命控制条。
///
/// media_kit controls 跑不了 headless，故源码守卫锁结构不变量；另用同构布局的 widget
/// 行为测试证「侧栏 MouseRegion 进入即触发 hover 救场回调」与「侧栏光标不粘 none」。
void main() {
  group('源码守卫：字幕列表侧栏光标唤回（BUG-391）', () {
    late String src;
    setUpAll(() {
      src = readVideoHibikiSource();
    });

    test('存在 _withSubtitleListCursorReveal 且复用 _handleSubtitleHover 救场', () {
      final int start = src.indexOf('Widget _withSubtitleListCursorReveal(');
      expect(start, greaterThanOrEqualTo(0), reason: '应有字幕列表侧栏光标唤回包裹器');
      final int next = src.indexOf('\n  Widget ', start + 1);
      final int end = next > start ? next : src.indexOf('\n  void ', start + 1);
      expect(end, greaterThan(start));
      final String body = src.substring(start, end);

      expect(
          body.contains('if (!_isDesktopVideoControls) return child;'), isTrue,
          reason: '仅桌面挂（移动端无 OS 光标语义，透传 child）');
      expect(body.contains('opaque: false'), isTrue,
          reason: 'opaque:false 不阻断指针下探（cue 行点击 / 查词 / 滚动照常）');
      // BUG-391 第三轮：onEnter 必须直发强制光标通道（前次 _handleSubtitleHover 两臂对
      // 侧栏全 no-op，是 no-op 补丁的根因）。撤掉 onEnter 直发即变红。
      expect(
          body.contains('_forceRevealOsCursorForPanel(event.device)'), isTrue,
          reason:
              'onEnter/onHover 必须经 _forceRevealOsCursorForPanel 直发 activateSystemCursor');
      expect(body.contains('onEnter:'), isTrue, reason: '进入侧栏唤回');
      expect(body.contains('onHover:'), isTrue, reason: '侧栏内移动持续唤回');
      expect(body.contains('_handleSubtitleHover(true)'), isTrue,
          reason: 'onEnter 仍保留字幕盒同款救场（无害冗余）');
    });

    test('_forceRevealOsCursorForPanel 直发 activateSystemCursor 且双门控（桌面 + 隐藏态）',
        () {
      final int start =
          src.indexOf('void _forceRevealOsCursorForPanel(int device) {');
      expect(start, greaterThanOrEqualTo(0),
          reason: '应有直发 OS 光标通道的 helper（绕开框架 lastSession 去重）');
      final int end = src.indexOf('\n  }', start) + 4;
      expect(end, greaterThan(start));
      final String body = src.substring(start, end);

      expect(body.contains('SystemChannels.mouseCursor.invokeMethod'), isTrue,
          reason: '必须直发 mouseCursor 通道');
      expect(body.contains("'activateSystemCursor'"), isTrue,
          reason: '通道方法名须为 activateSystemCursor（与框架一致）');
      expect(body.contains("'kind': 'basic'"), isTrue,
          reason: "kind 须为 'basic'（IDC_ARROW），不是 none");
      expect(body.contains("'device': device"), isTrue,
          reason: '设备 id 取自进入侧栏的真实 pointer event');
      expect(body.contains('if (!_isDesktopVideoControls) return;'), isTrue,
          reason: '门控①：仅桌面发');
      expect(body.contains('if (_cursorHidden.value != true) return;'), isTrue,
          reason: '门控②：仅 _cursorHidden==true 才发（防回退成无条件覆写 cue 行手型）');
    });

    test('字幕列表侧栏面板用 _withSubtitleListCursorReveal 包裹', () {
      final int start = src.indexOf('Widget _subtitleJumpSidePanel(');
      expect(start, greaterThanOrEqualTo(0));
      final int end = src.indexOf('\n  Widget ', start + 1);
      final String body = src.substring(start, end > start ? end : src.length);
      expect(body.contains('_withSubtitleListCursorReveal('), isTrue,
          reason: '侧栏内容必须经光标唤回包裹器，否则光标在侧栏残留 none');
      final int wrapIdx = body.indexOf('_withSubtitleListCursorReveal(');
      final int panelIdx = body.indexOf('VideoSubtitleJumpPanel(');
      expect(panelIdx, greaterThan(wrapIdx),
          reason: '包裹器应包住 VideoSubtitleJumpPanel（光标 region 在面板之上）');
    });

    test('_handleSubtitleHover 仍是唯一救场（唤回光标 + 续命控制条）', () {
      final int start =
          src.indexOf('void _handleSubtitleHover(bool hovering) {');
      expect(start, greaterThanOrEqualTo(0));
      final int end = src.indexOf('\n  }', start) + 4;
      final String body = src.substring(start, end);
      expect(body.contains('_setCursorHidden(false)'), isTrue,
          reason: 'hover 唤回光标（让顶层胜出层让位）');
      expect(body.contains('_pokeControlsVisible()'), isTrue,
          reason: '续命控制条（避免 media_kit mount=false 自身 cursor 置 none）');
    });
  });

  group('行为：同构布局下侧栏光标不粘 none + 进入触发救场（BUG-391）', () {
    testWidgets('鼠标移到字幕列表侧栏：光标可见 + 触发 hover 救场', (WidgetTester tester) async {
      bool hoverRescued = false;
      const double panelWidth = 300;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Expanded(
                  child: Container(
                    clipBehavior: Clip.none,
                    color: const Color(0xFF000000),
                    child: const Stack(
                      fit: StackFit.expand,
                      children: <Widget>[
                        ColoredBox(color: Colors.green),
                        Positioned.fill(
                          child: MouseRegion(
                            cursor: SystemMouseCursors.none,
                            child: SizedBox.expand(),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                SizedBox(
                  width: panelWidth,
                  child: MouseRegion(
                    opaque: false,
                    onEnter: (PointerEvent _) => hoverRescued = true,
                    onHover: (PointerEvent _) => hoverRescued = true,
                    child: Material(
                      type: MaterialType.transparency,
                      child: Container(
                        color: const Color(0xEE112233),
                        child: const Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: <Widget>[
                            Padding(
                              padding: EdgeInsets.all(12),
                              child: Text('字幕列表'),
                            ),
                            Divider(height: 1),
                            Expanded(child: SizedBox()),
                          ],
                        ),
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

      await gesture.moveTo(const Offset(250, 300));
      await tester.pump();
      expect(kind(active()), 'none', reason: '视频区控制条淡出态光标应隐藏（none）');
      expect(hoverRescued, isFalse, reason: '尚未进入侧栏');

      await gesture.moveTo(const Offset(650, 300));
      await tester.pump();
      expect(hoverRescued, isTrue,
          reason: '进入字幕列表侧栏应触发 hover 救场（唤回光标 + 续命控制条）');
      expect(kind(active()), isNot('none'), reason: '字幕列表侧栏上光标必须可见（不粘 none）');

      // 收尾：把鼠标移出所有 region 让 MouseTracker 把 cursor session 复位回 basic
      // （否则残留的 none/隐藏 session 会跨测试泄漏污染后续 widget 测试的初始光标态）。
      await gesture.moveTo(const Offset(-100, -100));
      await tester.pump();
    });
  });
}
