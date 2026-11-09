// 服务端 AnkiConnect 兼容监听（docs/specs/2026-11-05-server-srs-design.md §4.5）：默认关；非回环没 key 拒绝起；
// key 选 profile（Yomitan 一门语言一个 key），共用 key 落默认 profile。
import 'dart:convert';
import 'dart:io';

import 'package:fushi_server/src/config/server_srs_config.dart';
import 'package:fushi_server/src/server_ankiconnect.dart';
import 'package:fushi_server/src/server_srs.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart' as shelf;
import 'package:test/test.dart';

const String kJa = '01928c3e-0000-7000-8000-00000000a0a0';
const String kZh = '01928c3e-0000-7000-8000-00000000b0b0';

void main() {
  late Directory tmp;
  late ServerSrsConfig srsConfig;
  late ServerAnkiConnectConfig acConfig;
  late ServerSrs srs;
  late ServerAnkiConnect ac;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('fushi_server_ac_');
    srsConfig = const ServerSrsConfig(profiles: <String>[kJa, kZh]);
    acConfig = const ServerAnkiConnectConfig();
    srs = ServerSrs(
      support: Directory(p.join(tmp.path, 'support'))..createSync(),
      syncData: Directory(p.join(tmp.path, 'interconnect'))..createSync(),
      deviceId: 'server-device',
      hostId: 'host',
      config: () => srsConfig,
      engine: () => null,
    );
    ac = ServerAnkiConnect(srs: srs, config: () => acConfig);
    await srs.start();
    await srs.syncNow();
  });

  tearDown(() async {
    await ac.stop();
    await srs.stop();
    try {
      await tmp.delete(recursive: true);
    } on FileSystemException {
      // Windows 句柄晚释放：留给系统清理。
    }
  });

  Future<Object?> call(String action, {String? key, Object? params}) async {
    final shelf.Response res = await ac.handle(
      shelf.Request(
        'POST',
        Uri.parse('http://server:8765/'),
        body: jsonEncode(<String, Object?>{
          'action': action,
          'version': 6,
          'key': ?key,
          'params': ?params,
        }),
      ),
    );
    if (res.statusCode != 200) return res.statusCode;
    final Map<String, Object?> body =
        (jsonDecode(await res.readAsString()) as Map).cast<String, Object?>();
    if (body['error'] != null) return 'error: ${body['error']}';
    return body['result'];
  }

  Future<int> notesIn(String uid) async =>
      (await srs.storeFor(uid)!.userNoteCount());

  Future<Object?> addNote(String key, String word) async {
    final List<Object?> models = (await call('modelNames', key: key))! as List;
    final String model =
        models.firstWhere(
              (Object? m) => '$m'.toLowerCase().contains('lapis'),
              orElse: () => models.first,
            )!
            as String;
    final List<Object?> fields =
        (await call(
              'modelFieldNames',
              key: key,
              params: <String, Object?>{'modelName': model},
            ))!
            as List;
    final List<Object?> decks = (await call('deckNames', key: key))! as List;
    return call(
      'addNote',
      key: key,
      params: <String, Object?>{
        'note': <String, Object?>{
          'deckName': decks.first,
          'modelName': model,
          'fields': <String, Object?>{fields.first! as String: word},
        },
      },
    );
  }

  test('默认关：apply 之后不监听', () async {
    await ac.apply();
    expect(ac.listening, isFalse);
    expect(ac.lastError, isNull);
  });

  test('非回环地址没配 key：拒绝起，并说明原因', () async {
    acConfig = const ServerAnkiConnectConfig(enabled: true, bind: '0.0.0.0');
    await ac.apply();
    expect(ac.listening, isFalse);
    expect(ac.lastError, contains('api_key'));

    acConfig = const ServerAnkiConnectConfig(
      enabled: true,
      bind: '0.0.0.0',
      apiKey: 'same',
      profileKeys: <String, String>{kZh: 'same'},
    );
    await ac.apply();
    expect(ac.listening, isFalse);
    expect(ac.lastError, contains('duplicate'));
  });

  test('本机监听：不带 key 的本机请求可用', () async {
    acConfig = const ServerAnkiConnectConfig(enabled: true, port: 0);
    await ac.apply();
    expect(ac.listening, isTrue);
    final HttpClient client = HttpClient();
    addTearDown(client.close);
    final HttpClientRequest req = await client.post('127.0.0.1', ac.port!, '/');
    req.write(jsonEncode(<String, Object?>{'action': 'version', 'version': 6}));
    final HttpClientResponse res = await req.close();
    final Map<String, Object?> body =
        (jsonDecode(await res.transform(utf8.decoder).join()) as Map)
            .cast<String, Object?>();
    expect(body['result'], 6);
  });

  test('profile key 把卡加进那份 profile；共用 key 进默认；不认识的 key 被拒', () async {
    acConfig = const ServerAnkiConnectConfig(
      enabled: true,
      apiKey: 'shared',
      profileKeys: <String, String>{kZh: 'zh-key'},
    );
    final int ja0 = await notesIn(kJa);
    final int zh0 = await notesIn(kZh);

    expect(await addNote('zh-key', '吃饭'), isA<int>());
    expect(await notesIn(kZh), zh0 + 1);
    expect(await notesIn(kJa), ja0);

    expect(await addNote('shared', '食べる'), isA<int>());
    expect(await notesIn(kJa), ja0 + 1, reason: '共用 key = 默认 profile（第一份）');

    expect(await call('deckNames', key: 'wrong'), startsWith('error: '));
    // 不在本机、不带 key：引擎端点按回环限制拒绝。
    acConfig = const ServerAnkiConnectConfig(enabled: true);
    expect(await call('deckNames'), 403);
  });
}
