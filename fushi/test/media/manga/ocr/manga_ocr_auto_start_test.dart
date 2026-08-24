import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/manga_ocr_wizard_engines.dart';
import 'package:fushi/src/media/manga/ocr/google_lens_ocr_service.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_auto_start.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_engine.dart';
import 'package:fushi/src/ocr/manga_ocr_service.dart';
import 'package:fushi/src/sync/interconnect_manga_ocr_client.dart';

/// 「点一下就识别」这条路不弹引擎选择框，因此**引擎选择的每一条分支都必须在这里
/// 说清楚**——尤其是它绝不悄悄替用户换一个能跑的引擎。一旦回退发生，Google Lens
/// 的上传边界就会在用户毫不知情时被跨过去。
class _FakeOcrService implements MangaOcrService {
  _FakeOcrService({this.supported = true, this.ready = false});

  final bool supported;
  final bool ready;

  @override
  bool get isSupportedPlatform => supported;

  @override
  Future<MangaOcrModelStatus> modelStatus() async => MangaOcrModelStatus(
        detectorReady: ready,
        recognizerReady: ready,
        diskBytes: 0,
        totalBytes: 100,
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
  }) =>
      const Stream<MangaOcrVolumeEvent>.empty();
}

class _FakeLensRunner implements GoogleLensMangaOcrRunner {
  @override
  Stream<MangaOcrVolumeEvent> ocrFolder({
    required String imageDirPath,
    String? volumeTitle,
    int startPage = 0,
    bool onlyMissing = true,
    required String language,
  }) =>
      const Stream<MangaOcrVolumeEvent>.empty();

  @override
  Future<void> clearCache(String imageDirPath) async {}
}

class _FakeRemoteRunner implements MangaOcrRemoteRunner {
  _FakeRemoteRunner(this.target);

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

MangaOcrWizardEngines engines({
  bool localReady = false,
  bool localSupported = true,
  bool lens = true,
  MangaOcrRemoteTarget? remoteTarget,
  bool hasRemoteRunner = false,
  String? preference,
}) =>
    MangaOcrWizardEngines(
      service: _FakeOcrService(supported: localSupported, ready: localReady),
      lensRunner: lens ? _FakeLensRunner() : null,
      remoteRunner:
          hasRemoteRunner ? _FakeRemoteRunner(remoteTarget) : null,
      initialEnginePreference: preference,
    );

void main() {
  late BuildContext ctx;

  Future<void> pumpContext(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(builder: (BuildContext c) {
          ctx = c;
          return const SizedBox.shrink();
        }),
      ),
    );
  }

  Future<MangaOcrAutoStartResult> start(
    MangaOcrWizardEngines e, {
    Future<bool> Function(BuildContext)? gate,
  }) =>
      startMangaOcrWithPreferredEngine(
        context: ctx,
        bookKey: 'book',
        imageDirPath: '/tmp/manga',
        startPage: 7,
        lensLanguage: 'ja',
        enginesOverride: e,
        lensDisclosureGate: gate ?? (BuildContext _) async => true,
      );

  testWidgets('偏好 Google Lens：同意上传后任务起来，引擎就是用户选的那个',
      (WidgetTester tester) async {
    await pumpContext(tester);
    final MangaOcrAutoStartResult result = await start(
      engines(preference: MangaOcrEnginePreference.googleLens.key),
    );
    expect(result.started, isTrue);
    expect(result.engine, MangaOcrEngineId.googleLens);
    expect(result.job!.bookKey, 'book');
  });

  testWidgets('偏好 Google Lens：用户在上传告知里取消 → cancelled，不报错',
      (WidgetTester tester) async {
    await pumpContext(tester);
    final MangaOcrAutoStartResult result = await start(
      engines(preference: MangaOcrEnginePreference.googleLens.key),
      gate: (BuildContext _) async => false,
    );
    expect(result.started, isFalse);
    expect(result.cancelled, isTrue);
    expect(result.unavailableReason, isNull,
        reason: '用户自己取消不是错误，多弹一句报错等于骂他一遍');
  });

  testWidgets('偏好本地 ONNX 但模型没下：明确说不可用，不启动注定失败的任务',
      (WidgetTester tester) async {
    await pumpContext(tester);
    final MangaOcrAutoStartResult result = await start(
      engines(preference: MangaOcrEnginePreference.localOnnx.key),
    );
    expect(result.started, isFalse);
    expect(result.cancelled, isFalse);
    expect(result.unavailableReason, isNotNull);
    expect(result.engine, MangaOcrEngineId.localOnnx,
        reason: '要能说出「本想用哪个引擎」，否则提示无从落地');
  });

  testWidgets('偏好本地 ONNX 且模型就绪：直接跑本地，不碰网络',
      (WidgetTester tester) async {
    await pumpContext(tester);
    final MangaOcrAutoStartResult result = await start(
      engines(
        localReady: true,
        preference: MangaOcrEnginePreference.localOnnx.key,
      ),
      gate: (BuildContext _) async =>
          throw StateError('本地引擎不该碰 Lens 上传告知'),
    );
    expect(result.started, isTrue);
    expect(result.engine, MangaOcrEngineId.localOnnx);
  });

  testWidgets('auto 且无离线引擎就绪：不回退 Lens（auto 的契约就是不自作主张上传）',
      (WidgetTester tester) async {
    await pumpContext(tester);
    final MangaOcrAutoStartResult result = await start(
      engines(preference: MangaOcrEnginePreference.auto.key),
      gate: (BuildContext _) async =>
          throw StateError('auto 绝不能走到 Lens 上传告知'),
    );
    expect(result.started, isFalse);
    expect(result.engine, isNull);
    expect(result.unavailableReason, isNotNull);
  });

  testWidgets('auto 且本地就绪：选本地', (WidgetTester tester) async {
    await pumpContext(tester);
    final MangaOcrAutoStartResult result = await start(
      engines(localReady: true, preference: MangaOcrEnginePreference.auto.key),
    );
    expect(result.started, isTrue);
    expect(result.engine, MangaOcrEngineId.localOnnx);
  });

  testWidgets('偏好已配对主机但探测不到 host：不可用，不静默换引擎',
      (WidgetTester tester) async {
    await pumpContext(tester);
    final MangaOcrAutoStartResult result = await start(
      engines(
        hasRemoteRunner: true,
        preference: MangaOcrEnginePreference.pairedHost.key,
      ),
    );
    expect(result.started, isFalse);
    expect(result.engine, MangaOcrEngineId.pairedHost);
    expect(result.unavailableReason, isNotNull);
  });

  testWidgets('偏好缺失时按出厂默认解析，不按 auto', (WidgetTester tester) async {
    // BUG-1780 的教训：出厂默认与回退值分叉过一次，结果是守卫恒绿、真实回归
    // 一路进 develop。这条把「没有偏好时用哪个」钉死在唯一真相源上。
    await pumpContext(tester);
    final MangaOcrAutoStartResult result = await start(engines());
    expect(
      result.engine,
      kDefaultMangaOcrEnginePreference.explicitEngine,
      reason: '偏好为空必须落到 kDefaultMangaOcrEnginePreference',
    );
  });

  testWidgets('能力探测：本地平台不支持时 localOnnx 既不 supported 也不 ready',
      (WidgetTester tester) async {
    await pumpContext(tester);
    final List<MangaOcrEngineCapability> caps =
        await probeMangaOcrCapabilities(engines(localSupported: false));
    final MangaOcrEngineCapability local = caps
        .firstWhere((MangaOcrEngineCapability c) =>
            c.id == MangaOcrEngineId.localOnnx);
    expect(local.supported, isFalse);
    expect(local.available, isFalse);
  });
}
