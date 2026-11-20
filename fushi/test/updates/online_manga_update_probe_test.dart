import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_service.dart';
import 'package:fushi/src/media/manga/library/online_manga_runtime_adapter.dart';
import 'package:fushi/src/updates/update_probes.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_engine/epub/epub_storage.dart';

/// 在线漫画订阅自动下载（设计稿 2026-09-12 §5；拍板
/// design-nmv-series-refresh-autodl 选 a）：入队挂在书架服务的落库之后，后台探针
/// 与作品页刷新同走一处。真 in-memory DB + 真 `OnlineMangaLibraryService`，只把
/// 运行时换成可编排的假 adapter。
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
  }) => OnlineMangaLibraryEntry(
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
  late OnlineMangaAutoDownload enqueueHook;

  Future<void> autoDownload(
    OnlineMangaLibraryEntry entry,
    List<OnlineMangaChapter> chapters,
  ) async {
    enqueued.add((
      seriesKey: entry.series.key,
      chapterKeys: chapters
          .map((OnlineMangaChapter c) => c.key)
          .toList(growable: false),
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
    root = await Directory.systemTemp.createTemp('fushi-manga-probe-');
    EpubStorage.debugBaseDirectoryOverride = root.path;
    database = FushiDatabase.forTesting(NativeDatabase.memory());
    adapter = _ScriptedAdapter();
    enqueueHook = autoDownload;
    service = OnlineMangaLibraryService(
      database: database,
      rootDirectory: root,
      adapter: adapter,
      autoDownload:
          (OnlineMangaLibraryEntry entry, List<OnlineMangaChapter> chapters) =>
              enqueueHook(entry, chapters),
    );
    enqueued = <({String seriesKey, List<String> chapterKeys})>[];
    errors = <({Object error, String bookKey})>[];
    await ErrorLogService.instance.clear();
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
    adapter.script = (OnlineMangaLibraryEntry entry) async =>
        OnlineMangaRefreshResult(
          series: entry.series,
          chapters: const <OnlineMangaChapter>[c3, c2, c1],
        );

    final int refreshed = await runOnlineMangaUpdateProbe(
      database: database,
      serviceFor: (OnlineMangaRuntimeKind _) => service,
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

  // BUG-4909（gap-mangamisc-1）：探针开跑时读的快照在刷新的几秒里会过时。
  test('刷新途中用户关了自动下载 / 作品页已把新章刷进库：探针按库里的描述符办', () async {
    final String key = await addBook(
      entryFor('/series/a', chapters: const <OnlineMangaChapter>[c2, c1]),
      autoDownload: true,
    );
    adapter.script = (OnlineMangaLibraryEntry entry) async {
      // 探针的快照是 [c2, c1] + autoDownload；源答话之前作品页先刷进了 c3、
      // 用户又关掉了自动下载。
      await service.refresh(
        bookKey: key,
        existing: entry,
        series: entry.series,
        chapters: const <OnlineMangaChapter>[c3, c2, c1],
      );
      await service.setSubscription(
        bookKey: key,
        entry: await stored(key),
        subscribed: true,
        autoDownload: false,
      );
      return OnlineMangaRefreshResult(
        series: entry.series,
        chapters: const <OnlineMangaChapter>[c3, c2, c1],
      );
    };
    await runOnlineMangaUpdateProbe(
      database: database,
      serviceFor: (OnlineMangaRuntimeKind _) => service,
      onError: onError,
    );
    expect(errors, isEmpty);
    // 作品页那次刷新时自动下载还开着，c3 由它入队（拍板 design-nmv-series-refresh-autodl）；
    // 探针这次落库时自动下载已关、c3 也不是相对库里的新章，不得再入队。
    expect(enqueued, hasLength(1), reason: '只有作品页那次刷新入队');
    expect(enqueued.single.chapterKeys, <String>['/chapter/3']);
    final OnlineMangaLibraryEntry after = await stored(key);
    expect(after.autoDownload, isFalse, reason: '探针的旧快照把自动下载写回了 true');
    expect(after.subscribed, isTrue);
    expect(after.chapters, hasLength(3));
  });

  test('刷新途中用户关了自动下载：新章照常落库但不入队', () async {
    final String key = await addBook(
      entryFor('/series/a', chapters: const <OnlineMangaChapter>[c2, c1]),
      autoDownload: true,
    );
    adapter.script = (OnlineMangaLibraryEntry entry) async {
      await service.setSubscription(
        bookKey: key,
        entry: await stored(key),
        subscribed: true,
        autoDownload: false,
      );
      return OnlineMangaRefreshResult(
        series: entry.series,
        chapters: const <OnlineMangaChapter>[c3, c2, c1],
      );
    };
    await runOnlineMangaUpdateProbe(
      database: database,
      serviceFor: (OnlineMangaRuntimeKind _) => service,
      onError: onError,
    );
    expect(errors, isEmpty);
    expect(enqueued, isEmpty, reason: '落库时库里的自动下载位已是关');
    expect((await stored(key)).chapters, hasLength(3));
  });

  test('新出现多章时按旧→新章序入队', () async {
    await addBook(
      entryFor('/series/a', chapters: const <OnlineMangaChapter>[c1]),
      autoDownload: true,
    );
    adapter.script = (OnlineMangaLibraryEntry entry) async =>
        OnlineMangaRefreshResult(
          series: entry.series,
          chapters: const <OnlineMangaChapter>[c3, c2, c1],
        );

    await runOnlineMangaUpdateProbe(
      database: database,
      serviceFor: (OnlineMangaRuntimeKind _) => service,
      onError: onError,
    );

    expect(enqueued.single.chapterKeys, <String>[
      '/chapter/2',
      '/chapter/3',
    ], reason: '源新→旧，入队要反过来：旧章先下');
  });

  test('首次入库 chapters 为空 → 刷新拿到整份列表不算新章、不入队', () async {
    final String keyA = await addBook(
      entryFor('/series/a'),
      autoDownload: true,
    );
    expect((await stored(keyA)).chapters, isEmpty);

    adapter.script = (OnlineMangaLibraryEntry entry) async =>
        OnlineMangaRefreshResult(
          series: entry.series,
          chapters: const <OnlineMangaChapter>[c2, c1],
        );

    final int refreshed = await runOnlineMangaUpdateProbe(
      database: database,
      serviceFor: (OnlineMangaRuntimeKind _) => service,
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
          series: entry.series,
          chapters: entry.chapters,
        );

    final int refreshed = await runOnlineMangaUpdateProbe(
      database: database,
      serviceFor: (OnlineMangaRuntimeKind _) => service,
    );
    expect(refreshed, 1);
    expect(enqueued, isEmpty);
  });

  test('服务没装 autoDownload 回调时探针照常刷新、不炸', () async {
    await addBook(
      entryFor('/series/a', chapters: const <OnlineMangaChapter>[c2, c1]),
      autoDownload: true,
    );
    adapter.script = (OnlineMangaLibraryEntry entry) async =>
        OnlineMangaRefreshResult(
          series: entry.series,
          chapters: const <OnlineMangaChapter>[c3, c2, c1],
        );
    final OnlineMangaLibraryService bare = OnlineMangaLibraryService(
      database: database,
      rootDirectory: root,
      adapter: adapter,
    );
    final int refreshed = await runOnlineMangaUpdateProbe(
      database: database,
      serviceFor: (OnlineMangaRuntimeKind _) => bare,
    );
    expect(refreshed, 1);
    expect(enqueued, isEmpty);
  });

  // 拍板 design-nmv-series-refresh-autodl（选 a）：作品页 / 历史页刷新先发现的
  // 新章也要自动下载；只在探针里入队时，这些章探针再看已不算「新」，永远漏下。
  test('作品页刷新先发现新章：订阅了自动下载就入队，之后探针不重复入队', () async {
    final String key = await addBook(
      entryFor('/series/a', chapters: const <OnlineMangaChapter>[c2, c1]),
      autoDownload: true,
    );
    adapter.script = (OnlineMangaLibraryEntry entry) async =>
        OnlineMangaRefreshResult(
          series: entry.series,
          chapters: const <OnlineMangaChapter>[c3, c2, c1],
        );

    // 作品页 `_refreshFromSource` 走的就是这个口。
    final OnlineMangaLibraryEntry updated = await service.refreshFromSource(
      bookKey: key,
      entry: await stored(key),
    );
    expect(updated.chapters, hasLength(3));
    expect(enqueued, hasLength(1));
    expect(enqueued.single.seriesKey, '/series/a');
    expect(enqueued.single.chapterKeys, <String>['/chapter/3']);

    await runOnlineMangaUpdateProbe(
      database: database,
      serviceFor: (OnlineMangaRuntimeKind _) => service,
      onError: onError,
    );
    expect(errors, isEmpty);
    expect(enqueued, hasLength(1), reason: 'c3 已入过队，探针不得再排一遍');
  });

  test('作品页刷新：没订阅自动下载的条目不入队', () async {
    final String key = await addBook(
      entryFor('/series/a', chapters: const <OnlineMangaChapter>[c2, c1]),
    );
    adapter.script = (OnlineMangaLibraryEntry entry) async =>
        OnlineMangaRefreshResult(
          series: entry.series,
          chapters: const <OnlineMangaChapter>[c3, c2, c1],
        );
    await service.refreshFromSource(bookKey: key, entry: await stored(key));
    expect(enqueued, isEmpty);
    expect((await stored(key)).chapters, hasLength(3));
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

  test('入队抛错记进错误日志：章表已落库、刷新照算成功，不阻断后面的条目', () async {
    final String keyA = await addBook(
      entryFor('/series/a', chapters: const <OnlineMangaChapter>[c2, c1]),
      autoDownload: true,
    );
    final String keyB = await addBook(
      entryFor('/series/b', chapters: const <OnlineMangaChapter>[c2, c1]),
      autoDownload: true,
    );
    adapter.script = (OnlineMangaLibraryEntry entry) async =>
        OnlineMangaRefreshResult(
          series: entry.series,
          chapters: const <OnlineMangaChapter>[c3, c2, c1],
        );

    enqueueHook =
        (
          OnlineMangaLibraryEntry entry,
          List<OnlineMangaChapter> chapters,
        ) async {
          if (entry.series.key == '/series/a') throw StateError('queue full');
          await autoDownload(entry, chapters);
        };

    final int refreshed = await runOnlineMangaUpdateProbe(
      database: database,
      serviceFor: (OnlineMangaRuntimeKind _) => service,
      onError: onError,
    );

    expect(refreshed, 2, reason: '刷新本身成功，入队失败不该把这条算成没刷到');
    expect(errors, isEmpty);
    expect(
      ErrorLogService.instance.entries
          .where(
            (ErrorLogEntry e) =>
                e.source.startsWith('OnlineMangaLibraryService.autoDownload') &&
                e.error.contains('queue full'),
          )
          .length,
      1,
      reason: '入队失败要留痕，不能静默吞掉',
    );
    expect(enqueued.single.seriesKey, '/series/b');
    expect((await stored(keyA)).chapters, hasLength(3));
    expect((await stored(keyB)).chapters, hasLength(3));
  });
}

typedef _RefreshScript =
    Future<OnlineMangaRefreshResult> Function(OnlineMangaLibraryEntry entry);

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
  }) => throw UnimplementedError();

  @override
  Future<Uint8List> fetchChapterPage(OnlineMangaPageRef page) =>
      throw UnimplementedError();

  @override
  Future<List<int>> fetchCover(
    OnlineMangaLibraryEntry entry,
    String url,
  ) async => <int>[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
}
