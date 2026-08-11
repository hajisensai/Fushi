import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 媒体去重的**批量化不变量**。
///
/// 用户报告：「真就一个一个删，感觉要删很久啊」。根因不是磁盘也不是哈希，是
/// resolving 阶段每个副本要发 5 次独立 AnkiConnect 请求（findNotes 判定 +
/// notesInfo + updateNoteFields + findNotes 复核 + deleteMediaFile）。而
/// AnkiConnect 的 HTTP 服务是 25 ms QTimer 协作轮询、每 tick 只 accept 一条连
/// 接、无 keep-alive、全在 Anki 主线程——**每个请求的地板成本与请求大小无关**，
/// 所以耗时 ≈ 往返数 × 一个 tick。实测基线：120 个副本 = 606 次往返；用户的
/// 940 个副本 ≈ 4706 次 ≈ 至少 118 秒纯轮询等待。
///
/// 修复 = 把这些请求打进 AnkiConnect 的 `multi`。本文件钉死的核心不变量是
/// **往返数从 O(副本数) 降成 O(副本数 / [kAnkiMediaDedupBatchSize])**，以及批
/// 量化不许换来任何安全语义的退让（批内单条失败、合并改写、保守跳过）。
class _BatchCountingService extends AnkiConnectService {
  _BatchCountingService({required this.mediaDirPath, required this.notes});

  final String mediaDirPath;

  /// noteId → 字段表（真会被改写）。
  final Map<int, Map<String, String>> notes;

  /// 每次真实网络往返记一条（值 = 该次往返的动作名）。
  final List<String> roundTrips = <String>[];
  final List<String> deleted = <String>[];

  /// 批内单条失败注入。
  final Set<String> failDeletesFor = <String>{};
  final Set<int> failNoteUpdatesFor = <int>{};
  final Set<String> failFindNotesFor = <String>{};

  int roundTripsFor(String action) =>
      roundTrips.where((String a) => a == action).length;

  void _tick(String action) => roundTrips.add(action);

  @override
  Future<String> getMediaDirPath() async {
    _tick('getMediaDirPath');
    return mediaDirPath;
  }

  /// 本文件只关心副本数驱动的往返数，note type 一个都不需要（模板/styling
  /// 的引用改写由 `anki_media_dedup_orchestration_test.dart` 覆盖）。
  @override
  Future<List<String>> getModelNames() async {
    _tick('modelNames');
    return const <String>[];
  }

  @override
  Future<List<int>> findNotesByQuery(String query) async {
    _tick('findNotes');
    return _findNotes(query);
  }

  List<int> _findNotes(String query) {
    // 与真 Anki 一样是朴素子串检索，不做文件名边界判断。
    final String needle = query.replaceAll('"', '');
    return notes.entries
        .where((MapEntry<int, Map<String, String>> e) =>
            e.value.values.any((String v) => v.contains(needle)))
        .map((MapEntry<int, Map<String, String>> e) => e.key)
        .toList()
      ..sort();
  }

  @override
  Future<Map<int, Map<String, String>>> notesInfoMany(List<int> noteIds) async {
    _tick('notesInfo');
    return <int, Map<String, String>>{
      for (final int id in noteIds)
        if (notes[id] != null) id: notes[id]!,
    };
  }

  @override
  Future<void> updateNoteFields(int noteId, Map<String, String> fields) async {
    notes[noteId]!.addAll(fields);
  }

  @override
  Future<void> deleteMediaFile(String filename) async {
    deleted.add(filename);
    final File f = File('$mediaDirPath${Platform.pathSeparator}$filename');
    if (f.existsSync()) f.deleteSync();
  }

  @override
  Future<List<AnkiConnectBatchResult>> requestMulti(
      List<AnkiConnectAction> actions) async {
    if (actions.isEmpty) return const <AnkiConnectBatchResult>[];
    _tick(actions.first.action);
    final List<AnkiConnectBatchResult> out = <AnkiConnectBatchResult>[];
    for (final AnkiConnectAction a in actions) {
      out.add(await _dispatch(a));
    }
    return out;
  }

  Future<AnkiConnectBatchResult> _dispatch(AnkiConnectAction a) async {
    final Map<String, dynamic> params = a.params ?? const <String, dynamic>{};
    switch (a.action) {
      case 'findNotes':
        final String query = params['query'] as String;
        if (failFindNotesFor.contains(query)) {
          return const AnkiConnectBatchResult(error: 'search failed');
        }
        return AnkiConnectBatchResult(result: _findNotes(query));
      case 'updateNoteFields':
        final Map<String, dynamic> note =
            params['note'] as Map<String, dynamic>;
        final int id = note['id'] as int;
        if (failNoteUpdatesFor.contains(id)) {
          return const AnkiConnectBatchResult(error: 'note was not found');
        }
        await updateNoteFields(id, note['fields'] as Map<String, String>);
        return const AnkiConnectBatchResult();
      case 'deleteMediaFile':
        final String filename = params['filename'] as String;
        if (failDeletesFor.contains(filename)) {
          return const AnkiConnectBatchResult(error: 'cannot delete');
        }
        await deleteMediaFile(filename);
        return const AnkiConnectBatchResult();
      default:
        return const AnkiConnectBatchResult(error: 'unsupported action');
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory mediaDir;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    mediaDir = Directory.systemTemp.createTempSync('hibiki_dedup_batch');
  });

  tearDown(() {
    if (mediaDir.existsSync()) mediaDir.deleteSync(recursive: true);
  });

  void writeMedia(String name, List<int> bytes) {
    File('${mediaDir.path}${Platform.pathSeparator}$name')
        .writeAsBytesSync(bytes);
  }

  bool mediaExists(String name) =>
      File('${mediaDir.path}${Platform.pathSeparator}$name').existsSync();

  /// 造 [count] 个各自独立的重复组：`g<i>a.mp3`（保留份，名短）+
  /// `g<i>bbbb.mp3`（副本），每组字节长度不同所以绝不会混组；第 i 条笔记引用
  /// 第 i 个副本。
  _BatchCountingService buildCollection(int count) {
    final Map<int, Map<String, String>> notes = <int, Map<String, String>>{};
    for (int i = 0; i < count; i++) {
      final List<int> bytes = List<int>.filled(16 + i, i % 251);
      writeMedia('g${i}a.mp3', bytes);
      writeMedia('g${i}bbbb.mp3', bytes);
      notes[1000 + i] = <String, String>{'Front': '[sound:g${i}bbbb.mp3]'};
    }
    return _BatchCountingService(mediaDirPath: mediaDir.path, notes: notes);
  }

  int ceilDiv(int a, int b) => (a + b - 1) ~/ b;

  test('核心不变量：N 个副本的删除只发 ceil(N/批大小) 次往返，不是 N 次', () async {
    // 跨过两个批边界，确保不是「恰好一批」的偶然。
    final int n = kAnkiMediaDedupBatchSize * 2 + 3;
    final int expectedBatches = ceilDiv(n, kAnkiMediaDedupBatchSize);
    final _BatchCountingService service = buildCollection(n);
    final AnkiConnectRepository repo = AnkiConnectRepository(service: service);

    final AnkiMediaDedupReport? report = await repo.runMediaDedup();

    expect(report!.duplicatesRemoved, n);
    expect(report.skipped, 0);
    expect(service.deleted, hasLength(n));

    // ── 这三条是本次性能修复的全部意义所在 ──────────────────────────
    expect(service.roundTripsFor('deleteMediaFile'), expectedBatches,
        reason: '$n 个副本的删除必须收敛成 $expectedBatches 次往返（一批一次）');
    expect(service.roundTripsFor('updateNoteFields'), expectedBatches,
        reason: '笔记改写同样按批合并，不是一条笔记一次往返');
    // 判定 findNotes + 复核 findNotes，各一批一次。
    expect(service.roundTripsFor('findNotes'), expectedBatches * 2);
    expect(service.roundTripsFor('notesInfo'), expectedBatches);

    // 总往返数必须远小于副本数——旧实现是 5N + 常数（120 副本实测 606 次）。
    expect(service.roundTrips.length, lessThan(n),
        reason: '总往返 ${service.roundTrips.length} 不该逼近副本数 $n');
  });

  test('干跑（用户确认前那一遍扫描）同样是批量的：每批 2 次往返', () async {
    final int n = kAnkiMediaDedupBatchSize * 2 + 3;
    final int expectedBatches = ceilDiv(n, kAnkiMediaDedupBatchSize);
    final _BatchCountingService service = buildCollection(n);
    final AnkiConnectRepository repo = AnkiConnectRepository(service: service);

    final AnkiMediaDedupReport? report = await repo.runMediaDedup(dryRun: true);

    expect(report!.deletions, hasLength(n));
    // 干跑只需要「查引用 + 拉字段」，一个字节都不写。
    expect(service.roundTripsFor('findNotes'), expectedBatches);
    expect(service.roundTripsFor('notesInfo'), expectedBatches);
    expect(service.roundTripsFor('updateNoteFields'), 0);
    expect(service.roundTripsFor('deleteMediaFile'), 0);
    expect(service.deleted, isEmpty);
  });

  test('批内单条删除失败：只有它计入 skipped，同批其余照删', () async {
    const int n = 4;
    final _BatchCountingService service = buildCollection(n);
    service.failDeletesFor.add('g2bbbb.mp3');
    final AnkiConnectRepository repo = AnkiConnectRepository(service: service);

    final AnkiMediaDedupReport? report = await repo.runMediaDedup();

    expect(report!.duplicatesRemoved, n - 1);
    expect(report.skipped, 1);
    expect(
      report.deletions.map((MediaDedupDeletion d) => d.filename),
      isNot(contains('g2bbbb.mp3')),
    );
    expect(mediaExists('g2bbbb.mp3'), isTrue);
    // 引用已经改指保留份，文件留着不会产生悬空引用（保留份还在）。
    expect(service.notes[1002]!['Front'], '[sound:g2a.mp3]');
    expect(mediaExists('g2a.mp3'), isTrue);
    // 整批仍然只发一次删除往返。
    expect(service.roundTripsFor('deleteMediaFile'), 1);
  });

  test('批内单条笔记改写失败：复核挡下删除，该副本 skipped，其余照删', () async {
    const int n = 3;
    final _BatchCountingService service = buildCollection(n);
    service.failNoteUpdatesFor.add(1001);
    final AnkiConnectRepository repo = AnkiConnectRepository(service: service);

    final AnkiMediaDedupReport? report = await repo.runMediaDedup();

    expect(report!.skipped, 1);
    expect(report.duplicatesRemoved, n - 1);
    // 字段没改成 → 复核仍能检索到 → 绝不删（否则卡片会显示问号方框）。
    expect(service.notes[1001]!['Front'], '[sound:g1bbbb.mp3]');
    expect(mediaExists('g1bbbb.mp3'), isTrue);
    expect(service.deleted, isNot(contains('g1bbbb.mp3')));
  });

  test('批内单条检索失败：不知道有没有人引用 → 保守跳过，绝不删', () async {
    const int n = 3;
    final _BatchCountingService service = buildCollection(n);
    service.failFindNotesFor.add('"g1bbbb.mp3"');
    final AnkiConnectRepository repo = AnkiConnectRepository(service: service);

    final AnkiMediaDedupReport? report = await repo.runMediaDedup();

    expect(report!.skipped, 1);
    expect(report.duplicatesRemoved, n - 1);
    expect(mediaExists('g1bbbb.mp3'), isTrue);
    // 检索失败被当成空列表的话这里会是 0 次跳过、文件被删掉。
    expect(service.deleted, isNot(contains('g1bbbb.mp3')));
  });

  test('同一条笔记引用同批多个副本：改写合并，后写不抹掉先写', () async {
    // `updateNoteFields` 是整字段覆盖。两个副本各算各的改写结果再分别写回，
    // 第二次写就会把第一次的改写抹掉，笔记里留下一个指向已删文件的引用。
    writeMedia('x.mp3', <int>[1, 1, 1]);
    writeMedia('xxxx.mp3', <int>[1, 1, 1]);
    writeMedia('y.mp3', <int>[2, 2, 2, 2]);
    writeMedia('yyyy.mp3', <int>[2, 2, 2, 2]);
    final _BatchCountingService service = _BatchCountingService(
      mediaDirPath: mediaDir.path,
      notes: <int, Map<String, String>>{
        7: <String, String>{
          'Front': '[sound:xxxx.mp3] 与 [sound:yyyy.mp3]',
        },
      },
    );
    final AnkiConnectRepository repo = AnkiConnectRepository(service: service);

    final AnkiMediaDedupReport? report = await repo.runMediaDedup();

    expect(report!.duplicatesRemoved, 2);
    expect(report.skipped, 0);
    expect(service.notes[7]!['Front'], '[sound:x.mp3] 与 [sound:y.mp3]');
    expect(mediaExists('xxxx.mp3'), isFalse);
    expect(mediaExists('yyyy.mp3'), isFalse);
    // 两个副本命中同一条笔记 → 合并成一条 update，整批一次往返。
    expect(service.roundTripsFor('updateNoteFields'), 1);
  });

  test('进度按批推进：done 单调不倒退且收敛到 total', () async {
    final int n = kAnkiMediaDedupBatchSize * 2 + 3;
    final _BatchCountingService service = buildCollection(n);
    final AnkiConnectRepository repo = AnkiConnectRepository(service: service);
    final List<AnkiMediaDedupProgress> events = <AnkiMediaDedupProgress>[];

    await repo.runMediaDedup(onProgress: events.add);

    final List<AnkiMediaDedupProgress> resolving = events
        .where((AnkiMediaDedupProgress p) =>
            p.stage == AnkiMediaDedupStage.resolving)
        .toList();
    // 每批一次 + 收尾一次：进度是真按批走的，不是假装逐个。
    expect(resolving, hasLength(ceilDiv(n, kAnkiMediaDedupBatchSize) + 1));
    for (int i = 1; i < resolving.length; i++) {
      expect(resolving[i].done, greaterThanOrEqualTo(resolving[i - 1].done));
      expect(resolving[i].bytesFreed,
          greaterThanOrEqualTo(resolving[i - 1].bytesFreed));
    }
    expect(resolving.last.done, n);
    expect(resolving.last.total, n);
  });

  // ── AnkiConnectService 层：一次 requestMulti = 一次 HTTP POST ──────────

  test('requestMulti：N 条子 action 打成恰好 1 次 HTTP POST', () async {
    final List<http.Request> sent = <http.Request>[];
    final http.Client client = MockClient((http.Request request) async {
      sent.add(request);
      final Map<String, dynamic> body =
          jsonDecode(request.body) as Map<String, dynamic>;
      final List<dynamic> actions =
          (body['params'] as Map<String, dynamic>)['actions'] as List<dynamic>;
      return http.Response(
        jsonEncode(<String, Object?>{
          'result': <Map<String, Object?>>[
            for (int i = 0; i < actions.length; i++)
              <String, Object?>{'result': null, 'error': null},
          ],
          'error': null,
        }),
        200,
        headers: <String, String>{'content-type': 'application/json'},
      );
    });
    final AnkiConnectService service = AnkiConnectService(client: client);

    final List<AnkiConnectBatchResult> results = await service.deleteMediaFiles(
      <String>[for (int i = 0; i < 40; i++) 'f$i.mp3'],
    );

    expect(results, hasLength(40));
    expect(sent, hasLength(1), reason: '40 个删除必须是 1 次 HTTP 往返');
    final Map<String, dynamic> body =
        jsonDecode(sent.single.body) as Map<String, dynamic>;
    expect(body['action'], 'multi');
    expect(body['version'], 6);
    final List<dynamic> actions =
        (body['params'] as Map<String, dynamic>)['actions'] as List<dynamic>;
    expect(actions, hasLength(40));
    for (final dynamic raw in actions) {
      final Map<String, dynamic> a = raw as Map<String, dynamic>;
      expect(a['action'], 'deleteMediaFile');
      // 子 action 必须自带 version 6，否则成功值是裸值、与信封混在一个数组里
      // 无法可靠区分。
      expect(a['version'], 6);
    }
  });

  test('requestMulti：超过 kMultiBatchSize 时按批切，往返数 = ceil(n/批)', () async {
    final List<http.Request> sent = <http.Request>[];
    final http.Client client = MockClient((http.Request request) async {
      sent.add(request);
      final Map<String, dynamic> body =
          jsonDecode(request.body) as Map<String, dynamic>;
      final List<dynamic> actions =
          (body['params'] as Map<String, dynamic>)['actions'] as List<dynamic>;
      return http.Response(
        jsonEncode(<String, Object?>{
          'result': <Map<String, Object?>>[
            for (int i = 0; i < actions.length; i++)
              <String, Object?>{'result': null, 'error': null},
          ],
          'error': null,
        }),
        200,
        headers: <String, String>{'content-type': 'application/json'},
      );
    });
    final AnkiConnectService service = AnkiConnectService(client: client);
    final int n = AnkiConnectService.kMultiBatchSize * 2 + 1;

    final List<AnkiConnectBatchResult> results = await service.deleteMediaFiles(
      <String>[for (int i = 0; i < n; i++) 'f$i.mp3'],
    );

    expect(results, hasLength(n));
    expect(sent, hasLength(3));
  });

  test('requestMulti：批内单条 error 逐条透出，不把整批吞掉', () async {
    final http.Client client = MockClient((http.Request request) async {
      return http.Response(
        jsonEncode(<String, Object?>{
          'result': <Map<String, Object?>>[
            <String, Object?>{'result': null, 'error': null},
            <String, Object?>{'result': null, 'error': 'cannot delete'},
            <String, Object?>{'result': null, 'error': null},
          ],
          'error': null,
        }),
        200,
        headers: <String, String>{'content-type': 'application/json'},
      );
    });
    final AnkiConnectService service = AnkiConnectService(client: client);

    final List<AnkiConnectBatchResult> results = await service.deleteMediaFiles(
      <String>['a.mp3', 'b.mp3', 'c.mp3'],
    );

    expect(results.map((AnkiConnectBatchResult r) => r.isError),
        <bool>[false, true, false]);
    expect(results[1].error, 'cannot delete');
  });

  test('findNotesByQueries：失败条返回 null，绝不降级成空列表', () async {
    final http.Client client = MockClient((http.Request request) async {
      return http.Response(
        jsonEncode(<String, Object?>{
          'result': <Map<String, Object?>>[
            <String, Object?>{
              'result': <int>[1, 2],
              'error': null,
            },
            <String, Object?>{'result': null, 'error': 'search failed'},
          ],
          'error': null,
        }),
        200,
        headers: <String, String>{'content-type': 'application/json'},
      );
    });
    final AnkiConnectService service = AnkiConnectService(client: client);

    final List<List<int>?> got =
        await service.findNotesByQueries(<String>['"a"', '"b"']);

    expect(got[0], <int>[1, 2]);
    expect(got[1], isNull, reason: '检索失败当成「没人引用」就会删掉仍在用的媒体');
  });

  test('requestMulti：结果条数与请求条数对不上 → 抛，不静默错位', () async {
    final http.Client client = MockClient((http.Request request) async {
      return http.Response(
        jsonEncode(<String, Object?>{
          'result': <Map<String, Object?>>[
            <String, Object?>{'result': null, 'error': null},
          ],
          'error': null,
        }),
        200,
        headers: <String, String>{'content-type': 'application/json'},
      );
    });
    final AnkiConnectService service = AnkiConnectService(client: client);

    expect(
      () => service.deleteMediaFiles(<String>['a.mp3', 'b.mp3']),
      throwsA(isA<AnkiConnectException>()),
    );
  });
}
