import 'dart:convert';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/fushi_remote_mining_client.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 互联 Lapis 客制化：`FushiRemoteMiningClient` 的 note type 读写语义。
/// 关键区分（可视化配置是显式用户操作，错误必须各归各位）：
/// - 旧版主机（404，无 `/api/anki/note-type/*` 端点）→ 读 null / 写 false，
///   按「后端不支持」降级，不报错；
/// - 主机全部不可达（传输层失败）→ 抛 [StateError]，绝不压成 null 被 UI
///   误报成「Lapis 卡型不存在」；
/// - token 被拒（401）→ 抛 [SyncAuthError]，用户须重新配对。
FushiDatabase _testDb() {
  return FushiDatabase.forTesting(
    DatabaseConnection(NativeDatabase.memory()),
  );
}

Future<SyncRepository> _repo(FushiDatabase db) async {
  final SyncRepository repo = SyncRepository(db);
  await repo.setFushiClientUrls(
      const <FushiClientUrl>[FushiClientUrl(url: 'http://host:8765')]);
  await repo.setFushiClientToken('tok');
  return repo;
}

Future<FushiRemoteMiningClient> _client(
  FushiDatabase db,
  http.Response Function(http.Request request) respond,
) async {
  return FushiRemoteMiningClient(
    repo: await _repo(db),
    httpClient: MockClient((http.Request request) async => respond(request)),
  );
}

http.Response _json(Map<String, dynamic> body) => http.Response.bytes(
      utf8.encode(jsonEncode(body)),
      200,
      headers: const <String, String>{
        'content-type': 'application/json; charset=utf-8',
      },
    );

void main() {
  test('read：主机回传定义 → 反序列化成 AnkiNoteTypeDefinition', () async {
    final FushiDatabase db = _testDb();
    addTearDown(db.close);
    http.Request? seen;
    final FushiRemoteMiningClient client = await _client(db, (http.Request r) {
      seen = r;
      return _json(<String, dynamic>{
        'noteType': const AnkiNoteTypeDefinition(
          name: 'Lapis',
          fields: <String>['Expression'],
          templates: <AnkiCardTemplate>[
            AnkiCardTemplate(name: 'Card', front: 'F', back: 'B'),
          ],
          css: '.card {}',
        ).toJson(),
      });
    });
    final AnkiNoteTypeDefinition? def =
        await client.readNoteTypeDefinition('Lapis');
    expect(seen!.url.path, '/api/anki/note-type/read');
    expect(jsonDecode(seen!.body), <String, dynamic>{'modelName': 'Lapis'});
    expect(def?.name, 'Lapis');
    expect(def?.templates.single.back, 'B');
  });

  test('read：主机可达但无该模型（noteType null）→ null', () async {
    final FushiDatabase db = _testDb();
    addTearDown(db.close);
    final FushiRemoteMiningClient client = await _client(
        db, (http.Request _) => _json(<String, dynamic>{'noteType': null}));
    expect(await client.readNoteTypeDefinition('Lapis'), isNull);
  });

  test('read：旧版主机（404，无端点）→ null（按后端不支持降级）', () async {
    final FushiDatabase db = _testDb();
    addTearDown(db.close);
    final FushiRemoteMiningClient client =
        await _client(db, (http.Request _) => http.Response('nope', 404));
    expect(await client.readNoteTypeDefinition('Lapis'), isNull);
  });

  test('read：主机全部不可达 → 抛 StateError（不冒充「模型不存在」）', () async {
    final FushiDatabase db = _testDb();
    addTearDown(db.close);
    final FushiRemoteMiningClient client = FushiRemoteMiningClient(
      repo: await _repo(db),
      httpClient: MockClient(
          (http.Request _) async => throw http.ClientException('boom')),
    );
    expect(
      () => client.readNoteTypeDefinition('Lapis'),
      throwsA(isA<StateError>()),
    );
  });

  test('read：token 被拒（401）→ 抛 SyncAuthError', () async {
    final FushiDatabase db = _testDb();
    addTearDown(db.close);
    final FushiRemoteMiningClient client =
        await _client(db, (http.Request _) => http.Response('nope', 401));
    expect(
      () => client.readNoteTypeDefinition('Lapis'),
      throwsA(isA<SyncAuthError>()),
    );
  });

  test('styling：写穿 ok=true；旧版主机 404 → false', () async {
    final FushiDatabase db = _testDb();
    addTearDown(db.close);
    http.Request? seen;
    final FushiRemoteMiningClient okClient =
        await _client(db, (http.Request r) {
      seen = r;
      return _json(<String, dynamic>{'ok': true});
    });
    expect(await okClient.updateNoteTypeStyling('Lapis', '.card {}'), isTrue);
    expect(seen!.url.path, '/api/anki/note-type/styling');
    expect(jsonDecode(seen!.body),
        <String, dynamic>{'modelName': 'Lapis', 'css': '.card {}'});

    final FushiRemoteMiningClient oldHost =
        await _client(db, (http.Request _) => http.Response('nope', 404));
    expect(await oldHost.updateNoteTypeStyling('Lapis', '.card {}'), isFalse);
  });

  test('templates：模板列表序列化进请求体', () async {
    final FushiDatabase db = _testDb();
    addTearDown(db.close);
    http.Request? seen;
    final FushiRemoteMiningClient client = await _client(db, (http.Request r) {
      seen = r;
      return _json(<String, dynamic>{'ok': true});
    });
    expect(
      await client.updateNoteTypeTemplates('Lapis', const <AnkiCardTemplate>[
        AnkiCardTemplate(name: 'Card', front: 'F', back: 'B2'),
      ]),
      isTrue,
    );
    expect(seen!.url.path, '/api/anki/note-type/templates');
    final Map<String, dynamic> body =
        jsonDecode(seen!.body) as Map<String, dynamic>;
    expect(body['modelName'], 'Lapis');
    expect((body['templates'] as List).single,
        <String, dynamic>{'name': 'Card', 'front': 'F', 'back': 'B2'});
  });
}
