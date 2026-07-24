import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/cover_ui/batch_scrape_controller.dart';
import 'package:hibiki/src/media/video/scraper/alias_cache.dart';
import 'package:hibiki/src/media/video/scraper/bangumi_client.dart';
import 'package:hibiki/src/media/video/scraper/cover_meta_store.dart';
import 'package:hibiki/src/media/video/scraper/poster_downloader.dart';
import 'package:hibiki/src/media/video/scraper/poster_scraper_service.dart';
import 'package:hibiki/src/media/video/video_book_repository.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'dart:io';

/// 最小合法 PNG 魔数字节。
final List<int> _fakePng = <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x01, 0x02, 0x03,
];

String _bangumiBody({required int id, required String name}) =>
    jsonEncode(<String, Object?>{
      'data': <Object?>[
        <String, Object?>{
          'id': id,
          'name': name,
          'images': <String, Object?>{'large': 'https://img/b$id.png'},
          'platform': 'TV',
          'eps': 12,
          'date': '2020-01-01',
          'score': 8.0,
        },
      ],
    });

void main() {
  late HibikiDatabase db;
  late VideoBookRepository repo;
  late Directory tmp;

  setUp(() async {
    db = HibikiDatabase.forTesting(NativeDatabase.memory());
    repo = VideoBookRepository(db);
    tmp = await Directory.systemTemp.createTemp('batch_scrape_ctrl_');
  });

  tearDown(() async {
    await db.close();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Future<VideoBookRow> seed(String uid, String videoPath) async {
    await db.upsertVideoBook(VideoBooksCompanion(
      bookUid: Value(uid),
      title: Value(uid),
      videoPath: Value(videoPath),
    ));
    return (await repo.getByBookUid(uid))!;
  }

  /// [gate]：每次 Bangumi 搜索前等待的闸门（外部控制流推进节奏，模拟慢网络）。
  PosterScraperService build({Future<void> Function()? gate}) =>
      PosterScraperService(
        repository: repo,
        coverMetaStore: CoverMetaStore(tmp),
        aliasCache: AliasCache(tmp),
        bangumiClient: BangumiClient(
          client: MockClient((http.Request req) async {
            if (gate != null) await gate();
            return http.Response(
              _bangumiBody(id: 1, name: 'Foo'),
              200,
              headers: const <String, String>{
                'content-type': 'application/json'
              },
            );
          }),
        ),
        posterDownloader: PosterDownloader(
          client: MockClient((http.Request req) async => http.Response.bytes(
                _fakePng,
                200,
                headers: const <String, String>{'content-type': 'image/png'},
              )),
        ),
        enableSidecar: false,
        coversDirectory: tmp,
      );

  /// 等控制器进入 done（监听器驱动，兼容真实文件/DB IO 的完成时序）。
  Future<void> waitForDone(BatchScrapeController controller) {
    if (controller.phase == BatchScrapePhase.done) {
      return Future<void>.value();
    }
    final Completer<void> done = Completer<void>();
    void onChanged() {
      if (controller.phase == BatchScrapePhase.done && !done.isCompleted) {
        done.complete();
      }
    }

    controller.addListener(onChanged);
    return done.future
        .timeout(const Duration(seconds: 30))
        .whenComplete(() => controller.removeListener(onChanged));
  }

  test('start→完成：phase 走 idle→running→done，结果保留、汇总正确', () async {
    final VideoBookRow a =
        await seed('video/a', p.join('lib', 'Foo', 'Foo - 01.mkv'));
    final BatchScrapeController controller = BatchScrapeController();
    addTearDown(controller.dispose);
    expect(controller.phase, BatchScrapePhase.idle);

    expect(
      controller.start(service: build(), books: <VideoBookRow>[a]),
      isTrue,
    );
    expect(controller.isRunning, isTrue);
    await waitForDone(controller);

    expect(controller.phase, BatchScrapePhase.done);
    expect(controller.rows, hasLength(1));
    expect(controller.rows.single.outcome, isA<ScrapeApplied>());
    expect(controller.summary.applied, 1);
    // done 后结果保留（重开弹窗可继续确认）。
    expect(controller.rows, isNotEmpty);
  });

  test('运行中重复 start 被拒绝（防重复启动）', () async {
    final VideoBookRow a =
        await seed('video/a', p.join('lib', 'Foo', 'Foo - 01.mkv'));
    final Completer<void> gate = Completer<void>();
    final BatchScrapeController controller = BatchScrapeController();
    addTearDown(controller.dispose);

    expect(
      controller.start(
        service: build(gate: () => gate.future),
        books: <VideoBookRow>[a],
      ),
      isTrue,
    );
    expect(controller.isRunning, isTrue);
    expect(
      controller.start(service: build(), books: <VideoBookRow>[a]),
      isFalse,
      reason: '同时只允许一个批量在跑',
    );
    gate.complete();
    // 放行后自然完成。
    await waitForDone(controller);
    expect(controller.phase, BatchScrapePhase.done);
  });

  test('cancel 真中止：流不再产出、phase=done、已产出结果保留', () async {
    final VideoBookRow a =
        await seed('video/a', p.join('lib', 'Foo', 'Foo - 01.mkv'));
    final VideoBookRow b =
        await seed('video/b', p.join('lib', 'Bar', 'Bar - 01.mkv'));
    // 闸门：首组放行、第二组挂起 → cancel 时恰有 1 行产出。
    int calls = 0;
    final Completer<void> secondGate = Completer<void>();
    final PosterScraperService svc = build(gate: () {
      calls++;
      return calls >= 2 ? secondGate.future : Future<void>.value();
    });
    final BatchScrapeController controller = BatchScrapeController();
    addTearDown(controller.dispose);
    controller.start(service: svc, books: <VideoBookRow>[a, b]);
    // 等首组产出。
    while (controller.rows.isEmpty) {
      await pumpEventQueue();
    }
    await controller.cancel();
    expect(controller.phase, BatchScrapePhase.done);
    final int rowsAfterCancel = controller.rows.length;
    secondGate.complete();
    await pumpEventQueue();
    expect(controller.rows.length, rowsAfterCancel, reason: '取消后流不再产出新行');
    // 已产出结果保留。
    expect(rowsAfterCancel, greaterThanOrEqualTo(1));
  });

  test('attach/detach 视图计数 + resetIfDone 清结果回 idle', () async {
    final VideoBookRow a =
        await seed('video/a', p.join('lib', 'Foo', 'Foo - 01.mkv'));
    final BatchScrapeController controller = BatchScrapeController();
    addTearDown(controller.dispose);
    controller.attachView();
    expect(controller.attachedViews, 1);
    controller.detachView();
    controller.detachView(); // 不下穿 0。
    expect(controller.attachedViews, 0);

    // running 时 resetIfDone 是 no-op。
    final Completer<void> gate = Completer<void>();
    controller.start(
      service: build(gate: () => gate.future),
      books: <VideoBookRow>[a],
    );
    controller.resetIfDone();
    expect(controller.isRunning, isTrue);
    gate.complete();
    await waitForDone(controller);
    expect(controller.phase, BatchScrapePhase.done);
    expect(controller.rows, isNotEmpty);
    controller.resetIfDone();
    expect(controller.phase, BatchScrapePhase.idle);
    expect(controller.rows, isEmpty);
  });
}
