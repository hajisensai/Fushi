// TODO-817 M1c MediaSourcesDialog widget 行为 + 源码守卫测试：
//  (1) 空库 -> 显示 media_source_no_sources。
//  (2) 预置 video 来源 -> 按 sortOrder 渲染 label/rootPath/统计文案。
//  (3) lastScanError != null -> 显示 media_source_scan_error。
//  (4) 移除来源 -> 确认对话框含 media_source_remove_keeps_media；确认后该来源消失，
//      且预置的 VideoBook 仍在（FK setNull，条目保留）。
//  (5) mediaKind='book' -> 统计文案用 media_source_count_book（N 本书）。
//  (6) 凭据红线源码守卫：对话框源码不写任何 password/credential/secret，且网络分支
//      不调 insertMediaSource、不传 configJson。
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/src/pages/implementations/media_sources_dialog.dart';
import 'package:hibiki_core/hibiki_core.dart';

import '../helpers/test_platform_services.dart';

HibikiDatabase _memDb() => HibikiDatabase.forTesting(
      NativeDatabase.memory(
        setup: (rawDb) => rawDb.execute('PRAGMA foreign_keys = ON'),
      ),
    );

Future<void> _pumpDialog(
  WidgetTester tester,
  HibikiDatabase db,
  String mediaKind,
) async {
  final AppModel appModel = AppModel(testPlatformServices())
    ..wireDatabaseForTesting(db);
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        appProvider.overrideWith((ref) => appModel),
      ],
      child: MaterialApp(
        // 固定窄窗，避免 master-detail 宽窗分支（既往测试教训）。
        home: MediaQuery(
          data: const MediaQueryData(size: Size(420, 800)),
          child: Scaffold(
            body: MediaSourcesDialog(mediaKind: mediaKind),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<int> _seedSource(
  HibikiDatabase db, {
  required String label,
  required String mediaKind,
  required String rootPath,
  int sortOrder = 0,
  int mediaCount = 0,
  DateTime? lastScannedAt,
  String? lastScanError,
}) {
  return db.insertMediaSource(MediaSourcesCompanion(
    label: Value(label),
    mediaKind: Value(mediaKind),
    transport: const Value('local'),
    rootPath: Value(rootPath),
    sortOrder: Value(sortOrder),
    mediaCount: Value(mediaCount),
    lastScannedAt: Value(lastScannedAt),
    lastScanError: Value(lastScanError),
    createdAt: Value(DateTime.now().millisecondsSinceEpoch),
  ));
}

/// 插入一条归属 [sourceId] 的视频条目（TODO-1036 累计计数用）。
Future<void> _seedVideo(
  HibikiDatabase db,
  String bookUid, {
  required int sourceId,
}) =>
    db.upsertVideoBook(VideoBooksCompanion(
      bookUid: Value(bookUid),
      title: Value(bookUid),
      videoPath: Value('/srv/$bookUid.mp4'),
      sourceId: Value(sourceId),
      importedAt: Value(DateTime.now()),
    ));

/// 插入一条归属 [sourceId] 的 EPUB 条目（TODO-1036 累计计数用）。
Future<void> _seedBook(
  HibikiDatabase db,
  String bookKey, {
  required int sourceId,
}) =>
    db.insertEpubBook(EpubBooksCompanion.insert(
      bookKey: bookKey,
      title: bookKey,
      epubPath: '/srv/$bookKey.epub',
      extractDir: '/srv/$bookKey',
      chapterCount: 1,
      chaptersJson: '[]',
      importedAt: DateTime.now().millisecondsSinceEpoch,
      sourceId: Value(sourceId),
    ));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('empty library shows no-sources message', (tester) async {
    final HibikiDatabase db = _memDb();
    addTearDown(db.close);
    await _pumpDialog(tester, db, 'video');
    expect(find.text('No sources yet'), findsOneWidget);
  });

  testWidgets('video sources render label / rootPath / count + last scan',
      (tester) async {
    final HibikiDatabase db = _memDb();
    addTearDown(db.close);
    // TODO-1036：统计显示的是来源**累计拥有**的条目数（直接 COUNT video_books），
    // 不是 mediaCount（上次扫描新增数）。这里给 Anime 实插 2 条视频，mediaCount
    // 故意设成不一致的 68 来证明 UI 不再读 mediaCount。
    final int anime = await _seedSource(db,
        label: 'Anime',
        mediaKind: 'video',
        rootPath: '/srv/anime',
        sortOrder: 0,
        mediaCount: 68,
        lastScannedAt: DateTime(2026, 6, 25, 11, 27));
    await _seedVideo(db, 'video/a1', sourceId: anime);
    await _seedVideo(db, 'video/a2', sourceId: anime);
    await _seedSource(db,
        label: 'Movies',
        mediaKind: 'video',
        rootPath: '/srv/movies',
        sortOrder: 1,
        mediaCount: 3);
    await _pumpDialog(tester, db, 'video');

    expect(find.text('Anime'), findsOneWidget);
    expect(find.text('/srv/anime'), findsOneWidget);
    expect(find.text('Movies'), findsOneWidget);
    // 统计文案用「N videos」（视频量词），N = 累计拥有数（2），不是 mediaCount(68)。
    expect(find.textContaining('2 videos'), findsOneWidget);
    expect(find.textContaining('68 videos'), findsNothing);
    expect(find.textContaining('Last scan 2026-06-25 11:27'), findsOneWidget);
  });

  testWidgets('scan error row shows scan-failed text', (tester) async {
    final HibikiDatabase db = _memDb();
    addTearDown(db.close);
    await _seedSource(db,
        label: 'Broken',
        mediaKind: 'video',
        rootPath: '/srv/broken',
        lastScanError: 'boom');
    await _pumpDialog(tester, db, 'video');
    expect(find.text('Scan failed'), findsOneWidget);
  });

  testWidgets('remove confirms, keeps imported media (FK setNull)',
      (tester) async {
    final HibikiDatabase db = _memDb();
    addTearDown(db.close);
    final int sid = await _seedSource(db,
        label: 'Anime', mediaKind: 'video', rootPath: '/srv/anime');
    // 归属本来源的视频条目。
    await db.upsertVideoBook(VideoBooksCompanion(
      bookUid: const Value('video/owned'),
      title: const Value('Owned'),
      videoPath: const Value('/srv/anime/owned.mp4'),
      sourceId: Value(sid),
      importedAt: Value(DateTime.now()),
    ));
    await _pumpDialog(tester, db, 'video');

    // 点移除图标 -> 确认对话框。
    await tester.tap(find.byIcon(Icons.remove_circle_outline));
    await tester.pumpAndSettle();
    expect(find.text('Removing a source does not delete imported media.'),
        findsOneWidget);

    // 确认（弹窗有两个「Remove Source」文本：标题 + 确认按钮，点最后一个）。
    await tester.tap(find.text('Remove Source').last);
    await tester.pumpAndSettle();

    // 来源消失，但视频条目仍在（sourceId 被置 NULL）。
    final List<MediaSourceRow> sources = await db.getAllMediaSources();
    expect(sources, isEmpty);
    final VideoBookRow? video = await db.getVideoBookByBookUid('video/owned');
    expect(video, isNotNull, reason: 'media must survive source removal');
    expect(video!.sourceId, isNull, reason: 'FK setNull detaches the source');
  });

  testWidgets('book mediaKind uses book count phrase (cumulative, not '
      'mediaCount)', (tester) async {
    final HibikiDatabase db = _memDb();
    addTearDown(db.close);
    // TODO-1036：mediaCount=12（上次扫描新增）但实际只有 3 本归属本来源，UI 必须
    // 显示累计 3，不是 12（重扫已全导入的来源 mediaCount 会回落 0）。
    final int novels = await _seedSource(db,
        label: 'Novels',
        mediaKind: 'book',
        rootPath: '/srv/novels',
        mediaCount: 12);
    await _seedBook(db, 'N1', sourceId: novels);
    await _seedBook(db, 'N2', sourceId: novels);
    await _seedBook(db, 'N3', sourceId: novels);
    await _pumpDialog(tester, db, 'book');
    expect(find.textContaining('3 books'), findsOneWidget);
    expect(find.textContaining('12 books'), findsNothing);
  });

  group('credential red-line source guard', () {
    late String src;
    setUpAll(() {
      src = File(
        'lib/src/pages/implementations/media_sources_dialog.dart',
      ).readAsStringSync();
    });

    test('no password/credential/secret written by the dialog', () {
      final RegExp banned =
          RegExp(r'(password|credential|secret)', caseSensitive: false);
      expect(banned.hasMatch(src), isFalse,
          reason: 'M1c must not store any credentials (M3 decision point)');
    });

    test('configJson is never passed to insertMediaSource', () {
      expect(src.contains('configJson:'), isFalse,
          reason: 'configJson must never be passed (stays NULL in M1c)');
    });

    test('uses HibikiReorderableColumn, not SDK ReorderableListView', () {
      expect(src.contains('HibikiReorderableColumn'), isTrue);
      expect(src.contains('ReorderableListView('), isFalse);
    });

    test('deletion goes through deleteMediaSource (FK setNull keeps media)',
        () {
      expect(src.contains('deleteMediaSource'), isTrue);
      expect(src.contains('deleteVideoBook'), isFalse);
      expect(src.contains('deleteEpubBook'), isFalse);
    });
  });
}
