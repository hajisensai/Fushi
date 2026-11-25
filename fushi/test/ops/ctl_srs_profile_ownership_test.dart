// 控制通道 `srs` 域的归属：一份 srs.db 里放两个 profile，路由装配在 A 的 store 上，调用方给出 B 的笔记 id
// ——读不到（404，与不存在的 id 同一个回答）、改不动（批量改笔记把它记进 missing，B 的字段原样）。
// 归属由 SrsDbStore 的按 id 读与内核的本机写命令把关（native/fushi_fsrs/src/store/sync2/ownership.rs），
// 路由本身不知道 profile。
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/ops/ctl_srs_routes.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_srs/fushi_srs.dart' show SrsNoteView;

import '../srs/srs_test_support.dart';

const String _kA = kSrsTestProfile;
const String _kB = '01928c3e-0000-7000-8000-0000000000b2';

/// 哪个 profile 都没有的笔记 id。
const String _kNowhere = '01928c3e-0000-7000-8000-00000000dead';

Future<Object?> _call(
  List<CtlRoute> routes,
  String method,
  String path, {
  Map<String, Object?> body = const <String, Object?>{},
}) {
  for (final CtlRoute route in routes) {
    if (route.method != method) continue;
    final Map<String, String>? params = route.match(path);
    if (params == null) continue;
    return route.handler(
      CtlCall(method: method, path: path, params: params, body: body),
    );
  }
  throw StateError('没有路由 $method $path');
}

Matcher _failure(int status) => throwsA(
  isA<CtlFailure>().having((CtlFailure f) => f.status, 'status', status),
);

/// 一个失败的调用回给调用方的 (状态码, 文案里去掉 id 之后的部分)：别人的 id 与不存在的 id 要一模一样。
Future<(int, String)> _failureOf(
  Future<Object?> Function() run,
  String id,
) async {
  try {
    await run();
  } on CtlFailure catch (f) {
    return (f.status, (f.message ?? '').replaceAll(id, '<id>'));
  }
  fail('调用成功了（期望失败）');
}

List<CtlRoute> _routesFor(SrsDbStore store) => buildSrsCtlRoutesFor(
  SrsCtlDeps(
    store: () async => store,
    moduleEnabled: () => true,
    changed: () {},
  ),
);

Future<String> _addNote(SrsDbStore s, String expression) => s.createNote(
  noteTypeId: s.lapisNoteTypeId,
  fieldsById: <String, String>{
    srsLapisFieldId(s.profileUid, 'Expression'): expression,
    srsLapisReadingFieldId(s.profileUid): 'よみ',
  },
);

/// 同一份 srs.db 上的两个 profile，各一条笔记。
class _Env {
  _Env(this.a, this.b, this.noteA, this.noteB);

  final SrsDbStore a;
  final SrsDbStore b;
  final String noteA;
  final String noteB;

  static Future<_Env> open() async {
    final SrsStorage storage = await openSrsTestStorage();
    final (FushiDatabase dbA, SrsDbStore a) = await openSrsTestStore(
      storage: storage,
      profileUid: _kA,
      deviceId: 'dev',
    );
    addTearDown(dbA.close);
    final (FushiDatabase dbB, SrsDbStore b) = await openSrsTestStore(
      storage: storage,
      profileUid: _kB,
      deviceId: 'dev',
    );
    addTearDown(dbB.close);
    return _Env(a, b, await _addNote(a, '甲の語'), await _addNote(b, '乙の語'));
  }

  Future<String> expressionB() async {
    final SrsNoteView? n = await b.note(noteB);
    return n!.field(srsLapisFieldId(_kB, 'Expression'));
  }
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  test('读一条笔记：别的 profile 的 id 与不存在的 id 同一个 404', () async {
    final _Env env = await _Env.open();
    final List<CtlRoute> routes = _routesFor(env.a);
    final (int, String) theirs = await _failureOf(
      () => _call(routes, 'GET', '$kSrsCtlRoot/notes/${env.noteB}'),
      env.noteB,
    );
    final (int, String) nowhere = await _failureOf(
      () => _call(routes, 'GET', '$kSrsCtlRoot/notes/$_kNowhere'),
      _kNowhere,
    );
    expect(theirs.$1, 404);
    expect(theirs, nowhere);
  });

  test('批量改字段 / 查找替换：别的 profile 的笔记进 missing，一个字都不改', () async {
    final _Env env = await _Env.open();
    final List<CtlRoute> routes = _routesFor(env.a);
    final String revB = await env.b.changeFingerprint();

    final Map<String, Object?> set =
        await _call(
              routes,
              'POST',
              '$kSrsCtlRoot/notes/batch/set-field',
              body: <String, Object?>{
                'notes': <String>[env.noteB],
                'targetField': 'Expression',
                'value': 'hijacked',
              },
            )
            as Map<String, Object?>;
    expect(set['missing'], <String>[env.noteB]);
    expect(set['fieldChanges'], 0);

    final Map<String, Object?> replaced =
        await _call(
              routes,
              'POST',
              '$kSrsCtlRoot/notes/batch/find-replace',
              body: <String, Object?>{
                'notes': <String>[env.noteB],
                'find': '乙',
                'replace': 'hijacked',
              },
            )
            as Map<String, Object?>;
    expect(replaced['missing'], <String>[env.noteB]);
    expect(replaced['fieldChanges'], 0);

    expect(await env.expressionB(), '乙の語');
    expect(await env.b.changeFingerprint(), revB);
  });

  test('重复笔记合并 / 标记不是重复：带上别的 profile 的笔记 → 404，两边都原样', () async {
    final _Env env = await _Env.open();
    final List<CtlRoute> routes = _routesFor(env.a);
    await expectLater(
      _call(
        routes,
        'POST',
        '$kSrsCtlRoot/duplicates/merge',
        body: <String, Object?>{
          'keep': env.noteA,
          'absorb': <String>[env.noteB],
        },
      ),
      _failure(404),
    );
    await expectLater(
      _call(
        routes,
        'POST',
        '$kSrsCtlRoot/duplicates/merge',
        body: <String, Object?>{
          'keep': env.noteB,
          'absorb': <String>[env.noteA],
        },
      ),
      _failure(404),
    );
    await expectLater(
      _call(
        routes,
        'POST',
        '$kSrsCtlRoot/duplicates/dismiss',
        body: <String, Object?>{
          'notes': <String>[env.noteA, env.noteB],
        },
      ),
      _failure(404),
    );
    expect((await env.a.note(env.noteA))!.deletedAt, isNull);
    expect((await env.b.note(env.noteB))!.deletedAt, isNull);
    expect(await env.expressionB(), '乙の語');
  });

  test('自己的笔记：读得到、批量改得动（另一个 profile 的同名字段不受影响）', () async {
    final _Env env = await _Env.open();
    final List<CtlRoute> routes = _routesFor(env.a);
    final Map<String, Object?> got =
        await _call(routes, 'GET', '$kSrsCtlRoot/notes/${env.noteA}')
            as Map<String, Object?>;
    expect((got['fields']! as Map<String, String>)['Expression'], '甲の語');

    final Map<String, Object?> set =
        await _call(
              routes,
              'POST',
              '$kSrsCtlRoot/notes/batch/set-field',
              body: <String, Object?>{
                'notes': <String>[env.noteA, env.noteB],
                'targetField': 'Expression',
                'value': '改めた',
              },
            )
            as Map<String, Object?>;
    expect(set['fieldChanges'], 1);
    expect(set['missing'], <String>[env.noteB]);
    final SrsNoteView? mine = await env.a.note(env.noteA);
    expect(mine!.field(srsLapisFieldId(_kA, 'Expression')), '改めた');
    expect(await env.expressionB(), '乙の語');
  });
}
