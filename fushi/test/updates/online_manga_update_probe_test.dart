import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_service.dart';
import 'package:fushi/src/media/manga/library/online_manga_runtime_adapter.dart';
import 'package:fushi/src/updates/update_probes.dart';
import 'package:fushi_engine/epub/epub_storage.dart';

/// 在线漫画探针的订阅自动下载（设计稿 2026-09-12 §5）：真 in-memory DB +
/// 真 `OnlineMangaLibraryService`，只把运行时换成可编排的假 adapter。
void main() {
  const OnlineMangaChapter c1 = OnlineMangaChapter(
    key: '/chapter/1',
    name: 'Chapter 1',
    number: 1,
    raw: <String, Object?>{'url': '/chapter/1'},
  );
  const OnlineMangaChapter c2 = OnlineMangaChapter(
    key: '/chapter/2',
    name: 'Chapter 2',
    number: 2,
    raw: <String, Object?>{'url': '/chapter/2'},
  );
  const OnlineMangaChapter c3 = OnlineMangaChapter(
    key: '/chapter/3',
    name: 'Chapter 3',
    number: 3,
    raw: <String, Object?>{'url': '/chapter/3'},
  );

  OnlineMangaLibraryEntry entryFor(
    String seriesKey, {
    List<OnlineMangaChapter> chapters = const <OnlineMangaChapter>[],
  }) =>
      OnlineMangaLibraryEntry(
        runtime: OnlineMangaRuntimeKind.mihon,
        extensionPackage: 'org.example.fixture',
        sourceId: '1',
        series: OnlineMangaSeries(
          key: seriesKey,
          title: 'Series $seriesKey',
          raw: <String, Object?>{'url': seriesKey},
        ),
        chapters: chapters,
      );

  late Directory root;
  late FushiDatabase database;
  late _ScriptedAdapter adapter;
  late OnlineMangaLibraryService service;
  late List<({String seriesKey, List<String> chapterKeys})> enqueued;
  late List<({Object error, String bookKey})> errors;

  Future<void> autoDownload(
    OnlineMangaLibraryEntry entry,
    List<OnlineMangaChapter> chapters,
  ) async {
    enqueued.add((
      seriesKey: entry.series.key,
      chapterKeys:
          chapters.map((OnlineMangaChapter c) => c.key).toList(growable: false),
    ));
  }

  void onError(Object error, String bookKey) {
    errors.add((error: error, bookKey: bookKey));
  }

  Future<OnlineMangaLibraryEntry> stored(String bookKey) async =>
      OnlineMangaLibraryEntry.tryParse(
        (await database.getEpubBook(bookKey))!.sourceMetadata,
      )!;

  /// 入库并按需打开订阅，返回 bookKey。
  Future<String> addBook(
    OnlineMangaLibraryEntry entry, {
    bool autoDownload = false,
  }) async {
    final EpubBookRow row = await service.add(entry);
    if (autoDownload) {
      await service.setSubscription(
        bookKey: row.bookKey,
        entry: await stored(row.bookKey),
        subscribed: true,
        autoDownload: true,
      );
    }
    return row.bookKey;
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('hibiki-manga-probe-');
    EpubStorage.debugBaseDirectoryOverride = root.path;
    database = FushiDatabase.forTesting(NativeDatabase.memory());
    adapter = _ScriptedAdapter();
    service = OnlineMangaLibraryService(
      database: database,
      rootDirectory: root,
      adapter: adapter,
    );
    enqueued = <({String seriesKey, List<String> chapterKeys})>[];
    errors = <({Object error, String bookKey})>[];
  });

  tearDown(() async {
    EpubStorage.debugBaseDirectoryOverride = null;
    await database.close();
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('只有 autoDownload 的条目把新章入队，且只入新出现那一章（旧→新序）', () async {
    final String keyA = await addBook(
      entryFor('/series/a', chapters: const <OnlineMangaChapter>[c2, c1]),
      autoDownload: true,
    );
    final String keyB = await addBook(
      entryFor('/series/b', chapters: const <OnlineMangaChapter>[c2, c1]),
    );
    expect((await stored(keyA)).autoDownload, isTrue);
    expect((await stored(keyB)).autoDownload, isFalse);

    // 源这次多了一章 c3（源按新→旧返回）。
    adapter.script =
        (OnlineMangaLibraryEntry entry) async => OnlineMangaRefreshResult(
              series: entry.series,
              chapters: const <OnlineMangaChapter>[c3, c2, c1],
            );

    final int refreshed = await runOnlineMangaUpdateProbe(
      database: database,
      serviceFor: (OnlineMangaRuntimeKind _) => service,
      autoDownload: autoDownload,
      onError: onError,
    );

    expect(refreshed, 2);
    expect(errors, isEmpty);
    expect(
      adapter.refreshedSeriesKeys,
      unorderedEquals(<String>['/series/a', '/series/b']),
      reason: '每条在线条目都刷新，不订阅的也刷（库的枚举序不是插入序）',
    );
    expect(enqueued, hasLength(1), reason: 'B 未订阅，不得入队');
    expect(enqueued.single.seriesKey, '/series/a');
    expect(enqueued.single.chapterKeys, <String>['/chapter/3']);

    expect((await stored(keyA)).chapters, hasLength(3));
    expect((await stored(keyB)).chapters, hasLength(3), reason: 'B 照常落库');
    expect((await stored(keyA)).autoDownload, isTrue, reason: '探针刷新不冲掉订阅');
  });

  test('新出现多章时按旧→新章序入队', () async {
    await addBook(
      entryFor('/series/a', chapters: const <OnlineMangaChapter>[c1]),
      autoDownload: true,
    );
    adapter.script =
        (OnlineMangaLibraryEntry entry) async => OnlineMangaRefreshResult(
              series: entry.series,
              chapters: const <OnlineMangaChapter>[c3, c2, c1],
            );

    await runOnlineMangaUpdateProbe(
      database: database,
      serviceFor: (OnlineMangaRuntimeKind _) => service,
      autoDownload: autoDownload,
      onError: onError,
    );

    expect(enqueued.single.chapterKeys, <String>['/chapter/2', '/chapter/3'],
        reason: '源新→旧，入队要反过来：旧章先下');
  });

  test('首次入库 chapters 为空 → 刷新拿到整份列表不算新章、不入队', () async {
    final String keyA = await addBook(
      entryFor('/series/a'),
      autoDownload: true,
    );
    expect((await stored(keyA)).chapters, isEmpty);

    adapter.script =
        (OnlineMangaLibraryEntry entry) async => OnlineMangaRefreshResult(
              series: entry.series,
              chapters: const <OnlineMangaChapter>[c2, c1],
            );

    final int refreshed = await runOnlineMangaUpdateProbe(
      database: database,
      serviceFor: (OnlineMangaRuntimeKind _) => service,
      autoDownload: autoDownload,
      onError: onError,
    );

    expect(refreshed, 1);
    expect(errors, isEmpty);
    expect(enqueued, isEmpty, reason: 'previous 为空是首次拉取，不是更新');
    expect((await stored(keyA)).chapters, hasLength(2), reason: '列表本身照常落库');
  });

  test('章节没变时不入队', () async {
    await addBook(
      entryFor('/series/a', chapters: const <OnlineMangaChapter>[c2, c1]),
      autoDownload: true,
    );
    adapter.script = (OnlineMangaLibraryEntry entry) async =>
        OnlineMangaRefreshResult(
            series: entry.series, chapters: entry.chapters);

    final int refreshed = await runOnlineMangaUpdateProbe(
      database: database,
      serviceFor: (OnlineMangaRuntimeKind _) => service,
      autoDownload: autoDownload,
    );
    expect(refreshed, 1);
    expect(enqueued, isEmpty);
  });

  test('不传 autoDownload 回调时探针照常刷新、不炸', () async {
    await addBook(
      entryFor('/series/a', chapters: const <OnlineMangaChapter>[c2, c1]),
      autoDownload: true,
    );
    adapter.script =
        (OnlineMangaLibraryEntry entry) async => OnlineMangaRefreshResult(
              series: entry.series,
              chapters: const <OnlineMangaChapter>[c3, c2, c1],
            );
    final int refreshed = await runOnlineMangaUpdateProbe(
      database: database,
      serviceFor: (OnlineMangaRuntimeKind _) => service,
    );
    expect(refreshed, 1);
  });

  test('一条刷新抛错 → onError 收到它的 bookKey，其它条目照常刷新入队', () async {
    final String keyA = await addBook(
      entryFor('/series/a', chapters: const <OnlineMangaChapter>[c2, c1]),
      autoDownload: true,
    );
    final String keyB = await addBook(
      entryFor('/series/b', chapters: const <OnlineMangaChapter>[c2, c1]),
      autoDownload: true,
    );

    adapter.script = (OnlineMangaLibraryEntry entry) async {
      if (entry.series.key == '/series/a') {
        throw const OnlineMangaUnavailable(
          OnlineMangaUnavailableReason.runtimeFailure,
          'boom',
        );
      }
      return OnlineMangaRefreshResult(
        series: entry.series,
        chapters: const <OnlineMangaChapter>[c3, c2, c1],
      );
    };

    final int refreshed = await runOnlineMangaUpdateProbe(
      database: database,
      serviceFor: (OnlineMangaRuntimeKind _) => service,
      autoDownload: autoDownload,
      onError: onError,
    );

    expect(refreshed, 1, reason: '抛错那条不计入 refreshed');
    expect(errors, hasLength(1));
    expect(errors.single.bookKey, keyA);
    expect(errors.single.error, isA<OnlineMangaUnavailable>());
    expect(enqueued, hasLength(1));
    expect(enqueued.single.seriesKey, '/series/b');
    expect(enqueued.single.chapterKeys, <String>['/chapter/3']);
    expect((await stored(keyA)).chapters, hasLength(2), reason: 'A 库里原样');
    expect((await stored(keyB)).chapters, hasLength(3));
  });

  test('autoDownload 回调自己抛错也只算这一条失败，不阻断后面的条目', () async {
    await addBook(
      entryFor('/series/a', chapters: const <OnlineMangaChapter>[c2, c1]),
      autoDownload: true,
    );
    final String keyB = await addBook(
      entryFor('/series/b', chapters: const <OnlineMangaChapter>[c2, c1]),
      autoDownload: true,
    );
    adapter.script =
        (OnlineMangaLibraryEntry entry) async => OnlineMangaRefreshResult(
              series: entry.series,
              chapters: const <OnlineMangaChapter>[c3, c2, c1],
            );

    await runOnlineMangaUpdateProbe(
      database: database,
      serviceFor: (OnlineMangaRuntimeKind _) => service,
      autoDownload: (OnlineMangaLibraryEntry entry,
          List<OnlineMangaChapter> chapters) async {
        if (entry.series.key == '/series/a') throw StateError('queue full');
        await autoDownload(entry, chapters);
      },
      onError: onError,
    );

    expect(errors, hasLength(1));
    expect(errors.single.error, isA<StateError>());
    expect(enqueued.single.seriesKey, '/series/b');
    expect((await stored(keyB)).chapters, hasLength(3));
  });
}

typedef _RefreshScript = Future<OnlineMangaRefreshResult> Function(
  OnlineMangaLibraryEntry entry,
);

/// 可编排的假运行时：`script` 决定每次 refresh 返回什么 / 抛什么。
class _ScriptedAdapter implements OnlineMangaRuntimeAdapter {
  _RefreshScript script = (OnlineMangaLibraryEntry entry) async =>
      OnlineMangaRefreshResult(series: entry.series, chapters: entry.chapters);

  final List<String> refreshedSeriesKeys = <String>[];

  @override
  OnlineMangaRuntimeKind get kind => OnlineMangaRuntimeKind.mihon;

  @override
  bool get isSupportedOnThisPlatform => true;

  @override
  Future<String?> sourceLabel(OnlineMangaLibraryEntry entry) async => 'Fixture';

  @override
  Future<OnlineMangaRefreshResult> refresh(OnlineMangaLibraryEntry entry) {
    refreshedSeriesKeys.add(entry.series.key);
    return script(entry);
  }

  @override
  Future<List<OnlineMangaPageRef>> resolveChapterPages({
    required OnlineMangaLibraryEntry entry,
    required OnlineMangaChapter chapter,
  }) =>
      throw UnimplementedError();

  @override
  Future<Uint8List> fetchChapterPage(OnlineMangaPageRef page) =>
      throw UnimplementedError();

  @override
  Future<List<int>> fetchCover(
    OnlineMangaLibraryEntry entry,
    String url,
  ) async =>
      <int>[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
}
