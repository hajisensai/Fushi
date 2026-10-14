// 复习媒体存储（内容哈希去重、路径安全）与卡面媒体改写（裸文件名 → 虚拟域 URL、
// [sound:] → 播放按钮、拦截器只认卡面虚拟域）。
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Color;

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart';
import 'package:fushi/src/srs/srs_card_media.dart';
import 'package:fushi/src/srs/srs_media_store.dart';

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('fushi_srs_media_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  group('SrsMediaStore', () {
    test('同内容同名（sha1 + 扩展名），重复存不重写', () async {
      final SrsMediaStore store = SrsMediaStore(
        SrsMediaStore.directoryFor(tmp, 'p-uid'),
      );
      final Uint8List bytes = Uint8List.fromList(<int>[1, 2, 3]);
      final String a = await store.store('foo.MP3', bytes);
      final String b = await store.store('bar.mp3', bytes);
      expect(a, b);
      expect(a, matches(RegExp(r'^[0-9a-f]{40}\.mp3$')));
      expect(store.root.path, endsWith('${Platform.pathSeparator}p-uid'));
      expect(await store.load(a), bytes);
      expect(store.root.listSync(), hasLength(1));
      // 不同内容 → 不同名。
      final String c = await store.store('foo.mp3', Uint8List(2));
      expect(c, isNot(a));
    });

    test('扩展名不合法时省略；不安全的名字解析为 null', () async {
      expect(SrsMediaStore.extensionOf('a.b.PNG'), 'png');
      expect(SrsMediaStore.extensionOf('noext'), '');
      expect(SrsMediaStore.extensionOf('weird.ex-t'), '');
      final SrsMediaStore store = SrsMediaStore(tmp);
      for (final String bad in <String>[
        '../x.png',
        'a/b.png',
        r'a\b.png',
        'C:evil',
        '..',
        '',
      ]) {
        expect(store.resolve(bad), isNull, reason: bad);
        expect(await store.load(bad), isNull, reason: bad);
      }
    });
  });

  group('卡面媒体改写', () {
    const String prefix = 'https://srs.local/media/';

    test('裸文件名 src / poster / CSS url() 改到虚拟域；外链与 data: 不动', () {
      final String out = srsLocalizeCardHtml(
        '<img src="a b&amp;c.png"><video src=\'clip.webm\' poster="p.jpg"></video>'
        '<img src="https://x.org/y.png"><img src="data:image/png;base64,AA">'
        '<img src="/abs.png"><div style="background:url(_bg.png)"></div>',
        urlPrefix: prefix,
      );
      expect(out, contains('src="${prefix}a%20b%26c.png"'));
      expect(out, contains("src='${prefix}clip.webm'"));
      expect(out, contains('poster="${prefix}p.jpg"'));
      expect(out, contains('src="https://x.org/y.png"'));
      expect(out, contains('src="data:image/png;base64,AA"'));
      expect(out, contains('src="/abs.png"'));
      expect(out, contains('url("${prefix}_bg.png")'));
    });

    test('[sound:x] → 播放按钮（data-sound 原名）', () {
      final String out = srsLocalizeCardHtml(
        '前[sound:word.mp3]后',
        urlPrefix: prefix,
      );
      expect(out, isNot(contains('[sound:')));
      expect(out, contains('class="fushi-srs-sound"'));
      expect(out, contains('data-sound="word.mp3"'));
    });

    test('拦截器只认卡面虚拟域的 /media/ 路径', () {
      expect(srsMediaNameFromUrl(Uri.parse('${prefix}a%20b.png')), 'a b.png');
      expect(
        srsMediaNameFromUrl(Uri.parse('fushi-srs://srs.local/media/x.mp3')),
        'x.mp3',
      );
      expect(
        srsMediaNameFromUrl(Uri.parse('https://fushi.local/media/x')),
        isNull,
      );
      expect(
        srsMediaNameFromUrl(Uri.parse('https://srs.local/other/x')),
        isNull,
      );
    });

    test('拦截响应：有文件 200 + MIME，没有 404，非卡面 URL 交回 null', () async {
      final SrsMediaStore store = SrsMediaStore(tmp);
      final String name = await store.store(
        'pic.png',
        Uint8List.fromList(<int>[5, 6]),
      );
      final dynamic ok = await srsCardMediaResponse(
        Uri.parse('$prefix$name'),
        store,
      );
      expect(ok.statusCode, 200);
      expect(ok.contentType, 'image/png');
      final dynamic missing = await srsCardMediaResponse(
        Uri.parse('${prefix}nope.png'),
        store,
      );
      expect(missing.statusCode, 404);
      expect(
        await srsCardMediaResponse(Uri.parse('https://fushi.local/x'), store),
        isNull,
      );
    });

    test('卡面 HTML：有前缀时注入播放按钮样式与点击委托', () {
      const SrsCardFace face = SrsCardFace(
        cardId: 'c',
        showingAnswer: false,
        bodyHtml: '<img src="a.png">[sound:b.mp3]',
        css: '.card{background:url(bg.jpg)}',
        languageCode: null,
        onBridgeKey: _noop,
      );
      final String html = srsCardHtml(
        face: face,
        dark: false,
        background: const Color(0xFFFFFFFF),
        foreground: const Color(0xFF000000),
        mediaUrlPrefix: prefix,
        accent: const Color(0xFF6750A4),
      );
      expect(html, contains('src="${prefix}a.png"'));
      expect(html, contains('url("${prefix}bg.jpg")'));
      expect(html, contains(kSrsPlaySoundHandler));
      expect(html, contains('--fushi-srs-accent:#6750a4'));
      // 无前缀（旧调用）逐字节不变。
      final String plain = srsCardHtml(
        face: face,
        dark: false,
        background: const Color(0xFFFFFFFF),
        foreground: const Color(0xFF000000),
      );
      expect(plain, contains('src="a.png"'));
      expect(plain, contains('[sound:b.mp3]'));
    });
  });
}

void _noop(String _) {}
