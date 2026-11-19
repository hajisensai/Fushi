import 'dart:async';
import 'dart:io';

import 'package:fushi_engine/tts/cast/cast_line_voicing.dart';
import 'package:fushi_engine/tts/cast/series_cast.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_script.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_timeline.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_validate.dart';
import 'package:fushi_engine/tts/render/tts_cast.dart';
import 'package:test/test.dart';

void main() {
  group('CastVoiceAssignment.resolveOver', () {
    final CastVoiceAssignment series = CastVoiceAssignment(
      defaultVoice: 's-def',
      narrationVoice: 's-narr',
      byCharacter: <String, String>{'A': 's-a', 'B': 's-b'},
      byCharacterKind: <String, Map<CastLineKind, String>>{
        'A': <CastLineKind, String>{CastLineKind.thought: 's-a-inner'},
      },
      retryVoices: <String>['r1', 'r2'],
    );

    test('book level wins at each tier, falls back to series', () {
      final CastVoiceAssignment book = CastVoiceAssignment(
        byCharacter: <String, String>{'B': 'b-b'},
        retryVoices: <String>['r2', 'r0'],
      );
      expect(book.resolveOver('A', CastLineKind.thought, series), 's-a-inner');
      expect(book.resolveOver('A', CastLineKind.spoken, series), 's-a');
      expect(book.resolveOver('B', CastLineKind.spoken, series), 'b-b');
      expect(book.resolveOver('C', CastLineKind.spoken, series), 's-def');
      expect(book.resolveOver('A', CastLineKind.narration, series), 's-narr');
      expect(book.retryVoicesOver(series), <String>['r2', 'r0', 'r1']);
    });

    test('a finer series tier beats a coarser book tier', () {
      final CastVoiceAssignment book = CastVoiceAssignment(
        byCharacter: <String, String>{'A': 'b-a'},
      );
      // 系列给了 A 的「心声」专用声音，本卷只设了 A 的总声音：心声仍取系列的细项。
      expect(book.resolveOver('A', CastLineKind.thought, series), 's-a-inner');
      expect(book.resolveOver('A', CastLineKind.shout, series), 'b-a');
    });

    test('json round trip keeps retry voices; rename moves voices', () {
      final CastVoiceAssignment back = CastVoiceAssignment.fromJson(
        series.toJson(),
      );
      expect(back.retryVoices, <String>['r1', 'r2']);
      back.renameCharacter('A', 'Z');
      expect(back.resolve('Z', CastLineKind.thought), 's-a-inner');
      expect(back.resolve('Z', CastLineKind.spoken), 's-a');
      expect(back.byCharacter.containsKey('A'), isFalse);
    });
  });

  group('SeriesCastProfile / store', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('series_cast'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('learnRoster merges by alias and skips fixed names', () {
      final SeriesCastProfile p = SeriesCastProfile(seriesKey: 'collection:1');
      p.learnRoster(const <TtsCastCharacter>[
        TtsCastCharacter(name: '宮城', aliases: <String>['宮城さん']),
        TtsCastCharacter(name: kTtsNarrator),
      ]);
      p.learnRoster(const <TtsCastCharacter>[
        TtsCastCharacter(name: '宮城さん', gender: 'female'),
      ]);
      expect(p.roster.keys, <String>['宮城']);
      expect(p.roster['宮城']!.gender, 'female');
      expect(canonicalCastName(p.roster, '宮城さん'), '宮城');
    });

    test('link / rekey / save round trip', () async {
      final SeriesCastStore store = SeriesCastStore(dir);
      await store.link('vol1', 'collection:1');
      await store.link('vol2', 'collection:1');
      final SeriesCastProfile p = await store.load('collection:1');
      expect(p.members, <String>['vol1', 'vol2']);
      p.voices.byCharacter['A'] = 'voice-a';
      p.title = 'X';
      await store.save(p, now: DateTime.fromMillisecondsSinceEpoch(5));

      await store.rekeyBook('vol2', 'vol2b');
      expect(await store.linkOf('vol2b'), 'collection:1');
      expect(await store.linkOf('vol2'), isNull);
      final SeriesCastProfile back = await store.load('collection:1');
      expect(back.members, <String>['vol1', 'vol2b']);
      expect(back.voices.byCharacter['A'], 'voice-a');
      expect(back.title, 'X');
      expect(back.updatedAt, greaterThanOrEqualTo(5));

      await store.link('vol1', null);
      expect((await store.load('collection:1')).members, <String>['vol2b']);
    });

    test(
      'update serializes concurrent writers across store instances',
      () async {
        // 制作台、按系列跑、漫画制作台各自拿着旧拷贝：都经 update 改，谁也不覆盖谁。
        final SeriesCastStore a = SeriesCastStore(dir);
        final SeriesCastStore b = SeriesCastStore(dir);
        await a.save(SeriesCastProfile(seriesKey: 'collection:9'));
        final Completer<void> gate = Completer<void>();
        final Future<SeriesCastProfile> slow = a.update('collection:9', (
          SeriesCastProfile p,
        ) async {
          await gate.future;
          p.voices.byCharacter['A'] = 'va';
        });
        final Future<SeriesCastProfile> fast = b.update(
          'collection:9',
          (SeriesCastProfile p) => p.learnRoster(const <TtsCastCharacter>[
            TtsCastCharacter(name: '宮城'),
          ]),
        );
        final Future<void> link = b.link('vol1', 'collection:9');
        gate.complete();
        await Future.wait(<Future<Object?>>[slow, fast, link]);
        final SeriesCastProfile back = await a.load('collection:9');
        expect(back.voices.byCharacter['A'], 'va');
        expect(back.roster.keys, <String>['宮城']);
        expect(back.members, <String>['vol1']);
        expect((await fast).voices.byCharacter['A'], 'va');

        // mutate 抛异常：不存盘，后续写入照常排队。
        await expectLater(
          a.update('collection:9', (SeriesCastProfile p) {
            p.voices.byCharacter['A'] = 'broken';
            throw StateError('boom');
          }),
          throwsStateError,
        );
        expect(
          (await b.update(
            'collection:9',
            (SeriesCastProfile p) => p.title = 'T',
          )).voices.byCharacter['A'],
          'va',
        );
      },
    );

    test('corrupt profile is moved aside', () async {
      final SeriesCastStore store = SeriesCastStore(dir);
      await store.save(SeriesCastProfile(seriesKey: 'k'));
      final File f = dir.listSync().whereType<File>().single;
      f.writeAsStringSync('{bad');
      final SeriesCastProfile p = await store.load('k');
      expect(p.isEmpty, isTrue);
      expect(File('${f.path}.corrupt').existsSync(), isTrue);
    });
  });

  group('TtsCast with series', () {
    test('voiceOf falls back to series; line overrides win', () {
      final TtsCast cast = TtsCast(voices: <String, String>{'B': 'own-b'})
        ..series = CastVoiceAssignment(
          narrationVoice: 's-narr',
          byCharacter: <String, String>{'A': 's-a', 'B': 's-b'},
        );
      cast.setUserSpeaker(0, 10, 'A');
      cast.setUserSpeaker(0, 20, 'B');
      expect(cast.presetFor(0, 10), 's-a');
      expect(cast.voiceInherited('A'), isTrue);
      expect(cast.presetFor(0, 20), 'own-b');
      expect(cast.presetFor(0, 99), 's-narr');

      cast.setLineOverrides(0, 10, voice: 'retry-1', say: 'よみ');
      expect(cast.presetFor(0, 10), 'retry-1');
      expect(cast.sayFor(0, 10), 'よみ');
      // 改说话人不丢单句覆盖；重新标注也不丢。
      cast.setUserSpeaker(0, 10, 'B');
      expect(cast.presetFor(0, 10), 'retry-1');
      cast.setLineOverrides(0, 30, voice: 'v', say: '  ');
      expect(cast.sayFor(0, 30), isNull);
      cast.mergeLlm(0, <String, TtsCastLine>{
        ttsLineKey(0, 30): const TtsCastLine(
          speaker: 'A',
          source: TtsCastSource.llm,
        ),
      });
      expect(cast.lines[ttsLineKey(0, 30)]!.speaker, 'A');
      expect(cast.presetFor(0, 30), 'v');

      final TtsCast back = TtsCast.fromJson(cast.toJson());
      expect(back.lines[ttsLineKey(0, 30)]!.voice, 'v');
      expect(back.series, isNull);
    });
  });

  group('MangaScriptLine overrides', () {
    test('lineId, voice and say', () {
      final MangaAudioScript script = MangaAudioScript(
        voices: CastVoiceAssignment(byCharacter: <String, String>{'A': 'a'}),
        lines: <MangaScriptLine>[
          MangaScriptLine(
            page: 3,
            blocks: <int>[2, 0],
            speaker: 'A',
            kind: CastLineKind.spoken,
          ),
        ],
      )..series = CastVoiceAssignment(retryVoices: <String>['r']);
      final MangaScriptLine line = script.lines.single;
      expect(line.lineId, 'p3b2.0');
      expect(script.voiceFor(line), 'a');
      expect(script.retryVoices, <String>['r']);
      expect(
        script.replaceLine(
          'p3b2.0',
          (MangaScriptLine l) => l.copyWith(voice: 'r', say: '手で'),
        ),
        isTrue,
      );
      final MangaScriptLine changed = script.lineById('p3b2.0')!;
      expect(script.voiceFor(changed), 'r');
      expect(resolveMangaLineText(changed, const []), '手で');
      final MangaAudioScript back = MangaAudioScript.fromJson(script.toJson());
      expect(back.lines.single.voice, 'r');
      expect(back.lines.single.say, '手で');
      expect(
        back.lines.single.copyWith(clearVoice: true, clearSay: true).voice,
        isNull,
      );
    });
  });

  group('CastVoicingLedger', () {
    test('placeholder estimate ignores punctuation and clamps', () {
      expect(estimatePlaceholderMs('…'), 800);
      expect(estimatePlaceholderMs('あいう、！'), 550 + 450);
      expect(estimatePlaceholderMs('あ' * 1000), 30000);
    });

    test('record, retry candidates, resolve, persist', () async {
      final CastVoicingLedger ledger = CastVoicingLedger();
      ledger.recordFailure(
        lineId: 'p1b0',
        text: 'あいう',
        voice: 'a',
        code: 'rejected',
      );
      final CastVoicingEntry e = ledger.recordFailure(
        lineId: 'p1b0',
        text: 'ignored',
        voice: 'r1',
        code: 'network',
      );
      expect(e.placeholderMs, 1000);
      expect(e.attempts.length, 2);
      expect(e.nextRetryVoice('a', <String>['a', 'r1', 'r2']), 'r2');
      expect(e.nextRetryVoice('a', <String>['r1']), isNull);

      final Directory dir = Directory.systemTemp.createTempSync('voicing');
      addTearDown(() => dir.deleteSync(recursive: true));
      final CastVoicingStore store = CastVoicingStore(dir);
      await store.save('book', ledger);
      final CastVoicingLedger back = await store.load('book');
      expect(back.entries['p1b0']!.failedVoices, <String?>{'a', 'r1'});
      back.retainOnly(<String>{'other'});
      expect(back.isEmpty, isTrue);
      await store.save('book', back);
      expect(store.fileFor('book').existsSync(), isFalse);
      expect(ledger.resolve('p1b0'), isTrue);
    });

    test('placeholder lines keep their slot in the manga timeline', () {
      final MangaTimeline tl = computeMangaTimeline(
        lines: const <MangaTimedLine>[
          MangaTimedLine(
            page: 0,
            speaker: 'A',
            kind: CastLineKind.spoken,
            durationMs: 1000,
          ),
          MangaTimedLine(
            page: 0,
            speaker: 'A',
            kind: CastLineKind.spoken,
            durationMs: 1300,
            placeholder: true,
          ),
        ],
        pageCount: 1,
      );
      expect(tl.lines[1].placeholder, isTrue);
      expect(tl.lines[1].endMs - tl.lines[1].startMs, 1300);
      expect(tl.lines[0].placeholder, isFalse);
    });
  });
}
