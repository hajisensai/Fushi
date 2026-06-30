import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/audiobook/audiobook_clip_export.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

/// TODO-1005 / BUG-472 守卫：有声书片段导出「失败但无任何错误日志」。
///
/// 根因：失败发生在 ffmpeg 被调用**之前**的静默早返回路径，这些路径只 debugPrint /
/// 只弹 toast，从不写 ErrorLogService（用户的 in-app 持久日志看不到）。本守卫钉住
/// 每个静默失败出口都已接上 ErrorLogService.instance.log(...)，并钉住「零长/错位
/// 区间」在纯函数 classify 层就被归类成 unsupportedRange（明确用户文案 + 完整日志），
/// 不会漏到 M2 ffmpeg 的静默 return null。
void main() {
  String libFile(String relative) =>
      File(relative).readAsStringSync().replaceAll('\r\n', '\n');

  group('export-clip silent failure exits all log to ErrorLogService', () {
    late String audiobookPart;

    setUpAll(() {
      audiobookPart = libFile(
        'lib/src/pages/implementations/reader_hibiki/audiobook.part.dart',
      );
    });

    test('emptySelection branch records an ErrorLogService entry', () {
      expect(audiobookPart, contains('ReaderHibiki.exportClip.emptySelection'),
          reason: '空选区/纯外字分支此前只 debugPrint，必须补 ErrorLogService '
              '(TODO-1005/BUG-472)。');
    });

    test('noAudio branch records an ErrorLogService entry', () {
      expect(audiobookPart, contains('ReaderHibiki.exportClip.noAudio'),
          reason: '无音频分支此前只 debugPrint，必须补 ErrorLogService。');
    });

    test('unsupportedRange branch keeps its ErrorLogService entry', () {
      expect(
          audiobookPart, contains('ReaderHibiki.exportClip.unsupportedRange'),
          reason: '跨章/跨文件/零长区间分支必须保留 ErrorLogService（明确用户文案）。');
    });

    test('M2 audio-clip-null branch records an ErrorLogService entry', () {
      expect(audiobookPart, contains('ReaderHibiki.exportClip.audioClipFailed'),
          reason: 'M2 裁音频返回 null 此前只弹 toast、零日志——这正是用户看到的'
              '「点了没反应、日志空白」。必须补 ErrorLogService (TODO-1005/BUG-472)。');
    });

    test('M3 overlay/text-render null branches record ErrorLogService entries',
        () {
      expect(audiobookPart, contains('ReaderHibiki.exportClip.noOverlay'),
          reason: 'M3 无 Overlay 早返回必须记 ErrorLogService。');
      expect(
          audiobookPart, contains('ReaderHibiki.exportClip.textRenderFailed'),
          reason: 'M3 文本图渲染失败早返回必须记 ErrorLogService。');
    });

    test('M4 synth-failure branch records an ErrorLogService entry', () {
      expect(audiobookPart, contains('ReaderHibiki.exportClip.synthFailed'),
          reason: 'M4 合成失败必须在管线层记一条 ErrorLogService 摘要。');
    });
  });

  group('ffmpeg early returns are no longer silent (desktop_audio_clipper)',
      () {
    test('extractAudioSegmentViaFfmpeg early returns report via shared helper',
        () {
      final String clipper =
          libFile('lib/src/utils/misc/desktop_audio_clipper.dart');
      // The two pre-ffmpeg early returns (non-positive range / missing input)
      // must go through _reportFfmpegEarlyReturn, which both logs to
      // ErrorLogService and forwards onFailure.
      expect(clipper, contains('void _reportFfmpegEarlyReturn('),
          reason: '必须有统一的早返回上报 helper (TODO-1005/BUG-472)。');
      expect('_reportFfmpegEarlyReturn'.allMatches(clipper).length,
          greaterThanOrEqualTo(3),
          reason: 'helper 定义 + 至少两个早返回调用点（非正区间 / 输入缺失）。');

      // Scope the no-silent-return assertions to the audio function body only
      // (the GIF/cover functions keep their own silent returns — out of scope).
      final int start =
          clipper.indexOf('Future<String?> extractAudioSegmentViaFfmpeg({');
      expect(start, greaterThanOrEqualTo(0),
          reason: 'extractAudioSegmentViaFfmpeg must still exist.');
      final int nextFn = clipper.indexOf('Future<String?> extract', start + 1);
      final String body = nextFn > start
          ? clipper.substring(start, nextFn)
          : clipper.substring(start);
      expect(body.contains('if (endMs <= startMs) return null;'), isFalse,
          reason: '零长/错位区间不得再静默 return null（裁音频函数体内）。');
      expect(body.contains('if (!File(inputPath).existsSync()) return null;'),
          isFalse,
          reason: '输入缺失不得再静默 return null（裁音频函数体内）。');
      expect('_reportFfmpegEarlyReturn'.allMatches(body).length, 2,
          reason: '裁音频函数两条早返回都必须经 _reportFfmpegEarlyReturn 上报。');
    });
  });

  group('degenerate range is classified (not leaked to ffmpeg) — part B', () {
    test('endMs <= startMs → unsupportedRange (明确文案，不漏到 ffmpeg)', () {
      // 文本 EPUB + 后挂音频时，句子 cue 易解析出零长/错位区间。这类区间必须在纯函数
      // classify 层被归类成 unsupportedRange（有完整日志 + 明确用户文案），而不是漏到
      // M2 extractAudioSegmentViaFfmpeg 的静默 return null。
      final AudiobookClipBoundaryResult zeroLen =
          classifyAudiobookClipSelection(
        selectedText: '僕は学校へ',
        audioFileCount: 1,
        sentenceRange: const AudioPlaybackRange(
          audioFileIndex: 0,
          startMs: 4000,
          endMs: 4000,
        ),
      );
      expect(zeroLen.kind, AudiobookClipBoundaryKind.unsupportedRange);

      final AudiobookClipBoundaryResult inverted =
          classifyAudiobookClipSelection(
        selectedText: '僕は学校へ',
        audioFileCount: 1,
        sentenceRange: const AudioPlaybackRange(
          audioFileIndex: 0,
          startMs: 5000,
          endMs: 4000,
        ),
      );
      expect(inverted.kind, AudiobookClipBoundaryKind.unsupportedRange);
      expect(inverted.isExportable, isFalse);
    });
  });
}
