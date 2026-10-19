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

EpubSection _section(int i, String text) =>
    EpubSection(index: i, href: 'ch$i.xhtml', text: text);

/// 2026-09-05 无職転生 01 真机对照复现：ASR 字幕把卷号朗读成「一」，匹配器精确
/// 快通道在 200 字窗口里撞上第七节正文「第一章」的「一」，游标越过第六节题词，
/// 后面 12 条题词 cue 连锁 miss。超短 cue 的精确命中只能在游标紧邻处作数。
void main() {
  group('EpubSrtMatcher 超短 cue', () {
    final List<EpubSection> sections = <EpubSection>[
      _section(0, '無職転生 異世界行ったら本気だす 理不尽な孫の手'),
      _section(1, '目の前に崖がある。踏み出して地面に叩きつけられるか、その場に留まって罵声を浴びせ続けるかは君の自由だ。'),
      _section(2, '第一章 幼年期 プロローグ 俺は三十四歳、住所不定無職。人生を後悔している真っ最中の小太りブサメンのナイスガイだ。'),
    ];

    test('一个字的 cue 不能把游标拽到远处（题词整段仍命中）', () {
      final List<AudioCue> cues = <AudioCue>[
        _cue(0, '無職転生'),
        _cue(1, '異世界行ったら本気出す'),
        _cue(2, '一'), // 卷号「1」被朗读成「一」——第二节没有，第三节「第一章」里有
        _cue(3, '理不尽な孫の手著'),
        _cue(4, '目の前に崖がある'),
        _cue(5, '踏み出して地面にたたきつけられるか'),
        _cue(6, 'その場にとどまって'),
        _cue(7, '罵声を浴びせ続けるかは'),
        _cue(8, '君の自由だ'),
        _cue(9, '第一章'),
        _cue(10, '幼年期'),
        _cue(11, 'プロローグ'),
        _cue(12, '俺は三十四歳住所不定無職'),
      ];
      final MatchResult r = EpubSrtMatcher.match(
        sections: sections,
        cues: cues,
        similarityThreshold: 0.6,
      );
      final Map<int, CueMatch> by = <int, CueMatch>{
        for (final CueMatch m in r.matches) m.cueSentenceIndex: m,
      };
      // 「一」在游标附近没有精确命中：必须 miss，而不是跳到第三节。
      expect(by[2]?.matched ?? false, isFalse, reason: '超短 cue 远处命中不该作数');
      // 题词五句全部在第二节命中。
      for (final int i in <int>[4, 6, 7, 8]) {
        expect(by[i]?.sectionIndex, 1, reason: 'cue #$i 应命中题词节');
      }
      // 正文照常。
      expect(by[12]?.sectionIndex, 2);
    });

    test('紧邻游标的超短 cue 仍可精确命中', () {
      final List<EpubSection> body = <EpubSection>[
        _section(0, '俺は三十四歳、住所不定無職。だが、気付いたら親が死んでいた。'),
      ];
      final List<AudioCue> cues = <AudioCue>[
        _cue(0, '俺は三十四歳住所不定無職'),
        _cue(1, 'だが'), // 2 字，就在游标正后方
        _cue(2, '気付いたら親が死んでいた'),
      ];
      final MatchResult r = EpubSrtMatcher.match(sections: body, cues: cues);
      expect(r.matchedCues, 3);
      expect(r.matches[1].score, 1.0);
      expect(r.matches[1].normCharStart, 12);
    });
  });

  // BUG-3530：『少女事案 2』ASR 字幕的三字 cue「すげえ」（正文「すげ～!!」，规范化
  // 后只剩「すげ」精确不中）在 200 字窗口里撞上 170 字后「すげえよなあ」，游标被
  // 拽走，中间 13 句全 miss，歌词页把这段正文整块灰显。
  group('EpubSrtMatcher 三到五字短 cue', () {
    final List<EpubSection> sections = <EpubSection>[
      _section(
        0,
        '「核のスイッチが押されそうになったから……大統領ヤってきた」\n'
        '「すげ～!!」\n'
        '　風町、それ殺し屋じゃないから。スパイとかそういうやつだから。\n'
        '「マジで尊敬するわ。師匠って呼んでいい？」\n'
        '「いいよ」\n'
        '　風町よ、本職相手に調子のりすぎだ。\n'
        '　俺は冷や冷やするが、殺し屋になりきった風町とラッキーの会話は進んでいく。\n'
        '「じゃあ、ここでサラリーマンを殺したのはラッキーじゃないんだ」\n'
        '「きっと『映画屋』だと思うなあ」\n'
        '　映画屋、というのも殺し屋の名前らしい。\n'
        '「殺しの場面をカメラで撮るんだよ。すげえよなあ」\n'
        '　でも今回は下手をうったらしい、とラッキーはいう。\n',
      ),
    ];

    test('紧跟命中的短 cue 不能越过整段跳到后文同形短句', () {
      // 真实转录稿 #2037–#2053（未改字）。
      final List<String> texts = <String>[
        '核のスイッチが押されそうになったから',
        '大統領やってきた',
        'すげえ',
        '風間それ殺し屋じゃないから',
        'スパイとかそういうやつだから',
        'マジで尊敬するわ師匠って呼んでいい',
        'いいよ',
        '風待ちよ',
        '本職相手に調子乗りすぎだ',
        '俺はひやひやするが殺し屋になりきった風間とラッキーの会話は進んでいく',
        'じゃあ',
        'ここでサラリーマンを殺したのはラッキーじゃないんだ',
        'きっと映画屋だと思うな',
        '映画屋というのも殺し屋の名前らしい',
        '殺しの場面をカメラで撮るんだよ',
        'すげえよな',
        'でも今回は下手を打ったらしい',
      ];
      final List<AudioCue> cues = <AudioCue>[
        for (int i = 0; i < texts.length; i++) _cue(i, texts[i]),
      ];
      final MatchResult r = EpubSrtMatcher.match(
        sections: sections,
        cues: cues,
      );
      expect(r.matches[2].matched, isFalse, reason: '「すげえ」远处同形句不该作数');
      // 被它挡住的那段对白与旁白全部按序命中。
      for (final int i in <int>[4, 5, 8, 11, 12, 13, 14, 15]) {
        expect(r.matches[i].matched, isTrue, reason: 'cue #$i「${texts[i]}」');
      }
      int last = -1;
      for (final CueMatch m in r.matches.where((CueMatch m) => m.matched)) {
        expect(m.normCharStart, greaterThanOrEqualTo(last));
        last = m.normCharStart;
      }
    });

    test('前面有 cue miss 时，短 cue 可越过它们那段正文命中', () {
      // 『少女事案 2』#155–#160：模糊没过线的一句把游标留在原地，「すごい」
      // 真实位置在游标后 20 字——固定 16 字上限会误拒它，让一字的「え」黏到
      // 「震えて」上。
      final List<EpubSection> body = <EpubSection>[
        _section(
          0,
          '　なんて思ってるうちに、白瀬さんの体がちょっと熱くなってくる。\n'
          '「……あ……ん……」\n'
          '　体が震えて、けっこう強く押しつけられる。すごい。そして──。\n'
          '「ん……ん…………んんっ…………くぅっ……！」\n'
          '　白瀬さんが大きく体を震わせる。\n',
        ),
      ];
      final List<AudioCue> cues = <AudioCue>[
        _cue(0, 'なんて思ってるうちに'),
        _cue(1, '白瀬さんの体がちょっと熱くなってくる'),
        _cue(2, 'あっ'),
        _cue(3, '体が震えて結構強くおしつけられる'),
        _cue(4, 'すごい'),
        _cue(5, 'そして'),
        _cue(6, '白瀬さんが大きく体を震わせる'),
      ];
      final MatchResult r = EpubSrtMatcher.match(sections: body, cues: cues);
      expect(r.matches[3].matched, isFalse, reason: '前提：这句模糊不过线');
      expect(r.matches[4].matched, isTrue);
      expect(r.matches[4].score, 1.0);
      expect(r.matches[5].matched, isTrue);
      expect(r.matches[6].matched, isTrue);
    });
  });
}
