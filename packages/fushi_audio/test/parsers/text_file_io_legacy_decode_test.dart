// BUG-4798：桌面三端与无头服务端读 CP932 / GBK / Big5 / EUC-JP 文本整份变成 U+FFFD。
//
// 这里是纯 Dart（`package:test`，没有 Flutter binding、没有任何平台插件），与无头服务端
// 的运行环境同构：`platformCharsetDecoder` 不装配，非 Unicode 字节只能靠
// [decodeLegacyText]（Rust 计算内核）。判据本身的用例钉在
// native/fushi_compute/src/legacy_text.rs；这里钉 `decodeTextBytes` 的分级接线与
// 「字节 → 解码 → 解析出 cue」整条链。
//
// 夹具在 test/fixtures/legacy_text/（generate.py 生成，Python codec 编码，与被测的
// encoding_rs 是两套独立实现）。原生库是硬依赖：找不到库直接失败，不 skip。
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_audio/fushi_audio.dart';
import 'package:test/test.dart';

const String _fixtureDir = 'test/fixtures/legacy_text';

Uint8List _fixture(String name) => File('$_fixtureDir/$name').readAsBytesSync();

String _expected(String name) =>
    utf8.decode(File('$_fixtureDir/$name.expected.txt').readAsBytesSync());

/// Windows-1252 的英文 SRT 原文：每句都有弯撇号 `’`（0x92），末尾一条 `“Wait…”`（0x85 0x94
/// 相邻）。0x92 与后一个字母恰好是 Shift_JIS / GBK 的一个合法双字节字，只看「解码零错误」
/// 会整份判成 Shift_JIS（`I don稚 know what you池e talking about.`）。
String _cp1252EnglishText() {
  const List<String> lines = <String>[
    'I don\u2019t know what you\u2019re talking about.',
    'It\u2019s fine, we\u2019ll manage.',
    'She\u2019s gone, isn\u2019t she?',
    'They\u2019ve left already.',
    'I\u2019m sure he\u2019d agree.',
  ];
  final StringBuffer doc = StringBuffer();
  int n = 0;
  void cue(String line) {
    n += 1;
    final String at =
        '00:${(n ~/ 60).toString().padLeft(2, '0')}:'
        '${(n % 60).toString().padLeft(2, '0')}';
    doc.write('$n\r\n$at,000 --> $at,500\r\n$line\r\n\r\n');
  }

  for (int k = 0; k < 20; k++) {
    lines.forEach(cue);
  }
  cue('\u201CWait\u2026\u201D');
  return doc.toString();
}

/// [_cp1252EnglishText] 的 Windows-1252 字节。
Uint8List _cp1252EnglishSrt() {
  const Map<int, int> cp1252 = <int, int>{
    0x2019: 0x92,
    0x201C: 0x93,
    0x201D: 0x94,
    0x2026: 0x85,
  };
  return Uint8List.fromList(<int>[
    for (final int rune in _cp1252EnglishText().runes) cp1252[rune] ?? rune,
  ]);
}

void main() {
  setUp(() {
    // 服务端 / 纯 Dart 环境：没有平台插件。
    expect(platformCharsetDecoder, isNull);
  });

  group('decodeTextBytes：本地多字节编码整份解回原文', () {
    for (final String name in <String>[
      'ja_cp932.ass',
      'ja_eucjp.srt',
      'zh_gbk.srt',
      'zh_big5.srt',
      'ko_euckr.srt',
    ]) {
      test(name, () async {
        final Uint8List bytes = _fixture(name);
        // 夹具确实不是 Unicode 家族：第 1 级认不出来。
        expect(decodeUnicodeText(bytes), isNull);
        final String text = await decodeTextBytes(bytes);
        expect(text, _expected(name));
        expect(text.contains('\u{FFFD}'), isFalse);
      });
    }

    test('大文件走后台 isolate、小文件就地解，结果一致', () async {
      final Uint8List large = _fixture('ja_cp932.ass');
      final Uint8List small = _fixture('zh_gbk.srt');
      expect(large.length, greaterThan(kLegacyDecodeInlineMaxBytes));
      expect(small.length, lessThanOrEqualTo(kLegacyDecodeInlineMaxBytes));
      expect(await decodeLegacyText(large), _expected('ja_cp932.ass'));
      expect(await decodeLegacyText(small), _expected('zh_gbk.srt'));
    });

    test('文件中间混进一个坏字节：仍按原编码解，只坏那一处', () async {
      final Uint8List clean = _fixture('ja_cp932.ass');
      // 插在一行的换行符之前，不拆开任何双字节字符。
      final int at = clean.indexOf(0x0A, clean.length ~/ 2);
      final Uint8List damaged = Uint8List.fromList(<int>[
        ...clean.sublist(0, at),
        0xFF,
        ...clean.sublist(at),
      ]);
      final String text = await decodeTextBytes(damaged);
      expect('\u{FFFD}'.allMatches(text).length, 1);
      expect(text.replaceAll('\u{FFFD}', ''), _expected('ja_cp932.ass'));
    });
  });

  group('decodeTextBytes：不该被当成本地编码的输入', () {
    test('坏了一个字节的 UTF-8 不被重解成乱码，只坏那一处', () async {
      final String original = _expected('ja_cp932.ass');
      final Uint8List utf8Bytes = utf8.encode(original);
      final int firstHigh = utf8Bytes.indexWhere((int b) => b >= 0x80);
      // 去掉一个多字节序列的首字节。
      final Uint8List damaged = Uint8List.fromList(<int>[
        ...utf8Bytes.sublist(0, firstHigh),
        ...utf8Bytes.sublist(firstHigh + 1),
      ]);
      expect(decodeUnicodeText(damaged), isNull);
      expect(await decodeLegacyText(damaged), isNull);
      final String text = await decodeTextBytes(damaged);
      expect(text, utf8.decode(damaged, allowMalformed: true));
      // 「おはよう」掉了首字节的「お」，其余原样。
      expect(text, contains('はよう、今日はいい天気ですね。'));
    });

    test('任何候选都解不开的字节降级到宽松 UTF-8，绝不抛异常', () async {
      final Uint8List garbage = Uint8List.fromList(<int>[
        ...ascii.encode('Dialogue: '),
        0xFF, 0xFF, 0xFF, //
        0x0A,
      ]);
      expect(await decodeLegacyText(garbage), isNull);
      final String text = await decodeTextBytes(garbage);
      expect(text.startsWith('Dialogue: '), isTrue);
      expect(text.contains('\u{FFFD}'), isTrue);
    });

    test(
      'Windows-1252 的英文字幕按 Windows-1252 解回原文，不被解成 Shift_JIS / GBK',
      () async {
        final Uint8List bytes = _cp1252EnglishSrt();
        expect(decodeUnicodeText(bytes), isNull);
        final String text = await decodeTextBytes(bytes);
        // 从前判不出、降级成宽松 UTF-8，每个弯撇号都变 U+FFFD。
        expect(text, _cp1252EnglishText());
        expect(
          text,
          contains('I don\u2019t know what you\u2019re talking about.'),
        );
        // 一个汉字 / 假名都不该冒出来。
        expect(
          RegExp(r'[\u3040-\u30FF\u3400-\u9FFF\uFF61-\uFF9F]').hasMatch(text),
          isFalse,
        );
      },
    );

    test('UTF-8 BOM + CP932 正文：BOM 不混进首行', () async {
      for (final String name in <String>['ja_cp932.ass', 'ja_eucjp.srt']) {
        final Uint8List bytes = Uint8List.fromList(<int>[
          0xEF, 0xBB, 0xBF, //
          ..._fixture(name),
        ]);
        expect(decodeUnicodeText(bytes), isNull);
        expect(await decodeTextBytes(bytes), _expected(name));
      }
    });

    test('全 ASCII / 空输入不进本地编码这一级', () async {
      expect(await decodeLegacyText(Uint8List(0)), isNull);
      expect(await decodeLegacyText(ascii.encode('WEBVTT\n\nhi\n')), isNull);
      expect(await decodeTextBytes(Uint8List(0)), '');
    });
  });

  group('端到端：本地编码字幕文件解析出 cue', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('fushi_legacy_text_');
    });

    tearDown(() async {
      if (dir.existsSync()) {
        await dir.delete(recursive: true);
      }
    });

    Future<File> copyFixture(String name) =>
        File('$_fixtureDir/$name').copy('${dir.path}/$name');

    test('CP932 的 ASS', () async {
      final List<AudioCue> cues = await AssParser.parse(
        assFile: await copyFixture('ja_cp932.ass'),
        bookKey: 'bug4798',
      );
      expect(cues.length, 240);
      expect(cues[0].startMs, 0);
      expect(cues[0].endMs, 2500);
      expect(cues[0].text, 'おはよう、今日はいい天気ですね。');
      expect(cues[3].text, 'ｱﾘｶﾞﾄｳ、助かった。');
      expect(cues[5].text, '第１２話　表示能力のテスト①');
    });

    test('EUC-JP 的 SRT', () async {
      final List<AudioCue> cues = await SrtParser.parse(
        srtFile: await copyFixture('ja_eucjp.srt'),
        bookKey: 'bug4798',
      );
      expect(cues.length, 24);
      expect(cues[0].text, 'おはよう、今日はいい天気ですね。');
      expect(cues[1].startMs, 3000);
      expect(cues[1].endMs, 5500);
    });

    test('GBK 的 SRT', () async {
      final List<AudioCue> cues = await SrtParser.parse(
        srtFile: await copyFixture('zh_gbk.srt'),
        bookKey: 'bug4798',
      );
      expect(cues.length, 24);
      expect(cues[0].text, '早上好，今天天气真不错。');
      expect(cues[4].text, '乔治·华盛顿与托马斯·杰斐逊');
    });

    test('Big5 的 SRT', () async {
      final List<AudioCue> cues = await SrtParser.parse(
        srtFile: await copyFixture('zh_big5.srt'),
        bookKey: 'bug4798',
      );
      expect(cues.length, 24);
      expect(cues[0].text, '早安，今天天氣真不錯。');
      expect(cues[4].text, '喬治·華盛頓與湯瑪斯·傑佛遜');
    });

    test('EUC-KR 的 SRT（从前被解成汉字）', () async {
      final List<AudioCue> cues = await SrtParser.parse(
        srtFile: await copyFixture('ko_euckr.srt'),
        bookKey: 'bug4798',
      );
      expect(cues.length, 24);
      expect(cues[0].text, '안녕하세요, 오늘은 날씨가 정말 좋네요.');
      expect(cues[3].text, '「약속이야」 그녀는 그렇게 말하며 웃었다.');
    });
  });
}
