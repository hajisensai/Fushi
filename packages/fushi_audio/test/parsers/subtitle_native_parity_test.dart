// 字幕解析搬进 Rust（native/fushi_compute/src/parse/subtitle/）后的逐位一致性回归。
//
// 摘要由**旧 Dart 实现**（删除前的 srt_parser / vtt_parser / ass_parser / subtitle_markup /
// strip_html_tags）对 subtitle_parity_corpus.dart 的确定性语料求得：每条输出按规范化形式
// （全部字段；double 按位模式；异常按类型与消息；列表的运行时类型；cueStyle 的对象共享关系）
// 串起来取 64 位 FNV-1a。新实现必须得到同一个摘要。摘要不一致时**不能**用新实现的输出回填：
// 要么是新实现改变了结果（修实现），要么是语料生成器被改了（回到删 Dart 实现前的提交，用旧
// 实现重新求摘要）。
//
// 原生库是硬依赖：找不到库这里直接失败，不 skip（测试宿主下自动向上查找
// native/fushi_compute/prebuilt/<平台>/，或用 FUSHI_COMPUTE_LIB 指定）。
@TestOn('vm')
library;

import 'dart:ffi';

import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_audio/src/parsers/strip_html_tags.dart';
import 'package:test/test.dart';

import 'subtitle_parity_corpus.dart';

/// 旧 Dart 实现在各语料上的摘要（条数见各测试），**分 CPU 架构**：语料里有 `NaN` 的
/// PlayRes / 坐标，而 Dart 的 `double.nan`（`double.tryParse('NaN')`）位模式等于硬件生成的
/// NaN——x64 是 0xFFF8…、arm64 是 0x7FF8…——所以旧实现本身在两种 CPU 上的输出就差在这几
/// 个位上（markup / ass 两项）。x64 摘要在 Windows x64 上求得，arm64 摘要在 macOS arm64 上
/// 求得（都是删除前的旧 Dart 实现）；Rust 侧 `dart_nan()` 同样取硬件 NaN。
const Map<String, String> _oldDartDigestsX64 = <String, String>{
  'markup': '72e2b157fcf311f9',
  'strip': 'e9e4cddfbe457903',
  'srt': '83417cc5f677979e',
  'vtt': 'a205570d14cc5fc9',
  'ass': '1d369fcf6f54ae6f',
  'sweep': '85c965485af1d588',
};

const Map<String, String> _oldDartDigestsArm64 = <String, String>{
  'markup': '9e8c3c547a4312bb',
  'strip': 'e9e4cddfbe457903',
  'srt': '83417cc5f677979e',
  'vtt': 'a205570d14cc5fc9',
  'ass': '71665138dee47163',
  'sweep': '85c965485af1d588',
};

final Map<String, String> _oldDartDigests = switch (Abi.current()) {
  Abi.windowsX64 || Abi.linuxX64 || Abi.macosX64 => _oldDartDigestsX64,
  Abi.windowsArm64 ||
  Abi.linuxArm64 ||
  Abi.macosArm64 ||
  Abi.androidArm64 ||
  Abi.iosArm64 => _oldDartDigestsArm64,
  final Abi other => throw UnsupportedError('no frozen digests for $other'),
};

String _digest(Iterable<String> canon) {
  final ParityDigest d = ParityDigest();
  canon.forEach(d.add);
  return d.hex;
}

void main() {
  test('markup corpus (20000 cues) matches the old Dart implementation', () {
    expect(
      _digest(
        markupCases(20000, kParitySeedBase + 1).map(
          (MarkupCase c) => canonValue(
            () => parseSubtitleMarkup(
              c.raw,
              playResX: c.playResX,
              playResY: c.playResY,
              layer: c.layer,
            ),
          ),
        ),
      ),
      _oldDartDigests['markup'],
    );
  });

  test(
    'stripHtmlTags corpus (20000 lines) matches the old Dart implementation',
    () {
      expect(
        _digest(
          htmlCases(
            20000,
            kParitySeedBase + 2,
          ).map((String raw) => canonValue(() => stripHtmlTags(raw))),
        ),
        _oldDartDigests['strip'],
      );
    },
  );

  test('SRT corpus (3000 documents) matches the old Dart implementation', () {
    expect(
      _digest(
        srtCases(3000, kParitySeedBase + 3).map(
          (String doc) => canonCues(
            () => SrtParser.parseString(
              content: doc,
              bookKey: 'k',
              chapterHref: 'c',
              audioFileIndex: 2,
            ),
          ),
        ),
      ),
      _oldDartDigests['srt'],
    );
  });

  test(
    'WebVTT corpus (3000 documents) matches the old Dart implementation',
    () {
      expect(
        _digest(
          vttCases(3000, kParitySeedBase + 4).map(
            (String doc) => canonCues(
              () => VttParser.parseString(content: doc, bookKey: 'k'),
            ),
          ),
        ),
        _oldDartDigests['vtt'],
      );
    },
  );

  test('ASS corpus (3000 documents) matches the old Dart implementation', () {
    expect(
      _digest(
        assCases(3000, kParitySeedBase + 5).map(
          (AssCase c) => canonCues(
            () => AssParser.parseString(
              content: c.doc,
              bookKey: 'k',
              includeDrawings: c.drawings,
            ),
          ),
        ),
      ),
      _oldDartDigests['ass'],
    );
  });

  test('grapheme sweep over every code point matches package:characters', () {
    expect(
      _digest(
        graphemeSweep().map(
          (String raw) => canonValue(() => parseSubtitleMarkup(raw)),
        ),
      ),
      _oldDartDigests['sweep'],
    );
  });

  group('representative samples (frozen from the old Dart implementation)', () {
    test('SRT: html, ruby, multi-line join, timecode forms', () {
      final List<AudioCue> cues = SrtParser.parseString(
        content:
            '﻿1\r\n00:00:01,000 --> 00:00:04,23\r\n<i>吾輩</i>は'
            '<ruby>猫<rt>ねこ</rt></ruby>\r\nである。\r\n\r\n'
            '2\n00:00:60,000 --> 00:00:61,000\nskip\n\n'
            '3\n1:02:03.4 --> 1:02:04.5\n{\\an8}上\\N下\n',
        bookKey: 'b',
      );
      expect(cues, hasLength(2));
      expect(cues[0].text, '吾輩は猫 である。');
      expect((cues[0].startMs, cues[0].endMs), (1000, 4230));
      expect((cues[1].startMs, cues[1].endMs), (3723400, 3724500));
      expect(cues[1].text, '上 下');
      expect(cues[1].markup!.lineBreakGraphemes, <int>[1]);
      expect(cues[1].markup!.anchor!.vertical, SubtitleVAlign.top);
      expect(cues[1].textFragmentId, '[data-cue-id="1"]');
    });

    test('SRT: hour overflow throws FormatException like int.parse', () {
      expect(
        () => SrtParser.parseString(
          content: '1\n99999999999999999999:00:00,000 --> 00:00:01,000\nx\n',
          bookKey: 'b',
        ),
        throwsA(
          isA<FormatException>().having(
            (FormatException e) => e.message,
            'message',
            'Positive input exceeds the limit of integer',
          ),
        ),
      );
    });

    test('VTT: header / NOTE skipped, settings cut, MM:SS.mmm', () {
      final List<AudioCue> cues = VttParser.parseString(
        content:
            'WEBVTT\n\nNOTE x\n\nid\n01:02.5 --> 01:03.000 align:left\n'
            '<c.y>a</c>\n\n --> 00:01.000\nnone\n',
        bookKey: 'b',
      );
      expect(cues, hasLength(1));
      expect((cues[0].startMs, cues[0].endMs), (62500, 63000));
      expect(cues[0].text, 'a');
    });

    test('ASS: styles, dynamic columns, stable sort, end fallback', () {
      const String src =
          '[Script Info]\nPlayResX: 1920\nPlayResY: 1080\n\n'
          '[V4+ Styles]\nFormat: Name, Fontname, Fontsize, PrimaryColour, '
          'Alignment\nStyle: Default,Arial,60,&H000000FF,2\n\n'
          '[Events]\nFormat: Layer, Start, End, Style, MarginL, Text\n'
          'Dialogue: 1,0:00:02.00,0:00:03.00,default,0,b,c\n'
          'Dialogue: 0,0:00:01.00,,Default,12,{\\an8\\k50}a{\\k25}b\n'
          'Dialogue: 0,0:00:01.50,0:00:00.50,Default,0,gone\n'
          '[Fonts]\nDialogue: 0,0:00:09.00,0:00:10.00,Default,0,after\n';
      final List<AudioCue> cues = AssParser.parseString(
        content: src,
        bookKey: 'b',
      );
      expect(cues.map((AudioCue c) => c.text), <String>['ab', 'b,c']);
      expect((cues[0].startMs, cues[0].endMs), (1000, 1500));
      expect((cues[1].startMs, cues[1].endMs), (2000, 3000));
      final SubtitleMarkup m0 = cues[0].markup!;
      expect(m0.anchor!.vertical, SubtitleVAlign.top);
      expect(m0.cueStyle!.marginL, 12);
      expect(m0.cueStyle!.primaryColorArgb, 0xFFFF0000);
      expect(m0.spans.map((SubtitleSpan s) => s.kStartCs), <int>[0, 50]);
      expect(m0.playResX, 1920);
      final SubtitleMarkup m1 = cues[1].markup!;
      expect(m1.layer, 1);
      expect(m1.anchor!.horizontal, SubtitleHAlign.center);
      expect(identical(m1.anchor, m1.cueStyle!.anchor), isTrue);
    });

    test('ASS: Start column past the row throws RangeError like List[]', () {
      expect(
        () => AssParser.parseString(
          content: '[Events]\nFormat: Text, End, Start\nDialogue: a,b\n',
          bookKey: 'b',
        ),
        throwsA(
          isA<RangeError>().having(
            (RangeError e) => e.toString(),
            'toString',
            'RangeError (length): Invalid value: Not in inclusive range 0..1: 2',
          ),
        ),
      );
    });

    test('markup: grapheme spans, drawing, clip, transitions', () {
      final SubtitleMarkup m = parseSubtitleMarkup(
        '{\\i1}\u{1F468}\u200D\u{1F469}\u200D\u{1F467}e\u0301'
        '{\\i0\\1c&HFF&}\u{1F1EF}\u{1F1F5}\u{1F1FA}\u{1F1F8}'
        '{\\p1\\3c&H00FF00&}m 0 0 l 192 0 192 108{\\p0}'
        '{\\t(0,500,2,\\fscx150\\alpha&H80&)\\iclip(0,0,960,540)}',
        playResX: 1920,
        playResY: 1080,
      );
      expect(
        m.plainText,
        '\u{1F468}\u200D\u{1F469}\u200D\u{1F467}e\u0301'
        '\u{1F1EF}\u{1F1F5}\u{1F1FA}\u{1F1F8}',
      );
      expect(
        m.spans.map((SubtitleSpan s) => (s.startGrapheme, s.endGrapheme)),
        <(int, int)>[(0, 2), (2, 4)],
      );
      expect(m.drawing!.maxX, 0.1);
      expect(m.drawingStyle!.outlineColorArgb, 0xFF00FF00);
      expect(m.clip!.inverse, isTrue);
      expect(m.scale!.toX, 1.5);
      expect(m.transitions.single.alphaTo, closeTo(1 - 128 / 255, 1e-12));
      expect(m.transitions.single.accel, 2);
      expect(
        () => m.transitions.add(m.transitions.first),
        throwsUnsupportedError,
      );
    });

    test('markup: karaoke duration overflow throws UnsupportedError', () {
      expect(
        () => parseSubtitleMarkup('{\\k${'1' * 400}}x'),
        throwsA(isA<UnsupportedError>()),
      );
    });

    test('stripHtmlTags: ruby annotations dropped, malformed falls back', () {
      expect(stripHtmlTags('<ruby>震<rt>ふる</rt></ruby>'), '震');
      expect(stripHtmlTags('<ruby>震<rt>ふる</ruby>え'), '震え');
      expect(stripHtmlTags('<ruby>漢<rt かん</ruby>の話'), '漢の話');
      expect(stripHtmlTags('a<rt/>b'), 'ab');
      expect(stripHtmlTags('<RT>x</Rt>y'), 'y');
      expect(stripHtmlTags(' a <> b\u0085'), 'a <> b');
    });
  });
}
