import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/game_stream_button_profile.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/sync/game_stream_virtual_button.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';

void main() {
  test('every physical button has a default action', () {
    for (final GameStreamPhysicalButton button
        in GameStreamPhysicalButton.values) {
      expect(
        GameStreamButtonProfile.defaults.containsKey(button),
        isTrue,
        reason: '$button has no default',
      );
    }
  });

  test('old buttons keep their pad mapping; Select switches lookup mode', () {
    const GameStreamButtonProfile profile = GameStreamButtonProfile();
    expect(
      profile.actionFor(GameStreamPhysicalButton.a),
      const GameStreamPadAction(GameStreamVirtualButton.confirm),
    );
    expect(
      profile.actionFor(GameStreamPhysicalButton.b),
      const GameStreamPadAction(GameStreamVirtualButton.cancel),
    );
    expect(
      profile.actionFor(GameStreamPhysicalButton.l1),
      const GameStreamPadAction(GameStreamVirtualButton.shoulderLeft),
    );
    expect(
      profile.actionFor(GameStreamPhysicalButton.r1),
      const GameStreamPadAction(GameStreamVirtualButton.shoulderRight),
    );
    expect(
      profile.actionFor(GameStreamPhysicalButton.start),
      const GameStreamPadAction(GameStreamVirtualButton.menu),
    );
    expect(
      profile.actionFor(GameStreamPhysicalButton.select),
      const GameStreamAppAction(GameStreamReceiverAction.toggleLookupMode),
    );
  });

  test('every host key a button may send resolves in the Windows runner', () {
    // GameStreamHostKeyAction.keys is the one list the on-screen pad and the
    // controller profile offer; the runner's ResolveVirtualKey is what the
    // host accepts. A key missing there would be rejected as invalid_key.
    final String source = File(
      'windows/runner/game_stream_input.cpp',
    ).readAsStringSync();
    final int start = source.indexOf('GameStreamInput::ResolveVirtualKey');
    expect(start, isNonNegative);
    final String body = source.substring(
      start,
      source.indexOf('return 0;', start),
    );
    final Set<String> named = <String>{
      for (final RegExpMatch match in RegExp(
        r'\{"([a-z0-9]+)",\s*VK_',
      ).allMatches(body))
        match.group(1)!,
    };
    expect(named, contains('control'), reason: 'table parsed');
    for (final String key in GameStreamHostKeyAction.keys) {
      final bool singleAlnum = RegExp(r'^[A-Za-z0-9]$').hasMatch(key);
      expect(
        singleAlnum || named.contains(key.toLowerCase()),
        isTrue,
        reason: '$key is not resolved by ResolveVirtualKey',
      );
    }
  });

  test('every action survives a wire round trip', () {
    final List<GameStreamButtonAction> actions = <GameStreamButtonAction>[
      const GameStreamNoAction(),
      for (final GameStreamVirtualButton button
          in GameStreamVirtualButton.values)
        GameStreamPadAction(button),
      for (final String key in GameStreamHostKeyAction.keys)
        GameStreamHostKeyAction(key),
      for (final GameStreamMouseAction mouse in GameStreamMouseAction.values)
        GameStreamMouseButtonAction(mouse),
      for (final GameStreamReceiverAction action
          in GameStreamReceiverAction.values)
        GameStreamAppAction(action),
    ];
    for (final GameStreamButtonAction action in actions) {
      expect(GameStreamButtonAction.tryParse(action.toWire()), action);
    }
  });

  test('unknown or malformed actions do not parse', () {
    expect(GameStreamButtonAction.tryParse(null), isNull);
    expect(GameStreamButtonAction.tryParse(3), isNull);
    expect(GameStreamButtonAction.tryParse(''), isNull);
    expect(GameStreamButtonAction.tryParse('pad:jump'), isNull);
    expect(GameStreamButtonAction.tryParse('key:PrintScreen'), isNull);
    expect(GameStreamButtonAction.tryParse('teleport:here'), isNull);
    expect(GameStreamButtonAction.tryParse(':confirm'), isNull);
  });

  test('only overrides are stored and choosing the default clears one', () {
    final GameStreamButtonProfile changed = const GameStreamButtonProfile()
        .withAction(
          GameStreamPhysicalButton.a,
          const GameStreamHostKeyAction('Space'),
        );
    expect(changed.toJson(), <String, String>{'a': 'key:Space'});
    expect(changed.isCustomized(GameStreamPhysicalButton.a), isTrue);

    final GameStreamButtonProfile back = changed.withAction(
      GameStreamPhysicalButton.a,
      GameStreamButtonProfile.defaults[GameStreamPhysicalButton.a]!,
    );
    expect(back.toJson(), isEmpty);
    expect(back, const GameStreamButtonProfile());
  });

  test('stored JSON round-trips and drops entries this build cannot read', () {
    final GameStreamButtonProfile profile = const GameStreamButtonProfile()
        .withAction(
          GameStreamPhysicalButton.r3,
          const GameStreamMouseButtonAction(GameStreamMouseAction.middleClick),
        )
        .withAction(GameStreamPhysicalButton.y, const GameStreamNoAction());
    final Object? decoded = jsonDecode(jsonEncode(profile.toJson()));
    expect(GameStreamButtonProfile.fromJson(decoded), profile);

    final GameStreamButtonProfile tolerant = GameStreamButtonProfile.fromJson(
      const <String, Object?>{
        'a': 'key:Space',
        'b': 'future:thing',
        'paddle1': 'key:Enter',
        'x': 7,
        // Equal to the default: not an override.
        'l1': 'pad:shoulderLeft',
      },
    );
    expect(tolerant.toJson(), <String, String>{'a': 'key:Space'});
    expect(GameStreamButtonProfile.fromJson('nonsense').toJson(), isEmpty);
  });

  test('controller keys map to physical buttons; arrows map to the D-pad', () {
    expect(
      GameStreamPhysicalButton.gameButtonFor(LogicalKeyboardKey.gameButtonX),
      GameStreamPhysicalButton.x,
    );
    expect(
      GameStreamPhysicalButton.gameButtonFor(
        LogicalKeyboardKey.gameButtonThumbRight,
      ),
      GameStreamPhysicalButton.r3,
    );
    expect(
      GameStreamPhysicalButton.gameButtonFor(LogicalKeyboardKey.arrowUp),
      isNull,
    );
    expect(
      GameStreamPhysicalButton.dpadFor(LogicalKeyboardKey.arrowLeft),
      GameStreamPhysicalButton.dpadLeft,
    );
    expect(GameStreamPhysicalButton.dpadFor(LogicalKeyboardKey.enter), isNull);
  });

  test('persists through preferences and stays on this device', () async {
    final FushiDatabase db = FushiDatabase.forTesting(
      DatabaseConnection(NativeDatabase.memory()),
    );
    addTearDown(db.close);
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    expect(prefs.gameStreamButtonProfile, const GameStreamButtonProfile());
    final GameStreamButtonProfile profile = const GameStreamButtonProfile()
        .withAction(
          GameStreamPhysicalButton.l2,
          const GameStreamHostKeyAction('A'),
        );
    await prefs.setGameStreamButtonProfile(profile);
    prefs.dispose();

    final PreferencesRepository reopened = PreferencesRepository(db);
    await reopened.loadFromDb();
    addTearDown(reopened.dispose);
    expect(reopened.gameStreamButtonProfile, profile);
    expect(
      SyncRepository.deviceLocalPrefKeys,
      contains(kGameStreamButtonProfilePrefKey),
    );
  });
}
