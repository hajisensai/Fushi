// `[sound:x]` 的词法与文件名解码只有一份（srs_sound_tag.dart）：卡面的三套渲染、宿主的
// 自动播放 / 重播清单、远程刷卡的媒体预取、字段编辑器对同一个标记解出同一个文件名。
import 'dart:io';

import 'package:fushi/src/srs/srs_card_autoplay.dart';
import 'package:fushi/src/srs/srs_card_media.dart';
import 'package:fushi/src/srs/srs_fushi_card_fields.dart';
import 'package:fushi/src/srs/srs_html_card.dart';
import 'package:fushi/src/srs/srs_sound_tag.dart';
import 'package:test/test.dart';

void main() {
  group('词法与转义', () {
    test('组 1 是标记里的原始文件名；取名字去首尾空白、解实体', () {
      final Match m = srsSoundTagPattern.firstMatch(
        'a[sound: Tom &amp; Jerry.mp3 ]b',
      )!;
      expect(m.group(1), ' Tom &amp; Jerry.mp3 ');
      expect(srsSoundTagName(m.group(1)!), 'Tom & Jerry.mp3');
      expect(srsSoundTagPattern.hasMatch('[sound:]'), isFalse);
    });

    test('&amp; 最后解：&amp;lt; 是字面的 &lt;', () {
      expect(srsUnescapeMediaName('a&amp;lt;b'), 'a&lt;b');
      expect(srsUnescapeMediaName('&quot;&#39;&lt;&gt;&amp;'), '"\'<>&');
    });

    test('属性值转义与解码互逆', () {
      const String name = 'a "b" <c> & d.mp3';
      expect(srsEscapeHtml(name), 'a &quot;b&quot; &lt;c&gt; &amp; d.mp3');
      expect(srsUnescapeMediaName(srsEscapeHtml(name)), name);
    });
  });

  group('同一个标记，各处解出同一个文件名', () {
    // Anki 的字段是 HTML：文件名里的 & 存成 &amp;。
    const String field = '[sound: Tom &amp; Jerry.mp3 ][sound:plain.mp3]';
    const List<String> names = <String>['Tom & Jerry.mp3', 'plain.mp3'];

    test('整面 WebView：按钮的 data-sound', () {
      final String html = srsLocalizeCardHtml(
        field,
        urlPrefix: 'https://srs.local/',
      );
      expect(html, contains('data-sound="Tom &amp; Jerry.mp3"'));
      expect(html, contains('data-sound="plain.mp3"'));
      expect(html, isNot(contains('[sound:')));
    });

    test('宿主：自动播放 / 重播清单、远程刷卡的媒体预取', () {
      expect(srsCardSoundNames(field), names);
      expect(srsCardMediaNames(field), names);
      expect(srsCardReferencedMedia(field), names.toSet());
    });

    test('原生 Fushi 卡面与字段编辑器', () {
      expect(srsAudioSources(field), names);
      expect(srsSoundNames(field), names);
    });

    test('原生 HTML 卡面：发音键', () {
      final SrsHtmlBlock root = SrsHtmlCardFace.parse(
        '<div>$field</div>',
        '',
      ).layout(dark: false, foreground: 0xFF000000);
      expect(srsHtmlVisibleSounds(root), names);
    });
  });

  test('守卫：复习模块里 [sound:x] 的取名正则只有 srs_sound_tag.dart 一份', () {
    // 带捕获组的写法 = 要取文件名。各自再抄一份就会各有各的去空白 / 解实体口径。
    const String capture = r"RegExp(r'\[sound:(";
    final List<String> offenders = <String>[
      for (final String dir in <String>[
        'lib/src/srs',
        'lib/src/pages/implementations/srs',
      ])
        for (final FileSystemEntity e in Directory(
          dir,
        ).listSync(recursive: true))
          if (e is File &&
              e.path.endsWith('.dart') &&
              !e.path.endsWith('srs_sound_tag.dart') &&
              e.readAsStringSync().contains(capture))
            e.path,
    ];
    expect(offenders, isEmpty);
    expect(
      File('lib/src/srs/srs_sound_tag.dart').readAsStringSync(),
      contains(capture),
    );
  });
}
