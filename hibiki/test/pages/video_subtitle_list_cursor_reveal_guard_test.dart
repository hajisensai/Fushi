import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'video_hibiki_page_source_corpus.dart';

/// BUG-391：视频字幕列表侧栏鼠标光标消失（第四轮·双管缓解）。
///
/// 定性（**不是根因修复**）：视频区光标隐藏是**框架层 MouseRegion**（fork
/// `material_desktop.dart:746-750`：控制条 `mount=false` → `cursor:none`、否则 `basic`，走
/// `MouseTracker`，几何只覆盖视频列 Expanded），**不是** native `SetCursor`。侧栏残留隐藏态
/// 的真因是 Flutter Windows embedder #84039 `WM_SETCURSOR` 竞态 + 框架 `MouseCursorManager`
/// `lastSession` 去重（`mouse_cursor.dart:75`）。本轮源码改动只是缓解层——**Windows 真机
/// 截图/录屏是合入硬门槛，源码守卫只锁结构、对真机有效性零增益**（headless 永远复现不了
/// #84039、`none→basic` 在测试环境正常回落）。
///
/// 管 1（源头层）：`controls_theme.part.dart` 的 `hideMouseOnControlsRemoval` 由裸 `true` 改成
/// `!_subtitleListVisible.value`（列表开时视频列 controls MouseRegion 恒走 basic、从未隐藏 →
/// 跨列那次 none→basic 转换不存在），并把构造桌面 theme 的 builder 改成同时监听
/// `_subtitleListVisible`（否则改了值 theme 不重建 = 哑火）。
/// 管 2（侧栏直发，改法 B）：`_forceRevealOsCursorForPanel` 门控只剩桌面、去掉 `_cursorHidden`
/// 那条（上一轮恒早退悖论），`onEnter` 跨列入侧栏无条件直发一次 `activateSystemCursor`。
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

    test(
        '管 2 改法 B：_forceRevealOsCursorForPanel 直发 activateSystemCursor 且只剩桌面门控（去掉 _cursorHidden）',
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
      // 改法 B：上一轮的 `_cursorHidden.value == true` 门控在列表开态恒早退（_hasVideoOverlay
      // 含 _subtitleListVisible → _cursorHidden 恒 false）= 第三轮空转。本轮**去掉**它，
      // onEnter 跨列入侧栏无条件直发。若回退加回该门控，本断言转红（与第三轮恒早退悖论自相矛盾）。
      expect(body.contains('_cursorHidden'), isFalse,
          reason:
              '改法 B：_forceRevealOsCursorForPanel 内不得再有 _cursorHidden 门控（否则列表开态恒早退空转）');
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

    test(
        '管 1·2a：桌面 theme 的 hideMouseOnControlsRemoval 非裸 true、依赖 _subtitleListVisible',
        () {
      // 列表开时禁用控制条淡出隐藏光标 → 视频列 controls MouseRegion 恒走 basic 分支、
      // 从源头消除跨列那次 none→basic 竞态来源。负向：改回裸 true 应转红。
      expect(src.contains('hideMouseOnControlsRemoval: true'), isFalse,
          reason: '管 1·2a：hideMouseOnControlsRemoval 不得是裸 true（列表开时必须翻 false）');
      expect(
          src.contains(
              'hideMouseOnControlsRemoval: !_subtitleListVisible.value'),
          isTrue,
          reason:
              '管 1·2a：hideMouseOnControlsRemoval 须为 !_subtitleListVisible.value（列表开 → 不隐藏光标）');
    });

    test('管 1·2b 防哑火：构造桌面 theme 的 builder 必须监听 _subtitleListVisible', () {
      // 硬前置：2a 让 hideMouseOnControlsRemoval 依赖 _subtitleListVisible，但若构造 theme 的
      // builder 不监听它，翻转时 theme 不重建 = 改了值也白改（哑火）。守卫 _buildVideoControlsInner
      // 内 ListenableBuilder.merge 同时含 _controlLayoutNotifier + _subtitleListVisible。
      final int start = src.indexOf('Widget _buildVideoControlsInner(');
      expect(start, greaterThanOrEqualTo(0),
          reason:
              '应有 _buildVideoControlsInner（构造 VideoControlsThemePair 的 builder）');
      final int end = src.indexOf('\n  Widget ', start + 1);
      final String body = src.substring(start, end > start ? end : src.length);
      // 监听器须同时含布局 + 字幕列表两个 notifier（顺序不强求，但两者都得在）。
      expect(body.contains('Listenable.merge('), isTrue,
          reason:
              '2b：须用 Listenable.merge 合并多个监听源（替代旧 ValueListenableBuilder 单听布局）');
      expect(body.contains('_controlLayoutNotifier'), isTrue,
          reason: '2b：仍须监听布局 notifier（沿用旧 ValueListenableBuilder 的语义）');
      expect(body.contains('_subtitleListVisible'), isTrue,
          reason:
              '2b 防哑火硬前置：构造桌面 theme 的 builder 必须监听 _subtitleListVisible，否则 2a 改了值也白改');
      // 旧的单监听 ValueListenableBuilder 不得残留在本 builder 顶层（否则只听布局 = 哑火回归）。
      expect(
          body.contains(
              'ValueListenableBuilder<VideoControlLayout>(\n      valueListenable: _controlLayoutNotifier'),
          isFalse,
          reason:
              '2b：不得回退成只监听 _controlLayoutNotifier 的单 ValueListenableBuilder（哑火）');
    });
  });

  // 诚实标注：本行为测试用**同构 widget 布局**证「侧栏 MouseRegion 进入即触发回调 + 光标不粘
  // none」，但 headless 测试环境**永远复现不了 #84039**（不接 Win embedder、`none→basic` 正常
  // 回落 basic），故对真机有效性**零增益**——它只证「侧栏有 region 接管 hover」这一结构前提，
  // 真正缓解是否生效**仅 Windows 真机截图/录屏可验（合入硬门槛）**。
  group('行为：同构布局下侧栏光标不粘 none + 进入触发救场（BUG-391·headless 对真机零增益）', () {
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
