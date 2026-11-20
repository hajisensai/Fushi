import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_service.dart';
import 'package:fushi/src/media/manga/library/online_manga_runtime_adapter.dart';
import 'package:fushi_engine/epub/epub_storage.dart';

/// v3 描述符（设计稿 2026-09-12 §2.3）：只在 v2 上加 `subscribed` / `autoDownload`
/// 两个可选位，不加 DB 列。这里钉三件事：往返一致、旧版本解析成 false、服务层的
/// 刷新 / 选章不把订阅位冲掉。
void main() {
  const List<OnlineMangaChapter> chapters = <OnlineMangaChapter>[
    OnlineMangaChapter(
      key: '/chapter/2',
      name: 'Chapter 2',
      number: 2,
      uploadedAt: 2,
      raw: <String, Object?>{'url': '/chapter/2'},
    ),
    OnlineMangaChapter(
      key: '/chapter/1',
      name: 'Chapter 1',
      number: 1,
      uploadedAt: 1,
      raw: <String, Object?>{'url': '/chapter/1'},
    ),
  ];

  OnlineMangaLibraryEntry entryFor({
    List<OnlineMangaChapter> chapters = const <OnlineMangaChapter>[],
    int? currentChapterIndex,
    bool subscribed = false,
    bool autoDownload = false,
  }) => OnlineMangaLibraryEntry(
    runtime: OnlineMangaRuntimeKind.mihon,
    extensionPackage: 'org.example.fixture',
    sourceId: '9223372036854775807',
    series: const OnlineMangaSeries(
      key: '/series/fixture',
      title: 'Fixture series',
      author: 'Fixture author',
      coverUrl: 'https://example.test/cover',
      raw: <String, Object?>{'url': '/series/fixture'},
    ),
    chapters: chapters,
    currentChapterIndex: currentChapterIndex,
    subscribed: subscribed,
    autoDownload: autoDownload,
  );

  Map<String, Object?> v2Json() => <String, Object?>{
    'type': 'hibiki-online-manga',
    'version': 2,
    'runtime': 'mihon',
    'extensionPackage': 'org.example.fixture',
    'sourceId': '1',
    'series': <String, Object?>{
      'key': '/s',
      'title': 'S',
      'raw': <String, Object?>{},
    },
    'chapters': <Map<String, Object?>>[
      <String, Object?>{
        'key': '/c/1',
        'name': 'ok',
        'raw': <String, Object?>{},
      },
    ],
    'currentChapterIndex': 0,
  };

  group('OnlineMangaLibraryEntry v3', () {
    test('v3 往返：subscribed / autoDownload 两位与 version 一起写出、读回', () {
      final OnlineMangaLibraryEntry entry = entryFor(
        chapters: chapters,
        currentChapterIndex: 1,
        subscribed: true,
        autoDownload: false,
      );
      final String encoded = entry.encode();
      final Map<String, Object?> json =
          (jsonDecode(encoded) as Map<Object?, Object?>)
              .cast<String, Object?>();
      expect(json['version'], 3);
      expect(json['type'], 'hibiki-online-manga');
      expect(json['subscribed'], isTrue);
      expect(json['autoDownload'], isFalse);

      final OnlineMangaLibraryEntry parsed = OnlineMangaLibraryEntry.tryParse(
        encoded,
      )!;
      expect(parsed.subscribed, isTrue);
      expect(parsed.autoDownload, isFalse);
      expect(parsed.currentChapterIndex, 1);
      expect(parsed.chapters.map((OnlineMangaChapter c) => c.key), <String>[
        '/chapter/2',
        '/chapter/1',
      ]);
    });

    test('v2 JSON（没有订阅两键）仍解析，两位缺省 false', () {
      final OnlineMangaLibraryEntry parsed = OnlineMangaLibraryEntry.tryParse(
        jsonEncode(v2Json()),
      )!;
      expect(parsed.subscribed, isFalse);
      expect(parsed.autoDownload, isFalse);
      expect(parsed.chapters.single.key, '/c/1');
      expect(parsed.currentChapterIndex, 0);
    });

    test('v1 hibiki-mihon 描述符解析成功，两位 false', () {
      final String legacy = jsonEncode(<String, Object?>{
        'type': 'hibiki-mihon',
        'version': 1,
        'extensionPackage': 'org.example.fixture',
        'sourceId': '9223372036854775807',
        'manga': <String, Object?>{
          'url': '/series/fixture',
          'title': 'Fixture series',
        },
        'chapters': <Map<String, Object?>>[
          <String, Object?>{'url': '/chapter/1', 'name': 'Chapter 1'},
        ],
        'currentChapterIndex': 0,
      });
      final OnlineMangaLibraryEntry parsed = OnlineMangaLibraryEntry.tryParse(
        legacy,
      )!;
      expect(parsed.runtime, OnlineMangaRuntimeKind.mihon);
      expect(parsed.subscribed, isFalse);
      expect(parsed.autoDownload, isFalse);
    });

    test('未知 version 4 不解析（不认识的版本不猜形状）', () {
      final Map<String, Object?> json = v2Json()..['version'] = 4;
      expect(OnlineMangaLibraryEntry.tryParse(jsonEncode(json)), isNull);
    });

    test('v3 描述符里订阅键是非 bool 值时按 false 读（不炸整条）', () {
      final Map<String, Object?> json = v2Json()
        ..['version'] = 3
        ..['subscribed'] = 'yes'
        ..['autoDownload'] = 1;
      final OnlineMangaLibraryEntry parsed = OnlineMangaLibraryEntry.tryParse(
        jsonEncode(json),
      )!;
      expect(parsed.subscribed, isFalse);
      expect(parsed.autoDownload, isFalse);
    });

    test('copyWith(subscribed: true) 只改这一位，其它字段原样', () {
      final OnlineMangaLibraryEntry base = entryFor(
        chapters: chapters,
        currentChapterIndex: 1,
      );
      final OnlineMangaLibraryEntry copied = base.copyWith(subscribed: true);
      expect(copied.subscribed, isTrue);
      expect(copied.autoDownload, isFalse);
      expect(copied.runtime, base.runtime);
      expect(copied.extensionPackage, base.extensionPackage);
      expect(copied.sourceId, base.sourceId);
      expect(identical(copied.series, base.series), isTrue);
      expect(identical(copied.chapters, base.chapters), isTrue);
      expect(copied.currentChapterIndex, 1);

      final OnlineMangaLibraryEntry both = copied.copyWith(autoDownload: true);
      expect(both.subscribed, isTrue, reason: 'copyWith 不传的位沿用原值');
      expect(both.autoDownload, isTrue);
    });
  });

  group('OnlineMangaLibraryService 订阅位', () {
    late Directory root;
    late FushiDatabase database;
    late OnlineMangaLibraryService service;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('fushi-online-manga-v3-');
      EpubStorage.debugBaseDirectoryOverride = root.path;
      database = FushiDatabase.forTesting(NativeDatabase.memory());
      service = OnlineMangaLibraryService(
        database: database,
        rootDirectory: root,
        adapter: _FixtureAdapter(),
      );
    });

    tearDown(() async {
      EpubStorage.debugBaseDirectoryOverride = null;
      await database.close();
      if (await root.exists()) await root.delete(recursive: true);
    });

    Future<OnlineMangaLibraryEntry> stored(String bookKey) async =>
        OnlineMangaLibraryEntry.tryParse(
          (await database.getEpubBook(bookKey))!.sourceMetadata,
        )!;

    test('setSubscription 落库；refreshFromSource 与 selectChapter 不冲掉', () async {
      final EpubBookRow row = await service.add(entryFor(chapters: chapters));
      final OnlineMangaLibraryEntry initial = await stored(row.bookKey);
      expect(initial.subscribed, isFalse);
      expect(initial.autoDownload, isFalse);

      final OnlineMangaLibraryEntry subscribed = await service.setSubscription(
        bookKey: row.bookKey,
        entry: initial,
        subscribed: true,
        autoDownload: true,
      );
      expect(subscribed.subscribed, isTrue);
      expect(subscribed.autoDownload, isTrue);
      expect(subscribed.chapters, hasLength(2), reason: '章节列表原样');

      final OnlineMangaLibraryEntry afterSet = await stored(row.bookKey);
      expect(afterSet.subscribed, isTrue);
      expect(afterSet.autoDownload, isTrue);
      expect(afterSet.chapters, hasLength(2));

      // 假 adapter 返回同一份章节；refresh 走 copyWith，两位必须活下来。
      final OnlineMangaLibraryEntry refreshed = await service.refreshFromSource(
        bookKey: row.bookKey,
        entry: afterSet,
      );
      expect(refreshed.subscribed, isTrue);
      expect(refreshed.autoDownload, isTrue);
      final OnlineMangaLibraryEntry afterRefresh = await stored(row.bookKey);
      expect(afterRefresh.subscribed, isTrue, reason: '刷新不能把订阅冲掉');
      expect(afterRefresh.autoDownload, isTrue);

      final OnlineMangaLibraryEntry selected = await service.selectChapter(
        bookKey: row.bookKey,
        entry: afterRefresh,
        chapterKey: afterRefresh.chapters[0].key,
      );
      expect(selected.currentChapterIndex, 0);
      final OnlineMangaLibraryEntry afterSelect = await stored(row.bookKey);
      expect(afterSelect.subscribed, isTrue, reason: '选章不能把订阅冲掉');
      expect(afterSelect.autoDownload, isTrue);
      expect(afterSelect.currentChapterIndex, 0);
    });

    // BUG-4909（gap-mangamisc-1）：写方各拿各的快照整份写回会互相回滚。
    test('拿着进页时快照的刷新晚落库：不回滚期间点的订阅', () async {
      final EpubBookRow row = await service.add(entryFor(chapters: chapters));
      // 进页时读到的描述符（未订阅）；刷新在飞的这几秒里用户点了订阅。
      final OnlineMangaLibraryEntry pageSnapshot = await stored(row.bookKey);
      await service.setSubscription(
        bookKey: row.bookKey,
        entry: pageSnapshot,
        subscribed: true,
        autoDownload: true,
      );
      // 刷新带着旧快照落库。
      final OnlineMangaLibraryEntry refreshed = await service.refreshFromSource(
        bookKey: row.bookKey,
        entry: pageSnapshot,
      );
      final OnlineMangaLibraryEntry after = await stored(row.bookKey);
      expect(after.subscribed, isTrue, reason: '旧快照的刷新把订阅写回了 false');
      expect(after.autoDownload, isTrue);
      expect(refreshed.subscribed, isTrue, reason: '返回值也要是库里的最新值');
    });

    test('拿着旧快照写订阅：不回滚期间选的章与刷进来的章表', () async {
      final EpubBookRow row = await service.add(entryFor(chapters: chapters));
      final OnlineMangaLibraryEntry pageSnapshot = await stored(row.bookKey);
      await service.selectChapter(
        bookKey: row.bookKey,
        entry: pageSnapshot,
        chapterKey: chapters[1].key,
      );
      const OnlineMangaChapter fresh = OnlineMangaChapter(
        key: '/chapter/3',
        name: 'Chapter 3',
        number: 3,
        raw: <String, Object?>{'url': '/chapter/3'},
      );
      await service.refresh(
        bookKey: row.bookKey,
        existing: pageSnapshot,
        series: pageSnapshot.series,
        chapters: <OnlineMangaChapter>[fresh, ...chapters],
      );
      await service.setSubscription(
        bookKey: row.bookKey,
        entry: pageSnapshot,
        subscribed: true,
        autoDownload: false,
      );
      final OnlineMangaLibraryEntry after = await stored(row.bookKey);
      expect(after.subscribed, isTrue);
      expect(after.chapters, hasLength(3), reason: '旧快照的订阅写把新章表冲掉了');
      expect(after.currentChapter?.key, chapters[1].key);
    });

    test('selectChapter 按 key：库里章表已被刷新改过时仍选中同一章', () async {
      final EpubBookRow row = await service.add(entryFor(chapters: chapters));
      final OnlineMangaLibraryEntry pageSnapshot = await stored(row.bookKey);
      const OnlineMangaChapter fresh = OnlineMangaChapter(
        key: '/chapter/3',
        name: 'Chapter 3',
        number: 3,
        raw: <String, Object?>{'url': '/chapter/3'},
      );
      // 源在最前插了一话：页面手上那份章表里下标 0 的章，在库里变成下标 1。
      await service.refresh(
        bookKey: row.bookKey,
        existing: pageSnapshot,
        series: pageSnapshot.series,
        chapters: <OnlineMangaChapter>[fresh, ...chapters],
      );
      final OnlineMangaLibraryEntry selected = await service.selectChapter(
        bookKey: row.bookKey,
        entry: pageSnapshot,
        chapterKey: pageSnapshot.chapters[0].key,
      );
      expect(selected.currentChapterIndex, 1, reason: '下标要按库里的章表重算');
      expect(selected.currentChapter?.key, pageSnapshot.chapters[0].key);
      final OnlineMangaLibraryEntry after = await stored(row.bookKey);
      expect(after.chapters, hasLength(3), reason: '选章不能把章表回滚成页面快照');
      expect(after.currentChapter?.key, pageSnapshot.chapters[0].key);

      await expectLater(
        service.selectChapter(
          bookKey: row.bookKey,
          entry: pageSnapshot,
          chapterKey: '/gone',
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('重复 add 走 refresh 分支，同样保住订阅位', () async {
      final EpubBookRow row = await service.add(entryFor(chapters: chapters));
      await service.setSubscription(
        bookKey: row.bookKey,
        entry: await stored(row.bookKey),
        subscribed: true,
        autoDownload: false,
      );

      // 源浏览页再点一次「加入书架」：传进来的 entry 两位都是 false。
      final EpubBookRow again = await service.add(entryFor(chapters: chapters));
      expect(again.bookKey, row.bookKey);
      final OnlineMangaLibraryEntry afterReadd = await stored(row.bookKey);
      expect(afterReadd.subscribed, isTrue, reason: '库里的订阅位不能被入参覆盖');
      expect(afterReadd.autoDownload, isFalse);
    });

    test('setSubscription 可以单独关 autoDownload 保留 subscribed', () async {
      final EpubBookRow row = await service.add(entryFor(chapters: chapters));
      final OnlineMangaLibraryEntry on = await service.setSubscription(
        bookKey: row.bookKey,
        entry: await stored(row.bookKey),
        subscribed: true,
        autoDownload: true,
      );
      final OnlineMangaLibraryEntry off = await service.setSubscription(
        bookKey: row.bookKey,
        entry: on,
        subscribed: true,
        autoDownload: false,
      );
      expect(off.subscribed, isTrue);
      expect(off.autoDownload, isFalse);
      final OnlineMangaLibraryEntry afterOff = await stored(row.bookKey);
      expect(afterOff.subscribed, isTrue);
      expect(afterOff.autoDownload, isFalse);
    });
  });

  // BUG-4913：作品页进页即后台刷新（联网要几秒），这期间用户开订阅 / 选章。
  // 刷新落库曾拿进页那一刻的快照整条覆盖，把刚写的订阅位与当前章冲掉；订阅写回
  // 也拿手里的旧快照覆盖刚刷新出来的章节表。
  group('OnlineMangaLibraryService 并发写不丢更新（BUG-4913）', () {
    late Directory root;
    late FushiDatabase database;
    late _GatedRefreshAdapter adapter;
    late OnlineMangaLibraryService service;

    const OnlineMangaChapter chapter3 = OnlineMangaChapter(
      key: '/chapter/3',
      name: 'Chapter 3',
      number: 3,
      uploadedAt: 3,
      raw: <String, Object?>{'url': '/chapter/3'},
    );
    final List<OnlineMangaChapter> refreshedChapters = <OnlineMangaChapter>[
      chapter3,
      ...chapters,
    ];

    setUp(() async {
      root = await Directory.systemTemp.createTemp('fushi-online-manga-race-');
      EpubStorage.debugBaseDirectoryOverride = root.path;
      database = FushiDatabase.forTesting(NativeDatabase.memory());
      adapter = _GatedRefreshAdapter();
      service = OnlineMangaLibraryService(
        database: database,
        rootDirectory: root,
        adapter: adapter,
      );
    });

    tearDown(() async {
      EpubStorage.debugBaseDirectoryOverride = null;
      await database.close();
      if (await root.exists()) await root.delete(recursive: true);
    });

    Future<OnlineMangaLibraryEntry> stored(String bookKey) async =>
        OnlineMangaLibraryEntry.tryParse(
          (await database.getEpubBook(bookKey))!.sourceMetadata,
        )!;

    test('刷新在途时开订阅：刷新落库后订阅两位仍在，章节表是刷新的', () async {
      final EpubBookRow row = await service.add(entryFor(chapters: chapters));
      final OnlineMangaLibraryEntry snapshot = await stored(row.bookKey);

      final Completer<OnlineMangaRefreshResult> gate =
          Completer<OnlineMangaRefreshResult>();
      adapter.next = gate;
      final Future<OnlineMangaLibraryEntry> refreshing = service
          .refreshFromSource(bookKey: row.bookKey, entry: snapshot);

      await service.setSubscription(
        bookKey: row.bookKey,
        entry: snapshot,
        subscribed: true,
        autoDownload: true,
      );
      gate.complete(
        OnlineMangaRefreshResult(
          series: snapshot.series,
          chapters: refreshedChapters,
        ),
      );
      final OnlineMangaLibraryEntry returned = await refreshing;

      final OnlineMangaLibraryEntry after = await stored(row.bookKey);
      expect(after.subscribed, isTrue, reason: '刷新不能拿旧快照冲掉刚开的订阅');
      expect(after.autoDownload, isTrue);
      expect(after.chapters.map((OnlineMangaChapter c) => c.key), <String>[
        '/chapter/3',
        '/chapter/2',
        '/chapter/1',
      ]);
      expect(returned.subscribed, isTrue, reason: '返回值是落库的那份');
    });

    test('刷新在途时选章：刷新落库后当前章按 key 跟到新下标', () async {
      final EpubBookRow row = await service.add(entryFor(chapters: chapters));
      final OnlineMangaLibraryEntry snapshot = await stored(row.bookKey);
      expect(snapshot.currentChapterIndex, isNull);

      final Completer<OnlineMangaRefreshResult> gate =
          Completer<OnlineMangaRefreshResult>();
      adapter.next = gate;
      final Future<OnlineMangaLibraryEntry> refreshing = service
          .refreshFromSource(bookKey: row.bookKey, entry: snapshot);

      // 选「Chapter 1」。
      await service.selectChapter(
        bookKey: row.bookKey,
        entry: snapshot,
        chapterKey: '/chapter/1',
      );
      gate.complete(
        OnlineMangaRefreshResult(
          series: snapshot.series,
          chapters: refreshedChapters,
        ),
      );
      await refreshing;

      final OnlineMangaLibraryEntry after = await stored(row.bookKey);
      expect(after.currentChapter?.key, '/chapter/1', reason: '刷新不能把刚选的章清掉');
      expect(after.currentChapterIndex, 2);
    });

    test('订阅写回以库里此刻的描述符为底：不拿手里的旧章节表盖掉刚刷新的', () async {
      final EpubBookRow row = await service.add(entryFor(chapters: chapters));
      final OnlineMangaLibraryEntry snapshot = await stored(row.bookKey);

      adapter.next = Completer<OnlineMangaRefreshResult>()
        ..complete(
          OnlineMangaRefreshResult(
            series: snapshot.series,
            chapters: refreshedChapters,
          ),
        );
      await service.refreshFromSource(bookKey: row.bookKey, entry: snapshot);

      // 作品页手里还是刷新前那份（两章）。
      final OnlineMangaLibraryEntry returned = await service.setSubscription(
        bookKey: row.bookKey,
        entry: snapshot,
        subscribed: true,
        autoDownload: false,
      );
      final OnlineMangaLibraryEntry after = await stored(row.bookKey);
      expect(after.chapters, hasLength(3), reason: '订阅只改两位，章节表不能退回旧的');
      expect(after.subscribed, isTrue);
      expect(after.autoDownload, isFalse);
      expect(returned.chapters, hasLength(3));
    });
  });
}

/// 刷新结果由测试手动放行，用来把「刷新在途」这段窗口钉住。
class _GatedRefreshAdapter extends _FixtureAdapter {
  Completer<OnlineMangaRefreshResult>? next;

  @override
  Future<OnlineMangaRefreshResult> refresh(OnlineMangaLibraryEntry entry) {
    final Completer<OnlineMangaRefreshResult>? gate = next;
    next = null;
    return gate?.future ?? super.refresh(entry);
  }
}

/// 与 online_manga_library_test.dart 同款：只做取封面 + 原样刷新。
class _FixtureAdapter implements OnlineMangaRuntimeAdapter {
  @override
  OnlineMangaRuntimeKind get kind => OnlineMangaRuntimeKind.mihon;

  @override
  bool get isSupportedOnThisPlatform => true;

  @override
  Future<String?> sourceLabel(OnlineMangaLibraryEntry entry) async => 'Fixture';

  @override
  Future<OnlineMangaRefreshResult> refresh(
    OnlineMangaLibraryEntry entry,
  ) async =>
      OnlineMangaRefreshResult(series: entry.series, chapters: entry.chapters);

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
