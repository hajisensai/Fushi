import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/manga_ocr_provider.dart';
import 'package:fushi/src/media/manga/manga_ocr_settings_section.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_engine.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_local_model_labels.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_model_downloads.dart';
import 'package:fushi/src/media/manga/ocr/system_ocr_manga_service.dart';
import 'package:fushi/src/ocr/manga_ocr_model_import.dart';
import 'package:fushi/src/sync/interconnect_manga_ocr_client.dart';
import 'package:fushi_engine/ocr/manga_ocr_local_model.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi_engine/ocr/manga_ocr_service.dart';
import 'package:fushi/utils.dart';
import '../../helpers/glass_unwrap.dart';

/// Fake 服务，模型状态与下载流可编程。
class _FakeOcrService implements MangaOcrService {
  _FakeOcrService({
    this.supported = true,
    this.ready = false,
    this.diskBytesOverride,
    this.obtainedBytesOverride,
    this.downloadEvents,
    this.acceleratorMissingBytes = 0,
  });

  final bool supported;
  bool ready;

  /// 提速组件还差的字节数；下载流跑完即清零（与真实服务「一次下齐」同形）。
  int acceleratorMissingBytes;
  int downloadCalls = 0;

  /// 磁盘占用与「清单是否齐全」解耦：残留 `.part`/遗留档就是「不 ready 但占着
  /// 磁盘」，这正是引擎用不到时仍须可删的那一档。
  final int? diskBytesOverride;

  /// 已拿到手的字节数（就绪档 + `.part` 残留），驱动「继续下载」文案。
  final int? obtainedBytesOverride;

  /// 自定义下载事件源（不给则走默认单文件两条）。
  ///
  /// 用 controller 而不是事件列表：进度断言要看的是**下载进行中**的中间态，流一
  /// 旦自然结束，UI 立刻收起进度条，那一帧就抓不到了。
  final StreamController<MangaOcrDownloadEvent>? downloadEvents;

  int deleteCalls = 0;

  @override
  bool get isSupportedPlatform => supported;

  @override
  Future<MangaOcrModelStatus> modelStatus() async => MangaOcrModelStatus(
        detectorReady: ready,
        recognizerReady: ready,
        diskBytes: diskBytesOverride ?? (ready ? 40 * 1024 * 1024 : 0),
        totalBytes: 40 * 1024 * 1024,
        obtainedBytes:
            obtainedBytesOverride ?? (ready ? 40 * 1024 * 1024 : 0),
        acceleratorMissingBytes: acceleratorMissingBytes,
      );

  @override
  Stream<MangaOcrDownloadEvent> downloadModels() async* {
    downloadCalls++;
    acceleratorMissingBytes = 0;
    final StreamController<MangaOcrDownloadEvent>? scripted = downloadEvents;
    if (scripted != null) {
      yield* scripted.stream;
      ready = true;
      return;
    }
    yield const MangaOcrDownloadEvent(
      fileName: 'detector.onnx',
      receivedBytes: 10,
      totalBytes: 20,
    );
    ready = true;
    yield const MangaOcrDownloadEvent(
      fileName: 'detector.onnx',
      receivedBytes: 20,
      totalBytes: 20,
      done: true,
    );
  }

  @override
  Future<int> deleteModels() async {
    deleteCalls++;
    ready = false;
    return 40 * 1024 * 1024;
  }

  @override
  Stream<MangaOcrVolumeEvent> ocrFolder({
    required String imageDirPath,
    String? volumeTitle,
    int startPage = 0,
  }) =>
      const Stream<MangaOcrVolumeEvent>.empty();
}

/// 记录调用的导入器：UI 测试只关心「入口接线对不对」，真实拷贝/解压逻辑由
/// `test/ocr/manga_ocr_model_import_test.dart` 单独盯。
class _FakeImporter extends MangaOcrModelImporter {
  _FakeImporter(this.result, {this.beforeReturn});

  final MangaOcrModelImportResult result;
  final Future<void> Function()? beforeReturn;
  final List<List<String>> calls = <List<String>>[];

  @override
  Future<MangaOcrModelImportResult> import({
    required List<String> sourcePaths,
    required Directory targetDir,
  }) async {
    calls.add(sourcePaths);
    await beforeReturn?.call();
    return result;
  }
}

/// 系统 OCR 可用性桩：设置区据此决定「设备自带」那项灰不灰。
class _FakeSystemOcr implements SystemOcrMangaRunner {
  _FakeSystemOcr(this.available);

  final bool available;

  @override
  Future<bool> isAvailable() async => available;

  @override
  Stream<MangaOcrVolumeEvent> ocrFolder({
    required String imageDirPath,
    String? volumeTitle,
    int startPage = 0,
    bool onlyMissing = true,
    required String language,
    MangaOcrPageFocus? focus,
  }) =>
      const Stream<MangaOcrVolumeEvent>.empty();

  @override
  Future<MokuroImage> recognizePageBytes(
    Uint8List bytes, {
    required String relativeUrl,
    required String language,
  }) =>
      throw UnimplementedError();
}

/// 已配对服务端的假探测：报一张模型表（或离线时什么都不报）。
class _FakeRemoteRunner implements MangaOcrRemoteRunner {
  _FakeRemoteRunner(this.models);

  /// null = 服务端离线（探测不到）。
  final List<MangaOcrRemoteModel>? models;

  @override
  Future<MangaOcrRemoteTarget?> probe() async {
    final List<MangaOcrRemoteModel>? reported = models;
    if (reported == null) return null;
    return MangaOcrRemoteTarget(
      baseUrl: 'http://127.0.0.1:1',
      capability: MangaOcrRemoteCapability(
        supported: true,
        modelsReady: true,
        models: reported,
      ),
    );
  }

  @override
  Stream<MangaOcrRemoteEvent> run({
    required MangaOcrRemoteTarget target,
    required String imageDirPath,
    String? volumeTitle,
  }) => throw UnimplementedError();
}

/// 测试宿主统一开「减少动态效果」：波浪进度 / 加载指示器停成静止形态。
Widget _reduceMotion(BuildContext context, Widget? child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: true),
      child: child!,
    );

void main() {
  Widget wrap(Widget child) {
    return ProviderScope(
      child: TranslationProvider(
        child: MaterialApp(
            // MD3 Expressive 波浪进度在下载中（不定态 / 0<value<1）持续推相位，
            // pumpAndSettle 永远等不到静止；「减少动态效果」下退回静止直线，
            // 下载行为不受影响。
            builder: _reduceMotion,
            home: Scaffold(body: SingleChildScrollView(child: child))),
      ),
    );
  }

  testWidgets('shows missing status + download button when models not ready',
      (WidgetTester tester) async {
    final _FakeOcrService service = _FakeOcrService(ready: false);
    await tester.pumpWidget(wrap(MangaOcrSettingsSection(
      service: service,
      mokuroPathGetter: () => '',
      mokuroPathSetter: (String _) async {},
      probeExternal: (String _) async => null,
      // 这条测的是「引擎用得到本地模型」时的完整块，必须把这个前提**显式**写出来。
      // 以前它靠 `_readEnginePreference()` 的回退值隐式拿到 `auto`，而生产出厂默认
      // 是 `google_lens`——测试因此长期在跑一条用户碰不到的分支（BUG-1780）。
      enginePreferenceGetter: () => 'auto',
    )));
    await tester.pumpAndSettle();

    expect(find.text(t.manga_ocr_model_status_missing), findsOneWidget);
    expect(find.widgetWithText(FilledButton, t.manga_ocr_download),
        findsOneWidget);
  });

  testWidgets('ready model without the speed-up pack offers to download it',
      (WidgetTester tester) async {
    final _FakeOcrService service = _FakeOcrService(
      ready: true,
      acceleratorMissingBytes: 94 * 1024 * 1024,
    );
    await tester.pumpWidget(wrap(MangaOcrSettingsSection(
      service: service,
      mokuroPathGetter: () => '',
      mokuroPathSetter: (String _) async {},
      probeExternal: (String _) async => null,
      enginePreferenceGetter: () => 'auto',
    )));
    await tester.pumpAndSettle();

    final Finder button =
        find.byKey(const ValueKey<String>('manga_ocr_accelerator_download'));
    expect(find.text(t.manga_ocr_model_status_ready), findsOneWidget);
    expect(button, findsOneWidget);
    expect(find.text(t.manga_ocr_accelerator_desc), findsOneWidget);

    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();

    expect(service.downloadCalls, 1);
    expect(button, findsNothing, reason: '下齐之后不再提示');
    expect(find.text(t.manga_ocr_accelerator_desc), findsNothing);
  });

  testWidgets('speed-up pack prompt is absent when nothing is missing',
      (WidgetTester tester) async {
    await tester.pumpWidget(wrap(MangaOcrSettingsSection(
      service: _FakeOcrService(ready: true),
      mokuroPathGetter: () => '',
      mokuroPathSetter: (String _) async {},
      probeExternal: (String _) async => null,
      enginePreferenceGetter: () => 'auto',
    )));
    await tester.pumpAndSettle();

    expect(find.text(t.manga_ocr_model_status_ready), findsOneWidget);
    expect(
        find.byKey(const ValueKey<String>('manga_ocr_accelerator_download')),
        findsNothing);
    expect(find.text(t.manga_ocr_accelerator_desc), findsNothing);
  });

  testWidgets('lens language dropdown persists the chosen language',
      (WidgetTester tester) async {
    final _FakeOcrService service = _FakeOcrService(ready: true);
    String stored = 'ja';
    await tester.pumpWidget(wrap(MangaOcrSettingsSection(
      service: service,
      mokuroPathGetter: () => '',
      mokuroPathSetter: (String _) async {},
      probeExternal: (String _) async => null,
      lensLanguageGetter: () => stored,
      lensLanguageSetter: (String value) async => stored = value,
    )));
    await tester.pumpAndSettle();

    expect(find.text(t.manga_ocr_lens_language_label), findsOneWidget);
    await tester
        .tap(find.byKey(const ValueKey<String>('manga_ocr_lens_language')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('English').last);
    await tester.pumpAndSettle();
    expect(stored, 'en');
  });

  testWidgets('lens language dropdown is absent without a language setter',
      (WidgetTester tester) async {
    final _FakeOcrService service = _FakeOcrService(ready: true);
    await tester.pumpWidget(wrap(MangaOcrSettingsSection(
      service: service,
      mokuroPathGetter: () => '',
      mokuroPathSetter: (String _) async {},
      probeExternal: (String _) async => null,
    )));
    await tester.pumpAndSettle();
    expect(find.text(t.manga_ocr_lens_language_label), findsNothing);
  });

  testWidgets('parallel tasks persists four and automatic across reopening',
      (WidgetTester tester) async {
    final _FakeOcrService service = _FakeOcrService(ready: true);
    int stored = 0;
    Widget settings() => wrap(MangaOcrSettingsSection(
          service: service,
          mokuroPathGetter: () => '',
          mokuroPathSetter: (String _) async {},
          probeExternal: (String _) async => null,
          parallelTasksGetter: () => stored,
          parallelTasksSetter: (int value) async => stored = value,
        ));
    final Finder field =
        find.byKey(const ValueKey<String>('manga_ocr_parallel_tasks'));
    final Finder dropdown =
        find.descendant(of: field, matching: find.byType(DropdownButton<int>));

    await tester.pumpWidget(settings());
    await tester.pumpAndSettle();
    expect(tester.widget<DropdownButton<int>>(glassUnwrap<DropdownButton<int>>(dropdown)).value, 0);
    await tester.ensureVisible(field);
    await tester.tap(field);
    await tester.pumpAndSettle();
    await tester.tap(find.text('4').last);
    await tester.pumpAndSettle();
    expect(stored, 4);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(settings());
    await tester.pumpAndSettle();
    expect(tester.widget<DropdownButton<int>>(glassUnwrap<DropdownButton<int>>(dropdown)).value, 4);
    await tester.ensureVisible(field);
    await tester.tap(field);
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.manga_ocr_parallel_auto).last);
    await tester.pumpAndSettle();
    expect(stored, 0);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(settings());
    await tester.pumpAndSettle();
    expect(tester.widget<DropdownButton<int>>(glassUnwrap<DropdownButton<int>>(dropdown)).value, 0);
  });

  String engineLabel(MangaOcrLocalModel model) =>
      t.manga_ocr_engine_local_model(model: localModelLabel(model));

  /// 打开引擎下拉并点选某一项（菜单里同一文字可能在闭合态与菜单各一份，取最后）。
  Future<void> pickEngine(WidgetTester tester, String label) async {
    final Finder field =
        find.byKey(const ValueKey<String>('manga_ocr_default_engine'));
    await tester.ensureVisible(field);
    await tester.tap(field);
    await tester.pumpAndSettle();
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  testWidgets('local models are engine choices; no separate model dropdown',
      (WidgetTester tester) async {
    String storedModel = 'manga_ocr';
    String storedEngine = 'auto';
    await tester.pumpWidget(wrap(MangaOcrSettingsSection(
      service: _FakeOcrService(ready: true),
      mokuroPathGetter: () => '',
      mokuroPathSetter: (String _) async {},
      probeExternal: (String _) async => null,
      enginePreferenceGetter: () => storedEngine,
      enginePreferenceSetter: (String value) async => storedEngine = value,
      localModelGetter: () => storedModel,
      localModelSetter: (String value) async => storedModel = value,
    )));
    await tester.pumpAndSettle();
    // 以前「默认 OCR 引擎」下面还有一个「本机 OCR 模型」下拉，两者说的是同一件事。
    expect(find.byKey(const ValueKey<String>('manga_ocr_local_model')),
        findsNothing);
    expect(find.text(t.manga_ocr_local_model), findsNothing);

    final Finder field =
        find.byKey(const ValueKey<String>('manga_ocr_default_engine'));
    await tester.ensureVisible(field);
    await tester.tap(field);
    await tester.pumpAndSettle();
    // Baberu 只在 Windows 列出；CTC 与经典 manga-ocr 五端都有。
    expect(find.text(engineLabel(MangaOcrLocalModel.mangaOcr)), findsWidgets);
    expect(find.text(engineLabel(MangaOcrLocalModel.mangaCtc)), findsWidgets);
    expect(find.text(engineLabel(MangaOcrLocalModel.baberu)),
        Platform.isWindows ? findsWidgets : findsNothing);
    // 单一的「本地 ONNX」项已被逐模型项取代。
    expect(find.text(t.manga_ocr_engine_local_onnx), findsNothing);
    await tester.tap(find.text(engineLabel(MangaOcrLocalModel.mangaCtc)).last);
    await tester.pumpAndSettle();
    expect(storedModel, 'manga_ctc');
    expect(storedEngine, 'local_onnx');
    // 状态行说清楚是哪个模型。
    expect(find.textContaining(t.manga_ocr_ctc_model), findsWidgets);
  });

  testWidgets('choosing a local model engine persists across reopening',
      (WidgetTester tester) async {
    String storedModel = 'manga_ocr';
    String storedEngine = 'google_lens';
    Widget settings() => wrap(MangaOcrSettingsSection(
          service: _FakeOcrService(ready: true),
          mokuroPathGetter: () => '',
          mokuroPathSetter: (String _) async {},
          probeExternal: (String _) async => null,
          enginePreferenceGetter: () => storedEngine,
          enginePreferenceSetter: (String value) async => storedEngine = value,
          localModelGetter: () => storedModel,
          localModelSetter: (String value) async => storedModel = value,
        ));
    final MangaOcrLocalModel target = Platform.isWindows
        ? MangaOcrLocalModel.baberu
        : MangaOcrLocalModel.mangaCtc;
    await tester.pumpWidget(settings());
    await tester.pumpAndSettle();
    await pickEngine(tester, engineLabel(target));
    expect(storedModel, target.key);
    expect(storedEngine, 'local_onnx');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(settings());
    await tester.pumpAndSettle();
    // 闭合态只显示选中项的标签。
    expect(find.text(engineLabel(target)), findsOneWidget);

    // 换回云端引擎不改本机模型偏好（自动模式下仍用它兜底）。
    await pickEngine(tester, t.manga_ocr_engine_google_lens);
    expect(storedEngine, 'google_lens');
    expect(storedModel, target.key);
  });

  testWidgets('model download keeps running after the page is closed',
      (WidgetTester tester) async {
    final StreamController<MangaOcrDownloadEvent> events =
        StreamController<MangaOcrDownloadEvent>();
    addTearDown(() {
      if (!events.isClosed) unawaited(events.close());
    });
    final _FakeOcrService service = _FakeOcrService(downloadEvents: events);
    final ProviderContainer container = ProviderContainer();
    addTearDown(container.dispose);
    final ValueNotifier<bool> showPage = ValueNotifier<bool>(true);
    addTearDown(showPage.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: TranslationProvider(
        child: MaterialApp(
          builder: _reduceMotion,
          home: Scaffold(
            body: SingleChildScrollView(
              child: ValueListenableBuilder<bool>(
                valueListenable: showPage,
                builder: (BuildContext context, bool show, Widget? _) => show
                    ? MangaOcrSettingsSection(
                        service: service,
                        mokuroPathGetter: () => '',
                        mokuroPathSetter: (String _) async {},
                        probeExternal: (String _) async => null,
                        enginePreferenceGetter: () => 'auto',
                      )
                    : const SizedBox.shrink(),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    final Finder download =
        find.widgetWithText(FilledButton, t.manga_ocr_download);
    await tester.ensureVisible(download);
    await tester.tap(download);
    await tester.pump();
    expect(find.text(t.manga_ocr_download_background_hint), findsOneWidget);

    // 关掉页面：以前 State.dispose 会取消订阅，几百 MB 白下。
    showPage.value = false;
    await tester.pump();
    expect(find.byType(MangaOcrSettingsSection), findsNothing);
    final MangaOcrModelDownloads downloads =
        container.read(mangaOcrModelDownloadsProvider);
    expect(downloads.isActive(MangaOcrLocalModel.mangaOcr), isTrue);
    expect(events.hasListener, isTrue);
    events.add(const MangaOcrDownloadEvent(
      fileName: 'detector.onnx',
      receivedBytes: 1024,
      totalBytes: 2048,
    ));
    await tester.pump();
    expect(downloads.progressOf(MangaOcrLocalModel.mangaOcr)?.receivedBytes,
        1024);

    // 重新打开页面：接回同一条下载的进度。
    showPage.value = true;
    await tester.pumpAndSettle();
    expect(find.text(t.manga_ocr_downloading_file(file: 'detector.onnx')),
        findsOneWidget);

    await events.close();
    await tester.pumpAndSettle();
    expect(downloads.isActive(MangaOcrLocalModel.mangaOcr), isFalse);
    expect(find.text(t.manga_ocr_model_status_ready), findsOneWidget);
  });

  testWidgets('switching engine during a download does not cancel it',
      (WidgetTester tester) async {
    final StreamController<MangaOcrDownloadEvent> events =
        StreamController<MangaOcrDownloadEvent>();
    addTearDown(() {
      if (!events.isClosed) unawaited(events.close());
    });
    String storedModel = 'manga_ocr';
    String storedEngine = 'local_onnx';
    await tester.pumpWidget(wrap(MangaOcrSettingsSection(
      service: _FakeOcrService(downloadEvents: events),
      mokuroPathGetter: () => '',
      mokuroPathSetter: (String _) async {},
      probeExternal: (String _) async => null,
      enginePreferenceGetter: () => storedEngine,
      enginePreferenceSetter: (String value) async => storedEngine = value,
      localModelGetter: () => storedModel,
      localModelSetter: (String value) async => storedModel = value,
    )));
    await tester.pumpAndSettle();
    final Finder download =
        find.widgetWithText(FilledButton, t.manga_ocr_download);
    await tester.ensureVisible(download);
    await tester.tap(download);
    await tester.pump();
    await pickEngine(tester, engineLabel(MangaOcrLocalModel.mangaCtc));
    expect(storedModel, 'manga_ctc');
    // manga-ocr 那条下载仍挂在全局登记表上。
    expect(events.hasListener, isTrue);
  });

  testWidgets(
    'download errors stop download without reporting ready',
    (WidgetTester tester) async {
      final StreamController<MangaOcrDownloadEvent> events =
          StreamController<MangaOcrDownloadEvent>();
      final _FakeOcrService service = _FakeOcrService(downloadEvents: events);
      await tester.pumpWidget(
        wrap(
          MangaOcrSettingsSection(
            service: service,
            mokuroPathGetter: () => '',
            mokuroPathSetter: (String _) async {},
            probeExternal: (String _) async => null,
            enginePreferenceGetter: () => 'auto',
          ),
        ),
      );
      await tester.pumpAndSettle();
      final Finder download = find.widgetWithText(
        FilledButton,
        t.manga_ocr_download,
      );
      await tester.ensureVisible(download);
      await tester.tap(download);
      await tester.pump();
      events.add(
        const MangaOcrDownloadEvent(
          fileName: 'encoder_model.onnx',
          receivedBytes: 10,
          totalBytes: 100,
        ),
      );
      await tester.pump();
      expect(
        find.text(t.manga_ocr_downloading_file(file: 'encoder_model.onnx')),
        findsOneWidget,
      );
      events.addError(StateError('download failed'));
      final Future<void> closed = events.close();
      await tester.pumpAndSettle();
      await closed;
      await tester.pumpAndSettle();
      expect(service.ready, isFalse);
      expect(find.text(t.manga_ocr_model_status_missing), findsOneWidget);
      expect(find.text(t.manga_ocr_model_status_ready), findsNothing);
      expect(download, findsOneWidget);
    },
  );

  testWidgets('default Lens disables deletion while model import is pending', (
    WidgetTester tester,
  ) async {
    final Completer<void> imported = Completer<void>();
    addTearDown(() {
      if (!imported.isCompleted) imported.complete();
    });
    final _FakeOcrService service = _FakeOcrService(diskBytesOverride: 4096);
    final _FakeImporter importer = _FakeImporter(
      const MangaOcrModelImportResult(
        imported: <String>[],
        skipped: <String>[],
        rejected: <MangaOcrModelImportRejection>[],
        stillMissing: <String>['vocab.txt'],
      ),
      beforeReturn: () => imported.future,
    );
    await tester.pumpWidget(
      wrap(
        MangaOcrSettingsSection(
          service: service,
          mokuroPathGetter: () => '',
          mokuroPathSetter: (String _) async {},
          probeExternal: (String _) async => null,
          systemOcrRunner: _FakeSystemOcr(false),
          enginePreferenceGetter: () => kDefaultMangaOcrEnginePreference.key,
          modelsDirProvider: () async => Directory.systemTemp,
          modelImporter: importer,
          pickImportPaths: (bool _) async => <String>['/picked/models'],
        ),
      ),
    );
    await tester.pumpAndSettle();
    final Finder deleteButton = find.widgetWithText(
      OutlinedButton,
      t.manga_ocr_delete,
    );
    expect(tester.widget<OutlinedButton>(glassUnwrap<OutlinedButton>(deleteButton)).onPressed, isNotNull);
    final Finder importButton = find.byKey(
      const ValueKey<String>('manga_ocr_import_button'),
    );
    await tester.ensureVisible(importButton);
    await tester.tap(importButton);
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('manga_ocr_import_pick_folder')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(importer.calls, hasLength(1));
    expect(imported.isCompleted, isFalse);
    expect(tester.widget<OutlinedButton>(glassUnwrap<OutlinedButton>(deleteButton)).onPressed, isNull);
    await tester.ensureVisible(deleteButton);
    await tester.tap(deleteButton);
    await tester.pump();
    expect(find.text(t.manga_ocr_delete_confirm_title), findsNothing);
    expect(service.deleteCalls, 0);
    imported.complete();
    await tester.pumpAndSettle();
    expect(tester.widget<OutlinedButton>(glassUnwrap<OutlinedButton>(deleteButton)).onPressed, isNotNull);
  });

  testWidgets('detect external shows probed version',
      (WidgetTester tester) async {
    final _FakeOcrService service = _FakeOcrService(ready: true);
    await tester.pumpWidget(wrap(MangaOcrSettingsSection(
      service: service,
      mokuroPathGetter: () => '/usr/bin/mokuro',
      mokuroPathSetter: (String _) async {},
      probeExternal: (String _) async => 'mokuro 0.2.1',
    )));
    await tester.pumpAndSettle();

    // ready 时展示删除按钮。
    expect(find.widgetWithText(OutlinedButton, t.manga_ocr_delete),
        findsOneWidget);

    await tester
        .tap(find.widgetWithText(OutlinedButton, t.manga_ocr_external_detect));
    await tester.pumpAndSettle();
    expect(find.text(t.manga_ocr_external_detected(version: 'mokuro 0.2.1')),
        findsOneWidget);
  });

  testWidgets(
      'unsupported platform does not offer unusable local model download',
      (WidgetTester tester) async {
    final _FakeOcrService service =
        _FakeOcrService(supported: false, ready: false);
    await tester.pumpWidget(wrap(MangaOcrSettingsSection(
      service: service,
      mokuroPathGetter: () => '',
      mokuroPathSetter: (String _) async {},
      probeExternal: (String _) async => null,
    )));
    await tester.pumpAndSettle();

    expect(
        find.widgetWithText(FilledButton, t.manga_ocr_download), findsNothing);
    expect(find.text(t.manga_ocr_unsupported), findsOneWidget);
  });

  testWidgets('legacy single-box Gemini controls are no longer rendered',
      (WidgetTester tester) async {
    final _FakeOcrService service = _FakeOcrService(ready: true);
    await tester.pumpWidget(wrap(MangaOcrSettingsSection(
      service: service,
      mokuroPathGetter: () => '',
      mokuroPathSetter: (String _) async {},
      probeExternal: (String _) async => null,
    )));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey<String>('manga_cloud_ocr_switch')),
        findsNothing);
    expect(find.byKey(const ValueKey<String>('manga_cloud_ocr_api_key')),
        findsNothing);
  });

  // ---- BUG-1732：引擎取舍说明 / 按引擎收起模型块 / 真实占用与释放量 ----

  testWidgets('engine dropdown spells out each engine trade-off',
      (WidgetTester tester) async {
    final _FakeOcrService service = _FakeOcrService(ready: true);
    await tester.pumpWidget(wrap(MangaOcrSettingsSection(
      service: service,
      mokuroPathGetter: () => '',
      mokuroPathSetter: (String _) async {},
      probeExternal: (String _) async => null,
      enginePreferenceGetter: () => 'auto',
      enginePreferenceSetter: (String _) async {},
    )));
    await tester.pumpAndSettle();

    await tester
        .tap(find.byKey(const ValueKey<String>('manga_ocr_default_engine')));
    await tester.pumpAndSettle();

    // 谷歌要联网、快、但质量不如本地——用户挑引擎的依据必须写在选项上。
    expect(find.text(t.manga_ocr_engine_google_lens_desc), findsWidgets);
    expect(find.text(t.manga_ocr_engine_local_onnx_desc), findsWidgets);
    expect(find.text(t.manga_ocr_engine_paired_host_desc), findsWidgets);
  });

  testWidgets('Google Lens engine never prompts for a local model download',
      (WidgetTester tester) async {
    final _FakeOcrService service = _FakeOcrService(ready: false);
    await tester.pumpWidget(wrap(MangaOcrSettingsSection(
      service: service,
      mokuroPathGetter: () => '',
      mokuroPathSetter: (String _) async {},
      probeExternal: (String _) async => null,
      enginePreferenceGetter: () => 'google_lens',
      enginePreferenceSetter: (String _) async {},
    )));
    await tester.pumpAndSettle();

    expect(
        find.widgetWithText(FilledButton, t.manga_ocr_download), findsNothing);
    expect(find.text(t.manga_ocr_model_status_missing), findsNothing);
  });

  testWidgets('出厂默认引擎下，模型下载入口仍然可达（BUG-1780）',
      (WidgetTester tester) async {
    // 「不劝你下」被实现成了「不给你下的机会」：引擎用不到本地模型且磁盘干净时，
    // 这一整块曾经直接 SizedBox.shrink()。而出厂默认引擎恰恰就是用不到本地模型的
    // Google Lens，于是「全新安装 + 从没下过模型」这条最常见的路径上，下载入口
    // 根本不存在——想切到离线引擎的用户无处可点。
    //
    // 这条守卫刻意用 kDefaultMangaOcrEnginePreference 而不是硬写 'google_lens'：
    // 出厂默认值将来再改，这条也跟着改，不会重新分叉。
    final _FakeOcrService service = _FakeOcrService(ready: false);
    await tester.pumpWidget(wrap(MangaOcrSettingsSection(
      service: service,
      mokuroPathGetter: () => '',
      mokuroPathSetter: (String _) async {},
      probeExternal: (String _) async => null,
      enginePreferenceGetter: () => kDefaultMangaOcrEnginePreference.key,
      enginePreferenceSetter: (String _) async {},
    )));
    await tester.pumpAndSettle();

    expect(
      find.widgetWithText(TextButton, t.manga_ocr_download),
      findsOneWidget,
      reason: '出厂默认引擎下必须仍能找到下载入口（次级形态：普通按钮，不是主按钮）',
    );
    // 分寸不能丢：当前引擎本来就不需要模型，那不是「缺陷状态」，不该喊「未下载」。
    expect(find.text(t.manga_ocr_model_status_missing), findsNothing);
    expect(
      find.widgetWithText(FilledButton, t.manga_ocr_download),
      findsNothing,
      reason: '次级入口不许升级成主按钮，否则又变成劝一个只用 Lens 的用户下 450 MB',
    );
  });

  testWidgets('local models left on disk stay deletable under a cloud engine',
      (WidgetTester tester) async {
    final _FakeOcrService service = _FakeOcrService(
      ready: false,
      diskBytesOverride: 3 * 1024 * 1024 * 1024,
    );
    await tester.pumpWidget(wrap(MangaOcrSettingsSection(
      service: service,
      mokuroPathGetter: () => '',
      mokuroPathSetter: (String _) async {},
      probeExternal: (String _) async => null,
      enginePreferenceGetter: () => 'google_lens',
      enginePreferenceSetter: (String _) async {},
    )));
    await tester.pumpAndSettle();

    expect(find.text(t.manga_ocr_model_unused_by_engine), findsOneWidget);
    expect(
      find.text(t.manga_ocr_model_disk_usage(
        size: FushiByteFormat.bytes(3 * 1024 * 1024 * 1024),
      )),
      findsOneWidget,
    );
    expect(
        find.widgetWithText(FilledButton, t.manga_ocr_download), findsNothing);

    await tester
        .tap(find.widgetWithText(OutlinedButton, t.manga_ocr_delete).first);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, t.manga_ocr_delete));
    await tester.pumpAndSettle();
    expect(service.deleteCalls, 1);
  });

  testWidgets('ready row reports real disk usage, not the manifest total',
      (WidgetTester tester) async {
    final _FakeOcrService service = _FakeOcrService(
      ready: true,
      diskBytesOverride: 512 * 1024 * 1024,
    );
    await tester.pumpWidget(wrap(MangaOcrSettingsSection(
      service: service,
      mokuroPathGetter: () => '',
      mokuroPathSetter: (String _) async {},
      probeExternal: (String _) async => null,
    )));
    await tester.pumpAndSettle();

    expect(
      find.text(t.manga_ocr_model_disk_usage(
        size: FushiByteFormat.bytes(512 * 1024 * 1024),
      )),
      findsOneWidget,
    );
  });

  testWidgets('download progress aggregates every file into one total',
      (WidgetTester tester) async {
    // 下载器按文件报进度；照搬就是进度条来回跑好几趟，用户把 450 MB 感知成
    // 好几个 G。断言的是跨文件累计后的绝对字节数。
    final StreamController<MangaOcrDownloadEvent> events =
        StreamController<MangaOcrDownloadEvent>();
    addTearDown(events.close);
    final _FakeOcrService service =
        _FakeOcrService(ready: false, downloadEvents: events);
    await tester.pumpWidget(wrap(MangaOcrSettingsSection(
      service: service,
      mokuroPathGetter: () => '',
      mokuroPathSetter: (String _) async {},
      probeExternal: (String _) async => null,
      // 完整块（主下载按钮 + 进度条）只在引擎用得到本地模型时出现；显式声明前提。
      enginePreferenceGetter: () => 'auto',
    )));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, t.manga_ocr_download));
    await tester.pump();

    // 检测器整档下完（10 MB），识别 encoder 下到 5 MB：总进度必须是 15 MB，
    // 而不是「当前文件 5/30」这种一条条各自归零的读数。
    events.add(const MangaOcrDownloadEvent(
      fileName: 'detector.onnx',
      receivedBytes: 10 * 1024 * 1024,
      totalBytes: 10 * 1024 * 1024,
    ));
    events.add(const MangaOcrDownloadEvent(
      fileName: 'encoder_model.onnx',
      receivedBytes: 5 * 1024 * 1024,
      totalBytes: 30 * 1024 * 1024,
    ));
    await tester.pump();
    await tester.pump();

    expect(
      find.text(t.manga_ocr_download_total_progress(
        done: FushiByteFormat.bytes(15 * 1024 * 1024),
        total: FushiByteFormat.bytes(40 * 1024 * 1024),
      )),
      findsOneWidget,
    );
  });

  testWidgets('未就绪时给出手动导入入口（下不动模型的用户唯一的出路）',
      (WidgetTester tester) async {
    await tester.pumpWidget(wrap(MangaOcrSettingsSection(
      service: _FakeOcrService(ready: false),
      mokuroPathGetter: () => '',
      mokuroPathSetter: (String _) async {},
      probeExternal: (String _) async => null,
      enginePreferenceGetter: () => 'auto',
    )));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey<String>('manga_ocr_import_button')),
        findsOneWidget);
  });

  testWidgets('有半成品时下载按钮说「继续下载」，而不是让人以为要重下',
      (WidgetTester tester) async {
    await tester.pumpWidget(wrap(MangaOcrSettingsSection(
      service: _FakeOcrService(
        ready: false,
        obtainedBytesOverride: 17 * 1024 * 1024,
      ),
      mokuroPathGetter: () => '',
      mokuroPathSetter: (String _) async {},
      probeExternal: (String _) async => null,
      enginePreferenceGetter: () => 'auto',
    )));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(FilledButton, t.manga_ocr_download_resume),
        findsOneWidget);
    expect(find.widgetWithText(FilledButton, t.manga_ocr_download), findsNothing);
  });

  testWidgets('全新安装没有半成品时仍说「下载模型」', (WidgetTester tester) async {
    await tester.pumpWidget(wrap(MangaOcrSettingsSection(
      service: _FakeOcrService(ready: false),
      mokuroPathGetter: () => '',
      mokuroPathSetter: (String _) async {},
      probeExternal: (String _) async => null,
      enginePreferenceGetter: () => 'auto',
    )));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(FilledButton, t.manga_ocr_download),
        findsOneWidget);
    expect(find.widgetWithText(FilledButton, t.manga_ocr_download_resume),
        findsNothing);
  });

  testWidgets('导入对话框先列出所需文件，再把选中的路径交给导入器',
      (WidgetTester tester) async {
    final Directory tempDir =
        Directory.systemTemp.createTempSync('manga_ocr_ui_import_');
    addTearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });
    final _FakeImporter importer = _FakeImporter(
      const MangaOcrModelImportResult(
        imported: <String>['vocab.txt'],
        skipped: <String>[],
        rejected: <MangaOcrModelImportRejection>[],
        stillMissing: <String>[],
      ),
    );

    await tester.pumpWidget(wrap(MangaOcrSettingsSection(
      service: _FakeOcrService(ready: false),
      mokuroPathGetter: () => '',
      mokuroPathSetter: (String _) async {},
      probeExternal: (String _) async => null,
      enginePreferenceGetter: () => 'auto',
      modelsDirProvider: () async => tempDir,
      modelImporter: importer,
      pickImportPaths: (bool folderMode) async =>
          folderMode ? <String>['/picked/dir'] : <String>['/picked/file'],
    )));
    await tester.pumpAndSettle();

    await tester
        .tap(find.byKey(const ValueKey<String>('manga_ocr_import_button')));
    await tester.pumpAndSettle();

    // 用户点进来最缺的信息是「到底要哪几个文件」——清单必须在选择器之前出现。
    expect(find.text(t.manga_ocr_import_title), findsOneWidget);
    expect(find.textContaining('vocab.txt'), findsOneWidget);

    await tester.tap(
        find.byKey(const ValueKey<String>('manga_ocr_import_pick_folder')));
    await tester.pumpAndSettle();

    expect(importer.calls, <List<String>>[
      <String>['/picked/dir']
    ]);
  });

  testWidgets('选「选择文件」走的是文件模式，不是文件夹模式',
      (WidgetTester tester) async {
    final _FakeImporter importer = _FakeImporter(
      const MangaOcrModelImportResult(
        imported: <String>[],
        skipped: <String>[],
        rejected: <MangaOcrModelImportRejection>[],
        stillMissing: <String>['vocab.txt'],
      ),
    );
    final Directory tempDir =
        Directory.systemTemp.createTempSync('manga_ocr_ui_import2_');
    addTearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    await tester.pumpWidget(wrap(MangaOcrSettingsSection(
      service: _FakeOcrService(ready: false),
      mokuroPathGetter: () => '',
      mokuroPathSetter: (String _) async {},
      probeExternal: (String _) async => null,
      enginePreferenceGetter: () => 'auto',
      modelsDirProvider: () async => tempDir,
      modelImporter: importer,
      pickImportPaths: (bool folderMode) async =>
          folderMode ? <String>['/picked/dir'] : <String>['/picked/file'],
    )));
    await tester.pumpAndSettle();

    await tester
        .tap(find.byKey(const ValueKey<String>('manga_ocr_import_button')));
    await tester.pumpAndSettle();
    await tester
        .tap(find.byKey(const ValueKey<String>('manga_ocr_import_pick_files')));
    await tester.pumpAndSettle();

    expect(importer.calls, <List<String>>[
      <String>['/picked/file']
    ]);
  });

  testWidgets('Baberu import dialog includes its recognizer and PP line models',
      (WidgetTester tester) async {
    await tester.pumpWidget(wrap(MangaOcrSettingsSection(
      service: _FakeOcrService(),
      mokuroPathGetter: () => '',
      mokuroPathSetter: (String _) async {},
      probeExternal: (String _) async => null,
      enginePreferenceGetter: () => 'auto',
      localModelGetter: () => 'baberu',
      localModelSetter: (String _) async {},
    )));
    await tester.pumpAndSettle();
    final Finder importButton =
        find.byKey(const ValueKey<String>('manga_ocr_import_button'));
    await tester.ensureVisible(importButton);
    await tester.tap(importButton);
    await tester.pumpAndSettle();
    expect(find.text(t.manga_ocr_import_title), findsOneWidget);
    for (final String name in <String>[
      'detector-v4-s_int8.onnx',
      'vision_fp16.onnx',
      'decoder_prefill_int8.onnx',
      'decoder_step_int8.onnx',
      'vocab.json',
      'ppocrv6_small_det.onnx',
      'ppocrv6_small_rec.onnx',
      'ppocrv6_small_rec.yml',
    ]) {
      expect(find.textContaining(name), findsOneWidget);
    }
    for (final String obsolete in <String>[
      'encoder_model.onnx',
      'decoder_model.onnx',
      'vocab.txt',
    ]) {
      expect(find.textContaining(obsolete), findsNothing);
    }
  }, skip: !Platform.isWindows);

  testWidgets('设备自带 OCR：可用时下拉里那项可选', (WidgetTester tester) async {
    await tester.pumpWidget(wrap(MangaOcrSettingsSection(
      service: _FakeOcrService(ready: false),
      mokuroPathGetter: () => '',
      mokuroPathSetter: (String _) async {},
      probeExternal: (String _) async => null,
      enginePreferenceGetter: () => 'auto',
      enginePreferenceSetter: (String _) async {},
      systemOcrRunner: _FakeSystemOcr(true),
    )));
    await tester.pumpAndSettle();

    await tester
        .tap(find.byKey(const ValueKey<String>('manga_ocr_default_engine')));
    await tester.pumpAndSettle();
    expect(find.text(t.manga_ocr_engine_system), findsWidgets);
    // 取舍必须写在选项自己身上：用户没有别的依据判断该不该选它。
    expect(find.textContaining(t.manga_ocr_engine_system_desc), findsWidgets);
  });

  testWidgets('设备自带 OCR：本机没有就置灰，不假装能跑',
      (WidgetTester tester) async {
    await tester.pumpWidget(wrap(MangaOcrSettingsSection(
      service: _FakeOcrService(ready: false),
      mokuroPathGetter: () => '',
      mokuroPathSetter: (String _) async {},
      probeExternal: (String _) async => null,
      enginePreferenceGetter: () => 'auto',
      enginePreferenceSetter: (String _) async {},
      systemOcrRunner: _FakeSystemOcr(false),
    )));
    await tester.pumpAndSettle();

    await tester
        .tap(find.byKey(const ValueKey<String>('manga_ocr_default_engine')));
    await tester.pumpAndSettle();
    // 下拉值类型是私有的（引擎 + 本机模型），按菜单项里的标签取那一项。
    final DropdownMenuItem<Object?> system = tester
        .widgetList<Widget>(find.ancestor(
          of: find.text(t.manga_ocr_engine_system),
          matching: find.byWidgetPredicate(
              (Widget widget) => widget is DropdownMenuItem),
        ))
        .cast<DropdownMenuItem<Object?>>()
        .first;
    expect(system.enabled, isFalse,
        reason: '选得中一个跑不了的引擎，只会换来一句没头没脑的报错');
  });
  String hostLabel(MangaOcrLocalModel model) =>
      t.manga_ocr_engine_paired_host_model(model: localModelLabel(model));

  testWidgets('server models are engine choices and persist the named model',
      (WidgetTester tester) async {
    String storedEngine = 'google_lens';
    String storedHostModel = '';
    await tester.pumpWidget(wrap(MangaOcrSettingsSection(
      service: _FakeOcrService(ready: true),
      mokuroPathGetter: () => '',
      mokuroPathSetter: (String _) async {},
      probeExternal: (String _) async => null,
      enginePreferenceGetter: () => storedEngine,
      enginePreferenceSetter: (String value) async => storedEngine = value,
      pairedHostModelGetter: () => storedHostModel,
      pairedHostModelSetter: (String value) async => storedHostModel = value,
      remoteRunner: _FakeRemoteRunner(const <MangaOcrRemoteModel>[
        MangaOcrRemoteModel(key: 'manga_ocr', ready: true),
        MangaOcrRemoteModel(key: 'manga_ctc', ready: false),
      ]),
    )));
    await tester.pumpAndSettle();

    final Finder field =
        find.byKey(const ValueKey<String>('manga_ocr_default_engine'));
    await tester.ensureVisible(field);
    await tester.tap(field);
    await tester.pumpAndSettle();
    expect(find.text(hostLabel(MangaOcrLocalModel.mangaOcr)), findsWidgets);
    expect(find.text(hostLabel(MangaOcrLocalModel.mangaCtc)), findsWidgets);
    // 服务端没下好的那个模型如实说出来，而不是等整卷传完才报错。
    expect(
      find.textContaining(t.manga_ocr_engine_paired_host_model_missing),
      findsOneWidget,
    );
    await tester.tap(find.text(hostLabel(MangaOcrLocalModel.mangaCtc)).last);
    await tester.pumpAndSettle();
    expect(storedEngine, 'paired_host');
    expect(storedHostModel, 'manga_ctc');

    // 选回「服务端默认」：清掉点名。
    await pickEngine(tester, t.manga_remote_ocr_engine);
    expect(storedEngine, 'paired_host');
    expect(storedHostModel, '');
  });

  testWidgets('a named server model stays selected while the server is offline',
      (WidgetTester tester) async {
    await tester.pumpWidget(wrap(MangaOcrSettingsSection(
      service: _FakeOcrService(ready: true),
      mokuroPathGetter: () => '',
      mokuroPathSetter: (String _) async {},
      probeExternal: (String _) async => null,
      enginePreferenceGetter: () => 'paired_host',
      enginePreferenceSetter: (String _) async {},
      pairedHostModelGetter: () => 'manga_ctc',
      pairedHostModelSetter: (String _) async {},
      remoteRunner: _FakeRemoteRunner(null),
    )));
    await tester.pumpAndSettle();
    // 闭合态显示的就是点名的那项（下拉找不到当前值会直接断言崩溃）。
    expect(find.text(hostLabel(MangaOcrLocalModel.mangaCtc)), findsOneWidget);
  });

  // 阅读器侧栏的 OCR 标签只有 ~320px。
  Widget narrowSection(String enginePreference) => wrap(SizedBox(
        width: 320,
        child: MangaOcrSettingsSection(
          service: _FakeOcrService(),
          mokuroPathGetter: () => '',
          mokuroPathSetter: (String _) async {},
          probeExternal: (String _) async => null,
          enginePreferenceGetter: () => enginePreference,
          parallelTasksGetter: () => 0,
          parallelTasksSetter: (int _) async {},
        ),
      ));
  Finder engineField() =>
      find.byKey(const ValueKey<String>('manga_ocr_default_engine'));
  // 闭合态是 IndexedStack：它只把选中项报成 onstage，未选中项的标签默认被
  // finder 跳过，必须 skipOffstage: false 才查得到。
  RenderParagraph closedLabel(WidgetTester tester, String label) =>
      tester.renderObject<RenderParagraph>(find.descendant(
          of: engineField(),
          matching: find.text(label, skipOffstage: false),
          skipOffstage: false));

  testWidgets('BUG-2912: narrow reader sheet shows engine and helper in full',
      (WidgetTester tester) async {
    // 引擎下拉闭合态曾被 dense 的一行高 SizedBox 裁掉第二行；并行任务说明被
    // 限死 3 行吞掉结尾。
    await tester.pumpWidget(narrowSection('auto'));
    await tester.pumpAndSettle();

    final RenderParagraph selected =
        closedLabel(tester, t.manga_ocr_engine_auto);
    final RenderParagraph oneLine =
        closedLabel(tester, t.manga_ocr_engine_google_lens);
    // 前提：这个宽度下选中项的标签确实要折行，否则下面的断言是空壳。
    expect(selected.textSize.height,
        greaterThanOrEqualTo(oneLine.textSize.height * 2));
    // 段落拿到的高度装得下它排出来的全部行。dense 时父级把高度钳在一行：
    // size 被 constrain 成一行而 textSize 仍是多行——视觉上第二行被裁掉。
    expect(
        selected.size.height, greaterThanOrEqualTo(selected.textSize.height));
    // 段落整个落在输入框里，没有被挤出闭合态。
    final Rect field = tester.getRect(find
        .descendant(of: engineField(), matching: find.byType(InputDecorator))
        .first);
    final Rect label = tester.getRect(find.descendant(
        of: engineField(), matching: find.text(t.manga_ocr_engine_auto)));
    expect(label.top, greaterThanOrEqualTo(field.top));
    expect(label.bottom, lessThanOrEqualTo(field.bottom));
    expect(
      tester
          .renderObject<RenderParagraph>(
              find.text(t.manga_ocr_parallel_tasks_desc))
          .didExceedMaxLines,
      isFalse,
    );
  });

  testWidgets(
      'BUG-2912: closed engine dropdown is only as tall as the selected label',
      (WidgetTester tester) async {
    // 非 dense 的闭合态是 IndexedStack，高度取所有子项的最大值：未选中项也允许
    // 折行的话，只要「自动（不会上传到 Lens）」折两行，选了单行 Google Lens 的
    // 按钮也恒为两行高——全局 OCR 设置页同样受影响。
    await tester.pumpWidget(narrowSection('google_lens'));
    await tester.pumpAndSettle();

    final RenderParagraph selected =
        closedLabel(tester, t.manga_ocr_engine_google_lens);
    final Size stack = tester.getSize(find
        .descendant(of: engineField(), matching: find.byType(IndexedStack))
        .first);
    expect(stack.height, selected.textSize.height);
    // 未选中项只排一行，不撑高闭合态。
    expect(closedLabel(tester, t.manga_ocr_engine_auto).textSize.height,
        selected.textSize.height);
  });
}
