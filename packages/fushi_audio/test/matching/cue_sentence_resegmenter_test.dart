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

  group('CueSentenceResegmenter 合缝', () {
    List<EpubSection> book(String text) => <EpubSection>[
          EpubSection(index: 0, href: 'ch0.xhtml', text: text),
        ];
    List<int> range(CueMatch m) => <int>[m.normCharStart, m.normCharEnd];

    test('书写假名、听写汉字的单字 cue 未命中：认领缝后两侧词中边界一起抹掉', () {
      // 归一化：ということをこころは自分が知った（16 字）。ASR 把「こころ」听成「心」，
      // 匹配器对不上；缝 [5,9) = をこころ，1.5 s 读 4 字，密度合理。
      final CueResegmentResult out = _r.resegment(
        sections: book('ということを、こころは、自分が知った。'),
        cues: <AudioCue>[
          _cue(0, 'ということ', start: 0, end: 2000),
          _cue(1, '心', start: 2000, end: 3500),
          _cue(2, 'は自分が知った', start: 3500, end: 7000),
        ],
        result: _result(<CueMatch>[
          _hit(0, 0, 5),
          CueMatch.unmatched,
          _hit(2, 9, 16),
        ]),
      );
      expect(out.stats.gapsClosed, 1);
      expect(out.stats.boundariesRemoved, 2);
      expect(out.cues, hasLength(1));
      expect(range(out.result.matches[0]), <int>[0, 16]);
      expect(out.cues[0].startMs, 0);
      expect(out.cues[0].endMs, 7000);
      expect(out.result.matchedCues, 1);
    });

    test('ASR 整句掉字：缝按发声时长分给中间的未命中 cue，密度按整块判', () {
      // 归一化：すりっぱを履いたつま先が冷えて足の指を丸めた（22 字）。7 s 的「そ」
      // 与 0.25 s 的「う」中间是 8 字缝；按听写长度平分会让「う」密度爆表。
      final CueResegmentResult out = _r.resegment(
        sections: book('スリッパを履いたつま先が冷えて、足の指を丸めた。'),
        cues: <AudioCue>[
          _cue(0, 'すりっぱを履い', start: 0, end: 3000),
          _cue(1, 'そ', start: 3000, end: 9000),
          _cue(2, 'う', start: 9000, end: 9250),
          _cue(3, '足の指を丸めた', start: 9250, end: 12000),
        ],
        result: _result(<CueMatch>[
          _hit(0, 0, 7),
          CueMatch.unmatched,
          CueMatch.unmatched,
          _hit(3, 15, 22),
        ]),
      );
      expect(out.stats.gapsClosed, 2);
      expect(out.cues, hasLength(2));
      // 缝 [7,15) 按 6000:250 分：そ [7,14)、う [14,15)。「履い｜た」「え｜て」两处
      // 词中边界抹掉；「て、｜足」是原边界（う｜足）且落在逗号上，连原时间一起保留。
      expect(out.stats.boundariesRemoved, 2);
      expect(range(out.result.matches[0]), <int>[0, 15]);
      expect(range(out.result.matches[1]), <int>[15, 22]);
      expect(out.cues[0].startMs, 0);
      expect(out.cues[0].endMs, 9250);
      expect(out.cues[1].startMs, 9250);
      expect(out.cues[1].endMs, 12000);
    });

    test('模糊命中的词尾没人认领：缝在第一个标点边界处切开分给两侧', () {
      // 归一化：時計を気にし出すああもうこんな時間（17 字）。前一条止于「出」，
      // 后一条起于「も」，缝 [7,10) = すああ；「す。「」后是句界 → 切在 8。
      final CueResegmentResult out = _r.resegment(
        sections: book('時計を気にし出す。「ああ、もうこんな時間」'),
        cues: <AudioCue>[
          _cue(0, '時計を気にし出', start: 0, end: 3000),
          _cue(1, 'もうこんな時間', start: 3000, end: 6000),
        ],
        result: _result(<CueMatch>[_hit(0, 0, 7), _hit(1, 10, 17)]),
      );
      expect(out.stats.gapsClosed, 2);
      expect(out.stats.boundariesRemoved, 0);
      expect(out.cues, hasLength(2));
      expect(range(out.result.matches[0]), <int>[0, 8]);
      expect(range(out.result.matches[1]), <int>[8, 17]);
    });

    test('ASR 幻觉（0 字缝）：认领空区间后折进前一片，幻觉 cue 消失', () {
      final CueResegmentResult out = _r.resegment(
        sections: book('夢見る時がある。転入生がやってくる。'),
        cues: <AudioCue>[
          _cue(0, '夢見る時がある', start: 0, end: 3000),
          _cue(1, 'はい', start: 3000, end: 3400),
          _cue(2, '転入生がやってくる', start: 3400, end: 7000),
        ],
        result: _result(<CueMatch>[
          _hit(0, 0, 7),
          CueMatch.unmatched,
          _hit(2, 7, 16),
        ]),
      );
      expect(out.stats.gapsClosed, 1);
      expect(out.stats.boundariesRemoved, 1);
      expect(out.cues, hasLength(2));
      expect(range(out.result.matches[0]), <int>[0, 7]);
      expect(range(out.result.matches[1]), <int>[7, 16]);
      // 幻觉 token（3000–3400 ms）折进前一片，前一片终点推到其末 token 之后。
      expect(out.cues[0].endMs, greaterThan(3000));
      expect(out.cues[1].startMs, out.cues[0].endMs);
      expect(out.cues[1].endMs, 7000);
      expect(out.cues[0].text, '夢見る時があるはい');
      expect(out.cues[1].text, '転入生がやってくる');
    });

    test('旁白真跳过一段：隐含朗读速度超上限，缝留着、两侧原样透传', () {
      // 缝 40 字，两侧各 2–3 s：谁认领密度都是中位数的好几倍。
      const String skipped = 'あいうえおかきくけこさしすせそたちつてとなにぬねのはひふへほまみむめもやゆよわ';
      final AudioCue a = _cue(0, '夢見る時がある', start: 0, end: 3000);
      final AudioCue b = _cue(1, '転入生がやってくる', start: 3000, end: 6500);
      final CueResegmentResult out = _r.resegment(
        sections: book('夢見る時がある$skipped転入生がやってくる。'),
        cues: <AudioCue>[a, b],
        result: _result(<CueMatch>[_hit(0, 0, 7), _hit(1, 47, 56)]),
      );
      expect(out.stats.gapsClosed, 0);
      expect(out.stats.changed, isFalse);
      expect(identical(out.cues[0], a), isTrue);
      expect(identical(out.cues[1], b), isTrue);
      expect(range(out.result.matches[0]), <int>[0, 7]);
      expect(range(out.result.matches[1]), <int>[47, 56]);
    });

    test('中间的未命中 cue 属另一音频文件或时间乱序：不认领，两侧原样', () {
      final AudioCue a = _cue(0, 'ということ', start: 0, end: 2000);
      final AudioCue other = _cue(1, '心', start: 2000, end: 3500)
        ..audioFileIndex = 1;
      final AudioCue b = _cue(2, 'は自分が知った', start: 3500, end: 7000);
      final CueResegmentResult out = _r.resegment(
        sections: book('ということを、こころは、自分が知った。'),
        cues: <AudioCue>[a, other, b],
        result: _result(<CueMatch>[
          _hit(0, 0, 5),
          CueMatch.unmatched,
          _hit(2, 9, 16),
        ]),
      );
      expect(out.stats.gapsClosed, 0);
      expect(out.cues, hasLength(3));
      expect(identical(out.cues[1], other), isTrue);
      expect(out.result.matches[1].matched, isFalse);
      expect(out.result.matchedCues, 2);
    });
  });
}
