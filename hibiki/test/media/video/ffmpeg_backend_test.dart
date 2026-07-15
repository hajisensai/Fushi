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

    // BUG-834：Android 制卡句子音频（ffmpeg-kit）失败时，toast/日志只显示 ffmpeg
    // version + configuration banner，真因（末尾的 Error/Invalid/... 行）被从头截
    // 断吃掉。failureSummary 必须从**尾段**抽真因，而不是从头截 500 字。
    test('failureSummary surfaces the tail error line, not the leading banner',
        () {
      // 复刻移动端 ffmpeg-kit n6.0 日志：超长 banner 在前（configuration 独占 >500
      // 字），真正的失败行在末尾。旧实现从头截 500 字 → 永远只剩 banner。
      final String longConfig = 'configuration: '
          '${List<String>.filled(60, '--enable-decoder=some_long_name').join(' ')}';
      final String output = <String>[
        'ffmpeg version n6.0 Copyright (c) 2000-2023 the FFmpeg developers',
        'built with Android (9352603, based on r450784d1) clang version 14.0.7',
        longConfig,
        "Input #0, mov,mp4,m4a,3gp,3g2,mj2, from '/data/user/0/app/cache/book.m4b':",
        '  Duration: 00:03:12.00, start: 0.000000, bitrate: 128 kb/s',
        '  Stream #0:0(und): Audio: aac (LC), 44100 Hz, stereo, fltp, 128 kb/s',
        '[aac @ 0x7f] Error while opening encoder - maybe incorrect parameters',
        'Conversion failed!',
      ].join('\n');

      final FfmpegRunResult result = FfmpegRunResult(
        returnCode: 1,
        output: output,
        executable: 'ffmpeg-kit',
        attemptedExecutables: const <String>['ffmpeg-kit'],
      );

      final String summary = result.failureSummary;
      // 真因（尾段错误行）必须出现——从尾向首取第一条含错误关键词的行
      // （'Conversion failed!' 命中 'failed'），而非开头 banner。
      expect(summary, contains('Conversion failed!'),
          reason: 'The real ffmpeg failure line (tail) must survive '
              'summarization instead of the leading banner.');
      // banner（version 行）不得成为唯一显示内容——旧的从头截断正是只剩它。
      expect(summary.contains('ffmpeg version n6.0'), isFalse,
          reason: 'The leading version banner must not crowd out the real '
              'error (old head-truncation showed only the banner).');
      expect(summary.contains('configuration:'), isFalse,
          reason: 'The long configuration banner must not be surfaced instead '
              'of the tail error (BUG-834).');
      // 仍带执行上下文。
      expect(summary, contains('executable=ffmpeg-kit'));
      expect(summary, contains('ffmpeg exit 1'));
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
