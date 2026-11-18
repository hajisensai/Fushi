import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// 落卡前的同步片段探测（[BaseAnkiRepository.rendersSynchronizedClip]）每张卡都要读一遍
// 目标笔记类型的定义。AnkiConnect 的 HTTP 服务按 25 ms 轮询，逐条读是四次往返；
// 这里钉住「一次 `multi` 往返读齐」，以及与逐条读相同的结果口径。

class _Repo extends AnkiConnectRepository {
  _Repo({required AnkiConnectService service}) : super(service: service);

  @override
  Future<AnkiSettings> loadSettings() async => const AnkiSettings(
    selectedDeckId: 1,
    selectedNoteTypeId: 2,
    availableDecks: <AnkiDeck>[AnkiDeck(id: 1, name: 'Mining')],
    availableNoteTypes: <AnkiNoteType>[
      AnkiNoteType(
        id: 2,
        name: 'Lapis',
        fields: <String>['Expression', 'Picture'],
      ),
    ],
    fieldMappings: <String, String>{
      'Expression': '{expression}',
      'Picture': '{card-image}',
    },
  );
}

void main() {
  /// 按子 action 名应答的假 AnkiConnect；[replies] 里的值是 `{result, error}` 信封。
  AnkiConnectService serviceWith(
    Map<String, Map<String, Object?>> replies,
    List<Map<String, dynamic>> sink,
  ) {
    final MockClient client = MockClient((http.Request request) async {
      final Map<String, dynamic> body =
          jsonDecode(request.body) as Map<String, dynamic>;
      sink.add(body);
      final Object? result;
      if (body['action'] == 'multi') {
        result = <Object?>[
          for (final Object? sub
              in (body['params'] as Map<String, dynamic>)['actions']
                  as List<dynamic>)
            replies[(sub! as Map<String, dynamic>)['action']] ??
                <String, Object?>{'result': null, 'error': 'unsupported'},
        ];
      } else {
        result = replies[body['action']]?['result'];
      }
      return http.Response(
        jsonEncode(<String, Object?>{'result': result, 'error': null}),
        200,
        headers: <String, String>{
          'content-type': 'application/json; charset=utf-8',
        },
      );
    });
    return AnkiConnectService(host: '127.0.0.1', port: 8765, client: client);
  }

  Map<String, Object?> ok(Object? result) => <String, Object?>{
    'result': result,
    'error': null,
  };

  final Map<String, Map<String, Object?>> lapis =
      <String, Map<String, Object?>>{
        'modelNames': ok(<String>['Basic', 'Lapis']),
        'modelFieldNames': ok(<String>['Expression', 'Picture']),
        'modelTemplates': ok(<String, Object?>{
          'Mining': <String, String>{
            'Front': '{{Expression}}',
            'Back': '<div class="image">{{Picture}}</div>',
          },
        }),
        'modelStyling': ok(<String, String>{'css': '.card{}'}),
      };

  test('readNoteTypeDefinition：一次 multi 往返读齐字段 / 卡模板 / CSS', () async {
    final List<Map<String, dynamic>> requests = <Map<String, dynamic>>[];
    final AnkiNoteTypeDefinition? definition = await _Repo(
      service: serviceWith(lapis, requests),
    ).readNoteTypeDefinition('Lapis');

    expect(requests, hasLength(1), reason: '四条只读 action 必须打进一次往返');
    expect(requests.single['action'], 'multi');
    final List<dynamic> actions =
        (requests.single['params'] as Map<String, dynamic>)['actions']
            as List<dynamic>;
    expect(
      actions.map((dynamic a) => (a as Map<String, dynamic>)['action']),
      <String>[
        'modelNames',
        'modelFieldNames',
        'modelTemplates',
        'modelStyling',
      ],
    );
    expect(definition!.name, 'Lapis');
    expect(definition.fields, <String>['Expression', 'Picture']);
    expect(definition.templates.single.name, 'Mining');
    expect(definition.templates.single.front, '{{Expression}}');
    expect(
      definition.templates.single.back,
      '<div class="image">{{Picture}}</div>',
    );
    expect(definition.css, '.card{}');
  });

  test('rendersSynchronizedClip：落卡前的探测只花一次往返', () async {
    final List<Map<String, dynamic>> requests = <Map<String, dynamic>>[];
    final bool? renders = await _Repo(
      service: serviceWith(lapis, requests),
    ).rendersSynchronizedClip();
    expect(renders, isTrue);
    expect(requests, hasLength(1));
  });

  test('模型不存在：返回 null，不因后三条子 action 报错而抛', () async {
    final List<Map<String, dynamic>> requests = <Map<String, dynamic>>[];
    const Map<String, Object?> missing = <String, Object?>{
      'result': null,
      'error': 'model was not found: Gone',
    };
    final AnkiNoteTypeDefinition? definition = await _Repo(
      service: serviceWith(<String, Map<String, Object?>>{
        'modelNames': ok(<String>['Basic']),
        'modelFieldNames': missing,
        'modelTemplates': missing,
        'modelStyling': missing,
      }, requests),
    ).readNoteTypeDefinition('Gone');
    expect(definition, isNull);
    expect(requests, hasLength(1));
  });

  test('模型存在而某条读取失败：按那一条的错误抛，不拼出半截定义', () async {
    final List<Map<String, dynamic>> requests = <Map<String, dynamic>>[];
    await expectLater(
      _Repo(
        service: serviceWith(<String, Map<String, Object?>>{
          ...lapis,
          'modelTemplates': <String, Object?>{
            'result': null,
            'error': 'collection is not available',
          },
        }, requests),
      ).readNoteTypeDefinition('Lapis'),
      throwsA(
        isA<AnkiConnectException>().having(
          (AnkiConnectException e) => e.message,
          'message',
          'collection is not available',
        ),
      ),
    );
  });
}
