import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/manga_ocr_settings_section.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_engine.dart';
import 'package:fushi/src/ocr/manga_ocr_model_import.dart';
import 'package:fushi/src/ocr/manga_ocr_service.dart';
import 'package:fushi/utils.dart';

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
  }) =>
      const Stream<MangaOcrVolumeEvent>.empty();
}

/// 记录调用的导入器：UI 测试只关心「入口接线对不对」，真实拷贝/解压逻辑由
/// `test/ocr/manga_ocr_model_import_test.dart` 单独盯。
class _FakeImporter extends MangaOcrModelImporter {
  _FakeImporter(this.result);

  final MangaOcrModelImportResult result;
  final List<List<String>> calls = <List<String>>[];

  @override
  Future<MangaOcrModelImportResult> import({
    required List<String> sourcePaths,
    required Directory targetDir,
  }) async {
    calls.add(sourcePaths);
    return result;
  }
}

void main() {
  Widget wrap(Widget child) {
    return ProviderScope(
      child: TranslationProvider(
        child: MaterialApp(
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
}
