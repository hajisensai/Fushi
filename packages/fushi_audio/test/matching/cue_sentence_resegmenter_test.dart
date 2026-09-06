import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_audio/fushi_audio.dart';

/// 造一条带逐 token 时间的 ASR cue：字符级 token（每个字一个 token），
/// [times] 是各 token 相对 cue 起点的发射时刻。
AudioCue _cue(
  int idx,
  String text, {
  required int start,
  required int end,
  List<int>? times,
  List<String>? tokens,
}) {
  final List<String> toks = tokens ?? text.split('');
  final List<int> ts =
      times ?? List<int>.generate(toks.length, (int i) => 200 + i * 100);
  return AudioCue()
    ..bookKey = 'b'
    ..chapterHref = 'ch0.xhtml'
    ..sentenceIndex = idx
    ..textFragmentId = ''
    ..text = text
    ..startMs = start
    ..endMs = end
    ..audioFileIndex = 0
    ..tokenTiming = CueTokenTiming(tokens: toks, offsetsMs: ts);
}

CueMatch _hit(int idx, int ns, int ne, {double score = 1}) => CueMatch(
      cueSentenceIndex: idx,
      sectionIndex: 0,
      normCharStart: ns,
      normCharEnd: ne,
      score: score,
    );

MatchResult _result(List<CueMatch> matches) => MatchResult(
      matches: matches,
      totalCues: matches.length,
      matchedCues: matches.where((CueMatch m) => m.matched).length,
    );

const CueSentenceResegmenter _r = CueSentenceResegmenter();

void main() {
  group('CueSentenceResegmenter', () {
    // 正文：三句，归一化后 `たとえば夢見る時がある転入生がやってくるその子は素敵な子`。
    const String book = 'たとえば、夢見る時がある。転入生がやってくる。その子は素敵な子。';
    final List<EpubSection> sections = <EpubSection>[
      const EpubSection(index: 0, href: 'ch0.xhtml', text: book),
    ];
    // 归一化偏移：たとえば(0-4) 夢見る時がある(4-11) 転入生がやってくる(11-20)
    // その子は素敵な子(20-28)。

    test('一条盖两句的 cue 在正文句号处拆开，新边界取下一句首 token − leadIn', () {
      // 听写文本没有句号：`夢見る時がある転入生がやってくる`（16 token）。
      final List<int> times = <int>[
        for (int i = 0; i < 7; i++) 100 + i * 100, // 夢見る時がある: 100..700
        for (int i = 0; i < 9; i++) 2000 + i * 100, // 転入生がやってくる: 2000..2800
      ];
      final List<AudioCue> cues = <AudioCue>[
        _cue(0, '夢見る時がある転入生がやってくる', start: 10000, end: 13500, times: times),
      ];
      final CueResegmentResult out = _r.resegment(
        sections: sections,
        cues: cues,
        result: _result(<CueMatch>[_hit(0, 4, 20)]),
      );
      expect(out.stats.boundariesAdded, 1);
      expect(out.stats.boundariesRemoved, 0);
      expect(out.cues, hasLength(2));
      expect(out.cues[0].text, '夢見る時がある');
      expect(out.cues[1].text, '転入生がやってくる');
      // 串首尾保留原时间；新边界 = 10000 + 2000 − 150。
      expect(out.cues[0].startMs, 10000);
      expect(out.cues[0].endMs, 11850);
      expect(out.cues[1].startMs, 11850);
      expect(out.cues[1].endMs, 13500);
      // 匹配区间按句切开，仍在正文归一化坐标上；序号重编。
      expect(out.result.matches[0].normCharStart, 4);
      expect(out.result.matches[0].normCharEnd, 11);
      expect(out.result.matches[1].normCharStart, 11);
      expect(out.result.matches[1].normCharEnd, 20);
      expect(out.result.matches[1].cueSentenceIndex, 1);
      expect(out.cues[1].sentenceIndex, 1);
      expect(out.result.matchedCues, 2);
      expect(out.result.totalCues, 2);
      // 新 cue 的 token 时间已按新起点重排。
      expect(out.cues[1].tokenTiming!.offsetsMs.first, 12000 - 11850);
    });

    test('词中切开的两条 cue 合并（正文里两个字紧挨着，边界抹掉）', () {
      final List<AudioCue> cues = <AudioCue>[
        _cue(0, 'たと', start: 0, end: 800, times: <int>[100, 200]),
        _cue(1, 'えば', start: 800, end: 1500, times: <int>[50, 150]),
      ];
      final CueResegmentResult out = _r.resegment(
        sections: sections,
        cues: cues,
        result: _result(<CueMatch>[_hit(0, 0, 2), _hit(1, 2, 4)]),
      );
      expect(out.stats.boundariesRemoved, 1);
      expect(out.stats.boundariesAdded, 0);
      expect(out.cues, hasLength(1));
      expect(out.cues.single.text, 'たとえば');
      expect(out.cues.single.startMs, 0);
      expect(out.cues.single.endMs, 1500);
      expect(out.result.matches.single.normCharStart, 0);
      expect(out.result.matches.single.normCharEnd, 4);
      expect(out.cues.single.tokenTiming!.tokens, <String>['た', 'と', 'え', 'ば']);
      expect(out.cues.single.tokenTiming!.offsetsMs, <int>[100, 200, 850, 950]);
    });

    test('落在逗号/句号间隙上的原边界保留，连原时间一起保留', () {
      final List<AudioCue> cues = <AudioCue>[
        _cue(0, 'たとえば', start: 0, end: 900),
        _cue(1, '夢見る時がある', start: 1000, end: 2500),
      ];
      final CueResegmentResult out = _r.resegment(
        sections: sections,
        cues: cues,
        result: _result(<CueMatch>[_hit(0, 0, 4), _hit(1, 4, 11)]),
      );
      expect(out.stats.changed, isFalse);
      // 没有任何改动：对象原样透传。
      expect(identical(out.cues[0], cues[0]), isTrue);
      expect(identical(out.cues[1], cues[1]), isTrue);
      expect(out.cues[0].endMs, 900);
      expect(out.cues[1].startMs, 1000);
    });

    test('串内既有句号新增边界、又有词中边界抹掉：保留的原边界时间不变', () {
      // 三条 cue：`たとえば夢見る時が` | `ある` | `転入生がやってくる`
      // 第 1/2 条之间在「が|あ」词中 → 抹掉；第 2/3 条之间是句号 → 保留原边界与
      // 原时间；第 1 条内部的逗号是软间隙，不新增边界。
      final List<AudioCue> cues = <AudioCue>[
        _cue(0, 'たとえば夢見る時が', start: 0, end: 1800),
        _cue(1, 'ある', start: 1800, end: 2400, times: <int>[100, 200]),
        _cue(2, '転入生がやってくる', start: 2600, end: 4000),
      ];
      final CueResegmentResult out = _r.resegment(
        sections: sections,
        cues: cues,
        result:
            _result(<CueMatch>[_hit(0, 0, 9), _hit(1, 9, 11), _hit(2, 11, 20)]),
      );
      expect(out.stats.boundariesRemoved, 1);
      expect(out.stats.boundariesAdded, 0);
      expect(out.cues.map((AudioCue c) => c.text), <String>[
        'たとえば夢見る時がある',
        '転入生がやってくる',
      ]);
      expect(out.cues[0].startMs, 0);
      expect(out.cues[0].endMs, 2400);
      expect(out.cues[1].startMs, 2600);
      expect(out.cues[1].endMs, 4000);
    });

    test('模糊命中（听写差）走编辑距离映射，句号仍切在正确位置', () {
      // 听写 `ゆめみる時がある転入生がやってくる`（夢見→ゆめみ，多两字）。
      final String text = 'ゆめみる時がある転入生がやってくる';
      final List<int> times = <int>[
        for (int i = 0; i < 8; i++) 100 + i * 100,
        for (int i = 0; i < 9; i++) 3000 + i * 100,
      ];
      final CueResegmentResult out = _r.resegment(
        sections: sections,
        cues: <AudioCue>[_cue(0, text, start: 0, end: 5000, times: times)],
        result: _result(<CueMatch>[_hit(0, 4, 20, score: 0.7)]),
      );
      expect(out.cues, hasLength(2));
      expect(out.cues[0].text, 'ゆめみる時がある');
      expect(out.cues[1].text, '転入生がやってくる');
      expect(out.cues[1].startMs, 3000 - 150);
      expect(out.result.matches[0].score, 0.7);
      expect(out.result.matches[1].normCharStart, 11);
    });

    test('标点 token 挂在前一句：句号不会被甩到下一句', () {
      final CueResegmentResult out = _r.resegment(
        sections: sections,
        cues: <AudioCue>[
          _cue(
            0,
            '夢見る時がある。転入生がやってくる',
            start: 0,
            end: 5000,
            times: <int>[
              for (int i = 0; i < 8; i++) 100 + i * 100,
              for (int i = 0; i < 9; i++) 3000 + i * 100,
            ],
          ),
        ],
        result: _result(<CueMatch>[_hit(0, 4, 20)]),
      );
      expect(out.cues[0].text, '夢見る時がある。');
      expect(out.cues[1].text, '転入生がやってくる');
    });

    test('未命中 / 没有 token 时间 / 区间不相接的 cue 原样透传', () {
      final AudioCue noTiming = AudioCue()
        ..bookKey = 'b'
        ..chapterHref = 'ch0.xhtml'
        ..sentenceIndex = 0
        ..textFragmentId = ''
        ..text = '夢見る時がある転入生がやってくる'
        ..startMs = 0
        ..endMs = 3000
        ..audioFileIndex = 0;
      final AudioCue miss = _cue(1, 'ざつおん', start: 3000, end: 4000);
      final AudioCue apart = _cue(2, 'その子は', start: 4000, end: 5000);
      final CueResegmentResult out = _r.resegment(
        sections: sections,
        cues: <AudioCue>[noTiming, miss, apart],
        result: _result(<CueMatch>[
          _hit(0, 4, 20),
          CueMatch.unmatched,
          _hit(2, 20, 24),
        ]),
      );
      expect(out.cues, hasLength(3));
      expect(identical(out.cues[0], noTiming), isTrue);
      expect(identical(out.cues[1], miss), isTrue);
      expect(identical(out.cues[2], apart), isTrue);
      expect(out.result.matches[1].matched, isFalse);
      expect(out.result.matchedCues, 2);
      expect(out.stats.changed, isFalse);
    });

    test('matches 与 cues 数量不符时原样返回', () {
      final CueResegmentResult out = _r.resegment(
        sections: sections,
        cues: <AudioCue>[_cue(0, 'たとえば', start: 0, end: 1)],
        result: _result(<CueMatch>[]),
      );
      expect(out.cues, hasLength(1));
      expect(out.stats.runs, 0);
    });

    test('新边界不早于上一句末 token + 一帧，且满足最短时长', () {
      // 两句 token 时间挨得极近：第二句首 token 只比第一句末 token 晚 20 ms。
      final CueResegmentResult out = _r.resegment(
        sections: sections,
        cues: <AudioCue>[
          _cue(
            0,
            '夢見る時がある転入生がやってくる',
            start: 0,
            end: 5000,
            times: <int>[
              for (int i = 0; i < 7; i++) 100 + i * 10,
              for (int i = 0; i < 9; i++) 180 + i * 10,
            ],
          ),
        ],
        result: _result(<CueMatch>[_hit(0, 4, 20)]),
      );
      expect(out.cues, hasLength(2));
      expect(out.cues[0].endMs, greaterThanOrEqualTo(160 + 40));
      expect(
          out.cues[0].endMs - out.cues[0].startMs, greaterThanOrEqualTo(300));
      expect(out.cues[1].startMs, out.cues[0].endMs);
      expect(out.cues[1].endMs, 5000);
    });
  });
}
