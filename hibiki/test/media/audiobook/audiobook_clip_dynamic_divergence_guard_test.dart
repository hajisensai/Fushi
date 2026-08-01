import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/audiobook/audiobook_clip_export.dart';
import 'package:hibiki/src/media/audiobook/mining_audio_clip.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

/// TODO-1115 review 守卫：动态导出（多句连读 + 逐句高亮）的两处硬化。
///
/// M1（audioFileIndex 分歧回退）：音频裁剪走静态 `range`（由 range.audioFileIndex 选
/// inputFile），起止 ms 却走 dynamicPlan.globalStartMs/globalEndMs（由 span 独立解析出的
/// dynamicPlan.audioFileIndex 定的坐标系）。二者理论可分歧；一旦 dynamicPlan.audioFileIndex
/// != range.audioFileIndex，就会拿 A 文件的 ms 偏移去裁 B 文件 → 错音频 + 错高亮。护栏：
/// 分歧则放弃动态、令 dynamicPlan=null，回退单句静态（运行时判据，不用 release 会被剥的
/// assert）。
///
/// M2（分类文本同源）：动态侧 [classifyAudiobookClipMultiCue] 的 selectedText 必须与静态
/// 路径 [_exportAudiobookClip] 的真实原生选区同源。BUG-1243 后跨句导出不能再用
/// `_miningSpanRange` 的句级优先语义：有选区时必须直接读 selection.offset/length，
/// 无选区的普通点词导出才回退 `_miningSpanRange()`。
void main() {
  String libFile(String relative) =>
      File(relative).readAsStringSync().replaceAll('\r\n', '\n');

  /// 复用 logging-guard 的函数体截取器：按 [signature]（函数名 + 起始 '('）先配平圆括号
  /// 跳过参数列表，再从其后第一个 '{' 起配平大括号截出函数体。
  String fnBody(String src, String signature) {
    final int start = src.indexOf(signature);
    expect(start, greaterThanOrEqualTo(0),
        reason: '函数 $signature 必须存在（结构守卫锚点）。');
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

  late String audiobookPart;

  setUpAll(() {
    audiobookPart = libFile(
      'lib/src/pages/implementations/reader_hibiki/audiobook.part.dart',
    );
  });

  group('M1: dynamic/static audioFileIndex divergence guard', () {
    test('BUG-1243 dynamic plan defines the classified audio range up front',
        () {
      final String body = fnBody(audiobookPart, 'void _exportAudiobookClip(');
      final int planAt = body.indexOf('_buildAudiobookClipPlan(');
      final int rangeAt = body.indexOf(
        'AudioPlaybackRange? sentenceRange',
        planAt,
      );
      final int classifyAt = body.indexOf(
        'classifyAudiobookClipSelection(',
        rangeAt,
      );
      expect(planAt, greaterThanOrEqualTo(0));
      expect(rangeAt, greaterThan(planAt));
      expect(classifyAt, greaterThan(rangeAt));
      // BUG-1320 之后整段窗口由 _buildAudiobookClipPlan 随记录字段 range 直接回传，
      // 不再从 dynamicPlan.global* 反推——超上限时 plan 为空但窗口仍有效，反推会连
      // 窗口一起丢，长选区退回单句锚（BUG-1243 的老症状）。
      expect(
        body.substring(rangeAt, classifyAt),
        contains('clipPlan.range'),
        reason: '多句计划算出的完整窗口必须原样进入最终裁剪范围，不能仍裁第一句',
      );
    });

    test(
        'dispatcher compares dynamicPlan.audioFileIndex to range.audioFileIndex',
        () {
      final String body = fnBody(audiobookPart, 'void _exportAudiobookClip(');
      // 必须存在「dynamicPlan.audioFileIndex != range.audioFileIndex」判据。
      // 容忍 dart format 换行/空白。
      final RegExp cmp = RegExp(
        r'dynamicPlan\.audioFileIndex\s*!=\s*range\.audioFileIndex',
      );
      expect(cmp.hasMatch(body), isTrue,
          reason: 'M1：分歧护栏必须比较 dynamicPlan.audioFileIndex != '
              'range.audioFileIndex（否则会拿 A 文件 ms 去裁 B 文件）。');
    });

    test('divergence path drops the dynamic plan (dynamicPlan = null)', () {
      final String body = fnBody(audiobookPart, 'void _exportAudiobookClip(');
      // 分歧时把 dynamicPlan 置 null → 回退单句静态。要求 dynamicPlan 是可变局部
      // （非 final）且有一处赋 null。
      expect(body.contains('dynamicPlan = null;'), isTrue,
          reason: 'M1：分歧时必须令 dynamicPlan = null 回退单句静态。');
      expect(body.contains('final _AudiobookClipDynamicPlan? dynamicPlan ='),
          isFalse,
          reason: 'M1：dynamicPlan 必须是可变局部（否则无法在分歧时置 null）。');
    });

    test('divergence path logs the fallback reason (no assert)', () {
      final String body = fnBody(audiobookPart, 'void _exportAudiobookClip(');
      expect(body, contains('ReaderHibiki.exportClip.audioFileIndexDivergence'),
          reason: 'M1：分歧回退必须记 ErrorLogService（release 会剥 assert）。');
      // 明确不用 assert 作为护栏（release 会被剥）。
      expect(body.contains('assert(dynamicPlan'), isFalse,
          reason: 'M1：不得用 assert 做分歧护栏（release 剥除）。');
    });
  });

  group('M2: dynamic classify text shares single source with static path', () {
    test(
        'BUG-1243 production plan keeps a three-cue native selection and '
        'highlights every sentence', () {
      AudioCue cue({
        required String text,
        required int normStart,
        required int normEnd,
        required int startMs,
      }) {
        return AudioCue()
          ..bookKey = 'book'
          ..chapterHref = 'chapter'
          ..sentenceIndex = normStart ~/ 10
          ..textFragmentId = SasayakiMatchCodec.encodeHit(
            sectionIndex: 0,
            normCharStart: normStart,
            normCharEnd: normEnd,
          )
          ..text = text
          ..startMs = startMs
          ..endMs = startMs + 1000
          ..audioFileIndex = 0;
      }

      final List<AudioCue> cues = <AudioCue>[
        cue(text: 'first', normStart: 0, normEnd: 10, startMs: 0),
        cue(text: 'second', normStart: 10, normEnd: 20, startMs: 1000),
        cue(text: 'third', normStart: 20, normEnd: 30, startMs: 2000),
      ];
      final AudiobookClipSelectionSpan selection =
          resolveAudiobookClipSelectionSpan(
        selectedText: 'first second third',
        selectedOffset: 0,
        selectedLength: 30,
        fallbackText: 'second',
        fallbackOffset: 10,
        fallbackLength: 10,
      );
      final List<AudioCue> span = miningSentenceCueSpan(
        cues: cues,
        cue: cues[1],
        sentence: selection.text,
        sectionIndex: 0,
        sentenceNormCharOffset: selection.offset,
        sentenceNormCharLength: selection.length,
      );
      expect(span, hasLength(3),
          reason:
              'native selection must override the narrower cached sentence');

      final AudioPlaybackRange range = clipExportGlobalRange(
        span: span,
        allCues: cues,
        headPadMs: 0,
        tailPadMs: 0,
      )!;
      final AudiobookClipMultiCueResult classified =
          classifyAudiobookClipMultiCue(
        selectedText: selection.text,
        audioFileCount: 1,
        globalRange: range,
        cueSpans: clipCueSpansWithDelay(span: span, delayMs: 0),
      );
      expect(classified.isExportable, isTrue);
      expect(
        audiobookClipCueTextMatchesSelection(
          selectedText: selection.text,
          cueSpans: classified.cueSpans,
        ),
        isTrue,
      );
      final List<int> highlights = clipFramePlan(
        cues: span,
        globalStartMs: classified.globalStartMs,
        globalEndMs: classified.globalEndMs,
        fps: 2,
      ).map((ClipFrameSpec frame) => frame.highlightCueIndex).toList();
      expect(highlights, <int>[0, 1, 2],
          reason: 'the production frame plan must highlight each selected cue');
    });
  });
}
