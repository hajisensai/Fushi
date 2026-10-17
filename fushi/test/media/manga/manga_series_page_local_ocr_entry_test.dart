import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/manga/library/manga_series_page.dart';
import 'package:fushi/src/media/manga/manga_ocr_background_job.dart';
import 'package:fushi/src/media/manga/manga_ocr_provider.dart';
import 'package:fushi/src/media/manga/manga_ocr_wizard_engines.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_engine.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_job_registry.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi_audio/fushi_audio.dart' show ReaderPositionRepository;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/ocr/manga_ocr_service.dart';
import 'package:path/path.dart' as p;

import '../../helpers/test_platform_services.dart';

/// 本地漫画作品页（用户 2026-10-14：「本地卷相比在线卷缺好多设置」「ocr 按钮也
/// 少了」）：识别本卷入口 + 进度横幅、卷信息里的阅读进度、「管理本卷」打开书架
/// 同一个菜单，以及库里行没了时作品页自己退出。
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

  @override
  String get mangaOcrEnginePreference => MangaOcrEnginePreference.localOnnx.key;
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

/// 记下 `enqueue`，真正排进去的任务换成一条永不结束的事件流：横幅要能看到
/// 「正在识别」这一态。
class _RecordingRegistry extends MangaOcrJobRegistry {
  final List<String> directories = <String>[];

  /// 不关闭：任务一直处在「识别中」。
  final StreamController<MangaOcrBackgroundEvent> _events =
      StreamController<MangaOcrBackgroundEvent>.broadcast();

  @override
  Future<MangaOcrRunningJob?> enqueue({
    required MangaOcrBackgroundJob job,
    required String mangaJsonPath,
  }) {
    directories.add(job.managedDirectory);
    return super.enqueue(
      job: MangaOcrBackgroundJob(
        bookKey: job.bookKey,
        managedDirectory: job.managedDirectory,
        engine: job.engine,
        events: _events.stream,
      ),
      mangaJsonPath: mangaJsonPath,
    );
  }
}

const String _bookKey = 'local ocr entry book';
const String _bookUid = 'local-ocr-entry-uid';

class _Fixture {
  _Fixture(this.db, this.appModel, this.bookDir, this.registry);

  final FushiDatabase db;
  final _TestAppModel appModel;
  final Directory bookDir;
  final _RecordingRegistry registry;
}

Future<_Fixture> _setUp(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1200, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  final Directory root = Directory.systemTemp.createTempSync(
    'manga_series_local_root_',
  );
  final Directory bookDir = Directory.systemTemp.createTempSync(
    'manga_series_ocr_entry_',
  );
  addTearDown(() {
    for (final Directory dir in <Directory>[root, bookDir]) {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    }
  });
  File(p.join(bookDir.path, 'manga.json')).writeAsStringSync(
    jsonEncode(<String, Object?>{
      'pages': <Map<String, Object?>>[
        for (int i = 1; i <= 10; i++)
          <String, Object?>{
            'url': 'images/p$i.jpg',
            'width': 100,
            'height': 150,
            'blocks': <Object?>[],
          },
      ],
    }),
  );
  Directory(p.join(bookDir.path, 'images')).createSync();
  for (int i = 1; i <= 10; i++) {
    File(p.join(bookDir.path, 'images', 'p$i.jpg')).writeAsBytesSync(<int>[1]);
  }
  await tester.runAsync(() async {
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: _bookKey,
        title: _bookKey,
        epubPath: 'manga.json',
        extractDir: bookDir.path,
        chapterCount: 10,
        chaptersJson: '[]',
        importedAt: DateTime.now().millisecondsSinceEpoch,
        format: const Value<String>('manga'),
        uid: const Value<String>(_bookUid),
      ),
    );
  });
  return _Fixture(db, _TestAppModel(db, root), bookDir, _RecordingRegistry());
}

/// 作品页压在一个根页上（「退出」要有地方退）。
Widget _harness(_Fixture f, {Future<void> Function()? showShelfMenu}) {
  return ProviderScope(
    overrides: <Override>[
      platformServicesProvider.overrideWithValue(testPlatformServices()),
      appProvider.overrideWith((ref) => f.appModel),
      mangaOcrJobRegistryProvider.overrideWithValue(f.registry),
    ],
    child: TranslationProvider(
      child: MaterialApp(
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: Center(
              child: TextButton(
                key: const ValueKey<String>('open_series'),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => MangaSeriesPage(
                      target: ShelfMangaSeriesTarget(
                        _bookKey,
                        showShelfMenu: showShelfMenu,
                      ),
                      ocrEnginesOverride: MangaOcrWizardEngines(
                        service: _FakeOcrService(),
                        initialEnginePreference: 'local_onnx',
                        initialLensLanguage: 'ja',
                        lensLanguageSetter: (_) async {},
                      ),
                    ),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// 真异步（DB / 文件 / 引擎探测）只能在 runAsync 里推进；轮询到 [until] 成立。
Future<void> _settle(WidgetTester tester, bool Function() until) async {
  await tester.runAsync(() async {
    for (int i = 0; i < 60 && !until(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
    }
  });
  await tester.pump();
}

Future<void> _openSeries(WidgetTester tester, _Fixture f) async {
  await tester.tap(find.byKey(const ValueKey<String>('open_series')));
  await _settle(
    tester,
    () => find
        .byKey(const ValueKey<String>('manga_series_open_local'))
        .evaluate()
        .isNotEmpty,
  );
}

void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  testWidgets('本地卷有「识别本卷」：排进注册表、横幅接管、按钮置灰', (WidgetTester tester) async {
    final _Fixture f = await _setUp(tester);
    await tester.pumpWidget(_harness(f));
    await _openSeries(tester, f);

    expect(
      find.byKey(const ValueKey<String>('manga_series_ocr_settings')),
      findsOneWidget,
    );
    final Finder ocrButton = find.byKey(
      const ValueKey<String>('manga_series_ocr_volume'),
    );
    expect(ocrButton, findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('manga_series_ocr_banner')),
      findsNothing,
    );

    await tester.tap(ocrButton);
    await _settle(tester, () => f.registry.directories.isNotEmpty);

    expect(f.registry.directories, <String>[
      f.bookDir.path,
    ], reason: '本地卷整卷一个任务，目录就是 extractDir（与阅读器自动识别同一约定）');
    await _settle(
      tester,
      () => find
          .byKey(const ValueKey<String>('manga_series_ocr_banner'))
          .evaluate()
          .isNotEmpty,
    );
    expect(
      find.byKey(const ValueKey<String>('manga_series_ocr_banner')),
      findsOneWidget,
      reason: '本地卷也要看得到识别进度与取消',
    );

    // 在跑时按钮置灰：再点不会重复排。
    await tester.tap(ocrButton, warnIfMissed: false);
    await _settle(tester, () => false);
    expect(f.registry.directories, hasLength(1));

    await tester.runAsync(() => f.registry.cancel(_bookKey));
    await tester.pump();
  });

  testWidgets('卷信息显示阅读进度；没打开过就不显示', (WidgetTester tester) async {
    final _Fixture f = await _setUp(tester);
    await tester.pumpWidget(_harness(f));
    await _openSeries(tester, f);
    final Finder progress = find.byKey(
      const ValueKey<String>('manga_series_local_progress'),
    );
    expect(progress, findsNothing);

    // 阅读器写位置 → 作品页跟着库的写入通知刷新，不用重进。
    await tester.runAsync(
      () => ReaderPositionRepository(f.db).save(
        bookUid: _bookUid,
        sectionIndex: 3,
        normCharOffset: 0,
        charOffset: 0,
      ),
    );
    await _settle(tester, () => progress.evaluate().isNotEmpty);
    expect(progress, findsOneWidget);
    expect(
      find.text(t.manga_series_read_progress(page: '4', total: '10')),
      findsOneWidget,
    );
  });

  testWidgets('「管理本卷」打开书架同一个菜单；没有入口时不露这一项', (WidgetTester tester) async {
    final _Fixture f = await _setUp(tester);
    int opened = 0;
    await tester.pumpWidget(
      _harness(
        f,
        showShelfMenu: () async {
          opened += 1;
        },
      ),
    );
    await _openSeries(tester, f);
    final Finder manage = find.byKey(
      const ValueKey<String>('manga_series_manage_volume'),
    );
    expect(manage, findsOneWidget);
    await tester.tap(manage);
    await tester.pump();
    expect(opened, 1);
  });

  testWidgets('没有书架菜单入口（书架以外的来路）时不露「管理本卷」', (WidgetTester tester) async {
    final _Fixture f = await _setUp(tester);
    await tester.pumpWidget(_harness(f));
    await _openSeries(tester, f);
    expect(
      find.byKey(const ValueKey<String>('manga_series_manage_volume')),
      findsNothing,
    );
  });

  testWidgets('书在库里被删掉后作品页自己退出（菜单动作晚于菜单关闭落库）', (WidgetTester tester) async {
    final _Fixture f = await _setUp(tester);
    await tester.pumpWidget(_harness(f));
    await _openSeries(tester, f);
    final Finder page = find.byType(MangaSeriesPage);
    expect(page, findsOneWidget);

    await tester.runAsync(() => f.db.deleteEpubBook(_bookKey));
    await _settle(tester, () => page.evaluate().isEmpty);
    await tester.pumpAndSettle();
    expect(page, findsNothing);
    expect(find.byKey(const ValueKey<String>('open_series')), findsOneWidget);
  });
}
