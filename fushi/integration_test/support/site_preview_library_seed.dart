// 「App 全貌」截图用的库播种：读 tool/site_previews/fetch_library_fixtures.dart 产出的
// library.json，把公有领域 / CC 作品写进干净隔离库，并补上首页 dashboard 需要的进度、
// 学习时长与游戏游玩记录——空库拍出来全是空态，看不出 app 长什么样。
//
// library.json：{books:[{title, author, epub, cover}], videos:[{title, file, cover}],
//                manga:[{title, series, cbz, cover}], games:[{title, cover}]}，路径相对该文件。
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:fushi/src/media/video/video_import_dialog.dart'
    show singleVideoBookUid;
import 'package:fushi/src/mining/galgame_library.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi_audio/fushi_audio.dart' show ReaderPositionRepository;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_importer.dart';
import 'package:fushi_engine/media/manga/manga_archive_importer.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:path/path.dart' as p;

/// 播种结果：各域条目在库里的标识，供后续开页 / 断言。
class SitePreviewLibrary {
  SitePreviewLibrary(
    this.bookKeys,
    this.videoUids,
    this.mangaKeys,
    this.gameIds,
  );

  final List<String> bookKeys;
  final List<String> videoUids;
  final List<String> mangaKeys;
  final List<String> gameIds;
}

List<Map<String, Object?>> _items(Map<String, Object?> json, String key) =>
    <Map<String, Object?>>[
      for (final Object? e in (json[key] as List<Object?>? ?? <Object?>[]))
        e! as Map<String, Object?>,
    ];

Future<SitePreviewLibrary> seedSitePreviewLibrary(
  AppModel appModel,
  Directory fixtures,
) async {
  final File manifest = File(p.join(fixtures.path, 'library.json'));
  final Map<String, Object?> json =
      jsonDecode(await manifest.readAsString()) as Map<String, Object?>;
  String abs(Object? rel) => p.normalize(p.join(fixtures.path, rel! as String));

  final FushiDatabase db = appModel.database;
  final DateTime now = DateTime.now();
  final String deviceId = await db.getOrCreateStudyDeviceId();

  Future<void> segment(
    String kind,
    String key,
    String title, {
    required int daysAgo,
    required int hour,
    required int minutes,
    int chars = 0,
  }) async {
    final DateTime start = DateTime(
      now.year,
      now.month,
      now.day - daysAgo,
      hour,
      5,
    );
    await db.upsertStudySegment(
      StudySegmentsCompanion.insert(
        uid: FushiDatabase.newStudySegmentUid(),
        deviceId: deviceId,
        mediaKind: kind,
        mediaKey: key,
        title: title,
        startAt: start.millisecondsSinceEpoch,
        endAt: start.add(Duration(minutes: minutes)).millisecondsSinceEpoch,
        dateKey: FushiDatabase.statDateKeyOf(start),
        hour: start.hour,
        durationMs: Value(minutes * 60 * 1000),
        chars: Value(chars),
        updatedAt: start.millisecondsSinceEpoch,
      ),
    );
  }

  // ── 书：倒序导入，让清单第一本成为「最近添加」之首；前几本带阅读进度 ──
  final List<String> bookKeys = <String>[];
  final List<Map<String, Object?>> books = _items(json, 'books');
  for (final Map<String, Object?> b in books.reversed) {
    final String path = abs(b['epub']);
    bookKeys.insert(
      0,
      await EpubImporter.importFromPath(
        db: db,
        filePath: path,
        fileName: p.basename(path),
      ),
    );
  }
  final ReaderPositionRepository positions = ReaderPositionRepository(db);
  // 进度：第一本读到约四成（首页「继续阅读」主卡），后两本少量。
  const List<(int, int)> bookProgress = <(int, int)>[
    (1, 4200),
    (0, 9000),
    (0, 2500),
  ];
  for (int i = 0; i < bookKeys.length && i < bookProgress.length; i++) {
    final EpubBookRow? row = await db.getEpubBook(bookKeys[i]);
    if (row == null) continue;
    await positions.save(
      bookUid: row.uid,
      sectionIndex: bookProgress[i].$1,
      normCharOffset: bookProgress[i].$2,
    );
  }
  for (int i = 0; i < bookKeys.length && i < 2; i++) {
    final String title = books[i]['title']! as String;
    await segment(
      kActivityMediaBook,
      bookKeys[i],
      title,
      daysAgo: 0,
      hour: 9 + i * 11,
      minutes: 72 - i * 30,
      chars: 21000 - i * 9000,
    );
    await segment(
      kActivityMediaBook,
      bookKeys[i],
      title,
      daysAgo: 1,
      hour: 21,
      minutes: 40,
      chars: 12000,
    );
  }

  // ── 视频：海报直接写 coverPath；前三部带观看进度 ──
  final VideoBookRepository videoRepo = VideoBookRepository(db);
  final List<String> videoUids = <String>[];
  final List<Map<String, Object?>> videos = _items(json, 'videos');
  for (final Map<String, Object?> v in videos.reversed) {
    final String path = abs(v['file']);
    final String uid = singleVideoBookUid(path);
    await videoRepo.saveVideoBook(
      VideoBooksCompanion(
        bookUid: Value(uid),
        title: Value(v['title']! as String),
        videoPath: Value(path),
        coverPath: Value(abs(v['cover'])),
      ),
    );
    videoUids.insert(0, uid);
  }
  for (int i = 0; i < videoUids.length && i < 3; i++) {
    await db.updateVideoBookPosition(
      videoUids[i],
      12000 + i * 5000,
      playedAt: now.subtract(Duration(hours: i + 1)).millisecondsSinceEpoch,
    );
    await segment(
      kActivityMediaVideo,
      videoUids[i],
      videos[i]['title']! as String,
      daysAgo: 0,
      hour: 14 + i,
      minutes: 25 - i * 6,
      chars: 600,
    );
  }

  // ── 漫画：每集一个 CBZ，封面即首页 ──
  final List<String> mangaKeys = <String>[];
  for (final Map<String, Object?> m in _items(json, 'manga').reversed) {
    mangaKeys.insert(
      0,
      await MangaArchiveImporter.importArchive(
        db: db,
        archivePath: abs(m['cbz']),
        title: m['title']! as String,
      ),
    );
  }

  // ── 游戏：假 exe 路径 + 封面 + 近几天的游玩记录 ──
  final List<String> gameIds = <String>[];
  final List<GalgameEntry> games = <GalgameEntry>[];
  final List<Map<String, Object?>> gameItems = _items(json, 'games');
  for (int i = 0; i < gameItems.length; i++) {
    final Map<String, Object?> g = gameItems[i];
    final String id = 'site-preview-game-$i';
    gameIds.add(id);
    games.add(
      GalgameEntry(
        id: id,
        name: g['title']! as String,
        exePath: 'C:\\Games\\site-preview-$i\\game.exe',
        workdir: 'C:\\Games\\site-preview-$i',
        addedAt: now.subtract(Duration(days: 20 - i)),
        coverPath: abs(g['cover']),
      ),
    );
  }
  await appModel.galgameRepo.addAll(games);
  for (int i = 0; i < gameIds.length; i++) {
    for (int d = 0; d < 3 - (i ~/ 2); d++) {
      final DateTime start = DateTime(
        now.year,
        now.month,
        // 从昨天往前排：今天的「继续」主卡留给书（游戏最近一次比读书早）。
        now.day - 1 - d - i,
        20 - i,
      );
      final DateTime end = start.add(Duration(minutes: 70 - i * 12));
      await db.insertGalgameSession(
        GalgameSessionsCompanion.insert(
          gameId: gameIds[i],
          startMs: start.millisecondsSinceEpoch,
          endMs: end.millisecondsSinceEpoch,
          durationSeconds: end.difference(start).inSeconds,
          dateKey: FushiDatabase.statDateKeyOf(end),
        ),
      );
    }
  }
  await appModel.galgameRepo.load();

  debugPrint(
    '[site-preview] seeded books=${bookKeys.length} '
    'videos=${videoUids.length} manga=${mangaKeys.length} '
    'games=${gameIds.length}',
  );
  return SitePreviewLibrary(bookKeys, videoUids, mangaKeys, gameIds);
}
