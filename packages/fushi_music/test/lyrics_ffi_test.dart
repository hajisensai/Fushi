import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_music/fushi_music.dart';
import 'package:test/test.dart';

/// 经真原生库解析 native/fushi_music/tests/fixtures/lyrics/samples（与 Rust golden 同一份样本），
/// 校验 Dart 线格式解码与 Rust 逐字节一致。原生库是硬依赖：找不到库判红，不 skip。
Directory _samples() {
  Directory dir = Directory.current.absolute;
  for (int i = 0; i < 6; i++) {
    final Directory candidate = Directory(
      '${dir.path}/native/fushi_music/tests/fixtures/lyrics/samples',
    );
    if (candidate.existsSync()) return candidate;
    dir = dir.parent;
  }
  throw StateError('lyrics samples not found from ${Directory.current.path}');
}

String _ext(String path) {
  final String name = path.split(RegExp(r'[\\/]')).last;
  final int dot = name.lastIndexOf('.');
  return dot < 0 ? '' : name.substring(dot + 1);
}

void main() {
  late Directory samples;
  setUpAll(() => samples = _samples());

  test('每个样本都能解析，且 Dart 编码与 Rust 线格式逐字节一致', () {
    final List<File> files = samples.listSync().whereType<File>().toList();
    expect(files.length, greaterThanOrEqualTo(15));
    for (final File f in files) {
      final LyricTimeline t = FushiLyrics.parse(
        f.readAsBytesSync(),
        hint: _ext(f.path),
        durationMs: 30000,
      );
      expect(t.lines, isNotEmpty, reason: f.path);
      final Uint8List again = encodeLyricTimeline(t);
      expect(decodeLyricTimeline(again), t, reason: f.path);
      // 经 Rust 导出 TTML 再解析：Dart 解码出的模型不变（TTML 是无损交换格式）。
      final LyricTimeline viaTtml = FushiLyrics.parse(
        FushiLyrics.export(t, 'ttml'),
        hint: 'ttml',
        durationMs: 30000,
      );
      expect(
        viaTtml.lines.length,
        t.lines.length,
        reason: 'ttml round trip ${f.path}',
      );
    }
  });

  test('AMLL TTML：声部侧位、和声、翻译、ruby 解进 Dart 模型', () {
    final LyricTimeline t = FushiLyrics.parse(
      File('${samples.path}/amll.ttml').readAsBytesSync(),
      hint: 'ttml',
    );
    expect(t.timingQuality, LyricTimingQuality.syllable);
    expect(t.lines[0].text, '沈むように');
    expect(t.lines[0].primaryTranslation, '像沉没一般');
    expect(t.lines[1].isBackground, isTrue);
    expect(t.sideOf(t.lines[0]), LyricAgentSide.start);
    expect(t.sideOf(t.lines[2]), LyricAgentSide.center);
    expect(t.lines[2].syllables[0].ruby, 'よる');
  });

  test('加密 QRC 明确报错而不是出乱码', () {
    expect(
      () => FushiLyrics.parse(
        Uint8List.fromList(<int>[0x98, 0x25, 0, 1, 2, 3]),
        hint: 'qrc',
      ),
      throwsA(isA<LyricsParseException>()),
    );
  });

  test('翻译合并 / 导出 LRC', () {
    final LyricTimeline src = FushiLyrics.parse(
      utf8.encode('[00:01.00]夜に駆ける\n[00:04.00]君の声'),
      hint: 'lrc',
    );
    final LyricTimeline zh = FushiLyrics.parse(
      utf8.encode('[00:01.10]在夜里奔跑\n[00:04.00]你的声音'),
      hint: 'lrc',
    );
    final LyricTimeline merged = FushiLyrics.mergeTranslation(src, zh, 'zh');
    expect(merged.lines[0].primaryTranslation, '在夜里奔跑');
    expect(merged.lines[1].translations.single.lang, 'zh');

    final String lrc = utf8.decode(FushiLyrics.export(merged, 'lrc'));
    expect(lrc, contains('[00:01.00]'));
    expect(FushiLyrics.parserVersion, greaterThanOrEqualTo(1));
  });

  test('ASS 原样渲染准备：UTF-16 → UTF-8，PlayRes 缺省按 libass 补', () {
    const String script =
        '[Script Info]\nPlayResX: 1280\n\n[Events]\nFormat: Layer, Start, End, '
        'Style, Name, MarginL, MarginR, MarginV, Effect, Text\nDialogue: 0,'
        '0:00:01.00,0:00:02.00,D,,0,0,0,,{\\k50}夜{\\k50}空\n';
    final Uint8List utf16 = Uint8List.fromList(<int>[
      0xFF,
      0xFE,
      for (final int u in script.codeUnits) ...<int>[u & 0xFF, u >> 8],
    ]);
    final AssRawScript raw = prepareAssRawScript(utf16);
    expect(raw.text, script);
    expect(raw.playResX, 1280);
    expect(raw.playResY, 1024);
  });

  test('线格式版本不符 / 截断抛 FormatException', () {
    final Uint8List ok = encodeLyricTimeline(
      const LyricTimeline(format: 'lrc', lines: <LyricLine>[]),
    );
    final Uint8List bad = Uint8List.fromList(ok)..[4] = 99;
    expect(() => decodeLyricTimeline(bad), throwsFormatException);
    expect(
      () => decodeLyricTimeline(Uint8List.sublistView(ok, 0, ok.length - 1)),
      throwsFormatException,
    );
  });
}
