import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show TraversalDirection;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/second_screen/companion/companion_context.dart';
import 'package:fushi/src/second_screen/companion/companion_protocol.dart';
import 'package:fushi/src/second_screen/input/controller_lookup_mode.dart';
import 'package:fushi/src/second_screen/input/controller_lookup_target.dart';
import 'package:fushi/src/shortcuts/dictionary_popup_gamepad.dart';
import 'package:fushi/src/shortcuts/gamepad_service.dart'
    show interceptNativeControllerLookupKey;
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_registry.dart';

class _FakeTarget extends ControllerLookupTarget {
  _FakeTarget(this.prefs) : super(readPref: (String k) => prefs[k]);

  final Map<String, Object?> prefs;
  final List<String> log = <String>[];
  bool owns = true;
  bool available = true;

  /// What the next lookups return (highlight length), in order; then 0.
  final List<int> matches = <int>[];
  int fromCursor = 10;
  int entered = 0;

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
  int get graphemesFromCursor => fromCursor;
  @override
  Future<int> lookupAtCursor({int? maxGraphemes}) async {
    log.add('lookup${maxGraphemes ?? ''}');
    return matches.isEmpty ? 0 : matches.removeAt(0);
  }

  @override
  Future<void> enterResult() async => entered++;
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
  late FushiShortcutRegistry shortcuts;

  setUp(() {
    registry = CompanionContextRegistry();
    sink = _FakeSink();
    registry
      ..bindControllerSink(sink)
      ..setActive(true);
    shortcuts = FushiShortcutRegistry()..loadDefaults(TargetPlatform.windows);
    mode = ControllerLookupMode(
      registry: registry,
      shortcutRegistry: shortcuts,
    );
    target = _FakeTarget(<String, Object?>{});
    replayed = <GamepadButton>[];
    mode
      ..redispatch = replayed.add
      ..popupHooks = (() => null)
      ..attach(target);
  });

  test('style: hold L1 by default, single screen included', () {
    expect(mode.style, ControllerLookupStyle.holdL1);
    registry.setActive(false);
    expect(mode.style, ControllerLookupStyle.holdL1);
    expect(ControllerLookupStyle.resolve(null), ControllerLookupStyle.holdL1);
    expect(
      ControllerLookupStyle.resolve('bogus'),
      ControllerLookupStyle.holdL1,
    );
    target.prefs[kControllerLookupStylePrefKey] = 'selectToggle';
    expect(mode.style, ControllerLookupStyle.selectToggle);
    target.prefs[kControllerLookupStylePrefKey] = 'off';
    expect(mode.style, ControllerLookupStyle.off);
  });

  test('style off on a single screen: every button keeps its page binding', () {
    registry.setActive(false);
    target.prefs[kControllerLookupStylePrefKey] = 'off';
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

  test('L1 + D-pad drive the cursor; every single step looks up at once', () {
    fakeAsync((FakeAsync async) {
      mode.onPress(GamepadButton.lb);
      // First lookup input during the hold enters right away.
      expect(mode.onPress(GamepadButton.dpadRight), isTrue);
      async.flushMicrotasks();
      expect(target.log, <String>['enter', 'step1w', 'lookup']);
      expect(mode.onRelease(GamepadButton.dpadRight), isTrue);
      mode.onPress(GamepadButton.dpadDown);
      mode.onRelease(GamepadButton.dpadDown);
      async.flushMicrotasks();
      mode.onPress(GamepadButton.thumbLeft); // L3: word -> character
      expect(mode.wordGranularity, isFalse);
      mode.onPress(GamepadButton.dpadLeft);
      mode.onRelease(GamepadButton.dpadLeft);
      async.flushMicrotasks();
      expect(target.log, <String>[
        'enter',
        'step1w',
        'lookup',
        'line1',
        'lookup',
        'step-1c',
        'lookup',
      ]);
      mode.onRelease(GamepadButton.lb);
      expect(replayed, isEmpty);
    });
  });

  test('a held D-pad direction repeats without lookups and looks up once on '
      'release', () {
    fakeAsync((FakeAsync async) {
      mode.onPress(GamepadButton.lb);
      mode.onPress(GamepadButton.dpadRight);
      async.elapse(
        ControllerLookupMode.repeatDelay +
            ControllerLookupMode.repeatInterval * 2,
      );
      expect(target.log.where((String e) => e == 'step1w').length, 3);
      expect(
        target.log.where((String e) => e == 'lookup').length,
        1,
        reason: 'only the first step looks up while the key is held',
      );
      mode.onRelease(GamepadButton.dpadRight);
      async.elapse(const Duration(seconds: 1));
      expect(target.log.where((String e) => e == 'step1w').length, 3);
      expect(target.log.last, 'lookup');
      expect(target.log.where((String e) => e == 'lookup').length, 2);
      mode.onRelease(GamepadButton.lb);
    });
  });

  test('the left stick follows the same rule: first step looks up, a held '
      'push looks up once when released', () {
    fakeAsync((FakeAsync async) {
      mode.onPress(GamepadButton.lb);
      async.elapse(ControllerLookupMode.holdThreshold);
      expect(mode.onStickMove(TraversalDirection.right), isTrue);
      async.flushMicrotasks();
      expect(mode.onStickMove(TraversalDirection.right), isTrue);
      expect(mode.onStickMove(TraversalDirection.right), isTrue);
      async.flushMicrotasks();
      expect(target.log, <String>[
        'enter',
        'step1w',
        'lookup',
        'step1w',
        'step1w',
      ]);
      mode.onStickRelease();
      async.flushMicrotasks();
      expect(target.log.last, 'lookup');
      // A single flick: one step, one lookup, nothing more on release.
      target.log.clear();
      mode.onStickMove(TraversalDirection.down);
      async.flushMicrotasks();
      mode.onStickRelease();
      async.flushMicrotasks();
      expect(target.log, <String>['line1', 'lookup']);
      mode.onRelease(GamepadButton.lb);
    });
  });

  test('right end: shrink from the last match, extend up to the line end, '
      'any move clears the cap', () {
    fakeAsync((FakeAsync async) {
      target.fromCursor = 4;
      mode.onPress(GamepadButton.lb);
      async.elapse(ControllerLookupMode.holdThreshold);
      target.matches.addAll(<int>[3, 2, 1]);
      void tap(GamepadButton b) {
        mode.onPress(b);
        mode.onRelease(b);
        async.flushMicrotasks();
      }

      tap(GamepadButton.dpadRight);
      expect(mode.lastMatched, 3);
      expect(mode.maxGraphemes, isNull);
      tap(GamepadButton.rightStickLeft); // 3 - 1
      expect(mode.maxGraphemes, 2);
      tap(GamepadButton.rightStickLeft); // matched 2 -> 1
      expect(mode.maxGraphemes, 1);
      target.log.clear();
      tap(GamepadButton.rightStickLeft); // already 1: no change, no lookup
      expect(mode.maxGraphemes, 1);
      expect(target.log, isEmpty);
      // The dictionary only finds 1 grapheme under caps 2 and 3: extend keeps
      // growing from the cap, not from the (shorter) match.
      target.matches.addAll(<int>[1, 1]);
      tap(GamepadButton.rightStickRight);
      expect(mode.maxGraphemes, 2);
      tap(GamepadButton.rightStickRight);
      expect(mode.maxGraphemes, 3);
      tap(GamepadButton.rightStickRight);
      expect(mode.maxGraphemes, 4);
      // Past the graphemes left on the line: back to unlimited.
      tap(GamepadButton.rightStickRight);
      expect(mode.maxGraphemes, isNull);
      expect(target.log, <String>['lookup2', 'lookup3', 'lookup4', 'lookup']);
      // A cursor move clears the cap and the last match.
      target.matches.add(3);
      tap(GamepadButton.dpadLeft);
      tap(GamepadButton.rightStickLeft);
      expect(mode.maxGraphemes, 2);
      tap(GamepadButton.dpadLeft);
      expect(mode.maxGraphemes, isNull);
      expect(mode.lastMatched, isNull);
      expect(target.log.last, 'lookup');
      mode.onRelease(GamepadButton.lb);
    });
  });

  test('the mode resolves its buttons from the registry: a rebind takes '
      'effect, an unbound button stays with the page', () {
    fakeAsync((FakeAsync async) {
      registry.setActive(false);
      final List<String> popup = <String>[];
      mode.popupHooks = () => _hooks(popup);
      // Mine moves from X to R3; X is unbound in the scope now.
      shortcuts.updateBinding(
        ShortcutAction.controllerLookupMine,
        const ShortcutBindingSet(
          gamepadBindings: <GamepadBinding>[
            GamepadBinding(GamepadButton.thumbRight),
          ],
        ),
      );
      expect(
        mode.actionFor(GamepadButton.thumbRight),
        ShortcutAction.controllerLookupMine,
      );
      expect(mode.actionFor(GamepadButton.x), isNull);
      mode.onPress(GamepadButton.lb);
      async.elapse(ControllerLookupMode.holdThreshold);
      expect(mode.onPress(GamepadButton.thumbRight), isTrue);
      expect(mode.onPress(GamepadButton.x), isFalse);
      expect(mode.onRelease(GamepadButton.x), isFalse);
      expect(mode.swallowsRepeat(GamepadButton.x), isFalse);
      expect(mode.swallowsRepeat(GamepadButton.thumbRight), isTrue);
      expect(popup, <String>['mine']);
      mode.onRelease(GamepadButton.lb);
    });
  });

  test('default keys of the controllerLookup scope', () {
    const Map<GamepadButton, ShortcutAction>
    expected = <GamepadButton, ShortcutAction>{
      GamepadButton.dpadLeft: ShortcutAction.controllerLookupCursorLeft,
      GamepadButton.dpadRight: ShortcutAction.controllerLookupCursorRight,
      GamepadButton.dpadUp: ShortcutAction.controllerLookupLineUp,
      GamepadButton.dpadDown: ShortcutAction.controllerLookupLineDown,
      GamepadButton.thumbLeft: ShortcutAction.controllerLookupToggleGranularity,
      GamepadButton.rightStickLeft: ShortcutAction.controllerLookupShrinkEnd,
      GamepadButton.rightStickRight: ShortcutAction.controllerLookupExtendEnd,
      GamepadButton.x: ShortcutAction.controllerLookupMine,
      GamepadButton.y: ShortcutAction.controllerLookupPlayAudio,
      GamepadButton.rt: ShortcutAction.controllerLookupNextEntry,
      GamepadButton.lt: ShortcutAction.controllerLookupPrevEntry,
      GamepadButton.a: ShortcutAction.controllerLookupEnterResult,
      GamepadButton.b: ShortcutAction.controllerLookupCloseOrExit,
    };
    for (final TargetPlatform p in <TargetPlatform>[
      TargetPlatform.windows,
      TargetPlatform.macOS,
      TargetPlatform.android,
      TargetPlatform.iOS,
    ]) {
      mode.shortcutRegistry = FushiShortcutRegistry()..loadDefaults(p);
      for (final MapEntry<GamepadButton, ShortcutAction> e
          in expected.entries) {
        expect(mode.actionFor(e.key), e.value, reason: '$p ${e.key}');
      }
      for (final GamepadButton b in <GamepadButton>[
        GamepadButton.lb,
        GamepadButton.rb,
        GamepadButton.select,
        GamepadButton.start,
      ]) {
        expect(mode.actionFor(b), isNull, reason: '$p $b enters / pages');
      }
    }
  });

  test('without a registry no button is a lookup-mode button', () {
    fakeAsync((FakeAsync async) {
      mode.shortcutRegistry = null;
      mode.onPress(GamepadButton.lb);
      async.elapse(ControllerLookupMode.holdThreshold);
      expect(mode.active, isTrue);
      expect(mode.onPress(GamepadButton.dpadRight), isFalse);
      expect(mode.onPress(GamepadButton.x), isFalse);
      mode.onRelease(GamepadButton.lb);
    });
  });

  test('A enters the in-page result (single screen); a lookup alone never '
      'hands the cursor over', () {
    fakeAsync((FakeAsync async) {
      registry.setActive(false);
      bool visible = false;
      mode.popupHooks = () => _hooks(<String>[], visible: visible);
      mode.onPress(GamepadButton.lb);
      async.elapse(ControllerLookupMode.holdThreshold);
      mode.onPress(GamepadButton.dpadRight);
      mode.onRelease(GamepadButton.dpadRight);
      async.flushMicrotasks();
      expect(target.entered, 0);
      mode.onPress(GamepadButton.a);
      expect(target.entered, 0, reason: 'nothing open, nothing to enter');
      visible = true;
      mode.onPress(GamepadButton.a);
      expect(target.entered, 1);
      mode.onRelease(GamepadButton.lb);
    });
  });

  test('with a lookup open on the companion, buttons act on it', () {
    fakeAsync((FakeAsync async) {
      sink.open = true;
      mode.onPress(GamepadButton.lb);
      mode.onPress(GamepadButton.x);
      mode.onPress(GamepadButton.y);
      // A (enter result) has nothing to enter on the companion.
      mode.onPress(GamepadButton.a);
      expect(target.entered, 0);
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
      mode.onPress(GamepadButton.x);
      mode.onPress(GamepadButton.y);
      mode.onPress(GamepadButton.rt);
      mode.onPress(GamepadButton.b);
      expect(popup, <String>['mine', 'audio', 'next']);
      // The page closes its own popup (universal Back).
      expect(replayed, <GamepadButton>[GamepadButton.b]);
      expect(sink.sent, isEmpty);
    });
  });

  test('S7i: "Lookups open on: Top screen": the mode stays on (hold L1), '
      'follow-ups go to the in-page popup, R1 still drives the panel', () {
    fakeAsync((FakeAsync async) {
      registry.setLookupsOnCompanion(false);
      expect(registry.lookupController, isNull);
      expect(registry.controller, same(sink));
      expect(mode.style, ControllerLookupStyle.holdL1);
      // A lookup is open on the companion (made from the panel itself): the
      // controller still works the popup on top.
      sink.open = true;
      final List<String> popup = <String>[];
      mode.popupHooks = () => _hooks(popup);
      mode.onPress(GamepadButton.lb);
      mode.onPress(GamepadButton.x);
      mode.onPress(GamepadButton.y);
      mode.onPress(GamepadButton.rt);
      expect(mode.onRightStick(24), isTrue);
      mode.onPress(GamepadButton.b);
      expect(popup, <String>['mine', 'audio', 'next', 'scroll24.0']);
      expect(replayed, <GamepadButton>[GamepadButton.b]);
      expect(sink.sent, isEmpty);
      mode.onRelease(GamepadButton.lb);

      expect(mode.onPress(GamepadButton.rb), isTrue);
      mode.onPress(GamepadButton.dpadDown);
      mode.onRelease(GamepadButton.dpadDown);
      expect(mode.onRelease(GamepadButton.rb), isTrue);
      expect(sink.sent, <String>[
        'P:${CompanionPanelNav.begin}',
        'P:${CompanionPanelNav.down}',
        'P:${CompanionPanelNav.end}',
      ]);

      // Back to "Bottom screen": follow-ups reach the companion again.
      registry.setLookupsOnCompanion(true);
      sink.sent.clear();
      mode.onPress(GamepadButton.lb);
      mode.onPress(GamepadButton.x);
      expect(sink.sent, <String>['L:${CompanionLookupActions.mine}']);
      mode.onRelease(GamepadButton.lb);
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

  test('a press left to the page keeps its release and repeats there '
      '(A in the in-page popup after enter result is no long press)', () {
    fakeAsync((FakeAsync async) {
      registry.setActive(false);
      mode.popupHooks = () => _hooks(<String>[]);
      mode.onPress(GamepadButton.lb);
      async.elapse(ControllerLookupMode.holdThreshold);
      expect(mode.onPress(GamepadButton.a), isTrue); // enter result
      expect(target.entered, 1);
      expect(mode.swallowsRepeat(GamepadButton.a), isTrue);
      expect(mode.onRelease(GamepadButton.a), isTrue);
      // The popup cursor owns the input now: A goes to the page, press,
      // repeat and release alike.
      target.owns = false;
      expect(mode.onPress(GamepadButton.a), isFalse);
      expect(mode.swallowsRepeat(GamepadButton.a), isFalse);
      expect(mode.onRelease(GamepadButton.a), isFalse);
      expect(mode.onPress(GamepadButton.dpadDown), isFalse);
      expect(mode.swallowsRepeat(GamepadButton.dpadDown), isFalse);
      expect(mode.onRelease(GamepadButton.dpadDown), isFalse);
      expect(target.entered, 1);
      mode.onRelease(GamepadButton.lb);
    });
  });

  test('a consumed press keeps its release swallowed after the mode left; '
      'a press from before the mode keeps its release with the page', () {
    fakeAsync((FakeAsync async) {
      target.prefs[kControllerLookupStylePrefKey] = 'selectToggle';
      // Held before the mode: the page saw the press, it gets the release.
      expect(mode.onPress(GamepadButton.dpadRight), isFalse);
      expect(mode.onPress(GamepadButton.select), isTrue);
      expect(mode.active, isTrue);
      expect(mode.swallowsRepeat(GamepadButton.dpadRight), isFalse);
      expect(mode.onRelease(GamepadButton.dpadRight), isFalse);
      // B leaves the mode on press; its release is still the mode's.
      expect(mode.onPress(GamepadButton.b), isTrue);
      expect(mode.active, isFalse);
      expect(mode.onRelease(GamepadButton.b), isTrue);
      expect(mode.onRelease(GamepadButton.select), isTrue);
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

  test('a raw-input claim (game stream) leaves every button to the page, '
      'companion up included', () {
    fakeAsync((FakeAsync async) {
      final Object stream = Object();
      // R1 held when the stream takes over: panel drive ends.
      expect(mode.onPress(GamepadButton.rb), isTrue);
      mode.onPress(GamepadButton.dpadDown);
      mode.claimRawInput(stream);
      expect(mode.panelDriving, isFalse);
      expect(mode.rawInputClaimed, isTrue);
      sink.sent.clear();
      for (final GamepadButton b in GamepadButton.values) {
        expect(mode.onPress(b), isFalse, reason: '$b');
        expect(mode.swallowsRepeat(b), isFalse, reason: '$b');
        expect(mode.onRelease(b), isFalse, reason: '$b');
      }
      // Holding L1 / R1 is a game button now, not lookup mode / panel drive.
      expect(mode.onPress(GamepadButton.lb), isFalse);
      async.elapse(ControllerLookupMode.holdThreshold * 2);
      expect(mode.active, isFalse);
      expect(mode.onStickMove(TraversalDirection.down), isFalse);
      expect(mode.onRightStick(40), isFalse);
      expect(sink.sent, isEmpty);
      expect(replayed, isEmpty);
      expect(target.log, isEmpty);

      // Only the owner's release counts; then R1 drives the panel again.
      mode.releaseRawInput(Object());
      expect(mode.rawInputClaimed, isTrue);
      mode.releaseRawInput(stream);
      expect(mode.rawInputClaimed, isFalse);
      expect(mode.onPress(GamepadButton.rb), isTrue);
      expect(mode.onRelease(GamepadButton.rb), isTrue);
      expect(replayed, <GamepadButton>[GamepadButton.rb]);
    });
  });

  test('a raw-input claim also bypasses the Android early key handler', () {
    const KeyDownEvent r1 = KeyDownEvent(
      physicalKey: PhysicalKeyboardKey.gameButtonRight1,
      logicalKey: LogicalKeyboardKey.gameButtonRight1,
      timeStamp: Duration.zero,
    );
    const KeyUpEvent r1Up = KeyUpEvent(
      physicalKey: PhysicalKeyboardKey.gameButtonRight1,
      logicalKey: LogicalKeyboardKey.gameButtonRight1,
      timeStamp: Duration.zero,
    );
    // Companion up, no claim: R1 is panel drive.
    expect(
      interceptNativeControllerLookupKey(r1, mode, isAndroid: true),
      isTrue,
    );
    expect(
      interceptNativeControllerLookupKey(r1Up, mode, isAndroid: true),
      isTrue,
    );
    mode.claimRawInput(Object());
    expect(
      interceptNativeControllerLookupKey(r1, mode, isAndroid: true),
      isFalse,
    );
    expect(
      interceptNativeControllerLookupKey(r1Up, mode, isAndroid: true),
      isFalse,
    );
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
