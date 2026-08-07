import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// W2-2 载入期迁移：存量用户卡模板里的音频旧别名 `{sasayaki-audio}` 在
/// [BaseAnkiRepository.loadSettings] 被一次性改写为 `{sentence-audio}` 并回写
/// 持久层（SharedPreferences 无版本阶梯，载入期改写即迁移通道）。断言覆盖：
/// 裸 token 与「拼进 HTML 大模板」两种字段形态都改写、无关字段逐字节不动、
/// 回写后幂等（源串不再含旧 token）、无残留时不写。
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

  test('loadSettings rewrites {sasayaki-audio} templates and persists',
      () async {
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

    // 已回写持久层：重读原始串零旧 token（幂等锚点）。
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String rewritten = prefs.getString('hoshi_anki_settings')!;
    expect(rewritten.contains('{sasayaki-audio}'), isFalse);
    expect(rewritten.contains('{sentence-audio}'), isTrue);
  });

  test('loadSettings leaves alias-free settings untouched', () async {
    final String cleanJson = jsonEncode(<String, dynamic>{
      'fieldMappings': <String, String>{'SentenceAudio': '{sentence-audio}'},
    });
    SharedPreferences.setMockInitialValues(<String, Object>{
      'hoshi_anki_settings': cleanJson,
    });

    final AnkiSettings settings = await _StubRepo().loadSettings();
    expect(settings.fieldMappings['SentenceAudio'], '{sentence-audio}');
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('hoshi_anki_settings'), cleanJson,
        reason: '无残留时不回写（字节等值）');
  });
}
