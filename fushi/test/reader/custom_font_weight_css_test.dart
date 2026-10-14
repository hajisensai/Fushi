/// BUG：查词弹窗用导入字体（只有 Regular 的 Klee One）时，MD3 词头的强调字重让
/// WebView 合成加粗，轮廓自相交的「費」被描成中空。
///
/// 这里钉住两件事：
///   1. 导入字体生效时弹窗根上关掉字重合成（`font-synthesis-weight: none`），且每条
///      `@font-face` 声明文件真实字重；
///   2. 同名条目 = 同一家族的多个字重文件：家族名只进链一次、每个文件各一条
///      `@font-face`（真实字重），导入时按字体 `name` 表的家族名命名让它们落成同名。
/// 最后一组在真 Chromium 里验证这两条 CSS 真的改变了字面选择与合成行为。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/font_preview/font_file_metadata.dart';
import 'package:fushi/src/reader/dictionary_font_css.dart';
import 'package:fushi/src/reader/dictionary_language_css.dart';
import 'package:fushi/src/reader/font_download_service.dart';
import 'package:fushi/src/reader/reader_settings.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

const int _tagOs2 = 0x4F532F32;
const int _tagName = 0x6E616D65;
const int _tagFvar = 0x66766172;

/// UTF-16BE 编码（Windows name 记录）。
List<int> _utf16be(String s) => <int>[
  for (final int unit in s.codeUnits) ...<int>[unit >> 8, unit & 0xFF],
];

/// 最小 sfnt：OS/2（usWeightClass）+ name（nameID 1/16 的 Windows 英语记录）+ 可选 fvar。
Uint8List _sfnt({
  required int weight,
  String? family,
  String? typographicFamily,
  (int, int)? wghtAxis,
}) {
  final List<(int, Uint8List)> tables = <(int, Uint8List)>[];
  final ByteData os2 = ByteData(86)
    ..setUint16(0, 1)
    ..setUint16(4, weight);
  tables.add((_tagOs2, os2.buffer.asUint8List()));

  final List<(int, String)> records = <(int, String)>[
    if (family != null) (1, family),
    if (typographicFamily != null) (16, typographicFamily),
  ];
  if (records.isNotEmpty) {
    final List<List<int>> strings = <List<int>>[
      for (final (int _, String s) in records) _utf16be(s),
    ];
    final int headerSize = 6 + records.length * 12;
    final BytesBuilder name = BytesBuilder();
    final ByteData head = ByteData(headerSize)
      ..setUint16(0, 0)
      ..setUint16(2, records.length)
      ..setUint16(4, headerSize);
    int offset = 0;
    for (int i = 0; i < records.length; i++) {
      final int rec = 6 + i * 12;
      head
        ..setUint16(rec, 3) // Windows
        ..setUint16(rec + 2, 1) // Unicode BMP
        ..setUint16(rec + 4, 0x409) // en-US
        ..setUint16(rec + 6, records[i].$1)
        ..setUint16(rec + 8, strings[i].length)
        ..setUint16(rec + 10, offset);
      offset += strings[i].length;
    }
    name.add(head.buffer.asUint8List());
    for (final List<int> s in strings) {
      name.add(s);
    }
    tables.add((_tagName, name.toBytes()));
  }

  if (wghtAxis != null) {
    final ByteData fvar = ByteData(36)
      ..setUint16(4, 16)
      ..setUint16(8, 1)
      ..setUint16(10, 20)
      ..setUint32(16, 0x77676874)
      ..setInt32(20, wghtAxis.$1 << 16)
      ..setInt32(24, 400 << 16)
      ..setInt32(28, wghtAxis.$2 << 16);
    tables.add((_tagFvar, fvar.buffer.asUint8List()));
  }

  final int dirSize = 12 + tables.length * 16;
  final ByteData dir = ByteData(dirSize)
    ..setUint32(0, 0x00010000)
    ..setUint16(4, tables.length);
  int offset = dirSize;
  for (int i = 0; i < tables.length; i++) {
    dir
      ..setUint32(12 + i * 16, tables[i].$1)
      ..setUint32(12 + i * 16 + 8, offset)
      ..setUint32(12 + i * 16 + 12, tables[i].$2.length);
    offset += tables[i].$2.length;
  }
  final BytesBuilder out = BytesBuilder()..add(dir.buffer.asUint8List());
  for (final (int _, Uint8List data) in tables) {
    out.add(data);
  }
  return out.toBytes();
}

/// 把一个 sfnt 包成只含一个子字体的 TTC。
Uint8List _ttcOf(Uint8List face) {
  const int headerSize = 16;
  final ByteData header = ByteData(headerSize)
    ..setUint32(0, 0x74746366)
    ..setUint16(4, 1)
    ..setUint32(8, 1)
    ..setUint32(12, headerSize);
  // 子字体表目录里的表偏移是相对整个文件的，整体后移 headerSize。
  final Uint8List shifted = Uint8List.fromList(face);
  final ByteData view = ByteData.sublistView(shifted);
  final int numTables = view.getUint16(4);
  for (int i = 0; i < numTables; i++) {
    final int at = 12 + i * 16 + 8;
    view.setUint32(at, view.getUint32(at) + headerSize);
  }
  return (BytesBuilder()
        ..add(header.buffer.asUint8List())
        ..add(shifted))
      .toBytes();
}

/// 把真实字体文件的 `OS/2.usWeightClass` 改成 [weight]（模拟同家族的另一字重文件）。
Uint8List _withWeightClass(Uint8List font, int weight) {
  final Uint8List out = Uint8List.fromList(font);
  final ByteData view = ByteData.sublistView(out);
  final int numTables = view.getUint16(4);
  for (int i = 0; i < numTables; i++) {
    final int rec = 12 + i * 16;
    if (view.getUint32(rec) == _tagOs2) {
      view.setUint16(view.getUint32(rec + 8) + 4, weight);
      return out;
    }
  }
  throw StateError('no OS/2 table');
}

Map<String, dynamic> _e(String name, String path) => <String, dynamic>{
  'name': name,
  'path': path,
  'enabled': true,
};

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('font_weight_css_'));
  tearDown(() => dir.deleteSync(recursive: true));

  String write(String name, List<int> bytes) {
    final File f = File(p.join(dir.path, name))..writeAsBytesSync(bytes);
    return f.path;
  }

  group('readFontFaceWeightSync', () {
    test('静态字体取 usWeightClass，可变字体取 wght 轴', () {
      expect(readFontFaceWeightSync(write('r.ttf', _sfnt(weight: 400))), (
        min: 400,
        max: 400,
      ));
      expect(readFontFaceWeightSync(write('sb.ttf', _sfnt(weight: 600))), (
        min: 600,
        max: 600,
      ));
      expect(
        readFontFaceWeightSync(
          write('v.ttf', _sfnt(weight: 400, wghtAxis: (100, 900))),
        ),
        (min: 100, max: 900),
      );
    });

    test('TTC 取第 0 个子字体（@font-face 只加载它）', () {
      expect(
        readFontFaceWeightSync(write('c.ttc', _ttcOf(_sfnt(weight: 300)))),
        (min: 300, max: 300),
      );
    });

    test('读不出（非字体 / 不存在）返回 null', () {
      expect(readFontFaceWeightSync(write('x.ttf', <int>[0, 1, 2, 3])), isNull);
      expect(readFontFaceWeightSync(p.join(dir.path, 'missing.ttf')), isNull);
    });
  });

  group('readFontFamilyNameSync', () {
    test('Typographic Family（16）优先于 Family（1）', () {
      final String path = write(
        'KleeOne-SemiBold.ttf',
        _sfnt(
          weight: 600,
          family: 'Klee One SemiBold',
          typographicFamily: 'Klee One',
        ),
      );
      expect(readFontFamilyNameSync(path), 'Klee One');
    });

    test('没有 16 时取 1；没有 name 表返回 null', () {
      expect(
        readFontFamilyNameSync(
          write('a.ttf', _sfnt(weight: 400, family: 'Klee One')),
        ),
        'Klee One',
      );
      expect(
        readFontFamilyNameSync(write('b.ttf', _sfnt(weight: 400))),
        isNull,
      );
    });
  });

  group('DictionaryFontCss.build（查词弹窗）', () {
    test('单个常规字体：@font-face 声明真实字重 400', () {
      final String regular = write('r.ttf', _sfnt(weight: 400));
      final css = DictionaryFontCss.build(
        <Map<String, dynamic>>[_e('Klee One', regular)],
        allowedDirectories: <String>[dir.path],
        fontUrlBuilder: (String path) => 'https://x/${p.basename(path)}',
      );
      expect(css.fontFamily, '"Klee One"');
      expect(
        css.fontFaces,
        '@font-face { font-family: "Klee One"; src: url("https://x/r.ttf") '
        'format("truetype"); font-weight: 400; font-display: swap; }',
      );
      expect(css.faceSources.single.weight, '400');
    });

    test('同名两字重：两条 @font-face 各带真实字重，家族名只进链一次', () {
      final String regular = write('r.ttf', _sfnt(weight: 400));
      final String semiBold = write('sb.ttf', _sfnt(weight: 600));
      final css = DictionaryFontCss.build(
        <Map<String, dynamic>>[
          _e('Klee One', regular),
          _e('Klee One', semiBold),
        ],
        allowedDirectories: <String>[dir.path],
        fontUrlBuilder: (String path) => 'https://x/${p.basename(path)}',
      );
      expect(css.fontFamily, '"Klee One"');
      expect(css.families, <String>['Klee One']);
      final List<String> faces = css.fontFaces.split('\n');
      expect(faces, hasLength(2));
      expect(faces[0], contains('r.ttf'));
      expect(faces[0], contains('font-weight: 400;'));
      expect(faces[1], contains('sb.ttf'));
      expect(faces[1], contains('font-weight: 600;'));
      expect(
        css.faceSources.map((DictionaryFontFaceSource f) => f.weight).toList(),
        <String?>['400', '600'],
      );
    });

    test('可变字体声明轴范围；读不出字重时不写描述符（与改动前一致）', () {
      final String variable = write(
        'v.ttf',
        _sfnt(weight: 400, wghtAxis: (100, 900)),
      );
      final String unknown = write('u.ttf', <int>[0, 1, 0, 0, 9, 9, 9, 9]);
      final css = DictionaryFontCss.build(
        <Map<String, dynamic>>[_e('Var', variable), _e('Unknown', unknown)],
        allowedDirectories: <String>[dir.path],
        fontUrlBuilder: (String path) => 'https://x/${p.basename(path)}',
      );
      final List<String> faces = css.fontFaces.split('\n');
      expect(faces[0], contains('font-weight: 100 900;'));
      expect(faces[1], isNot(contains('font-weight')));
      expect(css.faceSources[1].weight, isNull);
    });
  });

  group('ReaderCustomFontCss.build（阅读器正文 / 歌词）', () {
    test('同名两字重：各自真实字重，家族名去重', () {
      final String regular = write('r.ttf', _sfnt(weight: 400));
      final String bold = write('b.ttf', _sfnt(weight: 700));
      final css = ReaderCustomFontCss.build(
        <Map<String, dynamic>>[_e('Klee One', regular), _e('Klee One', bold)],
        allowedDirectories: <String>[dir.path],
        fontUrlBuilder: (String path) => 'https://x/${p.basename(path)}',
      );
      expect(css.fontFamily, '"Klee One"');
      final List<String> faces = css.fontFaces.split('\n');
      expect(faces, hasLength(2));
      expect(faces[0], contains('font-weight: 400;'));
      expect(faces[1], contains('font-weight: 700;'));
    });
  });

  group('dictionaryLanguageFontCss 的字重合成开关', () {
    test('有导入字体：根上关掉字重合成（含 iOS 15 认的简写）', () {
      final String css = dictionaryLanguageFontCss(
        customFamilies: <String>['Klee One'],
        dictionaries: const <DictionaryLanguageEntry>[],
        platform: TargetPlatform.windows,
        suppressWeightSynthesis: true,
      );
      expect(
        css,
        contains(
          'html, body { font-synthesis: style; font-synthesis-weight: none; }',
        ),
      );
    });

    test('扩展弹窗的根选择器同样带上', () {
      final String css = dictionaryLanguageFontCss(
        customFamilies: <String>['Klee One'],
        dictionaries: const <DictionaryLanguageEntry>[],
        platform: TargetPlatform.windows,
        rootSelector: '#entries-container',
        suppressWeightSynthesis: true,
      );
      expect(css, contains('#entries-container { font-synthesis: style;'));
    });

    test('没有导入字体：不碰合成（系统字体照旧）', () {
      final String css = dictionaryLanguageFontCss(
        customFamilies: <String>['Yu Gothic'],
        dictionaries: const <DictionaryLanguageEntry>[],
        platform: TargetPlatform.windows,
      );
      expect(css, isNot(contains('font-synthesis')));
    });
  });

  group('导入命名：按字体 name 表的家族名', () {
    test('KleeOne-SemiBold.ttf 落成 "Klee One"，与 Regular 同名', () async {
      final FontDownloadService service = FontDownloadService(
        fontsDir: Directory(p.join(dir.path, 'custom_fonts')),
        dioFactory: () => Dio(),
      );
      final File src = File(p.join(dir.path, 'KleeOne-SemiBold.ttf'))
        ..writeAsBytesSync(
          _sfnt(
            weight: 600,
            family: 'Klee One SemiBold',
            typographicFamily: 'Klee One',
          ),
        );
      final List<ImportedFontFile> files = await service.importFile(
        src,
        fileName: 'KleeOne-SemiBold.ttf',
      );
      expect(files.single.name, 'Klee One');
      expect(File(files.single.path).existsSync(), isTrue);
      expect(p.basename(files.single.path), startsWith('Klee One_'));
    });

    test('读不出家族名时退回文件名（旧行为）', () async {
      final FontDownloadService service = FontDownloadService(
        fontsDir: Directory(p.join(dir.path, 'custom_fonts')),
        dioFactory: () => Dio(),
      );
      final File src = File(p.join(dir.path, 'Mystery.ttf'))
        ..writeAsBytesSync(<int>[
          0x00,
          0x01,
          0x00,
          0x00,
          ...List<int>.filled(16, 0x41),
        ]);
      final List<ImportedFontFile> files = await service.importFile(
        src,
        fileName: 'Mystery.ttf',
      );
      expect(files.single.name, 'Mystery');
    });
  });

  group('真 Chromium：字面选择与合成加粗', () {
    final String? chrome =
        <String?>[
              Platform.environment['CHROME_EXECUTABLE'],
              r'C:\Program Files\Google\Chrome\Application\chrome.exe',
              r'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
              '/usr/bin/google-chrome',
              '/usr/bin/chromium',
              '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
            ]
            .whereType<String>()
            .where((String path) => File(path).existsSync())
            .firstOrNull;
    // 仓库里现成的静态 Regular 字体（usWeightClass 400，只有一个字面）。
    final File realFont = File(
      '../third_party/m_extension_server/upstream_src/AndroidCompat/src/main/'
      'resources/font/NotoSans/NotoSansSymbols2-Regular.ttf',
    );
    final String? skip = chrome == null
        ? 'Chromium required; set CHROME_EXECUTABLE'
        : !realFont.existsSync()
        ? 'fixture font missing'
        : null;

    /// 在真 Chromium 里布局 [styleCss] 之下的探针，回读 JSON 报告。
    Future<Map<String, dynamic>> render(String styleCss) async {
      // 上下两条带：上面常规字重、下面 700。合成加粗在 Chromium 里**不改步进宽度**，
      // 只把轮廓描粗，所以判据是真实像素的「墨量」（深色像素数），不是 DOM 宽度。
      const String glyphs = '☐☐☐☐☐☐☐☐☐☐☐☐☐☐☐☐☐☐☐☐';
      final File html = File(p.join(dir.path, 'probe.html'))
        ..writeAsStringSync('''<!doctype html><meta charset="utf-8">
<style>
$styleCss
html, body { margin: 0; background: #fff; color: #000; }
div { position: absolute; left: 0; height: 100px; font-size: 48px;
      line-height: 100px; white-space: nowrap; }
pre { position: absolute; top: 300px; }
</style>
<body>
<div id="regular" style="top:0; font-weight:400"></div>
<div id="bold" style="top:100px; font-weight:700"></div>
<pre id="results"></pre>
<script>
// 字形只在两个字重都加载完之后才写进去：font-display: swap 下先画的是回退字体，
// 截图若赶在加载前，测到的就是回退字体而不是被测字体（那时墨量为 0，断言会抓住）。
const text = '$glyphs';
Promise.all([
  document.fonts.load('400 48px "Probe Family"', text),
  document.fonts.load('700 48px "Probe Family"', text),
]).then(() => {
  document.getElementById('regular').textContent = text;
  document.getElementById('bold').textContent = text;
  return document.fonts.ready;
}).then(() => {
  const faces = [];
  document.fonts.forEach((f) => faces.push({weight: f.weight, status: f.status}));
  document.getElementById('results').textContent = btoa(JSON.stringify({faces}));
});
</script>
</body>''');
      List<String> args(String mode) => <String>[
        '--headless',
        '--no-sandbox',
        '--disable-gpu',
        '--no-first-run',
        '--disable-background-networking',
        '--hide-scrollbars',
        '--force-device-scale-factor=1',
        '--window-size=1200,200',
        '--virtual-time-budget=5000',
        mode,
        '--user-data-dir=${dir.path}/profile',
        html.uri.toString(),
      ];
      // 比外层的 90s 短：Chrome 真卡住时先由这里抛，错误里带得上 stderr。
      final ProcessResult dom = await Process.run(
        chrome!,
        args('--dump-dom'),
      ).timeout(const Duration(seconds: 40));
      expect(dom.exitCode, 0, reason: '${dom.stderr}');
      final RegExpMatch? payload = RegExp(
        r'<pre id="results">([^<]+)</pre>',
      ).firstMatch(dom.stdout as String);
      expect(payload, isNotNull, reason: '${dom.stdout}\n${dom.stderr}');
      final Map<String, dynamic> report =
          jsonDecode(utf8.decode(base64Decode(payload!.group(1)!)))
              as Map<String, dynamic>;

      final String shot = p.join(dir.path, 'probe.png');
      final ProcessResult capture = await Process.run(
        chrome,
        args('--screenshot=$shot'),
      ).timeout(const Duration(seconds: 40));
      expect(File(shot).existsSync(), isTrue, reason: '${capture.stderr}');
      final img.Image image = img.decodePng(File(shot).readAsBytesSync())!;
      int ink(int top) {
        int count = 0;
        for (int y = top; y < top + 100 && y < image.height; y++) {
          for (int x = 0; x < image.width; x++) {
            if (image.getPixel(x, y).luminanceNormalized < 0.5) count++;
          }
        }
        return count;
      }

      return <String, dynamic>{...report, 'regular': ink(0), 'bold': ink(100)};
    }

    /// 生产路径：DictionaryFontCss.build（内联 data: URL）+ 弹窗的语言链 CSS。
    String popupCss(
      List<Map<String, dynamic>> fonts, {
      required bool suppress,
    }) {
      final css = DictionaryFontCss.build(
        fonts,
        allowedDirectories: <String>[dir.path],
      );
      final String languageCss = dictionaryLanguageFontCss(
        customFamilies: css.families,
        dictionaries: const <DictionaryLanguageEntry>[],
        platform: TargetPlatform.windows,
        suppressWeightSynthesis: suppress,
      );
      return '${css.fontFaces}\n$languageCss';
    }

    test(
      '只有 Regular：关掉合成后粗体与常规墨量相同；对照组（不关）确实合成加粗',
      () async {
        final String regular = write('reg.ttf', realFont.readAsBytesSync());
        final List<Map<String, dynamic>> fonts = <Map<String, dynamic>>[
          _e('Probe Family', regular),
        ];

        final Map<String, dynamic> control = await render(
          popupCss(fonts, suppress: false),
        );
        // 对照组证明探针不是空壳：不关合成时 700 被合成加粗，墨量明显变多。
        expect(
          control['bold'] as int,
          greaterThan((control['regular'] as int) * 1.15),
          reason: '$control',
        );

        final Map<String, dynamic> fixed = await render(
          popupCss(fonts, suppress: true),
        );
        expect(fixed['regular'] as int, greaterThan(0), reason: '$fixed');
        expect(fixed['bold'], fixed['regular'], reason: '$fixed');
      },
      skip: skip ?? false,
      timeout: const Timeout(Duration(seconds: 90)),
    );

    test(
      '同名 Regular + SemiBold：粗体选中 600 字面，即使不关合成也不再合成',
      () async {
        final Uint8List bytes = realFont.readAsBytesSync();
        final String regular = write('reg.ttf', bytes);
        final String semiBold = write('sb.ttf', _withWeightClass(bytes, 600));
        // 故意不关合成：单凭 @font-face 的真实字重，700 的请求就该落到 600 字面
        // （≥ 600 不触发合成），与第 1 条修法互相独立地成立。
        final Map<String, dynamic> report = await render(
          popupCss(<Map<String, dynamic>>[
            _e('Probe Family', regular),
            _e('Probe Family', semiBold),
          ], suppress: false),
        );
        final List<dynamic> faces = report['faces'] as List<dynamic>;
        expect(
          faces.map((dynamic f) => (f as Map<String, dynamic>)['weight']),
          containsAll(<String>['400', '600']),
          reason: '$report',
        );
        // 两个字面都被实际加载（常规带 + 粗体带），说明 700 的请求落到了 600 字面；
        // 两份文件轮廓相同、600 字面不触发合成 → 墨量相同。
        for (final dynamic f in faces) {
          expect(
            (f as Map<String, dynamic>)['status'],
            'loaded',
            reason: '$report',
          );
        }
        expect(report['bold'], report['regular'], reason: '$report');
      },
      skip: skip ?? false,
      timeout: const Timeout(Duration(seconds: 90)),
    );
  });
}
