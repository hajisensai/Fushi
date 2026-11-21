// 引擎探测并行化与「只探一个引擎」的短路。
//
// 以前五项探测依次 await：外部 mokuro（起进程，上限 15 秒）与配对主机（每台上限
// 4 秒）的耗时叠在本地引擎的结果前面，每次排 OCR 任务都要等它们的总和。各项互不
// 依赖，现在并行发出；调用方已确定只用一个引擎（显式偏好 / 本次点名）时只探它。
import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/manga/external_mokuro_runner.dart';
import 'package:fushi/src/media/manga/manga_ocr_engine_probe.dart';
import 'package:fushi/src/media/manga/manga_ocr_wizard_engines.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_engine.dart';
import 'package:fushi/src/media/manga/ocr/system_ocr_manga_service.dart';
import 'package:fushi/src/ocr/system_ocr_channel.dart';
import 'package:fushi/src/sync/interconnect_manga_ocr_client.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi_engine/ocr/ocr_types.dart' show OcrRgbaImage;
import 'package:fushi_engine/ocr/manga_ocr_service.dart';

const Duration _builtinDelay = Duration(seconds: 1);
const Duration _externalDelay = Duration(seconds: 3);
const Duration _systemDelay = Duration(seconds: 2);
const Duration _remoteDelay = Duration(seconds: 4);

class _SlowOcrService implements MangaOcrService {
  int statusCalls = 0;

  @override
  bool get isSupportedPlatform => true;

  @override
  Future<MangaOcrModelStatus> modelStatus() async {
    statusCalls += 1;
    await Future<void>.delayed(_builtinDelay);
    return const MangaOcrModelStatus(
      detectorReady: true,
      recognizerReady: true,
      diskBytes: 1,
      totalBytes: 1,
    );
  }

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

class _SlowExternalRunner extends ExternalMokuroRunner {
  int probeCalls = 0;

  @override
  Future<String?> probe() async {
    probeCalls += 1;
    await Future<void>.delayed(_externalDelay);
    return 'mokuro 0.2.0';
  }
}

class _SlowSystemOcr implements SystemOcrMangaRunner {
  @override
  Future<MokuroImage> recognizePagePixels(
    OcrRgbaImage image, {
    required String relativeUrl,
    required String language,
  }) => throw UnimplementedError();

  int availableCalls = 0;
  int statusCalls = 0;

  @override
  Future<bool> isAvailable() async {
    availableCalls += 1;
    await Future<void>.delayed(_systemDelay ~/ 2);
    return true;
  }

  @override
  Future<SystemOcrModelStatus> modelStatus({required String language}) async {
    statusCalls += 1;
    await Future<void>.delayed(_systemDelay ~/ 2);
    return SystemOcrModelStatus.ready;
  }

  @override
  Stream<MangaOcrVolumeEvent> ocrFolder({
    required String imageDirPath,
    String? volumeTitle,
    int startPage = 0,
    bool onlyMissing = true,
    required String language,
    MangaOcrPageFocus? focus,
  }) => const Stream<MangaOcrVolumeEvent>.empty();

  @override
  Future<MokuroImage> recognizePageBytes(
    Uint8List bytes, {
    required String relativeUrl,
    required String language,
  }) => throw UnimplementedError();
}

const MangaOcrRemoteTarget _capableTarget = MangaOcrRemoteTarget(
  baseUrl: 'http://192.168.1.2:1234',
  capability: MangaOcrRemoteCapability(supported: true, modelsReady: true),
);

class _SlowRemoteRunner implements MangaOcrRemoteRunner {
  int probeCalls = 0;

  @override
  Future<MangaOcrRemoteTarget?> probe() async {
    probeCalls += 1;
    await Future<void>.delayed(_remoteDelay);
    return _capableTarget;
  }

  @override
  Stream<MangaOcrRemoteEvent> run({
    required MangaOcrRemoteTarget target,
    required String imageDirPath,
    String? volumeTitle,
  }) => const Stream<MangaOcrRemoteEvent>.empty();
}

class _Rig {
  final _SlowOcrService service = _SlowOcrService();
  final _SlowExternalRunner external = _SlowExternalRunner();
  final _SlowSystemOcr systemOcr = _SlowSystemOcr();
  final _SlowRemoteRunner remote = _SlowRemoteRunner();

  MangaOcrWizardEngines get engines => MangaOcrWizardEngines(
    service: service,
    externalRunner: external,
    systemOcrRunner: systemOcr,
    remoteRunner: remote,
  );
}

/// 在假时钟里跑一次探测，返回（结果，耗时）。
(MangaOcrEngineAvailability, Duration) _timedProbe(
  FakeAsync async,
  _Rig rig, {
  MangaOcrEngineId? only,
}) {
  MangaOcrEngineAvailability? availability;
  Duration? finishedAt;
  probeMangaOcrEngines(rig.engines, only: only).then((
    MangaOcrEngineAvailability value,
  ) {
    availability = value;
    finishedAt = async.elapsed;
  });
  async.elapse(const Duration(minutes: 1));
  expect(availability, isNotNull, reason: '探测必须结束');
  return (availability!, finishedAt!);
}

void main() {
  test('各引擎并行探测：总耗时是最慢的一项，不是各项之和', () {
    fakeAsync((FakeAsync async) {
      final _Rig rig = _Rig();
      final (MangaOcrEngineAvailability availability, Duration elapsed) =
          _timedProbe(async, rig);

      // 串行是 1 + 3 + 2 + 4 = 10 秒；并行是最慢的配对主机那 4 秒。
      expect(elapsed, _remoteDelay);
      expect(availability.builtinReady, isTrue);
      expect(availability.externalReady, isTrue);
      expect(availability.systemOcrReady, isTrue);
      expect(availability.remoteUsable, isTrue);
      expect(rig.service.statusCalls, 1);
      expect(rig.external.probeCalls, 1);
      expect(rig.systemOcr.availableCalls, 1);
      expect(rig.systemOcr.statusCalls, 1);
      expect(rig.remote.probeCalls, 1);
    });
  });

  test('only：只探点名的那个引擎，其余不探、按未就绪报告', () {
    fakeAsync((FakeAsync async) {
      final _Rig rig = _Rig();
      final (MangaOcrEngineAvailability availability, Duration elapsed) =
          _timedProbe(async, rig, only: MangaOcrEngineId.localOnnx);

      expect(elapsed, _builtinDelay, reason: '不再等外部 CLI / 配对主机');
      expect(availability.isUsable(MangaOcrEngineId.localOnnx), isTrue);
      expect(rig.external.probeCalls, 0);
      expect(rig.systemOcr.availableCalls, 0);
      expect(rig.remote.probeCalls, 0);
      expect(availability.isUsable(MangaOcrEngineId.externalMokuro), isFalse);
      expect(availability.isUsable(MangaOcrEngineId.systemOcr), isFalse);
      expect(availability.isUsable(MangaOcrEngineId.pairedHost), isFalse);
      // 「给没给 runner」是结构事实，不随短路变化。
      expect(availability.externalOffered, isTrue);
      expect(availability.systemOcrOffered, isTrue);
      expect(availability.remoteOffered, isTrue);
    });
  });

  test('only 配对主机：探到的目标照常带出（任务要用它）', () {
    fakeAsync((FakeAsync async) {
      final _Rig rig = _Rig();
      final (MangaOcrEngineAvailability availability, Duration elapsed) =
          _timedProbe(async, rig, only: MangaOcrEngineId.pairedHost);

      expect(elapsed, _remoteDelay);
      expect(availability.remoteTarget, same(_capableTarget));
      expect(rig.service.statusCalls, 0);
      expect(rig.external.probeCalls, 0);
    });
  });

  test('only Lens：它不需要探测，一项都不探', () {
    fakeAsync((FakeAsync async) {
      final _Rig rig = _Rig();
      final (MangaOcrEngineAvailability availability, Duration elapsed) =
          _timedProbe(async, rig, only: MangaOcrEngineId.googleLens);

      expect(elapsed, Duration.zero);
      expect(availability.lensOffered, isFalse, reason: '这套装置没给 Lens runner');
      expect(rig.service.statusCalls, 0);
      expect(rig.remote.probeCalls, 0);
    });
  });

  test('mangaOcrProbeTargetFor：auto 全探，显式偏好只探它，本次点名优先', () {
    expect(mangaOcrProbeTargetFor(MangaOcrEnginePreference.auto), isNull);
    expect(
      mangaOcrProbeTargetFor(MangaOcrEnginePreference.systemOcr),
      MangaOcrEngineId.systemOcr,
    );
    expect(
      mangaOcrProbeTargetFor(
        MangaOcrEnginePreference.auto,
        engineChoice: MangaOcrEngineId.pairedHost,
      ),
      MangaOcrEngineId.pairedHost,
    );
    expect(
      mangaOcrProbeTargetFor(
        MangaOcrEnginePreference.localOnnx,
        engineChoice: MangaOcrEngineId.googleLens,
      ),
      MangaOcrEngineId.googleLens,
    );
  });
}
