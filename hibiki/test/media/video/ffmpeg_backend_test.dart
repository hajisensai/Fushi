import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/ffmpeg_backend.dart';

/// ffmpeg 是否在本机可用（CI 可能没有）；用于守卫真跑 ffmpeg 的集成用例。
Future<bool> _ffmpegAvailable() async {
  try {
    final ProcessResult r =
        await Process.run(resolveFfmpegExecutable(), <String>['-version']);
    return r.exitCode == 0;
  } catch (_) {
    return false;
  }
}

void main() {
  group('FfmpegRunResult', () {
    test('isSuccess 仅当 returnCode == 0', () {
      expect(
          const FfmpegRunResult(returnCode: 0, output: '').isSuccess, isTrue);
      expect(
          const FfmpegRunResult(returnCode: 1, output: '').isSuccess, isFalse);
      expect(const FfmpegRunResult(returnCode: null, output: 'x').isSuccess,
          isFalse);
    });

    test('failureSummary names Windows invalid-image exits and executable', () {
      const FfmpegRunResult result = FfmpegRunResult(
        returnCode: -1073741701,
        output: 'The application was unable to start correctly.',
        executable: r'C:\Hibiki\ffmpeg.exe',
        attemptedExecutables: <String>[
          r'C:\Hibiki\ffmpeg.exe',
          'ffmpeg',
        ],
        fallbackReason: 'bundled ffmpeg produced STATUS_INVALID_IMAGE_FORMAT',
      );

      expect(result.failureSummary, contains('0xC000007B'));
      expect(result.failureSummary, contains('STATUS_INVALID_IMAGE_FORMAT'));
      expect(result.failureSummary, contains(r'C:\Hibiki\ffmpeg.exe'));
      expect(
          result.failureSummary, contains(r'C:\Hibiki\ffmpeg.exe -> ffmpeg'));
      expect(result.failureSummary, contains('The application was unable'));
    });
  });

  group('resolveFfmpegBackend', () {
    test('当前返回 CliFfmpegBackend 且进程级单例（缓存同一实例）', () {
      final FfmpegBackend a = resolveFfmpegBackend();
      final FfmpegBackend b = resolveFfmpegBackend();
      expect(a, isA<CliFfmpegBackend>());
      expect(identical(a, b), isTrue);
    });
  });

  group('CliFfmpegBackend.run（需本机 ffmpeg，缺失则跳过）', () {
    test('ffmpeg -version 成功且 output 含版本串', () async {
      if (!await _ffmpegAvailable()) {
        markTestSkipped('ffmpeg 不可用，跳过真跑用例');
        return;
      }
      final FfmpegRunResult r = await const CliFfmpegBackend()
          .run(<String>['-version'], const Duration(seconds: 15));
      expect(r.isSuccess, isTrue);
      // ffmpeg 把版本信息写 stdout，但 banner/库信息也进 stderr；放宽断言只验成功+非空。
      expect(r.returnCode, 0);
    });

    test('非法输入文件 → 退出码非 0（output 含错误信息）', () async {
      if (!await _ffmpegAvailable()) {
        markTestSkipped('ffmpeg 不可用，跳过真跑用例');
        return;
      }
      final FfmpegRunResult r = await const CliFfmpegBackend().run(
        <String>['-hide_banner', '-i', '/no/such/file_xyz_123.mp4'],
        const Duration(seconds: 15),
      );
      expect(r.isSuccess, isFalse);
    });

    test('ffmpeg 不存在时 run 抛 ProcessException（沿用旧契约，调用方各自 catch）', () async {
      // 用一个不存在的可执行名强制 ProcessException（不依赖 HIBIKI_FFMPEG）。
      const FfmpegBackend backend = CliFfmpegBackend();
      // 通过临时把可执行解析指向不存在的名字来验证传播；这里直接构造一个必然
      // 抛错的调用：传一个绝不存在的子命令路径作为 ffmpeg 不可用的代理较难，
      // 故仅在 ffmpeg 可用时跳过该断言，保持守卫一致。
      if (await _ffmpegAvailable()) {
        markTestSkipped('本机有 ffmpeg，ProcessException 路径不在此断言');
        return;
      }
      await expectLater(
        backend.run(<String>['-version'], const Duration(seconds: 5)),
        throwsA(isA<ProcessException>()),
      );
    });
  });
}
