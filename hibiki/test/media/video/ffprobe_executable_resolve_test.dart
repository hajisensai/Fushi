import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/ffmpeg_backend.dart';

/// TODO-1045：ffprobe 可执行解析优先级镜像 ffmpeg——HIBIKI_FFPROBE 覆盖 >
/// 程序旁捆绑 ffprobe > 系统 PATH；以及 bundled 跑不起来回退 PATH 的 CLI 逻辑。
void main() {
  group('resolveFfprobeExecutableFrom 优先级', () {
    test('HIBIKI_FFPROBE 覆盖最高优先', () {
      expect(
        resolveFfprobeExecutableFrom(
            override: '/opt/ff/ffprobe', bundledPath: '/app/ffprobe'),
        '/opt/ff/ffprobe',
      );
    });

    test('无覆盖时用程序旁捆绑 ffprobe（空白覆盖视同无覆盖）', () {
      expect(
        resolveFfprobeExecutableFrom(
            override: null, bundledPath: '/app/ffprobe'),
        '/app/ffprobe',
      );
      expect(
        resolveFfprobeExecutableFrom(
            override: '   ', bundledPath: r'C:\Hibiki\ffprobe.exe'),
        r'C:\Hibiki\ffprobe.exe',
      );
    });

    test('无覆盖无捆绑回退系统 PATH 的 ffprobe', () {
      expect(
        resolveFfprobeExecutableFrom(override: null, bundledPath: null),
        'ffprobe',
      );
      expect(
        resolveFfprobeExecutableFrom(override: '', bundledPath: ''),
        'ffprobe',
      );
    });
  });

  group('runCliFfprobeForTesting bundled fallback', () {
    test('bundled ffprobe launch failure falls back to PATH ffprobe', () async {
      final List<String> calls = <String>[];
      final FfmpegRunResult result = await runCliFfprobeForTesting(
        override: null,
        bundledPath: r'C:\App\Hibiki\ffprobe.exe',
        args: <String>['-show_format', 'x.m4b'],
        timeout: const Duration(seconds: 1),
        runner: (String executable, List<String> args, Duration timeout) async {
          calls.add(executable);
          if (executable.endsWith(r'Hibiki\ffprobe.exe')) {
            throw ProcessException(executable, args, 'launch failed', 193);
          }
          return const FfmpegRunResult(
            returnCode: 0,
            output: '{"format":{"tags":{"title":"ok"}}}',
          );
        },
      );

      expect(result.isSuccess, isTrue);
      expect(result.output, contains('"title":"ok"'));
      expect(calls, <String>[r'C:\App\Hibiki\ffprobe.exe', 'ffprobe']);
      expect(result.executable, 'ffprobe');
      expect(result.fallbackReason, contains('launch failed'));
    });

    test('successful bundled ffprobe does NOT fall back', () async {
      final List<String> calls = <String>[];
      final FfmpegRunResult result = await runCliFfprobeForTesting(
        override: null,
        bundledPath: '/app/ffprobe',
        args: <String>['-show_format', 'x.m4b'],
        timeout: const Duration(seconds: 1),
        runner: (String executable, List<String> args, Duration timeout) async {
          calls.add(executable);
          return const FfmpegRunResult(
            returnCode: 0,
            output: '{"format":{"tags":{}}}',
          );
        },
      );

      expect(result.isSuccess, isTrue);
      expect(calls, <String>['/app/ffprobe'], reason: 'bundled 成功不该再调 PATH');
    });

    test('explicit HIBIKI_FFPROBE launch failure propagates (no silent PATH)',
        () async {
      await expectLater(
        runCliFfprobeForTesting(
          override: r'D:\Custom\ffprobe.exe',
          bundledPath: r'C:\App\Hibiki\ffprobe.exe',
          args: <String>['-show_format', 'x.m4b'],
          timeout: const Duration(seconds: 1),
          runner:
              (String executable, List<String> args, Duration timeout) async {
            throw ProcessException(executable, args, 'launch failed', 2);
          },
        ),
        throwsA(isA<ProcessException>()),
      );
    });

    test('no bundled, no override: PATH ffprobe ProcessException propagates',
        () async {
      await expectLater(
        runCliFfprobeForTesting(
          override: null,
          bundledPath: null,
          args: <String>['-show_format', 'x.m4b'],
          timeout: const Duration(seconds: 1),
          runner:
              (String executable, List<String> args, Duration timeout) async {
            throw ProcessException(executable, args, 'not found', 2);
          },
        ),
        throwsA(isA<ProcessException>()),
      );
    });
  });
}
