import 'dart:convert';

import 'package:fushi_engine/tts/manga_audio/manga_audio_script.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audiobook_match.dart';
import 'package:test/test.dart';

/// 合成语料：第 i 条 cue 占 `[i*10000, i*10000+9000)`，同一文件。
List<MangaAudiobookCue> _corpus(
  List<String> texts, {
  String bookKey = 'novel-1',
  int fileIndex = 0,
}) => <MangaAudiobookCue>[
  for (int i = 0; i < texts.length; i++)
    MangaAudiobookCue(
      bookKey: bookKey,
      fileIndex: fileIndex,
      startMs: i * 10000,
      endMs: i * 10000 + 9000,
      text: texts[i],
    ),
];

List<MangaAudiobookQueryLine> _lines(List<String> texts) =>
    <MangaAudiobookQueryLine>[
      for (int i = 0; i < texts.length; i++) (lineId: 'p0b$i', text: texts[i]),
    ];

MangaScriptLine _scriptLine(int block, {MangaLineAudioSource? audio}) =>
    MangaScriptLine(
      page: 0,
      blocks: <int>[block],
      speaker: 'A',
      kind: CastLineKind.spoken,
      audio: audio ?? const MangaSynthesized(),
    );

void main() {
  group('matchMangaLinesToAudiobook', () {
    test('整句命中取 cue 边界，标点 / 片假名差异归一化后不影响', () {
      final MangaAudiobookMatchResult r = matchMangaLinesToAudiobook(
        lines: _lines(<String>['お前はもう死んでいる！']),
        corpus: _corpus(<String>['今日は晴れだった。', '「おまえはもう死んでいる」', '明日も晴れるだろう。']),
      );
      final MangaAudiobookLineMatch m = r.lines.single;
      expect(m.outcome, MangaAudiobookLineOutcome.hit);
      expect(
        m.clip,
        const MangaAudiobookClip(
          bookKey: 'novel-1',
          fileIndex: 0,
          startMs: 10000,
          endMs: 19000,
        ),
      );
      expect(r.stats.hits, 1);
      expect(r.stats.hitDurationMs, 9000);
    });

    test('不足 6 字的句子不参与匹配，哪怕语料里有一模一样的 cue', () {
      final MangaAudiobookMatchResult r = matchMangaLinesToAudiobook(
        lines: _lines(<String>['ありがとう', 'え？']),
        corpus: _corpus(<String>['ありがとう', 'え？']),
      );
      expect(r.lines.map((MangaAudiobookLineMatch m) => m.outcome), <Object>[
        MangaAudiobookLineOutcome.tooShort,
        MangaAudiobookLineOutcome.tooShort,
      ]);
      expect(r.stats.tooShort, 2);
      expect(r.stats.eligible, 0);
      expect(
        r.lines.every((MangaAudiobookLineMatch m) => m.clip == null),
        true,
      );
    });

    test('单调推进：重复的台词命中游标之后的那一处，游标之前的不回头', () {
      const String repeated = 'そんなことは絶対に許さない';
      final MangaAudiobookMatchResult r = matchMangaLinesToAudiobook(
        lines: _lines(<String>[
          '第二章の始まりを告げる鐘が鳴った',
          repeated,
          // 只在游标之前出现过 → 不回头，判没命中。
          '最初の一行目はここにある',
        ]),
        corpus: _corpus(<String>[
          '最初の一行目はここにある', // 0
          repeated, // 1：游标之前的同句
          '第二章の始まりを告げる鐘が鳴った', // 2
          '関係のない地の文が続く', // 3
          repeated, // 4：应命中这里
        ]),
      );
      expect(r.lines[0].cueIndex, 2);
      expect(r.lines[1].outcome, MangaAudiobookLineOutcome.hit);
      expect(r.lines[1].cueIndex, 4);
      expect(r.lines[1].clip!.startMs, 40000);
      expect(r.lines[2].outcome, MangaAudiobookLineOutcome.miss);
      expect(r.stats.misses, 1);
    });

    test('没命中的句子不动游标，后面的句子照常往下找', () {
      final MangaAudiobookMatchResult r = matchMangaLinesToAudiobook(
        lines: _lines(<String>['漫画にしかない独自の台詞です', '彼女は静かに窓の外を見ていた']),
        corpus: _corpus(<String>['彼女は静かに窓の外を見ていた']),
      );
      expect(r.lines[0].outcome, MangaAudiobookLineOutcome.miss);
      expect(r.lines[1].outcome, MangaAudiobookLineOutcome.hit);
    });

    test('只在窗口内找：游标之后太远的同句不算', () {
      final List<String> texts = <String>[
        for (int i = 0; i < 20; i++) '関係ない文章その$i番目です',
        '遠く離れた場所にある台詞',
      ];
      final MangaAudiobookMatchResult r = matchMangaLinesToAudiobook(
        lines: _lines(<String>['遠く離れた場所にある台詞']),
        corpus: _corpus(texts),
        options: const MangaAudiobookMatchOptions(window: 10),
      );
      expect(r.lines.single.outcome, MangaAudiobookLineOutcome.miss);
    });

    test('台词跨同一文件相邻两条 cue：片段从第一条起点到第二条终点', () {
      final MangaAudiobookMatchResult r = matchMangaLinesToAudiobook(
        lines: _lines(<String>['俺は行く。お前はここで待っていろ。']),
        corpus: _corpus(<String>['無関係な文章です。', '俺は行く。', 'お前はここで待っていろ。']),
      );
      final MangaAudiobookLineMatch m = r.lines.single;
      expect(m.outcome, MangaAudiobookLineOutcome.hit);
      expect(m.clip!.startMs, 10000);
      expect(m.clip!.endMs, 29000);
    });

    test('跨音频文件的相邻 cue 不拼', () {
      final List<MangaAudiobookCue> corpus = <MangaAudiobookCue>[
        ..._corpus(<String>['俺は行く。']),
        ..._corpus(<String>['お前はここで待っていろ。'], fileIndex: 1),
      ];
      final MangaAudiobookMatchResult r = matchMangaLinesToAudiobook(
        lines: _lines(<String>['俺は行く。お前はここで待っていろ。']),
        corpus: corpus,
      );
      expect(r.lines.single.isHit, false);
    });

    test('半句：cue 有逐 token 时间时按 token 裁出区间', () {
      final MangaAudiobookCue cue = MangaAudiobookCue(
        bookKey: 'novel-1',
        fileIndex: 2,
        startMs: 5000,
        endMs: 9000,
        text: '雨が降っていたので、僕は傘を持って家を出た。',
        tokens: <String>[
          '雨が',
          '降っていたので',
          '、',
          '僕は',
          '傘を',
          '持って',
          '家を',
          '出た',
          '。',
        ],
        tokenOffsetsMs: <int>[0, 400, 1200, 1400, 1800, 2200, 2800, 3200, 3600],
      );
      final MangaAudiobookMatchResult r = matchMangaLinesToAudiobook(
        lines: _lines(<String>['僕は傘を持って家を出た']),
        corpus: <MangaAudiobookCue>[cue],
      );
      final MangaAudiobookLineMatch m = r.lines.single;
      expect(m.outcome, MangaAudiobookLineOutcome.partialHit);
      // 首 token「僕は」(1400) 与前一个有字 token 之间的中点：前一 token 是「、」(1200)，
      // 归一化后为空但发射时刻照用 → (1200+1400)/2 = 1300；末 token「出た」(3200)
      // 与「。」(3600) 中点 3400。
      expect(m.clip!.fileIndex, 2);
      expect(m.clip!.startMs, 5000 + 1300);
      expect(m.clip!.endMs, 5000 + 3400);
      expect(r.stats.partialHits, 1);
      expect(r.stats.cuesWithTokenTiming, 1);
    });

    test('半句：cue 没有逐 token 时间就不算命中，单独计数', () {
      final MangaAudiobookMatchResult r = matchMangaLinesToAudiobook(
        lines: _lines(<String>['僕は傘を持って家を出た']),
        corpus: _corpus(<String>['雨が降っていたので、僕は傘を持って家を出た。']),
      );
      final MangaAudiobookLineMatch m = r.lines.single;
      expect(m.outcome, MangaAudiobookLineOutcome.partialNoTiming);
      expect(m.clip, isNull);
      expect(m.isHit, false);
      expect(r.stats.partialNoTiming, 1);
      expect(r.stats.matched, 0);
      expect(r.stats.tokenTimingAvailable, false);
    });

    test('半句命中后游标停在同一条 cue，下一句还能命中它的另一半', () {
      final MangaAudiobookCue cue = MangaAudiobookCue(
        bookKey: 'novel-1',
        fileIndex: 0,
        startMs: 0,
        endMs: 6000,
        text: '扉を開けると冷たい風が吹き込んできた。',
        tokens: <String>['扉を', '開けると', '冷たい', '風が', '吹き込んできた', '。'],
        tokenOffsetsMs: <int>[0, 600, 1800, 2600, 3200, 5600],
      );
      final MangaAudiobookMatchResult r = matchMangaLinesToAudiobook(
        lines: _lines(<String>['扉を開けると', '冷たい風が吹き込んできた']),
        corpus: <MangaAudiobookCue>[cue],
      );
      expect(r.lines[0].outcome, MangaAudiobookLineOutcome.partialHit);
      expect(r.lines[1].outcome, MangaAudiobookLineOutcome.partialHit);
      expect(
        r.lines[0].clip!.endMs,
        lessThanOrEqualTo(r.lines[1].clip!.startMs),
      );
    });
  });

  group('applyMangaAudiobookMatches / audioPlanFor', () {
    MangaAudiobookMatchResult resultFor(MangaAudioScript s) {
      // 第 0 句命中，第 1 句没命中，第 2 句命中但用户定过音源。
      return MangaAudiobookMatchResult(
        lines: <MangaAudiobookLineMatch>[
          MangaAudiobookLineMatch(
            lineId: s.lines[0].lineId,
            outcome: MangaAudiobookLineOutcome.hit,
            clip: const MangaAudiobookClip(
              bookKey: 'novel-1',
              fileIndex: 0,
              startMs: 0,
              endMs: 1000,
            ),
          ),
          MangaAudiobookLineMatch(
            lineId: s.lines[1].lineId,
            outcome: MangaAudiobookLineOutcome.miss,
          ),
          MangaAudiobookLineMatch(
            lineId: s.lines[2].lineId,
            outcome: MangaAudiobookLineOutcome.hit,
            clip: const MangaAudiobookClip(
              bookKey: 'novel-1',
              fileIndex: 0,
              startMs: 5000,
              endMs: 6000,
            ),
          ),
        ],
        stats: const MangaAudiobookMatchStats(
          lines: 3,
          hits: 2,
          partialHits: 0,
          partialNoTiming: 0,
          misses: 1,
          tooShort: 0,
          hitDurationMs: 2000,
          cues: 1,
          cuesWithTokenTiming: 0,
        ),
      );
    }

    MangaAudioScript script(MangaAudioSourcePolicy policy) => MangaAudioScript(
      sourcePolicy: policy,
      audiobookSources: <String>['novel-1'],
      lines: <MangaScriptLine>[
        _scriptLine(0),
        // 上一轮匹配写下的旧片段，这轮没命中 → 改回合成。
        _scriptLine(
          1,
          audio: const MangaAudiobookClip(
            bookKey: 'novel-1',
            fileIndex: 0,
            startMs: 100,
            endMs: 200,
          ),
        ),
        _scriptLine(2, audio: const MangaSynthesized(byUser: true)),
      ],
    );

    test('有声书优先：命中写片段、旧片段清掉、用户定的不动', () {
      final MangaAudioScript s = script(MangaAudioSourcePolicy.audiobookFirst);
      final MangaAudiobookApplyReport rep = applyMangaAudiobookMatches(
        s,
        resultFor(s),
      );
      expect(rep.clipsWritten, 1);
      expect(rep.clipsCleared, 1);
      expect(rep.userKept, 1);
      expect(s.lines[0].audio, isA<MangaAudiobookClip>());
      expect(s.lines[1].audio, const MangaSynthesized());
      expect(s.lines[2].audio, const MangaSynthesized(byUser: true));
      expect(s.lines.map(s.audioPlanFor), <MangaLineAudioPlan>[
        MangaLineAudioPlan.audiobookClip,
        MangaLineAudioPlan.synthesize,
        MangaLineAudioPlan.synthesize,
      ]);
    });

    test('只用有声书：没命中的不读；用户定的合成照样合成', () {
      final MangaAudioScript s = script(MangaAudioSourcePolicy.audiobookOnly);
      applyMangaAudiobookMatches(s, resultFor(s));
      expect(s.lines.map(s.audioPlanFor), <MangaLineAudioPlan>[
        MangaLineAudioPlan.audiobookClip,
        MangaLineAudioPlan.silent,
        MangaLineAudioPlan.synthesize,
      ]);
    });

    test('只合成：匹配写过的片段全清，用户钉的片段保留', () {
      final MangaAudioScript s = script(MangaAudioSourcePolicy.synthOnly);
      s.lines[2] = s.lines[2].copyWith(
        audio: const MangaAudiobookClip(
          bookKey: 'novel-1',
          fileIndex: 1,
          startMs: 0,
          endMs: 500,
          byUser: true,
        ),
      );
      final MangaAudiobookApplyReport rep = applyMangaAudiobookMatches(
        s,
        resultFor(s),
      );
      expect(rep.clipsWritten, 0);
      expect(s.lines[0].audio, const MangaSynthesized());
      expect(s.lines[1].audio, const MangaSynthesized());
      expect(s.audioPlanFor(s.lines[2]), MangaLineAudioPlan.audiobookClip);
    });
  });

  group('落盘', () {
    test('关联书单、片段的 bookKey 与用户标记往返不丢', () {
      final MangaAudioScript s = MangaAudioScript(
        audiobookSources: <String>['novel-1', 'novel-2'],
        lines: <MangaScriptLine>[
          _scriptLine(
            0,
            audio: const MangaAudiobookClip(
              bookKey: 'novel-2',
              fileIndex: 4,
              startMs: 10,
              endMs: 20,
              byUser: true,
            ),
          ),
          _scriptLine(1, audio: const MangaSynthesized(byUser: true)),
        ],
      );
      final MangaAudioScript back = MangaAudioScript.fromJson(
        jsonDecode(jsonEncode(s.toJson())),
      );
      expect(back.audiobookSources, <String>['novel-1', 'novel-2']);
      expect(back.lines[0].audio, s.lines[0].audio);
      expect(back.lines[1].audio, const MangaSynthesized(byUser: true));
    });

    test('旧文件：没有 books 键 = 没关联；没有 k 的旧片段按第一本关联书解释', () {
      final Object? raw = jsonDecode(
        '{"v":1,"lines":[{"p":0,"b":[0],"s":"A","k":"spoken",'
        '"audio":{"t":"book","f":1,"s":0,"e":900}}]}',
      );
      final MangaAudioScript old = MangaAudioScript.fromJson(raw);
      expect(old.audiobookSources, isEmpty);
      final MangaAudiobookClip clip =
          old.lines.single.audio as MangaAudiobookClip;
      expect(clip.bookKey, isNull);
      // 没有关联书时无从解释，按没命中合成。
      expect(old.audioPlanFor(old.lines.single), MangaLineAudioPlan.synthesize);
      old.audiobookSources.add('novel-1');
      expect(old.clipBookKey(clip), 'novel-1');
      expect(
        old.audioPlanFor(old.lines.single),
        MangaLineAudioPlan.audiobookClip,
      );
    });
  });
}
