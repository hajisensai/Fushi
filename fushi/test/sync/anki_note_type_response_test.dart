// 互联 Lapis 客制化：`/api/anki/note-type/*` 三个端点的共享 handler 契约。
// 手机端（AnkiDroid / AnkiMobile 无改已存在模板的平台 API）经互联读写主机端
// Anki 的 note type，可视化配置 Lapis 因此第一次在手机上可用。
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/sync/forwarded_mine_payload.dart';
import 'package:fushi/src/sync/fushi_remote_api_handlers.dart';
import 'package:fushi/src/sync/fushi_remote_lookup_service.dart';
import 'package:fushi/src/sync/immersion_mine_payload.dart';
import 'package:fushi_anki/fushi_anki.dart';

class _FakeMining implements FushiRemoteMiningService {
  AnkiNoteTypeDefinition? noteTypeDef;
  bool writeOk = true;
  final List<String> reads = <String>[];
  final List<(String, String)> stylingWrites = <(String, String)>[];
  final List<(String, List<AnkiCardTemplate>)> templateWrites =
      <(String, List<AnkiCardTemplate>)>[];

  @override
  Future<AnkiNoteTypeDefinition?> readNoteTypeDefinition(
      String modelName) async {
    reads.add(modelName);
    return noteTypeDef;
  }

  @override
  Future<bool> updateNoteTypeStyling(String modelName, String css) async {
    stylingWrites.add((modelName, css));
    return writeOk;
  }

  @override
  Future<bool> updateNoteTypeTemplates(
      String modelName, List<AnkiCardTemplate> templates) async {
    templateWrites.add((modelName, templates));
    return writeOk;
  }

  @override
  Future<bool> probeMediaMaintenance() async => false;

  @override
  Future<AnkiMediaDedupReport?> runMediaDedup({bool dryRun = true}) async =>
      null;

  @override
  Future<RemoteMineResult> mineEntry(
          {required Map<String, String> fields,
          required String sentence}) async =>
      const RemoteMineResult(result: 'success');

  @override
  Future<RemoteMineResult> mineImmersion(ImmersionMinePayload payload) async =>
      const RemoteMineResult(result: 'success');

  @override
  Future<RemoteMineResult> mineForwarded(ForwardedMinePayload payload) async =>
      const RemoteMineResult(result: 'success');

  @override
  Future<bool> isDuplicate(
          {required String expression, required String reading}) async =>
      false;
}

void main() {
  group('buildAnkiNoteTypeReadResponse', () {
    test('回传完整定义 JSON（wire 形状与 AnkiNoteTypeDefinition.toJson 一致）', () async {
      final _FakeMining m = _FakeMining()
        ..noteTypeDef = const AnkiNoteTypeDefinition(
          name: 'Lapis',
          fields: <String>['Expression', 'Sentence'],
          templates: <AnkiCardTemplate>[
            AnkiCardTemplate(name: 'Card', front: 'F', back: 'B'),
          ],
          css: '.card { color: red; }',
        );
      final Map<String, dynamic> resp = await buildAnkiNoteTypeReadResponse(
        <String, dynamic>{'modelName': 'Lapis'},
        mining: m,
      );
      expect(m.reads.single, 'Lapis');
      final Map<String, dynamic> noteType =
          resp['noteType'] as Map<String, dynamic>;
      // 回传体必须能被客户端 AnkiNoteTypeDefinition.fromJson 原样读回。
      final AnkiNoteTypeDefinition roundTrip =
          AnkiNoteTypeDefinition.fromJson(noteType);
      expect(roundTrip.name, 'Lapis');
      expect(roundTrip.fields, <String>['Expression', 'Sentence']);
      expect(roundTrip.templates.single.back, 'B');
      expect(roundTrip.css, '.card { color: red; }');
    });

    test('模型不存在/后端不支持 → noteType 为 null（不是错误）', () async {
      final Map<String, dynamic> resp = await buildAnkiNoteTypeReadResponse(
        <String, dynamic>{'modelName': 'Lapis'},
        mining: _FakeMining(),
      );
      expect(resp.containsKey('noteType'), isTrue);
      expect(resp['noteType'], isNull);
    });

    test('modelName 缺失 → FormatException（调用方转 400）', () {
      expect(
        () => buildAnkiNoteTypeReadResponse(<String, dynamic>{},
            mining: _FakeMining()),
        throwsFormatException,
      );
    });
  });

  group('buildAnkiNoteTypeStylingResponse', () {
    test('写穿 + 回 ok', () async {
      final _FakeMining m = _FakeMining();
      final Map<String, dynamic> resp = await buildAnkiNoteTypeStylingResponse(
        <String, dynamic>{'modelName': 'Lapis', 'css': '.card {}'},
        mining: m,
      );
      expect(resp['ok'], isTrue);
      expect(m.stylingWrites.single, ('Lapis', '.card {}'));
    });

    test('空串 css 合法（清空 styling 是有效操作）', () async {
      final _FakeMining m = _FakeMining();
      final Map<String, dynamic> resp = await buildAnkiNoteTypeStylingResponse(
        <String, dynamic>{'modelName': 'Lapis', 'css': ''},
        mining: m,
      );
      expect(resp['ok'], isTrue);
      expect(m.stylingWrites.single, ('Lapis', ''));
    });

    test('css 缺失 → FormatException；后端不支持 → ok=false', () async {
      expect(
        () => buildAnkiNoteTypeStylingResponse(
            <String, dynamic>{'modelName': 'Lapis'},
            mining: _FakeMining()),
        throwsFormatException,
      );
      final Map<String, dynamic> resp = await buildAnkiNoteTypeStylingResponse(
        <String, dynamic>{'modelName': 'Lapis', 'css': 'x'},
        mining: _FakeMining()..writeOk = false,
      );
      expect(resp['ok'], isFalse);
    });
  });

  group('buildAnkiNoteTypeTemplatesResponse', () {
    test('解析 templates 列表并写穿', () async {
      final _FakeMining m = _FakeMining();
      final Map<String, dynamic> resp =
          await buildAnkiNoteTypeTemplatesResponse(
        <String, dynamic>{
          'modelName': 'Lapis',
          'templates': <dynamic>[
            <String, dynamic>{'name': 'Card', 'front': 'F', 'back': 'B2'},
          ],
        },
        mining: m,
      );
      expect(resp['ok'], isTrue);
      expect(m.templateWrites.single.$1, 'Lapis');
      expect(m.templateWrites.single.$2.single.name, 'Card');
      expect(m.templateWrites.single.$2.single.back, 'B2');
    });

    test('templates 缺失/元素类型错 → FormatException', () {
      expect(
        () => buildAnkiNoteTypeTemplatesResponse(
            <String, dynamic>{'modelName': 'Lapis'},
            mining: _FakeMining()),
        throwsFormatException,
      );
      expect(
        () => buildAnkiNoteTypeTemplatesResponse(
          <String, dynamic>{
            'modelName': 'Lapis',
            'templates': <dynamic>['not a map'],
          },
          mining: _FakeMining(),
        ),
        throwsFormatException,
      );
    });
  });
}
