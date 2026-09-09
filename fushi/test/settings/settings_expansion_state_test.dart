import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/settings/settings_expansion_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  test(
    'unset sections use their declared defaults and do not write storage',
    () async {
      final SettingsExpansionState state = SettingsExpansionState();
      addTearDown(state.dispose);
      await state.load();
      expect(state.value('advanced', defaultValue: false), isFalse);
      expect(state.value('common', defaultValue: true), isTrue);
      expect((await SharedPreferences.getInstance()).getKeys(), isEmpty);
    },
  );

  test(
    'a fresh store restores device choices independently for each section',
    () async {
      final SettingsExpansionState first = SettingsExpansionState();
      final SettingsExpansionState restored = SettingsExpansionState();
      addTearDown(first.dispose);
      addTearDown(restored.dispose);
      await first.setExpanded('reading.advanced', true);
      await first.setExpanded('video.advanced', false);
      await restored.load();
      expect(restored.value('reading.advanced', defaultValue: false), isTrue);
      expect(restored.value('video.advanced', defaultValue: true), isFalse);
      expect(restored.value('lookup.advanced', defaultValue: false), isFalse);
    },
  );

  test(
    'latest user intent wins while asynchronous preferences are loading',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        '${SettingsExpansionState.keyPrefix}advanced': false,
        '${SettingsExpansionState.keyPrefix}other': true,
      });
      final Completer<SharedPreferences> loaded =
          Completer<SharedPreferences>();
      final SettingsExpansionState state = SettingsExpansionState(
        loadPreferences: () => loaded.future,
      );
      addTearDown(state.dispose);
      final Future<void> loading = state.load();
      final Future<void> firstToggle = state.setExpanded('advanced', false);
      final Future<void> secondToggle = state.setExpanded('advanced', true);
      expect(state.value('advanced', defaultValue: false), isTrue);
      final SharedPreferences preferences =
          await SharedPreferences.getInstance();
      loaded.complete(preferences);
      await Future.wait(<Future<void>>[loading, firstToggle, secondToggle]);
      expect(state.value('advanced', defaultValue: false), isTrue);
      expect(state.value('other', defaultValue: false), isTrue);
      expect(
        preferences.getBool('${SettingsExpansionState.keyPrefix}advanced'),
        isTrue,
      );
    },
  );

  test(
    'an explicit later load recovers after the first loader failure',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        '${SettingsExpansionState.keyPrefix}advanced': true,
      });
      int attempts = 0;
      final SettingsExpansionState state = SettingsExpansionState(
        loadPreferences: () async {
          attempts++;
          if (attempts == 1) {
            throw StateError('device store temporarily unavailable');
          }
          return SharedPreferences.getInstance();
        },
      );
      addTearDown(state.dispose);
      await expectLater(state.load(), throwsStateError);
      expect(state.value('advanced', defaultValue: false), isFalse);
      await state.load();
      expect(attempts, 2);
      expect(state.value('advanced', defaultValue: false), isTrue);
    },
  );

  test('unrelated keys and malformed section values are ignored', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'profile': true,
      '${SettingsExpansionState.keyPrefix}malformed': 'true',
    });
    final SettingsExpansionState state = SettingsExpansionState();
    addTearDown(state.dispose);
    await state.load();
    expect(state.value('profile', defaultValue: false), isFalse);
    expect(state.value('malformed', defaultValue: false), isFalse);
  });
}
