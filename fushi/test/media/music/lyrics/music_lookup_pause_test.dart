import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/floating_lyric_lookup_host.dart';
import 'package:fushi/src/media/music/lyrics/music_lookup_pause.dart';

/// BUG-4198：桌面歌词点词查词不遵守「查词时暂停」。
class _FakePlayback extends ChangeNotifier {
  bool playing = false;
  int playCalls = 0;
  int pauseCalls = 0;

  Future<void> play() async {
    playCalls++;
    setPlaying(true);
  }

  Future<void> pause() async {
    pauseCalls++;
    setPlaying(false);
  }

  void setPlaying(bool value) {
    if (playing == value) return;
    playing = value;
    notifyListeners();
  }
}

void main() {
  late _FakePlayback playback;
  late bool settingEnabled;
  late MusicLookupPause gate;

  setUp(() {
    playback = _FakePlayback()..playing = true;
    settingEnabled = true;
    gate = MusicLookupPause(
      playback: playback,
      isPlaying: () => playback.playing,
      play: playback.play,
      pause: playback.pause,
      settingEnabled: () => settingEnabled,
    );
  });

  tearDown(() => gate.dispose());

  test('playing + setting on: lookup pauses, closing the card resumes', () {
    gate.lookupStarted();
    expect(playback.pauseCalls, 1);
    expect(playback.playing, isFalse);
    expect(gate.pausedForLookup, isTrue);

    gate.lookupClosed();
    expect(playback.playCalls, 1);
    expect(playback.playing, isTrue);
    expect(gate.pausedForLookup, isFalse);
  });

  test('setting off: lookup never touches playback', () {
    settingEnabled = false;
    gate.lookupStarted();
    gate.lookupClosed();
    expect(playback.pauseCalls, 0);
    expect(playback.playCalls, 0);
    expect(playback.playing, isTrue);
  });

  test(
    'already paused: lookup does not pause, closing does not start music',
    () {
      playback.setPlaying(false);
      gate.lookupStarted();
      gate.lookupClosed();
      expect(playback.pauseCalls, 0);
      expect(playback.playCalls, 0);
      expect(playback.playing, isFalse);
    },
  );

  test('looking up another word with the card open keeps one pause', () {
    gate.lookupStarted();
    gate.lookupStarted();
    expect(playback.pauseCalls, 1);
    gate.lookupClosed();
    expect(playback.playCalls, 1);
  });

  test(
    'user resumes while the card is open: closing does not override them',
    () {
      gate.lookupStarted();
      playback.setPlaying(true); // 用户在卡开着时自己按了播放
      playback.setPlaying(false); // 又自己按了暂停
      gate.lookupClosed();
      expect(playback.playCalls, 0);
      expect(playback.playing, isFalse);
    },
  );

  test('a card closing that this gate did not pause for is a no-op', () {
    gate.lookupClosed();
    expect(playback.playCalls, 0);
    expect(playback.pauseCalls, 0);
  });

  test('in-app lookup card close signal reaches listeners', () {
    final FloatingLyricLookupNotifier notifier =
        FloatingLyricLookupNotifier.instance;
    int closed = 0;
    void listener() => closed++;
    notifier.lookupClosed.addListener(listener);
    addTearDown(() => notifier.lookupClosed.removeListener(listener));
    notifier.notifyLookupClosed();
    expect(closed, 1);
  });

  group('wiring (source scan)', () {
    String read(String p) =>
        File(p).readAsStringSync().replaceAll('\r\n', '\n');

    test('desktop lyric onLookup pauses on both lookup routes', () {
      final String app = read('lib/src/models/app_model.dart');
      final int start = app.indexOf('desktop: FloatingLyricMusicSurface(');
      expect(start, isNonNegative);
      final String surface = app.substring(
        start,
        app.indexOf('onPlayPause:', start),
      );
      // 全局查词卡成功弹出后暂停；退回应用内查词卡前也暂停。
      expect(
        'lookupPause.lookupStarted()'.allMatches(surface).length,
        2,
        reason: '两条查词路线都要遵守「查词时暂停」',
      );
      expect(app, contains('prefsRepo.musicLyricsLookupPause'));
      expect(
        app,
        contains('GlobalLookupController.instance.addHiddenListener('),
      );
      expect(
        app,
        contains('FloatingLyricLookupNotifier.instance.lookupClosed'),
      );
    });

    test('global card fires hidden listeners on a desktop dismissal', () {
      final String src = read('lib/src/lookup/global_lookup_controller.dart');
      final int start = src.indexOf('void _onOverlayHidden(');
      // 关窗通知在路由作废（finally）之后发，取到函数尾而不是 finally 前。
      final String body = src.substring(
        start,
        src.indexOf('GlobalLookupRoute debugActivateDesktopRoute()', start),
      );
      final int desktop = body.indexOf("if (route.source == 'desktop')");
      expect(desktop, isNonNegative);
      expect(body.substring(desktop), contains('_hiddenListeners'));
    });

    test('in-app card announces close when its last layer is popped', () {
      final String src = read(
        'lib/src/media/audiobook/floating_lyric_lookup_host.dart',
      );
      expect(src, contains('onPop: _onPop,'));
      final int start = src.indexOf('void _onPop(int index)');
      final String body = src.substring(start, src.indexOf('}\n', start));
      expect(body, contains('popNestedPopupAt(index, _popup)'));
      expect(body, contains('_notifier.notifyLookupClosed()'));
    });
  });
}
