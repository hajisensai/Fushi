import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/scraper/auto_scrape_service.dart';
import 'package:fushi/src/media/video/scraper/cover_meta_store.dart';
import 'package:fushi/src/media/video/scraper/cover_scraper_service.dart';
import 'package:fushi/src/media/video/scraper/scraper_types.dart';
import 'package:fushi/src/media/video/video_book_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;
import 'package:transparent_image/transparent_image.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FushiDatabase db;
  late VideoBookRepository repo;
  late Directory tmp;
  late Directory library;
  late Directory covers;
  late CoverMetaStore coverMeta;
  late int factoryCalls;

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    repo = VideoBookRepository(db);
    tmp = await Directory.systemTemp.createTemp('sidecar_auto_service_');
    library = Directory(p.join(tmp.path, 'library'));
    covers = Directory(p.join(tmp.path, 'covers'));
    await library.create(recursive: true);
    await covers.create(recursive: true);
    coverMeta = CoverMetaStore(covers);
    factoryCalls = 0;
  });

  tearDown(() async {
    await db.close();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Future<VideoBookRow> seed({
    required String bookUid,
    required String videoPath,
    int? sourceId,
  }) async {
    await db.upsertVideoBook(VideoBooksCompanion(
      bookUid: Value<String>(bookUid),
      title: Value<String>(bookUid),
      videoPath: Value<String>(videoPath),
      sourceId: Value<int?>(sourceId),
    ));
    return (await repo.getByBookUid(bookUid))!;
  }

  Future<VideoBookRow> seedLocal(String bookUid) async {
    final File video = File(p.join(library.path, '$bookUid.mkv'));
    await video.parent.create(recursive: true);
    await video.writeAsBytes(<int>[0, 1, 2, 3]);
    return seed(bookUid: bookUid, videoPath: video.path);
  }

  Future<void> writePoster() =>
      File(p.join(library.path, 'poster.jpg')).writeAsBytes(kTransparentImage);

  Future<CoverScraperService> serviceFactory() async {
    factoryCalls++;
    return CoverScraperService(
      repository: repo,
      coverMetaStore: coverMeta,
      coversDirectory: covers,
    );
  }

  VideoScrapeAutoService build({bool Function()? isEnabled}) =>
      VideoScrapeAutoService(
        repository: repo,
        serviceFactory: serviceFactory,
        isEnabled: isEnabled,
        perBookDelay: Duration.zero,
      );

  test('兼容本地条目自动采用用户 sidecar', () async {
    final VideoBookRow book = await seedLocal('local');
    await writePoster();
    final VideoScrapeAutoService auto = build();

    await auto.sweep(<VideoBookRow>[book]);

    expect(auto.attemptedCount, 1);
    expect(factoryCalls, 1);
    expect((await repo.getByBookUid(book.bookUid))!.coverPath, isNotNull);
    expect((await coverMeta.get(book.bookUid))!.origin, CoverOrigin.sidecar);
  });

  test('远端与已登记来源条目不创建旧 sidecar service', () async {
    final VideoBookRow remote = await seed(
      bookUid: 'remote',
      videoPath: 'https://host/stream.m3u8',
    );
    final VideoBookRow sourced = await seed(
      bookUid: 'sourced',
      videoPath: p.join(library.path, 'sourced.mkv'),
      sourceId: 99,
    );
    final VideoScrapeAutoService auto = build();

    await auto.sweep(<VideoBookRow>[remote, sourced]);

    expect(auto.attemptedCount, 0);
    expect(factoryCalls, 0);
  });

  test('历史资料行不阻止采用用户后来添加的 sidecar', () async {
    final VideoBookRow book = await seedLocal('done');
    await db.upsertVideoScrapeMeta(
      VideoScrapeMetaCompanion.insert(
        bookUid: book.bookUid,
        source: 'anidb',
        subjectId: '1',
        title: 'done',
        scrapedAt: DateTime(2026, 1, 1),
      ),
    );
    await writePoster();
    final VideoScrapeAutoService auto = build();

    await auto.sweep(<VideoBookRow>[book]);

    expect(auto.attemptedCount, 1);
    expect(factoryCalls, 1);
    expect((await coverMeta.get(book.bookUid))!.origin, CoverOrigin.sidecar);
  });

  test('每本每进程只尝试一次，forget 后可重新检查 sidecar', () async {
    final VideoBookRow book = await seedLocal('retry');
    final VideoScrapeAutoService auto = build();

    await auto.sweep(<VideoBookRow>[book]);
    await writePoster();
    await auto.sweep(<VideoBookRow>[book]);
    expect((await repo.getByBookUid(book.bookUid))!.coverPath, isNull);

    auto.forget(book.bookUid);
    await auto.sweep(<VideoBookRow>[book]);
    expect((await repo.getByBookUid(book.bookUid))!.coverPath, isNotNull);
  });

  test('兼容总闸每轮读取，关到开无需重建调度器', () async {
    final VideoBookRow book = await seedLocal('toggle');
    await writePoster();
    bool enabled = false;
    final VideoScrapeAutoService auto = build(isEnabled: () => enabled);

    await auto.sweep(<VideoBookRow>[book]);
    expect(factoryCalls, 0);

    enabled = true;
    await auto.sweep(<VideoBookRow>[book]);
    expect(factoryCalls, 1);
    expect((await repo.getByBookUid(book.bookUid))!.coverPath, isNotNull);
  });

  test('dispose 后不再创建 sidecar service', () async {
    final VideoBookRow book = await seedLocal('disposed');
    await writePoster();
    final VideoScrapeAutoService auto = build()..dispose();
    await auto.sweep(<VideoBookRow>[book]);
    expect(factoryCalls, 0);
    expect(auto.attemptedCount, 0);
  });
}
