import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 反馈 JAEwvc6Lmr：离线已制卡缓存依赖的后端契约。
///
/// * [BaseAnkiRepository.probeDuplicate] 必须分清「Anki 说没有」（`false`）和
///   「没问到」（`null`）——此前两者都折成 `isDuplicate == false`，上层无从退回缓存。
/// * [BaseAnkiRepository.isDuplicate] 的 fail-soft 口径不变（没问到仍是 `false`）。
/// * 作用域键带上决定查重结果的全部设置；整份列出走与查重同一组参数。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const AnkiNoteType noteType = AnkiNoteType(
    id: 2,
    name: 'Fushi',
    fields: <String>['Expression', 'Reading'],
  );
  const AnkiSettings settings = AnkiSettings(
    selectedDeckId: 1,
    selectedNoteTypeId: 2,
    availableDecks: <AnkiDeck>[AnkiDeck(id: 1, name: 'Mining')],
    availableNoteTypes: <AnkiNoteType>[noteType],
    fieldMappings: <String, String>{
      'Expression': '{expression}',
      'Reading': '{reading}',
    },
  );

  group('AnkiDroid', () {
    const MethodChannel channel = MethodChannel('app.fushi.reader/anki');

    void mockChannel(Future<Object?> Function(MethodCall call) handler) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, handler);
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });
    }

    test('provider 出错 → probe 回 null（没问到），isDuplicate 仍是 false', () async {
      mockChannel((MethodCall call) async {
        if (call.method == 'checkForDuplicates') {
          throw PlatformException(
            code: 'DUPE_CHECK_FAILED',
            message: 'collection is not available',
          );
        }
        fail('unexpected channel call: ${call.method}');
      });
      final _DroidRepo repo = _DroidRepo(settings);
      expect(await repo.probeDuplicate('食べる', 'たべる'), isNull);
      expect(await repo.isDuplicate('食べる', 'たべる'), isFalse);
    });

    test('未授权（native 报 PERMISSION_DENIED）同样是「没问到」', () async {
      mockChannel((MethodCall call) async {
        throw PlatformException(code: 'PERMISSION_DENIED');
      });
      expect(await _DroidRepo(settings).probeDuplicate('食べる', ''), isNull);
    });

    test('provider 应答 → probe 原样给出 true / false', () async {
      bool answer = true;
      mockChannel((MethodCall call) async => answer);
      final _DroidRepo repo = _DroidRepo(settings);
      expect(await repo.probeDuplicate('食べる', 'たべる'), isTrue);
      answer = false;
      expect(await repo.probeDuplicate('食べる', 'たべる'), isFalse);
    });

    test('作用域只有笔记类型（AnkiDroid 判重没有卡组维度）', () async {
      expect(
        await _DroidRepo(settings).minedCacheScope(),
        'ankidroid|model:Fushi',
      );
      expect(await _DroidRepo(const AnkiSettings()).minedCacheScope(), isNull);
    });

    test('listFirstFields：按当前笔记类型请求，null 结果当失败抛出', () async {
      final List<MethodCall> calls = <MethodCall>[];
      List<Object?>? reply = <Object?>['食べる', '<b>飲む</b>', 3];
      mockChannel((MethodCall call) async {
        calls.add(call);
        return reply;
      });
      final _DroidRepo repo = _DroidRepo(settings);
      expect(await repo.listMinedFirstFields(), <String>['食べる', '<b>飲む</b>']);
      expect(calls.single.method, 'listFirstFields');
      expect(calls.single.arguments, <String, dynamic>{'model': 'Fushi'});

      reply = null;
      await expectLater(repo.listMinedFirstFields(), throwsStateError);
    });
  });

  group('AnkiConnect', () {
    setUp(AnkiConnectRepository.resetDuplicateCheckCooldown);
    tearDown(AnkiConnectRepository.resetDuplicateCheckCooldown);

    test('传输层失败与冷却窗内 → probe 回 null，isDuplicate 仍是 false', () async {
      int calls = 0;
      final _ConnectRepo repo = _ConnectRepo(
        settings,
        MockClient((http.Request request) async {
          calls++;
          throw const SocketException('Connection refused');
        }),
      );
      expect(await repo.probeDuplicate('食べる', ''), isNull);
      expect(AnkiConnectRepository.isDuplicateCheckInCooldown, isTrue);
      final int afterFirst = calls;
      // 冷却窗内：不触网，仍回「没问到」而不是「没有」。
      expect(await repo.probeDuplicate('飲む', ''), isNull);
      expect(calls, afterFirst);
      expect(await repo.isDuplicate('飲む', ''), isFalse);
    });

    test('主机应答 → probe 给出结论', () async {
      final _ConnectRepo repo = _ConnectRepo(
        settings,
        MockClient((http.Request request) async {
          return http.Response(
            jsonEncode(<String, Object?>{
              'result': <Object?>[
                <String, Object?>{
                  'canAdd': false,
                  'error': kAnkiConnectDuplicateError,
                },
              ],
              'error': null,
            }),
            200,
          );
        }),
      );
      expect(await repo.probeDuplicate('食べる', ''), isTrue);
    });

    test('作用域带连接目标、笔记类型与查重卡组过滤', () async {
      expect(
        await _ConnectRepo(
          settings,
          MockClient(_unreachable),
        ).minedCacheScope(),
        'ankiconnect|http://localhost:8765|model:Fushi|deck:"Mining"',
      );
      expect(
        await _ConnectRepo(
          settings.copyWith(
            duplicateScope: AnkiDuplicateScope.collection,
            ankiConnectHost: '192.168.1.5',
          ),
          MockClient(_unreachable),
        ).minedCacheScope(),
        'ankiconnect|http://192.168.1.5:8765|model:Fushi|',
      );
      expect(
        await _ConnectRepo(
          const AnkiSettings(),
          MockClient(_unreachable),
        ).minedCacheScope(),
        isNull,
      );
    });

    test('整份列出：findNotes 用查重同一组参数，notesInfo 分批取第一字段', () async {
      final List<int> ids = List<int>.generate(
        kAnkiMinedFirstFieldsBatchSize + 5,
        (int i) => 1000 + i,
      );
      final List<String> queries = <String>[];
      final List<int> batchSizes = <int>[];
      final _ConnectRepo repo = _ConnectRepo(
        settings,
        MockClient((http.Request request) async {
          final Map<String, dynamic> body =
              jsonDecode(request.body) as Map<String, dynamic>;
          final Map<String, dynamic> params =
              (body['params'] as Map<String, dynamic>?) ?? <String, dynamic>{};
          switch (body['action']) {
            case 'findNotes':
              queries.add(params['query'] as String);
              return http.Response(
                jsonEncode(<String, Object?>{'result': ids, 'error': null}),
                200,
              );
            case 'notesInfo':
              final List<dynamic> notes = params['notes'] as List<dynamic>;
              batchSizes.add(notes.length);
              return http.Response(
                jsonEncode(<String, Object?>{
                  'result': <Object?>[
                    for (final dynamic id in notes)
                      <String, Object?>{
                        'noteId': id,
                        'fields': <String, Object?>{
                          'Expression': <String, Object?>{
                            'value': 'w$id',
                            'order': 0,
                          },
                          'Reading': <String, Object?>{
                            'value': 'r$id',
                            'order': 1,
                          },
                        },
                      },
                  ],
                  'error': null,
                }),
                200,
              );
          }
          fail('unexpected action ${body['action']}');
        }),
      );
      final List<String>? fields = await repo.listMinedFirstFields();
      expect(queries, <String>['deck:"Mining" note:"Fushi"']);
      expect(batchSizes, <int>[kAnkiMinedFirstFieldsBatchSize, 5]);
      expect(fields, <String>[for (final int id in ids) 'w$id']);
    });

    test('整份列出失败照抛，不返回空列表', () async {
      final _ConnectRepo repo = _ConnectRepo(
        settings,
        MockClient(_unreachable),
      );
      await expectLater(repo.listMinedFirstFields(), throwsA(anything));
    });
  });

  test('搜索式：collection 范围不带卡组过滤，引号被转义', () {
    expect(
      ankiMinedFirstFieldsQuery(
        modelName: 'My "Vocab"',
        deckName: 'Mining',
        scope: AnkiDuplicateScope.collection,
      ),
      r'note:"My \"Vocab\""',
    );
    expect(
      ankiMinedFirstFieldsQuery(
        modelName: 'Vocab',
        deckName: 'Japanese::Mining',
        scope: AnkiDuplicateScope.deckRoot,
      ),
      'deck:"Japanese" note:"Vocab"',
    );
  });
}

Future<http.Response> _unreachable(http.Request request) async =>
    throw const SocketException('Connection refused');

class _DroidRepo extends AnkiRepository {
  _DroidRepo(this.settings);

  final AnkiSettings settings;

  @override
  Future<AnkiSettings> loadSettings() async => settings;
}

class _ConnectRepo extends AnkiConnectRepository {
  _ConnectRepo(this.settings, http.Client client)
    : super(service: AnkiConnectService(client: client));

  final AnkiSettings settings;

  @override
  Future<AnkiSettings> loadSettings() async => settings;
}
