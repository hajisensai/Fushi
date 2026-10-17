import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/ai/ai_failure_text.dart';
import 'package:fushi/src/media/audiobook/tts/studio/tts_cast_annotator.dart';
import 'package:fushi/src/media/audiobook/tts/studio/tts_studio_text.dart';
import 'package:fushi/src/media/audiobook/tts/tts_book_plan.dart';
import 'package:fushi/src/media/audiobook/tts/tts_ui_text.dart';
import 'package:fushi_engine/tts/render/tts_cast.dart';
import 'package:fushi_engine/tts/render/tts_pause.dart';
import 'package:fushi_engine/tts/render/tts_render_queue.dart';
import 'package:fushi_engine/tts/tts_types.dart';

TtsRenderJob _job({
  TtsRenderJobStatus status = TtsRenderJobStatus.running,
  TtsRenderJobPhase? phase,
  int done = 0,
  int total = 0,
  String? error,
}) => TtsRenderJob(
  id: 'j',
  bookKey: 'b',
  title: 'T',
  presetId: 'p',
  sections: const <int>[],
  verify: false,
  createdAt: 0,
  updatedAt: 0,
  status: status,
  phase: phase,
  done: done,
  total: total,
  error: error,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  group('ttsRenderFailureText', () {
    test('maps studio failure codes', () {
      expect(
        ttsRenderFailureText('voice_missing'),
        t.audiobook_studio_failure_voice_missing,
      );
      expect(
        ttsRenderFailureText('voice_unavailable'),
        t.audiobook_studio_failure_voice_unavailable,
      );
      expect(
        ttsRenderFailureText('book_missing'),
        t.audiobook_studio_failure_book_missing,
      );
      expect(
        ttsRenderFailureText('encode_failed'),
        t.audiobook_studio_failure_encode_failed,
      );
      expect(
        ttsRenderFailureText('internal'),
        t.audiobook_studio_failure_internal,
      );
      expect(
        ttsRenderFailureText('voice_incomplete'),
        t.audiobook_tts_voice_incomplete,
      );
      expect(ttsRenderFailureText('empty_book'), t.audiobook_tts_empty_book);
    });

    test('maps tts_<code> to the TTS failure text', () {
      expect(
        ttsRenderFailureText('tts_network'),
        ttsFailureText(const TtsFailure(TtsFailureCode.network)),
      );
      expect(
        ttsRenderFailureText('tts_rateLimited'),
        ttsFailureText(const TtsFailure(TtsFailureCode.rateLimited)),
      );
    });

    test('unknown codes fall back to internal', () {
      expect(
        ttsRenderFailureText('tts_nope'),
        t.audiobook_studio_failure_internal,
      );
      expect(ttsRenderFailureText('???'), t.audiobook_studio_failure_internal);
      expect(ttsRenderFailureText(null), t.audiobook_studio_failure_internal);
    });
  });

  group('ttsRenderJobStatusText', () {
    test('running phases carry progress', () {
      expect(
        ttsRenderJobStatusText(_job(phase: TtsRenderJobPhase.planning)),
        t.audiobook_studio_phase_planning,
      );
      expect(
        ttsRenderJobStatusText(
          _job(phase: TtsRenderJobPhase.synthesizing, done: 3, total: 10),
        ),
        t.audiobook_studio_phase_synthesizing(done: 3, total: 10),
      );
      expect(
        ttsRenderJobStatusText(
          _job(phase: TtsRenderJobPhase.encoding, done: 1, total: 4),
        ),
        t.audiobook_studio_phase_encoding(done: 1, total: 4),
      );
      expect(
        ttsRenderJobStatusText(
          _job(phase: TtsRenderJobPhase.verifying, done: 2, total: 4),
        ),
        t.audiobook_studio_phase_verifying(done: 2, total: 4),
      );
      expect(
        ttsRenderJobStatusText(_job(phase: TtsRenderJobPhase.importing)),
        t.audiobook_studio_phase_importing,
      );
    });

    test('terminal and queued states', () {
      expect(
        ttsRenderJobStatusText(_job(status: TtsRenderJobStatus.queued)),
        t.audiobook_studio_status_queued,
      );
      expect(
        ttsRenderJobStatusText(_job(status: TtsRenderJobStatus.done)),
        t.audiobook_studio_status_done,
      );
      expect(
        ttsRenderJobStatusText(_job(status: TtsRenderJobStatus.cancelled)),
        t.audiobook_studio_status_cancelled,
      );
      expect(
        ttsRenderJobStatusText(
          _job(status: TtsRenderJobStatus.failed, error: 'encode_failed'),
        ),
        t.audiobook_studio_status_failed(
          reason: t.audiobook_studio_failure_encode_failed,
        ),
      );
    });
  });

  test('ttsRenderJobProgress', () {
    expect(ttsRenderJobProgress(_job()), isNull);
    expect(
      ttsRenderJobProgress(
        _job(phase: TtsRenderJobPhase.synthesizing, done: 5, total: 20),
      ),
      0.25,
    );
    expect(ttsRenderJobProgress(_job(status: TtsRenderJobStatus.done)), 1);
    expect(
      ttsRenderJobProgress(_job(status: TtsRenderJobStatus.queued)),
      isNull,
    );
  });

  group('cast helpers', () {
    test('ttsCastAnnotateFailureText', () {
      expect(
        ttsCastAnnotateFailureText(const TtsCastAnnotateFailure('cancelled')),
        isNull,
      );
      expect(
        ttsCastAnnotateFailureText(
          const TtsCastAnnotateFailure('no_ai_provider'),
        ),
        t.audiobook_studio_cast_no_ai,
      );
      expect(
        ttsCastAnnotateFailureText(const TtsCastAnnotateFailure('bad_output')),
        t.audiobook_studio_cast_failure_bad_output,
      );
      expect(
        ttsCastAnnotateFailureText(
          const TtsCastAnnotateFailure('ai_failed', 'rate_limited'),
        ),
        t.audiobook_studio_cast_failed(reason: aiFailureText('rate_limited')),
      );
      expect(
        ttsCastAnnotateFailureText(const TtsCastAnnotateFailure('ai_failed')),
        t.audiobook_studio_cast_failed(
          reason: t.audiobook_studio_failure_internal,
        ),
      );
    });

    test('ttsCastAnnotatedCount counts only the given chapters', () {
      final TtsCast cast = TtsCast(annotatedSections: <int>{1, 3, 9});
      expect(ttsCastAnnotatedCount(cast, <int>[1, 2, 3]), 2);
      expect(ttsCastAnnotatedCount(cast, <int>[]), 0);
    });

    test('ttsCastIsReviewLine: quoted or already cast', () {
      TtsPlanSentence s(String text, int matchStart) => TtsPlanSentence(
        section: 2,
        href: 'c.xhtml',
        text: text,
        spokenText: text,
        matchStart: matchStart,
        matchEnd: matchStart + text.length,
        studyStart: 0,
        studyEnd: 0,
      );
      final TtsCast cast = TtsCast()..setUserSpeaker(2, 40, 'A');
      expect(ttsCastIsReviewLine(cast, s('「おはよう」', 0)), isTrue);
      expect(ttsCastIsReviewLine(cast, s('地の文。', 10)), isFalse);
      expect(ttsCastIsReviewLine(cast, s('地の文。', 40)), isTrue);
    });
  });

  group('cast roster / review helpers', () {
    test('ttsCastAnnotateProgressText distinguishes phases', () {
      expect(
        ttsCastAnnotateProgressText(kTtsCastPhaseRoster, 1, 4),
        t.audiobook_studio_cast_phase_roster(done: 1, total: 4),
      );
      expect(
        ttsCastAnnotateProgressText(kTtsCastPhaseLines, 2, 4),
        t.audiobook_studio_cast_progress(done: 2, total: 4),
      );
      expect(
        ttsCastAnnotateProgressText(null, 0, 0),
        t.audiobook_studio_cast_progress(done: 0, total: 0),
      );
    });

    test('unknown count and character rows include roster-only names', () {
      final TtsCast cast =
          TtsCast(
              roster: <String, TtsCastCharacter>{
                'A': const TtsCastCharacter(name: 'A'),
                'C': const TtsCastCharacter(name: 'C'),
              },
            )
            ..setUserSpeaker(0, 0, 'A')
            ..setUserSpeaker(0, 5, 'A')
            ..setUserSpeaker(0, 9, 'B')
            ..setUserSpeaker(0, 12, kTtsUnknown);
      final List<({String speaker, int count})> speakers = cast.speakers();
      expect(ttsCastUnknownCount(speakers), 1);
      expect(
        ttsCastCharacterRows(cast, speakers),
        <({String speaker, int count})>[
          (speaker: 'A', count: 2),
          (speaker: 'B', count: 1),
          (speaker: 'C', count: 0),
        ],
      );
    });

    test('ttsCastCharacterTraits', () {
      expect(ttsCastCharacterTraits(null), isNull);
      expect(ttsCastCharacterTraits(const TtsCastCharacter(name: 'X')), isNull);
      expect(
        ttsCastCharacterTraits(
          const TtsCastCharacter(
            name: 'X',
            gender: 'female',
            age: 'teen',
            aliases: <String>['x1', 'x2'],
            description: ' cheerful ',
          ),
        ),
        <String>[
          t.audiobook_studio_cast_gender_female,
          t.audiobook_studio_cast_age_teen,
          t.audiobook_studio_cast_aliases(names: 'x1、x2'),
          'cheerful',
        ].join(' · '),
      );
    });

    test('ttsCastLineSubtitle shows confidence and evidence for llm lines', () {
      expect(ttsCastLineSubtitle(null), t.audiobook_studio_cast_narrator);
      expect(
        ttsCastLineSubtitle(
          const TtsCastLine(
            speaker: kTtsUnknown,
            source: TtsCastSource.llm,
            confidence: 0.42,
            evidence: TtsCastEvidence.implicit,
          ),
        ),
        <String>[
          t.audiobook_studio_cast_unknown,
          t.audiobook_studio_cast_confidence(pct: 42),
          t.audiobook_studio_cast_evidence_implicit,
        ].join(' · '),
      );
      expect(
        ttsCastLineSubtitle(
          const TtsCastLine(
            speaker: 'A',
            source: TtsCastSource.user,
            confidence: 0.1,
          ),
        ),
        'A',
      );
    });

    test('review-only filter keeps only lines needing review', () {
      TtsPlanSentence s(int matchStart) => TtsPlanSentence(
        section: 1,
        href: 'c.xhtml',
        text: '「x」',
        spokenText: '「x」',
        matchStart: matchStart,
        matchEnd: matchStart + 1,
        studyStart: 0,
        studyEnd: 0,
      );
      final TtsCast cast = TtsCast(
        lines: <String, TtsCastLine>{
          ttsLineKey(1, 0): const TtsCastLine(
            speaker: 'A',
            source: TtsCastSource.llm,
            confidence: 0.3,
          ),
          ttsLineKey(1, 10): const TtsCastLine(
            speaker: 'A',
            source: TtsCastSource.llm,
            confidence: 0.95,
            evidence: TtsCastEvidence.explicit,
          ),
        },
      );
      expect(ttsCastIsReviewLine(cast, s(0), reviewOnly: true), isTrue);
      expect(ttsCastIsReviewLine(cast, s(10), reviewOnly: true), isFalse);
      expect(ttsCastIsReviewLine(cast, s(20), reviewOnly: true), isFalse);
      expect(ttsCastIsReviewLine(cast, s(20)), isTrue);
    });
  });

  group('render options / export helpers', () {
    test('pause preset labels', () {
      expect(
        ttsPausePresetLabel(TtsPausePreset.none),
        t.audiobook_studio_pause_none,
      );
      expect(
        ttsPausePresetLabel(TtsPausePreset.literary),
        t.audiobook_studio_pause_literary,
      );
    });

    test('export failure text and file name', () {
      expect(
        ttsAudiobookExportFailureText('export_unsupported'),
        t.audiobook_studio_export_unsupported,
      );
      expect(
        ttsAudiobookExportFailureText('export_unsupported', ' muxer ipod '),
        '${t.audiobook_studio_export_unsupported}\nmuxer ipod',
      );
      expect(
        ttsAudiobookExportFailureText('export_failed', 'ffmpeg exit 1'),
        t.audiobook_studio_export_failed(reason: 'ffmpeg exit 1'),
      );
      expect(
        ttsAudiobookExportFailureText('export_failed'),
        t.audiobook_studio_export_failed(
          reason: t.audiobook_studio_failure_internal,
        ),
      );
      expect(ttsAudiobookExportFileName('a/b: c?'), 'a_b_ c_.m4b');
      expect(ttsAudiobookExportFileName('  '), 'audiobook.m4b');
    });
  });
}
