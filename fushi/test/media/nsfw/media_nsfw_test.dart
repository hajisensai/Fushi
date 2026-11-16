import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/nsfw/nsfw_card_image.dart';
import 'package:fushi/src/media/nsfw/media_nsfw_cover.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/nsfw_cover_blur.dart';
import 'package:fushi/src/utils/components/shelf_card_widgets.dart';
import 'package:fushi/src/utils/components/shelf_cover_material.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/privacy/media_nsfw.dart';
import 'package:image/image.dart' as img;
import 'package:material_ui/material_ui.dart';

/// 作品级 NSFW（拍板台 w04vrhUAaX：所有媒体都支持是否 NSFW）：
/// - 判定口径：自己被标，或在 NSFW 合集里（书按 uid 入合集也认）；
/// - 快照随表变更重载（封面消费端不用各自 invalidate）；
/// - 封面框在 [ShelfCoverNsfw] 下把封面打模糊（材质 / 非材质两条路径）；
/// - 制卡图片：开关关 / 非 NSFW 原样；NSFW + 开 → 模糊副本；解不开 → 不带图（fail-closed）。
void main() {
  late FushiDatabase db;
  setUp(() => db = FushiDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<String> book(String key) async {
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: key,
        title: key,
        epubPath: '/x/$key.epub',
        extractDir: '/x/$key',
        chapterCount: 1,
        chaptersJson: '[]',
        importedAt: 0,
      ),
    );
    return (await db.getEpubBook(key))!.uid;
  }

  Future<void> video(String uid) => db
      .into(db.videoBooks)
      .insert(
        VideoBooksCompanion.insert(
          bookUid: uid,
          title: uid,
          videoPath: '/v/$uid.mkv',
          importedAt: const Value<int?>(0),
        ),
      );

  Future<int> nsfwCollection(String name) async {
    final int id = await db.createMediaCollection(name);
    await db.setMediaNsfw(
      TagHostKind.collection,
      collectionTagEntryKey(id),
      true,
    );
    return id;
  }

  group('判定口径', () {
    test('自己被标 / 在 NSFW 合集里（书按 uid 入合集、视频、游戏）都算 NSFW', () async {
      final String uid = await book('B');
      await book('Plain');
      await video('v1');
      await video('v2');
      await db.setMediaNsfw(TagHostKind.video, 'v2', true);
      final int c = await nsfwCollection('秘');
      await db.addToCollection(c, MediaKind.epub, uid);
      await db.addToCollection(c, MediaKind.video, 'v1');
      await db.addToCollection(c, MediaKind.game, 'g1');

      final MediaNsfwSnapshot snap = await MediaNsfwSnapshot.load(db);
      expect(snap.isBookNsfw('B'), isTrue, reason: 'uid 成员键归一到 bookKey');
      expect(snap.isBookNsfw('Plain'), isFalse);
      expect(snap.isVideoNsfw('v1'), isTrue);
      expect(snap.isVideoNsfw('v2'), isTrue);
      expect(snap.isCollectionNsfw(c), isTrue);
      expect(snap.isGameInNsfwCollection('g1'), isTrue);
      expect(
        snap.isNsfw(TagHostKind.collection, collectionTagEntryKey(c)),
        isTrue,
      );

      expect(await isMediaNsfwEffective(db, TagHostKind.epub, 'B'), isTrue);
      expect(
        await isMediaNsfwEffective(db, TagHostKind.epub, 'Plain'),
        isFalse,
      );
      expect(
        (await nsfwCollectionsContaining(
          db,
          TagHostKind.video,
          'v1',
        )).map((MediaCollectionRow r) => r.name),
        <String>['秘'],
      );
    });

    test('NSFW 与私密互不蕴含', () async {
      await video('v1');
      await db.setMediaPrivate(TagHostKind.video, 'v1', true);
      expect((await MediaNsfwSnapshot.load(db)).isVideoNsfw('v1'), isFalse);
    });

    test('快照随标记 / 合集成员变化重载', () async {
      await video('v1');
      final StreamController<MediaNsfwSnapshot> seen =
          StreamController<MediaNsfwSnapshot>.broadcast();
      Future<MediaNsfwSnapshot> next(bool Function(MediaNsfwSnapshot) p) =>
          seen.stream.firstWhere(p).timeout(const Duration(seconds: 5));
      final Future<MediaNsfwSnapshot> first = next((_) => true);
      final StreamSubscription<MediaNsfwSnapshot> sub = watchMediaNsfwSnapshot(
        db,
      ).listen(seen.add);
      expect((await first).isVideoNsfw('v1'), isFalse);

      final Future<MediaNsfwSnapshot> marked = next(
        (MediaNsfwSnapshot s) => s.isVideoNsfw('v1'),
      );
      await db.setMediaNsfw(TagHostKind.video, 'v1', true);
      await marked;

      final Future<MediaNsfwSnapshot> cleared = next(
        (MediaNsfwSnapshot s) => !s.isVideoNsfw('v1'),
      );
      await db.setMediaNsfw(TagHostKind.video, 'v1', false);
      await cleared;

      final Future<MediaNsfwSnapshot> inherited = next(
        (MediaNsfwSnapshot s) => s.isVideoNsfw('v1'),
      );
      final int c = await nsfwCollection('剧');
      await db.addToCollection(c, MediaKind.video, 'v1');
      await inherited; // 加入 NSFW 合集也要触发
      await sub.cancel();
      await seen.close();
    });
  });

  group('封面模糊', () {
    Widget harness(Widget child, {ShelfCoverMaterial? material}) {
      final Widget scoped = material == null
          ? child
          : ShelfCoverMaterialScope(material: material, child: child);
      return MaterialApp(
        theme: ThemeData(
          extensions: const <ThemeExtension<dynamic>>[FushiEinkTheme(false)],
        ),
        home: Scaffold(
          body: Center(child: SizedBox(width: 120, height: 170, child: scoped)),
        ),
      );
    }

    ImageFiltered blurOf(WidgetTester tester) => tester.widget<ImageFiltered>(
      find.byKey(const ValueKey<String>('nsfw-cover-blur')),
    );

    for (final ShelfCoverMaterial? material in <ShelfCoverMaterial?>[
      null,
      ShelfCoverMaterial.glossyBook,
    ]) {
      testWidgets('封面框读 ShelfCoverNsfw：标了才模糊（材质 $material）', (
        WidgetTester tester,
      ) async {
        Widget frame(bool blur) => harness(
          ShelfCoverNsfw(
            blur: blur,
            child: const ShelfCoverFrame(
              child: ColoredBox(color: Color(0xFF336699)),
            ),
          ),
          material: material,
        );
        await tester.pumpWidget(frame(false));
        await tester.pumpAndSettle();
        expect(blurOf(tester).enabled, isFalse);

        await tester.pumpWidget(frame(true));
        await tester.pumpAndSettle();
        expect(blurOf(tester).enabled, isTrue);
        expect(blurOf(tester).imageFilter, isA<ui.ImageFilter>());
      });
    }

    testWidgets('没有 ShelfCoverNsfw 的封面框不模糊', (WidgetTester tester) async {
      await tester.pumpWidget(
        harness(
          const ShelfCoverFrame(child: ColoredBox(color: Color(0xFF336699))),
        ),
      );
      await tester.pumpAndSettle();
      expect(blurOf(tester).enabled, isFalse);
    });

    test('MediaNsfwTarget：游戏自己的成人向标记并入', () {
      expect(
        const MediaNsfwTarget.game(
          'g',
          adult: true,
        ).resolve(MediaNsfwSnapshot.none),
        isTrue,
      );
      expect(
        const MediaNsfwTarget.book('b').resolve(MediaNsfwSnapshot.none),
        isFalse,
      );
    });
  });

  group('制卡图片', () {
    late Directory dir;
    late String cover;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('nsfw_card_image_');
      final img.Image src = img.Image(width: 60, height: 90);
      for (int y = 0; y < 90; y++) {
        for (int x = 0; x < 60; x++) {
          // 棋盘格：模糊后高频细节必须消失。
          final bool on = ((x ~/ 3) + (y ~/ 3)).isEven;
          src.setPixelRgb(x, y, on ? 255 : 0, on ? 255 : 0, on ? 255 : 0);
        }
      }
      cover = '${dir.path}/cover.png';
      File(cover).writeAsBytesSync(img.encodePng(src));
    });
    tearDown(() => dir.deleteSync(recursive: true));

    test('开关关 / 非 NSFW：原样返回', () async {
      await book('B');
      await db.setMediaNsfw(TagHostKind.epub, 'B', true);
      expect(
        await resolveNsfwCardImagePath(
          db: db,
          path: cover,
          blurCardImages: false,
          kind: TagHostKind.epub,
          entryKey: 'B',
        ),
        cover,
      );
      await book('C');
      expect(
        await resolveNsfwCardImagePath(
          db: db,
          path: cover,
          blurCardImages: true,
          kind: TagHostKind.epub,
          entryKey: 'C',
        ),
        cover,
      );
    });

    test('NSFW + 开：换成模糊副本，原图的高频细节消失', () async {
      await book('B');
      await db.setMediaNsfw(TagHostKind.epub, 'B', true);
      final String? out = await resolveNsfwCardImagePath(
        db: db,
        path: cover,
        blurCardImages: true,
        kind: TagHostKind.epub,
        entryKey: 'B',
      );
      expect(out, isNotNull);
      expect(out, isNot(cover));
      expect(out, endsWith('.jpg'));
      final img.Image blurred = img.decodeJpg(File(out!).readAsBytesSync())!;
      expect(blurred.height, greaterThan(blurred.width), reason: '保持竖版比例');
      // 棋盘格原图相邻像素黑白交替；模糊后相邻像素差应该很小。
      int maxStep = 0;
      for (int x = 1; x < blurred.width; x++) {
        final int a = blurred.getPixel(x - 1, blurred.height ~/ 2).r.toInt();
        final int b = blurred.getPixel(x, blurred.height ~/ 2).r.toInt();
        if ((a - b).abs() > maxStep) maxStep = (a - b).abs();
      }
      expect(maxStep, lessThan(40));
    });

    test('图解不开：fail-closed，不带图', () async {
      await book('B');
      await db.setMediaNsfw(TagHostKind.epub, 'B', true);
      final String bad = '${dir.path}/bad.jpg';
      File(bad).writeAsBytesSync(<int>[1, 2, 3, 4]);
      expect(
        await resolveNsfwCardImagePath(
          db: db,
          path: bad,
          blurCardImages: true,
          kind: TagHostKind.epub,
          entryKey: 'B',
        ),
        isNull,
      );
    });
  });
}
