import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_anki/fushi_anki_core.dart';
import 'package:fushi_engine/sync/forwarded_mine_payload.dart';
import 'package:fushi_engine/sync/fushi_remote_lookup_service.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi_engine/sync/immersion_mine_payload.dart';
import 'package:fushi_server/src/remote_mining_host.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 互联「制卡到服务端」：[ServerRemoteMiningService] 的映射语义，以及挂到真
/// [FushiSyncServer] 上后 `/api/mine`、`/api/mine/forward`、`/api/duplicate` 走通。
/// 落卡本身（fushi-anki-sync 会话）用注入的假 [ServerMineCard] 代替——真会话的渲染 /
/// 查重 / 写库链路由引擎的 `AnkiSyncMiner` 负责，与落地队列共用。
void main() {
  late List<({String raw, AnkiMiningContext context, bool coverExisted})> calls;
  late MineOutcome nextOutcome;
  late List<String> mediaWrites;

  ServerRemoteMiningService build({Future<bool> Function(String expression)? isDuplicate}) => ServerRemoteMiningService(
    mineCard: (String raw, AnkiMiningContext context) async {
      calls.add((
        raw: raw,
        context: context,
        coverExisted: context.coverPath != null && File(context.coverPath!).existsSync(),
      ));
      return nextOutcome;
    },
    isDuplicateExpression: isDuplicate ?? (String expression) async => expression == '食べる',
    writeDictionaryMedia: (String json) async => mediaWrites.add(json),
  );

  setUp(() {
    calls = <({String raw, AnkiMiningContext context, bool coverExisted})>[];
    nextOutcome = const MineOutcome.success(deckName: 'Mining', audioWarning: 'no audio');
    mediaWrites = <String>[];
  });

  test('mineEntry：fields 原样成为载荷、句子进上下文；外字先落缓存；success 带牌组与音频警告', () async {
    final RemoteMineResult r = await build().mineEntry(
      fields: <String, String>{'expression': '食べる', 'dictionaryMedia': '[{"dictionary":"D","path":"a.svg"}]'},
      sentence: 'りんごを食べる',
    );
    expect(r.result, 'success');
    expect(r.deckName, 'Mining');
    expect(r.message, 'no audio');
    expect(jsonDecode(calls.single.raw), containsPair('expression', '食べる'));
    expect(calls.single.context.sentence, 'りんごを食べる');
    expect(mediaWrites, <String>['[{"dictionary":"D","path":"a.svg"}]']);
  });

  test('失败带原因；notConfigured / duplicate 只回结果名', () async {
    nextOutcome = MineOutcome.failure('Sign in to the Anki sync server first.');
    final RemoteMineResult err = await build().mineEntry(
      fields: const <String, String>{'expression': 'x'},
      sentence: '',
    );
    expect(err.result, 'error');
    expect(err.message, 'Sign in to the Anki sync server first.');
    nextOutcome = const MineOutcome.notConfigured();
    expect((await build().mineEntry(fields: const <String, String>{}, sentence: '')).result, 'notConfigured');
    nextOutcome = const MineOutcome.duplicate();
    final RemoteMineResult dup = await build().mineEntry(fields: const <String, String>{}, sentence: '');
    expect(dup.result, 'duplicate');
    expect(dup.message, isNull);
  });

  test('mineForwarded：随附的封面字节落成本机临时文件交给落卡，落完回收', () async {
    final RemoteMineResult r = await build().mineForwarded(
      ForwardedMinePayload(
        rawPayloadJson: jsonEncode(<String, String>{'expression': '食べる'}),
        sentence: 's',
        coverBytes: Uint8List.fromList(<int>[1, 2, 3]),
        coverExt: 'jpg',
      ),
    );
    expect(r.result, 'success');
    expect(calls.single.coverExisted, isTrue);
    expect(p.extension(calls.single.context.coverPath!), '.jpg');
    expect(File(calls.single.context.coverPath!).existsSync(), isFalse);
  });

  test('沉浸制卡明确回不支持，不落卡', () async {
    final RemoteMineResult r = await build().mineImmersion(
      const ImmersionMinePayload(fields: <String, String>{'expression': 'x'}, sentence: 's'),
    );
    expect(r.result, 'error');
    expect(r.message, kServerImmersionMiningUnsupported);
    expect(calls, isEmpty);
  });

  test('查重：透传会话结果；后端抛错按不重复；空表记不查', () async {
    final ServerRemoteMiningService svc = build();
    expect(await svc.isDuplicate(expression: '食べる', reading: ''), isTrue);
    expect(await svc.isDuplicate(expression: '飲む', reading: ''), isFalse);
    expect(await svc.isDuplicate(expression: '', reading: ''), isFalse);
    final ServerRemoteMiningService failing = build(isDuplicate: (String _) async => throw StateError('signed out'));
    expect(await failing.isDuplicate(expression: '食べる', reading: ''), isFalse);
  });

  test('服务端没有 Anki 桌面：打开词 failed，模板读写 / 媒体去重不支持', () async {
    final ServerRemoteMiningService svc = build();
    expect(await svc.openWordInAnki(expression: 'x', reading: ''), AnkiOpenWordOutcome.failed);
    expect(await svc.readNoteTypeDefinition('Lapis'), isNull);
    expect(await svc.updateNoteTypeStyling('Lapis', ''), isFalse);
    expect(await svc.updateNoteTypeTemplates('Lapis', const <AnkiCardTemplate>[]), isFalse);
    expect(await svc.probeMediaMaintenance(), isFalse);
    expect(await svc.runMediaDedup(), isNull);
  });

  group('挂到 FushiSyncServer', () {
    late Directory tmp;
    late FushiSyncServer server;
    late HttpClient client;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('fushi_server_mining_');
      server = FushiSyncServer(syncDataDir: tmp.path, port: 0, token: 'host-token', miningService: build());
      await server.start();
      client = HttpClient();
    });

    tearDown(() async {
      client.close(force: true);
      await server.stop();
      await tmp.delete(recursive: true);
    });

    Future<({int status, Map<String, dynamic> json})> post(String path, Object body) async {
      final HttpClientRequest req = await client.postUrl(Uri.parse('http://127.0.0.1:${server.port}$path'));
      req.headers
        ..set('Authorization', 'Basic ${base64Encode(utf8.encode('hibiki:host-token'))}')
        ..contentType = ContentType.json;
      req.write(jsonEncode(body));
      final HttpClientResponse res = await req.close();
      final String text = await utf8.decodeStream(res);
      return (status: res.statusCode, json: Map<String, dynamic>.from(jsonDecode(text) as Map));
    }

    test('/api/mine、/api/mine/forward、/api/duplicate 走到服务端制卡', () async {
      final mine = await post('/api/mine', <String, Object>{
        'fields': <String, String>{'expression': '食べる'},
        'sentence': 's',
      });
      expect(mine.status, 200);
      expect(mine.json, containsPair('result', 'success'));
      expect(mine.json, containsPair('deckName', 'Mining'));
      final forward = await post(
        '/api/mine/forward',
        ForwardedMinePayload(rawPayloadJson: jsonEncode(<String, String>{'expression': '飲む'}), sentence: 's').toJson(),
      );
      expect(forward.status, 200);
      expect(forward.json, containsPair('result', 'success'));
      expect(calls, hasLength(2));
      final dup = await post('/api/duplicate', <String, String>{'expression': '食べる', 'reading': 'たべる'});
      expect(dup.json, containsPair('duplicate', true));
    });

    test('capabilities 如实报 mining: true、gameStream: false', () async {
      final HttpClientRequest req = await client.getUrl(Uri.parse('http://127.0.0.1:${server.port}/api/capabilities'));
      req.headers.set('Authorization', 'Basic ${base64Encode(utf8.encode('hibiki:host-token'))}');
      final Map<String, dynamic> caps = Map<String, dynamic>.from(
        jsonDecode(await utf8.decodeStream(await req.close())) as Map,
      );
      expect(caps['mining'], isTrue);
      expect(caps['gameStream'], isFalse);
      expect(caps['lookup'], <String, Object>{'dictionary': false, 'history': false});
    });
  });
}
