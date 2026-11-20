import 'dart:io';

import 'package:fushi/src/media/audiobook/tts/studio/tts_render_encode.dart';
import 'package:fushi/src/media/audiobook/tts/studio/tts_render_unvoiced.dart';
import 'package:fushi/src/media/audiobook/tts/tts_book_plan.dart';
import 'package:fushi_engine/tts/cast/cast_line_voicing.dart';
import 'package:fushi_engine/tts/render/tts_cast.dart';
import 'package:fushi_engine/tts/render/tts_render_queue.dart';
import 'package:fushi_engine/tts/tts_types.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 制作流程里没配上音的句子：占位、记账、熔断，以及沿用已入库章的清单。

TtsPlanSentence _s(int section, int start, String text) => TtsPlanSentence(
  section: section,
  href: 'c$section.xhtml',
  text: text,
  spokenText: text,
  matchStart: start,
  matchEnd: start + text.length,
  studyStart: start,
  studyEnd: start + text.length,
);

TtsUnvoicedLine _fail(String lineId, {String code = 'network'}) =>
    TtsUnvoicedLine(
      planIndex: 0,
      lineId: lineId,
      text: 'こんにちは',
      voice: 'v1',
      code: code,
    );

void main() {
  group('per-line failure classification', () {
    test('engine failures become placeholders, cancel and others do not', () {
      expect(
        ttsFailureIsPerLine(const TtsFailure(TtsFailureCode.rejected)),
        isTrue,
      );
      expect(
        ttsFailureIsPerLine(const TtsFailure(TtsFailureCode.network)),
        isTrue,
      );
      expect(
        ttsFailureIsPerLine(const TtsFailure(TtsFailureCode.cancelled)),
        isFalse,
      );
      expect(ttsFailureIsPerLine(const FileSystemException('x')), isFalse);
      expect(ttsFailureIsPerLine(StateError('bug')), isFalse);
    });

    test('codes recorded in the ledger', () {
      expect(
        ttsUnvoicedCode(const TtsFailure(TtsFailureCode.rejected, 'bad')),
        'rejected',
      );
      expect(
        ttsUnvoicedDetail(const TtsFailure(TtsFailureCode.busy, 'd')),
        'd',
      );
      expect(
        ttsUnvoicedCode(const TtsRenderFailure('voice_missing')),
        'voice_missing',
      );
      expect(ttsUnvoicedCode(StateError('x')), 'internal');
    });
  });

  group('TtsUnvoicedBreaker', () {
    test('trips only after a streak with no success in between', () {
      final TtsUnvoicedBreaker breaker = TtsUnvoicedBreaker(threshold: 3);
      expect(breaker.recordFailure(), isFalse);
      expect(breaker.recordFailure(), isFalse);
      breaker.recordSuccess();
      expect(breaker.streak, 0);
      expect(breaker.recordFailure(), isFalse);
      expect(breaker.recordFailure(), isFalse);
      expect(breaker.recordFailure(), isTrue);
    });
  });

  group('placeholder durations', () {
    test('voiced keep measured time, placeholders get the estimate', () {
      final List<int> durations = ttsChapterDurationsWithPlaceholders(
        placeholder: const <bool>[false, true, false],
        voicedDurationsMs: const <int>[1200, 900],
        texts: const <String>['a', 'あいうえお', 'b'],
      );
      expect(durations, <int>[1200, estimatePlaceholderMs('あいうえお'), 900]);
    });

    test('mismatched mask is a programming error', () {
      expect(
        () => ttsChapterDurationsWithPlaceholders(
          placeholder: const <bool>[true],
          voicedDurationsMs: const <int>[100],
          texts: const <String>['a'],
        ),
        throwsArgumentError,
      );
    });

    test('placeholder keys never match the expected chapter keys', () {
      const TtsChapterManifest manifest = TtsChapterManifest(
        section: 1,
        keys: <String>['k1', '${kTtsPlaceholderKeyPrefix}k2'],
        durationsMs: <int>[100, 800],
        pausePreset: 'standard',
        loudnorm: true,
      );
      expect(ttsPlaceholderManifestKey('k2'), '${kTtsPlaceholderKeyPrefix}k2');
      // 重跑时期望键里没有前缀：含占位的章不会被当作已完成跳过。
      expect(
        manifest.matches(
          1,
          const <String>['k1', 'k2'],
          pausePreset: 'standard',
          loudnorm: true,
          gapsMs: const <int>[800, 600, 2000],
          legacyGapsMs: const <int>[800, 600, 2000],
        ),
        isFalse,
      );
    });
  });

  group('spoken text and line identity', () {
    test('typed say overrides the planned reading', () {
      final TtsCast cast = TtsCast();
      final TtsPlanSentence s = _s(2, 40, '本文');
      expect(ttsSentenceSpokenText(cast, s), '本文');
      cast.setLineOverrides(2, 40, voice: null, say: 'ほんぶん');
      expect(ttsSentenceSpokenText(cast, s), 'ほんぶん');
      expect(ttsSentenceLineId(s), ttsLineKey(2, 40));
    });
  });

  group('reconcileTtsVoicingLedger', () {
    test('records failures, resolves rendered lines, drops dead lines', () {
      final CastVoicingLedger ledger = CastVoicingLedger();
      ledger.recordFailure(
        lineId: '1:0',
        text: 'a',
        voice: 'v1',
        code: 'network',
      );
      ledger.recordFailure(
        lineId: '2:0',
        text: 'b',
        voice: 'v1',
        code: 'network',
      );
      ledger.recordFailure(
        lineId: '9:0',
        text: 'gone',
        voice: 'v1',
        code: 'network',
      );
      reconcileTtsVoicingLedger(
        ledger: ledger,
        // 本次渲染了第 1、3 章：1:0 这次配上了，3:5 失败；第 2 章没渲染，原样保留。
        renderedLineIds: <String>{'1:0', '3:5'},
        liveLineIds: <String>{'1:0', '2:0', '3:5'},
        failures: <TtsUnvoicedLine>[_fail('3:5', code: 'rejected')],
      );
      expect(ledger.entries.keys, unorderedEquals(<String>['2:0', '3:5']));
      expect(ledger.entries['3:5']!.lastAttempt!.code, 'rejected');
      expect(ledger.entries['3:5']!.lastAttempt!.voice, 'v1');
      expect(
        ledger.entries['3:5']!.placeholderMs,
        estimatePlaceholderMs('こんにちは'),
      );
    });

    test('a failing line keeps accumulating attempts across renders', () {
      final CastVoicingLedger ledger = CastVoicingLedger();
      for (int i = 0; i < 2; i++) {
        reconcileTtsVoicingLedger(
          ledger: ledger,
          renderedLineIds: <String>{'1:0'},
          liveLineIds: <String>{'1:0'},
          failures: <TtsUnvoicedLine>[_fail('1:0')],
        );
      }
      expect(ledger.entries['1:0']!.attempts, hasLength(2));
    });
  });

  group('persisted chapter manifests', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('tts_persist_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test(
      'import writes sidecars, a new job adopts matching chapters',
      () async {
        final Directory work = Directory(p.join(tmp.path, 'work'))
          ..createSync();
        final Directory persist = Directory(p.join(tmp.path, 'persist'))
          ..createSync();
        const TtsRenderChapter chapter = TtsRenderChapter(
          fileIndex: 0,
          section: 3,
          planIndices: <int>[0, 1],
        );
        const TtsChapterManifest manifest = TtsChapterManifest(
          section: 3,
          keys: <String>['a', 'b'],
          durationsMs: <int>[100, 200],
          pausePreset: 'standard',
          loudnorm: false,
        );
        File(
          p.join(work.path, '${chapter.stem}.json'),
        ).writeAsStringSync(manifest.encode());
        // 持久目录里：本章成品（入库时由 syncAudioFiles 拷入）+ 一个旧章的孤儿清单。
        File(
          p.join(persist.path, '${chapter.stem}.m4a'),
        ).writeAsBytesSync(<int>[1, 2, 3]);
        final File stale = File(
          p.join(persist.path, 'tts_999$kTtsPersistedManifestSuffix'),
        )..writeAsStringSync('{}');

        await persistTtsChapterManifests(
          workDir: work,
          persistDir: persist,
          chapters: const <TtsRenderChapter>[chapter],
        );
        expect(stale.existsSync(), isFalse);

        final TtsChapterManifest? read = await readTtsPersistedChapter(
          persist,
          chapter,
        );
        expect(read, isNotNull);
        expect(read!.keys, <String>['a', 'b']);

        final Directory next = Directory(p.join(tmp.path, 'next'));
        await adoptTtsPersistedChapter(persist, next, chapter);
        final TtsChapterManifest? adopted = await readTtsChapterManifest(
          next,
          chapter,
        );
        expect(adopted?.durationsMs, <int>[100, 200]);
        expect(
          File(p.join(next.path, '${chapter.stem}.m4a')).readAsBytesSync(),
          <int>[1, 2, 3],
        );
      },
    );

    test('no persisted audio means nothing to adopt', () async {
      const TtsRenderChapter chapter = TtsRenderChapter(
        fileIndex: 1,
        section: 4,
        planIndices: <int>[0],
      );
      File(
        p.join(tmp.path, '${chapter.stem}$kTtsPersistedManifestSuffix'),
      ).writeAsStringSync('{}');
      expect(await readTtsPersistedChapter(tmp, chapter), isNull);
    });
  });
}
