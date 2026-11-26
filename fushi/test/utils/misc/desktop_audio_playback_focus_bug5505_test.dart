import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/misc/desktop_audio_playback.dart';
import 'package:just_audio/just_audio.dart';

/// BUG-5505（反馈 E--G5mP95S）：Android 上复习卡发音 / 自动播放走共用 just_audio 播放器，
/// 缺省每次 play() 激活 audio_session = 申请 AUDIOFOCUS_GAIN，后台别家 app 的音乐每读一个词
/// 就被暂停再恢复。读一个词不申请焦点（BUG-3311 的意图）；长时连续播放（漫画朗读会话）
/// 仍按会话显式申请 / 释放焦点（[DesktopAudioPlayback.holdLongPlayback]）。

class _NoopPlayer implements AudioPlayer {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('Android 上共用预览播放器不激活音频会话；其余平台照旧', () {
    expect(previewPlayerHandlesAudioSession(isAndroid: true), isFalse);
    expect(previewPlayerHandlesAudioSession(isAndroid: false), isTrue);
  });

  test('共用播放器按上面的判据构造（不回退成 just_audio 缺省）', () {
    final String src = File(
      'lib/src/utils/misc/desktop_audio_playback.dart',
    ).readAsStringSync();
    final List<RegExpMatch> ctors = RegExp(
      r'AudioPlayer\(([^)]*)\)',
    ).allMatches(src).toList();
    expect(ctors, isNotEmpty);
    for (final RegExpMatch m in ctors) {
      expect(
        m.group(1),
        contains('handleAudioSessionActivation: _playerHandlesSession'),
        reason: m.group(0),
      );
    }
    expect(
      src,
      contains(
        'static bool _playerHandlesSession = previewPlayerHandlesAudioSession(',
      ),
    );
  });

  group('长时播放按会话持有焦点（Android 判据下）', () {
    late List<bool> activations;

    void reset({required bool playerHandlesSession}) {
      activations = <bool>[];
      DesktopAudioPlayback.debugReset(
        player: _NoopPlayer(),
        playFutureSpansPlayback: true,
        playerHandlesSession: playerHandlesSession,
        sessionActivator: (bool active) async {
          activations.add(active);
          return true;
        },
      );
    }

    test('会话开始 setActive(true)、结束 setActive(false)；重复调用不重复激活', () async {
      reset(playerHandlesSession: false);
      final Object session = Object();
      await DesktopAudioPlayback.holdLongPlayback(session, active: true);
      await DesktopAudioPlayback.holdLongPlayback(session, active: true);
      expect(activations, <bool>[true]);
      await DesktopAudioPlayback.holdLongPlayback(session, active: false);
      await DesktopAudioPlayback.holdLongPlayback(session, active: false);
      expect(activations, <bool>[true, false]);
    });

    test('两个持有者：最后一个释放才交还焦点', () async {
      reset(playerHandlesSession: false);
      final Object a = Object();
      final Object b = Object();
      await DesktopAudioPlayback.holdLongPlayback(a, active: true);
      await DesktopAudioPlayback.holdLongPlayback(b, active: true);
      await DesktopAudioPlayback.holdLongPlayback(a, active: false);
      expect(activations, <bool>[true]);
      await DesktopAudioPlayback.holdLongPlayback(b, active: false);
      expect(activations, <bool>[true, false]);
    });

    test('播放器自己激活会话的平台（iOS / macOS / 桌面）不另外激活', () async {
      reset(playerHandlesSession: true);
      final Object session = Object();
      await DesktopAudioPlayback.holdLongPlayback(session, active: true);
      await DesktopAudioPlayback.holdLongPlayback(session, active: false);
      expect(activations, isEmpty);
    });

    test('激活失败只记日志，不抛给朗读会话', () async {
      DesktopAudioPlayback.debugReset(
        player: _NoopPlayer(),
        playFutureSpansPlayback: true,
        playerHandlesSession: false,
        sessionActivator: (bool active) async => throw StateError('no focus'),
      );
      await expectLater(
        DesktopAudioPlayback.holdLongPlayback(Object(), active: true),
        completes,
      );
    });
  });

  test('漫画朗读会话按 isRunning 申请 / 释放，页面销毁时释放', () {
    final String src = File(
      'lib/src/media/manga/reader/manga_fushi/read_aloud.part.dart',
    ).readAsStringSync();
    expect(
      src,
      contains('DesktopAudioPlayback.holdLongPlayback(this, active: running)'),
    );
    expect(
      src,
      contains('DesktopAudioPlayback.holdLongPlayback(this, active: false)'),
    );
  });
}
