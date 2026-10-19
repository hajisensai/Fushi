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
