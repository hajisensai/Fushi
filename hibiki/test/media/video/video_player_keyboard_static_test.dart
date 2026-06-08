import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 源码守卫：视频键盘交互 + 自动播放——都依赖真实 libmpv player，无法纯单测
/// （测试宿主无 libmpv，`load()` / Player 构造即抛），故在源码层钉死结构。
void main() {
  String read(String relPath) => File(relPath).readAsStringSync();

  group('Escape 退出视频页（覆盖 media_kit 默认）', () {
    final String page =
        read('lib/src/pages/implementations/video_hibiki_page.dart');

    test('桌面控制主题覆盖 keyboardShortcuts', () {
      expect(
          page.contains('keyboardShortcuts: _videoKeyboardShortcuts('), isTrue,
          reason: 'media_kit 默认 Escape 只 exitFullscreen，非全屏吞掉 Esc → 必须整表覆盖');
    });

    test('Escape 非全屏退页面、全屏退全屏', () {
      final RegExpMatch? body = RegExp(
        r'Map<ShortcutActivator, VoidCallback> _videoKeyboardShortcuts\((.*?)\n  \}',
        dotAll: true,
      ).firstMatch(page);
      expect(body, isNotNull, reason: '找不到 _videoKeyboardShortcuts 方法体');
      final String b = body!.group(1)!;
      expect(b.contains('LogicalKeyboardKey.escape'), isTrue);
      expect(b.contains('isFullscreen('), isTrue, reason: '全屏时 Escape 应退全屏');
      expect(b.contains('exitFullscreen('), isTrue);
      expect(b.contains('_handleBackOrExit()'), isTrue,
          reason: '非全屏时 Escape 应退出视频页');
    });

    test('退出汇聚点 PopScope 与 Escape 共用（行为一致）', () {
      expect(page.contains('Future<void> _handleBackOrExit() async'), isTrue);
      // PopScope 的 onPop 与 Escape 都走 _handleBackOrExit。
      expect('_handleBackOrExit()'.allMatches(page).length,
          greaterThanOrEqualTo(2),
          reason: 'PopScope onPop 与 Escape 快捷键都必须汇聚到 _handleBackOrExit');
    });

    test('全屏 helper 用 controls 子树捕获的 context（非本页祖先 context）', () {
      expect(page.contains('_videoControlsContext = controlsContext'), isTrue,
          reason: 'isFullscreen/toggle/exitFullscreen 需 controls 子树内 context');
    });
  });

  group('asbplayer-style playback shortcuts', () {
    final String page =
        read('lib/src/pages/implementations/video_hibiki_page.dart');
    final RegExpMatch body = RegExp(
      r'Map<ShortcutActivator, VoidCallback> _videoKeyboardShortcuts\((.*?)\n  \}',
      dotAll: true,
    ).firstMatch(page)!;
    final String b = body.group(1)!;

    test('arrowLeft 走 skipToPrevCue，无 cue 回退 3s', () {
      final int left = b.indexOf('LogicalKeyboardKey.arrowLeft');
      final int right = b.indexOf('LogicalKeyboardKey.arrowRight');
      expect(left, greaterThanOrEqualTo(0));
      final String leftBlock = b.substring(left, right);
      expect(leftBlock.contains('skipToPrevCue()'), isTrue);
      expect(leftBlock.contains('cues.isEmpty'), isTrue);
      expect(leftBlock.contains('-_asbSeekMs'), isTrue);
    });

    test('arrowRight 走 skipToNextCue，无 cue 回退 3s', () {
      final int right = b.indexOf('LogicalKeyboardKey.arrowRight');
      final String rightBlock = b.substring(right);
      expect(rightBlock.contains('skipToNextCue()'), isTrue);
      expect(rightBlock.contains('_asbSeekMs'), isTrue);
    });

    test('A/D match asbplayer backward/forward seek and Shift+F fast-forwards',
        () {
      expect(page.contains('static const int _asbSeekMs = 3000'), isTrue);
      expect(page.contains('LogicalKeyboardKey.keyA'), isTrue);
      expect(page.contains('seekRelative(-_asbSeekMs)'), isTrue);
      expect(page.contains('LogicalKeyboardKey.keyD'), isTrue);
      expect(page.contains('seekRelative(_asbSeekMs)'), isTrue);
      expect(
        page.contains(
          'SingleActivator(LogicalKeyboardKey.keyF, shift: true)',
        ),
        isTrue,
      );
      expect(page.contains('seekRelative(_asbFastSeekMs)'), isTrue);
    });

    test('subtitle offset has keyboard bindings and 100ms step', () {
      expect(page.contains('static const int _subtitleOffsetStepMs = 100'),
          isTrue);
      expect(page.contains('_adjustSubtitleOffset(-_subtitleOffsetStepMs)'),
          isTrue);
      expect(page.contains('_adjustSubtitleOffset(_subtitleOffsetStepMs)'),
          isTrue);
    });

    test('speed changes in 0.1 steps', () {
      expect(page.contains('static const double _speedStep = 0.1'), isTrue);
      expect(page.contains('_adjustSpeed(_speedStep)'), isTrue);
      expect(page.contains('_adjustSpeed(-_speedStep)'), isTrue);
    });
  });

  group('查词浮层打开时点同句另一个词：切换查词、保持暂停', () {
    final String page =
        read('lib/src/pages/implementations/video_hibiki_page.dart');

    test('dismiss barrier 走 onTapUp → _onDismissBarrierTap（带坐标判定）', () {
      expect(page.contains('onTapUp: (TapUpDetails d) =>'), isTrue);
      expect(page.contains('_onDismissBarrierTap(d.globalPosition)'), isTrue,
          reason: 'barrier 需带坐标判定，而非无脑 _popNestedPopupAt');
    });

    test('_onDismissBarrierTap：命中字符则 _lookupAt（不关栈不恢复），否则 dismiss', () {
      final RegExpMatch? body = RegExp(
        r'void _onDismissBarrierTap\(Offset globalPos\) \{(.*?)\n  \}',
        dotAll: true,
      ).firstMatch(page);
      expect(body, isNotNull, reason: '找不到 _onDismissBarrierTap 方法体');
      final String b = body!.group(1)!;
      final int hitAt = b.indexOf('_subtitleHitTester.hitTest(globalPos)');
      final int lookupAt = b.indexOf('_lookupAt(');
      final int popAt = b.indexOf('_popNestedPopupAt(0)');
      expect(hitAt, greaterThanOrEqualTo(0), reason: '需先反查字幕字符命中');
      expect(lookupAt, greaterThan(hitAt),
          reason: '命中字符后切换查词（保持暂停：_lookupAt 已暂停不再暂停、不清标记）');
      expect(popAt, greaterThan(lookupAt), reason: '未命中字符才 dismiss + 恢复');
    });

    test('字幕 overlay 绑定 _subtitleHitTester', () {
      expect(page.contains('hitTester: _subtitleHitTester'), isTrue);
    });
  });

  group('进页面/换集自动播放', () {
    final String controller =
        read('lib/src/media/video/video_player_controller.dart');
    final String page =
        read('lib/src/pages/implementations/video_hibiki_page.dart');

    test('load 支持 autoPlay 参数', () {
      expect(controller.contains('bool autoPlay = false'), isTrue,
          reason: 'autoPlay 默认 false 保留既有测试/行为');
    });

    test('autoPlay 在恢复 seek 之后调用 player.play()（避免起播闪跳）', () {
      final int restore = controller.indexOf('await player.seek(');
      final int auto = controller.indexOf('if (autoPlay && _player == player)');
      final int play = controller.indexOf('await player.play();');
      expect(restore, greaterThanOrEqualTo(0));
      expect(auto, greaterThan(restore),
          reason: 'autoPlay 播放必须在恢复 seek 之后（否则从 0 起播再跳）');
      expect(play, greaterThan(auto));
    });

    test('页面 _loadVideo 传 autoPlay: true', () {
      expect(page.contains('autoPlay: true'), isTrue, reason: '进页面/换集后应直接开播');
    });
  });
}
