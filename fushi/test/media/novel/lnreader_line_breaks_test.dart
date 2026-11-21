import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/novel/online/lnreader_line_breaks.dart';
import 'package:fushi/src/media/novel/online/lnreader_models.dart';

/// 拍板台 zCkIxtnwcV：LNReader 源级开关「合并段内换行」。
void main() {
  group('mergeLnReaderSoftLineBreaks', () {
    test('カクヨム式逐行 <p>：句中折行接回去，空行与句末断行保留', () {
      // 宿主 toXhtml 之后的カクヨム正文形态：每行一个 <p>，空行是 <p><br/></p>。
      const String input =
          '<p>　彼女はゆっくりと振り返って、</p>\n'
          '<p>僕の顔を見た。</p>\n'
          '<p><br/></p>\n'
          '<p>「どうしたの？」</p>\n'
          '<p>　返事はなかった。</p>';
      expect(
        mergeLnReaderSoftLineBreaks(input),
        '<p>　彼女はゆっくりと振り返って、僕の顔を見た。</p>\n'
        '<p><br/></p>\n'
        '<p>「どうしたの？」</p>\n'
        '<p>　返事はなかった。</p>',
      );
    });

    test('多行连续折行接成一段', () {
      expect(
        mergeLnReaderSoftLineBreaks('<p>一行目と</p><p>二行目と</p><p>三行目。</p>'),
        '<p>一行目と二行目と三行目。</p>',
      );
    });

    test('下一行是对话 / 全角空格缩进 / 符号开头时不接', () {
      const String input =
          '<p>彼は言った</p><p>「行こう」</p>'
          '<p>そして</p><p>　新しい段落。</p>'
          '<p>場面</p><p>◇◇◇</p>';
      expect(mergeLnReaderSoftLineBreaks(input), input);
    });

    test('上一行以句末 / 收尾标点结束时不接', () {
      const String input =
          '<p>終わり。</p><p>次。</p>'
          '<p>「台詞」</p><p>次。</p>'
          '<p>なんだと！</p><p>次。</p>'
          '<p>そうか……</p><p>次。</p>';
      expect(mergeLnReaderSoftLineBreaks(input), input);
    });

    test('振假名读音不算行尾 / 行首；ruby 元素整体搬进上一行', () {
      expect(
        mergeLnReaderSoftLineBreaks(
          '<p>その<ruby>剣<rp>（</rp><rt>つるぎ</rt><rp>）</rp></ruby></p>'
          '<p><ruby>光<rt>ひかり</rt></ruby>は消えた。</p>',
        ),
        '<p>その<ruby>剣<rp>（</rp><rt>つるぎ</rt><rp>）</rp></ruby>'
        '<ruby>光<rt>ひかり</rt></ruby>は消えた。</p>',
      );
    });

    test('带插图 / 标题的段落不动', () {
      const String input =
          '<div><h2>第一話</h2></div><p><br/><br/></p>'
          '<p>挿絵の前</p><p><img src="images/c1-0.jpg" alt=""/></p>'
          '<p>挿絵の後</p>';
      expect(mergeLnReaderSoftLineBreaks(input), input);
    });

    test('单个 <br> 断行：句中折行去掉 <br>，空行（连续 <br>）保留', () {
      expect(
        mergeLnReaderSoftLineBreaks(
          '<div>空を見上げると<br/>\n星が瞬いていた。<br/><br/>翌朝。</div>',
        ),
        '<div>空を見上げると星が瞬いていた。<br/><br/>翌朝。</div>',
      );
    });

    test('拉丁文折行补一个空格', () {
      expect(
        mergeLnReaderSoftLineBreaks('<p>The quick brown</p><p>fox jumps.</p>'),
        '<p>The quick brown fox jumps.</p>',
      );
    });

    test('带属性的下一行不并（属性可能是锚点 / 语言标记）', () {
      const String input = '<p>前の行</p><p lang="en">next</p>';
      expect(mergeLnReaderSoftLineBreaks(input), input);
    });

    test('文字与转义原样保留', () {
      expect(
        mergeLnReaderSoftLineBreaks('<p>a &lt; b &amp; d</p><p>c</p>'),
        '<p>a &lt; b &amp; d c</p>',
      );
    });

    test('不是良构 XML 时原样返回，不丢正文', () {
      const String broken = '<p>開いたまま<p>閉じない';
      expect(mergeLnReaderSoftLineBreaks(broken), broken);
    });
  });

  group('LnReaderInstalledPlugin.mergeLineBreaks', () {
    const LnReaderInstalledPlugin plugin = LnReaderInstalledPlugin(
      id: 'jp.kakuyomu',
      name: 'Kakuyomu',
      site: 'https://kakuyomu.jp/',
      lang: '日本語',
      version: '1.0.0',
      url: '',
      iconUrl: '',
      storeUrl: '',
      enabled: true,
      pinned: false,
      sortOrder: 0,
      installedAt: 0,
    );

    test('默认关；旧 state.json 没有这个字段时读成关', () {
      expect(plugin.mergeLineBreaks, isFalse);
      final Map<String, Object?> legacy = plugin.toJson()
        ..remove('mergeLineBreaks');
      expect(
        LnReaderInstalledPlugin.tryFromJson(legacy)!.mergeLineBreaks,
        isFalse,
      );
    });

    test('开关经 copyWith 与 JSON 往返保留', () {
      final LnReaderInstalledPlugin on = plugin.copyWith(mergeLineBreaks: true);
      expect(on.mergeLineBreaks, isTrue);
      expect(
        LnReaderInstalledPlugin.tryFromJson(on.toJson())!.mergeLineBreaks,
        isTrue,
      );
      expect(on.copyWith(pinned: true).mergeLineBreaks, isTrue);
    });
  });
}
