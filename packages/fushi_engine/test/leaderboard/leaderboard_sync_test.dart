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

LocalShelfEntry _e(
  String key, {
  int chars = 0,
  String? title,
  int? finishedAt,
  int? lastActiveAt,
  String? cover,
}) => LocalShelfEntry(
  localKey: key,
  localCoverPath: cover,
  lastActiveAt: lastActiveAt,
  upload: ShelfEntryUpload(
    kind: LeaderboardKind.book,
    refs: <String>['t:${title ?? key}|'],
    title: title ?? key,
    finished: finishedAt != null,
    finishedAt: finishedAt,
    finishedDate: finishedAt == null ? null : '2026-09-01',
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

String _k(int i) => 'book:${i.toString().padLeft(4, '0')}';

List<String> _keys(ShelfSyncBatch b) =>
    b.put.map((LocalShelfEntry e) => e.localKey).toList();

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
      expect(_keys(plan.batches.single), <String>['book:a', 'book:b']);
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

    test('增量：变了的已同步条目一批、新条目单独成批且不带 daily；没变化就没有批次', () {
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
        _shelf(
          <LocalShelfEntry>[a, _e('book:b', chars: 2), _e('book:c')],
          <DailyCharsUpload>[_d('2026-09-01', 3)],
        ),
        state,
        reset: false,
      );
      expect(plan.batches, hasLength(2));
      expect(_keys(plan.batches[0]), <String>['book:b']);
      expect(plan.batches[0].daily, hasLength(1));
      expect(plan.batches[0].newEntriesOnly, isFalse);
      expect(_keys(plan.batches[1]), <String>['book:c']);
      expect(plan.batches[1].daily, isEmpty);
      expect(plan.batches[1].newEntriesOnly, isTrue);
    });

    test('删除：本地消失的 localKey 进 droppedLocalKeys；全员消失的作品 put 前先删', () {
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
      expect(plan.preRemoveWorkIds, <String>['W2']);
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
        for (int i = 0; i < n; i++) _e(_k(i)),
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

    test('不预合并：同 workId 的成员任一变了，整组各带自己的 refs 进同一批', () {
      final LocalShelfEntry a = _e('book:a', chars: 1);
      final LocalShelfEntry b = _e('book:b', chars: 2);
      final LocalShelfEntry c = _e('book:c', chars: 4);
      final LocalShelfEntry d = _e('book:d', chars: 8);
      final LeaderboardSyncState state = _synced(
        <LocalShelfEntry>[a, b, c, d],
        <String, String>{
          'book:a': 'W1',
          'book:b': 'W1',
          'book:c': 'W1',
          'book:d': 'W2',
        },
      );
      final ShelfSyncPlan plan = planShelfSync(
        _shelf(<LocalShelfEntry>[_e('book:a', chars: 9), b, c, d]),
        state,
        reset: false,
      );
      final ShelfSyncBatch batch = plan.batches.single;
      expect(_keys(batch), <String>['book:a', 'book:b', 'book:c']);
      expect(
        batch.put.map((LocalShelfEntry e) => e.upload.refs.single),
        <String>['t:book:a|', 't:book:b|', 't:book:c|'],
      );
      expect(batch.put.map((LocalShelfEntry e) => e.upload.chars), <int>[
        9,
        2,
        4,
      ]);
    });

    test('组员本地没了：剩下的成员整组重发（服务端那行要去掉它的字数）', () {
      final LocalShelfEntry a = _e('book:a', chars: 1);
      final LocalShelfEntry b = _e('book:b', chars: 2);
      final ShelfSyncPlan plan = planShelfSync(
        _shelf(<LocalShelfEntry>[a]),
        _synced(
          <LocalShelfEntry>[a, b],
          <String, String>{'book:a': 'W1', 'book:b': 'W1'},
        ),
        reset: false,
      );
      expect(_keys(plan.batches.single), <String>['book:a']);
      expect(plan.preRemoveWorkIds, isEmpty, reason: 'W1 仍有 a 映射');
      expect(plan.droppedLocalKeys, <String>['book:b']);
    });

    test('reset 不按旧 state 分组：每条单独上报', () {
      final LocalShelfEntry a = _e('book:a', chars: 1);
      final LocalShelfEntry b = _e('book:b', chars: 2);
      final ShelfSyncPlan plan = planShelfSync(
        _shelf(<LocalShelfEntry>[a, b]),
        _synced(
          <LocalShelfEntry>[a, b],
          <String, String>{'book:a': 'W1', 'book:b': 'W1'},
        ),
        reset: true,
      );
      expect(_keys(plan.batches.single), <String>['book:a', 'book:b']);
      expect(
        plan.batches.single.put.map((LocalShelfEntry e) => e.upload.chars),
        <int>[1, 2],
      );
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

    test('书架上限：读完优先、其次最近活动；超出的计入 droppedForShelfLimit', () {
      final List<LocalShelfEntry> entries = <LocalShelfEntry>[
        _e('book:a', lastActiveAt: 10),
        _e('book:b', finishedAt: 1000),
        _e('book:c', lastActiveAt: 50),
        _e('book:d', finishedAt: 5),
        _e('book:e', lastActiveAt: 30),
      ];
      final ShelfSyncPlan plan = planShelfSync(
        _shelf(entries),
        LeaderboardSyncState.empty,
        reset: true,
        maxShelfRows: 3,
      );
      expect(plan.droppedForShelfLimit, 2);
      expect(_keys(plan.batches.single), <String>[
        'book:b',
        'book:c',
        'book:d',
      ]);

      // 已同步的在读条目被新读完的挤出去：它的作品在 put 之前先删，腾出行数。
      final ShelfSyncPlan inc = planShelfSync(
        _shelf(entries),
        _synced(
          <LocalShelfEntry>[entries[0], entries[1], entries[2]],
          <String, String>{'book:a': 'WA', 'book:b': 'WB', 'book:c': 'WC'},
        ),
        reset: false,
        maxShelfRows: 3,
      );
      expect(inc.preRemoveWorkIds, <String>['WA']);
      expect(inc.batches.single.newEntriesOnly, isTrue);
      expect(_keys(inc.batches.single), <String>['book:d']);
      expect(capShelfEntries(entries, max: 10).$2, 0);
    });
  });

  group('packShelfGroups', () {
    test('组不跨批；超过单批的大组才拆开', () {
      List<LocalShelfEntry> g(String p, int n) => <LocalShelfEntry>[
        for (int i = 0; i < n; i++) _e('$p$i'),
      ];
      final List<List<LocalShelfEntry>> out = packShelfGroups(
        <List<LocalShelfEntry>>[g('a', 3), g('b', 3), g('c', 1), g('d', 7)],
        5,
      );
      expect(out.map((List<LocalShelfEntry> b) => b.length), <int>[3, 4, 5, 2]);
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
    test('往返（含待补封面）', () {
      const LeaderboardSyncState s = LeaderboardSyncState(
        entries: <String, SyncedEntry>{
          'book:a': SyncedEntry(hash: 'h1', workId: 'W1'),
        },
        daily: <String, int>{'2026-09-01': 3},
        shelfCount: 1,
        pendingCovers: <String>{'book:a'},
      );
      final LeaderboardSyncState back = LeaderboardSyncState.fromJson(
        (jsonDecode(jsonEncode(s.toJson())) as Map<Object?, Object?>)
            .cast<String, dynamic>(),
      );
      expect(back.entries, s.entries);
      expect(back.daily, s.daily);
      expect(back.shelfCount, 1);
      expect(back.pendingCovers, <String>{'book:a'});
      expect(back.neverSynced, isFalse);
      expect(LeaderboardSyncState.empty.neverSynced, isTrue);
      expect(
        LeaderboardSyncState.fromJson(<String, dynamic>{}).pendingCovers,
        isEmpty,
      );
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
    late bool Function(Map<String, dynamic> body)? shelfFullWhen;
    late bool Function(int i)? needsCover;
    late List<int> coverStatuses;

    setUp(() {
      uploadDevice = null;
      shelfErrors = <(int, String)>[];
      shelfCalls = 0;
      shelfBodies = <Map<String, dynamic>>[];
      coverUploads = <String>[];
      serverShelfCount = 0;
      failOnShelfCall = -1;
      workIdByTitle = <String, String>{};
      shelfFullWhen = null;
      needsCover = null;
      coverStatuses = <int>[];
    });

    String workIdFor(String title) =>
        workIdByTitle[title] ?? 'W_${title.replaceAll(':', '_')}';

    http.Response json(Object body, [int status = 200]) => http.Response.bytes(
      utf8.encode(jsonEncode(body)),
      status,
      headers: <String, String>{'content-type': 'application/json'},
    );

    List<String> putTitles(Map<String, dynamic> body) => <String>[
      for (final Object? p in body['put'] as List<Object?>)
        (p as Map<Object?, Object?>)['title'] as String,
    ];

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
          if (shelfFullWhen?.call(body) ?? false) {
            shelfBodies.add(<String, dynamic>{'shelfFull': true, ...body});
            return json(<String, dynamic>{'error': 'shelf_full'}, 413);
          }
          shelfBodies.add(body);
          final List<String> titles = putTitles(body);
          return json(<String, dynamic>{
            'works': <Map<String, dynamic>>[
              for (int i = 0; i < titles.length; i++)
                <String, dynamic>{
                  'i': i,
                  'workId': workIdFor(titles[i]),
                  'needsCover': needsCover?.call(i) ?? i == 0,
                },
            ],
            'shelfCount': serverShelfCount,
          });
        }
        if (r.url.path.endsWith('/cover')) {
          coverUploads.add(r.url.pathSegments[2]);
          final int status = coverStatuses.isEmpty
              ? 200
              : coverStatuses.removeAt(0);
          if (status != 200) {
            return json(<String, dynamic>{'error': 'e$status'}, status);
          }
          return json(<String, dynamic>{'cover': '/img/x'});
        }
        return json(<String, dynamic>{'error': 'not_found'}, 404);
      }),
    );

    Future<Uint8List?> thumb(LocalShelfEntry e) async =>
        Uint8List.fromList(<int>[1, 2, 3]);

    test('首次：不查 me，reset 全量；needsCover 补传封面', () async {
      final ShelfSyncOutcome out = await syncShelf(
        client(),
        _shelf(
          <LocalShelfEntry>[_e('book:a'), _e('book:b')],
          <DailyCharsUpload>[_d('2026-09-01', 4)],
        ),
        LeaderboardSyncState.empty,
        coverThumb: thumb,
      );
      final LeaderboardSyncState s = out.state;
      expect(shelfBodies.single['reset'], isTrue);
      // 桩只对每批第 0 条回 needsCover。
      expect(coverUploads, <String>['W_book_a']);
      expect(s.entries['book:a']!.workId, 'W_book_a');
      expect(s.entries['book:b']!.workId, 'W_book_b');
      expect(s.daily, <String, int>{'2026-09-01': 4});
      expect(s.pendingCovers, isEmpty);
      expect(s.neverSynced, isFalse);
      expect(out.coverError, isNull);
      expect(out.droppedForShelfLimit, 0);
    });

    test('计数一致：本地全删的作品 put 前先 remove；改落别处的旧作品最后 remove', () async {
      final LocalShelfEntry a = _e('book:a', chars: 1);
      final LocalShelfEntry b = _e('book:b', chars: 1);
      final LocalShelfEntry c = _e('book:c', chars: 1);
      final LeaderboardSyncState state = _synced(
        <LocalShelfEntry>[a, b, c],
        <String, String>{'book:a': 'WA', 'book:b': 'WB', 'book:c': 'WA'},
      );
      serverShelfCount = 2; // WA、WB
      // a、c 同属 WA → 整组重发（各带自己的值）；服务端这次把两条都落到 WN（别名合并
      // 改判）；b 本地删了。
      workIdByTitle['book:a'] = 'WN';
      workIdByTitle['book:c'] = 'WN';
      final LeaderboardSyncState s = (await syncShelf(
        client(),
        _shelf(<LocalShelfEntry>[_e('book:a', chars: 9), c]),
        state,
      )).state;
      expect(shelfBodies, hasLength(3));
      expect(shelfBodies[0]['remove'], <String>['WB']);
      expect(shelfBodies[0]['put'], isEmpty);
      expect(shelfBodies[1]['reset'], isFalse);
      expect(putTitles(shelfBodies[1]), <String>['book:a', 'book:c']);
      expect(shelfBodies[1]['remove'], isEmpty);
      expect(shelfBodies[2]['remove'], <String>['WA']);
      expect(shelfBodies[2]['put'], isEmpty);
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
        for (int i = 0; i < 501; i++) _e(_k(i)),
      ];
      failOnShelfCall = 1; // 第二批失败
      Object? caught;
      try {
        await syncShelf(client(), _shelf(entries), LeaderboardSyncState.empty);
      } on LeaderboardSyncException catch (e) {
        caught = e;
        expect(e.partialState.entries, hasLength(500));
        expect(e.anyBatchAccepted, isTrue);
        expect(e.error, isA<LeaderboardApiException>());
        // 续传：用 partialState 再跑，服务端计数与 state 一致时只补剩下那条。
        serverShelfCount = 500;
        failOnShelfCall = -1;
        shelfBodies.clear();
        final LeaderboardSyncState s = (await syncShelf(
          client(),
          _shelf(entries),
          e.partialState,
        )).state;
        expect(shelfBodies.single['reset'], isFalse);
        expect(shelfBodies.single['put'], hasLength(1));
        expect(s.entries, hasLength(501));
      }
      expect(caught, isNotNull);
    });

    test('新条目落到已有作品上：该作品整组补发一轮（服务端那行不能只剩新条目）', () async {
      final LocalShelfEntry a = _e('book:a', chars: 1);
      serverShelfCount = 1;
      workIdByTitle['book:a'] = 'W1';
      workIdByTitle['book:n'] = 'W1';
      final LeaderboardSyncState s = (await syncShelf(
        client(),
        _shelf(<LocalShelfEntry>[a, _e('book:n', chars: 5)]),
        _synced(<LocalShelfEntry>[a], <String, String>{'book:a': 'W1'}),
      )).state;
      expect(shelfBodies, hasLength(2));
      expect(putTitles(shelfBodies[0]), <String>['book:n']);
      expect(putTitles(shelfBodies[1]), <String>['book:a', 'book:n']);
      expect(s.entries['book:a']!.workId, 'W1');
      expect(s.entries['book:n']!.workId, 'W1');
      expect(s.entries['book:n']!.hash, isNotEmpty);
    });

    test('reset 分批劈开同一作品：补发一轮把整组放进同一批', () async {
      final List<LocalShelfEntry> entries = <LocalShelfEntry>[
        for (int i = 0; i < 501; i++) _e(_k(i)),
      ];
      workIdByTitle[_k(0)] = 'WS';
      workIdByTitle[_k(500)] = 'WS';
      final LeaderboardSyncState s = (await syncShelf(
        client(),
        _shelf(entries),
        LeaderboardSyncState.empty,
      )).state;
      expect(shelfBodies, hasLength(3));
      expect(putTitles(shelfBodies[2]), <String>[_k(0), _k(500)]);
      expect(s.entries[_k(0)]!.workId, 'WS');
    });

    test('书架满（413 shelf_full）：只丢新条目，已同步条目的更新与 daily 照常', () async {
      final LocalShelfEntry a = _e('book:a', chars: 1);
      serverShelfCount = 1;
      shelfFullWhen = (Map<String, dynamic> body) =>
          putTitles(body).contains('book:new1');
      final ShelfSyncOutcome out = await syncShelf(
        client(),
        _shelf(
          <LocalShelfEntry>[
            _e('book:a', chars: 2),
            _e('book:new1'),
            _e('book:new2'),
          ],
          <DailyCharsUpload>[_d('2026-09-01', 7)],
        ),
        _synced(<LocalShelfEntry>[a], <String, String>{'book:a': 'W_book_a'}),
      );
      expect(putTitles(shelfBodies[0]), <String>['book:a']);
      expect(shelfBodies[0]['daily'], hasLength(1));
      expect(shelfBodies[1]['shelfFull'], isTrue);
      expect(out.droppedForShelfLimit, 2);
      expect(out.state.entries.keys, <String>['book:a']);
      expect(out.state.daily, <String, int>{'2026-09-01': 7});
      expect(
        out.state.entries['book:a']!.hash,
        _e('book:a', chars: 2).upload.contentHash(),
      );
    });

    test('封面：第一个 429 立即停下，剩余留待补；hash 不清空，下次只补封面不重 put', () async {
      needsCover = (int i) => true;
      coverStatuses = <int>[429];
      final List<LocalShelfEntry> entries = <LocalShelfEntry>[
        _e('book:a'),
        _e('book:b'),
        _e('book:c'),
      ];
      final ShelfSyncOutcome out = await syncShelf(
        client(),
        _shelf(entries),
        LeaderboardSyncState.empty,
        coverThumb: thumb,
      );
      expect(coverUploads, <String>['W_book_a'], reason: '429 后不再补');
      expect(out.coverError, isA<LeaderboardApiException>());
      expect(out.state.pendingCovers, <String>{'book:a', 'book:b', 'book:c'});
      for (final LocalShelfEntry e in entries) {
        expect(out.state.entries[e.localKey]!.hash, e.upload.contentHash());
      }

      // 下次：书架没变 → 不 put；只补封面。
      serverShelfCount = 3;
      shelfBodies.clear();
      coverUploads.clear();
      final ShelfSyncOutcome next = await syncShelf(
        client(),
        _shelf(entries),
        out.state,
        coverThumb: thumb,
      );
      expect(shelfBodies, isEmpty);
      expect(coverUploads, <String>['W_book_a', 'W_book_b', 'W_book_c']);
      expect(next.state.pendingCovers, isEmpty);
      expect(next.coverError, isNull);
    });

    test('封面：5xx 同样停下；4xx 与本地缩略图失败只放弃该作品、继续后面的', () async {
      needsCover = (int i) => true;
      coverStatuses = <int>[400, 503];
      final ShelfSyncOutcome out = await syncShelf(
        client(),
        _shelf(<LocalShelfEntry>[
          _e('book:a'),
          _e('book:b'),
          _e('book:c'),
          _e('book:d'),
        ]),
        LeaderboardSyncState.empty,
        coverThumb: (LocalShelfEntry e) async {
          if (e.localKey == 'book:a') throw StateError('disk');
          return Uint8List.fromList(<int>[1]);
        },
      );
      // a 本地失败放弃；b 400 放弃；c 503 停下；d 没轮到。
      expect(coverUploads, <String>['W_book_b', 'W_book_c']);
      expect(out.coverError, isA<StateError>());
      expect(out.state.pendingCovers, <String>{'book:c', 'book:d'});
    });

    test('409 conflict：原样重发该批（最多 3 次），成功即继续', () async {
      shelfErrors = <(int, String)>[(409, 'conflict'), (409, 'conflict')];
      final LeaderboardSyncState s = (await syncShelf(
        client(),
        _shelf(<LocalShelfEntry>[_e('book:a')]),
        LeaderboardSyncState.empty,
      )).state;
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
          isA<LeaderboardSyncException>()
              .having(
                (LeaderboardSyncException e) => e.partialState.neverSynced,
                'partialState.neverSynced',
                isTrue,
              )
              .having(
                (LeaderboardSyncException e) => e.anyBatchAccepted,
                'anyBatchAccepted',
                isFalse,
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
        _shelf(<LocalShelfEntry>[for (int i = 0; i < 501; i++) _e(_k(i))]),
        _synced(<LocalShelfEntry>[a], <String, String>{'book:a': 'W1'}),
        claim: true,
      );
      expect(shelfBodies, hasLength(2));
      expect(shelfBodies[0]['reset'], isTrue);
      expect(shelfBodies[0]['claim'], isTrue);
      expect(shelfBodies[1]['reset'], isFalse);
      expect(shelfBodies[1].containsKey('claim'), isFalse);
    });

    test('已知同 workId 的条目各自上报（服务端合并），workId 记到每个 localKey', () async {
      final LocalShelfEntry a = _e('book:a', title: 'T');
      final LocalShelfEntry b = _e('book:b', title: 'T');
      serverShelfCount = 1;
      workIdByTitle['T'] = 'WT';
      final LeaderboardSyncState s = (await syncShelf(
        client(),
        _shelf(<LocalShelfEntry>[
          _e('book:a', chars: 5, title: 'T'),
          _e('book:b', chars: 7, title: 'T'),
        ]),
        _synced(
          <LocalShelfEntry>[a, b],
          <String, String>{'book:a': 'WT', 'book:b': 'WT'},
        ),
      )).state;
      final List<Object?> put = shelfBodies.single['put'] as List<Object?>;
      expect(put, hasLength(2));
      expect(
        put.map((Object? p) => (p as Map<Object?, Object?>)['chars']),
        <int>[5, 7],
      );
      expect(s.entries['book:a']!.workId, 'WT');
      expect(s.entries['book:b']!.workId, 'WT');
    });
  });
}
