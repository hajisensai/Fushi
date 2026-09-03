/// BUG-1680：AnkiDroid 后端的 note type 模板读写（Lapis 样式客制化）。
///
/// 长期以来 Android 上整个 Lapis 样式区是隐藏的，依据是「AnkiDroid Content
/// Provider 改不了已存在的 note type」。那个前提是错的：AnkiDroid 的
/// CardContentProvider.update() 的 `models/<mid>` 分支支持写 `Model.CSS`，
/// `models/<mid>/templates/<ord>` 分支支持写 QUESTION_FORMAT / ANSWER_FORMAT；
/// 被拒绝的只有改字段名，而样式客制化一个字段名都不改。
///
/// 这里同时守两层：Dart 侧经 MethodChannel 的读写契约（行为测试），以及 Java
/// 桥确实实现了那三个方法、且用的是 provider 真正认的那几个列（源码扫描——
/// 本仓没有跑 JVM 的测试宿主，这是 Java 侧最强的可落地层）。
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki.dart';

const MethodChannel _channel = MethodChannel('app.fushi.reader/anki');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<MethodCall> calls;
  late Map<String, Object?> responses;

  setUp(() {
    calls = <MethodCall>[];
    responses = <String, Object?>{};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (MethodCall call) async {
      calls.add(call);
      return responses[call.method];
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  group('AnkiRepository note type 模板读写', () {
    test('声明支持编辑已存在 note type（Lapis 样式区据此显示）', () {
      expect(AnkiRepository().supportsNoteTypeEditing, isTrue);
    });

    test('readNoteTypeDefinition 解析字段/模板/CSS', () async {
      responses['readNoteType'] = <Object?, Object?>{
        'name': 'Lapis',
        'fields': <Object?>['Word', 'Sentence'],
        'css': '.card { color: red; }',
        'templates': <Object?>[
          <Object?, Object?>{
            'ord': 0,
            'name': 'Card 1',
            'front': '{{Word}}',
            'back': '{{Sentence}}',
          },
        ],
      };

      final AnkiNoteTypeDefinition? def =
          await AnkiRepository().readNoteTypeDefinition('Lapis');

      expect(def, isNotNull);
      expect(def!.name, 'Lapis');
      expect(def.fields, <String>['Word', 'Sentence']);
      expect(def.css, '.card { color: red; }');
      expect(def.templates, hasLength(1));
      expect(def.templates.single.name, 'Card 1');
      expect(def.templates.single.front, '{{Word}}');
      expect(def.templates.single.back, '{{Sentence}}');
      expect(
        calls.map((MethodCall c) => c.method),
        containsAllInOrder(
            <String>['requestAnkidroidPermissions', 'readNoteType']),
      );
      expect(
        calls.last.arguments,
        containsPair('noteTypeName', 'Lapis'),
      );
    });

    test('readNoteTypeDefinition：note type 不存在返回 null（不是错误）', () async {
      responses['readNoteType'] = null;
      expect(await AnkiRepository().readNoteTypeDefinition('Lapis'), isNull);
    });

    test('updateNoteTypeStyling 把 CSS 发过去并透传结果', () async {
      responses['updateNoteTypeStyling'] = true;
      final bool ok =
          await AnkiRepository().updateNoteTypeStyling('Lapis', 'body{}');
      expect(ok, isTrue);
      final MethodCall call = calls
          .firstWhere((MethodCall c) => c.method == 'updateNoteTypeStyling');
      expect(call.arguments, containsPair('noteTypeName', 'Lapis'));
      expect(call.arguments, containsPair('css', 'body{}'));
    });

    test('updateNoteTypeStyling：桥返回 false（provider 没认下改动）不谎报成功', () async {
      responses['updateNoteTypeStyling'] = false;
      expect(
        await AnkiRepository().updateNoteTypeStyling('Lapis', 'body{}'),
        isFalse,
      );
    });

    test('updateNoteTypeTemplates 按模板名发送正/反面', () async {
      responses['updateNoteTypeTemplates'] = true;
      final bool ok = await AnkiRepository().updateNoteTypeTemplates(
        'Lapis',
        const <AnkiCardTemplate>[
          AnkiCardTemplate(name: 'Card 1', front: 'F', back: 'B'),
        ],
      );
      expect(ok, isTrue);
      final MethodCall call = calls
          .firstWhere((MethodCall c) => c.method == 'updateNoteTypeTemplates');
      final List<Object?> sent =
          (call.arguments as Map)['templates'] as List<Object?>;
      expect(sent, hasLength(1));
      expect(sent.single, <String, String>{
        'name': 'Card 1',
        'front': 'F',
        'back': 'B',
      });
    });

    test('updateNoteTypeTemplates：空列表不打桥（没有可写的东西）', () async {
      expect(
        await AnkiRepository().updateNoteTypeTemplates(
          'Lapis',
          const <AnkiCardTemplate>[],
        ),
        isFalse,
      );
      expect(calls, isEmpty);
    });
  });

  group('Java 桥实现（源码扫描守卫）', () {
    late String java;

    setUpAll(() {
      java = File(
        'android/app/src/main/java/app/fushi/reader/AnkiChannelHandler.java',
      ).readAsStringSync();
    });

    test('三个 method 都有 case 分支', () {
      expect(java, contains('case "readNoteType":'));
      expect(java, contains('case "updateNoteTypeStyling":'));
      expect(java, contains('case "updateNoteTypeTemplates":'));
    });

    test('写入用的是 provider 真正认的那几个列', () {
      // provider 的 models/<mid> 分支只认 Model.CSS 这一个与样式有关的键；
      // templates/<ord> 分支认 QUESTION_FORMAT / ANSWER_FORMAT。换成别的列名
      // 会被静默忽略（update 返回 0），表现成「点了应用样式什么都没变」。
      expect(java, contains('FlashCardsContract.Model.CSS'));
      expect(java, contains('FlashCardsContract.CardTemplate.QUESTION_FORMAT'));
      expect(java, contains('FlashCardsContract.CardTemplate.ANSWER_FORMAT'));
    });

    test('不把字段名塞进 ContentValues（provider 明确拒绝，整次 update 会抛）', () {
      // provider: "Field names cannot be changed via provider"。读 FIELD_NAMES
      // 是合法的（readNoteType 就在读），写不是——判据只能是「有没有 put 进
      // ContentValues」，不能是「文件里出没出现过这个常量」。
      expect(
          java, isNot(contains('.put(FlashCardsContract.Model.FIELD_NAMES')));
    });
  });
}
