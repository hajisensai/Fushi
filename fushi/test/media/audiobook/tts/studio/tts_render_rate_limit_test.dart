import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/audiobook/tts/studio/tts_render_runner.dart';
import 'package:fushi/src/media/audiobook/tts/studio/tts_render_unvoiced.dart';
import 'package:fushi/src/media/audiobook/tts/studio/tts_render_verify.dart';
import 'package:fushi/src/media/audiobook/tts/studio/tts_studio_text.dart';
import 'package:fushi_engine/tts/providers/edge_tts_provider.dart';
import 'package:fushi_engine/tts/providers/gpt_sovits_tts_provider.dart';
import 'package:fushi_engine/tts/render/tts_render_queue.dart';
import 'package:fushi_engine/tts/tts_pronunciation.dart';
import 'package:fushi_engine/tts/tts_provider.dart';
import 'package:fushi_engine/tts/tts_retry.dart';
import 'package:fushi_engine/tts/tts_types.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/tts/studio/tts_studio_rate_limit_panel.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';
import 'package:material_ui/material_ui.dart';

/// 11-20 反馈 #9：限流面板的参数确实进了合成任务（并发 / 每句间隔 / 被限流时），
/// 429 不再变成占位静音；#8 的「识别后替换」进了语音识别校对。

TtsRenderJob _job({
  int? concurrency,
  int gapMs = 0,
  TtsRateLimitAction action = TtsRateLimitAction.waitRetry,
}) => TtsRenderJob(
  id: '1',
  bookKey: 'b',
  title: 't',
  presetId: 'p',
  sections: const <int>[],
  verify: false,
  createdAt: 0,
  updatedAt: 0,
  onlineConcurrency: concurrency,
  sentenceGapMs: gapMs,
  rateLimitAction: action,
);

const TtsVoicePreset _edge = TtsVoicePreset(
  id: 'e',
  providerId: EdgeTtsDescriptor.providerId,
  name: 'Edge',
);
const TtsVoicePreset _sovits = TtsVoicePreset(
  id: 's',
  providerId: GptSovitsTtsDescriptor.providerId,
  name: 'SoVITS',
);

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  group('ttsRenderVoicePacing', () {
    test('online voice takes the job concurrency and gap', () {
      final ({int concurrency, Duration gap}) pacing = ttsRenderVoicePacing(
        _job(concurrency: 4, gapMs: 300),
        const EdgeTtsDescriptor(),
        _edge,
      );
      expect(pacing.concurrency, 4);
      expect(pacing.gap, const Duration(milliseconds: 300));
    });

    test('online voice without a job value keeps the preset concurrency', () {
      final ({int concurrency, Duration gap}) pacing = ttsRenderVoicePacing(
        _job(),
        const EdgeTtsDescriptor(),
        _edge,
      );
      expect(
        pacing.concurrency,
        ttsEffectiveConcurrency(const EdgeTtsDescriptor(), _edge),
      );
      expect(pacing.gap, Duration.zero);
    });

    test('local / self-hosted voices ignore the online throttle', () {
      expect(
        const GptSovitsTtsDescriptor().category,
        isNot(TtsProviderCategory.online),
      );
      final ({int concurrency, Duration gap}) pacing = ttsRenderVoicePacing(
        _job(concurrency: 4, gapMs: 1000),
        const GptSovitsTtsDescriptor(),
        _sovits,
      );
      expect(
        pacing.concurrency,
        ttsEffectiveConcurrency(const GptSovitsTtsDescriptor(), _sovits),
      );
      expect(pacing.gap, Duration.zero);
    });
  });

  group('rate limit handling', () {
    test('the job action picks the retry policy', () {
      expect(
        identical(
          ttsRenderRetryPolicy(_job()),
          TtsRetryPolicy.patientRateLimit,
        ),
        isTrue,
      );
      expect(
        identical(
          ttsRenderRetryPolicy(_job(action: TtsRateLimitAction.pause)),
          TtsRetryPolicy.pauseOnRateLimit,
        ),
        isTrue,
      );
    });

    test('429 is never a per-line placeholder', () {
      expect(
        ttsFailureIsPerLine(const TtsFailure(TtsFailureCode.rateLimited)),
        isFalse,
      );
      expect(
        ttsFailureIsPerLine(const TtsFailure(TtsFailureCode.rejected)),
        isTrue,
      );
    });

    test('pause turns a 429 into the resumable paused code', () {
      const TtsFailure limited = TtsFailure(TtsFailureCode.rateLimited);
      expect(
        ttsRenderFailureCodeFor(
          _job(action: TtsRateLimitAction.pause),
          limited,
        ),
        'rate_limited_paused',
      );
      expect(ttsRenderFailureCodeFor(_job(), limited), 'tts_rateLimited');
      expect(
        ttsRenderFailureText('rate_limited_paused'),
        t.audiobook_studio_failure_rate_limited_paused,
      );
    });
  });

  group('rate limit panel helpers', () {
    test('estimate splits sentences across lanes and adds the gap', () {
      expect(
        ttsStudioEstimateMinutes(sentences: 0, concurrency: 2, gapMs: 0),
        0,
      );
      // 240 句 / 2 路 = 120 个请求 × 1.5 s = 3 分钟。
      expect(
        ttsStudioEstimateMinutes(sentences: 240, concurrency: 2, gapMs: 0),
        3,
      );
      // 加 500 ms 间隔：120 × 2 s = 4 分钟。
      expect(
        ttsStudioEstimateMinutes(sentences: 240, concurrency: 2, gapMs: 500),
        4,
      );
    });

    test('custom preset concurrency shows up as its own segment', () {
      expect(ttsStudioConcurrencySegments(1), <int>[1, 2, 4]);
      expect(ttsStudioConcurrencySegments(3), <int>[1, 2, 3, 4]);
      expect(ttsStudioConcurrencySegments(8), <int>[1, 2, 4, 8]);
      expect(ttsStudioConcurrencySegments(99), <int>[1, 2, 4, 8]);
    });
  });

  group('post-recognition replacements in ASR proofreading', () {
    const TtsVerifySentence sentence = TtsVerifySentence(
      planIndex: 0,
      text: '今日は晴れ',
      spokenText: '今日は晴れ',
      startMs: 0,
      endMs: 1000,
    );
    const List<TtsHeardToken> heard = <TtsHeardToken>[
      TtsHeardToken(atMs: 100, text: 'キョウ'),
      TtsHeardToken(atMs: 400, text: 'ハ晴れ'),
    ];

    test('without rules the respelled reading is flagged', () {
      expect(
        flagTtsChapterSentences(
          sentences: const <TtsVerifySentence>[sentence],
          heard: heard,
          threshold: 0.9,
        ),
        hasLength(1),
      );
    });

    test('rules spanning tokens turn it back before comparing', () {
      expect(
        flagTtsChapterSentences(
          sentences: const <TtsVerifySentence>[sentence],
          heard: heard,
          threshold: 0.9,
          heardRewrites: const <TtsPronunciationRule>[
            TtsPronunciationRule(written: 'キョウハ', spoken: '今日は'),
          ],
        ),
        isEmpty,
      );
    });
  });

  testWidgets('panel controls report the chosen parameters', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    int? concurrency;
    TtsRateLimitAction? action;
    int local = 0, chapters = 0;
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: ListView(
              children: <Widget>[
                TtsStudioRateLimitPanel(
                  sentences: 243,
                  concurrency: 2,
                  sentenceGapMs: 300,
                  action: TtsRateLimitAction.waitRetry,
                  onConcurrencyChanged: (int n) => concurrency = n,
                  onGapChanged: (_) {},
                  onActionChanged: (TtsRateLimitAction v) => action = v,
                  onUseLocalVoice: () => local++,
                  onSelectedChaptersOnly: () => chapters++,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text(t.audiobook_studio_rate_limit_estimate(n: 243, minutes: 4)),
      findsOneWidget,
    );
    await tester.tap(find.text('4'));
    await tester.pumpAndSettle();
    expect(concurrency, 4);
    // 长文案在窄行里会被设计系统换成菜单行，这里直接走行的回调。
    tester
        .widget<AdaptiveSettingsSegmentedRow<TtsRateLimitAction>>(
          find.byKey(const ValueKey<String>('tts-studio-rate-limit-action')),
        )
        .onChanged(TtsRateLimitAction.pause);
    expect(action, TtsRateLimitAction.pause);
    await tester.tap(find.text(t.audiobook_studio_rate_limit_use_local));
    await tester.tap(find.text(t.audiobook_studio_rate_limit_selected_only));
    await tester.pumpAndSettle();
    expect((local, chapters), (1, 1));
  });
}
