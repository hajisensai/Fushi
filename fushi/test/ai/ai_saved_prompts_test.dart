import 'dart:convert';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/ai/ai_saved_prompts.dart';
import 'package:fushi/src/models/preference_keys.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi_core/fushi_core.dart';

/// 反馈 _LLhOKwmI3：「已保存的提示词」库的存取 / 序列化契约。
void main() {
  group('codec', () {
    test('编码 → 解码往返；通用条目不写 scene 字段', () {
      const List<AiSavedPrompt> prompts = <AiSavedPrompt>[
        AiSavedPrompt(
          id: 'a',
          name: 'A',
          text: 'make it blue',
          sceneWire: 'theme',
        ),
        AiSavedPrompt(id: 'b', name: 'B', text: 'be concise'),
      ];
      final String raw = encodeAiSavedPrompts(prompts);
      final List<Object?> json = jsonDecode(raw) as List<Object?>;
      expect((json[1]! as Map<String, Object?>).containsKey('scene'), isFalse);
      expect(decodeAiSavedPrompts(raw), prompts);
    });

    test('内置预设永不落盘', () {
      final String raw = encodeAiSavedPrompts(<AiSavedPrompt>[
        ...aiBuiltinPrompts(AiPromptScene.theme),
        const AiSavedPrompt(id: 'u', name: 'U', text: 'x'),
      ]);
      expect(decodeAiSavedPrompts(raw).map((AiSavedPrompt p) => p.id), <String>[
        'u',
      ]);
    });

    test('逐条容错：坏条目 / 空正文 / 伪造内置 id / 重复 id 只丢那一条', () {
      final String raw = jsonEncode(<Object?>[
        <String, Object?>{'id': 'ok', 'name': 'Ok', 'text': 'keep'},
        'not a map',
        <String, Object?>{'id': 'empty', 'name': 'E', 'text': '   '},
        <String, Object?>{'id': 'builtin:theme:x', 'name': 'F', 'text': 'y'},
        <String, Object?>{'id': 'ok', 'name': 'Dup', 'text': 'dup'},
        <String, Object?>{'id': 'badscene', 'text': 't', 'scene': 3},
        <String, Object?>{'id': 'noname', 'text': 'first line\nsecond'},
      ]);
      final List<AiSavedPrompt> out = decodeAiSavedPrompts(raw);
      expect(out.map((AiSavedPrompt p) => p.id), <String>['ok', 'noname']);
      expect(out.first.name, 'Ok');
      expect(out.last.name, 'first line', reason: '缺名字时用正文首行');
    });

    test('空串 = 空列表；不是 JSON 列表抛 FormatException', () {
      expect(decodeAiSavedPrompts(''), isEmpty);
      expect(() => decodeAiSavedPrompts('{"a":1}'), throwsFormatException);
      expect(() => decodeAiSavedPrompts('not json'), throwsFormatException);
    });

    test('认不出的场景原样保留（新版本写的），只是不在任何已知场景显示', () {
      final String raw = jsonEncode(<Object?>[
        <String, Object?>{
          'id': 'f',
          'name': 'Future',
          'text': 'x',
          'scene': 'future_scene',
        },
      ]);
      final List<AiSavedPrompt> out = decodeAiSavedPrompts(raw);
      expect(out.single.sceneWire, 'future_scene');
      expect(out.single.scene, isNull);
      expect(out.single.isGeneral, isFalse);
      for (final AiPromptScene scene in AiPromptScene.values) {
        expect(aiSavedPromptsFor(out, scene), isEmpty);
      }
      expect(encodeAiSavedPrompts(out), contains('future_scene'));
    });
  });

  group('场景过滤与保存', () {
    test('本场景专属 + 通用条目可见，别的场景的不可见', () {
      const List<AiSavedPrompt> all = <AiSavedPrompt>[
        AiSavedPrompt(id: '1', name: '1', text: 'a', sceneWire: 'theme'),
        AiSavedPrompt(id: '2', name: '2', text: 'b', sceneWire: 'dict_style'),
        AiSavedPrompt(id: '3', name: '3', text: 'c'),
      ];
      expect(
        aiSavedPromptsFor(
          all,
          AiPromptScene.theme,
        ).map((AiSavedPrompt p) => p.id),
        <String>['1', '3'],
      );
      expect(
        aiSavedPromptsFor(
          all,
          AiPromptScene.srsField,
        ).map((AiSavedPrompt p) => p.id),
        <String>['3'],
      );
    });

    test('addAiSavedPrompt：新条目归当前场景；同正文不重复，只改名挪到末尾', () {
      List<AiSavedPrompt> all = addAiSavedPrompt(
        const <AiSavedPrompt>[],
        name: '  ',
        text: '  warm paper  ',
        scene: AiPromptScene.theme,
        id: 'x',
      );
      expect(all.single.text, 'warm paper');
      expect(all.single.name, 'warm paper', reason: '空名字用正文生成');
      expect(all.single.scene, AiPromptScene.theme);
      all = addAiSavedPrompt(
        <AiSavedPrompt>[
          ...all,
          const AiSavedPrompt(id: 'y', name: 'Y', text: 'other'),
        ],
        name: 'Paper',
        text: 'warm paper',
        scene: AiPromptScene.theme,
      );
      expect(all.map((AiSavedPrompt p) => p.id), <String>['y', 'x']);
      expect(all.last.name, 'Paper');
      // 别的场景的同正文条目不算重复。
      all = addAiSavedPrompt(
        all,
        name: 'D',
        text: 'warm paper',
        scene: AiPromptScene.dictStyle,
        id: 'z',
      );
      expect(all, hasLength(3));
    });

    test('withScope 切换通用 / 本场景', () {
      const AiSavedPrompt p = AiSavedPrompt(
        id: 'a',
        name: 'A',
        text: 't',
        sceneWire: 'theme',
      );
      final AiSavedPrompt general = p.withScope(
        general: true,
        scene: AiPromptScene.theme,
      );
      expect(general.isGeneral, isTrue);
      expect(general.visibleIn(AiPromptScene.srsField), isTrue);
      expect(
        general.withScope(general: false, scene: AiPromptScene.srsField).scene,
        AiPromptScene.srsField,
      );
    });

    test('每个场景都有 1–3 条内置预设，id 唯一且都是内置 id', () {
      final Set<String> ids = <String>{};
      for (final AiPromptScene scene in AiPromptScene.values) {
        final List<AiSavedPrompt> builtins = aiBuiltinPrompts(scene);
        expect(builtins.length, inInclusiveRange(1, 3), reason: scene.name);
        for (final AiSavedPrompt p in builtins) {
          expect(p.isBuiltin, isTrue);
          expect(p.scene, scene);
          expect(p.name.trim(), isNotEmpty);
          expect(p.text.trim(), isNotEmpty);
          expect(ids.add(p.id), isTrue, reason: 'duplicate ${p.id}');
        }
      }
    });

    test('场景落盘值冻结且唯一', () {
      expect(AiPromptScene.values.map((AiPromptScene s) => s.wire), <String>[
        'srs_field',
        'srs_template',
        'theme',
        'dict_style',
        'lapis_style',
        'gal_text_process',
      ]);
      for (final AiPromptScene s in AiPromptScene.values) {
        expect(AiPromptScene.fromWire(s.wire), s);
      }
      expect(AiPromptScene.fromWire('nope'), isNull);
    });
  });

  group('PreferencesRepository', () {
    late FushiDatabase db;
    late PreferencesRepository prefs;

    setUp(() async {
      db = FushiDatabase.forTesting(
        DatabaseConnection(NativeDatabase.memory()),
      );
      prefs = PreferencesRepository(db);
      await prefs.loadFromDb();
    });

    tearDown(() async {
      prefs.dispose();
      await db.close();
    });

    test('偏好键已登记；默认空列表；写入后读回一致', () async {
      expect(kKnownPreferenceKeys, contains(kAiSavedPromptsPrefKey));
      expect(prefs.aiSavedPrompts, isEmpty);
      const List<AiSavedPrompt> prompts = <AiSavedPrompt>[
        AiSavedPrompt(id: 'a', name: 'A', text: 'x', sceneWire: 'srs_field'),
        AiSavedPrompt(id: 'b', name: 'B', text: 'y'),
      ];
      await prefs.setAiSavedPrompts(prompts);
      expect(prefs.aiSavedPrompts, prompts);
      expect(
        prefs.getPref(kAiSavedPromptsPrefKey, defaultValue: ''),
        encodeAiSavedPrompts(prompts),
      );
    });

    test('整串损坏时当空列表，不抛', () async {
      await prefs.setPref(kAiSavedPromptsPrefKey, '{broken');
      expect(prefs.aiSavedPrompts, isEmpty);
    });
  });
}
