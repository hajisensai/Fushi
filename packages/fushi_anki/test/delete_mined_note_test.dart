import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 反馈 JNyykxvuY9「撤回制卡」：两个 Anki 后端都能按 note id 删卡。
///   * AnkiConnect：先 `notesInfo` 确认还在（`deleteNotes` 不回原本在不在），再
///     `deleteNotes`；已不在报 false，不发删除；出错照抛（不能把「问不到」当成删了）。
///   * AnkiDroid：原生 `deleteNote`（CardContentProvider delete notes/<id>）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AnkiConnect', () {
    AnkiConnectRepository repoWith(
      List<String> actions, {
      bool exists = true,
      bool fail = false,
    }) {
      final MockClient client = MockClient((http.Request request) async {
        final Map<String, dynamic> body =
            jsonDecode(request.body) as Map<String, dynamic>;
        final String action = body['action'] as String;
        actions.add(action);
        if (fail) {
          return http.Response(
            jsonEncode(<String, Object?>{'result': null, 'error': 'boom'}),
            200,
          );
        }
        final Object? result = switch (action) {
          'notesInfo' =>
            exists
                ? <Object?>[
                    <String, Object?>{
                      'noteId': 7,
                      'modelName': 'Lapis',
                      'fields': <String, Object?>{
                        'Expression': <String, Object?>{
                          'value': '雪',
                          'order': 0,
                        },
                      },
                    },
                  ]
                : <Object?>[<String, Object?>{}],
          _ => null,
        };
        return http.Response(
          jsonEncode(<String, Object?>{'result': result, 'error': null}),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      return _ConnectRepo(
        service: AnkiConnectService(
          host: '127.0.0.1',
          port: 8765,
          client: client,
        ),
      );
    }

    test('还在 → deleteNotes，返回 true', () async {
      final List<String> actions = <String>[];
      final AnkiConnectRepository repo = repoWith(actions);
      expect(repo.canDeleteMinedNotes, isTrue);
      expect(await repo.deleteMinedNote(7), isTrue);
      expect(actions, <String>['notesInfo', 'deleteNotes']);
    });

    test('已不在 → false，不发删除', () async {
      final List<String> actions = <String>[];
      expect(
        await repoWith(actions, exists: false).deleteMinedNote(7),
        isFalse,
      );
      expect(actions, <String>['notesInfo']);
    });

    test('后端报错 → 抛，不当成删了', () async {
      await expectLater(
        repoWith(<String>[], fail: true).deleteMinedNote(7),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('AnkiDroid', () {
    const MethodChannel channel = MethodChannel('app.fushi.reader/anki');

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('走原生 deleteNote，按原生回答报删没删', () async {
      final List<MethodCall> calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
            calls.add(call);
            return (call.arguments as Map)['noteId'] == 1654000000123;
          });
      final AnkiRepository repo = AnkiRepository();
      expect(repo.canDeleteMinedNotes, isTrue);
      expect(await repo.deleteMinedNote(1654000000123), isTrue);
      expect(await repo.deleteMinedNote(5), isFalse);
      expect(calls.map((MethodCall c) => c.method), <String>[
        'deleteNote',
        'deleteNote',
      ]);
    });

    test('原生报错（没权限等）→ 抛', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
            throw PlatformException(code: 'PERMISSION_DENIED');
          });
      await expectLater(
        AnkiRepository().deleteMinedNote(1),
        throwsA(isA<PlatformException>()),
      );
    });
  });

  test('基类默认删不了：canDeleteMinedNotes=false，调用即抛 UnsupportedError', () async {
    final _Plain repo = _Plain();
    expect(repo.canDeleteMinedNotes, isFalse);
    await expectLater(
      repo.deleteMinedNote(1),
      throwsA(isA<UnsupportedError>()),
    );
  });
}

class _ConnectRepo extends AnkiConnectRepository {
  _ConnectRepo({required AnkiConnectService service})
    : super(service: service);

  @override
  Future<AnkiSettings> loadSettings() async => const AnkiSettings();
}

class _Plain extends BaseAnkiRepository {
  @override
  Future<AnkiFetchResult> fetchConfiguration() async =>
      const AnkiFetchResult.error('unused');
  @override
  Future<MineOutcome> mineEntry({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async => const MineOutcome.success();
  @override
  Future<bool> isDuplicate(String expression, String reading) async => false;
  @override
  Future<bool> createNoteType(AnkiNoteTypeTemplate template) async => false;
  @override
  Future<bool> createDeck(String name) async => false;
}
