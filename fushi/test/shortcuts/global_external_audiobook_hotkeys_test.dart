import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/lookup/global_lookup_controller.dart';
import 'package:fushi/src/media/audiobook/floating_lyric_channel.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_defaults.dart';
import 'package:fushi/src/shortcuts/shortcut_labels.dart';

/// 反馈 uvIcQB5gPG：有声书悬浮字幕的全局快捷键（Fushi 不在前台时也能控制）。
///
/// 本文件钉：五个动作都在 globalExternal scope（走 OS 级热键，不经页面派发）、
/// 键盘-only、持久化 key 稳定；桌面默认不绑键（OS 热键全系统吞键）；执行体真的
/// 接到悬浮窗按钮同一个播放控制器与设置页同一个显隐置位入口；显隐动作只在有原生
/// 悬浮字幕窗的平台注册。
void main() {
  const Map<ShortcutAction, String> keys = <ShortcutAction, String>{
    ShortcutAction.globalExternalFloatingLyricToggle:
        'global_external_floating_lyric_toggle',
    ShortcutAction.globalExternalAudiobookPlayPause:
        'global_external_audiobook_play_pause',
    ShortcutAction.globalExternalAudiobookPrevSentence:
        'global_external_audiobook_prev_sentence',
    ShortcutAction.globalExternalAudiobookNextSentence:
        'global_external_audiobook_next_sentence',
    ShortcutAction.globalExternalAudiobookReplaySentence:
        'global_external_audiobook_replay_sentence',
  };

  test('落在 globalExternal scope、键盘-only、持久化 key 稳定、有标签', () {
    for (final MapEntry<ShortcutAction, String> e in keys.entries) {
      expect(e.key.scope, ShortcutScope.globalExternal, reason: e.value);
      expect(e.key.key, e.value);
      expect(e.key.channels, const <ShortcutChannel>{
        ShortcutChannel.keyboard,
      }, reason: e.value);
      expect(e.key.label, isNotEmpty, reason: e.value);
    }
  });

  test('所有平台默认都不绑键（不偷任何系统级组合键）', () {
    for (final TargetPlatform platform in TargetPlatform.values) {
      final Map<ShortcutAction, ShortcutBindingSet> table =
          ShortcutDefaults.forPlatform(platform);
      for (final ShortcutAction action in keys.keys) {
        final ShortcutBindingSet? set = table[action];
        expect(set, isNotNull, reason: '$platform 缺 ${action.key}');
        expect(set!.keyboardBindings, isEmpty, reason: '$platform');
        expect(set.gamepadBindings, isEmpty, reason: '$platform');
        expect(set.mouseBindings, isEmpty, reason: '$platform');
      }
    }
  });

  test('显隐悬浮字幕只在有原生悬浮字幕窗时注册，播放控制恒可用', () {
    addTearDown(() => FloatingLyricChannel.platformOverride = null);
    FloatingLyricChannel.platformOverride = false;
    expect(
      GlobalLookupController.osHotKeyActionWorksHere(
        ShortcutAction.globalExternalFloatingLyricToggle,
      ),
      isFalse,
    );
    FloatingLyricChannel.platformOverride = true;
    expect(
      GlobalLookupController.osHotKeyActionWorksHere(
        ShortcutAction.globalExternalFloatingLyricToggle,
      ),
      isTrue,
    );
    for (final bool floating in <bool>[false, true]) {
      FloatingLyricChannel.platformOverride = floating;
      for (final ShortcutAction action in <ShortcutAction>[
        ShortcutAction.globalExternalAudiobookPlayPause,
        ShortcutAction.globalExternalAudiobookPrevSentence,
        ShortcutAction.globalExternalAudiobookNextSentence,
        ShortcutAction.globalExternalAudiobookReplaySentence,
      ]) {
        expect(
          GlobalLookupController.osHotKeyActionWorksHere(action),
          isTrue,
          reason: '${action.key} floating=$floating',
        );
      }
    }
  });

  test('执行体接到悬浮窗按钮同一个控制器、设置页同一个显隐入口', () {
    final String controller = File(
      'lib/src/lookup/global_lookup_controller.dart',
    ).readAsStringSync();
    expect(
      controller,
      matches(
        RegExp(
          r'ShortcutAction\.globalExternalFloatingLyricToggle:\s+'
          r'toggleAudiobookFloatingLyric,',
        ),
      ),
    );
    for (final String call in <String>[
      'c.togglePlayPause()',
      'c.skipToPrevCue()',
      'c.skipToNextCue()',
      'c.replayCurrentCue()',
    ]) {
      expect(controller, contains(call));
    }
    // 播放控制取 app 级会话的控制器（悬浮窗按钮用的同一个）。
    expect(controller, contains('_appModel?.audiobookSession.controller'));
    // 显隐走设置页开关的置位入口（窗与意图 pref 原子同步），不裸写 pref。
    expect(
      controller,
      contains('await model.setFloatingLyricEnabled(target);'),
    );
    expect(controller, isNot(contains('setShowFloatingLyric(')));

    // 悬浮窗按钮那一侧确实是这几个控制器方法——热键与按钮行为一致。
    final String session = File(
      'lib/src/media/audiobook/audiobook_session.dart',
    ).readAsStringSync();
    expect(
      session,
      contains('onPlayPause: () => _controller?.togglePlayPause(),'),
    );
    expect(
      session,
      contains('onPreviousCue: () => _controller?.skipToPrevCue(),'),
    );
    expect(session, contains('onNextCue: () => _controller?.skipToNextCue(),'));
  });
}
