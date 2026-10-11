import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/ai/ai_failure_text.dart';
import 'package:fushi/src/media/audiobook/tts/studio/tts_cast_annotator.dart';
import 'package:fushi/src/media/audiobook/tts/studio/tts_studio_page.dart';
import 'package:fushi/src/media/audiobook/tts/tts_book_plan.dart';
import 'package:fushi/src/media/audiobook/tts/tts_ui_text.dart';
import 'package:fushi_engine/tts/render/tts_cast.dart';
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
}
