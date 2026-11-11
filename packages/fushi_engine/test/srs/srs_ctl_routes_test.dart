// 复习（SRS）控制通道路由与操作描述的共用实现（srs_ctl_routes.dart / srs_ctl_ops.dart）：app 与无头服务端
// 都只是往里注入一个 SrsCtlHost。这里对真 SrsDbStore（临时 srs.db，一份库上开两份 profile）跑：
// - 路由本体：查询、冲突中心、重复笔记、批量改笔记；
// - 多 profile 宿主：`profile` 参数（query / body）点名哪一份，两份互不串；宿主的拒绝原样抛出；写后通知带着
//   这次作用的 profile；
// - 操作目录：每条路由都有描述、id 前缀与追加参数生效；写操作的撤销载荷里带 profile，撤销回到同一份
//   （哪怕宿主的「没点名」解析之后变了）；单库宿主（app）的载荷不带这个键。
// app 侧的同一批行为（单库装配）仍由 fushi/test/ops/ctl_srs_routes_test.dart、op_undo_srs_test.dart、
// op_srs_note_batch_test.dart 覆盖。
import 'dart:convert';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_ctl_ops.dart';
import 'package:fushi_engine/srs/srs_ctl_routes.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_duplicate_notes.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:test/test.dart';

import 'support/srs_test_storage.dart';

const String kJa = '01928c3e-0000-7000-8000-0000000000a1';
const String kZh = '01928c3e-0000-7000-8000-0000000000b2';

Map<String, Object?> _map(Object? v) => Map<String, Object?>.from(v! as Map);

List<Map<String, Object?>> _rows(Object? v) => <Map<String, Object?>>[
  for (final Object? row in v! as List<Object?>) _map(row),
];

Matcher _failure(int status, [String? code]) => throwsA(
  isA<CtlFailure>()
      .having((CtlFailure f) => f.status, 'status', status)
      .having((CtlFailure f) => f.code, 'code', code ?? anything),
);

/// 按 `METHOD path` 找路由并调用（GET 的参数走 query，其余走 body——与 HTTP 入口同形）。
Future<Object?> _call(
  List<CtlRoute> routes,
  String method,
  String path, [
  Map<String, Object?> args = const <String, Object?>{},
]) {
  for (final CtlRoute route in routes) {
    if (route.method != method) continue;
    final Map<String, String>? params = route.match(path);
    if (params == null) continue;
    return route.handler(
      method == 'GET'
          ? CtlCall(
              method: method,
              path: path,
              params: params,
              query: <String, String>{
                for (final MapEntry<String, Object?> e in args.entries)
                  e.key: '${e.value}',
              },
            )
          : CtlCall(method: method, path: path, params: params, body: args),
    );
  }
  throw StateError('没有路由 $method $path');
}

/// 一份 srs.db 上的两份 profile + 多 profile 宿主（与无头服务端同形：点名取那份，没点名取 [fallback]）。
class _Env {
  _Env(this.ja, this.zh);

  final SrsDbStore ja;
  final SrsDbStore zh;

  /// 没点名时解析到哪份（null = 拒绝，要求点名）。
  String? fallback;

  /// 写后通知收到的 profile。
  final List<String?> changed = <String?>[];

  SrsDbStore of(String uid) => uid == kJa ? ja : zh;

  late final SrsCtlHost host = SrsCtlHost(
    open: (String? profile) async {
      final String? uid = profile ?? fallback;
      if (uid == null) {
        throw const CtlFailure(409, 'profile_required', 'profile_required');
      }
      if (uid != kJa && uid != kZh) {
        throw const CtlFailure(404, 'profile_not_served', 'profile_not_served');
      }
      return SrsCtlTarget(of(uid), profile: uid);
    },
    changed: (SrsCtlTarget target) => changed.add(target.profile),
  );

  late final List<CtlRoute> routes = srsCtlRoutes(host);

  static Future<_Env> open() async {
    final SrsStorage st = await openTestSrsStorage();
    Future<SrsDbStore> store(String uid) => SrsDbStore.open(
      db: st.db,
      core: st.core,
      profileUid: uid,
      deviceId: 'dev',
    );
    return _Env(await store(kJa), await store(kZh));
  }
}

Future<String> _addNote(
  SrsDbStore s,
  String expression, {
  String sentence = '',
}) => s.createNote(
  noteTypeId: s.lapisNoteTypeId,
  fieldsById: <String, String>{
    srsLapisFieldId(s.profileUid, 'Expression'): expression,
    if (sentence.isNotEmpty)
      srsLapisFieldId(s.profileUid, 'Sentence'): sentence,
  },
);

Future<String> _field(SrsDbStore s, String noteId, String key) async =>
    (await s.note(noteId))!.field(srsLapisFieldId(s.profileUid, key));

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('路由：查询', () {
    late _Env env;
    late String fish;

    setUp(() async {
      env = await _Env.open();
      fish = await _addNote(env.ja, '魚', sentence: '魚を食べる');
      await _addNote(env.ja, '犬');
      await _addNote(env.zh, '吃饭');
    });

    test('decks / notes / note / stats 读的是点名的那一份，两份互不串', () async {
      final List<Map<String, Object?>> decks = _rows(
        _map(
          await _call(
            env.routes,
            'GET',
            '$kSrsCtlRoot/decks',
            <String, Object?>{'profile': kJa},
          ),
        )['decks'],
      );
      expect(decks, isNotEmpty);
      expect(
        decks.fold<int>(
          0,
          (int sum, Map<String, Object?> d) =>
              sum + (d['depth'] == 0 ? d['new']! as int : 0),
        ),
        greaterThanOrEqualTo(2),
      );

      Future<Map<String, Object?>> search(Map<String, Object?> args) async =>
          _map(await _call(env.routes, 'GET', '$kSrsCtlRoot/notes', args));

      final Map<String, Object?> ja = await search(<String, Object?>{
        'profile': kJa,
      });
      expect(ja['total'], 2);
      expect(ja['mode'], 'notes');
      final Map<String, Object?> zh = await search(<String, Object?>{
        'profile': kZh,
      });
      expect(zh['total'], 1);
      expect(_rows(zh['items']).single['sortField'], '吃饭');

      final Map<String, Object?> hit = await search(<String, Object?>{
        'profile': kJa,
        'q': '魚',
      });
      expect(_rows(hit['items']).single['noteId'], fish);
      expect(
        (await search(<String, Object?>{
          'profile': kJa,
          'field': 'Expression',
          'q': '犬',
        }))['total'],
        1,
      );
      expect(
        (await search(<String, Object?>{
          'profile': kJa,
          'field': 'Expression',
          'q': '食べる',
        }))['total'],
        0,
        reason: '例句不在 Expression 字段里',
      );
      final Map<String, Object?> cards = await search(<String, Object?>{
        'profile': kJa,
        'q': '魚',
        'mode': 'cards',
        'limit': 1,
      });
      expect(_rows(cards['items']).single['cardId'], isNotNull);
      await expectLater(
        search(<String, Object?>{'profile': kJa, 'mode': 'x'}),
        _failure(400),
      );

      final Map<String, Object?> note = _map(
        await _call(
          env.routes,
          'GET',
          '$kSrsCtlRoot/notes/$fish',
          <String, Object?>{'profile': kJa},
        ),
      );
      expect(_map(note['fields'])['Expression'], '魚');
      expect(_map(note['fields'])['Sentence'], '魚を食べる');
      expect(note['cards'], isNotEmpty);
      // 同一个 id 在另一份 profile 里不存在。
      await expectLater(
        _call(env.routes, 'GET', '$kSrsCtlRoot/notes/$fish', <String, Object?>{
          'profile': kZh,
        }),
        _failure(404),
      );

      final Map<String, Object?> stats = _map(
        await _call(env.routes, 'GET', '$kSrsCtlRoot/stats', <String, Object?>{
          'profile': kJa,
        }),
      );
      expect(_map(stats['cards'])['total'], greaterThanOrEqualTo(2));
      expect(_map(stats['today'])['reviews'], 0);
      await expectLater(
        _call(env.routes, 'GET', '$kSrsCtlRoot/stats', <String, Object?>{
          'profile': kJa,
          'deck': 'no such deck',
        }),
        _failure(404),
      );
      expect(env.changed, isEmpty, reason: '只读路由不发写后通知');
    });

    test('宿主的拒绝原样抛出：没点名 / 没提供的 profile', () async {
      await expectLater(
        _call(env.routes, 'GET', '$kSrsCtlRoot/decks'),
        _failure(409, 'profile_required'),
      );
      await expectLater(
        _call(env.routes, 'GET', '$kSrsCtlRoot/conflicts', <String, Object?>{
          'profile': '01928c3e-0000-7000-8000-0000000000ff',
        }),
        _failure(404, 'profile_not_served'),
      );
      env.fallback = kZh;
      expect(
        _map(await _call(env.routes, 'GET', '$kSrsCtlRoot/notes'))['total'],
        1,
        reason: '没点名时用宿主解析出的那份',
      );
    });
  });

  group('路由：重复笔记与批量改笔记', () {
    late _Env env;

    setUp(() async => env = await _Env.open());

    test('conflicts 列出重复建议；merge 写的是点名的那份并通知；dismiss 之后建议消失', () async {
      final String keep = await _addNote(env.ja, '雪');
      final String other = await _addNote(env.ja, '雪');
      final String rainA = await _addNote(env.ja, '雨');
      final String rainB = await _addNote(env.ja, '雨');
      const Map<String, Object?> ja = <String, Object?>{'profile': kJa};

      Future<List<Map<String, Object?>>> duplicates() async => _rows(
        _map(
          await _call(env.routes, 'GET', '$kSrsCtlRoot/conflicts', ja),
        )['duplicates'],
      );

      expect(await duplicates(), hasLength(2));
      expect(
        _rows(
          _map(
            await _call(
              env.routes,
              'GET',
              '$kSrsCtlRoot/conflicts',
              <String, Object?>{'profile': kZh},
            ),
          )['duplicates'],
        ),
        isEmpty,
      );

      await expectLater(
        _call(
          env.routes,
          'POST',
          '$kSrsCtlRoot/duplicates/merge',
          <String, Object?>{
            ...ja,
            'keep': keep,
            'absorb': <String>[keep],
          },
        ),
        _failure(400),
      );
      await expectLater(
        _call(
          env.routes,
          'POST',
          '$kSrsCtlRoot/duplicates/merge',
          <String, Object?>{
            ...ja,
            'keep': keep,
            'absorb': <String>['nope'],
          },
        ),
        _failure(404),
      );
      expect(env.changed, isEmpty, reason: '被拒的写不发通知');

      final Map<String, Object?> merged = _map(
        await _call(
          env.routes,
          'POST',
          '$kSrsCtlRoot/duplicates/merge',
          <String, Object?>{
            ...ja,
            'keep': keep,
            'absorb': <String>[other],
          },
        ),
      );
      expect(merged['absorbed'], <String>[other]);
      expect(merged['linkedCards'], 1);
      expect(env.changed, <String?>[kJa]);
      expect((await env.ja.note(other))?.deletedAt, isNotNull);
      expect(await duplicates(), hasLength(1));

      await expectLater(
        _call(
          env.routes,
          'POST',
          '$kSrsCtlRoot/duplicates/dismiss',
          <String, Object?>{
            ...ja,
            'notes': <String>[rainA],
          },
        ),
        _failure(400),
      );
      await _call(
        env.routes,
        'POST',
        '$kSrsCtlRoot/duplicates/dismiss',
        <String, Object?>{
          ...ja,
          'notes': <String>[rainA, rainB],
        },
      );
      expect(await duplicates(), isEmpty);
      expect((await env.ja.note(rainB))!.deletedAt, isNull);
      expect(env.changed, <String?>[kJa, kJa]);
    });

    test('被扣住的删除 / 被覆盖的标志：不存在的冲突 404', () async {
      const Map<String, Object?> ja = <String, Object?>{'profile': kJa};
      await expectLater(
        _call(
          env.routes,
          'POST',
          '$kSrsCtlRoot/conflicts/held/nope/delete',
          ja,
        ),
        _failure(404),
      );
      await expectLater(
        _call(env.routes, 'POST', '$kSrsCtlRoot/conflicts/held/nope/keep', ja),
        _failure(404),
      );
      await expectLater(
        _call(
          env.routes,
          'POST',
          '$kSrsCtlRoot/conflicts/fields/resolve',
          <String, Object?>{
            ...ja,
            'kind': 'card',
            'entity': 'nope',
            'key': 'flag',
            'keep': 'current',
          },
        ),
        _failure(404),
      );
      await expectLater(
        _call(
          env.routes,
          'POST',
          '$kSrsCtlRoot/conflicts/fields/resolve',
          <String, Object?>{
            ...ja,
            'kind': 'card',
            'entity': 'nope',
            'key': 'flag',
            'keep': 'both',
          },
        ),
        _failure(400),
      );
    });

    test('批量改笔记：预演不写；没给目标 400；真改只动点名那份里的笔记', () async {
      final String ja = await _addNote(env.ja, '魚', sentence: 'old');
      final String zh = await _addNote(env.zh, '鱼', sentence: 'old');
      const String path = '$kSrsCtlRoot/notes/batch/set-field';

      await expectLater(
        _call(env.routes, 'POST', path, <String, Object?>{
          'profile': kJa,
          'targetField': 'Sentence',
          'value': 'new',
        }),
        _failure(400),
        reason: '不给 notes / 查询 = 不允许改全库',
      );

      final Map<String, Object?> preview = _map(
        await _call(env.routes, 'POST', path, <String, Object?>{
          'profile': kJa,
          'targetField': 'Sentence',
          'value': 'new',
          'q': 'Sentence:old',
          'dryRun': true,
        }),
      );
      expect(preview['dryRun'], isTrue);
      expect(preview['notes'], 1);
      expect(_rows(preview['sample']).single['after'], 'new');
      expect(await _field(env.ja, ja, 'Sentence'), 'old');
      expect(env.changed, isEmpty);

      final Map<String, Object?> done = _map(
        await _call(env.routes, 'POST', path, <String, Object?>{
          'profile': kJa,
          'targetField': 'Sentence',
          'value': 'new',
          'q': 'Sentence:old',
        }),
      );
      expect(done['dryRun'], isFalse);
      expect(done['notes'], 1);
      expect(await _field(env.ja, ja, 'Sentence'), 'new');
      expect(await _field(env.zh, zh, 'Sentence'), 'old');
      expect(env.changed, <String?>[kJa]);

      final Map<String, Object?> replaced = _map(
        await _call(
          env.routes,
          'POST',
          '$kSrsCtlRoot/notes/batch/find-replace',
          <String, Object?>{
            'profile': kZh,
            'notes': <String>[zh],
            'find': 'o(l)d',
            'replace': r'$1',
            'regex': true,
          },
        ),
      );
      expect(replaced['fieldChanges'], 1);
      expect(await _field(env.zh, zh, 'Sentence'), 'l');
      await expectLater(
        _call(
          env.routes,
          'POST',
          '$kSrsCtlRoot/notes/batch/find-replace',
          <String, Object?>{
            'profile': kZh,
            'notes': <String>[zh],
            'find': '(',
            'replace': '',
            'regex': true,
          },
        ),
        _failure(400),
      );
      await expectLater(
        _call(
          env.routes,
          'POST',
          '$kSrsCtlRoot/notes/batch/card-type',
          <String, Object?>{
            'profile': kZh,
            'notes': <String>[zh],
            'type': 'haiku',
          },
        ),
        _failure(400),
      );
    });

    // BUG-4387：SrsDbStore 按 id 的读写不看 profile。多 profile 宿主点名 A 却给 B 的 id 时路由先拦。
    test('点名的 profile 里没有这些笔记（id 是另一份的）：一律 404，两份都没被动过', () async {
      final String ja = await _addNote(env.ja, '魚', sentence: 'old');
      final String dupA = await _addNote(env.ja, '雪');
      final String dupB = await _addNote(env.ja, '雪');
      final String zh = await _addNote(env.zh, '鱼', sentence: 'old');
      Future<Object?> edits() async =>
          (await env.ja.db
                  .customSelect('SELECT COUNT(*) AS c FROM srs_field_edits')
                  .getSingle())
              .data['c'];
      final Object? editsBefore = await edits();

      Future<Object?> asZh(String path, Map<String, Object?> body) => _call(
        env.routes,
        'POST',
        '$kSrsCtlRoot/$path',
        <String, Object?>{'profile': kZh, ...body},
      );

      await expectLater(
        asZh('notes/batch/set-field', <String, Object?>{
          'targetField': 'Sentence',
          'value': 'X',
          // 自己那份的笔记混着别人的：整批拒绝，自己的也不写。
          'notes': <String>[zh, ja],
        }),
        _failure(404),
      );
      await expectLater(
        asZh('notes/batch/set-field', <String, Object?>{
          'targetField': 'Sentence',
          'value': 'X',
          'notes': <String>[ja],
          'dryRun': true,
        }),
        _failure(404),
        reason: '预演也不读别人的笔记',
      );
      await expectLater(
        asZh('notes/batch/find-replace', <String, Object?>{
          'find': 'old',
          'replace': 'X',
          'notes': <String>[ja],
        }),
        _failure(404),
      );
      await expectLater(
        asZh('notes/batch/card-type', <String, Object?>{
          'type': 'sentence',
          'notes': <String>[ja],
        }),
        _failure(404),
      );
      await expectLater(
        asZh('duplicates/merge', <String, Object?>{
          'keep': dupA,
          'absorb': <String>[dupB],
        }),
        _failure(404),
      );
      await expectLater(
        asZh('duplicates/dismiss', <String, Object?>{
          'notes': <String>[dupA, dupB],
        }),
        _failure(404),
      );

      expect(env.changed, isEmpty);
      expect(await _field(env.ja, ja, 'Sentence'), 'old');
      expect(await _field(env.zh, zh, 'Sentence'), 'old');
      expect((await env.ja.note(dupB))!.deletedAt, isNull);
      expect(await env.ja.duplicateNoteGroups(), hasLength(1));
      expect(await edits(), editsBefore, reason: '没有往任何一份写修改记录');

      // 库里根本没有的 id 不归这道核对管：照各路由原来的处理。
      final Map<String, Object?> missing = _map(
        await asZh('notes/batch/set-field', <String, Object?>{
          'targetField': 'Sentence',
          'value': 'X',
          'notes': <String>['01928c3e-0000-7000-8000-00000000dead'],
        }),
      );
      expect(missing['fieldChanges'], 0);
      expect(await edits(), editsBefore);
    });
  });

  group('操作目录', () {
    late _Env env;

    const OpParam profileParam = OpParam.string(
      'profile',
      description: 'Profile uid.',
    );

    OpCatalog catalogOf(SrsCtlHost host, {bool available = true}) =>
        OpCatalog.build(
          srsCtlRoutes(host),
          srsCtlOpDescriptions(
            host,
            idPrefix: 'server.',
            availability: () => available
                ? const OpAvailability.available()
                : const OpAvailability.unavailable('srs_unavailable'),
            scopeParams: const <OpParam>[profileParam],
          ),
        );

    Map<String, Object?> roundTrip(OpUndoRecord record) =>
        jsonDecode(jsonEncode(record.payload)) as Map<String, Object?>;

    setUp(() async => env = await _Env.open());

    test('每条路由都有描述；id 带前缀、每条都带追加的参数；写操作要么可撤销要么不可逆且带表态参数', () {
      final OpCatalog catalog = catalogOf(env.host);
      final List<CtlRoute> routes = srsCtlRoutes(env.host);
      expect(catalog.ops, hasLength(routes.length));
      expect(
        <String>{
          for (final FushiOp op in catalog.ops)
            '${op.route.method} ${op.route.pattern}',
        },
        <String>{for (final CtlRoute r in routes) '${r.method} ${r.pattern}'},
      );
      expect(
        <String>[for (final FushiOp op in catalog.ops) op.id],
        <String>[
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
        ],
      );
      for (final FushiOp op in catalog.ops) {
        expect(
          op.params.where((OpParam p) => p.name == 'profile'),
          hasLength(1),
          reason: op.id,
        );
        expect(op.currentAvailability().isAvailable, isTrue, reason: op.id);
        switch (op.risk) {
          case OpRisk.read:
            expect(op.route.method, 'GET', reason: op.id);
            expect(op.undo, isNull, reason: op.id);
          case OpRisk.write:
            expect(op.undo, isNotNull, reason: op.id);
          case OpRisk.irreversible:
            expect(op.id, 'server.srs.conflict.held.keep');
            expect(op.spec.gateParams.map((OpParam p) => p.name), <String>[
              'confirm',
            ]);
        }
        // 说明文字里引用的别的操作 id 也带前缀（不留指向不存在的 `srs.x` 的引用）。
        for (final String text in <String>[
          op.summary,
          for (final OpParam p in op.params) p.description,
        ]) {
          expect(
            RegExp(r'(?<![.\w])srs\.[a-z]').hasMatch(text),
            isFalse,
            reason: '${op.id}: $text',
          );
        }
      }
      expect(
        catalogOf(
          env.host,
          available: false,
        ).ops.every((FushiOp op) => !op.currentAvailability().isAvailable),
        isTrue,
      );

      // 不带前缀 / 追加参数（app 的装配）：id 与参数原样。
      final OpCatalog plain = OpCatalog.build(
        routes,
        srsCtlOpDescriptions(env.host),
      );
      expect(plain['srs.notes.search'], isNotNull);
      expect(
        plain['srs.notes.search']!.params.any(
          (OpParam p) => p.name == 'profile',
        ),
        isFalse,
      );
      expect(plain['srs.note.get']!.currentAvailability().isAvailable, isTrue);
    });

    test('批量改笔记：撤销载荷带 profile，撤销回到同一份——哪怕「没点名」之后解析到了别的', () async {
      final OpInvoker invoker = OpInvoker(catalogOf(env.host));
      final String ja = await _addNote(env.ja, '魚', sentence: 'old');
      final String zh = await _addNote(env.zh, '鱼', sentence: 'old');

      // 没点名：宿主此刻解析到日语那份。
      env.fallback = kJa;
      final OpInvocation done = await invoker.invoke(
        'server.srs.notes.set-field',
        <String, Object?>{
          'targetField': 'Sentence',
          'value': 'new',
          'q': 'Sentence:old',
        },
        caller: OpCaller.model,
        captureUndo: true,
      );
      expect(_map(done.result)['notes'], 1);
      expect(await _field(env.ja, ja, 'Sentence'), 'new');
      expect(await _field(env.zh, zh, 'Sentence'), 'old');
      final Map<String, Object?> payload = roundTrip(done.undo!);
      expect(payload['profile'], kJa);
      expect(payload['notes'], 1);

      // 之后「没点名」变成解析到中文那份：撤销仍然回日语那份。
      env.fallback = kZh;
      env.changed.clear();
      final OpUndoOutcome outcome = await invoker
          .catalog['server.srs.notes.set-field']!
          .undo!
          .revert(payload);
      expect(outcome.status, OpUndoStatus.done);
      expect(await _field(env.ja, ja, 'Sentence'), 'old');
      expect(await _field(env.zh, zh, 'Sentence'), 'old');
      expect(env.changed, <String?>[kJa]);

      // 预演不写入：载荷为空，撤销是空操作。
      final OpInvocation preview = await invoker.invoke(
        'server.srs.notes.set-field',
        <String, Object?>{
          'profile': kZh,
          'targetField': 'Sentence',
          'value': 'x',
          'notes': <String>[zh],
          'dryRun': true,
        },
        caller: OpCaller.model,
        captureUndo: true,
      );
      expect(roundTrip(preview.undo!)['undo'], isEmpty);
    });

    test('合并 / 不是重复：撤销拆回原样；之后又被改过的字段保留现值、报 partial', () async {
      final OpInvoker invoker = OpInvoker(catalogOf(env.host));
      final String keep = await _addNote(env.zh, '雪');
      final String other = await _addNote(env.zh, '雪', sentence: '下雪了');

      final OpInvocation merged = await invoker.invoke(
        'server.srs.duplicates.merge',
        <String, Object?>{
          'profile': kZh,
          'keep': keep,
          'absorb': <String>[other],
        },
        caller: OpCaller.model,
        captureUndo: true,
      );
      expect(await _field(env.zh, keep, 'Sentence'), '下雪了', reason: '空字段补齐');
      expect((await env.zh.note(other))?.deletedAt, isNotNull);
      final Map<String, Object?> payload = roundTrip(merged.undo!);
      expect(payload['profile'], kZh);
      final OpUndo undo = invoker.catalog['server.srs.duplicates.merge']!.undo!;
      expect((await undo.revert(payload)).status, OpUndoStatus.done);
      expect(await _field(env.zh, keep, 'Sentence'), '');
      expect((await env.zh.note(other))!.deletedAt, isNull);
      expect(await env.zh.duplicateNoteGroups(), hasLength(1));

      final OpInvocation again = await invoker.invoke(
        'server.srs.duplicates.merge',
        <String, Object?>{
          'profile': kZh,
          'keep': keep,
          'absorb': <String>[other],
        },
        caller: OpCaller.model,
        captureUndo: true,
      );
      await env.zh.updateNote(
        keep,
        fieldsById: <String, String>{srsLapisFieldId(kZh, 'Sentence'): '手动改过'},
      );
      // 撤销凭据按字段键裁决（srs_edit_undo.dart）：被改过的那个字段保留现值，其余键照样撤回 → partial。
      expect(
        (await undo.revert(roundTrip(again.undo!))).status,
        OpUndoStatus.partial,
      );
      expect(await _field(env.zh, keep, 'Sentence'), '手动改过');

      final String rainA = await _addNote(env.zh, '雨');
      final String rainB = await _addNote(env.zh, '雨');
      final OpInvocation dismissed = await invoker.invoke(
        'server.srs.duplicates.dismiss',
        <String, Object?>{
          'profile': kZh,
          'notes': <String>[rainA, rainB],
        },
        caller: OpCaller.model,
        captureUndo: true,
      );
      expect(await env.zh.duplicateNoteGroups(), isEmpty);
      final Map<String, Object?> dismissPayload = roundTrip(dismissed.undo!);
      expect(dismissPayload['profile'], kZh);
      expect(
        (await invoker.catalog['server.srs.duplicates.dismiss']!.undo!.revert(
          dismissPayload,
        )).status,
        OpUndoStatus.done,
      );
      expect(await env.zh.duplicateNoteGroups(), hasLength(1));
    });

    test('撤销时那份库取不到 → failed，不抛；保留被扣住的删除没有表态参数时模型给不出来', () async {
      final OpInvoker invoker = OpInvoker(catalogOf(env.host));
      final String note = await _addNote(env.ja, '魚', sentence: 'old');
      final OpInvocation done = await invoker.invoke(
        'server.srs.notes.set-field',
        <String, Object?>{
          'profile': kJa,
          'targetField': 'Sentence',
          'value': 'new',
          'notes': <String>[note],
        },
        caller: OpCaller.model,
        captureUndo: true,
      );
      final Map<String, Object?> payload = roundTrip(done.undo!)
        ..['profile'] = '01928c3e-0000-7000-8000-0000000000ff';
      final OpUndoOutcome outcome = await invoker
          .catalog['server.srs.notes.set-field']!
          .undo!
          .revert(payload);
      expect(outcome.status, OpUndoStatus.superseded, reason: '404 = 对象已不在');
      expect(await _field(env.ja, note, 'Sentence'), 'new');

      await expectLater(
        invoker.invoke('server.srs.conflict.held.keep', <String, Object?>{
          'profile': kJa,
          'id': 'x',
          'confirm': true,
        }, caller: OpCaller.model),
        _failure(400),
        reason: '表态参数只能由运行时在用户确认后注入',
      );
    });

    test('单库宿主（app 的装配）：载荷不带 profile，撤销照常', () async {
      int changed = 0;
      final SrsCtlHost single = SrsCtlHost(
        open: (String? profile) async => SrsCtlTarget(env.ja),
        changed: (SrsCtlTarget target) => changed++,
      );
      final OpInvoker invoker = OpInvoker(
        OpCatalog.build(srsCtlRoutes(single), srsCtlOpDescriptions(single)),
      );
      final String note = await _addNote(env.ja, '魚', sentence: 'old');
      final OpInvocation done = await invoker.invoke(
        'srs.notes.set-field',
        <String, Object?>{
          'targetField': 'Sentence',
          'value': 'new',
          'notes': <String>[note],
        },
        caller: OpCaller.model,
        captureUndo: true,
      );
      final Map<String, Object?> payload = roundTrip(done.undo!);
      expect(payload.containsKey('profile'), isFalse);
      expect(payload.keys.toSet(), <String>{'notes', 'undo'});
      expect(changed, 1);
      expect(
        (await invoker.catalog['srs.notes.set-field']!.undo!.revert(
          payload,
        )).status,
        OpUndoStatus.done,
      );
      expect(await _field(env.ja, note, 'Sentence'), 'old');
      expect(changed, 2);
    });
  });
}
