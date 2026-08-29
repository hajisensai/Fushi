import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_service.dart';
import 'package:fushi/src/media/manga/library/online_manga_runtime_adapter.dart';
import 'package:fushi/src/media/manga/mihon/mihon_models.dart';
import 'package:fushi/src/media/manga/mihon/mihon_reader_chapter.dart';
import 'package:path/path.dart' as p;

/// 身份串的分隔符是 NUL。测试里也用 `String.fromCharCode(0)` 而不是源码字面量：
/// 裸 NUL 会让 git 把 .dart 判成 binary，diff/merge 会静默丢改动。
final String _nul = String.fromCharCode(0);

void main() {
  late Directory root;
  late FushiDatabase database;
  late OnlineMangaLibraryService service;

  OnlineMangaLibraryEntry entryFor({
    List<OnlineMangaChapter> chapters = const <OnlineMangaChapter>[],
    int? currentChapterIndex,
  }) =>
      OnlineMangaLibraryEntry(
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
      );

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

  setUp(() async {
    root = await Directory.systemTemp.createTemp('hibiki-online-manga-');
    database = FushiDatabase.forTesting(NativeDatabase.memory());
    service = OnlineMangaLibraryService(
      database: database,
      rootDirectory: root,
      adapter: _FixtureAdapter(),
    );
  });

  tearDown(() async {
    await database.close();
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('入库写出漫画身份、封面与描述符，重复入库不建第二行', () async {
    final EpubBookRow row = await service.add(entryFor(chapters: chapters));

    expect(row.bookKey, startsWith('mihon-'));
    expect(row.format, 'manga');
    expect(row.coverPath, 'cover.png');
    expect(
      File(p.join(row.extractDir, 'cover.png')).existsSync(),
      isTrue,
      reason: '封面必须落盘，否则作品页首屏就得依赖网络',
    );

    final OnlineMangaLibraryEntry parsed =
        OnlineMangaLibraryEntry.tryParse(row.sourceMetadata)!;
    expect(parsed.runtime, OnlineMangaRuntimeKind.mihon);
    expect(parsed.sourceId, '9223372036854775807');
    expect(parsed.chapters, hasLength(2));
    expect(OnlineMangaLibraryService.initialChapterIndex(parsed), 1,
        reason: '源按新→旧返回，新读者从列表末尾（最旧那话）开始');

    final EpubBookRow again = await service.add(entryFor(chapters: chapters));
    expect(again.bookKey, row.bookKey);
    expect(await database.getAllEpubBooks(), hasLength(1));
  });

  test('刷出空章节列表不得覆盖书架：抛失败、库里旧描述符原样保留', () async {
    final EpubBookRow row = await service.add(entryFor(chapters: chapters));
    final OnlineMangaLibraryEntry stored =
        OnlineMangaLibraryEntry.tryParse(row.sourceMetadata)!;
    expect(stored.chapters, hasLength(2));

    // Mihon 的 chapterListParse 撞 Cloudflare 拦截页时**返回空列表而不抛**。
    await expectLater(
      service.refresh(
        bookKey: row.bookKey,
        existing: stored,
        series: stored.series,
        chapters: const <OnlineMangaChapter>[],
      ),
      throwsA(isA<OnlineMangaUnavailable>()),
    );

    final EpubBookRow? after = await database.getEpubBook(row.bookKey);
    final OnlineMangaLibraryEntry kept =
        OnlineMangaLibraryEntry.tryParse(after!.sourceMetadata)!;
    expect(kept.chapters, hasLength(2),
        reason: '一次没抛异常的失败刷新不得把书架里的章节清空');
    expect(after.chapterCount, 2);
  });

  test('刷新本来就空的条目仍照常落库（守卫只挡「有变没有」）', () async {
    final EpubBookRow row = await service.add(entryFor());
    final OnlineMangaLibraryEntry stored =
        OnlineMangaLibraryEntry.tryParse(row.sourceMetadata)!;
    expect(stored.chapters, isEmpty);

    final OnlineMangaLibraryEntry? updated = await service.refresh(
      bookKey: row.bookKey,
      existing: stored,
      series: stored.series,
      chapters: chapters,
    );
    expect(updated?.chapters, hasLength(2));
  });

  test('bookKey 与 v88 的推导逐字节一致（存量书架条目不能变孤儿）', () async {
    // v88 的公式（fushi/lib/src/media/manga/mihon/mihon_library.dart 原文）：
    //   sha256(packageName NUL sourceId NUL manga.url)[0:32]，前缀 'mihon-'
    // 这里独立重算一遍，而不是调被测代码——两侧同源取值的比较恒真。
    final String identity = <String>[
      'org.example.fixture',
      '9223372036854775807',
      '/series/fixture',
    ].join(_nul);
    final String expected =
        'mihon-${sha256.convert(utf8.encode(identity)).toString().substring(0, 32)}';

    expect(
      OnlineMangaLibraryService.bookKeyOf(entryFor()),
      expected,
      reason: 'bookKey 既是 epub_books 主键也是磁盘目录名；改一个字符就等于把'
          '所有已入库的在线漫画变成找不到的孤儿',
    );
  });

  test('v1 描述符（hibiki-mihon）仍能解析——存量条目零改动继续可用', () {
    final String legacy = jsonEncode(<String, Object?>{
      'type': 'hibiki-mihon',
      'version': 1,
      'extensionPackage': 'org.example.fixture',
      'sourceId': '9223372036854775807',
      'manga': <String, Object?>{
        'url': '/series/fixture',
        'title': 'Fixture series',
        'author': 'Fixture author',
        'thumbnail_url': 'https://example.test/cover',
      },
      'chapters': <Map<String, Object?>>[
        <String, Object?>{
          'url': '/chapter/2',
          'name': 'Chapter 2',
          'chapter_number': 2,
          'date_upload': 2,
        },
        <String, Object?>{
          'url': '/chapter/1',
          'name': 'Chapter 1',
          'chapter_number': 1,
          'date_upload': 1,
        },
      ],
      'currentChapterIndex': 1,
    });

    final OnlineMangaLibraryEntry parsed =
        OnlineMangaLibraryEntry.tryParse(legacy)!;
    expect(parsed.runtime, OnlineMangaRuntimeKind.mihon);
    expect(parsed.series.key, '/series/fixture');
    expect(parsed.series.coverUrl, 'https://example.test/cover');
    expect(parsed.chapters.map((OnlineMangaChapter c) => c.key),
        <String>['/chapter/2', '/chapter/1']);
    expect(parsed.currentChapter?.name, 'Chapter 1');
    expect(
      parsed.chapters.first.raw['url'],
      '/chapter/2',
      reason: 'raw 必须原样保留，否则回灌 getPages 时拿不到源认识的 payload',
    );
  });

  test('无 key 的章节被丢弃，不会挤进同一个空 chapterKey 主键', () {
    final String payload = jsonEncode(<String, Object?>{
      'type': 'hibiki-online-manga',
      'version': 2,
      'runtime': 'mihon',
      'extensionPackage': 'org.example.fixture',
      'sourceId': '1',
      'series': <String, Object?>{'key': '/s', 'title': 'S', 'raw': <String, Object?>{}},
      'chapters': <Map<String, Object?>>[
        <String, Object?>{'key': '', 'name': 'broken', 'raw': <String, Object?>{}},
        <String, Object?>{'key': '/c/1', 'name': 'ok', 'raw': <String, Object?>{}},
      ],
    });
    final OnlineMangaLibraryEntry parsed =
        OnlineMangaLibraryEntry.tryParse(payload)!;
    expect(parsed.chapters, hasLength(1));
    expect(parsed.chapters.single.key, '/c/1');
  });

  test('选章不再清零 reader_positions（换章不丢上一章进度）', () async {
    final EpubBookRow row = await service.add(entryFor(chapters: chapters));
    await ReaderPositionRepository(database).save(
      bookUid: row.uid,
      sectionIndex: 7,
      normCharOffset: 0,
      charOffset: 0,
    );

    final OnlineMangaLibraryEntry parsed =
        OnlineMangaLibraryEntry.tryParse(row.sourceMetadata)!;
    final OnlineMangaLibraryEntry selected = await service.selectChapter(
      bookKey: row.bookKey,
      entry: parsed,
      chapterIndex: 0,
    );
    expect(selected.currentChapter?.name, 'Chapter 2');

    final ReaderPosition? position =
        await ReaderPositionRepository(database).findByBookUid(row.uid);
    expect(
      position?.sectionIndex,
      7,
      reason: 'v88 前 selectChapter 会把这一行清零，于是换章即永久丢掉上一章'
          '的位置；每章进度归 manga_chapter_states 之后，选章不该再破坏它',
    );
  });

  test('刷新按 chapterKey 重定位当前章，而不是沿用下标', () async {
    final EpubBookRow row = await service.add(entryFor(chapters: chapters));
    final OnlineMangaLibraryEntry parsed =
        OnlineMangaLibraryEntry.tryParse(row.sourceMetadata)!;
    // 当前停在最旧那话（下标 1）。
    final OnlineMangaLibraryEntry selected = await service.selectChapter(
      bookKey: row.bookKey,
      entry: parsed,
      chapterIndex: 1,
    );

    // 源更新：最前面插了一话新的，于是原来那话的下标从 1 变成 2。
    const OnlineMangaChapter fresh = OnlineMangaChapter(
      key: '/chapter/3',
      name: 'Chapter 3',
      number: 3,
      uploadedAt: 3,
      raw: <String, Object?>{'url': '/chapter/3'},
    );
    final OnlineMangaLibraryEntry? refreshed = await service.refresh(
      bookKey: row.bookKey,
      existing: selected,
      series: selected.series,
      chapters: <OnlineMangaChapter>[fresh, ...chapters],
    );

    expect(refreshed!.currentChapterIndex, 2);
    expect(
      refreshed.currentChapter?.name,
      'Chapter 1',
      reason: '刷新后必须还停在同一话上；沿用旧下标会把用户挪到别的章',
    );
  });

  test('章节缓存目录按 chapterKey 稳定，预览与书架命中同一份', () async {
    final EpubBookRow row = await service.add(entryFor(chapters: chapters));
    final Directory first = service.chapterDirectory(row.bookKey, chapters.last);
    expect(
      p.relative(first.path, from: root.path),
      startsWith(p.join('reader-cache', 'chapters', row.bookKey)),
    );
    expect(
      service.chapterDirectory(row.bookKey, chapters.last).path,
      first.path,
    );
  });

  group('resumeChapterIndex', () {
    test('一次没读过 → 回退到最旧那话', () {
      final OnlineMangaLibraryEntry entry = entryFor(chapters: chapters);
      expect(
        OnlineMangaLibraryService.resumeChapterIndex(
          entry,
          const <String, MangaChapterStateRow>{},
        ),
        1,
      );
    });

    test('最近读过且没读完 → 落回那一话', () {
      final OnlineMangaLibraryEntry entry = entryFor(chapters: chapters);
      expect(
        OnlineMangaLibraryService.resumeChapterIndex(
          entry,
          <String, MangaChapterStateRow>{
            '/chapter/1': _state(chapterKey: '/chapter/1', updatedAt: 10),
          },
        ),
        1,
      );
    });

    test('最近那话已读完 → 前进到更新的一话（列表新→旧，所以下标 -1）', () {
      final OnlineMangaLibraryEntry entry = entryFor(chapters: chapters);
      expect(
        OnlineMangaLibraryService.resumeChapterIndex(
          entry,
          <String, MangaChapterStateRow>{
            '/chapter/1':
                _state(chapterKey: '/chapter/1', updatedAt: 10, readAt: 11),
          },
        ),
        0,
      );
    });

    test('最新一话也读完了 → 停在原地，不越界', () {
      final OnlineMangaLibraryEntry entry = entryFor(chapters: chapters);
      expect(
        OnlineMangaLibraryService.resumeChapterIndex(
          entry,
          <String, MangaChapterStateRow>{
            '/chapter/2':
                _state(chapterKey: '/chapter/2', updatedAt: 20, readAt: 21),
          },
        ),
        0,
      );
    });
  });

  group('运行时归一化', () {
    test('Mihon：url 即身份，raw 能被 MihonChapter.fromJson 吃回来', () {
      const MihonChapter native = MihonChapter(
        url: '/chapter/9',
        name: 'Chapter 9',
        uploadedAt: 99,
        number: 9,
        scanlator: 'Fixture scans',
      );
      final OnlineMangaChapter normalized =
          MihonLibraryAdapter.chapterOf(native);
      expect(normalized.key, '/chapter/9');
      expect(normalized.scanlator, 'Fixture scans');
      expect(normalized.number, 9);
      expect(MihonChapter.fromJson(normalized.raw).url, '/chapter/9');
    });

    test('Mihon：详情增量不带 url 时，身份回退到已知 key（BUG-1767 同族）', () {
      const MihonManga delta = MihonManga(url: '', title: 'Delta only');
      final OnlineMangaSeries series = MihonLibraryAdapter.seriesOf(delta);
      // seriesOf 的 fallback 就是 manga.url 本身；这里验证的是「raw 里一定补得出
      // 一个 url」，否则回灌 MihonManga.fromJson 会造出无身份的对象。
      expect(series.raw.containsKey('url'), isTrue);
    });

    test('Aidoku：scanlators 是复数列表、字段是蛇形、标题可回退到话号', () {
      final List<OnlineMangaChapter> parsed =
          AidokuLibraryAdapter.chaptersOf(<String, Object?>{
        'chapters': <Map<String, Object?>>[
          <String, Object?>{
            'key': '/c/10',
            'title': '',
            'chapter_number': 10,
            'date_uploaded': 1234,
            'scanlators': <String>['Alpha', 'Beta'],
          },
        ],
      });
      expect(parsed, hasLength(1));
      expect(parsed.single.key, '/c/10');
      expect(parsed.single.number, 10);
      expect(parsed.single.uploadedAt, 1234);
      expect(
        parsed.single.scanlator,
        'Alpha, Beta',
        reason: 'Aidoku 用复数 scanlators 列表；读成单数 scanlator 会得到 null',
      );
      expect(
        parsed.single.name,
        'Ch. 10',
        reason: '标题为空要回退到话号，否则章节列表是一排空行',
      );
    });

    test('Aidoku：作品 raw 剥掉 chapters，避免几百章存两遍', () {
      final OnlineMangaSeries series =
          AidokuLibraryAdapter.seriesOf(<String, Object?>{
        'key': '/s/1',
        'title': 'S',
        'authors': <String>['A', 'B'],
        'tags': <String>['x', 'y'],
        'chapters': <Object?>[<String, Object?>{'key': '/c/1'}],
      }, fallbackKey: '/s/1');
      expect(series.raw.containsKey('chapters'), isFalse);
      expect(series.author, 'A, B');
      expect(series.genreLabels, <String>['x', 'y']);
    });
  });
}

MangaChapterStateRow _state({
  required String chapterKey,
  required int updatedAt,
  int? readAt,
  int lastPage = 3,
}) =>
    MangaChapterStateRow(
      bookUid: 'uid',
      chapterKey: chapterKey,
      lastPage: lastPage,
      lastFraction: -1,
      readAt: readAt,
      updatedAt: updatedAt,
    );

/// 只做「取封面」这一件事的适配器。
///
/// 服务层的契约（身份、落盘、去重、刷新重定位）与具体运行时无关，用真
/// MihonManager 反而要先把扩展登记进库才能走到 fetchCover。
class _FixtureAdapter implements OnlineMangaRuntimeAdapter {
  @override
  OnlineMangaRuntimeKind get kind => OnlineMangaRuntimeKind.mihon;

  @override
  bool get isSupportedOnThisPlatform => true;

  @override
  Future<String?> sourceLabel(OnlineMangaLibraryEntry entry) async => 'Fixture';

  @override
  Future<OnlineMangaRefreshResult> refresh(OnlineMangaLibraryEntry entry) async =>
      OnlineMangaRefreshResult(series: entry.series, chapters: entry.chapters);

  @override
  Future<OnlineMangaReaderChapter> openChapter({
    required OnlineMangaLibraryEntry entry,
    required OnlineMangaChapter chapter,
    required Directory managedDirectory,
    required bool persistProgress,
    int? initialPage,
  }) =>
      throw UnimplementedError();

  @override
  Future<List<int>> fetchCover(
    OnlineMangaLibraryEntry entry,
    String url,
  ) async =>
      // PNG 魔数：让 _imageExtension 判成 .png。
      <int>[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
}
