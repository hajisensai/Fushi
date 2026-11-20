// BUG：统一引擎探测漏了系统 OCR（Apple Vision / Android ML Kit）。
//
// `resolveMangaOcrEngine` 的 auto 回退顺序里排着 systemOcr，但
// `MangaOcrEngineAvailability.capabilities` 从不列它，于是 auto 永远落不到它上：
// Apple 上没下本地模型时，「装完即用」的 Vision 只有手动选才用得上。反过来
// `isUsable(systemOcr)` 恒真，显式选了它的阅读器 / 作品页 / 下载钩子任务不经可用
// 性校验，没有原生侧的平台（Windows / Linux）会直接排一个必失败的任务。
import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/manga/manga_ocr_engine_probe.dart';
import 'package:fushi/src/media/manga/manga_ocr_wizard_engines.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_engine.dart';
import 'package:fushi/src/media/manga/ocr/system_ocr_manga_service.dart';
import 'package:fushi/src/ocr/system_ocr_channel.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi_engine/ocr/manga_ocr_service.dart';

class _FakeOcrService implements MangaOcrService {
  _FakeOcrService({required this.modelsReady});

  final bool modelsReady;

  @override
  bool get isSupportedPlatform => true;

  @override
  Future<MangaOcrModelStatus> modelStatus() async => MangaOcrModelStatus(
    detectorReady: modelsReady,
    recognizerReady: modelsReady,
    diskBytes: modelsReady ? 1 : 0,
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

class _FakeSystemOcr implements SystemOcrMangaRunner {
  _FakeSystemOcr({
    this.available = true,
    this.throws = false,
    this.hangs = false,
    this.status = SystemOcrModelStatus.ready,
    this.statusThrows = false,
    this.statusHangs = false,
  });

  final bool available;
  final bool throws;

  /// [modelStatus] 的回答（BUG-4705）。
  final SystemOcrModelStatus status;
  final bool statusThrows;
  final bool statusHangs;
  final List<String> statusLanguages = <String>[];

  /// 模拟原生侧永不应答（平台通道回复丢失）。
  final bool hangs;

  @override
  Future<bool> isAvailable() async {
    if (hangs) return Completer<bool>().future;
    if (throws) throw StateError('channel exploded');
    return available;
  }

  @override
  Future<SystemOcrModelStatus> modelStatus({required String language}) async {
    statusLanguages.add(language);
    if (statusHangs) return Completer<SystemOcrModelStatus>().future;
    if (statusThrows) throw StateError('modelStatus exploded');
    return status;
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

MangaOcrWizardEngines _engines({
  bool modelsReady = false,
  SystemOcrMangaRunner? systemOcr,
  String? lensLanguage,
}) => MangaOcrWizardEngines(
  service: _FakeOcrService(modelsReady: modelsReady),
  systemOcrRunner: systemOcr,
  initialLensLanguage: lensLanguage,
);

MangaOcrEngineId? _resolve(
  MangaOcrEngineAvailability availability,
  MangaOcrEnginePreference preference,
) => resolveMangaOcrEngine(
  preference: preference,
  hasExistingMetadata: false,
  capabilities: availability.capabilities,
);

void main() {
  test('auto 在本地模型未就绪、系统 OCR 可用时落到系统 OCR', () async {
    final MangaOcrEngineAvailability availability = await probeMangaOcrEngines(
      _engines(systemOcr: _FakeSystemOcr()),
    );

    expect(availability.systemOcrOffered, isTrue);
    expect(availability.systemOcrReady, isTrue);
    expect(
      _resolve(availability, MangaOcrEnginePreference.auto),
      MangaOcrEngineId.systemOcr,
    );
    expect(availability.isUsable(MangaOcrEngineId.systemOcr), isTrue);
    // 后台（下载完成钩子）读同一份判据：零上传、零下载，可以自动跑。
    expect(
      resolveBackgroundMangaOcrEngine(
        preference: MangaOcrEnginePreference.auto,
        availability: availability,
      ),
      MangaOcrEngineId.systemOcr,
    );
  });

  test('本地模型就绪时 auto 仍优先本地模型（质量优先）', () async {
    final MangaOcrEngineAvailability availability = await probeMangaOcrEngines(
      _engines(modelsReady: true, systemOcr: _FakeSystemOcr()),
    );

    expect(
      _resolve(availability, MangaOcrEnginePreference.auto),
      MangaOcrEngineId.localOnnx,
    );
  });

  test('原生侧回「不可用」时系统 OCR 不算可用，显式偏好也不放行', () async {
    final MangaOcrEngineAvailability availability = await probeMangaOcrEngines(
      _engines(systemOcr: _FakeSystemOcr(available: false)),
    );

    expect(availability.systemOcrOffered, isTrue);
    expect(availability.systemOcrReady, isFalse);
    expect(_resolve(availability, MangaOcrEnginePreference.auto), isNull);
    expect(availability.isUsable(MangaOcrEngineId.systemOcr), isFalse);
    expect(
      resolveBackgroundMangaOcrEngine(
        preference: MangaOcrEnginePreference.systemOcr,
        availability: availability,
      ),
      isNull,
    );
  });

  test('探测抛异常按不可用处理，不拖垮整次探测', () async {
    final MangaOcrEngineAvailability availability = await probeMangaOcrEngines(
      _engines(modelsReady: true, systemOcr: _FakeSystemOcr(throws: true)),
    );

    expect(availability.systemOcrReady, isFalse);
    expect(availability.isUsable(MangaOcrEngineId.systemOcr), isFalse);
    expect(availability.builtinReady, isTrue);
  });

  test('原生侧不应答时超时按不可用，其余引擎照常出结果', () {
    fakeAsync((FakeAsync async) {
      MangaOcrEngineAvailability? availability;
      probeMangaOcrEngines(
        _engines(modelsReady: true, systemOcr: _FakeSystemOcr(hangs: true)),
      ).then((MangaOcrEngineAvailability value) => availability = value);

      async.elapse(kSystemOcrProbeTimeout - const Duration(milliseconds: 1));
      expect(availability, isNull);
      async.elapse(const Duration(milliseconds: 2));

      expect(availability, isNotNull);
      expect(availability!.systemOcrReady, isFalse);
      expect(availability!.builtinReady, isTrue);
    });
  });

  group('BUG-4705：没有 Play 服务时 auto 不选系统 OCR，选项与显式选择保留', () {
    for (final SystemOcrModelStatus absent in <SystemOcrModelStatus>[
      SystemOcrModelStatus.playServicesMissing,
      SystemOcrModelStatus.playServicesInvalid,
      SystemOcrModelStatus.playServicesUnavailable,
    ]) {
      test('$absent', () async {
        final _FakeSystemOcr runner = _FakeSystemOcr(status: absent);
        final MangaOcrEngineAvailability availability =
            await probeMangaOcrEngines(
              _engines(systemOcr: runner, lensLanguage: 'zh'),
            );

        expect(runner.statusLanguages, <String>['zh'], reason: '按 OCR 语言查');
        expect(availability.systemOcrPlayServicesAbsent, isTrue);
        expect(availability.systemOcrOffered, isTrue, reason: '选项保留');
        expect(availability.systemOcrReady, isTrue, reason: '选项不置灰');
        expect(_resolve(availability, MangaOcrEnginePreference.auto), isNull);
        expect(
          resolveBackgroundMangaOcrEngine(
            preference: MangaOcrEnginePreference.auto,
            availability: availability,
          ),
          isNull,
        );
        // 显式选了它仍能跑：失败后由引导弹窗说明，而不是悄悄不跑。
        expect(availability.isUsable(MangaOcrEngineId.systemOcr), isTrue);
        expect(
          _resolve(availability, MangaOcrEnginePreference.systemOcr),
          MangaOcrEngineId.systemOcr,
        );
      });
    }

    test('能修好的 Play 服务问题 / 缺模型不拦 auto', () async {
      for (final SystemOcrModelStatus status in <SystemOcrModelStatus>[
        SystemOcrModelStatus.ready,
        SystemOcrModelStatus.missing,
        SystemOcrModelStatus.playServicesDisabled,
        SystemOcrModelStatus.playServicesUpdateRequired,
        SystemOcrModelStatus.playServicesUpdating,
      ]) {
        final MangaOcrEngineAvailability availability =
            await probeMangaOcrEngines(
              _engines(systemOcr: _FakeSystemOcr(status: status)),
            );
        expect(availability.systemOcrPlayServicesAbsent, isFalse);
        expect(
          _resolve(availability, MangaOcrEnginePreference.auto),
          MangaOcrEngineId.systemOcr,
          reason: '$status',
        );
      }
    });

    test('有本地模型时仍是本地模型，没有 Play 服务也不影响', () async {
      final MangaOcrEngineAvailability availability =
          await probeMangaOcrEngines(
            _engines(
              modelsReady: true,
              systemOcr: _FakeSystemOcr(
                status: SystemOcrModelStatus.playServicesMissing,
              ),
            ),
          );
      expect(
        _resolve(availability, MangaOcrEnginePreference.auto),
        MangaOcrEngineId.localOnnx,
      );
    });

    test('平台本就不可用时不再多问一次 modelStatus', () async {
      final _FakeSystemOcr runner = _FakeSystemOcr(available: false);
      await probeMangaOcrEngines(_engines(systemOcr: runner));
      expect(runner.statusLanguages, isEmpty);
    });

    test('modelStatus 抛异常按「不确定」处理，不拦 auto；未配语言按 ja 查', () async {
      final _FakeSystemOcr runner = _FakeSystemOcr(statusThrows: true);
      final MangaOcrEngineAvailability availability =
          await probeMangaOcrEngines(_engines(systemOcr: runner));
      expect(runner.statusLanguages, <String>['ja']);
      expect(availability.systemOcrPlayServicesAbsent, isFalse);
      expect(
        _resolve(availability, MangaOcrEnginePreference.auto),
        MangaOcrEngineId.systemOcr,
      );
    });

    test('modelStatus 不应答时超时按「不确定」，不吊死整次探测', () {
      fakeAsync((FakeAsync async) {
        MangaOcrEngineAvailability? availability;
        probeMangaOcrEngines(
          _engines(systemOcr: _FakeSystemOcr(statusHangs: true)),
        ).then((MangaOcrEngineAvailability value) => availability = value);
        async.elapse(kSystemOcrProbeTimeout + const Duration(milliseconds: 1));
        expect(availability, isNotNull);
        expect(availability!.systemOcrPlayServicesAbsent, isFalse);
      });
    });
  });

  test('没给 runner（隔离入口）时系统 OCR 既不提供也不可用', () async {
    final MangaOcrEngineAvailability availability = await probeMangaOcrEngines(
      _engines(),
    );

    expect(availability.systemOcrOffered, isFalse);
    expect(availability.isUsable(MangaOcrEngineId.systemOcr), isFalse);
  });
}
