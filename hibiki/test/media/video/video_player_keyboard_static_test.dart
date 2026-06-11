import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 源码守卫：视频键盘交互 + 自动播放——都依赖真实 libmpv player，无法纯单测
/// （测试宿主无 libmpv，`load()` / Player 构造即抛），故在源码层钉死结构。
void main() {
  String read(String relPath) => File(relPath).readAsStringSync();

  group('Escape 退出视频页（覆盖 media_kit 默认）', () {
    final String page =
        read('lib/src/pages/implementations/video_hibiki_page.dart');
    final String shortcuts =
        read('lib/src/media/video/video_player_shortcuts.dart');

    test('桌面控制主题覆盖 keyboardShortcuts', () {
      expect(
          page.contains('keyboardShortcuts: _videoKeyboardShortcuts('), isTrue,
          reason: 'media_kit 默认 Escape 只 exitFullscreen，非全屏吞掉 Esc → 必须整表覆盖');
    });

    test('Escape 非全屏退页面、全屏退全屏', () {
      expect(shortcuts.contains('LogicalKeyboardKey.escape'), isTrue);
      expect(page.contains('escape: () {'), isTrue,
          reason: '页面必须把 Escape action 接入真实退出逻辑');
      expect(page.contains('isFullscreen('), isTrue, reason: '全屏时 Escape 应退全屏');
      expect(page.contains('_exitVideoFullscreen('), isTrue,
          reason: 'Escape 全屏退出必须走 Hibiki 中和后的 fullscreen helper');
      expect(page.contains('_handleBackOrExit()'), isTrue,
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
    final String shortcuts =
        read('lib/src/media/video/video_player_shortcuts.dart');

    test('TODO-090：普通 arrowLeft = 时间 seek（seekBackward）', () {
      // 普通方向键不再绑跳句，改绑 ±秒时间 seek（asbplayer 习惯）。
      final int left = shortcuts.indexOf('LogicalKeyboardKey.arrowLeft):');
      expect(left, greaterThanOrEqualTo(0), reason: '普通（无修饰键）arrowLeft 必须存在');
      final String leftLine =
          shortcuts.substring(left, shortcuts.indexOf('\n', left));
      expect(leftLine.contains('actions.seekBackward'), isTrue,
          reason: '普通 arrowLeft = 时间回退 seek（TODO-090）');
      // 普通方向键不应绑句子跳转（那是 Ctrl 组合的活）。
      expect(leftLine.contains('previousSubtitle'), isFalse);
    });

    test('TODO-090：普通 arrowRight = 时间 seek（seekForward）', () {
      final int right = shortcuts.indexOf('LogicalKeyboardKey.arrowRight):');
      expect(right, greaterThanOrEqualTo(0));
      final String rightLine =
          shortcuts.substring(right, shortcuts.indexOf('\n', right));
      expect(rightLine.contains('actions.seekForward'), isTrue,
          reason: '普通 arrowRight = 时间前进 seek（TODO-090）');
      expect(rightLine.contains('nextSubtitle'), isFalse);
    });

    test('TODO-090：Ctrl+←/→ = 上/下一句字幕（句子 seek）', () {
      final int ctrlLeft =
          shortcuts.indexOf('LogicalKeyboardKey.arrowLeft, control: true');
      final int ctrlRight =
          shortcuts.indexOf('LogicalKeyboardKey.arrowRight, control: true');
      expect(ctrlLeft, greaterThanOrEqualTo(0), reason: 'Ctrl+← 必须绑句子跳转');
      expect(ctrlRight, greaterThanOrEqualTo(0), reason: 'Ctrl+→ 必须绑句子跳转');
      expect(shortcuts.indexOf('actions.previousSubtitle', ctrlLeft),
          greaterThan(ctrlLeft),
          reason: 'Ctrl+← = previousSubtitle');
      expect(shortcuts.indexOf('actions.nextSubtitle', ctrlRight),
          greaterThan(ctrlRight),
          reason: 'Ctrl+→ = nextSubtitle');
    });

    test('TODO-085：Ctrl+← 上句太远退化回退 Xs（skipToPrevCueOrSeekBack）', () {
      // previousSubtitle action 走集中决策方法，内部按 seekSeconds 阈值跳句 or 回退。
      expect(page.contains('skipToPrevCueOrSeekBack('), isTrue,
          reason: 'Ctrl+← 必须走含「上句太远回退 Xs」退化的决策方法');
      expect(page.contains('seekSeconds: _asbConfig.seekSeconds'), isTrue,
          reason: '退化阈值用配置的 seekSeconds 秒');
      // TODO-073：下一句也集中到 skipToNextCueOrSeekForward（无字幕时前进 Xs、
      // 不再卡住 / 回开头），与 previousSubtitle 的 skipToPrevCueOrSeekBack 对称。
      expect(page.contains('skipToNextCueOrSeekForward('), isTrue,
          reason: '下一句走含「无字幕前进 Xs」的集中决策方法（TODO-073）');
      expect(page.contains('_asbSeekMs'), isTrue);
    });

    test('TODO-085 决策纯函数 prevSeekDecisionFor 存在并按 seekSeconds 阈值退化', () {
      final String controller =
          read('lib/src/media/video/video_player_controller.dart');
      expect(
          controller.contains('static PrevSeekDecision prevSeekDecisionFor('),
          isTrue);
      expect(controller.contains('final int thresholdMs = seekSeconds * 1000;'),
          isTrue,
          reason: '阈值 = seekSeconds 秒');
      expect(controller.contains('if (gapMs > thresholdMs)'), isTrue,
          reason: 'gap 超过阈值才退化成回退 Xs（> 才退化，恰好等于仍跳句）');
    });

    test('A/D and Shift+F use one configured asbplayer seek value', () {
      expect(page.contains('int get _asbSeekMs =>'), isTrue);
      expect(page.contains('_asbConfig.seekSeconds * 1000'), isTrue);
      expect(page.contains('_asbFastSeekMs'), isFalse);
      expect(page.contains('fastSeekSeconds'), isFalse);
      expect(shortcuts.contains('LogicalKeyboardKey.keyA'), isTrue);
      expect(page.contains('seekRelative(-_asbSeekMs)'), isTrue);
      expect(shortcuts.contains('LogicalKeyboardKey.keyD'), isTrue);
      expect(page.contains('seekRelative(_asbSeekMs)'), isTrue);
      final int shiftF = shortcuts.indexOf('LogicalKeyboardKey.keyF,');
      expect(shiftF, greaterThanOrEqualTo(0));
      expect(shortcuts.indexOf('shift: true', shiftF), greaterThan(shiftF));
      expect(page.contains('seekRelative(_asbSeekMs)'), isTrue);
    });

    test('up/down remain volume keys and do not adjust subtitle offset', () {
      final int up = shortcuts.indexOf('LogicalKeyboardKey.arrowUp');
      final int down = shortcuts.indexOf('LogicalKeyboardKey.arrowDown');
      final int equal = shortcuts.indexOf('LogicalKeyboardKey.equal');
      expect(up, greaterThanOrEqualTo(0));
      expect(down, greaterThan(up));
      expect(equal, greaterThan(down));
      final String arrowBlock = shortcuts.substring(up, equal);
      expect(arrowBlock.contains('actions.volumeUp'), isTrue);
      expect(arrowBlock.contains('actions.volumeDown'), isTrue);
      expect(page.contains('_adjustVolume(_volumeStep)'), isTrue);
      expect(page.contains('_adjustVolume(-_volumeStep)'), isTrue);
      expect(arrowBlock.contains('_adjustSubtitleOffset'), isFalse);
    });

    test('subtitle sync is a settings control, not an arrow-key binding', () {
      // TODO-060：字幕调轴改由设置面板的「字幕调轴」行（滑条 + ± 按钮 + 数值输入框）
      // 经 onSetDelay → _setDelayMs 绝对提交，不再走旧的 _adjustSubtitleOffset 增量
      // 回调（已删）。字幕调轴绝不能绑到方向键（方向键恒为音量）。
      expect(page.contains('onSetDelay: _setDelayMs'), isTrue);
      expect(page.contains('_setDelayMs'), isTrue);
      expect(shortcuts.contains('_setDelayMs'), isFalse,
          reason: '字幕调轴不绑方向键，只在设置面板调');
      // 旧的增量调轴 plumbing 已彻底移除（防回潮）。
      expect(page.contains('_adjustSubtitleOffset'), isFalse);
      expect(page.contains('_subtitleOffsetStepMs'), isFalse);
    });

    test('speed changes by configured asbplayer step', () {
      expect(page.contains('double get _speedStep => _asbConfig.speedStep'),
          isTrue);
      expect(page.contains('_adjustSpeed(_speedStep)'), isTrue);
      expect(page.contains('_adjustSpeed(-_speedStep)'), isTrue);
    });

    test('mpv-style common playback shortcuts are mapped where supported', () {
      expect(shortcuts.contains('LogicalKeyboardKey.keyP'), isTrue,
          reason: 'mpv default: p toggles play/pause');
      expect(shortcuts.contains('LogicalKeyboardKey.digit9'), isTrue,
          reason: 'mpv default: 9 decreases volume');
      expect(shortcuts.contains('LogicalKeyboardKey.digit0'), isTrue,
          reason: 'mpv default: 0 increases volume');
      expect(shortcuts.contains('LogicalKeyboardKey.keyM'), isTrue,
          reason: 'mpv default: m toggles mute');
      expect(shortcuts.contains('LogicalKeyboardKey.bracketLeft'), isTrue,
          reason: 'mpv default: [ decreases speed');
      expect(shortcuts.contains('LogicalKeyboardKey.bracketRight'), isTrue,
          reason: 'mpv default: ] increases speed');
      expect(shortcuts.contains('LogicalKeyboardKey.backspace'), isTrue,
          reason: 'mpv default: Backspace resets speed');
      expect(shortcuts.contains('LogicalKeyboardKey.comma'), isTrue,
          reason: 'mpv default: , steps one frame backward');
      expect(shortcuts.contains('LogicalKeyboardKey.period'), isTrue,
          reason: 'mpv default: . steps one frame forward');
      expect(shortcuts.contains('LogicalKeyboardKey.keyS'), isTrue,
          reason: 'mpv default: s takes a screenshot');
      expect(page.contains('_toggleMute()'), isTrue);
      expect(page.contains('_setSpeed(1.0)'), isTrue);
      expect(page.contains('frameStep(forward: false)'), isTrue);
      expect(page.contains('frameStep(forward: true)'), isTrue);
      expect(page.contains('_saveScreenshot()'), isTrue);
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
