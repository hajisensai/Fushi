import 'dart:io';
import 'dart:math';

import 'package:fushi_engine/foundation/pref_store.dart';
import 'package:fushi_engine/tts/render/tts_render_queue.dart';
import 'package:fushi_engine/tts/tts_pronunciation.dart';
import 'package:fushi_engine/tts/tts_retry.dart';
import 'package:fushi_engine/tts/tts_types.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 11-20 反馈 #8 / #9：TTS 文本规则只存一份（三类、按类通知），以及整本书制作的
/// 限流参数（随任务持久化）与 429 退避策略。

class _MapPrefs implements PrefStore {
  final Map<String, dynamic> values = <String, dynamic>{};

  @override
  dynamic getPref(String key, {dynamic defaultValue}) =>
      values.containsKey(key) ? values[key] : defaultValue;

  @override
  Future<void> setPref(String key, dynamic value) async => values[key] = value;
}

class _NeverRunner implements TtsRenderRunner {
  @override
  Future<({bool verified, List<TtsRenderFlag> flags})> run(
    TtsRenderJob job, {
    required TtsRenderProgress onProgress,
    required TtsRenderCancelToken cancel,
  }) => Future<({bool verified, List<TtsRenderFlag> flags})>.value((
    verified: false,
    flags: const <TtsRenderFlag>[],
  ));
}

void main() {
  group('TtsTextRulesStore', () {
    test('three kinds live under their own keys; pronunciation key frozen', () {
      expect(TtsTextRuleKind.pronunciation.prefKey, 'tts_pronunciation_rules');
      expect(
        TtsTextRuleKind.values.map((TtsTextRuleKind k) => k.prefKey).toSet(),
        hasLength(3),
      );
    });

    test('two views over one store see each other saves', () async {
      final _MapPrefs prefs = _MapPrefs();
      final TtsTextRulesStore store = TtsTextRulesStore(prefs);
      final List<TtsTextRuleKind> seen = <TtsTextRuleKind>[];
      store.changes.listen(seen.add);

      await store.save(
        TtsTextRuleKind.postRecognition,
        const <TtsPronunciationRule>[
          TtsPronunciationRule(written: 'きょう', spoken: '今日'),
        ],
      );

      expect(seen, <TtsTextRuleKind>[TtsTextRuleKind.postRecognition]);
      expect(store.load(TtsTextRuleKind.postRecognition).single.spoken, '今日');
      expect(store.load(TtsTextRuleKind.pronunciation), isEmpty);
      // 另一个读者（同一偏好表）读到的也是这一份。
      expect(
        TtsTextRulesStore(
          prefs,
        ).load(TtsTextRuleKind.postRecognition).single.written,
        'きょう',
      );
    });

    test('pre-synthesis rewrites apply after the pronunciation dictionary', () {
      expect(
        applyTtsSpokenRules(
          '今日〜',
          pronunciation: const <TtsPronunciationRule>[
            TtsPronunciationRule(written: '今日', spoken: 'きょう'),
          ],
          preSynthesis: const <TtsPronunciationRule>[
            TtsPronunciationRule(written: '〜', spoken: 'ー'),
            TtsPronunciationRule(written: 'きょう', spoken: 'キョウ'),
          ],
        ),
        'キョウー',
      );
    });
  });

  group('rate-limit retry policies', () {
    final Random rng = Random(1);
    const TtsFailure limitedLong = TtsFailure.withRetry(
      TtsFailureCode.rateLimited,
      retryAfter: Duration(seconds: 90),
    );

    test('default gives up on a long Retry-After, patient waits it out', () {
      expect(const TtsRetryPolicy().delayBefore(1, limitedLong, rng), isNull);
      expect(
        TtsRetryPolicy.patientRateLimit.delayBefore(1, limitedLong, rng),
        const Duration(seconds: 90),
      );
      // 第 8 次仍按 Retry-After，第 9 次才放弃。
      expect(
        TtsRetryPolicy.patientRateLimit.delayBefore(8, limitedLong, rng),
        const Duration(seconds: 90),
      );
      expect(
        TtsRetryPolicy.patientRateLimit.delayBefore(9, limitedLong, rng),
        isNull,
      );
    });

    test('without Retry-After the patient policy backs off exponentially', () {
      const TtsFailure limited = TtsFailure(TtsFailureCode.rateLimited);
      final Duration first = TtsRetryPolicy.patientRateLimit.delayBefore(
        1,
        limited,
        rng,
      )!;
      final Duration fourth = TtsRetryPolicy.patientRateLimit.delayBefore(
        4,
        limited,
        rng,
      )!;
      expect(first, lessThanOrEqualTo(const Duration(seconds: 2)));
      expect(fourth, greaterThanOrEqualTo(const Duration(seconds: 8)));
      expect(fourth, lessThanOrEqualTo(const Duration(seconds: 16)));
    });

    test('pause never retries a 429 but still retries other blips', () {
      expect(
        TtsRetryPolicy.pauseOnRateLimit.delayBefore(
          1,
          const TtsFailure(TtsFailureCode.rateLimited),
          rng,
        ),
        isNull,
      );
      expect(
        TtsRetryPolicy.pauseOnRateLimit.delayBefore(
          1,
          const TtsFailure(TtsFailureCode.network),
          rng,
        ),
        isNotNull,
      );
    });

    test('ttsWithRetry waits exactly the server Retry-After on 429', () async {
      int attempts = 0;
      final List<Duration> waits = <Duration>[];
      final String out = await ttsWithRetry<String>(
        () async {
          attempts++;
          if (attempts == 1) {
            throw const TtsFailure.withRetry(
              TtsFailureCode.rateLimited,
              retryAfter: Duration(milliseconds: 30),
            );
          }
          return 'ok';
        },
        cancel: TtsCancelToken(),
        policy: TtsRetryPolicy.patientRateLimit,
        onRetry: (int retry, TtsFailure failure, Duration delay) =>
            waits.add(delay),
      );
      expect(out, 'ok');
      expect(attempts, 2);
      expect(waits, <Duration>[const Duration(milliseconds: 30)]);
    });

    test(
      '429 retries do not eat the budget for other transient failures',
      () async {
        // 先连着 5 次 429（子策略允许 8 次），再来一次超时：默认策略的超时重试序号应从
        // 1 起，而不是接着 429 数到 6 后因超过 3 次立刻放弃。
        int attempts = 0;
        final List<(int, TtsFailureCode)> seen = <(int, TtsFailureCode)>[];
        final String out = await ttsWithRetry<String>(
          () async {
            attempts++;
            if (attempts <= 5) {
              throw const TtsFailure.withRetry(
                TtsFailureCode.rateLimited,
                retryAfter: Duration(milliseconds: 1),
              );
            }
            if (attempts == 6) throw const TtsFailure(TtsFailureCode.timeout);
            return 'ok';
          },
          cancel: TtsCancelToken(),
          policy: const TtsRetryPolicy(
            baseDelay: Duration(milliseconds: 1),
            maxDelay: Duration(milliseconds: 1),
            rateLimited: TtsRetryPolicy(
              maxRetries: 8,
              baseDelay: Duration(milliseconds: 1),
              maxDelay: Duration(milliseconds: 1),
            ),
          ),
          onRetry: (int retry, TtsFailure failure, Duration _) =>
              seen.add((retry, failure.code)),
        );
        expect(out, 'ok');
        expect(attempts, 7);
        expect(seen, <(int, TtsFailureCode)>[
          (1, TtsFailureCode.rateLimited),
          (2, TtsFailureCode.rateLimited),
          (3, TtsFailureCode.rateLimited),
          (4, TtsFailureCode.rateLimited),
          (5, TtsFailureCode.rateLimited),
          (1, TtsFailureCode.timeout),
        ]);
      },
    );
  });

  group('render job rate-limit parameters', () {
    test('enqueue persists concurrency, gap and action', () async {
      final Directory tmp = await Directory.systemTemp.createTemp('tts_rl_');
      addTearDown(() => tmp.delete(recursive: true));
      final TtsRenderQueue queue = TtsRenderQueue(
        store: File(p.join(tmp.path, 'jobs.json')),
        workRoot: Directory(p.join(tmp.path, 'work')),
        runner: _NeverRunner(),
      );
      final TtsRenderJob job = await queue.enqueue(
        bookKey: 'b',
        title: 't',
        presetId: 'edge',
        onlineConcurrency: 4,
        sentenceGapMs: 300,
        rateLimitAction: TtsRateLimitAction.pause,
      );
      expect(job.onlineConcurrency, 4);
      expect(job.sentenceGapMs, 300);
      expect(job.rateLimitAction, TtsRateLimitAction.pause);

      final TtsRenderJob back = TtsRenderJob.fromJson(job.toJson());
      expect(back.onlineConcurrency, 4);
      expect(back.sentenceGapMs, 300);
      expect(back.rateLimitAction, TtsRateLimitAction.pause);
    });

    test('old manifests without the keys fall back to voice defaults', () {
      final TtsRenderJob legacy = TtsRenderJob.fromJson(<String, Object?>{
        'id': '1',
        'bookKey': 'b',
        'sections': <int>[],
        'verify': false,
      });
      expect(legacy.onlineConcurrency, isNull);
      expect(legacy.sentenceGapMs, 0);
      expect(legacy.rateLimitAction, TtsRateLimitAction.waitRetry);
    });
  });
}
