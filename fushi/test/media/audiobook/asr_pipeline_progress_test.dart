import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/asr_pipeline_progress.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_audio/fushi_audio_core.dart';
import 'package:fushi_engine/media/audiobook/audiobook_alignment_service.dart'
    show AudiobookAlignmentStep;
import 'package:fushi_engine/media/audiobook/audiobook_text_coverage.dart';
import 'package:fushi_engine/media/audiobook/audiobook_transcribe_import_queue.dart';
import 'package:material_ui/material_ui.dart';

const AsrStageState _p = AsrStageState.pending;
const AsrStageState _a = AsrStageState.active;
const AsrStageState _d = AsrStageState.done;
const AsrStageState _s = AsrStageState.skipped;
const AsrStageState _f = AsrStageState.failed;

CueMatch _hit(int section, int start, int end) => CueMatch(
  cueSentenceIndex: 0,
  sectionIndex: section,
  normCharStart: start,
  normCharEnd: end,
  score: 1,
);

MatchResult _result(List<CueMatch> matches) => MatchResult(
  matches: matches,
  totalCues: matches.length,
  matchedCues: matches.where((CueMatch m) => m.matched).length,
);

AudiobookTranscribeJob _job({
  AudiobookTranscribeJobStatus status = AudiobookTranscribeJobStatus.running,
  AudiobookTranscribeJobPhase? phase,
  String? contentPath = '/book.epub',
}) => AudiobookTranscribeJob(
  id: '1',
  title: 'T',
  audioPaths: const <String>['/a.mp3'],
  contentPath: contentPath,
  createdAt: 0,
  updatedAt: 0,
  status: status,
  phase: phase,
);

void main() {
  group('asrPipelineStates', () {
    test('当前格高亮，之前打勾，之后空心', () {
      expect(
        asrPipelineStates(current: AsrPipelineStage.transcribe),
        <AsrStageState>[_d, _d, _a, _p, _p],
      );
    });

    test('跳过的阶段在走过之后画成跳过，没走到时仍空心', () {
      const Set<AsrPipelineStage> skipped = <AsrPipelineStage>{
        AsrPipelineStage.downloadModel,
      };
      expect(
        asrPipelineStates(
          current: AsrPipelineStage.loadModel,
          skipped: skipped,
        ),
        <AsrStageState>[_s, _a, _p, _p, _p],
      );
      expect(asrPipelineStates(skipped: skipped), <AsrStageState>[
        _p,
        _p,
        _p,
        _p,
        _p,
      ]);
    });

    test('全部完成 / 只完成一部分 / 失败', () {
      expect(asrPipelineStates(allDone: true), <AsrStageState>[
        _d,
        _d,
        _d,
        _d,
        _d,
      ]);
      expect(
        asrPipelineStates(
          completed: const <AsrPipelineStage>{
            AsrPipelineStage.downloadModel,
            AsrPipelineStage.loadModel,
            AsrPipelineStage.transcribe,
          },
        ),
        <AsrStageState>[_d, _d, _d, _p, _p],
      );
      expect(
        asrPipelineStates(current: AsrPipelineStage.loadModel, failed: true),
        <AsrStageState>[_d, _f, _p, _p, _p],
      );
    });
  });

  group('asrPipelineStatesForJob', () {
    test('后台任务各阶段对到阶段轨', () {
      expect(asrPipelineStatesForJob(_job(phase: null)), <AsrStageState>[
        _a,
        _p,
        _p,
        _p,
        _p,
      ]);
      expect(
        asrPipelineStatesForJob(
          _job(phase: AudiobookTranscribeJobPhase.matching),
        ),
        <AsrStageState>[_d, _d, _d, _a, _p],
      );
      final AudiobookTranscribeJob skippedDownload = _job(
        phase: AudiobookTranscribeJobPhase.loadingModel,
      )..modelDownloadSkipped = true;
      expect(asrPipelineStatesForJob(skippedDownload), <AsrStageState>[
        _s,
        _a,
        _p,
        _p,
        _p,
      ]);
    });

    test('没有正文：匹配正文为跳过；完成全部走完；失败不画', () {
      expect(
        asrPipelineStatesForJob(
          _job(status: AudiobookTranscribeJobStatus.done, contentPath: null),
        ),
        <AsrStageState>[_d, _d, _d, _s, _d],
      );
      expect(
        asrPipelineStatesForJob(
          _job(status: AudiobookTranscribeJobStatus.queued),
        ),
        <AsrStageState>[_p, _p, _p, _p, _p],
      );
      expect(
        asrPipelineStatesForJob(
          _job(status: AudiobookTranscribeJobStatus.failed),
        ),
        isNull,
      );
    });
  });

  test('百分比：四舍五入但没完成时封顶 99%', () {
    expect(formatAsrPercent(0.426), '43%');
    expect(formatAsrPercent(0.996), '99%');
    expect(formatAsrPercent(1), '100%');
    expect(formatAsrPercent(-0.2), '0%');
    expect(
      asrAlignmentStepLabel(AudiobookAlignmentStep.finishing),
      t.audiobook_transcribe_step_finishing,
    );
  });

  group('computeTextCoverageFromLengths', () {
    test('分母是首处命中到末处命中；重叠只算一次；章内偏移换全书偏移', () {
      // 三章：100 / 50 / 100。第 0 章前 20 字（封面目录）与第 2 章末 30 字（后记）
      // 不在有效区间内；第 1 章 [10,20) 没命中。
      final AudiobookTextCoverage c = computeTextCoverageFromLengths(
        sectionNormLengths: const <int>[100, 50, 100],
        result: _result(<CueMatch>[
          _hit(0, 20, 60),
          _hit(0, 50, 100), // 与上一条叠 10 字
          _hit(1, 0, 10),
          _hit(1, 20, 50),
          CueMatch.unmatched,
          _hit(2, 0, 70),
        ]),
      );
      // 全书区间 [20, 220)：200 字；未覆盖 = 第 1 章 [10,20) = 10 字。
      expect(c.spanChars, 200);
      expect(c.coveredChars, 190);
      expect(c.charRate, closeTo(0.95, 1e-9));
      expect(c.matchedCues, 5);
      expect(c.totalCues, 6);
      expect(c.tier, AudiobookCoverageTier.poor);
    });

    test('越界与空区间忽略；没有命中时字符覆盖率为 null、按 cue 率分档', () {
      final AudiobookTextCoverage none = computeTextCoverageFromLengths(
        sectionNormLengths: const <int>[10],
        result: _result(<CueMatch>[CueMatch.unmatched, _hit(5, 0, 3)]),
      );
      expect(none.charRate, isNull);
      expect(none.spanChars, 0);
      final AudiobookTextCoverage clamped = computeTextCoverageFromLengths(
        sectionNormLengths: const <int>[10],
        result: _result(<CueMatch>[_hit(0, 2, 40), _hit(0, 5, 5)]),
      );
      expect(clamped.coveredChars, 8);
      expect(clamped.spanChars, 8);
      expect(clamped.tier, AudiobookCoverageTier.excellent);
    });

    test('分档阈值 98% / 96%', () {
      expect(audiobookCoverageTierOf(0.98), AudiobookCoverageTier.excellent);
      expect(audiobookCoverageTierOf(0.9799), AudiobookCoverageTier.acceptable);
      expect(audiobookCoverageTierOf(0.96), AudiobookCoverageTier.acceptable);
      expect(audiobookCoverageTierOf(0.9599), AudiobookCoverageTier.poor);
    });

    test('sidecar 往返；坏文件读成 null', () async {
      final Directory dir = await Directory.systemTemp.createTemp('asr_cov_');
      addTearDown(() => dir.delete(recursive: true));
      final String srt = '${dir.path}/transcript.srt';
      expect(readAsrCoverageSidecarSync(srt), isNull);
      const AudiobookTextCoverage c = AudiobookTextCoverage(
        matchedCues: 9,
        totalCues: 10,
        coveredChars: 97,
        spanChars: 100,
      );
      await writeAsrCoverageSidecar(srt, c);
      expect(readAsrCoverageSidecarSync(srt), c);
      File(asrCoveragePathFor(srt)).writeAsStringSync('{oops');
      expect(readAsrCoverageSidecarSync(srt), isNull);
    });
  });

  Widget host(Widget child) => TranslationProvider(
    child: MaterialApp(
      home: Scaffold(
        body: Padding(padding: const EdgeInsets.all(16), child: child),
      ),
    ),
  );

  testWidgets('阶段轨：五格各按状态画标记，跳过格带提示', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(
        AsrPipelineStageRail(states: const <AsrStageState>[_s, _d, _a, _p, _p]),
      ),
    );
    await tester.pumpAndSettle();
    for (final String key in <String>[
      'asr-pipeline-stage-0-skipped',
      'asr-pipeline-stage-1-done',
      'asr-pipeline-stage-2-active',
      'asr-pipeline-stage-3-pending',
      'asr-pipeline-stage-4-pending',
    ]) {
      expect(find.byKey(ValueKey<String>(key)), findsOneWidget, reason: key);
    }
    expect(find.text(t.audiobook_transcribe_stage_match_text), findsOneWidget);
    expect(
      find.byTooltip(t.audiobook_transcribe_stage_state_skipped),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('进度条：补间走到目标值后显示百分比；不定态不显示百分比', (WidgetTester tester) async {
    await tester.pumpWidget(host(const AsrSmoothedProgressBar(value: 0.2)));
    await tester.pumpAndSettle();
    expect(find.text('20%'), findsOneWidget);
    await tester.pumpWidget(host(const AsrSmoothedProgressBar(value: 0.6)));
    // 补间途中：既不是旧值也还没到新值。
    await tester.pump(const Duration(milliseconds: 60));
    final String mid = tester
        .widget<Text>(
          find.byKey(const ValueKey<String>('asr-progress-percent')),
        )
        .data!;
    expect(mid, isNot('60%'));
    await tester.pumpAndSettle();
    expect(find.text('60%'), findsOneWidget);
    await tester.pumpWidget(host(const AsrSmoothedProgressBar(value: null)));
    // 不定态的条一直在动，等不到 settle：推一帧就够看百分比在不在。
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      find.byKey(const ValueKey<String>('asr-progress-percent')),
      findsNothing,
    );
  });

  testWidgets('覆盖情况：按档着色，命中句数与覆盖率都在', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(
        const AsrCoverageSummary(
          coverage: AudiobookTextCoverage(
            matchedCues: 1234,
            totalCues: 1260,
            coveredChars: 973,
            spanChars: 1000,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('asr-coverage-tag-acceptable')),
      findsOneWidget,
    );
    expect(
      find.text(t.audiobook_transcribe_coverage_text(pct: '97.3')),
      findsOneWidget,
    );
    expect(
      find.text(
        t.audiobook_transcribe_coverage_cues(matched: 1234, total: 1260),
      ),
      findsOneWidget,
    );
  });
}
