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
import 'package:fushi/src/media/metadata/book_art_store.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/ocr/manga_ocr_service.dart';
import 'package:image/image.dart' as img;
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import '../../helpers/test_platform_services.dart';

/// BUG-4912（应用内反馈 vJJGPZtC3p）：书架里刮削过封面的漫画，书架卡显示刮削出的
/// 卷封面，点进作品页却还是源原来的封面——作品页只读 `row.coverPath`，不查刮削层
/// （[BookArtStore]）。作品页的封面 / hero 背景必须与书架卡同一优先级：
/// 用户 override > 刮削卷封面 > 书自带封面。
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

/// 一张能解码的小 PNG（[BookArtStore.write] 会校验卷封面字节可解码）。
List<int> _png(int shade) => img.encodePng(
  img.Image(width: 4, height: 6)..clear(img.ColorRgb8(shade, shade, shade)),
);

const String _bookKey = 'futari bus vol 1';
const String _bookUid = 'futari-bus-uid-1';

class _Fixture {
  _Fixture(this.db, this.appModel, this.root, this.ownCoverPath);

  final FushiDatabase db;
  final _TestAppModel appModel;
  final Directory root;
  final String ownCoverPath;
}

Future<_Fixture> _setUp(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1200, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  BookArtStore.resetForTesting();
  addTearDown(BookArtStore.resetForTesting);
  final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  final Directory root = Directory.systemTemp.createTempSync(
    'manga_series_scraped_cover_',
  );
  addTearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });
  final Directory bookDir = Directory(p.join(root.path, 'book'))..createSync();
  Directory(p.join(bookDir.path, 'images')).createSync();
  final String ownCover = p.join(bookDir.path, 'images', 'p1.jpg');
  File(ownCover).writeAsBytesSync(_png(10));
  File(p.join(bookDir.path, 'manga.json')).writeAsStringSync(
    jsonEncode(<String, Object?>{
      'pages': <Map<String, Object?>>[
        <String, Object?>{
          'url': 'images/p1.jpg',
          'width': 100,
          'height': 150,
          'blocks': <Object?>[],
        },
      ],
    }),
  );
  await tester.runAsync(() async {
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: _bookKey,
        title: 'FUTARI BUS 1',
        epubPath: 'manga.json',
        extractDir: bookDir.path,
        chapterCount: 1,
        chaptersJson: '[]',
        importedAt: DateTime.now().millisecondsSinceEpoch,
        format: const Value<String>('manga'),
        uid: const Value<String>(_bookUid),
        coverPath: const Value<String?>('images/p1.jpg'),
      ),
    );
  });
  return _Fixture(db, _TestAppModel(db, root), root, ownCover);
}

Widget _harness(_Fixture f) {
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

MediaPosterDetailHero? _heroOrNull(WidgetTester tester) {
  final Finder hero = find.byType(MediaPosterDetailHero);
  if (hero.evaluate().isEmpty) return null;
  return tester.widget<MediaPosterDetailHero>(hero);
}

/// 等作品页读到书行（hero 拿到封面）。
Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(() async {
    for (int i = 0; i < 60 && _heroOrNull(tester)?.posterImage == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
    }
  });
  await tester.pump(const Duration(seconds: 1));
}

/// [ImageProvider] → 它解码的磁盘文件路径（`resizedFileImage` 包一层 ResizeImage）。
String? _filePathOf(ImageProvider? provider) {
  ImageProvider? inner = provider;
  if (inner is ResizeImage) inner = inner.imageProvider;
  return inner is FileImage ? inner.file.path : null;
}

/// 海报位实际画的那张图。
String? _posterFilePath(WidgetTester tester) {
  final Finder image = find.descendant(
    of: find.byType(MediaPosterDetailHero),
    matching: find.byType(Image),
  );
  for (final Element e in image.evaluate()) {
    final String? path = _filePathOf((e.widget as Image).image);
    if (path != null) return path;
  }
  return null;
}

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.zhCn));

  testWidgets('没刮削：作品页封面 / hero 背景是书自带封面', (WidgetTester tester) async {
    final _Fixture f = await _setUp(tester);
    await tester.pumpWidget(_harness(f));
    await _settle(tester);

    final MediaPosterDetailHero hero = _heroOrNull(tester)!;
    expect(_filePathOf(hero.posterImage), f.ownCoverPath);
    expect(_filePathOf(hero.backdropFallback), f.ownCoverPath);
    expect(_posterFilePath(tester), f.ownCoverPath);
  });

  testWidgets('刮削过卷封面：作品页封面 / hero 背景与书架卡一致用刮削封面', (WidgetTester tester) async {
    final _Fixture f = await _setUp(tester);
    final BookArtStore store = BookArtStore.of(f.appModel.thumbnailsDirectory);
    await tester.runAsync(
      () => store.write(
        record: const BookArtRecord(
          bookKey: _bookKey,
          source: 'mangabaka',
          seriesId: '1',
          seriesTitle: 'FUTARI BUS',
          scrapedAt: 1,
        ),
        coverBytes: _png(90),
      ),
    );
    final String scrapedPath = store.coverPathFor(_bookKey);
    // 书架卡走的那条链（刮削层）确实拿到了这张图——作品页必须与它一致。
    expect(
      ReaderFushiSource.instance
          .scrapedThumbnailFile(
            appModel: f.appModel,
            item: ReaderFushiSource.instance.overrideTitleMediaItemForBookKey(
              _bookKey,
            ),
          )
          ?.path,
      scrapedPath,
    );

    await tester.pumpWidget(_harness(f));
    await _settle(tester);

    final MediaPosterDetailHero hero = _heroOrNull(tester)!;
    expect(_filePathOf(hero.posterImage), scrapedPath);
    expect(_filePathOf(hero.backdropFallback), scrapedPath);
    expect(_posterFilePath(tester), scrapedPath);
  });

  testWidgets('用户 override 封面优先于刮削封面（与书架卡同一优先级）', (WidgetTester tester) async {
    final _Fixture f = await _setUp(tester);
    final BookArtStore store = BookArtStore.of(f.appModel.thumbnailsDirectory);
    await tester.runAsync(
      () => store.write(
        record: const BookArtRecord(
          bookKey: _bookKey,
          source: 'mangabaka',
          seriesId: '1',
          seriesTitle: 'FUTARI BUS',
          scrapedAt: 1,
        ),
        coverBytes: _png(90),
      ),
    );
    final String overridePath = ReaderFushiSource.instance
        .getOverrideThumbnailFilename(
          appModel: f.appModel,
          item: ReaderFushiSource.instance.overrideTitleMediaItemForBookKey(
            _bookKey,
          ),
        );
    File(overridePath).writeAsBytesSync(_png(200));

    await tester.pumpWidget(_harness(f));
    await _settle(tester);

    final MediaPosterDetailHero hero = _heroOrNull(tester)!;
    expect(_filePathOf(hero.posterImage), overridePath);
    expect(_posterFilePath(tester), overridePath);
  });
}
