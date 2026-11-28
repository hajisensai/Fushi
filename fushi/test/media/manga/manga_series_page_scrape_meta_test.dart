import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/detail/media_poster_detail.dart';
import 'package:fushi/src/media/manga/library/manga_series_page.dart';
import 'package:fushi/src/media/manga/manga_ocr_provider.dart';
import 'package:fushi/src/media/manga/manga_ocr_wizard_engines.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_job_registry.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/ocr/manga_ocr_service.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import '../../helpers/test_platform_services.dart';

/// 本地漫画作品页显示刮削资料（2026-11-16 所有者「详情页元数据呢，有元数据的都
/// 要有详情页」）：单本刮削资料（或所属合集的作品资料）→ 海报 hero 换横版背景、
/// 原名、评分 / 年份 / 类型 chip、简介、「资料」区块与「查看条目」，与书详情页
/// 同一份展示；没有资料时作品页不变（封面模糊垫底、无资料区块）。
class _TestAppModel extends AppModel {
  _TestAppModel(this._db, Directory root) : super(testPlatformServices()) {
    wireLocalAudioForTesting(
      prefsRepo: PreferencesRepository(_db),
      databaseDirectory: root,
    );
  }

  final FushiDatabase _db;

  @override
  FushiDatabase get database => _db;
}

class _FakeOcrService implements MangaOcrService {
  @override
  bool get isSupportedPlatform => true;

  @override
  Future<MangaOcrModelStatus> modelStatus() async => const MangaOcrModelStatus(
    detectorReady: true,
    recognizerReady: true,
    diskBytes: 1,
    totalBytes: 1,
  );

  @override
  Stream<MangaOcrDownloadEvent> downloadModels() =>
      const Stream<MangaOcrDownloadEvent>.empty();

  @override
  Future<int> deleteModels() async => 0;

  @override
  Stream<MangaOcrVolumeEvent> ocrFolder({
    required String imageDirPath,
    String? volumeTitle,
    int startPage = 0,
  }) => const Stream<MangaOcrVolumeEvent>.empty();
}

const String _bookKey = 'kimetsu vol 1';
const String _bookUid = 'kimetsu-uid-1';

class _Fixture {
  _Fixture(this.db, this.appModel, this.root);

  final FushiDatabase db;
  final _TestAppModel appModel;
  final Directory root;

  String get backdropPath => p.join(root.path, 'backdrop.jpg');
}

Future<_Fixture> _setUp(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1200, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  final Directory root = Directory.systemTemp.createTempSync(
    'manga_series_scrape_meta_',
  );
  addTearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });
  final Directory bookDir = Directory(p.join(root.path, 'book'))..createSync();
  File(p.join(bookDir.path, 'manga.json')).writeAsStringSync(
    jsonEncode(<String, Object?>{
      'pages': <Map<String, Object?>>[
        for (int i = 1; i <= 3; i++)
          <String, Object?>{
            'url': 'images/p$i.jpg',
            'width': 100,
            'height': 150,
            'blocks': <Object?>[],
          },
      ],
    }),
  );
  File(p.join(root.path, 'backdrop.jpg')).writeAsBytesSync(<int>[1, 2, 3]);
  await tester.runAsync(() async {
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: _bookKey,
        title: '鬼滅の刃 1',
        epubPath: 'manga.json',
        extractDir: bookDir.path,
        chapterCount: 3,
        chaptersJson: '[]',
        importedAt: DateTime.now().millisecondsSinceEpoch,
        format: const Value<String>('manga'),
        uid: const Value<String>(_bookUid),
        author: const Value<String>('吾峠呼世晴'),
      ),
    );
  });
  return _Fixture(db, _TestAppModel(db, root), root);
}

Future<void> _scrapeItem(WidgetTester tester, _Fixture f) =>
    tester.runAsync(() async {
      await f.db.upsertItemScrapeMeta(
        ItemScrapeMetaCompanion.insert(
          mediaType: MediaKind.epub.dbValue,
          entryKey: _bookUid,
          source: 'anilist',
          title: const Value<String>('鬼灭之刃'),
          originalTitle: const Value<String>('Demon Slayer'),
          summary: const Value<String>('炭治郎为让妹妹变回人类而踏上旅途。'),
          airDate: const Value<String>('2016-02-15'),
          rating: const Value<double>(8.4),
          ratingCount: const Value<int>(5321),
          tagsJson: const Value<String>(
            '[{"name":"Action"},{"name":"Supernatural"}]',
          ),
          detailUrl: const Value<String>('https://anilist.co/manga/87216'),
          scrapedAt: 1,
        ),
      );
      await f.db
          .into(f.db.itemImages)
          .insert(
            ItemImagesCompanion.insert(
              mediaType: MediaKind.epub.dbValue,
              entryKey: _bookUid,
              kind: MediaImageKind.backdrop.dbValue,
              path: f.backdropPath,
            ),
          );
    });

Widget _harness(_Fixture f, {List<Uri>? opened}) {
  return ProviderScope(
    overrides: <Override>[
      platformServicesProvider.overrideWithValue(testPlatformServices()),
      appProvider.overrideWith((ref) => f.appModel),
      mangaOcrJobRegistryProvider.overrideWithValue(MangaOcrJobRegistry()),
    ],
    child: TranslationProvider(
      child: MaterialApp(
        home: MangaSeriesPage(
          target: const ShelfMangaSeriesTarget(_bookKey),
          openExternal: (Uri uri) async => opened?.add(uri),
          ocrEnginesOverride: MangaOcrWizardEngines(
            service: _FakeOcrService(),
            initialEnginePreference: 'local_onnx',
            initialLensLanguage: 'ja',
            lensLanguageSetter: (_) async {},
          ),
        ),
      ),
    ),
  );
}

Future<void> _settle(WidgetTester tester, bool Function() until) async {
  await tester.runAsync(() async {
    for (int i = 0; i < 60 && !until(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
    }
  });
  await tester.pump(const Duration(seconds: 1));
}

bool _present(String key) =>
    find.byKey(ValueKey<String>(key)).evaluate().isNotEmpty;

MediaPosterDetailHero _hero(WidgetTester tester) =>
    tester.widget<MediaPosterDetailHero>(find.byType(MediaPosterDetailHero));

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.zhCn));

  testWidgets('单本有刮削资料：横版背景 / 原名 / 评分·年份·类型 / 简介 / 资料区块 / 查看条目', (
    WidgetTester tester,
  ) async {
    final _Fixture f = await _setUp(tester);
    await _scrapeItem(tester, f);
    final List<Uri> opened = <Uri>[];
    await tester.pumpWidget(_harness(f, opened: opened));
    await _settle(tester, () => _present('manga-series-rating'));

    final MediaPosterDetailHero hero = _hero(tester);
    final ImageProvider? backdrop = hero.backdrop;
    expect(backdrop, isA<ResizeImage>());
    final ImageProvider inner = (backdrop! as ResizeImage).imageProvider;
    expect(inner, isA<FileImage>());
    expect((inner as FileImage).file.path, f.backdropPath);
    expect(hero.originalTitle, 'Demon Slayer');
    expect(hero.summary, '炭治郎为让妹妹变回人类而踏上旅途。');
    expect(find.byKey(const ValueKey<String>('manga-series-rating')), findsOne);
    expect(find.text('2016'), findsOne);
    expect(find.text('Action'), findsOne);
    expect(find.text('Supernatural'), findsOne);

    // 资料区块：作者 / 发行日期 / 评分(人数) / 来源。
    final Finder facts = find.byKey(
      const ValueKey<String>('manga-series-facts'),
    );
    expect(find.descendant(of: facts, matching: find.text('吾峠呼世晴')), findsOne);
    expect(
      find.descendant(of: facts, matching: find.text('2016-02-15')),
      findsOne,
    );
    expect(
      find.descendant(of: facts, matching: find.textContaining('8.4')),
      findsOne,
    );

    // 来源写显示名（AniList），不是原始 key。
    expect(
      find.descendant(of: facts, matching: find.text('AniList')),
      findsOne,
    );
    // 页数并进资料区块；没打开过时不再有只装页数的「卷信息」卡。
    expect(
      find.descendant(
        of: facts,
        matching: find.text(t.manga_series_page_count),
      ),
      findsOne,
    );
    expect(find.text(t.manga_series_volume_info), findsNothing);

    // 原有本地卷功能都在：识别本卷 / OCR 设置，与刮削 / 查看条目同一排图标钮。
    expect(_present('manga_series_ocr_volume'), isTrue);
    expect(_present('manga_series_ocr_settings'), isTrue);
    expect(find.byTooltip('${t.book_detail_source_open} · AniList'), findsOne);

    final Finder link = find.byKey(
      const ValueKey<String>('manga-series-source-link'),
    );
    expect(link, findsOne);
    await tester.tap(link);
    await tester.pump();
    expect(opened, <Uri>[Uri.parse('https://anilist.co/manga/87216')]);
  });

  testWidgets('单本没刮削、所属合集有作品资料：退到合集资料', (WidgetTester tester) async {
    final _Fixture f = await _setUp(tester);
    await tester.runAsync(() async {
      final int cid = await f.db.createMediaCollection('鬼滅の刃');
      await f.db.addToCollection(cid, MediaKind.epub, _bookUid);
      await f.db.upsertCollectionScrapeMeta(
        CollectionScrapeMetaCompanion.insert(
          collectionId: Value<int>(cid),
          source: 'bangumi',
          subjectId: '1',
          title: '鬼灭之刃',
          summary: const Value<String>('作品简介'),
          rating: const Value<double>(7.9),
          tagsJson: const Value<String>('[{"name":"热血"}]'),
          scrapedAt: DateTime(2026),
        ),
      );
    });
    await tester.pumpWidget(_harness(f));
    await _settle(tester, () => _present('manga-series-rating'));

    expect(_hero(tester).summary, '作品简介');
    expect(find.byKey(const ValueKey<String>('manga-series-rating')), findsOne);
    expect(find.text('热血'), findsOne);
  });

  testWidgets('单本只有用户选的横幅、所属合集有作品资料：资料取合集，横幅取单本', (WidgetTester tester) async {
    final _Fixture f = await _setUp(tester);
    await tester.runAsync(() async {
      final int cid = await f.db.createMediaCollection('鬼滅の刃');
      await f.db.addToCollection(cid, MediaKind.epub, _bookUid);
      await f.db.upsertCollectionScrapeMeta(
        CollectionScrapeMetaCompanion.insert(
          collectionId: Value<int>(cid),
          source: 'bangumi',
          subjectId: '1',
          title: '鬼灭之刃',
          summary: const Value<String>('作品简介'),
          scrapedAt: DateTime(2026),
        ),
      );
      // 「横幅…」只给单本写了一张用户横幅，没有单本资料行。
      await f.db.replaceItemImagesOfKind(
        mediaType: MediaKind.epub,
        entryKey: _bookUid,
        kind: MediaImageKind.backdrop,
        images: <({String path, String? sourceUrl})>[
          (path: f.backdropPath, sourceUrl: null),
        ],
        userChosen: true,
      );
    });
    await tester.pumpWidget(_harness(f));
    await _settle(
      tester,
      () =>
          find.byType(MediaPosterDetailHero).evaluate().isNotEmpty &&
          _hero(tester).summary != null,
    );

    final MediaPosterDetailHero hero = _hero(tester);
    expect(hero.summary, '作品简介', reason: '选了横幅不该把合集的作品资料挤掉');
    final ImageProvider inner = (hero.backdrop! as ResizeImage).imageProvider;
    expect((inner as FileImage).file.path, f.backdropPath);
  });

  testWidgets('没有刮削资料：作品页不变（封面垫底、无资料区块 / 评分 / 外链）', (
    WidgetTester tester,
  ) async {
    final _Fixture f = await _setUp(tester);
    await tester.pumpWidget(_harness(f));
    await _settle(tester, () => _present('manga_series_open_local'));
    // 让刮削资料的异步读也走完（读空）。
    await _settle(tester, () => false);

    final MediaPosterDetailHero hero = _hero(tester);
    expect(hero.backdrop, isNull);
    expect(hero.logo, isNull);
    expect(hero.originalTitle, isNull);
    expect(hero.summary, isNull);
    // 资料区块只剩页数一行（书架侧事实），没有刮削来的发行日期 / 评分 / 来源。
    final Finder facts = find.byKey(
      const ValueKey<String>('manga-series-facts'),
    );
    expect(facts, findsOne);
    expect(
      find.descendant(
        of: facts,
        matching: find.text(t.manga_series_page_count),
      ),
      findsOne,
    );
    expect(
      find.descendant(
        of: facts,
        matching: find.text(t.book_detail_field_source),
      ),
      findsNothing,
    );
    expect(_present('manga-series-rating'), isFalse);
    expect(_present('manga-series-source-link'), isFalse);
    // 书架以外的入口没给刮削回调：不出刮削按钮。
    expect(_present('manga-series-scrape'), isFalse);
    expect(_present('manga_series_ocr_volume'), isTrue);
    expect(find.text(t.manga_series_volume_info), findsNothing);
  });
}
