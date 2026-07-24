import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/media/manga/manga_ocr_settings_section.dart';
import 'package:hibiki/src/ocr/manga_ocr_service.dart';

/// Fake 服务，模型状态与下载流可编程。
class _FakeOcrService implements MangaOcrService {
  _FakeOcrService({this.supported = true, this.ready = false});

  final bool supported;
  bool ready;

  @override
  bool get isSupportedPlatform => supported;

  @override
  Future<MangaOcrModelStatus> modelStatus() async => MangaOcrModelStatus(
        detectorReady: ready,
        recognizerReady: ready,
        downloadedBytes: ready ? 40 * 1024 * 1024 : 0,
        totalBytes: 40 * 1024 * 1024,
      );

  @override
  Stream<MangaOcrDownloadEvent> downloadModels() async* {
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
  Future<void> deleteModels() async {
    ready = false;
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

  testWidgets('unsupported platform shows explanation, no model rows',
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

    expect(find.text(t.manga_ocr_unsupported), findsOneWidget);
    expect(
        find.widgetWithText(FilledButton, t.manga_ocr_download), findsNothing);
    // 外部 CLI 块仍在。
    expect(find.widgetWithText(OutlinedButton, t.manga_ocr_external_detect),
        findsOneWidget);
  });
}
