// 服务端的复习库内容端点（admin_srs_ctl.dart）：与 app 的 `fushi_cli srs …` 同一份 engine 路由，挂在
// admin API 下。对真的 HeadlessHost + AdminApi + AdminServer（真 HTTP、真 srs.db，两份 profile）跑：
// - 鉴权：不带 admin token 一律 401，路由根本不执行；
// - profile：点名取那份、两份互不串；没点名时只有一份可用就是它，几份都可用 409 profile_required；
//   没提供的 404；一份都没有 409；
// - `fushi_server ctl srs …`：真 AdminClient 打到真服务上，中英文输出、退出码；
// - AI 操作目录：接了复习库才有这组操作；经 ServerAgentToolbox 执行 → 记进服务端库 → 撤销写回同一份。
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/ai/agent/agent_tool.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_duplicate_notes.dart';
import 'package:fushi_server/src/admin/admin_api.dart';
import 'package:fushi_server/src/admin/admin_context.dart';
import 'package:fushi_server/src/admin/admin_ops.dart';
import 'package:fushi_server/src/admin/admin_server.dart';
import 'package:fushi_server/src/agent_host.dart';
import 'package:fushi_server/src/config/server_config.dart';
import 'package:fushi_server/src/ctl/admin_client.dart';
import 'package:fushi_server/src/ctl/ctl_commands.dart';
import 'package:fushi_server/src/headless_host.dart';
import 'package:fushi_server/src/server_identity.dart';
import 'package:fushi_server/src/server_language.dart';
import 'package:fushi_server/src/server_log.dart';
import 'package:fushi_server/src/server_paths.dart';
import 'package:fushi_server/src/server_prefs.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart' as shelf;
import 'package:test/test.dart';

const String kJa = '01928c3e-0000-7000-8000-00000000a0a0';
const String kZh = '01928c3e-0000-7000-8000-00000000b0b0';
const String kToken = 'srs-ctl-token=';

/// 这组端点的全部路由（method + 样例路径）。
const List<(String, String)> kDataRoutes = <(String, String)>[
  ('GET', 'srs/decks'),
  ('GET', 'srs/notes'),
  ('GET', 'srs/notes/n1'),
  ('GET', 'srs/stats'),
  ('GET', 'srs/conflicts'),
  ('POST', 'srs/conflicts/held/c1/delete'),
  ('POST', 'srs/conflicts/held/c1/keep'),
  ('POST', 'srs/conflicts/fields/resolve'),
  ('POST', 'srs/duplicates/merge'),
  ('POST', 'srs/duplicates/dismiss'),
  ('POST', 'srs/notes/batch/card-type'),
  ('POST', 'srs/notes/batch/set-field'),
  ('POST', 'srs/notes/batch/find-replace'),
];

void main() {
  late Directory tmp;
  late FushiDatabase db;
  late HeadlessHost host;
  late AdminApi api;
  late AdminServer server;
  late HttpClient http;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('fushi_admin_srs_ctl_');
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    final File configFile = File(p.join(tmp.path, 'fushi_server.yaml'));
    final ServerConfig config =
        ServerConfig.defaults(dataDir: p.join(tmp.path, 'data')).copyWith(
          port: 0,
          bind: '127.0.0.1',
          tls: false,
          adminPort: 0,
          adminBind: '127.0.0.1',
          adminToken: kToken,
        );
    await config.save(configFile);
    final ServerPrefs prefs = ServerPrefs(db);
    final ServerIdentity identity = await ServerIdentity.loadOrCreate(prefs);
    final ServerPaths paths = ServerPaths(config.dataDir);
    await paths.ensureLayout();
    host = HeadlessHost(
      config: config,
      paths: paths,
      db: db,
      prefs: prefs,
      identity: identity,
      p2pAvailable: () => false,
    );
    await host.start();
    final AdminContext ctx = AdminContext(
      config: config,
      configFile: configFile,
      paths: paths,
      log: ServerLog(file: File(p.join(tmp.path, 'server.log'))),
      db: db,
      identity: identity,
      host: host,
      startedAt: DateTime.now(),
    );
    api = AdminApi(ctx);
    server = AdminServer(ctx: ctx, token: kToken, api: api);
    await server.start();
    http = HttpClient();
  });

  tearDown(() async {
    serverLanguage = ServerConfig.defaultLanguage;
    http.close(force: true);
    await server.stop();
    await host.stop();
    await db.close();
    try {
      await tmp.delete(recursive: true);
    } on FileSystemException {
      // Windows 句柄晚释放：留给系统清理。
    }
  });

  /// 真 HTTP 请求（经 AdminServer 的鉴权）。
  Future<(int, Map<String, Object?>)> request(
    String method,
    String path, {
    Object? body,
    String? token = kToken,
  }) async {
    final HttpClientRequest req = await http.openUrl(
      method,
      Uri.parse('http://127.0.0.1:${server.port}/api/admin/$path'),
    );
    if (token != null) {
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    }
    if (body != null) {
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
    }
    final HttpClientResponse res = await req.close();
    final String text = await utf8.decodeStream(res);
    return (res.statusCode, Map<String, Object?>.from(jsonDecode(text) as Map));
  }

  /// 管理员勾选 [uids] 并等它们可用。
  Future<void> serve(List<String> uids) async {
    final (int code, Map<String, Object?> st) = await request(
      'PUT',
      'srs',
      body: <String, Object?>{'profiles': uids},
    );
    expect(code, 200, reason: '$st');
    await host.srs!.syncNow();
    for (final String uid in uids) {
      expect(host.srs!.storeFor(uid), isNotNull, reason: uid);
    }
  }

  SrsDbStore store(String uid) => host.srs!.storeFor(uid)!;

  Future<String> addNote(
    String uid,
    String expression, {
    String sentence = '',
  }) => store(uid).createNote(
    noteTypeId: store(uid).lapisNoteTypeId,
    fieldsById: <String, String>{
      srsLapisFieldId(uid, 'Expression'): expression,
      if (sentence.isNotEmpty) srsLapisFieldId(uid, 'Sentence'): sentence,
    },
  );

  Future<String> sentence(String uid, String note) async =>
      (await store(uid).note(note))!.field(srsLapisFieldId(uid, 'Sentence'));

  test('鉴权：不带 token / token 不对一律 401，写路由没有执行；带 token 才进得去', () async {
    await serve(<String>[kJa]);
    final String a = await addNote(kJa, '雪');
    final String b = await addNote(kJa, '雪');
    for (final String? token in <String?>[null, 'wrong-token']) {
      for (final (String method, String path) in kDataRoutes) {
        final (int code, Map<String, Object?> body) = await request(
          method,
          path,
          token: token,
          body: method == 'POST'
              ? <String, Object?>{
                  'keep': a,
                  'absorb': <String>[b],
                  'notes': <String>[a, b],
                }
              : null,
        );
        expect(code, 401, reason: '$method $path token=$token');
        expect(body, <String, Object?>{'error': 'unauthorized'});
      }
    }
    expect((await store(kJa).note(b))!.deletedAt, isNull);
    expect(await store(kJa).duplicateNoteGroups(), hasLength(1));

    final (int code, Map<String, Object?> decks) = await request(
      'GET',
      'srs/decks',
    );
    expect(code, 200);
    expect(decks['decks'], isNotEmpty);
    // cookie 通道（WebUI）同样认。
    final HttpClientRequest req = await http.getUrl(
      Uri.parse('http://127.0.0.1:${server.port}/api/admin/srs/conflicts'),
    );
    req.headers.set(
      HttpHeaders.cookieHeader,
      adminSetCookieValue(kToken, secure: false).split(';').first,
    );
    expect((await req.close()).statusCode, 200);
  });

  test('profile：一份都没有 409；点名取那份、互不串；几份可用时不点名 409；没提供的 404', () async {
    var (int code, Map<String, Object?> body) = await request(
      'GET',
      'srs/decks',
    );
    expect(code, 409);
    expect(body['reason'], 'profile_unavailable');

    await serve(<String>[kJa, kZh]);
    final String fish = await addNote(kJa, '魚', sentence: 'old');
    final String zhNote = await addNote(kZh, '鱼', sentence: 'old');

    (code, body) = await request('GET', 'srs/notes?profile=$kJa');
    expect(code, 200);
    expect(body['total'], 1);
    expect(((body['items']! as List<Object?>).single! as Map)['noteId'], fish);
    (code, body) = await request('GET', 'srs/notes?profile=$kZh&q=鱼');
    expect(body['total'], 1);
    (code, body) = await request('GET', 'srs/notes/$fish?profile=$kZh');
    expect(code, 404, reason: '日语那份的笔记不在中文那份里');
    expect(body['reason'], 'not_found');
    (code, body) = await request('GET', 'srs/notes/$fish?profile=$kJa');
    expect((body['fields']! as Map)['Expression'], '魚');
    (code, body) = await request('GET', 'srs/stats?profile=$kJa');
    expect(code, 200);
    expect((body['cards']! as Map)['total'], greaterThanOrEqualTo(1));
    (code, body) = await request('GET', 'srs/conflicts?profile=$kJa');
    expect(code, 200);
    expect(body.keys, containsAll(<String>['held', 'fields', 'duplicates']));

    for (final (String method, String path) in kDataRoutes) {
      (code, body) = await request(
        method,
        path,
        body: method == 'POST' ? const <String, Object?>{} : null,
      );
      expect(code, 409, reason: '$method $path');
      expect(body['reason'], 'profile_required', reason: '$method $path');
    }
    (code, body) = await request(
      'GET',
      'srs/decks?profile=01928c3e-0000-7000-8000-00000000dead',
    );
    expect(code, 404);
    expect(body['reason'], 'profile_not_served');

    // 写：只动点名那份（POST 的 profile 在 body 里）。
    (code, body) = await request(
      'POST',
      'srs/notes/batch/set-field',
      body: <String, Object?>{
        'profile': kJa,
        'targetField': 'Sentence',
        'value': 'new',
        'notes': <String>[fish],
      },
    );
    expect(code, 200, reason: '$body');
    expect(body['notes'], 1);
    expect(await sentence(kJa, fish), 'new');
    expect(await sentence(kZh, zhNote), 'old');
    (code, body) = await request(
      'POST',
      'srs/notes/batch/set-field',
      body: <String, Object?>{'profile': kJa, 'targetField': 'Sentence'},
    );
    expect(code, 400, reason: '不给目标 = 不允许改全库');
    // 点名中文那份、id 却是日语那份的（BUG-4387：库按 id 读写不看 profile）：404，哪份都不写。
    (code, body) = await request(
      'POST',
      'srs/notes/batch/set-field',
      body: <String, Object?>{
        'profile': kZh,
        'targetField': 'Sentence',
        'value': 'wrong library',
        'notes': <String>[fish],
      },
    );
    expect(code, 404, reason: '$body');
    expect(body['reason'], 'not_found');
    final String dup = await addNote(kJa, '魚');
    (code, body) = await request(
      'POST',
      'srs/duplicates/merge',
      body: <String, Object?>{
        'profile': kZh,
        'keep': fish,
        'absorb': <String>[dup],
      },
    );
    expect(code, 404, reason: '$body');
    expect((await store(kJa).note(dup))!.deletedAt, isNull);
    expect(await sentence(kJa, fish), 'new');
    (code, body) = await request(
      'POST',
      'srs/conflicts/held/nope/keep',
      body: <String, Object?>{'profile': kJa, 'confirm': true},
    );
    expect(code, 404);

    // 只剩一份可用：不点名就是它。
    await serve(<String>[kZh]);
    (code, body) = await request('GET', 'srs/notes');
    expect(code, 200);
    expect(
      ((body['items']! as List<Object?>).single! as Map)['noteId'],
      zhNote,
    );
    // 原有的配置面端点不受影响。
    (code, body) = await request('GET', 'srs/profiles');
    expect(code, 200);
    expect(body['profiles'], isA<List<Object?>>());
  });

  group('fushi_server ctl srs', () {
    late AdminClient client;
    late StringBuffer out;
    late StringBuffer err;

    setUp(() {
      client = AdminClient(
        baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
        token: kToken,
      );
      out = StringBuffer();
      err = StringBuffer();
    });
    tearDown(() => client.close());

    Future<int> ctl(List<String> args) {
      out.clear();
      err.clear();
      return runCtlAction(
        client,
        buildCtlParser().parse(args),
        out: out,
        err: err,
      );
    }

    test('读：牌组 / 搜索 / 一条笔记 / 统计 / 冲突中心，中英文输出', () async {
      await serve(<String>[kJa, kZh]);
      final String fish = await addNote(kJa, '魚', sentence: '魚を食べる');
      await addNote(kJa, '雪');
      await addNote(kJa, '雪');

      serverLanguage = 'zh';
      expect(await ctl(<String>['srs', 'decks', '--srs-profile', kJa]), 0);
      expect('$out', contains('牌组'));
      expect(await ctl(<String>['srs', 'notes', '魚', '--srs-profile', kJa]), 0);
      expect('$out', contains('共 1 条'));
      expect('$out', contains(fish));
      expect(
        await ctl(<String>[
          'srs',
          'notes',
          '魚',
          '--field',
          'Expression',
          '--cards',
          '--limit',
          '5',
          '--srs-profile',
          kJa,
        ]),
        0,
      );
      expect('$out', contains('卡片 id'));
      expect(await ctl(<String>['srs', 'note', fish, '--srs-profile', kJa]), 0);
      expect('$out', contains('Sentence: 魚を食べる'));
      expect(await ctl(<String>['srs', 'stats', '--srs-profile', kJa]), 0);
      expect('$out', contains('30 天真实保留率'));
      expect(await ctl(<String>['srs', 'conflicts', '--srs-profile', kJa]), 0);
      expect('$out', contains('疑似重复'));
      expect(await ctl(<String>['srs', 'conflicts', '--srs-profile', kZh]), 0);
      expect('$out'.trim(), '没有冲突');

      serverLanguage = 'en';
      expect(await ctl(<String>['srs', 'decks', '--srs-profile', kJa]), 0);
      expect('$out', contains('Deck'));
      expect('$out', isNot(contains('牌组')));
      expect(await ctl(<String>['srs', 'notes', '--srs-profile', kJa]), 0);
      expect('$out', contains('3 in total'));
      expect(await ctl(<String>['srs', 'stats', '--srs-profile', kJa]), 0);
      expect('$out', contains('30-day true retention'));
      expect(await ctl(<String>['srs', 'conflicts', '--srs-profile', kJa]), 0);
      expect('$out', contains('Likely duplicates'));
      expect(await ctl(<String>['srs', 'conflicts', '--srs-profile', kZh]), 0);
      expect('$out'.trim(), 'No conflicts');
      // --json：原样输出服务端 JSON。
      expect(
        await ctl(<String>['srs', 'decks', '--srs-profile', kJa, '--json']),
        0,
      );
      expect((jsonDecode('$out') as Map)['decks'], isNotEmpty);

      // 退出码：没点名（两份可用）409 → 75；笔记不存在 404 → 1；用法错误 64、不发请求。
      expect(await ctl(<String>['srs', 'decks']), 75);
      expect('$err', contains('profile_required'));
      expect(
        await ctl(<String>['srs', 'note', 'nope', '--srs-profile', kJa]),
        1,
      );
      expect(await ctl(<String>['srs', 'note']), 64);
      expect(await ctl(<String>['srs', 'help']), 64);
      expect('$err', contains('find-replace <find> <replace>'));
      serverLanguage = 'zh';
      expect(await ctl(<String>['srs', 'help']), 64);
      expect('$err', contains('find-replace <查找> <替换为>'));
    });

    test('写：批量改笔记预演 / 真改、合并重复、标记不是重复、保留要 --yes', () async {
      await serve(<String>[kJa]);
      serverLanguage = 'en';
      final String fish = await addNote(kJa, '魚', sentence: 'old');

      expect(
        await ctl(<String>['srs', 'set-field', 'Sentence', '--value', 'new']),
        64,
        reason: '没给 --note / --query = 不允许改全库',
      );
      expect(
        await ctl(<String>[
          'srs',
          'set-field',
          'Sentence',
          '--value',
          'new',
          '--query',
          'Sentence:old',
          '--dry-run',
        ]),
        0,
      );
      expect('$out', contains('Preview: would change 1 note(s)'));
      expect(await sentence(kJa, fish), 'old');
      expect(
        await ctl(<String>[
          'srs',
          'set-field',
          'Sentence',
          '--value',
          'new',
          '--note',
          fish,
        ]),
        0,
      );
      expect('$out', contains('Changed 1 note(s)'));
      expect(await sentence(kJa, fish), 'new');
      expect(
        await ctl(<String>[
          'srs',
          'find-replace',
          'n(e)w',
          r'$1',
          '--regex',
          '--in-field',
          'Sentence',
          '--note',
          fish,
        ]),
        0,
      );
      expect(await sentence(kJa, fish), 'e');
      expect(
        await ctl(<String>['srs', 'card-type', 'haiku', '--note', fish]),
        64,
      );
      expect(
        await ctl(<String>['srs', 'card-type', 'sentence', '--note', fish]),
        0,
      );

      final String keep = await addNote(kJa, '雪');
      final String other = await addNote(kJa, '雪');
      expect(await ctl(<String>['srs', 'merge', keep]), 64);
      expect(await ctl(<String>['srs', 'merge', keep, other]), 0);
      expect('$out', contains('Merged $other into $keep'));
      expect((await store(kJa).note(other))!.deletedAt, isNotNull);

      final String rainA = await addNote(kJa, '雨');
      final String rainB = await addNote(kJa, '雨');
      expect(await ctl(<String>['srs', 'not-duplicate', rainA]), 64);
      expect(await ctl(<String>['srs', 'not-duplicate', rainA, rainB]), 0);
      expect(await store(kJa).duplicateNoteGroups(), isEmpty);

      expect(await ctl(<String>['srs', 'conflict-keep', 'c1']), 64);
      expect('$err', contains('--yes'));
      expect(await ctl(<String>['srs', 'conflict-keep', 'c1', '--yes']), 1);
      expect(await ctl(<String>['srs', 'conflict-delete', 'c1']), 1);
      expect(
        await ctl(<String>['srs', 'conflict-resolve', 'card', 'x', 'flag']),
        64,
      );
      expect(
        await ctl(<String>[
          'srs',
          'conflict-resolve',
          'card',
          'x',
          'flag',
          '--keep',
          'current',
        ]),
        1,
      );
      // 原有的配置面动作照旧走各自的端点。
      expect(await ctl(<String>['srs', 'status']), 0);
      expect(await ctl(<String>['srs', 'profiles']), 0);
    });
  });

  group('AI 操作目录', () {
    const List<String> kDataOps = <String>[
      'server.srs.decks.list',
      'server.srs.notes.search',
      'server.srs.note.get',
      'server.srs.stats',
      'server.srs.conflicts.list',
      'server.srs.conflict.held.delete',
      'server.srs.conflict.held.keep',
      'server.srs.conflict.field.resolve',
      'server.srs.duplicates.merge',
      'server.srs.duplicates.dismiss',
      'server.srs.notes.card-type',
      'server.srs.notes.set-field',
      'server.srs.notes.find-replace',
    ];

    OpCatalog catalog() =>
        buildServerAdminOpCatalog(() => api.handle, srs: () => host.srs);

    test('接了复习库才有这组操作；没有可用的 profile 时不可用；风险分级与撤销齐全、都不常驻', () async {
      final OpCatalog without = buildServerAdminOpCatalog(() => api.handle);
      final OpCatalog with_ = catalog();
      for (final String id in kDataOps) {
        expect(without[id], isNull, reason: id);
        final FushiOp op = with_[id]!;
        expect(op.currentAvailability().isAvailable, isFalse, reason: id);
        expect(kServerAgentResidentOps, isNot(contains(id)));
        expect(
          op.params.where((OpParam p) => p.name == 'profile'),
          hasLength(1),
          reason: id,
        );
      }
      expect(with_.ops.length, without.ops.length + kDataOps.length);

      await serve(<String>[kJa]);
      for (final FushiOp op in with_.ops) {
        if (!kDataOps.contains(op.id)) continue;
        expect(op.currentAvailability().isAvailable, isTrue, reason: op.id);
        switch (op.risk) {
          case OpRisk.read:
            expect(op.undo, isNull, reason: op.id);
          case OpRisk.write:
            expect(op.undo, isNotNull, reason: op.id);
          case OpRisk.irreversible:
            expect(op.id, 'server.srs.conflict.held.keep');
            expect(op.spec.needsConfirmation, isTrue);
            expect(op.spec.gateParams.map((OpParam p) => p.name), <String>[
              kServerOpConfirmGate,
            ]);
        }
      }
    });

    test(
      '经 ServerAgentToolbox：读、写 → 记进服务端库 → 撤销写回点名的那份；被手改过 superseded',
      () async {
        await serve(<String>[kJa, kZh]);
        final String fish = await addNote(kJa, '魚', sentence: 'old');
        final String zhNote = await addNote(kZh, '鱼', sentence: 'old');
        final ServerAgentToolbox toolbox = ServerAgentToolbox(
          invoker: OpInvoker(catalog()),
          db: db,
        );

        final AgentToolResult found = await toolbox.execute(
          const AgentToolInvocation(
            sessionId: 's1',
            name: 'server.srs.notes.search',
            arguments: <String, Object?>{'profile': kJa, 'q': '魚'},
          ),
        );
        expect(found.isError, isFalse, reason: '${found.errorMessage}');
        expect((found.data! as Map)['total'], 1);
        expect(found.actionId, isNull, reason: '读操作不记撤销');

        // 两份都可用时不点名：拒绝，不猜。
        final AgentToolResult ambiguous = await toolbox.execute(
          const AgentToolInvocation(
            sessionId: 's1',
            name: 'server.srs.decks.list',
            arguments: <String, Object?>{},
          ),
        );
        expect(ambiguous.isError, isTrue);

        final AgentToolResult changed = await toolbox.execute(
          AgentToolInvocation(
            sessionId: 's1',
            name: 'server.srs.notes.set-field',
            arguments: <String, Object?>{
              'profile': kJa,
              'targetField': 'Sentence',
              'value': 'new',
              'notes': <String>[fish],
            },
          ),
        );
        expect(changed.isError, isFalse, reason: '${changed.errorMessage}');
        expect(await sentence(kJa, fish), 'new');
        expect(await sentence(kZh, zhNote), 'old');
        final AiAgentActionRow row = (await db.listAiAgentActions()).single;
        expect(row.opId, 'server.srs.notes.set-field');
        expect(
          (jsonDecode(row.undoPayloadJson!) as Map)['profile'],
          kJa,
          reason: '撤销载荷记下作用的 profile',
        );
        expect(
          (await toolbox.undo(changed.actionId!)).status,
          AgentUndoStatus.done,
        );
        expect(await sentence(kJa, fish), 'old');

        final AgentToolResult again = await toolbox.execute(
          AgentToolInvocation(
            sessionId: 's1',
            name: 'server.srs.notes.set-field',
            arguments: <String, Object?>{
              'profile': kJa,
              'targetField': 'Sentence',
              'value': 'new',
              'notes': <String>[fish],
            },
          ),
        );
        await store(kJa).updateNote(
          fish,
          fieldsById: <String, String>{
            srsLapisFieldId(kJa, 'Sentence'): '管理员手改',
          },
        );
        expect(
          (await toolbox.undo(again.actionId!)).status,
          AgentUndoStatus.superseded,
        );
        expect(await sentence(kJa, fish), '管理员手改');

        // 不可逆的「保留」：没有用户确认不执行。
        final AgentToolResult keep = await toolbox.execute(
          const AgentToolInvocation(
            sessionId: 's1',
            name: 'server.srs.conflict.held.keep',
            arguments: <String, Object?>{'profile': kJa, 'id': 'c1'},
          ),
        );
        expect(keep.errorCode, 'confirmation_required');
      },
    );

    test('操作目录的路由不经 admin API 转发（撤销载荷按这次调用取实际写下的改动）', () async {
      await serve(<String>[kJa]);
      final String fish = await addNote(kJa, '魚', sentence: 'old');
      final List<String> forwarded = <String>[];
      final OpInvoker invoker = OpInvoker(
        buildServerAdminOpCatalog(
          () => (shelf.Request r) async {
            forwarded.add('${r.method} /${r.url.path}');
            return api.handle(r);
          },
          srs: () => host.srs,
        ),
      );
      final OpInvocation done = await invoker.invoke(
        'server.srs.notes.set-field',
        <String, Object?>{
          'targetField': 'Sentence',
          'value': 'new',
          'notes': <String>[fish],
        },
        caller: OpCaller.model,
        captureUndo: true,
      );
      expect(forwarded, isEmpty);
      expect(done.undo!.payload['profile'], kJa, reason: '只有一份可用：不点名就是它');
      expect(done.undo!.payload['undo'], hasLength(1));
    });
  });
}
