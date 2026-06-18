/// Generates a synthetic test EPUB with marker paragraphs for pagination testing.
///
/// Run: dart run integration_test/helpers/generate_test_epub.dart
/// Output: integration_test/fixtures/test_pagination.epub
///
/// Also imported by reader_pagination_test.dart (EpubGenerator) to seed the
/// marker book at runtime, so the suite is hermetic on a fresh install.
// ignore_for_file: avoid_print
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

// Minimal ZIP implementation for EPUB generation (no external deps).

void main() {
  final epub = EpubGenerator();
  final bytes = epub.generate();
  final outFile = File('integration_test/fixtures/test_pagination.epub');
  outFile.createSync(recursive: true);
  outFile.writeAsBytesSync(bytes);
  print('Generated ${outFile.path} (${bytes.length} bytes)');
}

class EpubGenerator {
  static const _lookupLead = 'testword 猫 testword 猫 testword 猫。';

  static const _jpTexts = [
    '桜の花が咲き始めた頃、少年は初めてその図書館を訪れた。古い木の扉を押し開けると、埃の匂いと紙の香りが混ざり合った空気が流れ出てきた。',
    '窓から差し込む午後の光が、本棚の間を縫うように伸びていた。少年は息を殺して、その光の道を辿った。',
    '図書館の奥には、誰も近寄らない古びた書架があった。そこには、背表紙の文字も読めないほど古い本が並んでいた。',
    '少年が一冊の本を手に取ると、ページの間から小さな鍵が落ちた。銀色に光るその鍵は、どこかの扉を開けるもののようだった。',
    '彼は鍵を握りしめ、図書館の中を探索し始めた。廊下の突き当たりに、見覚えのない扉を見つけた。',
    '扉の向こうには、想像もしなかった世界が広がっていた。空は紫色で、二つの月が浮かんでいた。',
    '風が吹くたびに、木々の葉が音楽を奏でた。まるで森全体が一つの楽器のようだった。',
    '小さな川のほとりに座って、少年は持ってきた本を開いた。物語の中の世界と、今いる世界が重なって見えた。',
    '日が暮れ始めると、森の中に小さな灯りが点り始めた。蛍のような光が、道を示すように飛んでいた。',
    '少年は光に導かれるまま歩き続けた。やがて、大きな湖にたどり着いた。湖面に映る二つの月が、静かに揺れていた。',
  ];

  static const _shortTexts = [
    '朝の光。',
    '風が吹く。',
    '鳥が鳴いた。',
    '花が咲いた。',
    '雨が止んだ。',
  ];

  static const _longText = '彼女は長い間、窓の外を見つめていた。街を歩く人々、走り去る車、風に揺れる街路樹。'
      'すべてが日常の一部であり、特別なことは何もなかった。しかし、今日は何かが違った。'
      '空気の匂いが変わったのか、光の色が変わったのか、それとも自分自身が変わったのか。'
      '彼女にはわからなかった。ただ、胸の奥で何かが動いたような気がした。'
      'それは期待かもしれないし、不安かもしれない。あるいは、その両方が混ざり合ったものかもしれない。';

  Uint8List generate() {
    final files = <String, Uint8List>{};

    files['mimetype'] = _utf8('application/epub+zip');
    files['META-INF/container.xml'] = _utf8(_containerXml);
    files['OEBPS/stylesheet.css'] = _utf8(_stylesheet);
    files['OEBPS/content.opf'] = _utf8(_buildOpf());
    files['OEBPS/toc.ncx'] = _utf8(_buildNcx());

    // Chapter 1: Standard Japanese paragraphs (420 markers)
    files['OEBPS/chapter_01_standard.xhtml'] =
        _utf8(_buildChapter('第一章　標準テスト', _generateStandard(420)));

    // Chapter 2: Very short (5 markers, tests 1-2 page scenarios)
    files['OEBPS/chapter_02_short.xhtml'] =
        _utf8(_buildChapter('第二章　短章テスト', _generateShort(5)));

    // Chapter 3: Mixed images + text (50 markers + inline SVG)
    files['OEBPS/chapter_03_images.xhtml'] =
        _utf8(_buildChapter('第三章　画像混在テスト', _generateWithImages(50)));

    // Chapter 4: Heavy ruby/furigana (100 markers)
    files['OEBPS/chapter_04_ruby.xhtml'] =
        _utf8(_buildChapter('第四章　振り仮名テスト', _generateWithRuby(100)));

    // Chapter 5: Vertical-optimized (100 markers with vertical-friendly content)
    files['OEBPS/chapter_05_vertical.xhtml'] =
        _utf8(_buildChapter('第五章　縦書きテスト', _generateStandard(100)));

    // Chapter 6: Mixed elements - headings, lists, blockquotes (80 markers)
    files['OEBPS/chapter_06_mixed.xhtml'] =
        _utf8(_buildChapter('第六章　混合要素テスト', _generateMixed(80)));

    // Chapter 7: Long chapter (500 markers)
    files['OEBPS/chapter_07_long.xhtml'] =
        _utf8(_buildChapter('第七章　長文テスト', _generateStandard(500)));

    return _buildZip(files);
  }

  String _generateStandard(int count) {
    final buf = StringBuffer();
    for (int i = 1; i <= count; i++) {
      final id = i.toString().padLeft(3, '0');
      final text = _jpTexts[(i - 1) % _jpTexts.length];
      buf.writeln('  <p id="m$id">【M$id】$_lookupLead$text</p>');
    }
    return buf.toString();
  }

  String _generateShort(int count) {
    final buf = StringBuffer();
    for (int i = 1; i <= count; i++) {
      final id = i.toString().padLeft(3, '0');
      final text = _shortTexts[(i - 1) % _shortTexts.length];
      buf.writeln('  <p id="m$id">【M$id】$text</p>');
    }
    return buf.toString();
  }

  String _generateWithImages(int count) {
    final buf = StringBuffer();
    for (int i = 1; i <= count; i++) {
      final id = i.toString().padLeft(3, '0');
      final text = _jpTexts[(i - 1) % _jpTexts.length];
      buf.writeln('  <p id="m$id">【M$id】$text</p>');
      if (i % 5 == 0) {
        buf.writeln(
            '  <svg xmlns="http://www.w3.org/2000/svg" width="200" height="150" '
            'viewBox="0 0 200 150">'
            '<rect width="200" height="150" fill="#ddd"/>'
            '<text x="100" y="75" text-anchor="middle" '
            'font-size="14" fill="#666">Image $i</text></svg>');
      }
    }
    return buf.toString();
  }

  String _generateWithRuby(int count) {
    final rubyPairs = [
      ['図書館', 'としょかん'],
      ['少年', 'しょうねん'],
      ['世界', 'せかい'],
      ['物語', 'ものがたり'],
      ['音楽', 'おんがく'],
      ['記憶', 'きおく'],
      ['冒険', 'ぼうけん'],
      ['秘密', 'ひみつ'],
      ['未来', 'みらい'],
      ['約束', 'やくそく'],
    ];
    final buf = StringBuffer();
    for (int i = 1; i <= count; i++) {
      final id = i.toString().padLeft(3, '0');
      final pair = rubyPairs[(i - 1) % rubyPairs.length];
      buf.writeln('  <p id="m$id">【M$id】'
          '<ruby>${pair[0]}<rt>${pair[1]}</rt></ruby>'
          'の中で、彼は新しい'
          '<ruby>${rubyPairs[(i + 2) % rubyPairs.length][0]}'
          '<rt>${rubyPairs[(i + 2) % rubyPairs.length][1]}</rt></ruby>'
          'を見つけた。それは彼の人生を変える出来事だった。</p>');
    }
    return buf.toString();
  }

  String _generateMixed(int count) {
    final buf = StringBuffer();
    int marker = 1;
    while (marker <= count) {
      final section = ((marker - 1) / 10).floor() + 1;
      final id = marker.toString().padLeft(3, '0');

      if (marker % 10 == 1) {
        buf.writeln('  <h2>セクション $section</h2>');
      }

      if (marker % 10 == 3) {
        buf.writeln('  <blockquote><p id="m$id">【M$id】'
            '「${_jpTexts[(marker - 1) % _jpTexts.length]}」</p></blockquote>');
      } else if (marker % 10 == 5) {
        buf.writeln('  <ul>');
        buf.writeln('    <li><p id="m$id">【M$id】'
            '${_shortTexts[(marker - 1) % _shortTexts.length]}</p></li>');
        marker++;
        if (marker <= count) {
          final id2 = marker.toString().padLeft(3, '0');
          buf.writeln('    <li><p id="m$id2">【M$id2】'
              '${_shortTexts[(marker - 1) % _shortTexts.length]}</p></li>');
        }
        buf.writeln('  </ul>');
      } else if (marker % 10 == 8) {
        buf.writeln('  <p id="m$id">【M$id】$_longText</p>');
      } else {
        final text = _jpTexts[(marker - 1) % _jpTexts.length];
        buf.writeln('  <p id="m$id">【M$id】$text</p>');
      }
      marker++;
    }
    return buf.toString();
  }

  String _buildChapter(String title, String body) {
    return '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="ja" lang="ja">
<head>
  <meta charset="UTF-8"/>
  <title>$title</title>
  <link rel="stylesheet" type="text/css" href="stylesheet.css"/>
</head>
<body>
  <h1>$title</h1>
$body
</body>
</html>''';
  }

  String _buildOpf() {
    final chapters = [
      'chapter_01_standard',
      'chapter_02_short',
      'chapter_03_images',
      'chapter_04_ruby',
      'chapter_05_vertical',
      'chapter_06_mixed',
      'chapter_07_long',
    ];
    final items = chapters
        .map((c) => '    <item id="$c" href="$c.xhtml" '
            'media-type="application/xhtml+xml"/>')
        .join('\n');
    final refs = chapters.map((c) => '    <itemref idref="$c"/>').join('\n');
    return '''<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="uid">urn:uuid:test-pagination-epub-001</dc:identifier>
    <dc:title>Pagination Test Book</dc:title>
    <dc:language>ja</dc:language>
    <dc:creator>Hibiki Test Suite</dc:creator>
    <meta property="dcterms:modified">2026-01-01T00:00:00Z</meta>
  </metadata>
  <manifest>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
    <item id="css" href="stylesheet.css" media-type="text/css"/>
$items
  </manifest>
  <spine toc="ncx">
$refs
  </spine>
</package>''';
  }

  String _buildNcx() {
    final titles = [
      '第一章　標準テスト',
      '第二章　短章テスト',
      '第三章　画像混在テスト',
      '第四章　振り仮名テスト',
      '第五章　縦書きテスト',
      '第六章　混合要素テスト',
      '第七章　長文テスト',
    ];
    final files = [
      'chapter_01_standard',
      'chapter_02_short',
      'chapter_03_images',
      'chapter_04_ruby',
      'chapter_05_vertical',
      'chapter_06_mixed',
      'chapter_07_long',
    ];
    final points = StringBuffer();
    for (int i = 0; i < titles.length; i++) {
      points.writeln('''    <navPoint id="nav${i + 1}" playOrder="${i + 1}">
      <navLabel><text>${titles[i]}</text></navLabel>
      <content src="${files[i]}.xhtml"/>
    </navPoint>''');
    }
    return '''<?xml version="1.0" encoding="UTF-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <head>
    <meta name="dtb:uid" content="urn:uuid:test-pagination-epub-001"/>
  </head>
  <docTitle><text>Pagination Test Book</text></docTitle>
  <navMap>
${points.toString().trimRight()}
  </navMap>
</ncx>''';
  }

  static const _containerXml = '''<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>''';

  static const _stylesheet = '''
body {
  font-family: serif;
  margin: 0;
  padding: 0;
}
h1 { font-size: 1.5em; margin-bottom: 1em; }
h2 { font-size: 1.2em; margin-top: 1.5em; margin-bottom: 0.5em; }
p { margin: 0.5em 0; }
blockquote { margin: 1em 2em; font-style: italic; }
svg { display: block; margin: 1em auto; max-width: 100%; }
''';

  Uint8List _utf8(String s) => Uint8List.fromList(utf8.encode(s));

  /// Minimal ZIP builder — stores files uncompressed (EPUB spec allows this).
  Uint8List _buildZip(Map<String, Uint8List> files) {
    final buf = BytesBuilder();
    final centralEntries = <_CentralEntry>[];

    // 'mimetype' must be first and stored uncompressed with no extra fields
    final orderedKeys = <String>['mimetype'];
    for (final key in files.keys) {
      if (key != 'mimetype') orderedKeys.add(key);
    }

    for (final name in orderedKeys) {
      final data = files[name]!;
      final nameBytes = Uint8List.fromList(utf8.encode(name));
      final offset = buf.length;

      // Local file header
      buf.add(_u32(0x04034b50)); // signature
      buf.add(_u16(20)); // version needed
      buf.add(_u16(0)); // flags
      buf.add(_u16(0)); // compression: stored
      buf.add(_u16(0)); // mod time
      buf.add(_u16(0)); // mod date
      buf.add(_u32(_crc32(data))); // crc-32
      buf.add(_u32(data.length)); // compressed size
      buf.add(_u32(data.length)); // uncompressed size
      buf.add(_u16(nameBytes.length)); // name length
      buf.add(_u16(0)); // extra length
      buf.add(nameBytes);
      buf.add(data);

      centralEntries
          .add(_CentralEntry(nameBytes, data.length, _crc32(data), offset));
    }

    final centralStart = buf.length;
    for (final entry in centralEntries) {
      buf.add(_u32(0x02014b50)); // signature
      buf.add(_u16(20)); // version made by
      buf.add(_u16(20)); // version needed
      buf.add(_u16(0)); // flags
      buf.add(_u16(0)); // compression
      buf.add(_u16(0)); // mod time
      buf.add(_u16(0)); // mod date
      buf.add(_u32(entry.crc)); // crc-32
      buf.add(_u32(entry.size)); // compressed size
      buf.add(_u32(entry.size)); // uncompressed size
      buf.add(_u16(entry.name.length)); // name length
      buf.add(_u16(0)); // extra length
      buf.add(_u16(0)); // comment length
      buf.add(_u16(0)); // disk number start
      buf.add(_u16(0)); // internal attrs
      buf.add(_u32(0)); // external attrs
      buf.add(_u32(entry.offset)); // relative offset
      buf.add(entry.name);
    }
    final centralEnd = buf.length;

    // End of central directory
    buf.add(_u32(0x06054b50)); // signature
    buf.add(_u16(0)); // disk number
    buf.add(_u16(0)); // central dir disk
    buf.add(_u16(centralEntries.length)); // entries on this disk
    buf.add(_u16(centralEntries.length)); // total entries
    buf.add(_u32(centralEnd - centralStart)); // central dir size
    buf.add(_u32(centralStart)); // central dir offset
    buf.add(_u16(0)); // comment length

    return buf.toBytes();
  }

  Uint8List _u16(int v) => Uint8List.fromList([v & 0xFF, (v >> 8) & 0xFF]);

  Uint8List _u32(int v) => Uint8List.fromList(
      [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF]);

  int _crc32(Uint8List data) {
    int crc = 0xFFFFFFFF;
    for (final byte in data) {
      crc ^= byte;
      for (int j = 0; j < 8; j++) {
        crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
      }
    }
    return crc ^ 0xFFFFFFFF;
  }
}

class _CentralEntry {
  final Uint8List name;
  final int size;
  final int crc;
  final int offset;
  _CentralEntry(this.name, this.size, this.crc, this.offset);
}
