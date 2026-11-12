// 反馈 rLCxUJ-2i4 / PR #3160 拍板项：ASS 把一句台词拆成几条起止相同的 Dialogue 时，
// 复制 / 制卡合成一句（按显示顺序拼接）。钉 [video_simultaneous_cues.dart] 的判据：
// 同起止 + 同 Layer + 同 Style（不比边距）才算一句；组内按画面自上而下排；文本按
// `\N` 同一口径以空格拼接；srt/vtt（无 Style）不合并；上下文按「句」切。
import 'package:test/test.dart';
import 'package:fushi/src/media/audiobook/mining_sentence_draft.dart';
import 'package:fushi/src/media/video/video_simultaneous_cues.dart';
import 'package:fushi_audio/fushi_audio.dart';

const SubtitleCueStyle _default = SubtitleCueStyle(
  fontName: 'Arial',
  fontSizePx: 48,
  primaryColorArgb: 0xFFFFFFFF,
);
const SubtitleCueStyle _sign = SubtitleCueStyle(
  fontName: 'Arial',
  fontSizePx: 36,
  primaryColorArgb: 0xFFFFFF00,
);

int _seq = 0;

AudioCue _ass(
  String text, {
  int startMs = 446000,
  int endMs = 448300,
  double? y,
  double x = 0.5,
  SubtitleCueStyle? style = _default,
  int layer = 0,
}) {
  final AudioCue cue = AudioCue()
    ..bookKey = 'video/1'
    ..chapterHref = 'video://default'
    ..sentenceIndex = _seq++
    ..textFragmentId = ''
    ..text = text
    ..startMs = startMs
    ..endMs = endMs
    ..audioFileIndex = 0;
  cue.markup = SubtitleMarkup(
    plainText: text,
    spans: const <SubtitleSpan>[],
    posFraction: y == null ? null : SubtitlePos(x, y),
    cueStyle: style,
    playResY: 720,
    layer: layer,
  );
  return cue;
}

AudioCue _srt(String text, {int startMs = 0, int endMs = 1000}) => AudioCue()
  ..bookKey = 'video/1'
  ..chapterHref = 'video://default'
  ..sentenceIndex = _seq++
  ..textFragmentId = ''
  ..text = text
  ..startMs = startMs
  ..endMs = endMs
  ..audioFileIndex = 0;

void main() {
  group('cuesShowAsOneSentence', () {
    test('反馈原文：起止相同、同 Style 的两行算一句', () {
      final AudioCue a = _ass('＜俺は 浩一に', y: 600 / 720);
      final AudioCue b = _ass('呼び出しをくらった＞', y: 680 / 720);
      expect(cuesShowAsOneSentence(a, b), isTrue);
    });

    test('起点或终点差 10ms 不合并（不设容差）', () {
      final AudioCue a = _ass('一');
      expect(cuesShowAsOneSentence(a, _ass('二', startMs: 446010)), isFalse);
      expect(cuesShowAsOneSentence(a, _ass('二', endMs: 448310)), isFalse);
    });

    test('不同 Style（标牌 / 注释）不合进对白', () {
      expect(
        cuesShowAsOneSentence(_ass('対白'), _ass('看板', style: _sign)),
        isFalse,
      );
    });

    test('只差事件级边距的同一 Style 仍算一句', () {
      final AudioCue a = _ass(
        '上の行',
        style: _default.withEventMargins(marginV: 80),
      );
      final AudioCue b = _ass(
        '下の行',
        style: _default.withEventMargins(marginV: 20),
      );
      expect(cuesShowAsOneSentence(a, b), isTrue);
    });

    test('不同 Layer 不合并（多层特效同位叠画）', () {
      expect(cuesShowAsOneSentence(_ass('光'), _ass('字', layer: 1)), isFalse);
    });

    test('srt / vtt（无 Style）同时显示也不合并', () {
      expect(cuesShowAsOneSentence(_srt('- はい'), _srt('- いいえ')), isFalse);
    });

    test('空正文 cue 不参与', () {
      expect(cuesShowAsOneSentence(_ass('台詞'), _ass('  ')), isFalse);
    });
  });

  group('simultaneousCueText', () {
    test('按显示顺序（画面自上而下）以空格拼接，与文件序无关', () {
      // 文件序先写下面那行。
      final AudioCue lower = _ass('呼び出しをくらった＞', y: 680 / 720);
      final AudioCue upper = _ass('＜俺は 浩一に', y: 600 / 720);
      final List<AudioCue> cues = <AudioCue>[lower, upper];
      const String expected = '＜俺は 浩一に 呼び出しをくらった＞';
      expect(simultaneousCueText(cues, lower), expected);
      expect(simultaneousCueText(cues, upper), expected);
    });

    test('竖直位置相同保持文件序', () {
      final AudioCue a = _ass('前');
      final AudioCue b = _ass('後');
      expect(simultaneousCueText(<AudioCue>[a, b], b), '前 後');
    });

    test('单独一行就是它自己（trim）', () {
      final AudioCue only = _ass('  ひとこと  ');
      final AudioCue other = _ass('別の句', startMs: 450000, endMs: 451000);
      expect(simultaneousCueText(<AudioCue>[only, other], only), 'ひとこと');
    });

    test('同时出现的标牌不拼进对白', () {
      final AudioCue line = _ass('対白');
      final AudioCue sign = _ass('看板', style: _sign, y: 0.1);
      expect(simultaneousCueText(<AudioCue>[sign, line], line), '対白');
    });

    test('重复的同文行只留一份', () {
      final AudioCue a = _ass('同じ', y: 0.8);
      final AudioCue b = _ass('同じ', y: 0.9);
      expect(simultaneousCueText(<AudioCue>[a, b], a), '同じ');
    });

    // 逐字 / 逐词各带 \pos 拼成一行的事件（同起止同 Style）：同一画面行按 x 自左而右
    // 直接相连，不插空格，行内重复的字不去重；换行才以空格分隔。
    test('同一画面行的片段按 x 直接相连，不同画面行以空格分隔', () {
      final AudioCue o = _ass('を', y: 0.9, x: 0.5);
      final AudioCue te = _ass('手', y: 0.9, x: 0.4);
      final AudioCue nobu = _ass('伸', y: 0.9, x: 0.6);
      final AudioCue a1 = _ass('あ', y: 0.8, x: 0.4);
      final AudioCue a2 = _ass('あ', y: 0.8, x: 0.5);
      final List<AudioCue> cues = <AudioCue>[o, nobu, te, a2, a1];
      expect(simultaneousCueText(cues, o), 'ああ 手を伸');
    });

    test('锚点不在流里时按判据收同组再补进锚点', () {
      final AudioCue stray = _ass('下', y: 0.9);
      final AudioCue inStream = _ass('上', y: 0.8);
      expect(simultaneousCueText(<AudioCue>[inStream], stray), '上 下');
    });
  });

  group('videoLookupMiningSentence', () {
    test('被点的行属于锚点那一句 → 整句', () {
      final AudioCue upper = _ass('＜俺は 浩一に', y: 600 / 720);
      final AudioCue lower = _ass('呼び出しをくらった＞', y: 680 / 720);
      expect(
        videoLookupMiningSentence(
          cues: <AudioCue>[upper, lower],
          anchor: lower,
          tappedSentence: '呼び出しをくらった＞',
        ),
        '＜俺は 浩一に 呼び出しをくらった＞',
      );
    });

    test('锚点那一句里没有被点的行 → 保留被点的行', () {
      final AudioCue upper = _ass('上', y: 0.8);
      final AudioCue lower = _ass('下', y: 0.9);
      expect(
        videoLookupMiningSentence(
          cues: <AudioCue>[upper, lower],
          anchor: lower,
          tappedSentence: '副字幕の行',
        ),
        '副字幕の行',
      );
    });

    test('无锚点 / 锚点单独成句 → 原样', () {
      final AudioCue only = _ass('ひとり');
      expect(
        videoLookupMiningSentence(
          cues: <AudioCue>[only],
          anchor: null,
          tappedSentence: ' 原文 ',
        ),
        ' 原文 ',
      );
      expect(
        videoLookupMiningSentence(
          cues: <AudioCue>[only],
          anchor: only,
          tappedSentence: 'ひとり',
        ),
        'ひとり',
      );
    });
  });

  group('groupSimultaneousCues + cueContextNeighbors（上下 N 句按句切）', () {
    test('同一句的两行合成一个元素；同起点的标牌自成一句', () {
      final AudioCue prev = _ass('前の句', startMs: 440000, endMs: 442000);
      final AudioCue lower = _ass('下の行', y: 0.9);
      final AudioCue upper = _ass('上の行', y: 0.8);
      final AudioCue sign = _ass('看板', style: _sign, y: 0.1);
      final AudioCue next = _ass('次の句', startMs: 450000, endMs: 452000);
      final List<List<AudioCue>> groups = groupSimultaneousCues(<AudioCue>[
        prev,
        lower,
        sign,
        upper,
        next,
      ]);
      expect(groups.map(joinSimultaneousCueText).toList(), <String>[
        '前の句',
        '上の行 下の行',
        '看板',
        '次の句',
      ]);

      final int idx = groups.indexWhere(
        (List<AudioCue> g) => g.any((AudioCue c) => identical(c, lower)),
      );
      final ({List<List<AudioCue>> prev, List<List<AudioCue>> next}) around =
          cueContextNeighbors<List<AudioCue>>(
            cues: groups,
            anchorIndex: idx,
            prevCount: 1,
            nextCount: 1,
          );
      expect(around.prev.map(joinSimultaneousCueText), <String>['前の句']);
      // 「下 1 句」不会取到同一句的另一行。
      expect(around.next.map(joinSimultaneousCueText), <String>['看板']);
    });

    test('cueContextNeighbors 泛型后越界仍返回空', () {
      final ({List<int> prev, List<int> next}) r = cueContextNeighbors<int>(
        cues: <int>[1, 2, 3],
        anchorIndex: 5,
        prevCount: 1,
        nextCount: 1,
      );
      expect(r.prev, isEmpty);
      expect(r.next, isEmpty);
    });
  });
}
