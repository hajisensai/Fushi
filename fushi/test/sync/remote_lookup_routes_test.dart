import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/fushi_remote_lookup_service.dart';
import 'package:fushi/src/sync/remote_lookup_routes.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:shelf/shelf.dart' as shelf;

import 'fushi_sync_server_source_corpus.dart';

/// [FushiSyncServer] 与 [YomitanApiServer] 共用的查词/制卡 handler 壳与音频 token
/// 存储。抽出前两边各一份，且只有互联侧修了 BUG-908(a) 的上限——合成一份后扩展侧
/// 也有了上限（本文件把这条行为钉死）。两台服务器各自的 HTTP 级用例
/// （`fushi_sync_server_*_test` / `yomitan_api_server_*_test`）继续覆盖分发与鉴权。
void main() {
  group('RemoteAudioTokenStore', () {
    late DateTime clock;
    late RemoteAudioTokenStore store;
    final Uint8List mp3 = Uint8List.fromList(utf8.encode('MP3'));

    setUp(() {
      clock = DateTime(2026, 9, 6, 12);
      store = RemoteAudioTokenStore(now: () => clock);
    });

    test('mint 后可 take；id 不可猜（24 字节 base64url）且每次不同', () {
      final String a = store.mint(mp3, 'audio/mpeg');
      final String b = store.mint(mp3, 'audio/mpeg');
      expect(a, isNot(b));
      expect(a.length, 24);
      expect(store.take(a)?.contentType, 'audio/mpeg');
      expect(store.take(null), isNull);
      expect(store.take('nope'), isNull);
    });

    test('TTL：5 分钟无访问被 prune；命中即续期（TODO-766）', () {
      final String id = store.mint(mp3, 'audio/mpeg');

      clock = clock.add(const Duration(minutes: 4));
      expect(store.take(id), isNotNull, reason: '4 分钟内命中 → 续期');

      clock = clock.add(const Duration(minutes: 4));
      expect(store.take(id), isNotNull, reason: '距上次命中 4 分钟 → 仍在窗口内（续期生效）');

      clock = clock.add(const Duration(minutes: 5, seconds: 1));
      expect(store.take(id), isNull, reason: '5 分钟无访问 → 过期');
      expect(store.count, 0);
    });

    test('上限（BUG-908(a)）：时钟不动狂签发时按最旧逐出，总数 <= maxTokens', () {
      final RemoteAudioTokenStore capped =
          RemoteAudioTokenStore(now: () => clock, maxTokens: 4);
      final List<String> ids = <String>[];
      for (int i = 0; i < 10; i++) {
        clock = clock.add(const Duration(seconds: 1));
        ids.add(capped.mint(mp3, 'audio/mpeg'));
      }
      expect(capped.count, lessThanOrEqualTo(4));
      expect(capped.take(ids.first), isNull, reason: '最旧的被逐出');
      expect(capped.take(ids.last), isNotNull, reason: '最新的还在');
    });

    test('默认上限 128、TTL 5 分钟——与互联侧 BUG-908(a) 修复值一致', () {
      final RemoteAudioTokenStore defaults = RemoteAudioTokenStore();
      expect(defaults.maxTokens, 128);
      expect(defaults.ttl, const Duration(minutes: 5));
    });
  });

  group('RemoteLookupRoutes', () {
    final Uint8List mp3 = Uint8List.fromList(utf8.encode('MP3'));

    shelf.Request post(String path, Object? body) => shelf.Request(
          'POST',
          Uri.parse('http://127.0.0.1:1$path'),
          body: body is String ? body : jsonEncode(body),
        );

    test('audio：查到即签发 token，URL 指向免鉴权取字节端点；取字节带长度头', () async {
      final RemoteLookupRoutes routes = RemoteLookupRoutes(
        audioTokens: RemoteAudioTokenStore(),
        lookup: _StubLookup(mp3),
      );

      final shelf.Response res = await routes.handleAudioLookup(
          post('/api/lookup/audio', {'expression': '猫', 'reading': 'ねこ'}));
      expect(res.statusCode, 200);
      expect(res.headers['content-type'], 'application/json; charset=utf-8');
      final Map<String, dynamic> json =
          jsonDecode(await res.readAsString()) as Map<String, dynamic>;
      expect(json['type'], 'audioResult');
      expect(json['contentType'], 'audio/mpeg');
      final Uri url = Uri.parse(json['url'] as String);
      expect(url.path, '/api/lookup/audio/file');
      expect(url.queryParameters['id'], isNotEmpty);

      final shelf.Response file = routes.handleAudioFile(
        shelf.Request('GET', url),
        headOnly: false,
      );
      expect(file.statusCode, 200);
      expect(file.headers['content-type'], 'audio/mpeg');
      expect(file.headers['content-length'], '3');
      expect(await file.readAsString(), 'MP3');

      final shelf.Response head = routes.handleAudioFile(
        shelf.Request('HEAD', url),
        headOnly: true,
      );
      expect(head.statusCode, 200);
      expect(head.headers['content-length'], '3');
    });

    test('audio：空 expression / 未命中 → {url:null}；无 service → 404；非法 JSON → 400',
        () async {
      final RemoteLookupRoutes hit = RemoteLookupRoutes(
        audioTokens: RemoteAudioTokenStore(),
        lookup: _StubLookup(mp3),
      );
      final shelf.Response empty = await hit
          .handleAudioLookup(post('/api/lookup/audio', {'expression': '  '}));
      expect(jsonDecode(await empty.readAsString())['url'], isNull);

      final RemoteLookupRoutes miss = RemoteLookupRoutes(
        audioTokens: RemoteAudioTokenStore(),
        lookup: _StubLookup(null),
      );
      final shelf.Response none = await miss
          .handleAudioLookup(post('/api/lookup/audio', {'expression': '猫'}));
      expect(jsonDecode(await none.readAsString())['url'], isNull);

      final RemoteLookupRoutes off =
          RemoteLookupRoutes(audioTokens: RemoteAudioTokenStore());
      expect(
          (await off.handleAudioLookup(
                  post('/api/lookup/audio', {'expression': '猫'})))
              .statusCode,
          404);
      expect(
          (await hit.handleAudioLookup(post('/api/lookup/audio', '{not json')))
              .statusCode,
          400);
      expect(
          routes404(hit.handleAudioFile(
              shelf.Request('GET', Uri.parse('http://h/api/lookup/audio/file')),
              headOnly: false)),
          isTrue);
    });

    test(
        'mine / forward / note-type：无挖词 service → 404 Mining off；非法 JSON → 400',
        () async {
      final RemoteLookupRoutes off =
          RemoteLookupRoutes(audioTokens: RemoteAudioTokenStore());
      for (final Future<shelf.Response> f in <Future<shelf.Response>>[
        off.handleMine(post('/api/mine', {})),
        off.handleMineForward(post('/api/mine/forward', {})),
        off.handleAnkiNoteType(
            post('/api/anki/note-type/read', {}), '/api/anki/note-type/read'),
      ]) {
        final shelf.Response r = await f;
        expect(r.statusCode, 404);
        expect(await r.readAsString(), 'Mining off');
      }

      final RemoteLookupRoutes on = RemoteLookupRoutes(
        audioTokens: RemoteAudioTokenStore(),
        mining: _NeverCalledMining(),
      );
      for (final Future<shelf.Response> f in <Future<shelf.Response>>[
        on.handleMine(post('/api/mine', '{bad')),
        on.handleMineForward(post('/api/mine/forward', '')),
        on.handleAnkiNoteType(post('/api/anki/note-type/read', '[1]'),
            '/api/anki/note-type/read'),
        on.handleDuplicate(post('/api/duplicate', 'null')),
      ]) {
        final shelf.Response r = await f;
        expect(r.statusCode, 400);
        expect(await r.readAsString(), 'Invalid JSON');
      }
    });

    test('note-type：三条子路径之外 → 404 Unknown endpoint（不碰 service）', () async {
      final RemoteLookupRoutes on = RemoteLookupRoutes(
        audioTokens: RemoteAudioTokenStore(),
        mining: _NeverCalledMining(),
      );
      final shelf.Response r = await on.handleAnkiNoteType(
          post('/api/anki/note-type/bogus', {}), '/api/anki/note-type/bogus');
      expect(r.statusCode, 404);
      expect(await r.readAsString(), 'Unknown endpoint');
    });

    test('duplicate：无挖词 service 降级为 {duplicate:false}，但非法 JSON 的 400 优先',
        () async {
      final RemoteLookupRoutes off =
          RemoteLookupRoutes(audioTokens: RemoteAudioTokenStore());
      final shelf.Response r =
          await off.handleDuplicate(post('/api/duplicate', {'term': '猫'}));
      expect(r.statusCode, 200);
      expect(jsonDecode(await r.readAsString()), {'duplicate': false});
      expect(
          (await off.handleDuplicate(post('/api/duplicate', '{'))).statusCode,
          400);
    });

    test('readJsonObjectBody：空体 / 非 object / 非法 JSON 一律 null；object 原样返回',
        () async {
      expect(await readJsonObjectBody(post('/x', '')), isNull);
      expect(await readJsonObjectBody(post('/x', '[1,2]')), isNull);
      expect(await readJsonObjectBody(post('/x', '{')), isNull);
      expect(await readJsonObjectBody(post('/x', {'a': 1})), {'a': 1});
    });

    test(
        'jsonResponse / jsonRawResponse：utf-8 charset 不可被 extraHeaders 覆盖（TODO-752a）',
        () async {
      final shelf.Response r =
          jsonRawResponse('{"a":1}', extraHeaders: <String, String>{
        'Content-Type': 'text/plain',
        'X-Extra': 'y',
      });
      expect(r.headers['content-type'], 'application/json; charset=utf-8');
      expect(r.headers['x-extra'], 'y');
      expect(
          await jsonResponse(<String, int>{'a': 1}).readAsString(), '{"a":1}');
    });

    test('小写 content-type 同样不可覆盖（HTTP 头名大小写不敏感）', () async {
      // 上一条只喂大写 'Content-Type'——那种情况下 Dart map 里是同一个键，靠后写
      // 覆盖。传小写时 map 里是**两个**键，两条都进 shelf 的 CaseInsensitiveMap，
      // 靠「显式那条排在展开之后」才赢。当前实现是对的（map 字面量迭代序 = 插入
      // 序），但这条正确性完全押在写法顺序上：谁把 extraHeaders 挪到 Content-Type
      // 后面展开、或者改成按精确键名 remove 再展开，小写这一路就会漏，而只喂大写
      // 的上一条测不出来。这条就是补那个盲区的。
      final shelf.Response r =
          jsonRawResponse('{"a":1}', extraHeaders: <String, String>{
        'content-type': 'text/plain',
        'Server-Timing': 'lookup;dur=3',
      });
      expect(r.headers['content-type'], 'application/json; charset=utf-8',
          reason: 'CJK 词典义项会被 client 按 latin1 解码成乱码（TODO-752a）');
      expect(r.headers['server-timing'], 'lookup;dur=3',
          reason: '剔除只能针对 content-type，别的透传头不能被误伤');
    });
  });

  group('源码守卫：两台服务器不再各写一份 handler 壳 / 音频 token 模型', () {
    // B3 拆分后 fushi_sync_server 是主库 + fushi_sync_server/*.part.dart：负向断言
    // 必须扫合并语料，只扫主库会让搬进 part 的重复壳真空通过。
    final Map<String, String Function()> sources = <String, String Function()>{
      'lib/src/sync/fushi_sync_server.dart': readFushiSyncServerSource,
      'lib/src/sync/yomitan_api_server.dart': () =>
          File('lib/src/sync/yomitan_api_server.dart').readAsStringSync(),
    };
    const Map<String, List<String>> banned = <String, List<String>>{
      'lib/src/sync/fushi_sync_server.dart': <String>[
        'class _RemoteAudioToken',
        'Future<shelf.Response> _handleMine(',
        'Future<shelf.Response> _handleMineForward(',
        'Future<shelf.Response> _handleAnkiNoteType(',
        'Future<shelf.Response> _handleDuplicate(',
        'Future<shelf.Response> _handleAudioLookup(',
        '_handleAudioFile(',
        '_generateAudioToken(',
        '_pruneAudioTokens(',
      ],
      'lib/src/sync/yomitan_api_server.dart': <String>[
        'class _YomitanAudioToken',
        'Future<shelf.Response> _handleMine(',
        'Future<shelf.Response> _handleMineForward(',
        'Future<shelf.Response> _handleAnkiNoteType(',
        'Future<shelf.Response> _handleDuplicate(',
        'Future<shelf.Response> _handleAudioLookup(',
        '_handleAudioFile(',
        '_generateAudioToken(',
        '_pruneAudioTokens(',
        'createdAt: DateTime.now()',
      ],
    };

    // 正向断言必须是**调用点**。原来写的是 `contains('RemoteLookupRoutes')`，而两个
    // 文件的注释里就写着这个类名——把六条分发全删光、只留注释，那条照样绿。
    const List<String> callSites = <String>[
      '_lookupRoutes.handleMine(',
      '_lookupRoutes.handleMineForward(',
      '_lookupRoutes.handleAnkiNoteType(',
      '_lookupRoutes.handleDuplicate(',
      '_lookupRoutes.handleAudioLookup(',
      '_lookupRoutes.handleAudioFile(',
    ];

    banned.forEach((String path, List<String> needles) {
      test(path, () {
        expect(File(path).existsSync(), isTrue,
            reason: '$path 不存在（请从 fushi/ 包根跑测试）');
        final String src = sources[path]!();
        for (final String site in callSites) {
          expect(src, contains(site),
              reason: '$path 少了 `$site`——这条端点没走共享壳，'
                  '要么被删了要么又被抄回本地一份');
        }
        for (final String needle in needles) {
          expect(src, isNot(contains(needle)),
              reason:
                  '$path 里出现 `$needle`——共享壳应只在 remote_lookup_routes.dart 有一份');
        }
      });
    });

    test('音频 token 的 id 必须来自 Random.secure()', () {
      // 这是整个 RemoteAudioTokenStore 唯一的安全属性：id 是能拿到任意查词音频的
      // bearer。换成 Random()（时间种子、可预测）之后，长度断言、`isNot(b)`
      // 断言、TTL 断言、上限断言**全部照绿**——没有任何别的测试会红。
      final String src =
          File('lib/src/sync/remote_lookup_routes.dart').readAsStringSync();
      expect(src, contains('Random.secure()'),
          reason: '音频 token id 是 bearer，必须用密码学随机源');
      expect(src, isNot(contains('Random()')),
          reason: '出现了可预测的 Random()：token 能被枚举出来');
    });
  });
}

bool routes404(shelf.Response r) => r.statusCode == 404;

class _StubLookup implements FushiRemoteLookupService {
  _StubLookup(this._bytes);

  final Uint8List? _bytes;

  @override
  Future<RemoteAudioLookup?> lookupAudio({
    required String expression,
    required String reading,
  }) async {
    final Uint8List? b = _bytes;
    return b == null
        ? null
        : RemoteAudioLookup(bytes: b, contentType: 'audio/mpeg');
  }

  @override
  Future<DictionarySearchResult?> searchDictionary({
    required String term,
    required bool wildcards,
    required int maximumTerms,
  }) async =>
      null;
}

/// 本文件只走 404/400/降级路径，任何触达 service 的调用都是错误。
class _NeverCalledMining implements FushiRemoteMiningService {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      fail('mining service must not be called: ${invocation.memberName}');
}
