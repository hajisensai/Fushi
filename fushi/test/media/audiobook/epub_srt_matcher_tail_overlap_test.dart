import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_audio/fushi_audio.dart';

AudioCue _cue(int idx, String text) {
  return AudioCue()
    ..bookKey = 'test'
    ..chapterHref = 'srt://default'
    ..sentenceIndex = idx
    ..textFragmentId = 'srt://$idx'
    ..text = text
    ..startMs = idx * 1000
    ..endMs = idx * 1000 + 900
    ..audioFileIndex = 0;
}

/// BUG-2204（2026-09-07 无職転生 21 真机录屏复现）：ASR 字幕把下一句首字「と」切进了
/// 前一句（「エリスだけは好きそうだけどな、高い所。と」），前句命中后游标越过了
/// 「とはいえ、今は…」的真实起点；后句「とはいえ、」在游标后找不到，200 字窗口里撞上
/// 155 字外的第二个「とはいえ、冒険者区も広い」——视口跳到下一页，中间 15 句全部
/// miss（DB 里 text_fragment_id 为空），高亮停在下一页 43 秒不动。
void main() {
  const String body =
      'アイシャは高い所が苦手か。悪いことをしたな。'
      '俺の身内には高い所が苦手なヤツが多いようだ。'
      'シルフィも高所恐怖症だし、俺も高いところはあんまり得意じゃない。'
      'エリスだけは好きそうだけどな、高い所。'
      'とはいえ、今はそれを考慮している暇はない。'
      '「地上を走ったら交通事故が起こるよ。さぁ、早く母さんを捜そう」'
      'これから、いなくなったゼニスか、あるいはゼニスを連れ出したギースを捜さなければならない。'
      '今の状態のゼニスを放置するわけにはいかないのだ。'
      '「うー……歩けない」「ほら、おんぶするから」「もう跳ばない？」「跳ばないよ」'
      'へたり込むアイシャをおんぶして、捜索開始だ。'
      'とはいえ、冒険者区も広い。どこから捜すべきか。'
      '「お兄ちゃん、酒場見ていこう。ご飯の時間だから、どこかで食べてるかも」';

  final List<EpubSection> sections = <EpubSection>[
    EpubSection(index: 0, href: 'ch9.xhtml', text: body),
  ];

  // 与 DB 里 sentence_index 59..82 的 ASR 文本逐字一致（含听写错误）。
  final List<AudioCue> cues = <AudioCue>[
    _cue(59, 'アイシャは高い所が苦手か。'),
    _cue(60, '悪いことをしたな。'),
    _cue(61, '俺の身内には高い所が苦手なヤツが多いようだ。'),
    _cue(62, 'シルフィも高所恐怖症だし、'),
    _cue(63, '俺も高いところはあんまり得意じゃない。'),
    _cue(64, 'エリスだけは好きそうだけどな、高い所。と'),
    _cue(65, 'とはいえ、'),
    _cue(66, '今はそれを考慮している暇はない'),
    _cue(67, '地上を走ったら交通事故が起こるよ'),
    _cue(68, 'そう'),
    _cue(69, '早く母さんを捜そう'),
    _cue(70, 'これから'),
    _cue(71, 'いなくなった銭すか'),
    _cue(72, 'あるいはゼニスを連れ出したギースを捜さなければならない'),
    _cue(73, '今の状態のゼニスを放置する訳にはいかないのだ'),
    _cue(74, 'うん'),
    _cue(75, 'あるけない'),
    _cue(76, 'ほらおんぶするから'),
    _cue(77, 'もうとばない'),
    _cue(78, 'とばないよ'),
    _cue(79, 'へたり込むアイシャをおんぶして捜索開始だ'),
    _cue(80, 'とはいえ'),
    _cue(81, '冒険者区も広い。'),
    _cue(82, 'どこから捜すべきか。'),
  ];

  test('前句多吃下一句首字：后句在游标前 1 字命中，前句被裁短，中间句子照常命中', () {
    final MatchResult r = EpubSrtMatcher.match(sections: sections, cues: cues);
    final Map<int, CueMatch> by = <int, CueMatch>{
      for (final CueMatch m in r.matches) m.cueSentenceIndex: m,
    };
    final CueMatch c64 = by[64]!;
    final CueMatch c65 = by[65]!;
    final CueMatch c80 = by[80]!;
    final CueMatch c81 = by[81]!;
    expect(c65.matched, isTrue);
    expect(
      c65.normCharStart,
      c64.normCharEnd,
      reason: '「とはいえ」紧接前句真实终点：前句多吃的「と」被裁掉、还给本句',
    );
    expect(
      c65.normCharStart,
      lessThan(c80.normCharStart),
      reason: 'cue 65 是第一个「とはいえ」，cue 80 才是第二个（冒険者区…）',
    );
    expect(c80.matched, isTrue);
    expect(c81.normCharStart, c80.normCharEnd);
    // 夹在两个「とはいえ」之间的句子必须命中（旧实现全部 miss）。
    // 69 不在名单里：ASR 把「さぁ」听成「そう」，超短 cue 撞进「捜そう」把游标带过
    // 「早く母さんを捜」——那是另一条既有弱点（shortCueMaxAdvance），与本 bug 无关。
    for (final int i in <int>[66, 67, 72, 76, 79]) {
      expect(by[i]?.matched ?? false, isTrue, reason: 'cue #$i 应在正文里命中');
      expect(
        by[i]!.normCharStart,
        allOf(greaterThan(c65.normCharStart), lessThan(c80.normCharStart)),
        reason: 'cue #$i 在两个「とはいえ」之间',
      );
    }
    expect(
      r.matchedCues,
      greaterThanOrEqualTo(18),
      reason: '24 条里只剩听写错误的 6 条 miss（旧实现 66..80 全部 miss，仅 9/24）',
    );
  });

  test('没有尾巴重叠时行为不变：正常顺序全命中、不回退到前一句内部', () {
    final List<AudioCue> clean = <AudioCue>[
      _cue(0, 'アイシャは高い所が苦手か。'),
      _cue(1, '悪いことをしたな。'),
      _cue(2, '俺の身内には高い所が苦手なヤツが多いようだ。'),
      _cue(3, '所が苦手'), // 前一句内部的子串：不许回退命中
      _cue(4, 'シルフィも高所恐怖症だし、'),
    ];
    final MatchResult r = EpubSrtMatcher.match(sections: sections, cues: clean);
    final Map<int, CueMatch> by = <int, CueMatch>{
      for (final CueMatch m in r.matches) m.cueSentenceIndex: m,
    };
    expect(by[2]!.normCharEnd, by[4]!.normCharStart, reason: '前句终点未被误裁');
    expect(
      by[3]?.matched ?? false,
      isFalse,
      reason: '回吃只允许 cueTailOverlap 字，不许退到前一句中段',
    );
  });
}
