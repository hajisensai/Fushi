// `kind = asr` 的 host 任务按素材选档位（spec 2026-10-19 P0）：此前服务工厂无参、
// app 与服务端两处装配都恒为 cleanSpeech，视频转写走不到 Parakeet 滑窗。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_asr_core/asr_core.dart' as asr;
import 'package:fushi_engine/asr/asr_host_job_runner.dart';
import 'package:fushi_engine/sync/host_jobs/host_job_runner.dart';

class _FactoryCalled implements Exception {
  const _FactoryCalled();
}

/// 只记录 runner 交给服务的音频清单；start 抛 [_FactoryCalled] 结束本次 run。
class _RecordingService implements asr.AsrTranscriptionService {
  _RecordingService(this.jobDir);

  final Directory jobDir;
  List<String>? started;
  bool jobDirAsked = false;

  @override
  Future<asr.AsrTranscribePlan> plan({
    required asr.AsrLanguage language,
    required asr.AsrAccelerationPreference preference,
  }) async => asr.AsrTranscribePlan(
    language: language,
    variant: asr.AsrEncoderVariant.int8,
    expectedProvider: asr.OnnxExecutionProvider.cpu,
    modelStatus: const asr.AsrModelStatus(
      ready: true,
      diskBytes: 0,
      totalBytes: 0,
      obtainedBytes: 0,
    ),
  );

  @override
  Future<Directory> jobDirFor(
    List<String> audioPaths,
    asr.AsrLanguage language, {
    List<asr.AsrSegmentSpan>? segments,
  }) async {
    jobDirAsked = true;
    return jobDir;
  }

  @override
  Future<asr.AsrRunningTranscription> start({
    required List<String> audioPaths,
    required asr.AsrLanguage language,
    required asr.AsrEncoderVariant variant,
    required asr.AsrAccelerationPreference preference,
    List<asr.AsrSegmentSpan>? segments,
  }) async {
    started = audioPaths;
    throw const _FactoryCalled();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('asrAudioProfileForJob', () {
    test('explicit parameter wins (case-insensitive)', () {
      expect(
        asrAudioProfileForJob(explicit: 'MIXEDAUDIO', path: 'a.mp3'),
        asr.AsrAudioProfile.mixedAudio,
      );
      expect(
        asrAudioProfileForJob(explicit: 'cleanSpeech', path: 'a.mkv'),
        asr.AsrAudioProfile.cleanSpeech,
      );
    });

    test('video extension or library video defaults to mixedAudio', () {
      expect(
        asrAudioProfileForJob(path: '/v/ep01.MKV'),
        asr.AsrAudioProfile.mixedAudio,
      );
      expect(
        asrAudioProfileForJob(fromLibraryVideo: true, path: '/x/audio'),
        asr.AsrAudioProfile.mixedAudio,
      );
    });

    test('plain audio keeps cleanSpeech', () {
      expect(
        asrAudioProfileForJob(path: '/b/chapter01.m4b'),
        asr.AsrAudioProfile.cleanSpeech,
      );
      expect(
        asrAudioProfileForJob(explicit: 'bogus', path: '/b/c.mp3'),
        asr.AsrAudioProfile.cleanSpeech,
      );
    });

    test('parseAsrAudioProfile rejects unknown names', () {
      expect(parseAsrAudioProfile('nope'), isNull);
      expect(
        parseAsrAudioProfile(' mixedaudio '),
        asr.AsrAudioProfile.mixedAudio,
      );
    });
  });

  group('AsrHostJobRunner', () {
    late Directory tmp;

    setUp(() => tmp = Directory.systemTemp.createTempSync('asr_runner_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    Future<asr.AsrAudioProfile?> profileFor(
      Map<String, Object?> params, {
      String inputName = 'in',
    }) async {
      final Directory inputs = Directory('${tmp.path}/inputs')..createSync();
      final Directory outputs = Directory('${tmp.path}/outputs')..createSync();
      File('${inputs.path}/$inputName').writeAsBytesSync(<int>[0]);
      asr.AsrAudioProfile? seen;
      final AsrHostJobRunner runner = AsrHostJobRunner(
        serviceFactory: (asr.AsrAudioProfile profile) {
          seen = profile;
          throw const _FactoryCalled();
        },
        resolveVideoPath: (String id) async => '${inputs.path}/$inputName',
      );
      try {
        await runner.run(
          HostJobContext(
            jobId: 'j',
            params: params,
            inputsDir: inputs,
            outputsDir: outputs,
            onProgress: (double _, String? _) {},
            cancel: HostJobCancelToken(),
          ),
        );
      } on _FactoryCalled {
        // 只验证交给工厂的档位。
      }
      return seen;
    }

    test('library video goes to mixedAudio', () async {
      expect(
        await profileFor(<String, Object?>{'language': 'ja', 'videoId': '7'}),
        asr.AsrAudioProfile.mixedAudio,
      );
    });

    test('uploaded input honours explicit audioProfile', () async {
      expect(
        await profileFor(<String, Object?>{
          'language': 'ja',
          'input': 'audio',
          'audioProfile': 'mixedAudio',
        }, inputName: 'audio'),
        asr.AsrAudioProfile.mixedAudio,
      );
    });

    test('uploaded audio without a profile stays cleanSpeech', () async {
      expect(
        await profileFor(<String, Object?>{
          'language': 'ja',
          'input': 'audio',
        }, inputName: 'audio'),
        asr.AsrAudioProfile.cleanSpeech,
      );
    });

    test(
      'all inputs (uploaded + host-local) reach the service in name order; '
      'host-library inputs check for a pre-existing service job dir',
      () async {
        final Directory inputs = Directory('${tmp.path}/inputs')..createSync();
        final Directory outputs = Directory('${tmp.path}/outputs')
          ..createSync();
        File('${inputs.path}/001_b.mp3').writeAsBytesSync(<int>[1]);
        final File hostFile = File('${tmp.path}/library/a.mp3')
          ..createSync(recursive: true)
          ..writeAsBytesSync(<int>[0]);
        final Directory serviceJobDir = Directory('${tmp.path}/asr_job')
          ..createSync();
        final _RecordingService service = _RecordingService(serviceJobDir);
        final AsrHostJobRunner runner = AsrHostJobRunner(
          serviceFactory: (asr.AsrAudioProfile _) => service,
        );
        await expectLater(
          runner.run(
            HostJobContext(
              jobId: 'j',
              params: const <String, Object?>{'language': 'ja'},
              inputsDir: inputs,
              outputsDir: outputs,
              onProgress: (double _, String? _) {},
              cancel: HostJobCancelToken(),
              hostInputs: <String, String>{'000_a.mp3': hostFile.path},
            ),
          ),
          throwsA(isA<_FactoryCalled>()),
        );
        expect(service.started, <String>[
          hostFile.path,
          '${inputs.path}/001_b.mp3',
        ]);
        expect(service.jobDirAsked, isTrue);
      },
    );

    test('validateParams rejects an unknown audioProfile', () {
      final AsrHostJobRunner runner = AsrHostJobRunner(
        serviceFactory: (asr.AsrAudioProfile _) => throw UnimplementedError(),
      );
      expect(
        () => runner.validateParams(<String, Object?>{
          'language': 'ja',
          'audioProfile': 'loud',
        }),
        throwsFormatException,
      );
    });
  });
}
