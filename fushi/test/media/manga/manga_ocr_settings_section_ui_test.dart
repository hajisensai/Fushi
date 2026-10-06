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
import 'package:fushi/src/media/manga/reader/manga_reader_settings_panel_kit.dart'
    show MangaPanelInfoButton;
import 'package:fushi/src/ocr/manga_ocr_model_import.dart';
import 'package:fushi/src/sync/interconnect_manga_ocr_client.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart'
    show FushiGroupedListItem;
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
  });

  final bool supported;
  bool ready;
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
      );

  @override
  Stream<MangaOcrDownloadEvent> downloadModels() async* {
    downloadCalls++;
    final StreamController<MangaOcrDownloadEvent>? scripted = downloadEvents;
    if (scripted != null) {
      yield* scripted.stream;
      ready = true;
      return;
    }
    yield const MangaOcrDownloadEvent(
      fileName: 'detector-v4-s_int8.onnx',
      receivedBytes: 10,
      totalBytes: 20,
    );
    ready = true;
    yield const MangaOcrDownloadEvent(
      fileName: 'detector-v4-s_int8.onnx',
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

  const ValueKey<String> engineRowKey =
      ValueKey<String>('manga_ocr_default_engine');
  const ValueKey<String> modelSummaryKey =
      ValueKey<String>('manga_ocr_model_summary');
  const ValueKey<String> modelCardKey =
      ValueKey<String>('manga_ocr_model_card');

  /// 引擎弹层里单项的 key（与 `_pickEngine` 同一拼法）。
  ValueKey<String> engineOptionKey(
    MangaOcrEnginePreference preference, {
    MangaOcrLocalModel? localModel,
    String? hostModel,
  }) =>
      ValueKey<String>('manga_ocr_engine_${preference.name}'
          '_${localModel?.key ?? ''}_${hostModel ?? ''}');

  /// 点按某个（可能在弹层滚动区外的）目标：先滚进视口再点。
  Future<void> tapVisible(WidgetTester tester, Finder target) async {
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
    await tester.tap(target);
    await tester.pumpAndSettle();
  }

  /// 点开默认引擎行，弹出引擎选项弹层。
  Future<void> openEngineSheet(WidgetTester tester) async {
    await tapVisible(tester, find.byKey(engineRowKey));
  }

  /// 打开引擎弹层并点选某一项（标签在行副标题里与说明拼在一起，弹层里单独一份；
  /// 取最后一个即弹层那份）。
  Future<void> pickEngine(WidgetTester tester, String label) async {
    await openEngineSheet(tester);
    await tapVisible(tester, find.text(label).last);
  }

  /// 引擎用不到本机模型时模型区收起成摘要卡：点开它才露出下载 / 导入 / 删除。
  Future<void> expandModelSummary(WidgetTester tester) async {
    await tapVisible(tester, find.byKey(modelSummaryKey));
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

    expect(find.byKey(modelCardKey), findsOneWidget);
    expect(find.byKey(modelSummaryKey), findsNothing,
        reason: '引擎用得到本机模型时不收起');
    expect(find.text(t.manga_ocr_model_status_missing), findsOneWidget);
    expect(find.widgetWithText(FilledButton, t.manga_ocr_download),
        findsOneWidget);
  });

  testWidgets('lens language row persists the chosen language',
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

    final Finder row =
        find.byKey(const ValueKey<String>('manga_ocr_lens_language'));
    expect(find.text(t.manga_ocr_lens_language_label), findsOneWidget);
    await tapVisible(tester, row);
    await tapVisible(tester, find.text('English').last);
    expect(stored, 'en');
    // 弹层选中即关，行副标题换成新选的语言。
    expect(find.descendant(of: row, matching: find.text('English')),
        findsOneWidget);
  });

  testWidgets('lens language row is absent without a language setter',
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
    final Finder row =
        find.byKey(const ValueKey<String>('manga_ocr_parallel_tasks'));
    Finder rowValue(String label) =>
        find.descendant(of: row, matching: find.text(label));

    await tester.pumpWidget(settings());
    await tester.pumpAndSettle();
    expect(rowValue(t.manga_ocr_parallel_auto), findsOneWidget);
    await tapVisible(tester, row);
    await tapVisible(tester, find.text('4').last);
    expect(stored, 4);
    expect(rowValue('4'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(settings());
    await tester.pumpAndSettle();
    expect(rowValue('4'), findsOneWidget);
    await tapVisible(tester, row);
    await tapVisible(tester, find.text(t.manga_ocr_parallel_auto).last);
    expect(stored, 0);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(settings());
    await tester.pumpAndSettle();
    expect(rowValue(t.manga_ocr_parallel_auto), findsOneWidget);
  });

  String engineLabel(MangaOcrLocalModel model) =>
      t.manga_ocr_engine_local_model(model: localModelLabel(model));

  testWidgets('local models are engine choices; no separate model dropdown',
      (WidgetTester tester) async {
    // Windows 上从 Baberu 起步，选 CTC 时模型偏好真的要被改写；别的平台只列
    // CTC，起步值只能就是它。
    String storedModel = Platform.isWindows
        ? MangaOcrLocalModel.baberu.key
        : MangaOcrLocalModel.mangaCtc.key;
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
    // 设置页已经没有任何下拉了：引擎是选择行 + 底部弹层。
    expect(
      find.byWidgetPredicate((Widget widget) =>
          widget is DropdownButtonFormField || widget is DropdownButton),
      findsNothing,
    );

    await openEngineSheet(tester);
    // Baberu 只在 Windows 列出；CTC 五端都有。
    expect(find.text(engineLabel(MangaOcrLocalModel.mangaCtc)), findsWidgets);
    expect(find.text(engineLabel(MangaOcrLocalModel.baberu)),
        Platform.isWindows ? findsWidgets : findsNothing);
    // 单一的「本地 ONNX」项已被逐模型项取代。
    expect(find.text(t.manga_ocr_engine_local_onnx), findsNothing);
    await tapVisible(
      tester,
      find.byKey(engineOptionKey(MangaOcrEnginePreference.localOnnx,
          localModel: MangaOcrLocalModel.mangaCtc)),
    );
    expect(storedModel, 'manga_ctc');
    expect(storedEngine, 'local_onnx');
    // 状态行说清楚是哪个模型。
    expect(find.textContaining(t.manga_ocr_ctc_model), findsWidgets);
  });

  testWidgets('choosing a local model engine persists across reopening',
      (WidgetTester tester) async {
    String storedModel = kDefaultMangaOcrLocalModel.key;
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
    // 引擎行副标题显示选中项的标签（与它的取舍说明拼在同一段）。
    expect(
      find.descendant(
          of: find.byKey(engineRowKey),
          matching: find.textContaining(engineLabel(target))),
      findsOneWidget,
    );

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
    // 宿主没接模型偏好时用的是默认本机模型（CTC）。
    expect(downloads.isActive(kDefaultMangaOcrLocalModel), isTrue);
    expect(events.hasListener, isTrue);
    events.add(const MangaOcrDownloadEvent(
      fileName: 'detector-v4-s_int8.onnx',
      receivedBytes: 1024,
      totalBytes: 2048,
    ));
    await tester.pump();
    expect(downloads.progressOf(kDefaultMangaOcrLocalModel)?.receivedBytes,
        1024);

    // 重新打开页面：接回同一条下载的进度。
    showPage.value = true;
    await tester.pumpAndSettle();
    expect(
        find.text(
            t.manga_ocr_downloading_file(file: 'detector-v4-s_int8.onnx')),
        findsOneWidget);

    await events.close();
    await tester.pumpAndSettle();
    expect(downloads.isActive(kDefaultMangaOcrLocalModel), isFalse);
    expect(find.text(t.manga_ocr_model_status_ready), findsOneWidget);
  });

  testWidgets('switching engine during a download does not cancel it',
      (WidgetTester tester) async {
    final StreamController<MangaOcrDownloadEvent> events =
        StreamController<MangaOcrDownloadEvent>();
    addTearDown(() {
      if (!events.isClosed) unawaited(events.close());
    });
    // Windows 列得出两个本机模型：从 Baberu 的下载中换到 CTC，最能说明「下载
    // 按模型归属全局登记表、换走了照跑」。其余平台只有 CTC，就换到云端引擎。
    final bool twoModels = Platform.isWindows;
    String storedModel = twoModels
        ? MangaOcrLocalModel.baberu.key
        : MangaOcrLocalModel.mangaCtc.key;
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
    if (twoModels) {
      await pickEngine(tester, engineLabel(MangaOcrLocalModel.mangaCtc));
      expect(storedModel, 'manga_ctc');
      expect(storedEngine, 'local_onnx');
    } else {
      await pickEngine(tester, t.manga_ocr_engine_google_lens);
      expect(storedEngine, 'google_lens');
    }
    // 原模型那条下载仍挂在全局登记表上。
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
          fileName: 'kellenok_manga_rec_v0.2.onnx',
          receivedBytes: 10,
          totalBytes: 100,
        ),
      );
      await tester.pump();
      expect(
        find.text(t.manga_ocr_downloading_file(
            file: 'kellenok_manga_rec_v0.2.onnx')),
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
        stillMissing: <String>['ppocrv6_small_rec.yml'],
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
    // 默认引擎（Lens）用不到本机模型：模型区先收起成摘要，点开才有删除 / 导入。
    await expandModelSummary(tester);
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

    // 出厂默认引擎用不到本机模型：先展开摘要；ready 时展示删除按钮。
    await expandModelSummary(tester);
    expect(find.widgetWithText(OutlinedButton, t.manga_ocr_delete),
        findsOneWidget);

    await tapVisible(
        tester, find.byKey(const ValueKey<String>('manga_ocr_external_detect')));
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('manga_ocr_external_result')),
        matching:
            find.text(t.manga_ocr_external_detected(version: 'mokuro 0.2.1')),
      ),
      findsOneWidget,
    );
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
    // 不支持的平台不收起：直接给出说明卡，也没有可展开的摘要。
    expect(find.byKey(modelSummaryKey), findsNothing);
    expect(
      find.descendant(
          of: find.byKey(modelCardKey),
          matching: find.text(t.manga_ocr_unsupported)),
      findsOneWidget,
    );
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

  testWidgets('engine sheet spells out each engine trade-off',
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

    // 行副标题就带着当前引擎的取舍。
    expect(
      find.descendant(
          of: find.byKey(engineRowKey),
          matching: find.text(
              '${t.manga_ocr_engine_auto}\n${t.manga_ocr_engine_auto_desc}')),
      findsOneWidget,
    );

    await openEngineSheet(tester);

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

    // 收起成一行摘要，说明当前引擎用不到它们。
    expect(find.byKey(modelSummaryKey), findsOneWidget);
    expect(
      find.descendant(
          of: find.byKey(modelSummaryKey),
          matching: find.textContaining(t.manga_ocr_model_unused_by_engine)),
      findsOneWidget,
    );
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

    // M3E 设置页：引擎用不到本机模型时模型区收起成摘要卡——收起不等于藏起来，
    // 摘要卡本身就是入口。
    expect(find.byKey(modelSummaryKey), findsOneWidget);
    expect(find.byKey(modelCardKey), findsNothing);
    expect(
        find.widgetWithText(FilledButton, t.manga_ocr_download), findsNothing);

    await expandModelSummary(tester);

    expect(
      find.widgetWithText(FilledButton, t.manga_ocr_download),
      findsOneWidget,
      reason: '出厂默认引擎下必须仍能找到下载入口（展开摘要后的次级色调按钮）',
    );
    // 分寸不能丢：当前引擎本来就不需要模型，那不是「缺陷状态」，不该喊「未下载」。
    // 展开后是中性的「用不到」说明卡，而不是劝一个只用 Lens 的用户下模型的强调卡。
    expect(find.text(t.manga_ocr_model_status_missing), findsNothing);
    expect(
      find.descendant(
          of: find.byKey(modelCardKey),
          matching: find.text(t.manga_ocr_model_unused_by_engine)),
      findsOneWidget,
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

    final String diskUsage = t.manga_ocr_model_disk_usage(
      size: FushiByteFormat.bytes(3 * 1024 * 1024 * 1024),
    );
    // 摘要里就报真实占用。
    expect(
      find.descendant(
          of: find.byKey(modelSummaryKey),
          matching: find.textContaining(diskUsage)),
      findsOneWidget,
    );

    await expandModelSummary(tester);

    expect(find.text(t.manga_ocr_model_unused_by_engine), findsOneWidget);
    expect(find.text(diskUsage), findsOneWidget);
    expect(
        find.widgetWithText(FilledButton, t.manga_ocr_download), findsNothing);

    await tapVisible(
        tester, find.widgetWithText(OutlinedButton, t.manga_ocr_delete).first);
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
      // 就绪卡只在引擎用得到本机模型时直接展开（出厂默认 Lens 下是摘要）。
      enginePreferenceGetter: () => 'auto',
    )));
    await tester.pumpAndSettle();

    expect(find.text(t.manga_ocr_model_status_ready), findsOneWidget);
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

    final Finder download =
        find.widgetWithText(FilledButton, t.manga_ocr_download);
    await tester.ensureVisible(download);
    await tester.tap(download);
    await tester.pump();

    // 检测器整档下完（10 MB），漫画 rec 下到 5 MB：总进度必须是 15 MB，
    // 而不是「当前文件 5/30」这种一条条各自归零的读数。
    events.add(const MangaOcrDownloadEvent(
      fileName: 'detector-v4-s_int8.onnx',
      receivedBytes: 10 * 1024 * 1024,
      totalBytes: 10 * 1024 * 1024,
    ));
    events.add(const MangaOcrDownloadEvent(
      fileName: 'kellenok_manga_rec_v0.2.onnx',
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

    final Finder importButton =
        find.byKey(const ValueKey<String>('manga_ocr_import_button'));
    expect(importButton, findsOneWidget);
    // 与主按钮成组时是描边按钮。
    expect(glassUnwrap<OutlinedButton>(importButton), findsOneWidget);
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
        imported: <String>['ppocrv6_small_rec.yml'],
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

    await tapVisible(
        tester, find.byKey(const ValueKey<String>('manga_ocr_import_button')));

    // 用户点进来最缺的信息是「到底要哪几个文件」——清单必须在选择器之前出现。
    // 默认本机模型是逐列 CTC，列的是它的清单。
    expect(find.text(t.manga_ocr_import_title), findsOneWidget);
    for (final String name in <String>[
      'detector-v4-s_int8.onnx',
      'ppocrv6_small_det.onnx',
      'ppocrv6_small_rec.yml',
      'kellenok_manga_rec_v0.2.onnx',
    ]) {
      expect(find.textContaining(name), findsOneWidget);
    }

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
        stillMissing: <String>['ppocrv6_small_rec.yml'],
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

    await tapVisible(
        tester, find.byKey(const ValueKey<String>('manga_ocr_import_button')));
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

  testWidgets('设备自带 OCR：可用时弹层里那项可选', (WidgetTester tester) async {
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

    await openEngineSheet(tester);
    expect(find.text(t.manga_ocr_engine_system), findsWidgets);
    // 取舍必须写在选项自己身上：用户没有别的依据判断该不该选它。
    expect(find.textContaining(t.manga_ocr_engine_system_desc), findsWidgets);
    final FushiGroupedListItem system = tester.widget<FushiGroupedListItem>(
        find.byKey(engineOptionKey(MangaOcrEnginePreference.systemOcr)));
    expect(system.onTap, isNotNull);
  });

  testWidgets('设备自带 OCR：本机没有就置灰，不假装能跑',
      (WidgetTester tester) async {
    String storedEngine = 'auto';
    await tester.pumpWidget(wrap(MangaOcrSettingsSection(
      service: _FakeOcrService(ready: false),
      mokuroPathGetter: () => '',
      mokuroPathSetter: (String _) async {},
      probeExternal: (String _) async => null,
      enginePreferenceGetter: () => storedEngine,
      enginePreferenceSetter: (String value) async => storedEngine = value,
      systemOcrRunner: _FakeSystemOcr(false),
    )));
    await tester.pumpAndSettle();

    await openEngineSheet(tester);
    // 弹层值类型是私有的（引擎 + 本机模型），按选项 key 取那一项。
    final Finder systemOption =
        find.byKey(engineOptionKey(MangaOcrEnginePreference.systemOcr));
    expect(tester.widget<FushiGroupedListItem>(systemOption).onTap, isNull,
        reason: '选得中一个跑不了的引擎，只会换来一句没头没脑的报错');
    await tester.ensureVisible(systemOption);
    await tester.pumpAndSettle();
    await tester.tap(systemOption, warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(storedEngine, 'auto');
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
        MangaOcrRemoteModel(key: 'baberu', ready: true),
        MangaOcrRemoteModel(key: 'manga_ctc', ready: false),
      ]),
    )));
    await tester.pumpAndSettle();

    await openEngineSheet(tester);
    expect(find.text(hostLabel(MangaOcrLocalModel.baberu)), findsWidgets);
    expect(find.text(hostLabel(MangaOcrLocalModel.mangaCtc)), findsWidgets);
    // 服务端没下好的那个模型如实说出来，而不是等整卷传完才报错。
    expect(
      find.textContaining(t.manga_ocr_engine_paired_host_model_missing),
      findsOneWidget,
    );
    await tapVisible(
      tester,
      find.byKey(engineOptionKey(MangaOcrEnginePreference.pairedHost,
          hostModel: 'manga_ctc')),
    );
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
    // 引擎行副标题显示的就是点名的那项（选项表里找不到当前值就没有副标题）。
    expect(
      find.descendant(
          of: find.byKey(engineRowKey),
          matching: find.textContaining(hostLabel(MangaOcrLocalModel.mangaCtc))),
      findsOneWidget,
    );
  });

  testWidgets('BUG-2912: engine row and parallel-tasks help show in full',
      (WidgetTester tester) async {
    // 原 BUG-2912：引擎下拉闭合态曾被 dense 的一行高 SizedBox 裁掉第二行；并行
    // 任务说明被限死 3 行吞掉结尾。M3E 设置页已没有下拉，阅读器侧板也改走
    // readerPanel 版式（单选卡片组），于是守卫改钉新形态的同一诉求：
    // ① 引擎行副标题（引擎名 + 取舍）整段排出，不截断、不被裁；
    // ② 并行任务的长说明收进 info，点开的对话框里整段可见。
    //
    // 原第二条「闭合态只与选中项一样高」（IndexedStack 取所有子项最大高）是
    // DropdownButton 闭合态特有的问题，新形态没有 IndexedStack，整条删掉。
    // 窄宽（320px）不再在这里测：测试字体每字等宽 1em，那个宽度下 5 行上限一定
    // 截断，测出来的是字体而不是布局。
    await tester.pumpWidget(wrap(MangaOcrSettingsSection(
      service: _FakeOcrService(),
      mokuroPathGetter: () => '',
      mokuroPathSetter: (String _) async {},
      probeExternal: (String _) async => null,
      enginePreferenceGetter: () => 'auto',
      parallelTasksGetter: () => 0,
      parallelTasksSetter: (int _) async {},
    )));
    await tester.pumpAndSettle();

    final RenderParagraph subtitle = tester.renderObject<RenderParagraph>(
        find.descendant(
            of: find.byKey(engineRowKey),
            matching: find.text(
                '${t.manga_ocr_engine_auto}\n${t.manga_ocr_engine_auto_desc}')));
    expect(subtitle.didExceedMaxLines, isFalse);
    // 段落拿到的高度装得下它排出来的全部行。
    expect(
        subtitle.size.height, greaterThanOrEqualTo(subtitle.textSize.height));

    final Finder info = find.descendant(
      of: find.byKey(const ValueKey<String>('manga_ocr_parallel_tasks')),
      matching: find.byType(MangaPanelInfoButton),
    );
    expect(info, findsOneWidget);
    await tapVisible(tester, info);
    expect(find.text(t.manga_ocr_parallel_tasks_desc), findsOneWidget);
  });
}
