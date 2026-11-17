import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/audiobook/tts/studio/tts_unvoiced_backfill.dart';
import 'package:fushi/src/media/audiobook/tts/studio/tts_unvoiced_page.dart';
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart';
import 'package:fushi_engine/tts/tts_types.dart';
import 'package:material_ui/material_ui.dart';

/// 「未配音」列表：列出账本里的句子，单句 / 批量补回把对应请求交给补回服务，
/// 补回后按账本重读。

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  testWidgets('lists ledger lines and sends backfill requests', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    List<TtsUnvoicedLineView> ledger = <TtsUnvoicedLineView>[
      (lineId: '1:0', text: 'いちばん目', code: 'rejected', attempts: 2),
      (lineId: '1:10', text: 'にばん目', code: 'voice_missing', attempts: 1),
    ];
    final List<List<TtsBackfillRequest>> sent = <List<TtsBackfillRequest>>[];
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: TtsUnvoicedPage(
            load: () async => ledger,
            backfill:
                (
                  List<TtsBackfillRequest> requests,
                  void Function(int done, int total) onProgress,
                ) async {
                  sent.add(requests);
                  onProgress(requests.length, requests.length);
                  // 第一句补回成功：账本里只剩第二句。
                  ledger = <TtsUnvoicedLineView>[ledger.last];
                  return const TtsBackfillResult(
                    succeeded: 1,
                    failed: 0,
                    exhausted: 0,
                    renderQueued: true,
                    renderBusy: false,
                  );
                },
            voiceOptions: () => const <FushiChoiceOption<String>>[
              FushiChoiceOption<String>(value: 'v1', label: 'Voice one'),
            ],
            retryVoicesSummary: () => 'Retry A, Retry B',
            onEditRetryVoices: () async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text(t.audiobook_studio_unvoiced_count(n: 2)), findsOneWidget);
    expect(find.text('いちばん目'), findsOneWidget);
    expect(
      find.text(
        t.audiobook_studio_unvoiced_attempts(
          n: 2,
          reason: ttsUnvoicedCodeText('rejected'),
        ),
      ),
      findsOneWidget,
    );

    // 单句「换配置重试」。
    await tester.tap(
      find.byKey(const ValueKey<String>('tts-unvoiced-line-1:0-retry')),
    );
    await tester.pumpAndSettle();
    expect(sent, hasLength(1));
    expect(sent.single.single.lineId, '1:0');
    expect(sent.single.single.strategy, TtsBackfillStrategy.retryNext);
    // 补回后按账本重读。
    expect(find.text('いちばん目'), findsNothing);
    expect(find.text(t.audiobook_studio_unvoiced_count(n: 1)), findsOneWidget);

    // 指定声音。
    await tester.tap(
      find.byKey(const ValueKey<String>('tts-unvoiced-line-1:10-voice')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Voice one'));
    await tester.pumpAndSettle();
    expect(sent.last.single.strategy, TtsBackfillStrategy.voice);
    expect(sent.last.single.voice, 'v1');

    // 全部换配置重试。
    await tester.tap(
      find.byKey(const ValueKey<String>('tts-unvoiced-retry-all')),
    );
    await tester.pumpAndSettle();
    expect(sent.last.map((TtsBackfillRequest r) => r.lineId), <String>['1:10']);
  });

  test('code text covers engine and studio codes', () {
    LocaleSettings.setLocale(AppLocale.en);
    expect(
      ttsUnvoicedCodeText('voice_missing'),
      t.audiobook_studio_failure_voice_missing,
    );
    expect(
      ttsUnvoicedCodeText(TtsFailureCode.rejected.name),
      isNot(t.audiobook_studio_failure_internal),
    );
    expect(
      ttsBackfillResultText(
        const TtsBackfillResult(
          succeeded: 0,
          failed: 0,
          exhausted: 3,
          renderQueued: false,
          renderBusy: true,
        ),
      ),
      '${t.audiobook_studio_unvoiced_exhausted(n: 3)}\n'
      '${t.audiobook_studio_unvoiced_render_busy}',
    );
  });
}
