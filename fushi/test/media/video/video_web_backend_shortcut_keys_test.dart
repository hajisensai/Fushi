// BUG-5417（反馈 bsozOyEfi1 / yPaPsQ6JYv）：原生播放器页的网页档（YouTube 等站点视频）里，
// S / Shift+S 截图与 PageUp / PageDown 上下一章曾被一刀切成「网页档诚实 no-op」——按下去没有
// 任何反应。截图其实与暂停 OCR 共用页面截帧链路，章节来自站点数据，都能服务。
//
// 这里用焦点驱动走真实按键：默认注册表 → 页级 press-time 解析
// （resolveVideoKeyboardShortcut）→ 网页档动作门控（videoWebBackendSupportsShortcutAction，
// 页面 `_buildVideoShortcutActions` 同源调用），断言 S / ← / → 都落到一个会执行的动作上。
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_player_shortcuts.dart';
import 'package:fushi/src/media/video/web_video_session.dart'
    show webVideoKeyBridgeScript;
import 'package:fushi/src/pages/implementations/dictionary_popup_input_bridge.dart'
    show resolveDictionaryPopupInputToken;
import 'package:fushi/src/pages/implementations/video_fushi_page.dart'
    show videoWebBackendSupportsShortcutAction;
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_registry.dart';

void main() {
  test('网页档能服务的动作：截图 / 带字幕截图 / 快退快进 / 上下一章', () {
    for (final ShortcutAction action in <ShortcutAction>[
      ShortcutAction.videoScreenshot,
      ShortcutAction.videoScreenshotSubtitled,
      ShortcutAction.videoSeekBackward,
      ShortcutAction.videoSeekForward,
      ShortcutAction.videoPreviousChapter,
      ShortcutAction.videoNextChapter,
      ShortcutAction.videoTogglePlayPause,
      ShortcutAction.videoOcrFrame,
    ]) {
      expect(
        videoWebBackendSupportsShortcutAction(action),
        isTrue,
        reason: '$action',
      );
    }
  });

  test('网页档诚实 no-op 的只有要 libmpv 的动作', () {
    for (final ShortcutAction action in <ShortcutAction>[
      ShortcutAction.videoToggleShaderCompare,
      ShortcutAction.videoPreviousFrame,
      ShortcutAction.videoNextFrame,
      ShortcutAction.videoToggleMiniWindow,
    ]) {
      expect(
        videoWebBackendSupportsShortcutAction(action),
        isFalse,
        reason: '$action',
      );
    }
  });

  testWidgets('焦点驱动：画面持焦时 S / ← / → 在网页档都执行', (WidgetTester tester) async {
    final FushiShortcutRegistry registry = FushiShortcutRegistry()
      ..loadDefaults(TargetPlatform.windows);
    final FocusNode surface = FocusNode(debugLabel: 'videoKeyboard');
    addTearDown(surface.dispose);
    final List<ShortcutAction> ran = <ShortcutAction>[];

    await tester.pumpWidget(
      MaterialApp(
        home: Focus(
          focusNode: surface,
          autofocus: true,
          onKeyEvent: (FocusNode node, KeyEvent event) {
            final VideoKeyboardResolution r = resolveVideoKeyboardShortcut(
              registry,
              event,
              modifiers: currentKeyboardModifiers(HardwareKeyboard.instance),
              hasEditableFocus: false,
              hasVisiblePopup: false,
              videoSurfaceHoldsFocus: surface.hasPrimaryFocus,
              videoNavigablePanelOpen: false,
            );
            if (r.dispatch != VideoKeyboardDispatch.run) {
              return KeyEventResult.ignored;
            }
            final ShortcutAction action = r.action!;
            if (videoWebBackendSupportsShortcutAction(action)) ran.add(action);
            return KeyEventResult.handled;
          },
          child: const SizedBox.expand(),
        ),
      ),
    );
    await tester.pump();
    expect(surface.hasPrimaryFocus, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);

    expect(ran, <ShortcutAction>[
      ShortcutAction.videoScreenshot,
      ShortcutAction.videoSeekBackward,
      ShortcutAction.videoSeekForward,
    ]);
  });

  test('WebView 持焦时的键盘桥：S / ← / → 在 token 表里，回传后解析到截图 / 快退 / 快进', () {
    final FushiShortcutRegistry registry = FushiShortcutRegistry()
      ..loadDefaults(TargetPlatform.windows);
    final String script = webVideoKeyBridgeScript(registry);
    for (final (String token, ShortcutAction action)
        in <(String, ShortcutAction)>[
          ('KeyS', ShortcutAction.videoScreenshot),
          ('ArrowLeft', ShortcutAction.videoSeekBackward),
          ('ArrowRight', ShortcutAction.videoSeekForward),
        ]) {
      expect(script, contains("'$token'"), reason: token);
      expect(
        resolveDictionaryPopupInputToken(
          registry: registry,
          token: token,
          scope: ShortcutScope.video,
        ),
        action,
        reason: token,
      );
    }
  });
}
