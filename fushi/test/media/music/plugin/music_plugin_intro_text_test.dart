import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/plugin/music_plugin_intro_text.dart';

/// 网易云外文艺人简介的真实形状（Polyphia，2026-11-06 用户截图）：开头一张百科信息框
/// 逐行排，正文里夹着 `<h>History </h>` 这种平台标题标记。
const String _netease =
    'Origin\nPlano, Texas, US\nGenres\nProgressive rock  trap   instrumental rock\n'
    'Years active\n2010–present\n'
    'Polyphia is an American rock band based in Plano, Texas, formed in 2010.\n'
    'Their third album, New Levels New Devils, was their first to chart.\n'
    '<h>History </h>\n'
    'Polyphia formed in 2010. The name of the band comes from the word "polyphony".\n'
    'Style and influences\n'
    'Polyphia was originally known for their guitar covers &amp; more.';

void main() {
  test('<h> 变小标题，标记不再出现在正文里', () {
    final List<MusicIntroBlock> blocks = parseMusicIntro(_netease);
    expect(blocks.map((MusicIntroBlock b) => b.runtimeType).toList(), <Type>[
      MusicIntroParagraph,
      MusicIntroHeading,
      MusicIntroParagraph,
    ]);
    expect(blocks[1].text, 'History');
    for (final MusicIntroBlock b in blocks) {
      expect(b.text, isNot(contains('<')), reason: b.text);
    }
    expect(blocks[0].text, startsWith('Origin\nPlano, Texas, US\nGenres\n'));
    expect(
      blocks[0].text,
      contains('Progressive rock trap instrumental rock'),
      reason: '行内连续空白收成一个',
    );
    expect(blocks[2].text, endsWith('guitar covers & more.'));
  });

  test('br / p / 其它标签：换行保留、标签剥掉、空行分段', () {
    final List<MusicIntroBlock> blocks = parseMusicIntro(
      '<p>第一段<b>加粗</b></p><br><br>第二段<br/>同段第二行',
    );
    expect(blocks.map((MusicIntroBlock b) => b.text).toList(), <String>[
      '第一段加粗',
      '第二段\n同段第二行',
    ]);
    expect(blocks.every((MusicIntroBlock b) => b is MusicIntroParagraph), true);
  });

  test('没有标记的纯文本原样一段；空白输入没有块', () {
    expect(parseMusicIntro('一支乐队。').single.text, '一支乐队。');
    expect(parseMusicIntro('  \n <br> \n '), isEmpty);
  });

  test('头部摘要跳过信息框的键 / 值，取第一行正文', () {
    expect(
      musicIntroSummary(_netease),
      'Polyphia is an American rock band based in Plano, Texas, formed in 2010.',
    );
  });

  test('头部摘要：整篇没有句子退回第一段；没有正文回 null', () {
    expect(musicIntroSummary('短简介\n第二行'), '短简介\n第二行');
    expect(musicIntroSummary('<h>只有标题</h>'), isNull);
  });

  test('头部摘要：中文短句就是正文，不因为短被跳过', () {
    // 旧判据（行长 ≥ 40 字）会跳过这句，取到后面那条长英文行。
    expect(
      musicIntroSummary(
        '一支来自东京的乐队。\n\n'
        'This band was formed in Tokyo in 2010 and has released five albums.',
      ),
      '一支来自东京的乐队。',
    );
    // 中文信息框（键 / 值都不是句子）照样跳过，取第一句正文。
    expect(
      musicIntroSummary('出生地\n台湾新北\n代表作\n七里香\n周杰伦，华语流行乐男歌手。'),
      '周杰伦，华语流行乐男歌手。',
    );
    // 缩写结尾的值不算句子。
    expect(
      musicIntroSummary('Origin\nPlano, Texas, U.S.\nA band from Texas.'),
      'A band from Texas.',
    );
  });

  test('实体只解一次：&amp;lt; 是字面的 &lt;，不会被二次解成 <', () {
    expect(
      parseMusicIntro('a &amp;lt;b&amp;gt; &amp;amp; c').single.text,
      'a &lt;b&gt; &amp; c',
    );
    expect(
      parseMusicIntro('&lt;tag&gt; &quot;x&quot; &#39;y&#39;').single.text,
      '<tag> "x" \'y\'',
    );
  });

  test('纯文本：段与段之间的空行保留（专辑 / 歌单简介不再挤成一坨）', () {
    expect(musicIntroPlainText('第一段。\n\n第二段。\n同段第二行'), '第一段。\n\n第二段。\n同段第二行');
    expect(musicIntroPlainText('前言<h>History</h>正文'), '前言\n\nHistory\n\n正文');
  });
}
