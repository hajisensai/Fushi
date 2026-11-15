import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/second_screen/second_screen_controller.dart';
import 'package:fushi/src/second_screen/second_screen_host.dart';

import 'fake_second_screen_platform.dart';

void main() {
  late Map<String, Object?> prefs;
  late FakeSecondScreenPlatform platform;
  late SecondScreenHost host;

  SecondScreenController build({SecondScreenHost? withHost}) =>
      SecondScreenController(
        readPref: (String k) => prefs[k],
        writePref: (String k, Object? v) async => prefs[k] = v,
        host: withHost ?? host,
      );

  setUp(() {
    prefs = <String, Object?>{};
    platform = FakeSecondScreenPlatform(
      displays: <SecondScreenDisplayInfo>[thorBottomScreen],
    );
    host = SecondScreenHost(platform);
  });

  tearDown(() => host.dispose());

  test('unsupported platform: inactive, no prompt, no setting row', () async {
    final SecondScreenController c = SecondScreenController(
      readPref: (String k) => prefs[k],
      writePref: (String k, Object? v) async => prefs[k] = v,
      host: null,
    );
    await c.start();
    expect(c.displayAvailable, isFalse);
    expect(c.needsApproval, isFalse);
    expect(c.isActive, isFalse);
    await c.setMode(SecondScreenMode.always);
    expect(c.isActive, isFalse);
  });

  test('no second display: inactive, no prompt', () async {
    platform.displays = <SecondScreenDisplayInfo>[];
    final SecondScreenController c = build();
    await c.start();
    expect(c.displayAvailable, isFalse);
    expect(c.needsApproval, isFalse);
    expect(c.isActive, isFalse);
    expect(platform.calls, isEmpty);
  });

  test('auto asks once; approval is remembered per screen', () async {
    final SecondScreenController c = build();
    await c.start();
    expect(c.needsApproval, isTrue);
    expect(c.isActive, isFalse);
    expect(platform.calls, isEmpty, reason: 'nothing starts before the answer');

    await c.answerApproval(useScreen: true);
    expect(c.isActive, isTrue);
    expect(platform.calls, <String>['show:4:companion']);
    expect(prefs[kSecondScreenApprovedPrefKey], contains('Screen-2|468x538'));
    c.dispose();

    // Next launch: no question, the companion starts by itself.
    final SecondScreenHost nextHost = SecondScreenHost(
      FakeSecondScreenPlatform(
        displays: <SecondScreenDisplayInfo>[thorBottomScreen],
      ),
    );
    addTearDown(nextHost.dispose);
    final SecondScreenController again = build(withHost: nextHost);
    await again.start();
    expect(again.needsApproval, isFalse);
    expect(again.isActive, isTrue);
  });

  test('"not now" stays single-screen for this run without saving', () async {
    final SecondScreenController c = build();
    await c.start();
    await c.answerApproval(useScreen: false);
    expect(c.needsApproval, isFalse);
    expect(c.isActive, isFalse);
    expect(prefs[kSecondScreenApprovedPrefKey], isNull);
  });

  test('a different screen (e.g. a TV) is not auto-approved', () async {
    prefs[kSecondScreenApprovedPrefKey] = '["Screen-2|468x538"]';
    platform.displays = <SecondScreenDisplayInfo>[hdmiScreen];
    final SecondScreenController c = build();
    await c.start();
    expect(c.needsApproval, isTrue);
    expect(c.isActive, isFalse);
  });

  test('a corrupt approval list asks again', () async {
    prefs[kSecondScreenApprovedPrefKey] = '{not json';
    final SecondScreenController c = build();
    await c.start();
    expect(c.needsApproval, isTrue);
  });

  test('off and always', () async {
    prefs[kSecondScreenModePrefKey] = 'off';
    final SecondScreenController c = build();
    await c.start();
    expect(c.needsApproval, isFalse);
    expect(c.isActive, isFalse);

    await c.setMode(SecondScreenMode.always);
    expect(c.isActive, isTrue);
    expect(prefs[kSecondScreenModePrefKey], 'always');

    await c.setMode(SecondScreenMode.off);
    expect(c.isActive, isFalse);
    expect(platform.calls.last, 'dismiss');
  });

  test('display removed at runtime falls back to single screen', () async {
    prefs[kSecondScreenModePrefKey] = 'always';
    final SecondScreenController c = build();
    await c.start();
    expect(c.isActive, isTrue);

    // Native closes the panel with its display, then reports the list.
    platform.detach();
    platform.setDisplays(<SecondScreenDisplayInfo>[]);
    await pumpEventQueue();
    expect(c.displayAvailable, isFalse);
    expect(c.isActive, isFalse);

    // It comes back: the companion follows.
    platform.setDisplays(<SecondScreenDisplayInfo>[thorBottomScreen]);
    await pumpEventQueue();
    expect(c.isActive, isTrue);
  });

  test('a crashed panel comes back on the next display event', () async {
    prefs[kSecondScreenModePrefKey] = 'always';
    final SecondScreenController c = build();
    await c.start();
    platform.detach();
    await pumpEventQueue();
    expect(c.isActive, isFalse, reason: 'isActive follows the real panel');
    expect(platform.calls, <String>['show:4:companion'], reason: 'no loop');
    platform.setDisplays(<SecondScreenDisplayInfo>[thorBottomScreen]);
    await pumpEventQueue();
    expect(c.isActive, isTrue);
  });

  test(
    'session toggle overrides the setting until the screen changes',
    () async {
      prefs[kSecondScreenModePrefKey] = 'always';
      final SecondScreenController c = build();
      await c.start();
      await c.toggleForSession();
      expect(c.isActive, isFalse);
      await c.toggleForSession();
      expect(c.isActive, isTrue);
      await c.toggleForSession();
      expect(c.isActive, isFalse);

      // Another screen: the override is gone, the setting applies again.
      platform.setDisplays(<SecondScreenDisplayInfo>[hdmiScreen]);
      await pumpEventQueue();
      expect(c.isActive, isTrue);
    },
  );

  test('the game stream takes the screen; the companion comes back', () async {
    prefs[kSecondScreenModePrefKey] = 'always';
    final SecondScreenController c = build();
    await c.start();
    await host.request(SecondScreenPanelMode.gameStream, 4);
    expect(c.isActive, isFalse, reason: 'lookups stay on the top screen');
    await host.request(SecondScreenPanelMode.gameStream, null);
    expect(c.isActive, isTrue);
  });

  test('a host reset places the companion again', () async {
    prefs[kSecondScreenModePrefKey] = 'always';
    final SecondScreenController c = build();
    await c.start();
    platform.up = null;
    platform.emit(
      const SecondScreenHostReset(<SecondScreenDisplayInfo>[thorBottomScreen]),
    );
    await pumpEventQueue();
    expect(c.isActive, isTrue);
    expect(platform.calls, <String>['show:4:companion', 'show:4:companion']);
  });
}
