/// 存量子篇作品海报清理（BUG-1393 ③）。
///
/// 分两层：
/// * **判据层**（纯函数 [planMemberCoverCleanup]）——重点是**误删方向**：把「不该
///   动的」逐条穷举，断言它们一条都不进计划。只验「该清的清了」对「多清了别人的」
///   完全无感；
/// * **落地层**（[runMemberCoverCleanup]）——真 DB + 真文件，断言海报升格到合集、
///   成员那一列被清、非目标行逐字节不变、幂等，以及升格后的合集封面**不会**被既有
///   `gcOrphanCovers` 当孤儿删掉。
library;

import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/scraper/cover_meta_store.dart';
import 'package:fushi/src/media/video/scraper/member_cover_cleanup.dart';
import 'package:fushi/src/media/video/scraper/scraper_types.dart';
import 'package:fushi/src/media/video/video_book_repository.dart';
import 'package:fushi/src/media/video/video_cover_extractor.dart'
    show videoCoverFileName;
import 'package:fushi/src/media/video/video_storage.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

const List<int> _jpegBytes = <int>[0xFF, 0xD8, 0xFF, 0x01, 0x02, 0x03];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ── 判据层：误删方向穷举 ────────────────────────────────────────
  group('planMemberCoverCleanup 判据', () {
    const String covers = r'/data/video_covers';

    List<MemberCoverCleanup> plan({
      required CoverOrigin? origin,
      String? coverPath = '$covers/video_ep1.jpg',
      Map<String, int>? members,
      Set<int> withOwnCover = const <int>{},
    }) =>
        planMemberCoverCleanup(
          multiMemberCollectionIdByVideoUid:
              members ?? <String, int>{'video/ep1': 1},
          coverMetaByUid: <String, CoverMeta>{
            if (origin != null) 'video/ep1': CoverMeta(origin: origin),
          },
          coverPathByUid: <String, String?>{'video/ep1': coverPath},
          collectionsWithOwnCover: withOwnCover,
          coversDirectoryPath: covers,
        );

    test('目标：多成员合集成员 + autoScraped + 封面在自有目录 → 进计划并升格', () {
      final List<MemberCoverCleanup> result =
          plan(origin: CoverOrigin.autoScraped);
      expect(result, hasLength(1));
      expect(result.single.bookUid, 'video/ep1');
      expect(result.single.collectionId, 1);
      expect(result.single.promoteToCollection, isTrue);
    });

    // ⚠️ 误删方向：以下每一条都是「不该动的」。任何一条漏进计划都意味着用户的
    //    封面被平白清掉。
    test('误删方向 · 用户亲自定的封面（manual / userScraped / sidecar）一条都不进计划', () {
      for (final CoverOrigin origin in <CoverOrigin>[
        CoverOrigin.manual,
        CoverOrigin.userScraped,
        CoverOrigin.sidecar,
      ]) {
        expect(plan(origin: origin), isEmpty, reason: '$origin 是用户拍板的，不许碰');
      }
    });

    test('误删方向 · 来源不明的存量 scraped 保守放过（分不清是自动刮的还是用户选的）', () {
      expect(plan(origin: CoverOrigin.scraped), isEmpty);
    });

    test('误删方向 · 抽帧封面 / 无 cover_meta 记录不进计划（这本来就是想保留的状态）', () {
      expect(plan(origin: CoverOrigin.autoFrame), isEmpty);
      expect(plan(origin: null), isEmpty);
    });

    test('误删方向 · 非子篇（不在多成员合集里）即便 autoScraped 也不进计划', () {
      expect(
        plan(origin: CoverOrigin.autoScraped, members: <String, int>{}),
        isEmpty,
      );
    });

    test('误删方向 · 封面路径为空 / null 不进计划', () {
      expect(plan(origin: CoverOrigin.autoScraped, coverPath: null), isEmpty);
      expect(plan(origin: CoverOrigin.autoScraped, coverPath: ''), isEmpty);
    });

    test('误删方向 · 封面在自有目录之外（用户自己放的图）不进计划', () {
      expect(
        plan(
          origin: CoverOrigin.autoScraped,
          coverPath: r'/home/me/pictures/my_own.jpg',
        ),
        isEmpty,
      );
      // 路径遍历也必须挡住：规范化后逃出自有目录。
      expect(
        plan(
          origin: CoverOrigin.autoScraped,
          coverPath: '$covers/../elsewhere/x.jpg',
        ),
        isEmpty,
      );
    });

    test('误删方向 · collections/ 子目录（合集自有封面）不在射程内', () {
      expect(
        plan(
          origin: CoverOrigin.autoScraped,
          coverPath: '$covers/collections/1.jpg',
        ),
        isEmpty,
        reason: '合集自有封面正是海报该待的地方，绝不能被当成成员海报摘掉',
      );
    });

    test('合集已有自有封面：成员仍清，但不覆盖合集那张（promote=false）', () {
      final List<MemberCoverCleanup> result = plan(
        origin: CoverOrigin.autoScraped,
        withOwnCover: <int>{1},
      );
      expect(result, hasLength(1));
      expect(result.single.promoteToCollection, isFalse);
    });

    test('同一合集多成员：只有排序最前的一个升格，其余只清列', () {
      final List<MemberCoverCleanup> result = planMemberCoverCleanup(
        multiMemberCollectionIdByVideoUid: <String, int>{
          'video/ep2': 1,
          'video/ep1': 1,
        },
        coverMetaByUid: <String, CoverMeta>{
          'video/ep1': const CoverMeta(origin: CoverOrigin.autoScraped),
          'video/ep2': const CoverMeta(origin: CoverOrigin.autoScraped),
        },
        coverPathByUid: <String, String?>{
          'video/ep1': '$covers/video_ep1.jpg',
          'video/ep2': '$covers/video_ep2.jpg',
        },
        collectionsWithOwnCover: const <int>{},
        coversDirectoryPath: covers,
      );
      expect(result.map((MemberCoverCleanup a) => a.bookUid).toList(),
          <String>['video/ep1', 'video/ep2']);
      expect(result.first.promoteToCollection, isTrue);
      expect(result.last.promoteToCollection, isFalse);
    });
  });

  // ── 落地层：真 DB + 真文件 ──────────────────────────────────────
  group('runMemberCoverCleanup 落地', () {
    late FushiDatabase db;
    late VideoBookRepository repo;
    late Directory covers;
    late Directory collectionCovers;
    late CoverMetaStore coverMeta;

    Future<void> seedBook(String uid, {String? coverFile}) async {
      String? coverPath;
      if (coverFile != null) {
        final File f = File(p.join(covers.path, coverFile));
        await f.writeAsBytes(_jpegBytes);
        coverPath = f.path;
      }
      await db.upsertVideoBook(VideoBooksCompanion(
        bookUid: Value(uid),
        title: Value(uid),
        videoPath: Value('D:/v/$uid.mkv'),
        coverPath: Value(coverPath),
      ));
    }

    setUp(() async {
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      repo = VideoBookRepository(db);
      covers = await Directory.systemTemp.createTemp('member_cleanup_');
      collectionCovers = Directory(p.join(covers.path, 'collections'));
      await collectionCovers.create(recursive: true);
      coverMeta = CoverMetaStore(covers);
    });

    tearDown(() async {
      await db.close();
      if (await covers.exists()) await covers.delete(recursive: true);
    });

    Future<int> run() => runMemberCoverCleanup(
          repo: repo,
          coverMetaStore: coverMeta,
          coversDirectory: covers,
          collectionCoversDirectory: collectionCovers,
        );

    test('海报升格成合集封面、成员那一列被清；非目标行逐字节不变', () async {
      // A：双成员合集，ep1 顶着自动刮来的作品海报，ep2 是抽帧。
      await seedBook('video/ep1', coverFile: 'ep1.jpg');
      await seedBook('video/ep2', coverFile: 'ep2.jpg');
      await coverMeta.set(
          'video/ep1', const CoverMeta(origin: CoverOrigin.autoScraped));
      await coverMeta.set(
          'video/ep2', const CoverMeta(origin: CoverOrigin.autoFrame));
      final int a = await db.createMediaCollection('A');
      await db.addToCollection(a, MediaKind.video, 'video/ep1');
      await db.addToCollection(a, MediaKind.video, 'video/ep2');

      // B：单成员合集 —— 单片，海报本来就该留在成员上。
      await seedBook('video/solo', coverFile: 'solo.jpg');
      await coverMeta.set(
          'video/solo', const CoverMeta(origin: CoverOrigin.autoScraped));
      final int b = await db.createMediaCollection('B');
      await db.addToCollection(b, MediaKind.video, 'video/solo');

      // C：不属任何合集的独立条目。
      await seedBook('video/free', coverFile: 'free.jpg');
      await coverMeta.set(
          'video/free', const CoverMeta(origin: CoverOrigin.autoScraped));

      // D：双成员合集，但用户手选过成员封面（userScraped）——永不覆盖。
      await seedBook('video/mine', coverFile: 'mine.jpg');
      await seedBook('video/mine2', coverFile: 'mine2.jpg');
      await coverMeta.set(
          'video/mine', const CoverMeta(origin: CoverOrigin.userScraped));
      final int d = await db.createMediaCollection('D');
      await db.addToCollection(d, MediaKind.video, 'video/mine');
      await db.addToCollection(d, MediaKind.video, 'video/mine2');

      expect(await run(), 1, reason: '只有 A 的 ep1 该被清');

      // 目标：ep1 摘干净、海报升格到合集 A。
      final VideoBookRow ep1 = (await db.getVideoBookByBookUid('video/ep1'))!;
      expect(ep1.coverPath, isNull);
      expect(await coverMeta.get('video/ep1'), isNull);
      final String promoted =
          p.join(collectionCovers.path, videoCoverFileName('$a'));
      expect((await db.getMediaCollectionById(a))!.coverPath, promoted);
      expect(File(promoted).readAsBytesSync(), _jpegBytes);

      // 误删方向：其余四本全部原封不动。
      for (final String uid in <String>[
        'video/ep2',
        'video/solo',
        'video/free',
        'video/mine',
        'video/mine2',
      ]) {
        final VideoBookRow row = (await db.getVideoBookByBookUid(uid))!;
        expect(row.coverPath, isNotNull, reason: '$uid 的封面被误清了');
        expect(File(row.coverPath!).existsSync(), isTrue);
      }
      expect((await coverMeta.get('video/ep2'))!.origin, CoverOrigin.autoFrame);
      expect(
          (await coverMeta.get('video/solo'))!.origin, CoverOrigin.autoScraped);
      expect(
          (await coverMeta.get('video/mine'))!.origin, CoverOrigin.userScraped);
      expect((await db.getMediaCollectionById(b))!.coverPath, isNull);
      expect((await db.getMediaCollectionById(d))!.coverPath, isNull);
    });

    test('合集已有自有封面：不覆盖它，但成员海报照样摘掉', () async {
      await seedBook('video/e1', coverFile: 'e1.jpg');
      await seedBook('video/e2', coverFile: 'e2.jpg');
      await coverMeta.set(
          'video/e1', const CoverMeta(origin: CoverOrigin.autoScraped));
      final int cid = await db.createMediaCollection('已刮过');
      await db.addToCollection(cid, MediaKind.video, 'video/e1');
      await db.addToCollection(cid, MediaKind.video, 'video/e2');
      final File own = File(p.join(collectionCovers.path, 'own.jpg'));
      await own.writeAsBytes(<int>[0x89, 0x50, 0x4E, 0x47]);
      await db.updateMediaCollectionCoverPath(cid, own.path);

      expect(await run(), 1);
      expect((await db.getMediaCollectionById(cid))!.coverPath, own.path,
          reason: '合集已有的自有封面（用户刮的）不许被存量清理顶掉');
      expect(own.readAsBytesSync(), <int>[0x89, 0x50, 0x4E, 0x47]);
      expect((await db.getVideoBookByBookUid('video/e1'))!.coverPath, isNull);
    });

    test('幂等：第二轮 0 条，且不再改动任何行', () async {
      await seedBook('video/a1', coverFile: 'a1.jpg');
      await seedBook('video/a2', coverFile: 'a2.jpg');
      await coverMeta.set(
          'video/a1', const CoverMeta(origin: CoverOrigin.autoScraped));
      final int cid = await db.createMediaCollection('A');
      await db.addToCollection(cid, MediaKind.video, 'video/a1');
      await db.addToCollection(cid, MediaKind.video, 'video/a2');

      expect(await run(), 1);
      final String? after = (await db.getMediaCollectionById(cid))!.coverPath;
      expect(await run(), 0);
      expect((await db.getMediaCollectionById(cid))!.coverPath, after);
      expect(
          (await db.getVideoBookByBookUid('video/a2'))!.coverPath, isNotNull);
    });

    test('误删方向 · 升格后的合集封面不会被既有 gcOrphanCovers 当孤儿删掉', () async {
      await seedBook('video/g1', coverFile: 'g1.jpg');
      await seedBook('video/g2', coverFile: 'g2.jpg');
      await coverMeta.set(
          'video/g1', const CoverMeta(origin: CoverOrigin.autoScraped));
      final int cid = await db.createMediaCollection('G');
      await db.addToCollection(cid, MediaKind.video, 'video/g1');
      await db.addToCollection(cid, MediaKind.video, 'video/g2');
      await run();

      final String promoted =
          (await db.getMediaCollectionById(cid))!.coverPath!;
      // GC 的保留集只含全库 video_books.cover_path（清完 g1 后就剩 g2）。
      await VideoStorage.gcOrphanCovers(
        referencedCoverPaths: <String>[
          for (final VideoBookRow r in await db.allVideoBooks())
            if (r.coverPath != null) r.coverPath!,
        ],
        coversDirectory: covers,
      );
      expect(File(promoted).existsSync(), isTrue,
          reason: 'gcOrphanCovers 非递归，collections/ 子目录必须免疫');
      expect(
        File((await db.getVideoBookByBookUid('video/g2'))!.coverPath!)
            .existsSync(),
        isTrue,
        reason: '仍被引用的成员封面不许被 GC 删',
      );
    });
  });
}
