/// 雾笺要写的逐字序列（folia `nebbiaChars.ts` + `nebbiaCredits.ts`）：每个字 `{ch, t, d}`（秒），
/// 词的分组，句尾随手画的图标，以及最后一句唱完后写在玻璃正中的曲名、歌手。
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart' show immutable;
import 'package:characters/characters.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_runtime.dart';

/// 一个字素，或 `icon:<名字>`（随手画的图标，nebbia_glyphs.dart 的线稿）。
@immutable
class NebbiaChar {
  const NebbiaChar(this.ch, this.t, this.d);
  final String ch;

  /// 开唱时刻（秒）。
  final double t;

  /// 唱多久（秒）。
  final double d;
}

/// 片尾两句的标记。
enum NebbiaCredits { title, artist }

/// 一句。
class NebbiaSourceLine {
  NebbiaSourceLine({
    required this.chars,
    required this.words,
    required this.t,
    required this.end,
    required this.next,
    this.credits,
  });

  final List<NebbiaChar> chars;

  /// 一个词一组字的下标，按顺序；空格不在任何一组里。
  final List<List<int>> words;
  final double t;
  final double end;

  /// 下一句开始的时刻，最后一句是 infinity。
  double next;
  final NebbiaCredits? credits;
}

const String kNebbiaIconPrefix = 'icon:';
bool nebbiaIsIcon(String ch) => ch.startsWith(kNebbiaIconPrefix);

/// emoji → 图标线稿（folia 换成 lucide 图标；这里是自己画的几种，见 nebbia_glyphs.dart）。
const Map<String, String> _emojiIcon = <String, String>{
  '❤': 'heart',
  '♥': 'heart',
  '💗': 'heart',
  '⭐': 'star',
  '★': 'star',
  '☆': 'star',
  '🌙': 'moon',
  '☀': 'sun',
  '🌞': 'sun',
  '🎵': 'music',
  '♪': 'music',
  '🎶': 'music',
  '🌸': 'flower',
  '✿': 'flower',
  '🌷': 'flower',
  '✨': 'sparkles',
  '☂': 'umbrella',
  '☔': 'umbrella',
  '😊': 'smile',
  '🙂': 'smile',
  '🍃': 'leaf',
  '🌿': 'leaf',
};

/// 句尾随手画的图标从这里挑（folia NEBBIA_DEFAULT_DOODLES 的子集）。
const List<String> kNebbiaDoodles = <String>[
  'heart',
  'star',
  'moon',
  'music',
  'flower',
  'sparkles',
  'umbrella',
  'smile',
  'leaf',
  'sun',
];

String _toChar(String grapheme) {
  final String bare = grapheme.replaceAll(RegExp('[️‍]'), '');
  final String? icon = _emojiIcon[bare];
  return icon == null ? bare : '$kNebbiaIconPrefix$icon';
}

/// 单字虚词（folia nebbiaBlocks 的 PARTICLES）。
const String kNebbiaParticles = '的了着过吗呢吧啊呀嘛之与和是也都就还又被把给のがをにはへとでやもねよなかしてたっ';

bool _isHan(String ch) {
  if (ch.isEmpty) return false;
  final int c = ch.runes.first;
  return (c >= 0x3400 && c <= 0x4DBF) ||
      (c >= 0x4E00 && c <= 0x9FFF) ||
      (c >= 0xF900 && c <= 0xFAFF) ||
      (c >= 0x20000 && c <= 0x2FA1F) ||
      ch == '々';
}

bool _isHiragana(String ch) {
  if (ch.isEmpty) return false;
  final int c = ch.runes.first;
  return c >= 0x3040 && c <= 0x309F;
}

bool _isKatakana(String ch) {
  if (ch.isEmpty) return false;
  final int c = ch.runes.first;
  return (c >= 0x30A0 && c <= 0x30FF) || ch == 'ー';
}

bool _isPunct(String ch) => RegExp(r'^[，。、！？!?,.・…「」『』（）()]$').hasMatch(ch);

/// 分词（folia 走 `segmentLyricWords` / Intl.Segmenter；这里是不依赖词典的近似）：
/// 空白断开；拉丁连写成一词；日文按「汉字 + 送假名」「一串片假名」切，单字虚词单独成词；
/// 纯中文的汉字串两两成词（剩三个时三个一词），虚词单独成词；图标单独成词；标点粘前一词。
List<List<int>> nebbiaGroupWords(List<String> chars) {
  final bool japanese = chars.any(_isHiragana) || chars.any(_isKatakana);
  final List<List<int>> words = <List<int>>[];
  List<int> run = <int>[];
  void flush() {
    if (run.isNotEmpty) words.add(run);
    run = <int>[];
  }

  String kind(String ch) {
    if (nebbiaIsIcon(ch)) return 'icon';
    if (ch.trim().isEmpty) return 'space';
    if (_isPunct(ch)) return 'punct';
    if (_isHan(ch)) return 'han';
    if (_isHiragana(ch)) return 'hira';
    if (_isKatakana(ch)) return 'kata';
    if (lyricVisualizerIsCjk(ch)) return 'cjk';
    return 'latin';
  }

  String prev = 'space';
  for (int i = 0; i < chars.length; i++) {
    final String ch = chars[i];
    final String k = kind(ch);
    switch (k) {
      case 'space':
        flush();
      case 'icon':
        flush();
        words.add(<int>[i]);
      case 'punct':
        if (run.isNotEmpty) {
          run.add(i);
        } else if (words.isNotEmpty) {
          words.last.add(i);
        } else {
          run.add(i);
        }
      case 'latin':
        if (prev != 'latin' && prev != 'punct') flush();
        run.add(i);
      case 'kata':
        if (prev != 'kata') flush();
        run.add(i);
      case 'hira':
        // 跟在汉字后面的只有格助词断开（て / た / し 多是送假名，留在词里）。
        if ((prev == 'han' || prev == 'hira')
            ? 'がをにはへでのもや'.contains(ch)
            : kNebbiaParticles.contains(ch)) {
          flush();
          words.add(<int>[i]);
        } else if (prev == 'han' || prev == 'hira') {
          run.add(i);
        } else {
          flush();
          run.add(i);
        }
      case 'han':
        if (kNebbiaParticles.contains(ch)) {
          flush();
          words.add(<int>[i]);
        } else if (japanese) {
          if (prev != 'han') flush();
          run.add(i);
        } else {
          if (prev != 'han') flush();
          run.add(i);
          // 中文：两字一词；后面正好只剩一个汉字时并进来成三字词。
          final bool nextHan =
              i + 1 < chars.length &&
              _isHan(chars[i + 1]) &&
              !kNebbiaParticles.contains(chars[i + 1]);
          final bool nextNextHan =
              i + 2 < chars.length &&
              _isHan(chars[i + 2]) &&
              !kNebbiaParticles.contains(chars[i + 2]);
          if (run.length >= 2 &&
              !(run.length == 2 && nextHan && !nextNextHan)) {
            flush();
          }
        }
      default:
        if (prev != k) flush();
        run.add(i);
    }
    prev = k;
  }
  flush();
  return words;
}

/// 一句的词：取框架的共享分词（`line.segments`，folia `segmentLyricWords`：中文逐字词典切分、日文
/// 汉字 + 送假名、拉丁按词、标点粘前），去掉空白；图标单独成词。[chars] 与 `line.glyphs` 一一对应。
List<List<int>> nebbiaSharedWords(
  LyricVisualizerLine line,
  List<String> chars,
) {
  final List<List<int>> words = <List<int>>[];
  for (final LyricVisualizerSegment seg in line.segments) {
    List<int> run = <int>[];
    final int end = math.min(chars.length, seg.firstGlyph + seg.glyphCount);
    for (int i = seg.firstGlyph; i < end; i++) {
      final String ch = chars[i];
      if (ch.trim().isEmpty) continue;
      if (nebbiaIsIcon(ch)) {
        if (run.isNotEmpty) words.add(run);
        run = <int>[];
        words.add(<int>[i]);
        continue;
      }
      run.add(i);
    }
    if (run.isNotEmpty) words.add(run);
  }
  return words;
}

/// 整首歌的逐字序列。[seed] 决定哪些句子句尾画图标、画哪个；[doodle] 是概率。
List<NebbiaSourceLine> buildNebbiaLines(
  List<LyricVisualizerLine> lines,
  int seed,
  double doodle,
) {
  final List<NebbiaSourceLine> out = <NebbiaSourceLine>[];
  for (int index = 0; index < lines.length; index++) {
    final LyricVisualizerLine line = lines[index];
    final List<NebbiaChar> chars = <NebbiaChar>[
      for (final LyricVisualizerGlyph g in line.glyphs)
        NebbiaChar(
          _toChar(g.text),
          g.startMs / 1000,
          math.max(0, g.endMs - g.startMs) / 1000,
        ),
    ];
    final List<List<int>> words = nebbiaSharedWords(line, <String>[
      for (final NebbiaChar c in chars) c.ch,
    ]);
    final double t = line.startMs / 1000;
    final double end = math.max(t, line.endMs / 1000);
    final double next = index + 1 < lines.length
        ? lines[index + 1].startMs / 1000
        : double.infinity;
    final LyricVisualizerRandom rng = LyricVisualizerRandom(
      (seed + (index + 1) * 977 + 31) & 0xFFFFFFFF,
    );
    if (chars.isNotEmpty &&
        !chars.any((NebbiaChar c) => nebbiaIsIcon(c.ch)) &&
        rng.next() < doodle) {
      final NebbiaChar last = chars.last;
      final double at = last.t + last.d;
      final String icon =
          kNebbiaDoodles[(rng.next() * kNebbiaDoodles.length).floor() %
              kNebbiaDoodles.length];
      chars
        ..add(NebbiaChar(' ', at, 0))
        ..add(NebbiaChar('$kNebbiaIconPrefix$icon', at + 0.08, 1.1));
      words.add(<int>[chars.length - 1]);
    }
    out.add(
      NebbiaSourceLine(chars: chars, words: words, t: t, end: end, next: next),
    );
  }
  return out;
}

/// 最后一句唱完后多久开写曲名（秒）。
const double kNebbiaCreditsDelay = 2.5;

NebbiaSourceLine _creditLine(String text, double t, NebbiaCredits kind) {
  final List<String> gs = text.characters.toList();
  final List<NebbiaChar> chars = <NebbiaChar>[
    for (int i = 0; i < gs.length; i++) NebbiaChar(gs[i], t + i * 0.1, 0.5),
  ];
  return NebbiaSourceLine(
    chars: chars,
    words: nebbiaGroupWords(gs),
    t: t,
    end: chars.isEmpty ? t : chars.last.t + chars.last.d,
    next: double.infinity,
    credits: kind,
  );
}

/// 在整首歌词后面接上片尾两句（没有歌词或没有曲名时不加）。
List<NebbiaSourceLine> appendNebbiaCredits(
  List<NebbiaSourceLine> source,
  String? title,
  String? artist,
) {
  final String? name = title?.trim();
  if (source.isEmpty || name == null || name.isEmpty) return source;
  final double at =
      source.map((NebbiaSourceLine l) => l.end).reduce(math.max) +
      kNebbiaCreditsDelay;
  source.last.next = math.min(source.last.next, at);
  final NebbiaSourceLine titleLine = _creditLine(name, at, NebbiaCredits.title);
  final List<NebbiaSourceLine> out = <NebbiaSourceLine>[...source, titleLine];
  final String? by = artist?.trim();
  if (by != null && by.isNotEmpty) {
    out.add(_creditLine(by, titleLine.end + 0.2, NebbiaCredits.artist));
  }
  return out;
}
