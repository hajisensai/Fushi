import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:fushi_engine/leaderboard/leaderboard_client.dart';
import 'package:fushi_engine/leaderboard/leaderboard_identity.dart';
import 'package:fushi_engine/leaderboard/leaderboard_models.dart';
import 'package:fushi_engine/leaderboard/leaderboard_sync.dart';
import 'package:fushi_engine/leaderboard/local_shelf.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

LocalShelfEntry _e(String key, {int chars = 0, String? title}) =>
    LocalShelfEntry(
      localKey: key,
      upload: ShelfEntryUpload(
        kind: LeaderboardKind.book,
        refs: <String>['t:${title ?? key}|'],
        title: title ?? key,
        finished: false,
        chars: chars,
      ),
    );

DailyCharsUpload _d(String date, int chars) =>
    DailyCharsUpload(date: date, chars: chars);

LocalShelf _shelf(
  List<LocalShelfEntry> entries, [
  List<DailyCharsUpload> daily = const <DailyCharsUpload>[],
]) => LocalShelf(entries: entries, daily: daily);

LeaderboardSyncState _synced(
  List<LocalShelfEntry> entries,
  Map<String, String> workIds, {
  Map<String, int> daily = const <String, int>{},
}) => LeaderboardSyncState(
  entries: <String, SyncedEntry>{
    for (final LocalShelfEntry e in entries)
      e.localKey: SyncedEntry(
        hash: e.upload.contentHash(),
        workId: workIds[e.localKey]!,
      ),
  },
  daily: daily,
  shelfCount: workIds.values.toSet().length,
);

String _date(int i) =>
    '2026-${(i ~/ 28 % 12 + 1).toString().padLeft(2, '0')}-'
    '${(i % 28 + 1).toString().padLeft(2, '0')}';

void main() {
  group('planShelfSync', () {
    test('首次全量：reset 只在第一批，全部条目与非零日期', () {
      final LocalShelf local = _shelf(
        <LocalShelfEntry>[_e('book:a'), _e('book:b')],
        <DailyCharsUpload>[_d('2026-09-01', 10)],
      );
      final ShelfSyncPlan plan = planShelfSync(
        local,
        LeaderboardSyncState.empty,
        reset: true,
      );
      expect(plan.reset, isTrue);
      expect(plan.batches, hasLength(1));
      expect(plan.batches.single.reset, isTrue);
      expect(
        plan.batches.single.put.map((ShelfSyncItem e) => e.localKey),
        <String>['book:a', 'book:b'],
      );
      expect(plan.batches.single.daily.single.chars, 10);
      expect(plan.droppedLocalKeys, isEmpty);
    });

    test('reset 且本地为空：仍发一个空的 reset 批（清空服务端）', () {
      final ShelfSyncPlan plan = planShelfSync(
        LocalShelf.empty,
        LeaderboardSyncState.empty,
        reset: true,
      );
      expect(plan.batches, hasLength(1));
      expect(plan.batches.single.reset, isTrue);
      expect(plan.batches.single.put, isEmpty);
    });

    test('增量：只 put hash 变了 / 新增的条目；没变化就没有批次', () {
      final LocalShelfEntry a = _e('book:a', chars: 1);
      final LocalShelfEntry b = _e('book:b', chars: 1);
      final LeaderboardSyncState state = _synced(
        <LocalShelfEntry>[a, b],
        <String, String>{'book:a': 'W1', 'book:b': 'W2'},
      );
      expect(
        planShelfSync(
          _shelf(<LocalShelfEntry>[a, b]),
          state,
          reset: false,
        ).batches,
        isEmpty,
      );
      final ShelfSyncPlan plan = planShelfSync(
        _shelf(<LocalShelfEntry>[a, _e('book:b', chars: 2), _e('book:c')]),
        state,
        reset: false,
      );
      expect(plan.batches.single.reset, isFalse);
      expect(
        plan.batches.single.put.map((ShelfSyncItem e) => e.localKey),
        <String>['book:b', 'book:c'],
      );
    });

    test('删除：本地消失的 localKey 进 droppedLocalKeys（remove 由孤儿规则算）', () {
      final LocalShelfEntry a = _e('book:a');
      final LocalShelfEntry b = _e('book:b');
      final ShelfSyncPlan plan = planShelfSync(
        _shelf(<LocalShelfEntry>[a]),
        _synced(
          <LocalShelfEntry>[a, b],
          <String, String>{'book:a': 'W1', 'book:b': 'W2'},
        ),
        reset: false,
      );
      expect(plan.batches, isEmpty);
      expect(plan.droppedLocalKeys, <String>['book:b']);
    });

    test('daily：只发变了的日期，消失的日期发 0', () {
      final ShelfSyncPlan plan = planShelfSync(
        _shelf(const <LocalShelfEntry>[], <DailyCharsUpload>[
          _d('2026-09-01', 10),
          _d('2026-09-02', 7),
        ]),
        const LeaderboardSyncState(
          daily: <String, int>{
            '2026-09-01': 10,
            '2026-09-02': 5,
            '2026-08-31': 3,
          },
          shelfCount: 0,
        ),
        reset: false,
      );
      expect(
        plan.batches.single.daily.map(
          (DailyCharsUpload d) => '${d.date}=${d.chars}',
        ),
        <String>['2026-09-02=7', '2026-08-31=0'],
      );
    });

    test('分批边界：500 条 put 一批、501 条两批；daily 按 400 独立切', () {
      List<LocalShelfEntry> many(int n) => <LocalShelfEntry>[
        for (int i = 0; i < n; i++) _e('book:${i.toString().padLeft(4, '0')}'),
      ];
      expect(
        planShelfSync(
          _shelf(many(500)),
          LeaderboardSyncState.empty,
          reset: true,
        ).batches,
        hasLength(1),
      );
      final ShelfSyncPlan plan = planShelfSync(
        _shelf(many(501), <DailyCharsUpload>[
          for (int i = 0; i < 1201; i++) _d(_date(i), 1),
        ]),
        LeaderboardSyncState.empty,
        reset: true,
      );
      // daily 1201 条 → 4 批（400/400/400/1），put 501 条 → 前两批。
      expect(plan.batches, hasLength(4));
      expect(plan.batches.map((ShelfSyncBatch b) => b.reset), <bool>[
        true,
        false,
        false,
        false,
      ]);
      expect(plan.batches.map((ShelfSyncBatch b) => b.put.length), <int>[
        500,
        1,
        0,
        0,
      ]);
      expect(plan.batches.map((ShelfSyncBatch b) => b.daily.length), <int>[
        400,
        400,
        400,
        1,
      ]);
    });
    test('合并：已知同 workId 的条目合成一条（读完取最晚、字数时长相加、refs 取第一个）', () {
      LocalShelfEntry entry(
        String key, {
        int? at,
        int chars = 0,
        String? cover,
      }) => LocalShelfEntry(
        localKey: key,
        localCoverPath: cover,
        upload: ShelfEntryUpload(
          kind: LeaderboardKind.book,
          refs: <String>['t:$key|'],
          title: key,
          finished: at != null,
          finishedAt: at,
          finishedDate: at == null ? null : '2026-09-0$at',
          chars: chars,
          ms: chars * 10,
        ),
      );
      final LocalShelf local = _shelf(<LocalShelfEntry>[
        entry('book:a', at: 3, chars: 1),
        entry('book:b', chars: 2, cover: '/c/b.jpg'),
        entry('book:c', at: 5, chars: 4),
        entry('book:d'),
      ]);
      const LeaderboardSyncState state = LeaderboardSyncState(
        entries: <String, SyncedEntry>{
          'book:a': SyncedEntry(hash: 'x', workId: 'W1'),
          'book:b': SyncedEntry(hash: 'x', workId: 'W1'),
          'book:c': SyncedEntry(hash: 'x', workId: 'W1'),
        },
        shelfCount: 1,
      );
      final List<ShelfSyncItem> items = groupShelfEntries(local, state);
      expect(items, hasLength(2));
      final ShelfSyncItem merged = items.first;
      expect(merged.localKeys, <String>['book:a', 'book:b', 'book:c']);
      expect(merged.localKey, 'book:a');
      expect(merged.entry.upload.refs, <String>['t:book:a|']);
      expect(merged.entry.upload.finished, isTrue);
      expect(merged.entry.upload.finishedAt, 5);
      expect(merged.entry.upload.finishedDate, '2026-09-05');
      expect(merged.entry.upload.chars, 7);
      expect(merged.entry.upload.ms, 70);
      expect(merged.entry.localCoverPath, '/c/b.jpg');
      expect(items.last.localKeys, <String>['book:d'], reason: '未知映射各自成组');

      // 已按合并后的 hash 记账：再规划时这一组不再 put。
      final String h = merged.entry.upload.contentHash();
      final ShelfSyncPlan again = planShelfSync(
        local,
        LeaderboardSyncState(
          entries: <String, SyncedEntry>{
            for (final String k in merged.localKeys)
              k: SyncedEntry(hash: h, workId: 'W1'),
            'book:d': SyncedEntry(
              hash: items.last.entry.upload.contentHash(),
              workId: 'W2',
            ),
          },
          shelfCount: 2,
        ),
        reset: false,
      );
      expect(again.batches, isEmpty);
    });

    test('daily 窗口：早于 dailyFrom 的旧日期不发删除', () {
      final ShelfSyncPlan plan = planShelfSync(
        const LocalShelf(
          entries: <LocalShelfEntry>[],
          daily: <DailyCharsUpload>[],
          dailyFrom: '2016-09-29',
        ),
        const LeaderboardSyncState(
          daily: <String, int>{'2016-09-28': 1, '2016-09-29': 2},
          shelfCount: 0,
        ),
        reset: false,
      );
      expect(
        plan.batches.single.daily.map(
          (DailyCharsUpload d) => '${d.date}=${d.chars}',
        ),
        <String>['2016-09-29=0'],
      );
    });
  });

  group('orphanedWorkIds', () {
    const SyncedEntry w1 = SyncedEntry(hash: 'h', workId: 'W1');
    const SyncedEntry w2 = SyncedEntry(hash: 'h', workId: 'W2');
    const SyncedEntry w3 = SyncedEntry(hash: 'h', workId: 'W3');

    test('本地删了、无人再映射 → 孤儿', () {
      expect(
        orphanedWorkIds(
          <String, SyncedEntry>{'a': w1, 'b': w2},
          <String, SyncedEntry>{'a': w1},
        ),
        <String>['W2'],
      );
    });

    test('多 localKey 同 workId：删掉其一不产孤儿', () {
      expect(
        orphanedWorkIds(
          <String, SyncedEntry>{'a': w1, 'b': w1},
          <String, SyncedEntry>{'a': w1},
        ),
        isEmpty,
      );
    });

    test('workId 变更：旧 workId 无人映射才算孤儿', () {
      expect(
        orphanedWorkIds(
          <String, SyncedEntry>{'a': w1, 'b': w2},
          <String, SyncedEntry>{'a': w3, 'b': w2},
        ),
        <String>['W1'],
      );
      expect(
        orphanedWorkIds(
          <String, SyncedEntry>{'a': w1, 'b': w1},
          <String, SyncedEntry>{'a': w3, 'b': w1},
        ),
        isEmpty,
      );
    });
  });

  group('LeaderboardSyncState JSON', () {
    test('往返', () {
      const LeaderboardSyncState s = LeaderboardSyncState(
        entries: <String, SyncedEntry>{
          'book:a': SyncedEntry(hash: 'h1', workId: 'W1'),
        },
        daily: <String, int>{'2026-09-01': 3},
        shelfCount: 1,
      );
      final LeaderboardSyncState back = LeaderboardSyncState.fromJson(
        (jsonDecode(jsonEncode(s.toJson())) as Map<Object?, Object?>)
            .cast<String, dynamic>(),
      );
      expect(back.entries, s.entries);
      expect(back.daily, s.daily);
      expect(back.shelfCount, 1);
      expect(back.neverSynced, isFalse);
      expect(LeaderboardSyncState.empty.neverSynced, isTrue);
    });

    test('坏形状 → FormatException', () {
      expect(
        () => LeaderboardSyncState.fromJson(<String, dynamic>{'entries': 3}),
        throwsFormatException,
      );
    });
  });

  group('syncShelf（MockClient）', () {
    final LeaderboardIdentity id = LeaderboardIdentity.generate(
      random: Random(11),
    );

    late List<Map<String, dynamic>> shelfBodies;
    late List<String> coverUploads;
    late int serverShelfCount;
    late int failOnShelfCall;
    late Map<String, String> workIdByTitle;
    late bool? uploadDevice;
    late List<(int, String)> shelfErrors;
    late int shelfCalls;

    setUp(() {
      uploadDevice = null;
      shelfErrors = <(int, String)>[];
      shelfCalls = 0;
      shelfBodies = <Map<String, dynamic>>[];
      coverUploads = <String>[];
      serverShelfCount = 0;
      failOnShelfCall = -1;
      workIdByTitle = <String, String>{};
    });

    String workIdFor(String title) =>
        workIdByTitle[title] ?? 'W_${title.replaceAll(':', '_')}';

    http.Response json(Object body, [int status = 200]) => http.Response.bytes(
      utf8.encode(jsonEncode(body)),
      status,
      headers: <String, String>{'content-type': 'application/json'},
    );

    LeaderboardClient client() => LeaderboardClient(
      baseUrl: Uri.parse('https://rank.example'),
      identity: id,
      httpClientFactory: () async => MockClient((http.Request r) async {
        if (r.url.path == '/v1/me') {
          return json(<String, dynamic>{
            'id': id.accountId,
            'nickname': 'n',
            'discriminator': 1,
            'avatar': null,
            'visibility': 'public',
            'createdAt': 1,
            'shelfCount': serverShelfCount,
            if (uploadDevice != null) 'uploadDevice': uploadDevice,
          });
        }
        if (r.url.path == '/v1/shelf') {
          shelfCalls++;
          if (shelfErrors.isNotEmpty) {
            final (int status, String code) = shelfErrors.removeAt(0);
            return json(<String, dynamic>{'error': code}, status);
          }
          if (shelfBodies.length == failOnShelfCall) {
            shelfBodies.add(<String, dynamic>{'failed': true});
            return json(<String, dynamic>{'error': 'boom'}, 500);
          }
          final Map<String, dynamic> body =
              (jsonDecode(utf8.decode(r.bodyBytes)) as Map<Object?, Object?>)
                  .cast<String, dynamic>();
          shelfBodies.add(body);
          final List<Object?> put = body['put'] as List<Object?>;
          return json(<String, dynamic>{
            'works': <Map<String, dynamic>>[
              for (int i = 0; i < put.length; i++)
                <String, dynamic>{
                  'i': i,
                  'workId': workIdFor(
                    (put[i] as Map<Object?, Object?>)['title'] as String,
                  ),
                  'needsCover': i == 0,
                },
            ],
            'shelfCount': serverShelfCount,
          });
        }
        if (r.url.path.endsWith('/cover')) {
          coverUploads.add(r.url.pathSegments[2]);
          return json(<String, dynamic>{'cover': '/img/x'});
        }
        return json(<String, dynamic>{'error': 'not_found'}, 404);
      }),
    );

    test('首次：不查 me，reset 全量；needsCover 调 coverThumb 补传', () async {
      final LeaderboardSyncState s = await syncShelf(
        client(),
        _shelf(
          <LocalShelfEntry>[_e('book:a'), _e('book:b')],
          <DailyCharsUpload>[_d('2026-09-01', 4)],
        ),
        LeaderboardSyncState.empty,
        coverThumb: (LocalShelfEntry e) async =>
            Uint8List.fromList(<int>[1, 2, 3]),
      );
      expect(shelfBodies.single['reset'], isTrue);
      // 桩只对每批第 0 条回 needsCover。
      expect(coverUploads, <String>['W_book_a']);
      expect(s.entries['book:a']!.workId, 'W_book_a');
      expect(s.entries['book:b']!.workId, 'W_book_b');
      expect(s.daily, <String, int>{'2026-09-01': 4});
      expect(s.neverSynced, isFalse);
    });

    test('计数一致：增量 put；本地删除与 workId 变更的孤儿最后 remove', () async {
      final LocalShelfEntry a = _e('book:a', chars: 1);
      final LocalShelfEntry b = _e('book:b', chars: 1);
      final LocalShelfEntry c = _e('book:c', chars: 1);
      final LeaderboardSyncState state = _synced(
        <LocalShelfEntry>[a, b, c],
        <String, String>{'book:a': 'WA', 'book:b': 'WB', 'book:c': 'WA'},
      );
      serverShelfCount = 2; // WA、WB
      // a、c 已知同属 WA → 合并成一条 put；a 变了，服务端这次把这组落到 WN（别名合并
      // 改判）；b 本地删了。
      workIdByTitle['book:a'] = 'WN';
      final LeaderboardSyncState s = await syncShelf(
        client(),
        _shelf(<LocalShelfEntry>[_e('book:a', chars: 9), c]),
        state,
      );
      expect(shelfBodies, hasLength(2));
      expect(shelfBodies[0]['reset'], isFalse);
      expect((shelfBodies[0]['put'] as List<Object?>), hasLength(1));
      expect(shelfBodies[0]['remove'], isEmpty);
      // WA 已无人映射（a、c 都改落 WN），WB 本地删了：两个都删。
      expect(shelfBodies[1]['remove'], <String>['WA', 'WB']);
      expect(shelfBodies[1]['put'], isEmpty);
      expect(s.entries.keys, unorderedEquals(<String>['book:a', 'book:c']));
      expect(s.entries['book:a']!.workId, 'WN');
      expect(s.entries['book:c']!.workId, 'WN');
    });

    test('服务端计数与 state 不符 → reset 全量', () async {
      final LocalShelfEntry a = _e('book:a');
      serverShelfCount = 5;
      await syncShelf(
        client(),
        _shelf(<LocalShelfEntry>[a]),
        _synced(<LocalShelfEntry>[a], <String, String>{'book:a': 'W1'}),
      );
      expect(shelfBodies.single['reset'], isTrue);
      expect(shelfBodies.single['put'], hasLength(1));
      expect(shelfBodies.single['remove'], isEmpty);
    });

    test('中途失败：抛 LeaderboardSyncException，partialState 含已成功的批', () async {
      final List<LocalShelfEntry> entries = <LocalShelfEntry>[
        for (int i = 0; i < 501; i++)
          _e('book:${i.toString().padLeft(4, '0')}'),
      ];
      failOnShelfCall = 1; // 第二批失败
      Object? caught;
      try {
        await syncShelf(client(), _shelf(entries), LeaderboardSyncState.empty);
      } on LeaderboardSyncException catch (e) {
        caught = e;
        expect(e.partialState.entries, hasLength(500));
        expect(e.error, isA<LeaderboardApiException>());
        // 续传：用 partialState 再跑，服务端计数与 state 一致时只补剩下那条。
        serverShelfCount = 500;
        failOnShelfCall = -1;
        shelfBodies.clear();
        final LeaderboardSyncState s = await syncShelf(
          client(),
          _shelf(entries),
          e.partialState,
        );
        expect(shelfBodies.single['reset'], isFalse);
        expect(shelfBodies.single['put'], hasLength(1));
        expect(s.entries, hasLength(501));
      }
      expect(caught, isNotNull);
    });

    test('封面补传失败：书架照常完成，条目 hash 置空待重传，最后报错', () async {
      Object? caught;
      try {
        await syncShelf(
          client(),
          _shelf(<LocalShelfEntry>[_e('book:a')]),
          LeaderboardSyncState.empty,
          coverThumb: (LocalShelfEntry e) async => throw StateError('disk'),
        );
      } on LeaderboardSyncException catch (e) {
        caught = e;
        expect(e.error, isA<StateError>());
        expect(e.partialState.entries['book:a']!.hash, '');
        expect(e.partialState.entries['book:a']!.workId, 'W_book_a');
        final ShelfSyncPlan next = planShelfSync(
          _shelf(<LocalShelfEntry>[_e('book:a')]),
          e.partialState,
          reset: false,
        );
        expect(next.batches.single.put.single.localKey, 'book:a');
      }
      expect(caught, isNotNull);
    });
    test('409 conflict：原样重发该批（最多 3 次），成功即继续', () async {
      shelfErrors = <(int, String)>[(409, 'conflict'), (409, 'conflict')];
      final LeaderboardSyncState s = await syncShelf(
        client(),
        _shelf(<LocalShelfEntry>[_e('book:a')]),
        LeaderboardSyncState.empty,
      );
      expect(shelfCalls, 3);
      expect(shelfBodies.single['reset'], isTrue);
      expect(s.entries['book:a']!.workId, 'W_book_a');
    });

    test('409 conflict 超过 3 次重试：按普通失败报出（进度可续）', () async {
      shelfErrors = <(int, String)>[
        for (int i = 0; i < 4; i++) (409, 'conflict'),
      ];
      await expectLater(
        syncShelf(
          client(),
          _shelf(<LocalShelfEntry>[_e('book:a')]),
          LeaderboardSyncState.empty,
        ),
        throwsA(isA<LeaderboardSyncException>()),
      );
      expect(shelfCalls, 4);
    });

    test('429 / 503：LeaderboardSyncException 带已推进的状态', () async {
      shelfErrors = <(int, String)>[(429, 'rate_limited')];
      await expectLater(
        syncShelf(
          client(),
          _shelf(<LocalShelfEntry>[_e('book:a')]),
          LeaderboardSyncState.empty,
        ),
        throwsA(
          isA<LeaderboardSyncException>().having(
            (LeaderboardSyncException e) => e.partialState.neverSynced,
            'partialState.neverSynced',
            isTrue,
          ),
        ),
      );
      expect(shelfCalls, 1, reason: '429 不重试');
    });

    test('409 upload_owned_by_other_device：抛专门异常，不重试', () async {
      shelfErrors = <(int, String)>[(409, 'upload_owned_by_other_device')];
      await expectLater(
        syncShelf(
          client(),
          _shelf(<LocalShelfEntry>[_e('book:a')]),
          LeaderboardSyncState.empty,
        ),
        throwsA(isA<LeaderboardUploadOwnedElsewhere>()),
      );
      expect(shelfCalls, 1);
    });

    test('me().uploadDevice == false：不发书架请求直接抛', () async {
      final LocalShelfEntry a = _e('book:a');
      uploadDevice = false;
      serverShelfCount = 1;
      await expectLater(
        syncShelf(
          client(),
          _shelf(<LocalShelfEntry>[a]),
          _synced(<LocalShelfEntry>[a], <String, String>{'book:a': 'W1'}),
        ),
        throwsA(isA<LeaderboardUploadOwnedElsewhere>()),
      );
      expect(shelfCalls, 0);
    });

    test('claim：强制 reset 全量，第一批带 claim、后续批不带', () async {
      final LocalShelfEntry a = _e('book:a');
      uploadDevice = false;
      await syncShelf(
        client(),
        _shelf(<LocalShelfEntry>[
          for (int i = 0; i < 501; i++)
            _e('book:${i.toString().padLeft(4, '0')}'),
        ]),
        _synced(<LocalShelfEntry>[a], <String, String>{'book:a': 'W1'}),
        claim: true,
      );
      expect(shelfBodies, hasLength(2));
      expect(shelfBodies[0]['reset'], isTrue);
      expect(shelfBodies[0]['claim'], isTrue);
      expect(shelfBodies[1]['reset'], isFalse);
      expect(shelfBodies[1].containsKey('claim'), isFalse);
    });

    test('已知同 workId 的条目合并后只 put 一条，workId 记到每个 localKey', () async {
      final LocalShelfEntry a = _e('book:a', title: 'T');
      final LocalShelfEntry b = _e('book:b', title: 'T');
      serverShelfCount = 1;
      workIdByTitle['T'] = 'WT';
      final LeaderboardSyncState s = await syncShelf(
        client(),
        _shelf(<LocalShelfEntry>[
          _e('book:a', chars: 5, title: 'T'),
          _e('book:b', chars: 7, title: 'T'),
        ]),
        _synced(
          <LocalShelfEntry>[a, b],
          <String, String>{'book:a': 'WT', 'book:b': 'WT'},
        ),
      );
      final List<Object?> put = shelfBodies.single['put'] as List<Object?>;
      expect(put, hasLength(1));
      expect((put.single as Map<Object?, Object?>)['chars'], 12);
      expect(s.entries['book:a'], s.entries['book:b']);
      expect(s.entries['book:a']!.workId, 'WT');
    });
  });
}
