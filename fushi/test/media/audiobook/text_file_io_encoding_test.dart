import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/platform_charset_detector.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_engine/media/video/subtitle/subtitle_content_language.dart';

/// BUG-1490：桌面端非 UTF-8 字幕全被误报为「不支持」。
///
/// 根因链（四环）：
/// 1. 用户的 `.tc.ass` 是 **UTF-16LE with BOM**（`FF FE` + ASCII 后跟 `00`）；
/// 2. `readTextWithEncoding` 先做 `utf8.decode` 严格解码 → `FormatException`；
/// 3. 退路 `CharsetDetector.autoDecode` 是 method channel，而
///    `flutter_charset_detector` 1.0.2 **只有 android / ios 联邦实现**，
///    Windows / macOS / Linux 必抛 `MissingPluginException`；
/// 4. `_loadExternalCues` 的 `catch (_) { return const <AudioCue>[] }` 把它
///    压成空 cue 列表 → UI 报「无法加载该字幕（可能是图形或不支持的字幕轨）」。
///
/// 本测试跑在 `flutter test` 宿主里，**没有任何插件实现**，与桌面端运行时同构：
/// 只要这里能解出正确文本，桌面端就能。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('detectEncodingFromBom（纯函数）', () {
    test('UTF-8 BOM', () {
      expect(
        detectEncodingFromBom(<int>[0xEF, 0xBB, 0xBF, 0x41]),
        UnicodeTextEncoding.utf8Bom,
      );
    });

    test('UTF-16LE BOM', () {
      expect(
        detectEncodingFromBom(<int>[0xFF, 0xFE, 0x41, 0x00]),
        UnicodeTextEncoding.utf16leBom,
      );
    });

    test('UTF-16BE BOM', () {
      expect(
        detectEncodingFromBom(<int>[0xFE, 0xFF, 0x00, 0x41]),
        UnicodeTextEncoding.utf16beBom,
      );
    });

    test('UTF-32LE 的 BOM 前缀与 UTF-16LE 相同，必须判成 UTF-32LE', () {
      // `FF FE 00 00` 是 UTF-32LE BOM；若先判 UTF-16LE，会把整段 UTF-32
      // 解成一串交替 NUL。这是 BOM 判定里唯一真正的歧义点。
      expect(
        detectEncodingFromBom(<int>[0xFF, 0xFE, 0x00, 0x00, 0x41, 0, 0, 0]),
        UnicodeTextEncoding.utf32leBom,
      );
    });

    test('UTF-32BE BOM', () {
      expect(
        detectEncodingFromBom(<int>[0x00, 0x00, 0xFE, 0xFF, 0, 0, 0, 0x41]),
        UnicodeTextEncoding.utf32beBom,
      );
    });

    test('无 BOM 返回 null', () {
      expect(detectEncodingFromBom(utf8.encode('[Script Info]')), isNull);
      expect(detectEncodingFromBom(<int>[]), isNull);
      expect(detectEncodingFromBom(<int>[0xFF]), isNull);
    });
  });

  group('detectBomlessUtf16（纯函数启发式）', () {
    test('无 BOM 的 UTF-16LE ASCII 主导文本判为 LE', () {
      expect(
        detectBomlessUtf16(_encodeUtf16(_minimalAss, littleEndian: true)),
        UnicodeTextEncoding.utf16leBomless,
      );
    });

    test('无 BOM 的 UTF-16BE 判为 BE', () {
      expect(
        detectBomlessUtf16(_encodeUtf16(_minimalAss, littleEndian: false)),
        UnicodeTextEncoding.utf16beBomless,
      );
    });

    test('普通 UTF-8 文本不误判', () {
      expect(detectBomlessUtf16(utf8.encode(_minimalAss)), isNull);
    });

    test('纯 ASCII UTF-8 不误判（无 0x00 字节）', () {
      expect(
        detectBomlessUtf16(
          utf8.encode('1\n00:00:01,000 --> 00:00:02,000\nhi\n'),
        ),
        isNull,
      );
    });

    test('奇数长度不可能是完整 UTF-16 流', () {
      final Uint8List even = _encodeUtf16(_minimalAss, littleEndian: true);
      final Uint8List odd = Uint8List.fromList(<int>[...even, 0x41]);
      expect(detectBomlessUtf16(odd), isNull);
    });

    test('太短的输入不做判定', () {
      expect(detectBomlessUtf16(<int>[0x41, 0x00]), isNull);
    });

    test('两侧都大量 0x00 的二进制垃圾不判为 UTF-16', () {
      expect(detectBomlessUtf16(Uint8List(64)), isNull);
    });
  });

  group('decodeUnicodeText（纯函数，零平台依赖）', () {
    test('UTF-8 无 BOM 原样解出', () {
      expect(decodeUnicodeText(utf8.encode(_minimalAss)), _minimalAss);
    });

    test('UTF-8 有 BOM：解出内容且 BOM 被剥掉', () {
      final Uint8List bytes = Uint8List.fromList(<int>[
        0xEF,
        0xBB,
        0xBF,
        ...utf8.encode(_minimalAss),
      ]);
      final String? text = decodeUnicodeText(bytes);
      expect(text, _minimalAss);
      expect(text!.startsWith(kBomChar), isFalse);
    });

    test('UTF-16LE 有 BOM（用户样本的形态）', () {
      final String? text = decodeUnicodeText(
        _encodeUtf16(_minimalAss, littleEndian: true, withBom: true),
      );
      expect(text, _minimalAss);
      expect(text!.startsWith(kBomChar), isFalse);
    });

    test('UTF-16BE 有 BOM', () {
      expect(
        decodeUnicodeText(
          _encodeUtf16(_minimalAss, littleEndian: false, withBom: true),
        ),
        _minimalAss,
      );
    });

    test('UTF-16LE 无 BOM', () {
      expect(
        decodeUnicodeText(_encodeUtf16(_minimalAss, littleEndian: true)),
        _minimalAss,
      );
    });

    test('UTF-32LE 有 BOM 不被当成 UTF-16LE', () {
      expect(
        decodeUnicodeText(_encodeUtf32(_minimalAss, littleEndian: true)),
        _minimalAss,
      );
    });

    test('UTF-32BE 有 BOM', () {
      expect(
        decodeUnicodeText(_encodeUtf32(_minimalAss, littleEndian: false)),
        _minimalAss,
      );
    });

    test('代理对（emoji / 增补平面）经 UTF-16 往返不丢', () {
      const String withEmoji = 'Dialogue text 𩸽 🍣 end';
      expect(
        decodeUnicodeText(
          _encodeUtf16(withEmoji, littleEndian: true, withBom: true),
        ),
        withEmoji,
      );
      expect(
        decodeUnicodeText(_encodeUtf16(withEmoji, littleEndian: false)),
        withEmoji,
      );
    });

    test('非 Unicode 家族（Shift-JIS 字节）返回 null，交给上层字符集检测', () {
      // 「日本語」的 CP932 编码：日 93 FA / 本 96 7B / 語 8C EA。
      final Uint8List sjis = Uint8List.fromList(<int>[
        0x93,
        0xFA,
        0x96,
        0x7B,
        0x8C,
        0xEA,
      ]);
      expect(decodeUnicodeText(sjis), isNull);
    });
  });

  group('readTextWithEncoding（真文件，桌面端无插件环境）', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('fushi_textio_');
    });

    tearDown(() async {
      if (dir.existsSync()) {
        await dir.delete(recursive: true);
      }
    });

    Future<String> readBytes(Uint8List bytes, String name) async {
      final File f = File('${dir.path}${Platform.pathSeparator}$name');
      await f.writeAsBytes(bytes, flush: true);
      return readTextWithEncoding(f);
    }

    test('UTF-8 无 BOM', () async {
      expect(await readBytes(utf8.encode(_minimalAss), 'a.ass'), _minimalAss);
    });

    test('UTF-8 有 BOM', () async {
      expect(
        await readBytes(
          Uint8List.fromList(<int>[
            0xEF,
            0xBB,
            0xBF,
            ...utf8.encode(_minimalAss),
          ]),
          'b.ass',
        ),
        _minimalAss,
      );
    });

    test('UTF-16LE 有 BOM —— 用户报的那种文件', () async {
      expect(
        await readBytes(
          _encodeUtf16(_minimalAss, littleEndian: true, withBom: true),
          'c.ass',
        ),
        _minimalAss,
      );
    });

    test('UTF-16BE 有 BOM', () async {
      expect(
        await readBytes(
          _encodeUtf16(_minimalAss, littleEndian: false, withBom: true),
          'd.ass',
        ),
        _minimalAss,
      );
    });

    test('UTF-16LE 无 BOM', () async {
      expect(
        await readBytes(_encodeUtf16(_minimalAss, littleEndian: true), 'e.ass'),
        _minimalAss,
      );
    });

    test('UTF-32LE 有 BOM', () async {
      expect(
        await readBytes(_encodeUtf32(_minimalAss, littleEndian: true), 'f.ass'),
        _minimalAss,
      );
    });

    test('非法字节降级到宽松 UTF-8，绝不抛异常', () async {
      // 既不是 Unicode 家族、也不是任何本地多字节编码的字节：旧实现在桌面端抛
      // MissingPluginException，整条字幕链失败。现在必须返回一个（有损的）字符串。
      final Uint8List garbage = Uint8List.fromList(<int>[
        ...utf8.encode('Dialogue: '),
        0xFF, 0xFF, 0xFF, //
        0x0A,
      ]);
      final String text = await readBytes(garbage, 'g.ass');
      expect(
        text.startsWith('Dialogue: '),
        isTrue,
        reason: 'ASCII 部分必须完好，不能整体失败',
      );
      expect(text.contains('\u{FFFD}'), isTrue, reason: '无法解码的字节替换为 U+FFFD');
    });

    test('空文件不抛', () async {
      expect(await readBytes(Uint8List(0), 'h.ass'), '');
    });
  });

  // BUG-4798：桌面三端读 CP932 / GBK / Big5 / EUC-JP 字幕整份变成 U+FFFD。
  //
  // 与 app 在桌面端的装配同构：`installPlatformCharsetDetector()` 在测试宿主（同
  // 桌面三端）上不装插件（它没有桌面实现）→ 落到 Rust 计算内核的
  // `decodeLegacyText`。夹具与纯 Dart（无头服务端同构）一侧的用例在
  // packages/fushi_audio/test/（`text_file_io_legacy_decode_test.dart`）。
  group('readTextWithEncoding（本地多字节编码，桌面端装配）', () {
    const String fixtureDir =
        '../packages/fushi_audio/test/fixtures/legacy_text';

    setUp(installPlatformCharsetDetector);

    tearDown(() {
      platformCharsetDecoder = null;
    });

    test('桌面端不装配插件（插件只有 android / ios 实现）', () {
      expect(Platform.isAndroid || Platform.isIOS, isFalse);
      expect(platformCharsetDecoder, isNull);
    });

    for (final String name in <String>[
      'ja_cp932.ass',
      'ja_eucjp.srt',
      'zh_gbk.srt',
      'zh_big5.srt',
    ]) {
      test('$name 解回原文', () async {
        final String expected = utf8.decode(
          File('$fixtureDir/$name.expected.txt').readAsBytesSync(),
        );
        expect(await readTextWithEncoding(File('$fixtureDir/$name')), expected);
      });
    }

    test('CP932 的 ASS 解析出日文 cue', () async {
      final List<AudioCue> cues = await AssParser.parse(
        assFile: File('$fixtureDir/ja_cp932.ass'),
        bookKey: 'bug4798',
      );
      expect(cues.length, 240);
      expect(cues[0].text, 'おはよう、今日はいい天気ですね。');
    });

    test('Windows-1252 的英文字幕按 Windows-1252 解回原文，正文语言仍判英文', () async {
      // 弯撇号 `’`（0x92）与后一个字母恰好是 Shift_JIS / GBK 的一个合法双字节字；
      // 末尾一条 `“Wait…”`（0x85 0x94 相邻）让「像 Latin-1」的短标签判据整份判否。
      // 解成汉字的话 BUG-3069 的字幕语言守卫会把这份英文字幕当成中文。
      const Map<int, int> cp1252 = <int, int>{
        0x2019: 0x92,
        0x201C: 0x93,
        0x201D: 0x94,
        0x2026: 0x85,
      };
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
        cue('I don\u2019t know what you\u2019re talking about.');
        cue('It\u2019s fine, we\u2019ll manage.');
        cue('She\u2019s gone, isn\u2019t she?');
        cue('They\u2019ve left already.');
        cue('I\u2019m sure he\u2019d agree.');
      }
      cue('\u201CWait\u2026\u201D');
      final Uint8List bytes = Uint8List.fromList(<int>[
        for (final int rune in doc.toString().runes) cp1252[rune] ?? rune,
      ]);

      final String text = await decodeTextBytes(bytes);
      // 从前判不出、降级成宽松 UTF-8，弯撇号处处是 U+FFFD。
      expect(text, doc.toString());
      expect(
        detectSubtitleContentLanguage(text),
        SubtitleContentLanguage.english,
      );
    });

    test('短片段（证据不足）不猜编码，照旧降级到宽松 UTF-8', () async {
      // CP932 「日本語」只有三个汉字：这点字节按 GBK / Big5 读也说得通。
      final Uint8List sjis = Uint8List.fromList(<int>[
        ...utf8.encode('Dialogue: '),
        0x93, 0xFA, 0x96, 0x7B, 0x8C, 0xEA, //
        0x0A,
      ]);
      final String text = await decodeTextBytes(sjis);
      expect(text.startsWith('Dialogue: '), isTrue);
      expect(text.contains('\u{FFFD}'), isTrue);
    });
  });

  group('端到端：UTF-16 字幕必须解析出 cue（原始失败路径）', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('fushi_textio_e2e_');
    });

    tearDown(() async {
      if (dir.existsSync()) {
        await dir.delete(recursive: true);
      }
    });

    Future<List<AudioCue>> parseAss(Uint8List bytes, String name) async {
      final File f = File('${dir.path}${Platform.pathSeparator}$name');
      await f.writeAsBytes(bytes, flush: true);
      return AssParser.parse(assFile: f, bookKey: 'bug1490');
    }

    test('UTF-16LE + BOM 的 ASS 解析出 2 条 cue', () async {
      final List<AudioCue> cues = await parseAss(
        _encodeUtf16(_minimalAss, littleEndian: true, withBom: true),
        'sample.tc.ass',
      );
      expect(cues.length, 2);
      expect(cues[0].startMs, 1000);
      expect(cues[0].endMs, 4230);
      expect(cues[0].text, '吾輩は猫である。');
      expect(cues[1].text, '名前はまだない。');
    });

    test('UTF-16BE 无 BOM 的 ASS 同样解析出 cue', () async {
      final List<AudioCue> cues = await parseAss(
        _encodeUtf16(_minimalAss, littleEndian: false),
        'sample_be.ass',
      );
      expect(cues.length, 2);
      expect(cues[0].text, '吾輩は猫である。');
    });

    test('UTF-8 + BOM 的 JSON 对齐文件可解析（jsonDecode 不吃 BOM）', () async {
      // 记事本 / PowerShell 5.1 写出的「UTF-8」就带 BOM。上游不剥 BOM 时
      // `jsonDecode` 直接抛 FormatException，且 JsonAlignmentParser 不 catch。
      const String json =
          '{"cues":[{"chapter":"c","i":0,"selector":"s",'
          '"start":10,"end":20,"file":0,"text":"あ"}]}';
      final File f = File('${dir.path}${Platform.pathSeparator}align.json');
      await f.writeAsBytes(
        Uint8List.fromList(<int>[0xEF, 0xBB, 0xBF, ...utf8.encode(json)]),
        flush: true,
      );
      final List<AudioCue> cues = await JsonAlignmentParser.parse(
        jsonFile: f,
        bookKey: 'bug1490',
      );
      expect(cues.length, 1);
      expect(cues[0].text, 'あ');
    });
  });
}

/// 最小 ASS 夹具：保留 `[Script Info]` / `[Events]` / `Format:` 三个结构要素
/// 和两条 Dialogue，足以走通 [AssParser] 的列定位逻辑。**不入库用户的 52KB 原件**。
const String _minimalAss =
    '[Script Info]\r\n'
    'ScriptType: v4.00+\r\n'
    '\r\n'
    '[Events]\r\n'
    'Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\r\n'
    'Dialogue: 0,0:00:01.00,0:00:04.23,Default,,0,0,0,,吾輩は猫である。\r\n'
    'Dialogue: 0,0:00:04.50,0:00:08.10,Default,,0,0,0,,名前はまだない。\r\n';

/// 把 [text] 编成 UTF-16 字节（测试夹具生成器，与被测实现独立编写）。
Uint8List _encodeUtf16(
  String text, {
  required bool littleEndian,
  bool withBom = false,
}) {
  final List<int> units = text.codeUnits;
  final int bomUnits = withBom ? 1 : 0;
  final ByteData data = ByteData((units.length + bomUnits) * 2);
  final Endian endian = littleEndian ? Endian.little : Endian.big;
  int offset = 0;
  if (withBom) {
    data.setUint16(0, 0xFEFF, endian);
    offset = 2;
  }
  for (int i = 0; i < units.length; i++) {
    data.setUint16(offset + i * 2, units[i], endian);
  }
  return data.buffer.asUint8List();
}

/// 把 [text] 编成带 BOM 的 UTF-32 字节。
Uint8List _encodeUtf32(String text, {required bool littleEndian}) {
  final List<int> runes = text.runes.toList();
  final ByteData data = ByteData((runes.length + 1) * 4);
  final Endian endian = littleEndian ? Endian.little : Endian.big;
  data.setUint32(0, 0xFEFF, endian);
  for (int i = 0; i < runes.length; i++) {
    data.setUint32(4 + i * 4, runes[i], endian);
  }
  return data.buffer.asUint8List();
}
