import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_asr_core/asr_core.dart' as asr;
import 'package:fushi_engine/media/video/subtitle/asr_proofread/moss_provisioning.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/moss_video_subtitle_recognizer.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/video_subtitle_recognizer.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/video_subtitle_recognizer_factory.dart';
import 'package:path/path.dart' as p;

import '../../../../helpers/fake_asr_transcription.dart';

const asr.MossCudaAvailability _cudaOk = asr.MossCudaAvailability(
  available: true,
  reason: null,
  gpus: <asr.NvidiaGpuInfo>[],
);
const asr.MossCudaAvailability _cudaNo = asr.MossCudaAvailability(
  available: false,
  reason: 'NVIDIA 驱动 550.1 低于要求（R580 及以上）',
  gpus: <asr.NvidiaGpuInfo>[],
);

/// 环境探测替身；没给的探测一调用就失败（断言「这条路不该去探」）。
MossHostProbes _probes({
  asr.AudioCppPlatform? platform,
  asr.MossCudaAvailability? cuda,
  bool? linuxGpu,
}) => MossHostProbes(
  platform: () => platform,
  cuda: (asr.AudioCppPlatform _) async =>
      cuda ?? (throw StateError('cuda probe not expected')),
  linuxGpu: () async => linuxGpu == null
      ? throw StateError('gpu probe not expected')
      : MossLinuxGpuProbe(found: linuxGpu, detail: 'fake'),
);

void main() {
  late Directory tmp;
  late asr.AsrSupportRootResolver previousRoot;
  late FakeAsrTranscriptionService service;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('vsrf_');
    previousRoot = asr.asrSupportRootResolver;
    asr.asrSupportRootResolver = () async => tmp;
    service = FakeAsrTranscriptionService(
      jobDir: Directory(p.join(tmp.path, 'asr')),
      text: (asr.AsrSegmentSpan s) => 'x',
    );
  });
  tearDown(() {
    asr.asrSupportRootResolver = previousRoot;
    tmp.deleteSync(recursive: true);
  });

  /// 本机已有的 CLI / 权重（覆盖路径），文件存在即可。
  (String, String) localMoss() {
    final File cli = File(p.join(tmp.path, 'bin', 'audiocpp_cli.exe'))
      ..createSync(recursive: true);
    final File model = File(p.join(tmp.path, 'm', 'moss.gguf'))
      ..createSync(recursive: true);
    return (cli.path, model.path);
  }

  Future<VideoSubtitleRecognizerChoice> resolve(
    VideoSubtitleSegmenterMode mode,
    MossHostProbes probes, {
    MossBackendPreference backend = MossBackendPreference.auto,
    bool local = false,
  }) {
    final (String, String)? paths = local ? localMoss() : null;
    return resolveVideoSubtitleRecognizer(
      mode: mode,
      mossBackend: backend,
      serviceFactory: (asr.AsrAudioProfile profile) => service,
      startProcess: FakeProcessStarter(
        (String e, List<String> a, FakeProcess proc) => proc.exit(1),
      ).call,
      probes: probes,
      mossCliPath: paths?.$1,
      mossModelPath: paths?.$2,
    );
  }

  group('decideMossBackend 平台矩阵', () {
    Future<MossBackendDecision> decide(
      MossBackendPreference pref,
      MossHostProbes probes,
    ) => decideMossBackend(pref, probes: probes);

    test('auto：Windows 达 CUDA 门槛 → cuda；不达 → 不用（原因来自探测）', () async {
      final MossBackendDecision ok = await decide(
        MossBackendPreference.auto,
        _probes(platform: asr.AudioCppPlatform.windowsX64, cuda: _cudaOk),
      );
      expect(ok.backend, asr.AudioCppBackend.cuda);
      expect(ok.pack!.directoryName, contains('windows-x64-cuda'));
      final MossBackendDecision no = await decide(
        MossBackendPreference.auto,
        _probes(platform: asr.AudioCppPlatform.windowsX64, cuda: _cudaNo),
      );
      expect(no.ok, isFalse);
      expect(no.code, MossUnavailableCode.cudaUnavailable);
      expect(no.reason, contains('R580'));
    });

    test('auto：Linux 探到 GPU → vulkan（不探 CUDA）；没探到 → noGpu', () async {
      final MossBackendDecision ok = await decide(
        MossBackendPreference.auto,
        _probes(platform: asr.AudioCppPlatform.linuxX64, linuxGpu: true),
      );
      expect(ok.backend, asr.AudioCppBackend.vulkan);
      expect(ok.pack!.directoryName, contains('linux-x64-vulkan'));
      final MossBackendDecision no = await decide(
        MossBackendPreference.auto,
        _probes(platform: asr.AudioCppPlatform.linuxX64, linuxGpu: false),
      );
      expect(no.code, MossUnavailableCode.noGpu);
    });

    test('cuda：Linux 没有 CLI（不探）；Windows 照样过 CUDA 门槛', () async {
      final MossBackendDecision linux = await decide(
        MossBackendPreference.cuda,
        _probes(platform: asr.AudioCppPlatform.linuxX64),
      );
      expect(linux.code, MossUnavailableCode.noRuntimeForBackend);
      expect(linux.reason, contains('vulkan'));
      final MossBackendDecision win = await decide(
        MossBackendPreference.cuda,
        _probes(platform: asr.AudioCppPlatform.windowsX64, cuda: _cudaNo),
      );
      expect(win.code, MossUnavailableCode.cudaUnavailable);
    });

    test('显式 vulkan / cpu：两平台直接用，不探显卡', () async {
      for (final asr.AudioCppPlatform platform in asr.AudioCppPlatform.values) {
        expect(
          (await decide(
            MossBackendPreference.vulkan,
            _probes(platform: platform),
          )).backend,
          asr.AudioCppBackend.vulkan,
        );
        expect(
          (await decide(
            MossBackendPreference.cpu,
            _probes(platform: platform),
          )).backend,
          asr.AudioCppBackend.cpu,
        );
      }
    });

    test('其它平台：一律不用', () async {
      for (final MossBackendPreference pref in MossBackendPreference.values) {
        final MossBackendDecision d = await decide(pref, _probes());
        expect(
          d.code,
          MossUnavailableCode.unsupportedPlatform,
          reason: '$pref',
        );
      }
    });
  });

  group('resolveVideoSubtitleRecognizer', () {
    test('window：滑窗、没有「没用上 MOSS」的原因，也不探环境', () async {
      final VideoSubtitleRecognizerChoice c = await resolve(
        VideoSubtitleSegmenterMode.window,
        _probes(),
      );
      expect(c.recognizer, isA<SlidingWindowVideoSubtitleRecognizer>());
      expect(c.usesMoss, isFalse);
      expect(c.mossUnavailableReason, isNull);
    });

    test('auto + 驱动不达标：退回滑窗并给原因；moss：抛错不降级', () async {
      final MossHostProbes probes = _probes(
        platform: asr.AudioCppPlatform.windowsX64,
        cuda: _cudaNo,
      );
      final VideoSubtitleRecognizerChoice c = await resolve(
        VideoSubtitleSegmenterMode.auto,
        probes,
      );
      expect(c.recognizer, isA<SlidingWindowVideoSubtitleRecognizer>());
      expect(c.mossUnavailableCode, MossUnavailableCode.cudaUnavailable);
      expect(c.mossUnavailableReason, contains('R580'));
      await expectLater(
        resolve(VideoSubtitleSegmenterMode.moss, probes),
        throwsA(isA<VideoSubtitleRecognizeFailure>()),
      );
    });

    test('判定能用但运行库没装：auto 退回（runtimeMissing），不下载', () async {
      final VideoSubtitleRecognizerChoice c = await resolve(
        VideoSubtitleSegmenterMode.auto,
        _probes(platform: asr.AudioCppPlatform.windowsX64, cuda: _cudaOk),
      );
      expect(c.mossUnavailableCode, MossUnavailableCode.runtimeMissing);
      expect(Directory(p.join(tmp.path, 'asr_runtimes')).existsSync(), isFalse);
    });

    test('运行库已装、权重没下：modelMissing', () async {
      final asr.AudioCppRuntimePack pack = asr.audioCppRuntimePackFor(
        asr.AudioCppPlatform.linuxX64,
        asr.AudioCppBackend.vulkan,
      )!;
      final Directory dir = Directory(
        p.join(tmp.path, 'asr_runtimes', pack.directoryName),
      )..createSync(recursive: true);
      File(p.join(dir.path, pack.executableName)).writeAsStringSync('');
      File(p.join(dir.path, '.audiocpp-installed.json')).writeAsStringSync(
        jsonEncode(<String, Object?>{
          'version': asr.kAudioCppVersion,
          'archives': <String>[
            for (final asr.AudioCppDownloadFile a in pack.archives) a.sha256,
          ],
        }),
      );
      final VideoSubtitleRecognizerChoice c = await resolve(
        VideoSubtitleSegmenterMode.auto,
        _probes(platform: asr.AudioCppPlatform.linuxX64, linuxGpu: true),
      );
      expect(c.mossUnavailableCode, MossUnavailableCode.modelMissing);

      final MossProvisionStatus status = await mossProvisionStatus(
        probes: _probes(
          platform: asr.AudioCppPlatform.linuxX64,
          linuxGpu: true,
        ),
      );
      expect(status.supported, isTrue);
      expect(status.runtime!.ready, isTrue);
      expect(status.model!.ready, isFalse);
      expect(status.ready, isFalse);
      expect(status.remainingBytes, asr.kMossModelFile.expectedBytes);
    });

    test('本机已有 CLI + 权重（覆盖路径）：用 MOSS，后端按判定', () async {
      final VideoSubtitleRecognizerChoice c = await resolve(
        VideoSubtitleSegmenterMode.moss,
        _probes(platform: asr.AudioCppPlatform.windowsX64, cuda: _cudaOk),
        local: true,
      );
      expect(c.recognizer, isA<MossVideoSubtitleRecognizer>());
      expect(c.recognizer.id, kMossVideoSubtitleRecognizerId);
      expect(c.mossBackend, asr.AudioCppBackend.cuda);
      expect(c.mossUnavailableReason, isNull);
      final MossVideoSubtitleRecognizer moss =
          c.recognizer as MossVideoSubtitleRecognizer;
      expect(moss.moss.backend, asr.AudioCppBackend.cuda);
      expect(moss.moss.modelPath, endsWith('moss.gguf'));

      final VideoSubtitleRecognizerChoice vk = await resolve(
        VideoSubtitleSegmenterMode.auto,
        _probes(platform: asr.AudioCppPlatform.windowsX64),
        backend: MossBackendPreference.vulkan,
        local: true,
      );
      expect(vk.mossBackend, asr.AudioCppBackend.vulkan);
    });

    test('覆盖路径不存在：当没装处理', () async {
      final VideoSubtitleRecognizerChoice c =
          await resolveVideoSubtitleRecognizer(
            mode: VideoSubtitleSegmenterMode.auto,
            serviceFactory: (asr.AsrAudioProfile profile) => service,
            probes: _probes(
              platform: asr.AudioCppPlatform.windowsX64,
              cuda: _cudaOk,
            ),
            mossCliPath: p.join(tmp.path, 'nope.exe'),
            mossModelPath: p.join(tmp.path, 'nope.gguf'),
          );
      expect(c.mossUnavailableCode, MossUnavailableCode.runtimeMissing);
    });
  });

  group('Linux GPU 探测', () {
    FakeProcessStarter noNvidia() => FakeProcessStarter(
      (String e, List<String> a, FakeProcess proc) =>
          proc.exit(127, stderrText: 'nvidia-smi: not found'),
    );

    test('nvidia-smi 列出卡 → 有（不管驱动版本）', () async {
      final MossLinuxGpuProbe r = await probeLinuxGpuForVulkan(
        startProcess: FakeProcessStarter((
          String e,
          List<String> a,
          FakeProcess proc,
        ) {
          proc
            ..stdoutWrite('470.10, 8.6\n')
            ..exit(0);
        }).call,
        devDri: Directory(p.join(tmp.path, 'no_dri')),
      );
      expect(r.found, isTrue);
    });

    test('没有 N 卡：要渲染节点 + 非 lavapipe 的 ICD 才算有', () async {
      final Directory dri = Directory(p.join(tmp.path, 'dri'))..createSync();
      final Directory icd = Directory(p.join(tmp.path, 'icd'))..createSync();
      Future<MossLinuxGpuProbe> probe() => probeLinuxGpuForVulkan(
        startProcess: noNvidia().call,
        devDri: dri,
        icdDirs: <String>[icd.path],
      );
      expect((await probe()).found, isFalse);
      File(p.join(dri.path, 'renderD128')).writeAsStringSync('');
      File(p.join(icd.path, 'lvp_icd.x86_64.json')).writeAsStringSync('{}');
      expect((await probe()).found, isFalse, reason: 'lavapipe 是 CPU 软渲染');
      File(p.join(icd.path, 'radeon_icd.x86_64.json')).writeAsStringSync('{}');
      final MossLinuxGpuProbe r = await probe();
      expect(r.found, isTrue);
      expect(r.detail, contains('radeon_icd'));
    });
  });

  test('ensureMossProvisioned：判定不能用时直接报错，不发请求', () async {
    await expectLater(
      ensureMossProvisioned(
        backend: MossBackendPreference.cuda,
        probes: _probes(platform: asr.AudioCppPlatform.linuxX64),
      ).toList(),
      throwsA(isA<StateError>()),
    );
  });
}
