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

    test('inputFile-null & range-too-long exits record ErrorLogService entries',
        () {
      // BUG-472(a) follow-up：dispatcher 的 exportable 分支还有两处只 toast 的早
      // 返回（inputFile == null 兜底 / 区间超长 refuse），此前漏补日志。
      expect(audiobookPart, contains('ReaderHibiki.exportClip.inputFileNull'),
          reason: 'inputFile == null 兜底必须记 ErrorLogService。');
      expect(audiobookPart, contains('ReaderHibiki.exportClip.rangeTooLong'),
          reason: '区间超长 refuse 必须记 ErrorLogService。');
    });

    // ── 结构性守卫（BUG-472b）：未来再加「只 toast 不打日志」的静默 return 必须变红 ──
    //
    // 字符串存在性断言只能挡删除既有 tag，挡不住有人在管线里**新增**一条不打日志的
    // 失败出口。这里对 _runAudiobookClipPipeline 与 _exportAudiobookClip 两个函数体
    // 做结构断言：函数体内的失败出口（弹 *_failed / *_unsupported_range / *_no_text
    // / *_no_selection toast）数 ≤ 同体内 ErrorLogService.instance.log 调用数，从而
    // 钉住「每个静默失败 return 都伴随一条日志」。

    // [signature] 应是函数名 + 起始 '('（如 `_runAudiobookClipPipeline(`）。先按圆括号
    // 配平跳过整个参数列表（命名参数列表自带 `{...}`，不能当函数体大括号），再从参数
    // 列表后的第一个 '{' 起按大括号配平截出函数体。
    String fnBody(String src, String signature) {
      final int start = src.indexOf(signature);
      expect(start, greaterThanOrEqualTo(0),
          reason: '函数 $signature 必须存在（结构守卫锚点）。');
      // 跳过参数列表：从签名末尾的 '(' 起配平圆括号。
      int i = start + signature.length - 1; // 指向起始 '('
      expect(src[i], '(', reason: 'signature 必须以 "(" 结尾。');
      int paren = 0;
      for (; i < src.length; i++) {
        final String ch = src[i];
        if (ch == '(') paren++;
        if (ch == ')') {
          paren--;
          if (paren == 0) break;
        }
      }
      // 参数列表已闭合，定位函数体起始 '{'。
      final int bodyStart = src.indexOf('{', i);
      expect(bodyStart, greaterThanOrEqualTo(0),
          reason: '函数 $signature 参数列表后必须有函数体 "{"。');
      int depth = 0;
      for (i = bodyStart; i < src.length; i++) {
        final String ch = src[i];
        if (ch == '{') depth++;
        if (ch == '}') {
          depth--;
          if (depth == 0) return src.substring(bodyStart, i + 1);
        }
      }
      fail('函数 $signature 大括号不配平，无法截出函数体。');
    }

    int countFailureToasts(String body) =>
        't.audiobook_export_clip_failed'.allMatches(body).length +
        't.audiobook_export_clip_unsupported_range'.allMatches(body).length +
        't.audiobook_export_clip_no_text'.allMatches(body).length +
        't.audiobook_export_clip_no_selection'.allMatches(body).length;

    // 容忍 dart format 把 ErrorLogService.instance.log( 折行成
    // ErrorLogService.instance 换行后 .log(（catch 块就是这样），
    // 用正则匹配 .instance 与 .log 之间任意空白。
    final RegExp errorLogRe = RegExp(r'ErrorLogService\.instance\s*\.log');
    int countErrorLogs(String body) => errorLogRe.allMatches(body).length;

    test('每个失败出口都伴随一条 ErrorLogService.log（_runAudiobookClipPipeline）', () {
      final String body = fnBody(
        audiobookPart,
        'Future<void> _runAudiobookClipPipeline(',
      );
      final int failures = countFailureToasts(body);
      final int logs = countErrorLogs(body);
      expect(failures, greaterThan(0), reason: '管线内应至少有一个失败出口（守卫自检，防截错函数体）。');
      expect(logs, greaterThanOrEqualTo(failures),
          reason: '管线内每个失败 toast/return 都必须伴随一条 ErrorLogService.log；'
              '新增不打日志的静默 return 会让本守卫变红 (BUG-472b)。');
    });

    test('每个失败出口都伴随一条 ErrorLogService.log（_exportAudiobookClip）', () {
      final String body = fnBody(audiobookPart, 'void _exportAudiobookClip(');
      final int failures = countFailureToasts(body);
      final int logs = countErrorLogs(body);
      expect(failures, greaterThan(0), reason: 'dispatcher 内应至少有一个失败出口（守卫自检）。');
      expect(logs, greaterThanOrEqualTo(failures),
          reason: 'dispatcher 内每个失败 toast/return 都必须伴随一条 '
              'ErrorLogService.log；新增不打日志的静默 return 会让本守卫变红 '
              '(BUG-472b)。');
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
