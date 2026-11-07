// 远程复习库的主机侧（docs/specs/2026-11-01-srs-remote-review-design.md）：
// - 线格式还原出的视图（笔记 / 笔记类型 / 牌组树 / 历史 / 预览 / 牌组行）与主机上直接读到的逐项相同；
// - 写操作同一请求 id 重发只执行一次；作答带基准时卡变了回 stale；
// - 主机切了配置回 profile_changed；路由的错误码。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_core/fushi_core.dart' show SrsCardCacheRow;
import 'package:fushi_engine/srs/apkg/srs_apkg_import.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_remote_store.dart';
import 'package:fushi_engine/srs/srs_remote_store_routes.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:test/test.dart';

import 'apkg/apkg_test_support.dart';
import 'apkg/srs_apkg_import_bench_test.dart' show benchApkg;
import 'apkg/srs_apkg_import_test.dart' show kFullOptions;

const String _uid = '01928c3e-0000-7000-8000-0000000a5e02';

Future<(SrsDbStore, SrsRemoteStoreService, String)> _setUp({
  void Function(String profileUid)? onWrite,
}) async {
  int clock = DateTime.utc(2026, 11, 1, 12).millisecondsSinceEpoch;
  final SrsDbStore store = await openTestStore(
    profileUid: _uid,
    deviceId: 'host',
    now: () => clock += 1000,
  );
  await importAnkiPackage(
    store: store,
    bytes: benchApkg(6),
    storeMedia: (String name, Uint8List b) async => name,
    options: kFullOptions,
    zstdDecompress: (Uint8List b) => null,
  );
  final SrsRemoteStoreService service = SrsRemoteStoreService(
    readStore: () async => store,
    readMedia: (String name) async =>
        name == 'a.png' ? Uint8List.fromList(<int>[1, 2, 3]) : null,
    onWrite: onWrite,
  );
  final String deck = (await store.deckSummaries())
      .where((SrsDeckSummary d) => d.totalCards > 0)
      .first
      .deck
      .id;
  return (store, service, deck);
}

/// 经路由走一遍 JSON（与真实网络同一份编码），返回整个回包。
Future<(int, Map<String, Object?>)> _route(
  SrsRemoteStoreService service,
  Map<String, Object?> body,
) async {
  final shelf.Response res = await handleSrsRemoteStoreRequest(
    service,
    shelf.Request(
      'POST',
      Uri.parse('http://host/api/srs/remote/call'),
      body: jsonEncode(body),
    ),
    'POST',
    '/api/srs/remote/call',
  );
  return (
    res.statusCode,
    (jsonDecode(await res.readAsString()) as Map).cast<String, Object?>(),
  );
}

Future<Object?> _call(
  SrsRemoteStoreService service,
  String op, [
  Map<String, Object?> args = const <String, Object?>{},
  String? request,
]) async {
  final (int status, Map<String, Object?> body) = await _route(
    service,
    <String, Object?>{
      'profile': _uid,
      'op': op,
      'args': args,
      'request': ?request,
    },
  );
  expect(status, 200, reason: '$op → $body');
  return body['result'];
}

void main() {
  test('牌组行线格式往返保留 RWKV 状态（rp / rs）', () async {
    final SrsDbStore store = await openTestStore(
      profileUid: _uid,
      deviceId: 'wire',
      now: () => DateTime.utc(2026, 11, 1, 12).millisecondsSinceEpoch,
    );
    final SrsDeckTree tree = await store.deckTree();
    final SrsDeckView deck = tree[store.defaultDeckId]!;
    SrsDeckSummary row({required bool pending, required bool scheduled}) =>
        SrsDeckSummary(
          deck: deck,
          fullName: 'Default',
          depth: 0,
          newCount: 1,
          learnCount: 2,
          reviewCount: 7,
          newBudget: const SrsNewCardBudget(
            limit: 20,
            allowed: 20,
            reviewBudget: 100,
            reason: null,
          ),
          totalCards: 30,
          rwkvPending: pending,
          rwkvScheduled: scheduled,
        );
    for (final SrsDeckSummary s in <SrsDeckSummary>[
      row(pending: true, scheduled: true),
      row(pending: false, scheduled: true),
      row(pending: false, scheduled: false),
    ]) {
      final SrsDeckSummary back = SrsRemoteWire.summaryFrom(
        jsonDecode(jsonEncode(SrsRemoteWire.summary(s))),
        tree,
      )!;
      expect(back.rwkvPending, s.rwkvPending);
      expect(back.rwkvScheduled, s.rwkvScheduled);
      expect(back.reviewCount, s.reviewCount);
    }
  });

  test('握手回包带主机的修订号、牌组树标签、时钟与排程能力', () async {
    final (SrsDbStore store, SrsRemoteStoreService service, _) = await _setUp();
    final (int status, Map<String, Object?> body) = await _route(
      service,
      <String, Object?>{'op': 'hello'},
    );
    expect(status, 200);
    expect(body['profile'], _uid);
    expect(body['rev'], store.revision);
    expect(body['fp'], store.contentFingerprint);
    expect(body['sched'], isTrue);
    expect(body['tt'], isA<String>());
    expect(body['now'], isA<int>());
  });

  test('线格式还原的视图与主机上读到的相同', () async {
    final (SrsDbStore store, SrsRemoteStoreService service, String deck) =
        await _setUp();
    final String cardId = (await store.studyState(deck))!.next!;
    final SrsCardDetail host = (await store.cardDetail(cardId))!;

    // 牌组树。
    final SrsDeckTree tree = SrsRemoteWire.deckTreeFrom(<SrsEntitySource>[
      for (final Object? s in (await _call(service, 'deckTree'))! as List)
        SrsRemoteWire.sourceFrom(s),
    ]);
    final SrsDeckTree hostTree = await store.deckTree();
    expect(
      <String>[for (final SrsDeckView d in tree.decks) '${d.id}:${d.name}']
        ..sort(),
      <String>[for (final SrsDeckView d in hostTree.decks) '${d.id}:${d.name}']
        ..sort(),
    );

    // 卡片详情：卡片行 + 笔记源 + 笔记类型引用。
    final Map<String, Object?> detail =
        ((await _call(service, 'cardDetail', <String, Object?>{
                  'card': cardId,
                }))!
                as Map)
            .cast<String, Object?>();
    final SrsCardCacheRow row = SrsRemoteWire.cardRowFrom(detail['card'])!;
    expect(row, host.card);
    final SrsNoteView note = SrsRemoteWire.notesFrom(<SrsEntitySource>[
      SrsRemoteWire.sourceFrom(detail['note']),
    ]).single;
    expect(note.fields, host.note.fields);
    expect(note.tags, host.note.tags);
    expect(note.edits.keys.toSet(), host.note.edits.keys.toSet());
    expect(detail['tpl'], host.template?.id);
    expect(detail['deckName'], host.deckName);

    final Map<String, Object?> ref = (detail['type']! as Map)
        .cast<String, Object?>();
    final List<Object?> typeSources =
        (await _call(service, 'noteTypeSources', <String, Object?>{
              'ids': <String>[ref['id']! as String],
            }))!
            as List;
    final SrsEntitySource typeSource = SrsRemoteWire.sourceFrom(
      typeSources.single,
    );
    expect(SrsRemoteWire.tagOf(typeSource), ref['tag']);
    final SrsNoteTypeView type = SrsRemoteWire.noteTypesFrom(
      _uid,
      <SrsEntitySource>[typeSource],
    ).single;
    expect(type.name, host.noteType.name);
    expect(type.css, host.noteType.css);
    expect(type.builtinKey, host.noteType.builtinKey);
    expect(
      <String>[
        for (final SrsTemplateDef t in type.templates)
          '${t.id}${t.front}${t.back}',
      ],
      <String>[
        for (final SrsTemplateDef t in host.noteType.templates)
          '${t.id}${t.front}${t.back}',
      ],
    );

    // 渲染 / 预览 / 牌组行 / 排队。
    final SrsRenderedCard rendered = SrsRemoteWire.renderedFrom(
      await _call(service, 'renderCard', <String, Object?>{'card': cardId}),
    )!;
    final SrsRenderedCard hostRendered = (await store.renderCard(cardId))!;
    expect(rendered.question, hostRendered.question);
    expect(rendered.answer, hostRendered.answer);
    expect(rendered.css, hostRendered.css);
    expect(rendered.fields, hostRendered.fields);

    final SrsAnswerPreview preview = SrsRemoteWire.previewFrom(
      await _call(service, 'preview', <String, Object?>{'card': cardId}),
    );
    final SrsAnswerPreview hostPreview = await store.preview(cardId);
    // 测试时钟每读一次走 1 秒：两次预览的「此刻」不同，到期按相对此刻比。
    for (int r = 1; r <= 4; r++) {
      final SrsScheduleResult got = preview.plan[r];
      final SrsScheduleResult want = hostPreview.plan[r];
      int? rel(int? at, int now) => at == null ? null : at - now;
      expect(rel(got.dueAt, preview.nowMs), rel(want.dueAt, hostPreview.nowMs));
      expect(got.queue, want.queue);
      expect(got.memory?.toJson(), want.memory?.toJson());
      expect(got.reps, want.reps);
    }
    expect(preview.algorithm, hostPreview.algorithm);

    final SrsStudyState study = SrsRemoteWire.studyFrom(
      await _call(service, 'studyState', <String, Object?>{'deck': deck}),
      tree,
    )!;
    final SrsStudyState hostStudy = (await store.studyState(deck))!;
    expect(study.next, hostStudy.next);
    expect(study.after, hostStudy.after);
    expect(study.summary.deck.id, hostStudy.summary.deck.id);
    expect(study.summary.newCount, hostStudy.summary.newCount);
    expect(study.summary.reviewCount, hostStudy.summary.reviewCount);
    expect(
      study.summary.newBudget.allowed,
      hostStudy.summary.newBudget.allowed,
    );

    // 历史（有日志的卡）。
    final SrsCardHistory hostHistory = await store.history(cardId);
    final SrsCardHistory history = SrsCardHistory.fromWire(
      ((await _call(service, 'history', <String, Object?>{'card': cardId}))!
              as Map)
          .cast<String, Object?>(),
    );
    expect(
      <String>[for (final SrsReviewLog l in history.all) l.id],
      <String>[for (final SrsReviewLog l in hostHistory.all) l.id],
    );
    expect(
      <String>[for (final SrsReviewLog l in history.effective) l.id],
      <String>[for (final SrsReviewLog l in hostHistory.effective) l.id],
    );
    expect(history.lastEffective?.id, hostHistory.lastEffective?.id);
    expect(history.state, hostHistory.state);
  });

  test('写操作同一请求 id 重发只执行一次，成功后通知主机', () async {
    int writes = 0;
    final (SrsDbStore store, SrsRemoteStoreService service, String deck) =
        await _setUp(onWrite: (String _) => writes++);
    final String cardId = (await store.studyState(deck))!.next!;
    final int before = (await store.history(cardId)).all.length;
    final Map<String, Object?> args = <String, Object?>{
      'card': cardId,
      'rating': 3,
      'durationMs': 999999,
      'deck': deck,
    };
    final List<Object?> both = await Future.wait(<Future<Object?>>[
      _call(service, 'answerAndStudy', args, 'req-1'),
      _call(service, 'answerAndStudy', args, 'req-1'),
    ]);
    final Object? again = await _call(service, 'answerAndStudy', args, 'req-1');
    expect(jsonEncode(both[0]), jsonEncode(both[1]));
    expect(jsonEncode(again), jsonEncode(both[0]));
    final SrsCardHistory after = await store.history(cardId);
    expect(after.all.length, before + 1);
    final SrsReviewLog log = SrsRemoteWire.logFrom((again! as Map)['log']);
    expect(log.id, after.lastEffective!.id);
    expect(log.durationMs, kSrsMaxAnswerDurationMs);
    expect(writes, 1);

    // 写操作不带请求 id 不执行。
    final (int status, Map<String, Object?> body) = await _route(
      service,
      <String, Object?>{'profile': _uid, 'op': 'setFlag', 'args': args},
    );
    expect(status, 400);
    expect(body['error'], SrsRemoteStoreError.badRequest);
  });

  test('作答带基准：卡在主机上变了回 stale，不记日志', () async {
    final (SrsDbStore store, SrsRemoteStoreService service, String deck) =
        await _setUp();
    final String cardId = (await store.studyState(deck))!.next!;
    final String? base = (await store.cardRow(cardId))!.lastLogId;
    await store.answer(cardId, 4);
    final int before = (await store.history(cardId)).all.length;
    final (int status, Map<String, Object?> body) = await _route(
      service,
      <String, Object?>{
        'profile': _uid,
        'op': 'answerAndStudy',
        'request': 'r-stale',
        'args': <String, Object?>{
          'card': cardId,
          'rating': 1,
          'durationMs': 1000,
          'checkBase': true,
          'base': base,
        },
      },
    );
    expect(status, 409);
    expect(body['error'], SrsRemoteStoreError.stale);
    expect((await store.history(cardId)).all.length, before);
  });

  test('卡片操作与撤销经远程执行', () async {
    final (SrsDbStore store, SrsRemoteStoreService service, String deck) =
        await _setUp();
    final String cardId = (await store.studyState(deck))!.next!;
    await _call(service, 'setFlag', <String, Object?>{
      'card': cardId,
      'flag': 2,
    }, 'f1');
    await _call(service, 'setSuspended', <String, Object?>{
      'card': cardId,
      'value': true,
    }, 's1');
    SrsCardCacheRow row = (await store.cardRow(cardId))!;
    expect(row.flag, 2);
    expect(row.suspended, isTrue);
    await _call(service, 'setSuspended', <String, Object?>{
      'card': cardId,
      'value': false,
    }, 's2');

    final Map<String, Object?> out =
        ((await _call(service, 'answerAndStudy', <String, Object?>{
                  'card': cardId,
                  'rating': 1,
                  'durationMs': 1000,
                }, 'a1'))!
                as Map)
            .cast<String, Object?>();
    final String logId = SrsRemoteWire.logFrom(out['log']).id;
    expect(
      await _call(service, 'undo', <String, Object?>{
        'card': cardId,
        'log': logId,
      }, 'u1'),
      isTrue,
    );
    row = (await store.cardRow(cardId))!;
    expect(row.suspended, isFalse);
    expect((await store.history(cardId)).lastEffective?.id, isNot(logId));
  });

  test('错误码：配置变了、不认识的操作、参数不对、模块关着', () async {
    final (_, SrsRemoteStoreService service, _) = await _setUp();
    Future<(int, Object?)> err(Map<String, Object?> body) async {
      final (int status, Map<String, Object?> b) = await _route(service, body);
      return (status, b['error']);
    }

    expect(await err(<String, Object?>{'profile': 'other', 'op': 'hello'}), (
      409,
      SrsRemoteStoreError.profileChanged,
    ));
    expect(await err(<String, Object?>{'op': 'nope'}), (
      404,
      SrsRemoteStoreError.unknownOp,
    ));
    expect(
      await err(<String, Object?>{
        'op': 'cardRow',
        'args': <String, Object?>{'card': 3},
      }),
      (400, SrsRemoteStoreError.badRequest),
    );
    expect(
      await err(<String, Object?>{
        'profile': _uid,
        'op': 'answerAndStudy',
        'request': 'x',
        'args': <String, Object?>{
          'card': 'missing',
          'rating': 9,
          'durationMs': 0,
        },
      }),
      (400, SrsRemoteStoreError.failed),
    );

    final SrsRemoteStoreService off = SrsRemoteStoreService(
      readStore: () async => null,
      readMedia: (String name) async => null,
    );
    final shelf.Response res = await handleSrsRemoteStoreRequest(
      off,
      shelf.Request(
        'POST',
        Uri.parse('http://host/api/srs/remote/call'),
        body: jsonEncode(<String, Object?>{'op': 'hello'}),
      ),
      'POST',
      '/api/srs/remote/call',
    );
    expect(res.statusCode, 503);

    final shelf.Response media = await handleSrsRemoteStoreRequest(
      service,
      shelf.Request('GET', Uri.parse('http://host/api/srs/remote/media/a.png')),
      'GET',
      '/api/srs/remote/media/a.png',
    );
    expect(media.statusCode, 200);
    expect(await media.read().expand((List<int> c) => c).toList(), <int>[
      1,
      2,
      3,
    ]);
  });

  test('写操作不带 profile 一律 400，不执行', () async {
    final (SrsDbStore store, SrsRemoteStoreService service, String deck) =
        await _setUp();
    final String cardId = (await store.studyState(deck))!.next!;
    final (int status, Map<String, Object?> body) = await _route(
      service,
      <String, Object?>{
        'op': 'setFlag',
        'request': 'no-profile',
        'args': <String, Object?>{'card': cardId, 'flag': 3},
      },
    );
    expect(status, 400);
    expect(body['error'], SrsRemoteStoreError.badRequest);
    expect((await store.cardRow(cardId))!.flag, isNot(3));
  });

  test('作答的基准核对与记日志在同一个写独占区：中途主机本机作答不会记两条', () async {
    final (SrsDbStore store, SrsRemoteStoreService service, String deck) =
        await _setUp();
    final String cardId = (await store.studyState(deck))!.next!;
    final String? base = (await store.cardRow(cardId))!.lastLogId;
    final int before = (await store.history(cardId)).all.length;
    // 主机本机占着写锁、还没提交作答时，远程作答已经发出。
    final Completer<void> gate = Completer<void>();
    final Future<void> local = store.runExclusive(() async {
      await gate.future;
      await store.answer(cardId, 4);
    });
    final Future<(int, Map<String, Object?>)> remote = _route(
      service,
      <String, Object?>{
        'profile': _uid,
        'op': 'answerAndStudy',
        'request': 'r-race',
        'args': <String, Object?>{
          'card': cardId,
          'rating': 1,
          'durationMs': 1000,
          'checkBase': true,
          'base': base,
        },
      },
    );
    // 让远程请求先跑到它的第一个等待点（修复前：已在锁外读完基准、正排队等记日志）。
    await Future<void>.delayed(const Duration(milliseconds: 100));
    gate.complete();
    await local;
    final (int status, Map<String, Object?> body) = await remote;
    expect(status, 409, reason: '$body');
    expect(body['error'], SrsRemoteStoreError.stale);
    expect((await store.history(cardId)).all.length, before + 1);
  });

  test('browseCommand 只放行浏览会话命令：seal_file / open_file / 改库命令一律拒绝', () async {
    final (SrsDbStore store, SrsRemoteStoreService service, _) = await _setUp();
    final Directory tmp = await Directory.systemTemp.createTemp('srs_remote_');
    addTearDown(() => tmp.delete(recursive: true));
    final File src = File('${tmp.path}/secret.txt')
      ..writeAsStringSync('secret');
    final String dst = '${tmp.path}/leak.bin';
    final List<Map<String, Object?>> forbidden = <Map<String, Object?>>[
      <String, Object?>{
        'op': 'seal_file',
        'key': List<int>.filled(32, 7),
        'name': 'leak.bin',
        'src': src.path,
        'dst': dst,
      },
      <String, Object?>{
        'op': 'open_file',
        'key': List<int>.filled(32, 7),
        'src': src.path,
        'dst': dst,
      },
      <String, Object?>{'op': 'apply'},
      <String, Object?>{'op': 'migrate'},
      <String, Object?>{'op': 'replay_all'},
      <String, Object?>{'op': 'status'},
      <String, Object?>{},
    ];
    for (final Map<String, Object?> request in forbidden) {
      final (int status, Map<String, Object?> body) = await _route(
        service,
        <String, Object?>{
          'profile': _uid,
          'op': 'browseCommand',
          'args': <String, Object?>{'request': request},
        },
      );
      expect(status, 400, reason: '${request['op']} → $body');
      expect(body['error'], SrsRemoteStoreError.badRequest);
      // 本机入口同一判据：这个入口不进写锁，不许被拿来绕开 sync2Command。
      expect(
        () => store.browseCommand(request),
        throwsA(isA<ArgumentError>()),
        reason: '${request['op']}',
      );
    }
    expect(File(dst).existsSync(), isFalse);

    // 浏览会话命令照常可用。
    final Object? stats = await _call(
      service,
      'browseCommand',
      <String, Object?>{
        'request': <String, Object?>{'op': 'browse_stats'},
      },
    );
    expect(stats, isNotNull);
    await _call(service, 'browseCommand', <String, Object?>{
      'request': <String, Object?>{'op': 'browse_close'},
    });
  });

  group('一台主机提供几份 profile（无头服务端：一门语言一份）', () {
    const String other = '01928c3e-0000-7000-8000-0000000b0b02';

    test('握手列出提供的 profile，点名的 uid 读那一份；不提供的 uid 回 profile_changed', () async {
      final (SrsDbStore a, _, _) = await _setUp();
      final SrsDbStore b = await openTestStore(
        profileUid: other,
        deviceId: 'host',
        now: () => DateTime.utc(2026, 11, 1, 12).millisecondsSinceEpoch,
      );
      final Map<String, SrsDbStore> served = <String, SrsDbStore>{
        _uid: a,
        other: b,
      };
      final SrsRemoteStoreService service = SrsRemoteStoreService(
        readStore: () async => a,
        readProfile: (String uid) async => served[uid],
        profiles: () async => const <SrsRemoteServedProfile>[
          SrsRemoteServedProfile(uid: _uid, name: 'Japanese', notes: 6),
          SrsRemoteServedProfile(uid: other, name: 'Chinese'),
        ],
        readMedia: (String name) async => null,
      );

      final (int s0, Map<String, Object?> hello) = await _route(
        service,
        <String, Object?>{'op': 'hello'},
      );
      expect(s0, 200);
      expect(hello['profile'], _uid, reason: '不点名 = 默认 profile');
      expect(
        (hello['profiles']! as List<Object?>)
            .map(
              (Object? e) => SrsRemoteServedProfile.fromJson(
                (e! as Map).cast<String, Object?>(),
              ).uid,
            )
            .toList(),
        <String>[_uid, other],
      );

      final (int s1, Map<String, Object?> helloB) = await _route(
        service,
        <String, Object?>{'op': 'hello', 'profile': other},
      );
      expect(s1, 200);
      expect(helloB['profile'], other);

      // 牌组树缓存按 profile 分开：A 的树不会被当成 B 的回出去。
      final (_, Map<String, Object?> treeA) = await _route(
        service,
        <String, Object?>{'op': 'deckSummaries', 'profile': _uid},
      );
      final (_, Map<String, Object?> treeB) = await _route(
        service,
        <String, Object?>{'op': 'deckSummaries', 'profile': other},
      );
      expect(treeA['tt'], isNot(treeB['tt']));
      expect(
        (treeA['result']! as List<Object?>).length,
        greaterThan((treeB['result']! as List<Object?>).length),
      );

      final (int s2, Map<String, Object?> gone) = await _route(
        service,
        <String, Object?>{
          'op': 'hello',
          'profile': '01928c3e-0000-7000-8000-00000000dead',
        },
      );
      expect((s2, gone['error']), (409, SrsRemoteStoreError.profileChanged));
    });

    test('桌面 host（不给 profiles）握手不带 profiles 字段', () async {
      final (_, SrsRemoteStoreService service, _) = await _setUp();
      final (_, Map<String, Object?> hello) = await _route(
        service,
        <String, Object?>{'op': 'hello'},
      );
      expect(hello.containsKey('profiles'), isFalse);
    });
  });
}
