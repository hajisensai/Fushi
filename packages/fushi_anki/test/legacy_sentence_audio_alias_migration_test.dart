import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 载入期迁移（[BaseAnkiRepository.readSettingsJson] 唯一通道）：
/// - W2-7 键搬移：存量 `hoshi_anki_settings` 值搬到 `fushi_anki_settings`
///   后删除旧键；
/// - W2-2 别名改写：存量卡模板里的 `{sasayaki-audio}` 一次性改写为
///   `{sentence-audio}` 并回写。
/// 断言覆盖：两迁移可叠加、裸 token 与大模板形态都改写、无关字段不动、
/// 幂等（新键无残留时零写）、全新用户零副作用。
class _StubRepo extends BaseAnkiRepository {
  @override
  Future<AnkiFetchResult> fetchConfiguration() async =>
      const AnkiFetchResult.error('n/a');

  @override
  Future<MineOutcome> mineEntry({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async =>
      const MineOutcome.success();

  @override
  Future<bool> isDuplicate(String expression, String reading) async => false;

  @override
  Future<bool> createNoteType(AnkiNoteTypeTemplate template) async => false;

  @override
  Future<bool> createDeck(String name) async => false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('legacy key + legacy alias migrate together on load', () async {
    final String legacyJson = jsonEncode(<String, dynamic>{
      'fieldMappings': <String, String>{
        'SentenceAudio': '{sasayaki-audio}',
        'Front': '<div>{expression} {sasayaki-audio}</div>',
        'Back': '{glossary}',
      },
    });
    SharedPreferences.setMockInitialValues(<String, Object>{
      'hoshi_anki_settings': legacyJson,
    });

    final AnkiSettings settings = await _StubRepo().loadSettings();
    expect(settings.fieldMappings['SentenceAudio'], '{sentence-audio}');
    expect(settings.fieldMappings['Front'],
        '<div>{expression} {sentence-audio}</div>',
        reason: '拼进 HTML 大模板的 token 也按子串改写');
    expect(settings.fieldMappings['Back'], '{glossary}', reason: '无关字段不动');

    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('hoshi_anki_settings'), isNull,
        reason: 'W2-7 键搬移后旧键删除');
    final String rewritten = prefs.getString('fushi_anki_settings')!;
    expect(rewritten.contains('{sasayaki-audio}'), isFalse);
    expect(rewritten.contains('{sentence-audio}'), isTrue);
  });

  test('legacy key without alias just moves to the new key', () async {
    final String legacyJson = jsonEncode(<String, dynamic>{
      'fieldMappings': <String, String>{'SentenceAudio': '{sentence-audio}'},
      'selectedDeckName': 'MyDeck',
    });
    SharedPreferences.setMockInitialValues(<String, Object>{
      'hoshi_anki_settings': legacyJson,
    });

    final AnkiSettings settings = await _StubRepo().loadSettings();
    expect(settings.selectedDeckName, 'MyDeck');
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('hoshi_anki_settings'), isNull);
    expect(prefs.getString('fushi_anki_settings'), legacyJson,
        reason: '搬移是字节等值，别名不在场时零改写');
  });

  test('new-key settings without residue are untouched', () async {
    final String cleanJson = jsonEncode(<String, dynamic>{
      'fieldMappings': <String, String>{'SentenceAudio': '{sentence-audio}'},
    });
    SharedPreferences.setMockInitialValues(<String, Object>{
      'fushi_anki_settings': cleanJson,
    });

    final AnkiSettings settings = await _StubRepo().loadSettings();
    expect(settings.fieldMappings['SentenceAudio'], '{sentence-audio}');
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('fushi_anki_settings'), cleanJson,
        reason: '无残留时不回写（字节等值）');
  });

  test('new key wins when both generations exist', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'fushi_anki_settings': jsonEncode(<String, dynamic>{
        'selectedDeckName': 'NewDeck',
      }),
      'hoshi_anki_settings': jsonEncode(<String, dynamic>{
        'selectedDeckName': 'OldDeck',
      }),
    });

    final AnkiSettings settings = await _StubRepo().loadSettings();
    expect(settings.selectedDeckName, 'NewDeck', reason: '新键是本代写入；旧键只是残影，不覆盖');
  });

  test('fresh user: no keys, no side effects', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final AnkiSettings settings = await _StubRepo().loadSettings();
    expect(settings.fieldMappings, isEmpty);
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('fushi_anki_settings'), isNull);
    expect(prefs.getString('hoshi_anki_settings'), isNull);
  });
}
