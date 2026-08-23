import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/scraper/cover_meta_store.dart';
import 'package:fushi/src/media/video/scraper/cover_scraper_service.dart';
import 'package:fushi/src/media/video/scraper/scraper_types.dart';
import 'package:fushi/src/media/video/scraper/sidecar_scanner.dart';
import 'package:fushi/src/media/video/video_book_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;
import 'package:transparent_image/transparent_image.dart';

import '../../../helpers/cover_cache_test_helpers.dart';

class _StubGeneratedArtifactChecker implements SidecarGeneratedArtifactChecker {
  const _StubGeneratedArtifactChecker(this.result);

  final bool result;

  @override
  Future<bool> isUnmodifiedGeneratedArtifact(String absolutePath) async =>
      result;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FushiDatabase db;
  late VideoBookRepository repo;
  late Directory tmp;
  late Directory library;
  late Directory covers;
  late CoverMetaStore coverMeta;

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    repo = VideoBookRepository(db);
    tmp = await Directory.systemTemp.createTemp('sidecar_cover_service_');
    library = Directory(p.join(tmp.path, 'library'));
    covers = Directory(p.join(tmp.path, 'covers'));
    await library.create(recursive: true);
    await covers.create(recursive: true);
    coverMeta = CoverMetaStore(covers);
  });

  tearDown(() async {
    await db.close();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  CoverScraperService build({
    SidecarGeneratedArtifactChecker? generatedArtifactChecker,
  }) =>
      CoverScraperService(
        repository: repo,
        coverMetaStore: coverMeta,
        generatedSidecarArtifactChecker: generatedArtifactChecker,
        coversDirectory: covers,
      );

  Future<VideoBookRow> seed({
    required String bookUid,
    required String fileName,
  }) async {
    final File video = File(p.join(library.path, fileName));
    await video.writeAsBytes(<int>[0, 1, 2, 3]);
    await db.upsertVideoBook(
      VideoBooksCompanion(
        bookUid: Value<String>(bookUid),
        title: Value<String>(fileName),
        videoPath: Value<String>(video.path),
      ),
    );
    return (await repo.getByBookUid(bookUid))!;
  }

  Future<void> writePoster() =>
      File(p.join(library.path, 'poster.jpg')).writeAsBytes(kTransparentImage);

  test('远端路径不参与 sidecar 扫描', () async {
    await db.upsertVideoBook(
      const VideoBooksCompanion(
        bookUid: Value<String>('video/remote'),
        title: Value<String>('remote'),
        videoPath: Value<String>('https://host/stream.m3u8'),
      ),
    );
    final VideoBookRow book = (await repo.getByBookUid('video/remote'))!;

    expect(
      await build().applySidecarCover(book),
      isA<ScrapeNotEligible>(),
    );
  });

  test('没有 sidecar 时不写封面或来源记录', () async {
    final VideoBookRow book = await seed(
      bookUid: 'video/none',
      fileName: 'none.mkv',
    );

    expect(await build().applySidecarCover(book), isA<ScrapeNoSidecar>());
    expect((await repo.getByBookUid(book.bookUid))!.coverPath, isNull);
    expect(await coverMeta.get(book.bookUid), isNull);
  });

  test('用户 sidecar 被复制并登记为受保护来源', () async {
    final VideoBookRow book = await seed(
      bookUid: 'video/sidecar',
      fileName: 'show.mkv',
    );
    await writePoster();

    final ScrapeApplied outcome =
        await build().applySidecarCover(book) as ScrapeApplied;
    expect(await File(outcome.coverPath).readAsBytes(), kTransparentImage);
    expect(
        (await repo.getByBookUid(book.bookUid))!.coverPath, outcome.coverPath);
    expect((await coverMeta.get(book.bookUid))!.origin, CoverOrigin.sidecar);
  });

  test('未改动的 Hibiki 生成海报不会伪装成用户 sidecar', () async {
    final VideoBookRow book = await seed(
      bookUid: 'video/generated',
      fileName: 'generated.mkv',
    );
    await writePoster();

    final ScrapeOutcome outcome = await build(
      generatedArtifactChecker: const _StubGeneratedArtifactChecker(true),
    ).applySidecarCover(book);
    expect(outcome, isA<ScrapeNoSidecar>());
    expect((await repo.getByBookUid(book.bookUid))!.coverPath, isNull);
    expect(await coverMeta.get(book.bookUid), isNull);
  });

  test('批处理不覆盖手动封面', () async {
    final VideoBookRow book = await seed(
      bookUid: 'video/manual',
      fileName: 'manual.mkv',
    );
    await writePoster();
    await coverMeta.set(
      book.bookUid,
      const CoverMeta(origin: CoverOrigin.manual),
    );

    final List<BatchScrapeProgress> progress =
        await build().scrapeLibrary(<VideoBookRow>[book]).toList();
    expect(progress.single.outcome, isA<ScrapeSkippedProtected>());
    expect((await repo.getByBookUid(book.bookUid))!.coverPath, isNull);
  });

  test('多成员合集子篇不采用作品级 sidecar 海报', () async {
    final VideoBookRow first = await seed(
      bookUid: 'video/ep1',
      fileName: 'show - 01.mkv',
    );
    final VideoBookRow second = await seed(
      bookUid: 'video/ep2',
      fileName: 'show - 02.mkv',
    );
    await writePoster();
    final int collectionId = await db.createMediaCollection('show');
    await db.addToCollection(collectionId, MediaKind.video, first.bookUid);
    await db.addToCollection(collectionId, MediaKind.video, second.bookUid);

    final List<BatchScrapeProgress> progress =
        await build().scrapeLibrary(<VideoBookRow>[first, second]).toList();
    expect(
      progress.map((BatchScrapeProgress item) => item.outcome),
      everyElement(isA<ScrapeSkippedProtected>()),
    );
    expect((await repo.getByBookUid(first.bookUid))!.coverPath, isNull);
    expect((await repo.getByBookUid(second.bookUid))!.coverPath, isNull);
  });

  test('sidecar 覆盖同一路径后驱逐双键解码缓存', () async {
    final VideoBookRow book = await seed(
      bookUid: 'video/cache',
      fileName: 'cache.mkv',
    );
    await writePoster();
    final CoverScraperService service = build();
    final ScrapeApplied first =
        await service.applySidecarCover(book) as ScrapeApplied;
    await populateBothCoverKeys(first.coverPath);

    final ScrapeApplied second =
        await service.applySidecarCover(book) as ScrapeApplied;
    expect(second.coverPath, first.coverPath);
    await expectBothCoverKeysEvicted(first.coverPath);
  });
}
