import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/audiobook_clip_export.dart';
import 'package:fushi_audio/fushi_audio.dart';

import '../../helpers/source_guard.dart';

/// BUG-1320：超时长上限此前被并进 unsupportedRange，同章长选区被误报
/// 「跨章或跨音频文件」。守卫三件事：
/// ① 单句/多句分类都把「太长」归 [AudiobookClipBoundaryKind.tooLong]（而非
///    unsupportedRange），调用方才能给诚实文案；
/// ② 上限 = 300s（单一真相源常量），i18n 文案里的「5 分钟」与之同步；
/// ③ 长片段的动态帧率按总帧数预算收敛（clipExportFps），提限不引爆临时盘。
void main() {
  group('classifyAudiobookClipSelection duration cap (BUG-1320)', () {
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

  group('classifyAudiobookClipMultiCue duration cap (BUG-1320)', () {
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

  group('cap constant ↔ i18n copy stay in sync (BUG-1320)', () {
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

  // BUG-1320 第二根因：多句路径判出 tooLong 后，调度层旧写法一个 `return null` 把窗口
  // 一起销毁，于是回落 _currentSentenceAudioRange() 的单句锚——用户报的场景（拖选一大段
  // 超长文本）根本走不到上面那条诚实文案分支，仍然产出「整段文字的卡片 + 只有一句声音」，
  // 或弹出误导的「跨章或跨音频文件」。下面按真实调度顺序把三个纯函数串起来跑，钉住
  // 「超长多句选区最终判 tooLong」这条端到端契约（上面的单元测试各自绿也盖不住这个洞）。
  group('multi-cue tooLong reaches the user (BUG-1320)', () {
    // 用户拖选了 6 分钟的多句选区。
    final AudioPlaybackRange longGlobalRange = AudioPlaybackRange(
      audioFileIndex: 0,
      startMs: 0,
      endMs: kAudiobookClipMaxDurationMs + 60 * 1000,
    );
    // 同一时刻 currentSentence 的单句锚只有 3 秒——旧实现回落到它，于是「太长」被
    // 洗成「可导出」，静默产出全文卡片 + 一句声音。
    final AudioPlaybackRange shortSentenceAnchor = AudioPlaybackRange(
      audioFileIndex: 0,
      startMs: 0,
      endMs: 3000,
    );
    const String selectedText = '拖选了一大段の非常に長いテキスト';

    AudiobookClipMultiCueResult multiCue(AudioPlaybackRange? globalRange) {
      return classifyAudiobookClipMultiCue(
        selectedText: selectedText,
        audioFileCount: 1,
        globalRange: globalRange,
        cueSpans: const <AudiobookClipCueSpan>[
          AudiobookClipCueSpan(text: '一句目', startMs: 0, endMs: 1000),
          AudiobookClipCueSpan(text: '二句目', startMs: 1000, endMs: 2000),
        ],
      );
    }

    /// 复刻 `_exportAudiobookClip` 的真实调度：计划窗口优先，只有真没窗口才回落单句锚。
    AudiobookClipBoundaryKind dispatch(AudioPlaybackRange? globalRange) {
      final AudiobookClipMultiCueResult result = multiCue(globalRange);
      final AudioPlaybackRange sentenceRange = audiobookClipPlanRange(
            kind: result.kind,
            globalRange: globalRange,
          ) ??
          shortSentenceAnchor;
      return classifyAudiobookClipSelection(
        selectedText: selectedText,
        audioFileCount: 1,
        sentenceRange: sentenceRange,
      ).kind;
    }

    test('超长多句选区最终判 tooLong，不被单句锚洗成 exportable', () {
      expect(multiCue(longGlobalRange).kind, AudiobookClipBoundaryKind.tooLong);
      expect(
        dispatch(longGlobalRange),
        AudiobookClipBoundaryKind.tooLong,
        reason: '旧实现把 tooLong 压成 null → 回落 3 秒单句锚 → 判 exportable → '
            '静默导出「整段文字的卡片 + 只有一句声音」，用户永远看不到诚实文案',
      );
    });

    test('audiobookClipPlanRange：tooLong 透传窗口，没窗口的三类才回落单句锚', () {
      expect(
        audiobookClipPlanRange(
          kind: AudiobookClipBoundaryKind.tooLong,
          globalRange: longGlobalRange,
        ),
        same(longGlobalRange),
        reason: 'tooLong 的窗口是选区真实音频范围，销毁它就是销毁信号本身',
      );
      expect(
        audiobookClipPlanRange(
          kind: AudiobookClipBoundaryKind.exportable,
          globalRange: longGlobalRange,
        ),
        same(longGlobalRange),
      );
      for (final AudiobookClipBoundaryKind kind in <AudiobookClipBoundaryKind>[
        AudiobookClipBoundaryKind.emptySelection,
        AudiobookClipBoundaryKind.noAudio,
        AudiobookClipBoundaryKind.unsupportedRange,
      ]) {
        expect(
          audiobookClipPlanRange(kind: kind, globalRange: longGlobalRange),
          isNull,
          reason: '$kind 多句路径没拿到可信窗口，回落单句锚是既有正确行为，不得改动',
        );
      }
    });

    test('真解析不出窗口时仍回落单句锚（不误伤既有行为）', () {
      // globalRange 为 null → unsupportedRange → 回落 3 秒单句锚 → 仍可导出单句。
      expect(multiCue(null).kind, AudiobookClipBoundaryKind.unsupportedRange);
      expect(dispatch(null), AudiobookClipBoundaryKind.exportable);
    });
  });

  group('dispatcher wiring keeps the tooLong window (BUG-1320)', () {
    late final String part;

    setUpAll(() {
      part = File(
        'lib/src/pages/implementations/reader_hibiki/audiobook.part.dart',
      ).readAsStringSync().replaceAll('\r\n', '\n');
    });

    test('_buildAudiobookClipPlan 用 audiobookClipPlanRange，而不是裸 return null',
        () {
      final String body = methodBody(part, '_buildAudiobookClipPlan({');
      expect(
        containsIdentifierCall(body, 'audiobookClipPlanRange'),
        isTrue,
        reason: 'BUG-1320：不可导出时若直接 return null，tooLong 与 unsupportedRange '
            '会被压成同一个信号，超长选区又会回落单句锚',
      );
      expect(
        containsCodeLine(body, 'if (!result.isExportable) return null;'),
        isFalse,
        reason: '这行正是吞掉 tooLong 信号的那一行，不得复活',
      );
      // 可导出时也必须把窗口带回去（调度方只认 clipPlan.range）。这条同时证明上面的
      // methodBody 窗口一路覆盖到方法末尾的 return，没有被字符串/嵌套花括号截断——
      // 否则上面的 isFalse 会静默变绿。
      expect(
        containsCodeLine(body, 'range: planRange,'),
        isTrue,
        reason: 'BUG-1320：计划非空时窗口也必须随记录带回，否则 exportable 路径同样会'
            '回落单句锚',
      );
    });

    test('_exportAudiobookClip 只在计划没窗口时才回落单句锚', () {
      final String body = methodBody(part, 'void _exportAudiobookClip() {');
      expect(
        containsCodeLine(
            body, 'clipPlan.range ?? _currentSentenceAudioRange()'),
        isTrue,
        reason: 'BUG-1320：窗口必须以多句计划为准，plan 为空不等于「没窗口」——'
            '超上限时 plan 为空但窗口有效，回落单句锚会把「太长」洗掉',
      );
    });
  });

  group('clipExportFps frame budget (BUG-1320)', () {
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
