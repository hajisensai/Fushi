// _Eb0txdN4H：视频页「复制当前台词」快捷键（主字幕 / 副字幕两个动作，默认不绑键）。
//
// 钉四件事：① 取句判据（正在显示的那几句 → 句间空隙回落 → 都没有不写剪贴板）；
// ② 两个动作在所有平台默认空绑定；③ 用户绑键后经注册表解析到动作、再经动作表派发到
// 执行体；④ 视频页把两个回调接到真实的复制执行体（主取 activeCues、副取 secondaryActiveCues）。
import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_current_line_copy.dart';
import 'package:fushi/src/media/video/video_player_shortcuts.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_defaults.dart';
import 'package:fushi/src/shortcuts/shortcut_registry.dart';
import 'package:fushi_audio/fushi_audio.dart';

import '../../helpers/source_guard.dart';
import '../../pages/video_fushi_page_source_corpus.dart';

AudioCue _cue(String text) => AudioCue()
  ..bookKey = 'video/1'
  ..chapterHref = 'video://default'
  ..sentenceIndex = 0
  ..textFragmentId = ''
  ..text = text
  ..startMs = 0
  ..endMs = 1000
  ..audioFileIndex = 0;

void main() {
  group('videoCurrentLineCopyText', () {
    test('复制正在显示的那几句（重叠字幕按显示顺序换行连接）', () {
      expect(
        videoCurrentLineCopyText(
          activeCues: <AudioCue>[_cue(' 一句目 '), _cue('二句目')],
          fallback: _cue('不该用到'),
        ),
        '一句目\n二句目',
      );
    });

    test('句间空隙没有在显示的句子时回落到 fallback；空白句不算', () {
      expect(
        videoCurrentLineCopyText(
          activeCues: <AudioCue>[_cue('   ')],
          fallback: _cue('刚播完的那句'),
        ),
        '刚播完的那句',
      );
    });

    test('都没有可复制的文本时返回 null（不写空剪贴板）', () {
      expect(videoCurrentLineCopyText(activeCues: const <AudioCue>[]), isNull);
      expect(
        videoCurrentLineCopyText(
          activeCues: const <AudioCue>[],
          fallback: _cue(''),
        ),
        isNull,
      );
    });
  });

  test('两个复制动作在所有平台默认空绑定（不抢 Ctrl+C）', () {
    for (final TargetPlatform platform in TargetPlatform.values) {
      final Map<ShortcutAction, ShortcutBindingSet> defaults =
          ShortcutDefaults.forPlatform(platform);
      for (final ShortcutAction action in <ShortcutAction>[
        ShortcutAction.videoCopyCurrentSubtitle,
        ShortcutAction.videoCopyCurrentSecondarySubtitle,
      ]) {
        final ShortcutBindingSet set = defaults[action]!;
        expect(set.keyboardBindings, isEmpty, reason: '$platform $action');
        expect(set.gamepadBindings, isEmpty, reason: '$platform $action');
        expect(set.mouseBindings, isEmpty, reason: '$platform $action');
      }
    }
  });

  test('用户绑键后：注册表解析到动作，动作表派发到对应执行体，且可配到屏幕按钮', () {
    final FushiShortcutRegistry registry = FushiShortcutRegistry()
      ..loadDefaults(TargetPlatform.windows);
    registry.updateBinding(
      ShortcutAction.videoCopyCurrentSubtitle,
      const ShortcutBindingSet(
        keyboardBindings: <InputBinding>[
          InputBinding(
            key: LogicalKeyboardKey.keyC,
            modifiers: <ModifierKey>{ModifierKey.ctrl},
          ),
        ],
      ),
    );
    registry.updateBinding(
      ShortcutAction.videoCopyCurrentSecondarySubtitle,
      const ShortcutBindingSet(
        keyboardBindings: <InputBinding>[
          InputBinding(
            key: LogicalKeyboardKey.keyC,
            modifiers: <ModifierKey>{ModifierKey.ctrl, ModifierKey.shift},
          ),
        ],
      ),
    );
    final ShortcutAction? primary = registry.resolveKeyboard(
      LogicalKeyboardKey.keyC,
      modifiers: const <ModifierKey>{ModifierKey.ctrl},
      scope: ShortcutScope.video,
    );
    final ShortcutAction? secondary = registry.resolveKeyboard(
      LogicalKeyboardKey.keyC,
      modifiers: const <ModifierKey>{ModifierKey.ctrl, ModifierKey.shift},
      scope: ShortcutScope.video,
    );
    expect(primary, ShortcutAction.videoCopyCurrentSubtitle);
    expect(secondary, ShortcutAction.videoCopyCurrentSecondarySubtitle);

    final List<String> log = <String>[];
    final Map<ShortcutAction, VoidCallback> callbacks = videoActionCallbacks(
      _actions(log),
    );
    callbacks[primary]!();
    callbacks[secondary]!();
    expect(log, <String>['copy-primary', 'copy-secondary']);
    expect(
      kVideoAssignableActions,
      containsAll(<ShortcutAction>[
        ShortcutAction.videoCopyCurrentSubtitle,
        ShortcutAction.videoCopyCurrentSecondarySubtitle,
      ]),
    );
  });

  test('视频页接线：两个回调接到真实复制执行体（主 / 副各取自己的活动句）', () {
    final String src = readVideoFushiSource();
    expect(
      src.contains('_runWhenImmersiveAllowsShortcuts(_copyCurrentSubtitle)'),
      isTrue,
    );
    expect(
      src.contains(
        '_runWhenImmersiveAllowsShortcuts(_copyCurrentSecondarySubtitle)',
      ),
      isTrue,
    );
    final String primary = methodBody(src, 'void _copyCurrentSubtitle()');
    expect(primary, contains('activeCues: controller.activeCues'));
    final String secondary = methodBody(
      src,
      'void _copyCurrentSecondarySubtitle()',
    );
    expect(secondary, contains('activeCues: controller.secondaryActiveCues'));
    expect(secondary, contains('controller.effectiveSecondaryDelayMs'));
  });
}

VideoPlayerShortcutActions _actions(List<String> log) {
  void noop() {}
  return VideoPlayerShortcutActions(
    togglePlayPause: noop,
    play: noop,
    pause: noop,
    previousSubtitle: noop,
    nextSubtitle: noop,
    seekBackward: noop,
    seekForward: noop,
    toggleShaderCompare: noop,
    volumeUp: noop,
    volumeDown: noop,
    toggleMute: noop,
    speedUp: noop,
    speedDown: noop,
    resetSpeed: noop,
    toggleHoldSpeed: noop,
    previousFrame: noop,
    nextFrame: noop,
    screenshot: noop,
    screenshotSubtitled: noop,
    ocrFrame: noop,
    toggleFullscreen: noop,
    toggleMiniWindow: noop,
    toggleMiniChrome: noop,
    toggleSubtitleList: noop,
    searchSubtitleList: noop,
    toggleImmersiveLock: noop,
    toggleSubtitleBlur: noop,
    cycleSubtitleObscure: noop,
    toggleSubtitleHide: noop,
    cycleSecondarySubtitleObscure: noop,
    toggleSecondarySubtitleHide: noop,
    toggleFavoriteSentence: noop,
    replayCurrentSubtitle: noop,
    replayPreviousSubtitle: noop,
    copyCurrentSubtitle: () => log.add('copy-primary'),
    copyCurrentSecondarySubtitle: () => log.add('copy-secondary'),
    toggleLoopCurrentSubtitle: noop,
    previousChapter: noop,
    nextChapter: noop,
    openSubtitleAlign: noop,
    subtitleDelayIncrease: noop,
    subtitleDelayDecrease: noop,
    alignSubtitleToPrev: noop,
    alignSubtitleToNext: noop,
    enterCaret: noop,
    escape: noop,
  );
}
