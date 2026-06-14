import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/ffmpeg_backend.dart';

/// 桌面 ffmpeg 可执行解析优先级：HIBIKI_FFMPEG 覆盖 > 程序旁捆绑 ffmpeg > 系统 PATH。
/// 让没装 ffmpeg 的电脑也能用捆绑的（开箱即用），同时保留显式覆盖与 PATH 回退。
void main() {
  group('resolveFfmpegExecutableFrom 优先级', () {
    test('HIBIKI_FFMPEG 覆盖最高优先', () {
      expect(
        resolveFfmpegExecutableFrom(
            override: '/opt/ff/ffmpeg', bundledPath: '/app/ffmpeg'),
        '/opt/ff/ffmpeg',
      );
    });

    test('无覆盖时用程序旁捆绑 ffmpeg', () {
      expect(
        resolveFfmpegExecutableFrom(override: null, bundledPath: '/app/ffmpeg'),
        '/app/ffmpeg',
      );
      // 空白覆盖视同无覆盖。
      expect(
        resolveFfmpegExecutableFrom(
            override: '   ', bundledPath: r'C:\Hibiki\ffmpeg.exe'),
        r'C:\Hibiki\ffmpeg.exe',
      );
    });

    test('无覆盖无捆绑回退系统 PATH 的 ffmpeg', () {
      expect(
        resolveFfmpegExecutableFrom(override: null, bundledPath: null),
        'ffmpeg',
      );
      expect(
        resolveFfmpegExecutableFrom(override: '', bundledPath: ''),
        'ffmpeg',
      );
    });
  });

  group('runCliFfmpegForTesting bundled fallback', () {
    test('Windows bundled ffmpeg invalid image falls back to PATH ffmpeg',
        () async {
      final List<String> calls = <String>[];

      final FfmpegRunResult result = await runCliFfmpegForTesting(
        override: null,
        bundledPath: r'C:\App\Hibiki\ffmpeg.exe',
        isWindows: true,
        args: <String>['-version'],
        timeout: const Duration(seconds: 1),
        runner: (String executable, List<String> args, Duration timeout) async {
          calls.add(executable);
          if (executable.endsWith(r'Hibiki\ffmpeg.exe')) {
            return const FfmpegRunResult(
              returnCode: -1073741701,
              output: 'STATUS_INVALID_IMAGE_FORMAT',
            );
          }
          return const FfmpegRunResult(returnCode: 0, output: 'ffmpeg version');
        },
      );

      expect(result.isSuccess, isTrue);
      expect(calls, <String>[r'C:\App\Hibiki\ffmpeg.exe', 'ffmpeg']);
    });

    test('explicit HIBIKI_FFMPEG invalid image does not fall back', () async {
      final List<String> calls = <String>[];

      final FfmpegRunResult result = await runCliFfmpegForTesting(
        override: r'D:\Custom\ffmpeg.exe',
        bundledPath: r'C:\App\Hibiki\ffmpeg.exe',
        isWindows: true,
        args: <String>['-version'],
        timeout: const Duration(seconds: 1),
        runner: (String executable, List<String> args, Duration timeout) async {
          calls.add(executable);
          return const FfmpegRunResult(
            returnCode: -1073741701,
            output: 'STATUS_INVALID_IMAGE_FORMAT',
          );
        },
      );

      expect(result.isSuccess, isFalse);
      expect(calls, <String>[r'D:\Custom\ffmpeg.exe']);
    });

    // TODO-336 / BUG-275: 一个损坏/架构不匹配的 bundled ffmpeg.exe 在 `Process.start`
    // 阶段就抛 ProcessException，且 errorCode 视具体损坏方式而异（实测 2 /
    // 216 / 193 都可能）。BUG-233 的回退只认 errorCode==193，于是字幕枚举
    // （`listEmbeddedSubtitleTracks` 的 `on ProcessException { return [] }`）把
    // 真失败吞成「无内封字幕」。回退必须按「bundled 这个文件跑不起来」回退，
    // 而非死盯单一错误码。
    test('bundled ffmpeg launch ProcessException (any code) falls back to PATH',
        () async {
      for (final int code in <int>[2, 216, 193, 5]) {
        final List<String> calls = <String>[];
        final FfmpegRunResult result = await runCliFfmpegForTesting(
          override: null,
          bundledPath: r'C:\App\Hibiki\ffmpeg.exe',
          isWindows: true,
          args: <String>['-hide_banner', '-i', r'C:\v\ep.mkv'],
          timeout: const Duration(seconds: 1),
          runner:
              (String executable, List<String> args, Duration timeout) async {
            calls.add(executable);
            if (executable.endsWith(r'Hibiki\ffmpeg.exe')) {
              throw ProcessException(executable, args, 'launch failed', code);
            }
            return const FfmpegRunResult(returnCode: 1, output: 'Subtitle');
          },
        );

        expect(result.output, contains('Subtitle'),
            reason: 'errorCode=$code 也应回退 PATH 取到字幕枚举输出');
        expect(calls, <String>[r'C:\App\Hibiki\ffmpeg.exe', 'ffmpeg'],
            reason: 'errorCode=$code 应先试 bundled 再回退 PATH');
      }
    });

    test('bundled ffmpeg launch failure falls back to PATH on non-Windows too',
        () async {
      final List<String> calls = <String>[];
      final FfmpegRunResult result = await runCliFfmpegForTesting(
        override: null,
        bundledPath: '/app/Hibiki/ffmpeg',
        isWindows: false,
        args: <String>['-hide_banner', '-i', '/v/ep.mkv'],
        timeout: const Duration(seconds: 1),
        runner: (String executable, List<String> args, Duration timeout) async {
          calls.add(executable);
          if (executable == '/app/Hibiki/ffmpeg') {
            // e.g. permission denied / not an executable on the bundled copy.
            throw ProcessException(executable, args, 'Permission denied', 13);
          }
          return const FfmpegRunResult(returnCode: 1, output: 'Subtitle');
        },
      );

      expect(result.output, contains('Subtitle'));
      expect(calls, <String>['/app/Hibiki/ffmpeg', 'ffmpeg']);
    });

    test('explicit HIBIKI_FFMPEG launch ProcessException still propagates',
        () async {
      // 显式覆盖保持旧契约：用户指定的路径跑不起来就如实报错，不悄悄换 PATH。
      await expectLater(
        runCliFfmpegForTesting(
          override: r'D:\Custom\ffmpeg.exe',
          bundledPath: r'C:\App\Hibiki\ffmpeg.exe',
          isWindows: true,
          args: <String>['-version'],
          timeout: const Duration(seconds: 1),
          runner:
              (String executable, List<String> args, Duration timeout) async {
            throw ProcessException(executable, args, 'launch failed', 2);
          },
        ),
        throwsA(isA<ProcessException>()),
      );
    });

    test('no bundled, no override: PATH launch ProcessException propagates',
        () async {
      // 无 bundled 无覆盖时直接走 PATH，PATH 上没有 ffmpeg 的 ProcessException
      // 必须向上传播（调用方 `listEmbeddedSubtitleTracks` 据此降级为无字幕）。
      await expectLater(
        runCliFfmpegForTesting(
          override: null,
          bundledPath: null,
          isWindows: true,
          args: <String>['-version'],
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
