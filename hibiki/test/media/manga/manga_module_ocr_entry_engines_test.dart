/// BUG-1418：OCR 向导两个入口的**引擎依赖集**必须同构。
///
/// 阅读器对已入库漫画跑整卷 OCR 走 [MangaModule.openBookOcr]；它此前自己手抄了
/// 一份向导构造参数表，抄漏了 `remoteRunner`，于是 `pairedHost` 引擎的 `supported`
/// 恒 false ——「配对主机」选项在阅读器入口**永不出现**。安卓没有本地 ONNX 引擎、
/// 也没有外部 mokuro CLI，这条洞让它只剩 Google Lens。
///
/// 修复方式不是补一个参数，而是把整套引擎依赖收成 [MangaOcrWizardEngines]（向导
/// 的必填参数，漏传编译不过）并只在 [MangaOcrWizardEngines.resolve] 装配一次，
/// 两个入口共用。本测试同时钉死：
/// - ① 阅读器入口在有可用 host 时「配对主机」选项**出现**；
/// - ② 无 host 时仍出现但不可用（保留持久化选择且不可触发）；
/// - ③ 导入向导入口拿到的依赖集与阅读器入口同构、不回归；
/// - ④ `externalRunner` 的 desktop 三元是**有意**差异，不许被一并抹平。
library;

import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/manga/manga_module.dart';
import 'package:fushi/src/media/manga/manga_ocr_provider.dart';
import 'package:fushi/src/media/manga/manga_ocr_wizard_dialog.dart';
import 'package:fushi/src/media/manga/manga_ocr_wizard_engines.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_engine.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/ocr/manga_ocr_service.dart';
import 'package:fushi/src/sync/interconnect_manga_ocr_client.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

import '../../helpers/test_platform_services.dart';

/// 移动端形态的内置服务：平台不支持（安卓真相，`pairedHost` 是关键补位引擎）。
class _UnsupportedOcrService implements MangaOcrService {
  @override
  bool get isSupportedPlatform => false;

  @override
  Future<MangaOcrModelStatus> modelStatus() async => const MangaOcrModelStatus(
        detectorReady: false,
        recognizerReady: false,
        downloadedBytes: 0,
        totalBytes: 1,
      );

  @override
  Stream<MangaOcrDownloadEvent> downloadModels() =>
      const Stream<MangaOcrDownloadEvent>.empty();

  @override
  Future<void> deleteModels() async {}

  @override
  Stream<MangaOcrVolumeEvent> ocrFolder({
    required String imageDirPath,
    String? volumeTitle,
  }) =>
      const Stream<MangaOcrVolumeEvent>.empty();
}

class _FakeRemoteRunner implements MangaOcrRemoteRunner {
  _FakeRemoteRunner({this.target});

  final MangaOcrRemoteTarget? target;

  @override
  Future<MangaOcrRemoteTarget?> probe() async => target;

  @override
  Stream<MangaOcrRemoteEvent> run({
    required MangaOcrRemoteTarget target,
    required String imageDirPath,
    String? volumeTitle,
  }) =>
      const Stream<MangaOcrRemoteEvent>.empty();
}

const MangaOcrRemoteTarget _capableTarget = MangaOcrRemoteTarget(
  baseUrl: 'http://192.168.1.2:1234',
  capability: MangaOcrRemoteCapability(supported: true, modelsReady: true),
);

void main() {
  late HibikiDatabase db;
  late Directory imageDir;
  late Directory tmpDir;
  late AppModel appModel;
  final _UnsupportedOcrService service = _UnsupportedOcrService();

  setUp(() async {
    db = HibikiDatabase.forTesting(NativeDatabase.memory());
    imageDir = Directory.systemTemp.createTempSync('manga_module_ocr_entry');
    File(p.join(imageDir.path, 'p001.jpg')).writeAsBytesSync(<int>[1, 2, 3]);
    tmpDir = Directory.systemTemp.createTempSync('manga_module_ocr_entry_db');
    final PreferencesRepository prefsRepo = PreferencesRepository(db);
    await prefsRepo.loadFromDb();
    appModel = AppModel(testPlatformServices())
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(
        prefsRepo: prefsRepo,
        databaseDirectory: tmpDir,
      );
  });

  tearDown(() async {
    await db.close();
    if (imageDir.existsSync()) imageDir.deleteSync(recursive: true);
    if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
  });

  Future<EpubBookRow> seedMangaBook() async {
    await db.into(db.epubBooks).insert(
          EpubBooksCompanion.insert(
            bookKey: 'manga1',
            title: '巻一',
            epubPath: p.join(imageDir.path, 'manga.json'),
            extractDir: imageDir.path,
            chapterCount: 1,
            chaptersJson: '[]',
            importedAt: 1700000000000,
            format: const Value<String>('manga'),
          ),
        );
    return (await db.getEpubBook('manga1'))!;
  }

  /// 挂一个按钮驱动入口，回传「点开入口」的动作。
  Future<void> pumpHost(
    WidgetTester tester,
    Future<void> Function(BuildContext context) open,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          appProvider.overrideWith((Ref ref) => appModel),
          mangaOcrServiceProvider.overrideWithValue(service),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (BuildContext ctx) => ElevatedButton(
                  onPressed: () => open(ctx),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  MangaOcrWizardEngines mountedEngines(WidgetTester tester) => tester
      .widget<MangaOcrWizardDialog>(
        find.byType(MangaOcrWizardDialog),
      )
      .engines;

  testWidgets('① 阅读器入口（openBookOcr）：有可用 host 时「配对主机」选项出现',
      (WidgetTester tester) async {
    final EpubBookRow book = await seedMangaBook();
    final _FakeRemoteRunner remote = _FakeRemoteRunner(target: _capableTarget);
    await pumpHost(tester, (BuildContext ctx) async {
      await MangaModule.openBookOcr(
        context: ctx,
        db: db,
        book: book,
        startPage: 3,
        remoteRunnerOverride: remote,
        desktopOverride: false,
      );
    });

    // 依赖真的到了向导手上（不是被入口吞掉）。
    expect(mountedEngines(tester).remoteRunner, same(remote));
    // 用户可见结果：引擎分段里出现「配对主机」。
    expect(
      find.text(t.manga_remote_ocr_engine),
      findsOneWidget,
      reason: '阅读器入口漏传 remoteRunner 时这条恒 findsNothing（BUG-1418）',
    );
  });

  testWidgets('② 阅读器入口：无可用 host 时「配对主机」保留但禁用', (WidgetTester tester) async {
    final EpubBookRow book = await seedMangaBook();
    final _FakeRemoteRunner remote = _FakeRemoteRunner(target: null);
    await pumpHost(tester, (BuildContext ctx) async {
      await MangaModule.openBookOcr(
        context: ctx,
        db: db,
        book: book,
        startPage: 0,
        remoteRunnerOverride: remote,
        desktopOverride: false,
      );
    });

    expect(find.text(t.manga_remote_ocr_engine), findsOneWidget);
    final SegmentedButton<MangaOcrEngineId> selector =
        tester.widget<SegmentedButton<MangaOcrEngineId>>(
      find.byType(SegmentedButton<MangaOcrEngineId>),
    );
    final ButtonSegment<MangaOcrEngineId> remoteSegment = selector.segments
        .singleWhere((ButtonSegment<MangaOcrEngineId> segment) =>
            segment.value == MangaOcrEngineId.pairedHost);
    expect(remoteSegment.enabled, isFalse,
        reason: '无可用 host 时保留分段以承载持久化选择，但必须不可触发');
    // runner 仍在，只是 probe 没有找到可用 host。
    expect(mountedEngines(tester).remoteRunner, same(remote));
    // Lens 全平台可用，引擎区不该退化成「无可用引擎」。
    expect(find.text(t.manga_ocr_engine_none), findsNothing);
  });

  testWidgets('③ 导入向导入口（openOcrImportWizard）：依赖集与阅读器入口同构',
      (WidgetTester tester) async {
    final _FakeRemoteRunner remote = _FakeRemoteRunner(target: _capableTarget);
    await pumpHost(tester, (BuildContext ctx) async {
      await MangaModule.openOcrImportWizard(
        context: ctx,
        db: db,
        remoteRunnerOverride: remote,
        desktopOverride: false,
      );
    });

    final MangaOcrWizardEngines engines = mountedEngines(tester);
    expect(engines.remoteRunner, same(remote));
    expect(engines.lensRunner, isNotNull, reason: 'Lens 是移动端唯一本地可用引擎');
    expect(engines.service, same(service));
    expect(engines.initialEnginePreference, appModel.mangaOcrEnginePreference);
  });

  testWidgets('④a externalRunner 的 desktop 三元是有意差异：非桌面无外部 CLI',
      (WidgetTester tester) async {
    final EpubBookRow book = await seedMangaBook();
    final _FakeRemoteRunner remote = _FakeRemoteRunner(target: _capableTarget);
    await pumpHost(tester, (BuildContext ctx) async {
      await MangaModule.openBookOcr(
        context: ctx,
        db: db,
        book: book,
        startPage: 0,
        remoteRunnerOverride: remote,
        desktopOverride: false,
      );
    });
    expect(mountedEngines(tester).externalRunner, isNull,
        reason: '非桌面没有外部 mokuro CLI');
  });

  testWidgets('④b externalRunner 的 desktop 三元是有意差异：桌面仍提供外部 CLI',
      (WidgetTester tester) async {
    final _FakeRemoteRunner remote = _FakeRemoteRunner(target: _capableTarget);
    await pumpHost(tester, (BuildContext ctx) async {
      await MangaModule.openOcrImportWizard(
        context: ctx,
        db: db,
        remoteRunnerOverride: remote,
        desktopOverride: true,
      );
    });
    expect(mountedEngines(tester).externalRunner, isNotNull,
        reason: '桌面必须仍提供外部 mokuro CLI 后备');
  });
}
