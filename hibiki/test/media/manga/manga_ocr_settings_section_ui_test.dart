import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/manga/manga_ocr_settings_section.dart';
import 'package:hibiki/src/ocr/manga_ocr_service.dart';
import 'package:hibiki/utils.dart';

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
      cloudEnabledGetter: () => false,
      cloudEnabledSetter: (bool _) async {},
      cloudApiKeyGetter: () => '',
      cloudApiKeySetter: (String _) async {},
      cloudModelGetter: () => '',
      cloudModelSetter: (String _) async {},
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
      cloudEnabledGetter: () => false,
      cloudEnabledSetter: (bool _) async {},
      cloudApiKeyGetter: () => '',
      cloudApiKeySetter: (String _) async {},
      cloudModelGetter: () => '',
      cloudModelSetter: (String _) async {},
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
      'unsupported platform still shows model download (P4: box scan on mobile) '
      'plus a mobile note', (WidgetTester tester) async {
    final _FakeOcrService service =
        _FakeOcrService(supported: false, ready: false);
    await tester.pumpWidget(wrap(MangaOcrSettingsSection(
      service: service,
      mokuroPathGetter: () => '',
      mokuroPathSetter: (String _) async {},
      probeExternal: (String _) async => null,
      cloudEnabledGetter: () => false,
      cloudEnabledSetter: (bool _) async {},
      cloudApiKeyGetter: () => '',
      cloudApiKeySetter: (String _) async {},
      cloudModelGetter: () => '',
      cloudModelSetter: (String _) async {},
    )));
    await tester.pumpAndSettle();

    // P4 契约：模型下载/状态行全平台显示（移动端用于框选识别）。
    expect(
        find.widgetWithText(FilledButton, t.manga_ocr_download), findsOneWidget,
        reason: '整卷引擎不支持的平台也必须能下载识别模型（单框补扫用）');
    expect(find.text(t.manga_ocr_mobile_note), findsOneWidget,
        reason: '不支持整卷的平台需说明模型用于框选识别');
  });

  testWidgets(
      'cloud OCR subgroup: switch writes pref, key obscured, privacy note',
      (WidgetTester tester) async {
    final _FakeOcrService service = _FakeOcrService(ready: true);
    bool enabled = false;
    String apiKey = '';
    String model = '';
    await tester.pumpWidget(wrap(MangaOcrSettingsSection(
      service: service,
      mokuroPathGetter: () => '',
      mokuroPathSetter: (String _) async {},
      probeExternal: (String _) async => null,
      cloudEnabledGetter: () => enabled,
      cloudEnabledSetter: (bool v) async => enabled = v,
      cloudApiKeyGetter: () => apiKey,
      cloudApiKeySetter: (String v) async => apiKey = v,
      cloudModelGetter: () => model,
      cloudModelSetter: (String v) async => model = v,
    )));
    await tester.pumpAndSettle();

    // 子组齐全：开关（默认关）+ key + 模型 + 隐私说明。
    expect(find.text(t.manga_cloud_ocr_section), findsOneWidget);
    expect(find.text(t.manga_cloud_ocr_privacy), findsOneWidget,
        reason: '必须明示所选图片将发送至 Google API');
    final AdaptiveSettingsSwitchRow toggle =
        tester.widget<AdaptiveSettingsSwitchRow>(
            find.byKey(const ValueKey<String>('manga_cloud_ocr_switch')));
    expect(toggle.value, isFalse, reason: '云端识别默认关（红线）');

    // key 字段密文显示。
    final TextField keyField = tester.widget<TextField>(
        find.byKey(const ValueKey<String>('manga_cloud_ocr_api_key')));
    expect(keyField.obscureText, isTrue);

    // 开关写穿注入 setter。
    await tester.ensureVisible(
        find.byKey(const ValueKey<String>('manga_cloud_ocr_switch')));
    await tester
        .tap(find.byKey(const ValueKey<String>('manga_cloud_ocr_switch')));
    await tester.pumpAndSettle();
    expect(enabled, isTrue);

    // key/模型输入写穿。
    await tester.enterText(
        find.byKey(const ValueKey<String>('manga_cloud_ocr_api_key')),
        ' secret-key ');
    expect(apiKey, 'secret-key', reason: 'key 写入前 trim');
    await tester.enterText(
        find.byKey(const ValueKey<String>('manga_cloud_ocr_model')),
        'gemini-2.5-pro');
    expect(model, 'gemini-2.5-pro');
  });
}
