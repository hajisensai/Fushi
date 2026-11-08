import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/second_screen/companion/companion_context.dart';
import 'package:fushi/src/second_screen/companion/companion_protocol.dart';
import 'package:fushi/src/second_screen/input/controller_lookup_mode.dart';
import 'package:fushi/src/second_screen/input/controller_lookup_target.dart';
import 'package:fushi/src/shortcuts/dictionary_popup_gamepad.dart';
import 'package:fushi/src/shortcuts/gamepad_service.dart'
    show interceptNativeControllerLookupKey;
import 'package:fushi/src/shortcuts/input_binding.dart';

class _FakeTarget extends ControllerLookupTarget {
  _FakeTarget(this.prefs) : super(readPref: (String k) => prefs[k]);

  final Map<String, Object?> prefs;
  final List<String> log = <String>[];
  bool owns = true;
  bool available = true;

  @override
  bool get isAvailable => available;
  @override
  bool get routerOwnsInput => owns;
  @override
  bool get hasWordSteps => true;
  @override
  void onModeEntered() => log.add('enter');
  @override
  void onModeExited() => log.add('exit');
  @override
  Future<void> stepCursor(int dir, {required bool word}) async =>
      log.add('step$dir${word ? 'w' : 'c'}');
  @override
  Future<void> stepLine(int dir) async => log.add('line$dir');
  @override
  Future<void> lookupAtCursor() async => log.add('lookup');
}

class _FakeSink implements CompanionControllerSink {
  bool open = false;
  final List<String> sent = <String>[];

  @override
  bool get lookupOpen => open;

  @override
  bool sendLookupAction(
    String action, [
    Map<String, Object?> args = const <String, Object?>{},
  ]) {
    sent.add('L:$action');
    return true;
  }

  @override
  bool sendPanelNav(String action) {
    sent.add('P:$action');
    return true;
  }
}

DictionaryPopupGamepadHooks _hooks(List<String> log, {bool visible = true}) =>
    DictionaryPopupGamepadHooks(
      hasVisiblePopup: () => visible,
      entryMove: (bool forward) async => log.add(forward ? 'next' : 'prev'),
      mineFirstEntry: () async => log.add('mine'),
      playFirstAudio: () async => log.add('audio'),
      scrollBy: (double dy) async => log.add('scroll$dy'),
    );

void main() {
  late CompanionContextRegistry registry;
  late ControllerLookupMode mode;
  late _FakeTarget target;
  late _FakeSink sink;
  late List<GamepadButton> replayed;

  setUp(() {
    registry = CompanionContextRegistry();
    sink = _FakeSink();
    registry
      ..bindControllerSink(sink)
      ..setActive(true);
    mode = ControllerLookupMode(registry: registry);
    target = _FakeTarget(<String, Object?>{});
    replayed = <GamepadButton>[];
    mode
      ..redispatch = replayed.add
      ..popupHooks = (() => null)
      ..attach(target);
  });

  test('style: hold L1 with the companion up, off on a single screen', () {
    expect(mode.style, ControllerLookupStyle.holdL1);
    registry.setActive(false);
    expect(mode.style, ControllerLookupStyle.off);
    target.prefs[kControllerLookupStylePrefKey] = 'selectToggle';
    expect(mode.style, ControllerLookupStyle.selectToggle);
  });

  test('companion off and no opt-in: every button keeps its page binding', () {
    registry.setActive(false);
    for (final GamepadButton b in GamepadButton.values) {
      expect(mode.onPress(b), isFalse, reason: '$b');
      expect(mode.onRelease(b), isFalse, reason: '$b');
    }
    expect(target.log, isEmpty);
    expect(sink.sent, isEmpty);
  });

  test('a short L1 tap is replayed on release, nothing else happens', () {
    fakeAsync((FakeAsync async) {
      expect(mode.onPress(GamepadButton.lb), isTrue);
      async.elapse(const Duration(milliseconds: 100));
      expect(mode.onRelease(GamepadButton.lb), isTrue);
      expect(replayed, <GamepadButton>[GamepadButton.lb]);
      expect(mode.active, isFalse);
      expect(target.log, isEmpty);
    });
  });

  test('holding L1 enters the mode; release leaves it without a replay', () {
    fakeAsync((FakeAsync async) {
      mode.onPress(GamepadButton.lb);
      async.elapse(ControllerLookupMode.holdThreshold);
      expect(mode.active, isTrue);
      expect(target.log, <String>['enter']);
      mode.onRelease(GamepadButton.lb);
      expect(mode.active, isFalse);
      expect(target.log, <String>['enter', 'exit']);
      expect(replayed, isEmpty);
    });
  });

  test('L1 + D-pad / A drive the cursor and look up', () {
    fakeAsync((FakeAsync async) {
      mode.onPress(GamepadButton.lb);
      // First lookup input during the hold enters right away.
      expect(mode.onPress(GamepadButton.dpadRight), isTrue);
      expect(mode.onRelease(GamepadButton.dpadRight), isTrue);
      mode.onPress(GamepadButton.dpadDown);
      mode.onRelease(GamepadButton.dpadDown);
      mode.onPress(GamepadButton.y); // word -> character
      mode.onPress(GamepadButton.dpadLeft);
      mode.onRelease(GamepadButton.dpadLeft);
      mode.onPress(GamepadButton.a);
      expect(target.log, <String>[
        'enter',
        'step1w',
        'line1',
        'step-1c',
        'lookup',
      ]);
      mode.onRelease(GamepadButton.lb);
      expect(replayed, isEmpty);
    });
  });

  test('a held D-pad direction repeats after the delay', () {
    fakeAsync((FakeAsync async) {
      mode.onPress(GamepadButton.lb);
      mode.onPress(GamepadButton.dpadRight);
      async.elapse(
        ControllerLookupMode.repeatDelay +
            ControllerLookupMode.repeatInterval * 2,
      );
      mode.onRelease(GamepadButton.dpadRight);
      async.elapse(const Duration(seconds: 1));
      expect(target.log.where((String e) => e == 'step1w').length, 3);
      mode.onRelease(GamepadButton.lb);
    });
  });

  test('with a lookup open on the companion, buttons act on it', () {
    fakeAsync((FakeAsync async) {
      sink.open = true;
      mode.onPress(GamepadButton.lb);
      mode.onPress(GamepadButton.a);
      mode.onPress(GamepadButton.x);
      mode.onPress(GamepadButton.rt);
      mode.onPress(GamepadButton.lt);
      expect(mode.onRightStick(24), isTrue);
      mode.onPress(GamepadButton.b);
      expect(sink.sent, <String>[
        'L:${CompanionLookupActions.mine}',
        'L:${CompanionLookupActions.playAudio}',
        'L:${CompanionLookupActions.nextEntry}',
        'L:${CompanionLookupActions.prevEntry}',
        'L:${CompanionLookupActions.scroll}',
        'L:${CompanionLookupActions.close}',
      ]);
      expect(target.log, <String>['enter']);
      // B with nothing open leaves the mode; the rest of the hold is swallowed.
      sink.open = false;
      mode.onPress(GamepadButton.b);
      expect(mode.active, isFalse);
      expect(mode.onPress(GamepadButton.dpadRight), isTrue);
      mode.onRelease(GamepadButton.lb);
      expect(replayed, isEmpty);
    });
  });

  test('single screen (opted in): follow-ups go to the in-page popup', () {
    fakeAsync((FakeAsync async) {
      registry.setActive(false);
      target.prefs[kControllerLookupStylePrefKey] = 'holdL1';
      final List<String> popup = <String>[];
      mode.popupHooks = () => _hooks(popup);
      mode.onPress(GamepadButton.lb);
      mode.onPress(GamepadButton.a);
      mode.onPress(GamepadButton.x);
      mode.onPress(GamepadButton.rt);
      mode.onPress(GamepadButton.b);
      expect(popup, <String>['mine', 'audio', 'next']);
      // The page closes its own popup (universal Back).
      expect(replayed, <GamepadButton>[GamepadButton.b]);
      expect(sink.sent, isEmpty);
    });
  });

  test('the caret on the in-page popup keeps the page handling', () {
    fakeAsync((FakeAsync async) {
      mode.onPress(GamepadButton.lb);
      mode.onPress(GamepadButton.dpadRight);
      target.owns = false;
      expect(mode.onPress(GamepadButton.dpadLeft), isFalse);
      mode.onRelease(GamepadButton.lb);
    });
  });

  test('an unavailable target leaves L1 to the page', () {
    target.available = false;
    expect(mode.onPress(GamepadButton.lb), isFalse);
    expect(mode.onRelease(GamepadButton.lb), isFalse);
  });

  test('Select toggles in selectToggle style', () {
    target.prefs[kControllerLookupStylePrefKey] = 'selectToggle';
    expect(mode.onPress(GamepadButton.select), isTrue);
    expect(mode.active, isTrue);
    expect(mode.onPress(GamepadButton.lb), isFalse);
    expect(mode.onPress(GamepadButton.select), isTrue);
    expect(mode.active, isFalse);
  });

  test('R1 held drives the companion panel; release ends it', () {
    fakeAsync((FakeAsync async) {
      expect(mode.onPress(GamepadButton.rb), isTrue);
      expect(mode.panelDriving, isTrue);
      mode.onPress(GamepadButton.dpadDown);
      mode.onRelease(GamepadButton.dpadDown);
      mode.onPress(GamepadButton.a);
      mode.onPress(GamepadButton.b);
      // Other buttons are swallowed while driving.
      expect(mode.onPress(GamepadButton.x), isTrue);
      expect(mode.onRelease(GamepadButton.rb), isTrue);
      expect(sink.sent, <String>[
        'P:${CompanionPanelNav.begin}',
        'P:${CompanionPanelNav.down}',
        'P:${CompanionPanelNav.activate}',
        'P:${CompanionPanelNav.back}',
        'P:${CompanionPanelNav.end}',
      ]);
      expect(replayed, isEmpty);
      expect(target.log, isEmpty);
    });
  });

  test('a short R1 tap is replayed; without the companion R1 is untouched', () {
    expect(mode.onPress(GamepadButton.rb), isTrue);
    expect(mode.onRelease(GamepadButton.rb), isTrue);
    expect(replayed, <GamepadButton>[GamepadButton.rb]);
    expect(sink.sent, isEmpty);
    registry.setActive(false);
    expect(mode.onPress(GamepadButton.rb), isFalse);
    expect(mode.onRelease(GamepadButton.rb), isFalse);
  });

  test('detach while active exits the mode', () {
    fakeAsync((FakeAsync async) {
      mode.onPress(GamepadButton.lb);
      async.elapse(ControllerLookupMode.holdThreshold);
      mode.detach(target);
      expect(mode.active, isFalse);
      expect(target.log, <String>['enter', 'exit']);
      expect(mode.onPress(GamepadButton.lb), isFalse);
    });
  });

  test('Android key events: down/up consumed, OS repeats swallowed', () {
    fakeAsync((FakeAsync async) {
      KeyEvent down(LogicalKeyboardKey key) => KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.gameButtonLeft1,
        logicalKey: key,
        timeStamp: Duration.zero,
      );
      int consumed = 0;
      bool feed(KeyEvent e) => interceptNativeControllerLookupKey(
        e,
        mode,
        onConsumed: () => consumed++,
        isAndroid: true,
      );
      expect(feed(down(LogicalKeyboardKey.gameButtonLeft1)), isTrue);
      expect(
        feed(
          const KeyRepeatEvent(
            physicalKey: PhysicalKeyboardKey.gameButtonLeft1,
            logicalKey: LogicalKeyboardKey.gameButtonLeft1,
            timeStamp: Duration.zero,
          ),
        ),
        isTrue,
      );
      expect(
        feed(
          const KeyUpEvent(
            physicalKey: PhysicalKeyboardKey.gameButtonLeft1,
            logicalKey: LogicalKeyboardKey.gameButtonLeft1,
            timeStamp: Duration.zero,
          ),
        ),
        isTrue,
      );
      expect(consumed, 1);
      expect(replayed, <GamepadButton>[GamepadButton.lb]);
      // Not Android: never intercepted.
      expect(
        interceptNativeControllerLookupKey(
          down(LogicalKeyboardKey.gameButtonLeft1),
          mode,
          isAndroid: false,
        ),
        isFalse,
      );
    });
  });
}
