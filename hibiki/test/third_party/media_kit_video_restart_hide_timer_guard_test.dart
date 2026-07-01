import 'dart:async';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

/// TODO-1059 zi wenti 2: kan shipin dianchu caidan, chixu dian dibu anniu
/// (kuaijin/tui/bofang) reng zai controlsHoverDuration (2s) hou zidong yincang,
/// shouzhi hai zai anniu shang -> luodao huamian wuchu. Genyin: fork yidong
/// kongzhitiao yincang Timer zhi zai zheng ping onTap yu seek shi chongzhi;
/// dibu anniu onPressed bu chongzhi, qie yidong _pokeControlsVisible zaotui no-op.
/// Xiufu: fork jia restartHideTimerSignal, State dingyue zai kejian tai chongpai
/// yincang Timer; Hibiki _RestartHideTimerSignal you anniu jing _pokeControlsVisible
/// yidong fenzhi poke(), chuanru _mobileControlsTheme. Zhenshi fork xu libmpv
/// (headless pao bu liao), gu fen liang ceng: fake_async xingwei + yuanma shouwei.
void main() {
  const Duration hover = Duration(seconds: 2);

  group('TODO-1059 s2 behaviour: repeated poke keeps controls visible', () {
    test('poke every <2s across controlsHoverDuration keeps it visible', () {
      fakeAsync((FakeAsync async) {
        final _HideTimerController ctrl =
            _HideTimerController(hoverDuration: hover);
        addTearDown(ctrl.dispose);
        ctrl.show();
        expect(ctrl.visible, isTrue);
        for (int i = 0; i < 4; i++) {
          async.elapse(const Duration(milliseconds: 1500));
          expect(ctrl.visible, isTrue,
              reason: 'poke window: controls must not have auto-hidden yet');
          ctrl.signal.poke();
        }
        expect(ctrl.visible, isTrue,
            reason: 'repeated poke kept it alive past controlsHoverDuration');
        async.elapse(const Duration(seconds: 2, milliseconds: 1));
        expect(ctrl.visible, isFalse,
            reason: 'after stopping poke it auto-hides normally');
      });
    });

    test('poke while hidden does NOT silently un-hide (restart only)', () {
      fakeAsync((FakeAsync async) {
        final _HideTimerController ctrl =
            _HideTimerController(hoverDuration: hover);
        addTearDown(ctrl.dispose);
        expect(ctrl.visible, isFalse);
        ctrl.signal.poke();
        async.elapse(const Duration(milliseconds: 10));
        expect(ctrl.visible, isFalse,
            reason:
                'hidden-state poke must be a no-op (!visible early return)');
      });
    });

    test('no poke -> auto-hides on schedule (baseline)', () {
      fakeAsync((FakeAsync async) {
        final _HideTimerController ctrl =
            _HideTimerController(hoverDuration: hover);
        addTearDown(ctrl.dispose);
        ctrl.show();
        expect(ctrl.visible, isTrue);
        async.elapse(const Duration(seconds: 2, milliseconds: 1));
        expect(ctrl.visible, isFalse, reason: 'without poke it hides after 2s');
      });
    });
  });

  group('TODO-1059 s2 source guard: fork restartHideTimerSignal wiring', () {
    late String forkSrc;
    setUpAll(() {
      final File f = File(
        '../third_party/media_kit_video/lib/media_kit_video_controls/'
        'src/controls/material.dart',
      );
      expect(f.existsSync(), isTrue,
          reason: 'vendored fork material.dart must exist');
      forkSrc = f.readAsStringSync().replaceAll('\r\n', '\n');
    });

    test('theme data exposes restartHideTimerSignal field', () {
      expect(
          forkSrc.contains('final Listenable? restartHideTimerSignal;'), isTrue,
          reason: 'theme data must carry restartHideTimerSignal');
      expect(forkSrc.contains('this.restartHideTimerSignal'), isTrue,
          reason: 'constructor must accept it');
      expect(
          forkSrc.contains(
              'restartHideTimerSignal ?? this.restartHideTimerSignal'),
          isTrue,
          reason: 'copyWith must carry it through');
    });

    test('State subscribes, restarts hide Timer while visible, detaches', () {
      expect(forkSrc.contains('void _restartHideTimer()'), isTrue,
          reason: 'State must have _restartHideTimer()');
      expect(forkSrc.contains('addListener(_restartHideTimer)'), isTrue,
          reason: 'must subscribe');
      expect(forkSrc.contains('removeListener(_restartHideTimer)'), isTrue,
          reason: 'must remove listener (no leak)');
      final int fn = forkSrc.indexOf('void _restartHideTimer()');
      final int end = forkSrc.indexOf('\n  }', fn);
      final String body = forkSrc.substring(fn, end);
      expect(body.contains('!visible'), isTrue,
          reason: 'must early-return when !visible');
      expect(
          body.contains('_timer?.cancel()') && body.contains('_timer = Timer('),
          isTrue,
          reason: 'must cancel and reschedule the hide Timer');
    });
  });

  group('TODO-1059 s2 source guard: Hibiki signal / poke / pass to fork theme',
      () {
    late String shellSrc;
    late String visibilitySrc;
    late String themeSrc;
    setUpAll(() {
      String read(String p) =>
          File(p).readAsStringSync().replaceAll('\r\n', '\n');
      shellSrc = read('lib/src/pages/implementations/video_hibiki_page.dart');
      visibilitySrc = read(
          'lib/src/pages/implementations/video_hibiki/controls_visibility.part.dart');
      themeSrc = read(
          'lib/src/pages/implementations/video_hibiki/controls_theme.part.dart');
    });

    test('_RestartHideTimerSignal define + field dispose', () {
      expect(
          shellSrc
              .contains('class _RestartHideTimerSignal extends ChangeNotifier'),
          isTrue,
          reason: 'must define _RestartHideTimerSignal(ChangeNotifier)');
      expect(shellSrc.contains('void poke() => notifyListeners();'), isTrue,
          reason: 'poke() must notifyListeners()');
      expect(shellSrc.contains('_restartHideTimerSignal.dispose()'), isTrue,
          reason: 'field must be disposed with the State');
    });

    test('_pokeControlsVisible mobile branch pokes signal', () {
      final int fn = visibilitySrc.indexOf('void _pokeControlsVisible()');
      expect(fn, greaterThanOrEqualTo(0),
          reason: 'cannot find _pokeControlsVisible');
      final int end = visibilitySrc.indexOf('\n  }', fn);
      final String body = visibilitySrc.substring(fn, end);
      expect(body.contains('_restartHideTimerSignal.poke()'), isTrue,
          reason:
              'mobile must poke the restart signal (old early-return = no-op)');
      expect(
        body.indexOf('_immersiveLocked.value') <
            body.indexOf('_restartHideTimerSignal.poke()'),
        isTrue,
        reason: 'suppression gates must precede poke',
      );
    });

    test('_mobileControlsTheme passes restartHideTimerSignal into fork theme',
        () {
      final int fn = themeSrc
          .indexOf('MaterialVideoControlsThemeData _mobileControlsTheme(');
      expect(fn, greaterThanOrEqualTo(0),
          reason: 'cannot find _mobileControlsTheme');
      final int end = themeSrc.indexOf('\n  }', fn);
      final String body = themeSrc.substring(fn, end);
      expect(body.contains('restartHideTimerSignal: _restartHideTimerSignal'),
          isTrue,
          reason:
              'must pass signal into fork theme, else fork never receives it');
    });
  });
}

/// Faithful mirror of the vendored fork _MaterialVideoControlsState hide-timer
/// contract (no render/gesture/media deps, runs headless + fake_async). show()
/// starts a hoverDuration hide Timer (onTap branch); a real ChangeNotifier signal
/// poke() fires _restartHideTimer, which only while visible cancels + reschedules
/// the Timer (same shape as the fork method) and early-returns when hidden. The
/// source-guard group locks the real fork structure to match; two layers guard.
class _HideTimerController {
  _HideTimerController({required this.hoverDuration}) {
    signal.addListener(_restartHideTimer);
  }

  final Duration hoverDuration;
  final _RestartHideTimerSignalFake signal = _RestartHideTimerSignalFake();
  bool visible = false;
  Timer? _timer;

  void show() {
    visible = true;
    _timer?.cancel();
    _timer = Timer(hoverDuration, () => visible = false);
  }

  void _restartHideTimer() {
    if (!visible) return;
    _timer?.cancel();
    _timer = Timer(hoverDuration, () => visible = false);
  }

  void dispose() {
    signal.removeListener(_restartHideTimer);
    signal.dispose();
    _timer?.cancel();
  }
}

/// Same shape as the pages private _RestartHideTimerSignal (tests cannot touch it).
class _RestartHideTimerSignalFake extends ChangeNotifier {
  void poke() => notifyListeners();
}
