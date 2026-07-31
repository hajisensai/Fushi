import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/audiobook/audiobook_clip_export.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

/// BUG-1262：超时长上限此前被并进 unsupportedRange，同章长选区被误报
/// 「跨章或跨音频文件」。守卫三件事：
/// ① 单句/多句分类都把「太长」归 [AudiobookClipBoundaryKind.tooLong]（而非
///    unsupportedRange），调用方才能给诚实文案；
/// ② 上限 = 300s（单一真相源常量），i18n 文案里的「5 分钟」与之同步；
/// ③ 长片段的动态帧率按总帧数预算收敛（clipExportFps），提限不引爆临时盘。
void main() {
  group('classifyAudiobookClipSelection duration cap (BUG-1262)', () {
    AudiobookClipBoundaryResult classify(int durationMs) {
      return classifyAudiobookClipSelection(
        selectedText: '長い選択範囲のテキスト',
        audioFileCount: 1,
        sentenceRange: AudioPlaybackRange(
          audioFileIndex: 0,
          startMs: 1000,
          endMs: 1000 + durationMs,
        ),
      );
    }

    test('over the cap → tooLong, never unsupportedRange', () {
      final AudiobookClipBoundaryResult result =
          classify(kAudiobookClipMaxDurationMs + 1);
      expect(result.kind, AudiobookClipBoundaryKind.tooLong,
          reason: '「太长」与「跨章/跨文件」是两种事实，混成一类会误报跨章');
      expect(result.isExportable, isFalse);
    });

    test('exactly at the cap stays exportable', () {
      expect(
        classify(kAudiobookClipMaxDurationMs).kind,
        AudiobookClipBoundaryKind.exportable,
      );
    });

    test('null/degenerate ranges keep the unsupportedRange kind', () {
      // 真正解析不出区间的场景不受 tooLong 拆分影响（文案对它们仍准确）。
      expect(
        classifyAudiobookClipSelection(
          selectedText: 'x',
          audioFileCount: 1,
          sentenceRange: null,
        ).kind,
        AudiobookClipBoundaryKind.unsupportedRange,
      );
    });
  });

  group('classifyAudiobookClipMultiCue duration cap (BUG-1262)', () {
    AudiobookClipMultiCueResult classify(int durationMs) {
      return classifyAudiobookClipMultiCue(
        selectedText: '複数句の選択',
        audioFileCount: 1,
        globalRange: AudioPlaybackRange(
          audioFileIndex: 0,
          startMs: 0,
          endMs: durationMs,
        ),
        cueSpans: const <AudiobookClipCueSpan>[
          AudiobookClipCueSpan(text: '複数句の選択', startMs: 0, endMs: 1000),
        ],
      );
    }

    test('over the cap → tooLong; at the cap → exportable', () {
      expect(
        classify(kAudiobookClipMaxDurationMs + 1).kind,
        AudiobookClipBoundaryKind.tooLong,
      );
      expect(
        classify(kAudiobookClipMaxDurationMs).kind,
        AudiobookClipBoundaryKind.exportable,
      );
    });
  });

  group('cap constant ↔ i18n copy stay in sync (BUG-1262)', () {
    test('cap is 5 minutes and the toast copy says so', () {
      // 上限常量与 audiobook_export_clip_too_long 文案（写死「5 分钟」）互为契约：
      // 改常量必须同步文案，本测试让漂移当场红。
      expect(kAudiobookClipMaxDurationMs, 5 * 60 * 1000);

      final Map<String, dynamic> en = json.decode(
        File('lib/i18n/strings.i18n.json').readAsStringSync(),
      ) as Map<String, dynamic>;
      final Map<String, dynamic> zh = json.decode(
        File('lib/i18n/strings_zh-CN.i18n.json').readAsStringSync(),
      ) as Map<String, dynamic>;
      expect(en['audiobook_export_clip_too_long'], contains('5 minutes'));
      expect(zh['audiobook_export_clip_too_long'], contains('5 分钟'));
    });

    test('dispatcher routes tooLong to the dedicated toast, not 跨章 copy', () {
      final String part = File(
        'lib/src/pages/implementations/reader_hibiki/audiobook.part.dart',
      ).readAsStringSync().replaceAll('\r\n', '\n');
      // tooLong 分支必须弹专属文案；不允许再把超长路由回 unsupported_range 文案。
      final int caseAt =
          part.indexOf('case AudiobookClipBoundaryKind.tooLong:');
      expect(caseAt, greaterThanOrEqualTo(0),
          reason: 'dispatcher 必须显式处理 tooLong 分支');
      final int caseEnd = part.indexOf('case ', caseAt + 1);
      final String caseBody = part.substring(caseAt, caseEnd);
      expect(caseBody, contains('t.audiobook_export_clip_too_long'));
      expect(caseBody,
          isNot(contains('t.audiobook_export_clip_unsupported_range')),
          reason: '超长选区绝不能再弹「跨章或跨音频文件」误导文案');
    });
  });

  group('clipExportFps frame budget (BUG-1262)', () {
    test('short clips keep the BUG-713 24fps highlight precision', () {
      expect(clipExportFps(durationMs: 5 * 1000), 24);
      expect(clipExportFps(durationMs: 120 * 1000), 24);
    });

    test('long clips shrink fps to keep total frames within budget', () {
      final int fps300 = clipExportFps(durationMs: 300 * 1000);
      expect(fps300, lessThan(24));
      expect(fps300 * 300, lessThanOrEqualTo(2880),
          reason: '总帧数不得超过提限前的既有最坏情况（120s×24fps）');
      expect(fps300, greaterThanOrEqualTo(6));
    });

    test('degenerate duration falls back to max fps', () {
      expect(clipExportFps(durationMs: 0), 24);
      expect(clipExportFps(durationMs: -5), 24);
    });
  });
}
