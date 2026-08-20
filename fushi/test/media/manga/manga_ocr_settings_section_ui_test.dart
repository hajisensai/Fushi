import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/manga_ocr_settings_section.dart';
import 'package:fushi/src/ocr/manga_ocr_service.dart';
import 'package:fushi/utils.dart';

/// Fake 服务，模型状态与下载流可编程。
class _FakeOcrService implements MangaOcrService {
  _FakeOcrService({
    this.supported = true,
    this.ready = false,
    this.diskBytesOverride,
    this.downloadEvents,
  });

  final bool supported;
  bool ready;

  /// 磁盘占用与「清单是否齐全」解耦：残留 `.part`/遗留档就是「不 ready 但占着
  /// 磁盘」，这正是引擎用不到时仍须可删的那一档。
  final int? diskBytesOverride;

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
}
