import 'dart:convert';

import 'package:fushi_engine/tts/tts_types.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';
import 'package:test/test.dart';

import 'tts_test_helpers.dart';

void main() {
  group('TtsVoicePreset json', () {
    test('round trip keeps params, secrets, revision', () {
      const TtsVoicePreset preset = TtsVoicePreset(
        id: 'p1',
        providerId: 'gpt_sovits',
        name: '声音 A',
        params: <String, String>{'endpoint': 'http://127.0.0.1:9880'},
        secrets: <String, String>{'api_key': 'sk-秘密', 'empty': ''},
        revision: 3,
      );
      final Map<String, Object?> json = preset.toJson();
      final Map<String, Object?> secretsB64 =
          json['secretsB64']! as Map<String, Object?>;
      expect(secretsB64.keys, <String>['api_key']);
      expect(secretsB64['api_key'], base64Encode(utf8.encode('sk-秘密')));
      expect(jsonEncode(json), isNot(contains('sk-')));

      final TtsVoicePreset back = TtsVoicePreset.fromJson(
        jsonDecode(jsonEncode(json)),
      )!;
      expect(back.id, 'p1');
      expect(back.providerId, 'gpt_sovits');
      expect(back.name, '声音 A');
      expect(back.params, preset.params);
      expect(back.secrets, <String, String>{'api_key': 'sk-秘密'});
      expect(back.revision, 3);
    });

    test('param prefers secrets, then params, then fallback', () {
      const TtsVoicePreset preset = TtsVoicePreset(
        id: 'p',
        providerId: 'x',
        name: '',
        params: <String, String>{'a': 'param', 'b': 'pb'},
        secrets: <String, String>{'a': 'secret'},
      );
      expect(preset.param('a'), 'secret');
      expect(preset.param('b'), 'pb');
      expect(preset.param('c', fallback: 'fb'), 'fb');
      expect(preset.param('c'), '');
    });

    test('fromJson rejects missing id/provider and drops bad base64', () {
      expect(TtsVoicePreset.fromJson('nope'), isNull);
      expect(TtsVoicePreset.fromJson(<String, Object?>{'provider': 'x'}), isNull);
      expect(
        TtsVoicePreset.fromJson(<String, Object?>{'id': '', 'provider': 'x'}),
        isNull,
      );
      final TtsVoicePreset p = TtsVoicePreset.fromJson(<String, Object?>{
        'id': 'i',
        'provider': 'x',
        'params': <String, Object?>{'ok': 'v', 'bad': 1},
        'secretsB64': <String, Object?>{'k': '%%%not-base64'},
        'revision': 'x',
      })!;
      expect(p.name, '');
      expect(p.params, <String, String>{'ok': 'v'});
      expect(p.secrets, isEmpty);
      expect(p.revision, 0);
    });

    test('copyWith', () {
      const TtsVoicePreset p = TtsVoicePreset(
        id: 'i',
        providerId: 'x',
        name: 'n',
      );
      final TtsVoicePreset q = p.copyWith(revision: 2, name: 'm');
      expect(q.id, 'i');
      expect(q.revision, 2);
      expect(q.name, 'm');
    });
  });

  group('TtsPresetStore', () {
    late MemoryPrefStore prefs;
    late TtsPresetStore store;

    setUp(() {
      prefs = MemoryPrefStore();
      store = TtsPresetStore(prefs);
    });

    test('empty / corrupt storage yields no presets', () {
      expect(store.loadPresets(), isEmpty);
      expect(store.activePreset(), isNull);
      prefs.values[TtsPresetStore.presetsKey] = '{broken';
      expect(store.loadPresets(), isEmpty);
      prefs.values[TtsPresetStore.presetsKey] = '{"a":1}';
      expect(store.loadPresets(), isEmpty);
    });

    test('save/load round trip, secrets stored as base64 only', () async {
      await store.savePresets(const <TtsVoicePreset>[
        TtsVoicePreset(
          id: 'a',
          providerId: 'edge',
          name: 'A',
          secrets: <String, String>{'api_key': 'topsecret'},
        ),
        TtsVoicePreset(id: 'b', providerId: 'azure', name: 'B'),
      ]);
      final String raw = prefs.values[TtsPresetStore.presetsKey] as String;
      expect(raw, isNot(contains('topsecret')));
      final List<TtsVoicePreset> loaded = store.loadPresets();
      expect(loaded.map((TtsVoicePreset p) => p.id), <String>['a', 'b']);
      expect(loaded.first.secrets['api_key'], 'topsecret');
    });

    test('invalid items are skipped', () {
      prefs.values[TtsPresetStore.presetsKey] = jsonEncode(<Object?>[
        <String, Object?>{'id': 'ok', 'provider': 'edge'},
        <String, Object?>{'id': 'noprovider'},
        42,
      ]);
      expect(store.loadPresets().map((TtsVoicePreset p) => p.id), <String>[
        'ok',
      ]);
    });

    test('activePreset falls back to first when unset or deleted', () async {
      await store.savePresets(const <TtsVoicePreset>[
        TtsVoicePreset(id: 'a', providerId: 'edge', name: 'A'),
        TtsVoicePreset(id: 'b', providerId: 'edge', name: 'B'),
      ]);
      expect(store.activePresetId, isNull);
      expect(store.activePreset()!.id, 'a');
      await store.setActivePresetId('b');
      expect(store.activePresetId, 'b');
      expect(store.activePreset()!.id, 'b');
      await store.setActivePresetId('gone');
      expect(store.activePreset()!.id, 'a');
      await store.setActivePresetId(null);
      expect(store.activePresetId, isNull);
    });

    test('speed defaults to 1.0 and rejects non-positive', () async {
      expect(store.speed, 1.0);
      await store.setSpeed(1.5);
      expect(store.speed, 1.5);
      prefs.values[TtsPresetStore.speedKey] = 0;
      expect(store.speed, 1.0);
      prefs.values[TtsPresetStore.speedKey] = 'fast';
      expect(store.speed, 1.0);
    });

    test('resume points per book', () async {
      expect(store.resumeFor('book1'), isNull);
      await store.saveResume(
        'book1',
        const TtsResumePoint(
          section: 2,
          matchStart: 120,
          offsetMs: 3456,
          audioKey: 'abc',
        ),
      );
      final TtsResumePoint r = store.resumeFor('book1')!;
      expect(r.section, 2);
      expect(r.matchStart, 120);
      expect(r.offsetMs, 3456);
      expect(r.audioKey, 'abc');
      expect(store.resumeFor('book2'), isNull);
      expect(prefs.values.keys, contains(TtsPresetStore.resumeKeyFor('book1')));
      prefs.values[TtsPresetStore.resumeKeyFor('book2')] = 'not json';
      expect(store.resumeFor('book2'), isNull);
      prefs.values[TtsPresetStore.resumeKeyFor('book2')] = '{"s":1}';
      expect(store.resumeFor('book2'), isNull);
    });
  });

  group('tts_types', () {
    test('TtsAudioFormat.parse', () {
      expect(TtsAudioFormat.parse('wav'), TtsAudioFormat.wav);
      expect(TtsAudioFormat.parse('mp3'), TtsAudioFormat.mp3);
      expect(TtsAudioFormat.parse('ogg'), isNull);
      expect(TtsAudioFormat.parse(null), isNull);
    });

    test('TtsBoundary json round trip and rejection', () {
      const TtsBoundary b = TtsBoundary(
        textOffset: 1,
        textLength: 2,
        offsetMs: 3,
        durationMs: 4,
      );
      final TtsBoundary back = TtsBoundary.fromJson(b.toJson())!;
      expect(
        <int>[back.textOffset, back.textLength, back.offsetMs, back.durationMs],
        <int>[1, 2, 3, 4],
      );
      expect(TtsBoundary.fromJson(<String, Object?>{'o': 1}), isNull);
      expect(TtsBoundary.fromJson(null), isNull);
    });

    test('TtsCancelToken listeners', () {
      final TtsCancelToken token = TtsCancelToken();
      int a = 0, b = 0;
      final void Function() unregisterA = token.onCancel(() => a++);
      token.onCancel(() => b++);
      unregisterA();
      expect(token.throwIfCancelled, returnsNormally);
      token.cancel();
      token.cancel();
      expect(a, 0);
      expect(b, 1);
      expect(
        token.throwIfCancelled,
        throwsA(
          isA<TtsFailure>().having(
            (TtsFailure f) => f.code,
            'code',
            TtsFailureCode.cancelled,
          ),
        ),
      );
      int c = 0;
      token.onCancel(() => c++);
      expect(c, 1);
    });

    test('TtsFailure.toString', () {
      expect(
        const TtsFailure(TtsFailureCode.network).toString(),
        'TtsFailure(network)',
      );
      expect(
        const TtsFailure(TtsFailureCode.serverError, 'HTTP 500').toString(),
        'TtsFailure(serverError: HTTP 500)',
      );
    });
  });
}
