/// 隐喻的字形来源（移植 folia `metaphor/metaphorGlyphs.ts`）：每个字画两格——紧的（字形本身，
/// 放大后切阈值边缘仍干净）和宽的（大模糊，字周围的一团，开唱时字从这团里凝出来，也让字和
/// 旁边的融球连得上）。笔画密的字（汉字、假名、谚文）宽的那团淡一些。注记（线稿上的公式和标签）
/// 是衬线斜体，key 前加 [metaphorNotePrefix]。一个 cue 的字拼成一张图集，每帧用 drawRawAtlas 实例化。
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

/// 字高在格子里占多少像素、四周留多少（宽模糊要的地方）、一格多大。
const double metaphorGlyphEm = 56;
const double _pad = 22;
const double metaphorGlyphCell = metaphorGlyphEm + _pad * 2;

/// 宽通道的模糊（folia 三遍半径 6 的盒式模糊在 72px 字高上 ≈ σ 6.5px → 0.09em）。
const double _wideSigma = 0.09 * metaphorGlyphEm;
const double _wideGain = 1.5;
const double _denseWide = 0.6;

/// 主题没指定字重时用的纤细一档（folia 用户定的 300）。
const FontWeight metaphorFontWeight = FontWeight.w300;

/// 字前面带这个就是注记的字。
const String metaphorNotePrefix = '\u0001';
const int _cacheLimit = 400;
const int _atlasColumns = 8;

final RegExp _dense = RegExp(r'[⺀-⿟぀-ヿ㐀-䶿一-鿿가-힯豈-﫿]', unicode: true);

const List<String> _noteFamilies = <String>[
  'Cambria Math',
  'STIX Two Math',
  'Cambria',
  'Georgia',
  'Times New Roman',
  'Noto Serif',
  'serif',
];

/// 一个 cue 的图集：每个 key 两格（紧、宽）。
class MetaphorAtlas {
  MetaphorAtlas(this.image, this.slots);

  final ui.Image image;

  /// key → 第几个（紧的格子在 2i，宽的在 2i+1）。
  final Map<String, int> slots;

  Rect tightRect(int slot) => _cellRect(slot * 2);
  Rect wideRect(int slot) => _cellRect(slot * 2 + 1);

  Rect _cellRect(int cell) => Rect.fromLTWH(
    (cell % (_atlasColumns * 2)) * metaphorGlyphCell,
    (cell ~/ (_atlasColumns * 2)) * metaphorGlyphCell,
    metaphorGlyphCell,
    metaphorGlyphCell,
  );

  void dispose() => image.dispose();
}

class _GlyphPainters {
  _GlyphPainters(this.tight, this.wide, this.advance, this.gain);

  final TextPainter tight;
  final TextPainter wide;

  /// 步进宽度，字高的倍数。
  final double advance;
  final double gain;

  void dispose() {
    tight.dispose();
    wide.dispose();
  }
}

/// 字形来源：量字宽、按 key 缓存排好的 TextPainter、拼图集。
class MetaphorGlyphSource {
  final Map<String, _GlyphPainters> _cache = <String, _GlyphPainters>{};

  _GlyphPainters _painters(String key) {
    final _GlyphPainters? hit = _cache[key];
    if (hit != null) return hit;
    if (_cache.length >= _cacheLimit * 2) clear();
    final bool note = key.startsWith(metaphorNotePrefix);
    final String char = note ? key.substring(metaphorNotePrefix.length) : key;
    final bool dense = !note && _dense.hasMatch(char);
    final TextStyle base = note
        ? const TextStyle(
            fontSize: metaphorGlyphEm,
            height: 1,
            leadingDistribution: TextLeadingDistribution.even,
            fontStyle: FontStyle.italic,
            fontWeight: FontWeight.w500,
            fontFamily: 'Cambria Math',
            fontFamilyFallback: _noteFamilies,
          )
        : const TextStyle(
            fontSize: metaphorGlyphEm,
            height: 1,
            leadingDistribution: TextLeadingDistribution.even,
            fontWeight: metaphorFontWeight,
          );
    final TextPainter tight = TextPainter(
      text: TextSpan(
        text: char,
        style: base.copyWith(color: Colors.white),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    // 宽的那团：字本身透明，只留模糊的影子
    final TextPainter wide = TextPainter(
      text: TextSpan(
        text: char,
        style: base.copyWith(
          color: const Color(0x00000000),
          shadows: const <Shadow>[
            Shadow(
              color: Colors.white,
              blurRadius: (_wideSigma - 0.5) / 0.57735,
            ),
          ],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final _GlyphPainters made = _GlyphPainters(
      tight,
      wide,
      math.max(0.2, tight.width / metaphorGlyphEm),
      dense ? _wideGain * _denseWide : _wideGain,
    );
    _cache[key] = made;
    return made;
  }

  /// 一个字的步进宽度，字高的倍数。
  double measure(String char) => _painters(char).advance;

  /// 注记的一个字的步进宽度。
  double measureNote(String char) =>
      _painters(metaphorNotePrefix + char).advance;

  /// 把几个字拼成一张图集；同一个字只占一组格子。
  MetaphorAtlas buildAtlas(Iterable<String> keys) {
    final List<String> unique = keys.toSet().toList();
    // 拼图集途中不清缓存（录进图里的段落还在用）：先腾地方
    if (_cache.length + unique.length > _cacheLimit) clear();
    final Map<String, int> slots = <String, int>{};
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(recorder);
    for (int i = 0; i < unique.length; i++) {
      final _GlyphPainters p = _painters(unique[i]);
      slots[unique[i]] = i;
      final int tightCell = i * 2;
      final int wideCell = tightCell + 1;
      _paintCell(canvas, p.tight, tightCell, 1);
      _paintCell(canvas, p.wide, wideCell, p.gain);
    }
    final ui.Picture picture = recorder.endRecording();
    final int cells = math.max(2, unique.length * 2);
    final int columns = math.min(cells, _atlasColumns * 2);
    final int rows = (cells / (_atlasColumns * 2)).ceil();
    final ui.Image image = picture.toImageSync(
      (columns * metaphorGlyphCell).ceil(),
      (rows * metaphorGlyphCell).ceil(),
    );
    picture.dispose();
    return MetaphorAtlas(image, slots);
  }

  void _paintCell(Canvas canvas, TextPainter p, int cell, double gain) {
    final double left = (cell % (_atlasColumns * 2)) * metaphorGlyphCell;
    final double top = (cell ~/ (_atlasColumns * 2)) * metaphorGlyphCell;
    final Rect rect = Rect.fromLTWH(
      left,
      top,
      metaphorGlyphCell,
      metaphorGlyphCell,
    );
    canvas
      ..save()
      ..clipRect(rect);
    if (gain != 1) {
      // 宽通道乘增益（封顶 1）：透明度过一遍色彩矩阵
      canvas.saveLayer(
        rect,
        Paint()
          ..colorFilter = ColorFilter.matrix(<double>[
            1, 0, 0, 0, 0, //
            0, 1, 0, 0, 0, //
            0, 0, 1, 0, 0, //
            0, 0, 0, gain, 0,
          ]),
      );
    }
    p.paint(
      canvas,
      Offset(
        left + (metaphorGlyphCell - p.width) / 2,
        top + (metaphorGlyphCell - p.height) / 2,
      ),
    );
    if (gain != 1) canvas.restore();
    canvas.restore();
  }

  void clear() {
    for (final _GlyphPainters p in _cache.values) {
      p.dispose();
    }
    _cache.clear();
  }
}
