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
      expect(result.executable, 'ffmpeg');
      expect(result.attemptedExecutables,
          <String>[r'C:\App\Hibiki\ffmpeg.exe', 'ffmpeg']);
      expect(result.fallbackReason, contains('STATUS_INVALID_IMAGE_FORMAT'));
    });

    test('fallback PATH launch failure keeps bundled invalid-image context',
        () async {
      final List<String> calls = <String>[];

      await expectLater(
        runCliFfmpegForTesting(
          override: null,
          bundledPath: r'C:\App\Hibiki\ffmpeg.exe',
          isWindows: true,
          args: <String>['-version'],
          timeout: const Duration(seconds: 1),
          runner:
              (String executable, List<String> args, Duration timeout) async {
            calls.add(executable);
            if (executable.endsWith(r'Hibiki\ffmpeg.exe')) {
              return const FfmpegRunResult(
                returnCode: -1073741701,
                output: 'STATUS_INVALID_IMAGE_FORMAT',
              );
            }
            throw ProcessException(executable, args, 'not found', 2);
          },
        ),
        throwsA(
          isA<ProcessException>()
              .having(
                (ProcessException e) => e.message,
                'message',
                contains(r'C:\App\Hibiki\ffmpeg.exe -> ffmpeg'),
              )
              .having(
                (ProcessException e) => e.message,
                'message',
                contains('STATUS_INVALID_IMAGE_FORMAT'),
              ),
        ),
      );

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
      expect(result.executable, r'D:\Custom\ffmpeg.exe');
      expect(result.attemptedExecutables, <String>[r'D:\Custom\ffmpeg.exe']);
      expect(result.failureSummary, contains('0xC000007B'));
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
        expect(result.executable, 'ffmpeg');
        expect(result.attemptedExecutables,
            <String>[r'C:\App\Hibiki\ffmpeg.exe', 'ffmpeg']);
        expect(result.fallbackReason, contains('launch failed'));
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

    // BUG-283 (TODO-372): 续 BUG-275。一类损坏让 bundled `Process.start` **成功**，
    // 进程真起来、随后在加载期才崩——典型 STATUS_DLL_NOT_FOUND(0xC0000135) /
    // STATUS_ENTRYPOINT_NOT_FOUND(0xC0000139)：ffmpeg.exe 本体没坏但依赖 DLL 缺失/
    // 被杀软隔离。退出码不是 BUG-275 认的 STATUS_INVALID_IMAGE_FORMAT，stderr 也空，
    // 旧逻辑原样返回这条空结果、从不回退 → 字幕枚举拿空文本 → 解析 0 条轨 → 静默
    // 无内封字幕。回退条件必须扩展为「bundled 跑起来却没产出任何 ffmpeg 工作输出」。
    test(
        'bundled crashes on load (DLL missing): empty output falls back to PATH',
        () async {
      // STATUS_DLL_NOT_FOUND(-1073741515) / STATUS_ENTRYPOINT_NOT_FOUND
      // (-1073741511) / 通用非 0：进程起来但无 stderr，都应回退。
      for (final int code in <int>[-1073741515, -1073741511, 1]) {
        final List<String> calls = <String>[];
        final FfmpegRunResult result = await runCliFfmpegForTesting(
          override: null,
          bundledPath: 'C:/App/Hibiki/ffmpeg.exe',
          isWindows: true,
          args: <String>['-hide_banner', '-i', 'C:/v/ep.mkv'],
          timeout: const Duration(seconds: 1),
          runner:
              (String executable, List<String> args, Duration timeout) async {
            calls.add(executable);
            if (executable == 'C:/App/Hibiki/ffmpeg.exe') {
              // 进程起来了（无 ProcessException），但 DLL 缺失加载期崩：
              // 退出码非 0、stderr 完全为空。
              return FfmpegRunResult(returnCode: code, output: '');
            }
            return const FfmpegRunResult(
              returnCode: 1,
              output: '  Stream #0:2(jpn): Subtitle: ass (default)',
            );
          },
        );

        expect(result.output, contains('Subtitle'),
            reason: 'returnCode=$code 空输出应回退 PATH 取到字幕枚举');
        expect(calls, <String>['C:/App/Hibiki/ffmpeg.exe', 'ffmpeg'],
            reason: 'returnCode=$code 应先试 bundled 再回退 PATH');
        expect(result.executable, 'ffmpeg');
        expect(result.attemptedExecutables,
            <String>['C:/App/Hibiki/ffmpeg.exe', 'ffmpeg']);
        expect(result.fallbackReason, contains('no usable output'));
      }
    });

    test('bundled empty output fallback is platform-agnostic (Linux/mac too)',
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
            // e.g. missing shared object: launched but exits non-zero, no stderr.
            return const FfmpegRunResult(returnCode: 127, output: '');
          }
          return const FfmpegRunResult(
            returnCode: 1,
            output: '  Stream #0:1(eng): Subtitle: subrip',
          );
        },
      );

      expect(result.output, contains('Subtitle'));
      expect(calls, <String>['/app/Hibiki/ffmpeg', 'ffmpeg']);
    });

    test('normal -i enumeration (non-zero + full stderr) does NOT fall back',
        () async {
      // 正常工作的 ffmpeg：`-i` 无输出文件恒退出非 0，但 stderr 满是流信息——
      // 这是成功枚举，绝不能误判成坏二进制去回退 PATH（否则平添一次进程开销）。
      final List<String> calls = <String>[];
      const String fullLog = 'Input #0, matroska,webm:\n'
          '  Stream #0:0: Video: hevc\n'
          '  Stream #0:1(jpn): Subtitle: ass (default)\n'
          'At least one output file must be specified';
      final FfmpegRunResult result = await runCliFfmpegForTesting(
        override: null,
        bundledPath: 'C:/App/Hibiki/ffmpeg.exe',
        isWindows: true,
        args: <String>['-hide_banner', '-i', 'C:/v/ep.mkv'],
        timeout: const Duration(seconds: 1),
        runner: (String executable, List<String> args, Duration timeout) async {
          calls.add(executable);
          return const FfmpegRunResult(returnCode: 1, output: fullLog);
        },
      );

      expect(result.output, contains('Subtitle'));
      expect(calls, <String>['C:/App/Hibiki/ffmpeg.exe'],
          reason: '正常枚举只该调一次 bundled，不回退 PATH');
    });

    test('bundled timeout (returnCode null + empty) does NOT fall back',
        () async {
      // 超时被 SIGKILL 返回 returnCode:null + 空输出——是慢 IO 而非坏二进制，
      // 回退会让用户对同一个慢文件再等一遍；保持原契约不回退，调用方按超时降级。
      final List<String> calls = <String>[];
      final FfmpegRunResult result = await runCliFfmpegForTesting(
        override: null,
        bundledPath: 'C:/App/Hibiki/ffmpeg.exe',
        isWindows: true,
        args: <String>['-hide_banner', '-i', 'C:/v/huge.mkv'],
        timeout: const Duration(seconds: 1),
        runner: (String executable, List<String> args, Duration timeout) async {
          calls.add(executable);
          return const FfmpegRunResult(returnCode: null, output: '');
        },
      );

      expect(result.returnCode, isNull);
      expect(calls, <String>['C:/App/Hibiki/ffmpeg.exe'],
          reason: '超时不该回退 PATH（慢 IO 非坏二进制）');
    });
  });
}
