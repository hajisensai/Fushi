/// Offline OCR assistance for Galgame calibration.
///
/// This file is intentionally outside `src/lookup`.  OCR is used only while a
/// user is calibrating a frozen screenshot: it proposes line/character
/// locations, while the Hook text remains the authoritative string and the
/// native grid remains the authoritative hit-test geometry.  The runtime
/// lookup path never calls this module.
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:fushi/src/lookup/gal_lookup_calibration_draft.dart';
import 'package:fushi/src/lookup/gal_lookup_calibration_capture.dart';
import 'package:fushi/src/lookup/gal_lookup_calibration_image_fit.dart';
import 'package:fushi/src/lookup/gal_lookup_calibration_preview.dart';
import 'package:fushi/src/lookup/gal_lookup_surface_profile.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi_engine/ocr/manga_ocr_model_downloader.dart';
import 'package:fushi_engine/ocr/manga_ocr_model_manifest.dart';
import 'package:fushi_engine/ocr/manga_ocr_service.dart';
import 'package:fushi_engine/ocr/ocr_host_bindings.dart';
import 'package:fushi_engine/ocr/ocr_inference.dart';
import 'package:fushi_engine/ocr/ocr_types.dart';
import 'package:fushi_engine/ocr/ppocr_line_detector.dart';
import 'package:fushi_engine/ocr/ppocr_line_recognizer.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

part 'gal_lookup_ocr_ink_geometry.dart';
part 'gal_lookup_ocr_character_advances.dart';
part 'gal_lookup_v24_fit.dart';
part 'gal_lookup_v24_checks.dart';
part 'gal_lookup_ocr_unicode.dart';

/// The only model files calibration needs.  The full manga OCR pack is about
/// 500 MB; these PP-OCRv6 small files are about 31 MB and provide exactly the
/// coarse line/character hints this job needs.
const List<MangaOcrModelFile> kGalCalibrationOcrModelManifest =
    <MangaOcrModelFile>[
      MangaOcrModelFile(
        fileName: kPpOcrDetFileName,
        url:
            'https://huggingface.co/PaddlePaddle/PP-OCRv6_small_det_onnx/'
            'resolve/$kPpOcrDetRevision/inference.onnx',
        expectedBytes: 9880512,
        role: MangaOcrModelRole.detector,
      ),
      MangaOcrModelFile(
        fileName: kPpOcrRecFileName,
        url:
            'https://huggingface.co/PaddlePaddle/PP-OCRv6_small_rec_onnx/'
            'resolve/$kPpOcrRecRevision/inference.onnx',
        expectedBytes: 21159378,
        role: MangaOcrModelRole.recognizer,
      ),
      MangaOcrModelFile(
        fileName: kPpOcrRecDictFileName,
        url:
            'https://huggingface.co/PaddlePaddle/PP-OCRv6_small_rec_onnx/'
            'resolve/$kPpOcrRecRevision/inference.yml',
        expectedBytes: 150579,
        role: MangaOcrModelRole.recognizer,
      ),
    ];

class GalCalibrationOcrModelStatus {
  const GalCalibrationOcrModelStatus({
    required this.ready,
    required this.obtainedBytes,
    required this.diskBytes,
    required this.totalBytes,
  });

  final bool ready;
  final int obtainedBytes;
  final int diskBytes;
  final int totalBytes;
}

/// Model storage is separate from the much larger manga OCR model directory.
class GalCalibrationOcrModelStore {
  GalCalibrationOcrModelStore({
    Future<Directory> Function()? directoryProvider,
    MangaOcrModelDownloader? downloader,
    List<MangaOcrModelFile>? manifest,
  }) : _directoryProvider = directoryProvider ?? _defaultDirectory,
       _downloader = downloader ?? MangaOcrModelDownloader(),
       manifest = List.unmodifiable(
         manifest ?? kGalCalibrationOcrModelManifest,
       );

  final Future<Directory> Function() _directoryProvider;
  final MangaOcrModelDownloader _downloader;
  final List<MangaOcrModelFile> manifest;

  static Future<Directory> _defaultDirectory() async {
    final Directory support = await AppPaths.supportRootDirectory();
    final Directory manga = Directory(
      p.join(support.path, 'ocr_models', 'manga'),
    );
    // The shared manga OCR service already downloads these PP-OCRv6 files.
    // Reuse them when present so enabling calibration does not create a second
    // 31 MB copy; otherwise keep the small calibration pack isolated from the
    // larger manga model lifecycle.
    final bool sharedReady = kGalCalibrationOcrModelManifest.every(
      (MangaOcrModelFile model) =>
          isMangaOcrModelFileReady(File(p.join(manga.path, model.fileName))),
    );
    if (sharedReady) return manga;
    return Directory(p.join(support.path, 'ocr_models', 'gal_calibration'));
  }

  Future<Directory> directory() => _directoryProvider();

  Future<GalCalibrationOcrModelStatus> status() async {
    final Directory dir = await directory();
    int obtained = 0;
    int disk = 0;
    bool ready = true;
    int total = 0;
    for (final MangaOcrModelFile model in manifest) {
      total += model.expectedBytes;
      final File file = File(p.join(dir.path, model.fileName));
      if (isMangaOcrModelFileReady(file)) {
        obtained += file.lengthSync();
        disk += file.lengthSync();
        continue;
      }
      ready = false;
      final File part = File('${file.path}.part');
      if (part.existsSync()) {
        obtained += part.lengthSync();
        disk += part.lengthSync();
      }
    }
    return GalCalibrationOcrModelStatus(
      ready: ready,
      obtainedBytes: obtained,
      diskBytes: disk,
      totalBytes: total,
    );
  }

  Stream<MangaOcrDownloadEvent> download() async* {
    final Directory dir = await directory();
    await dir.create(recursive: true);
    yield* _downloader.downloadAll(files: manifest, targetDir: dir);
  }
}

/// An OCR detector's line box plus the text it guessed.  Coordinates are in
/// the full captured client image, not in the cropped dialogue region.
class GalCalibrationOcrLine {
  const GalCalibrationOcrLine({
    required this.text,
    required this.rect,
    required this.score,
    this.tokens = const <GalCalibrationOcrToken>[],
  });

  final String text;
  final OcrRect rect;
  final double score;
  final List<GalCalibrationOcrToken> tokens;
}

/// Approximate recognition-frame locations, not exact glyph outlines.
class GalCalibrationOcrToken {
  const GalCalibrationOcrToken(
    this.text,
    this.rect,
    this.confidence, {
    this.synthetic = false,
  });
  final String text;
  final OcrRect rect;
  final double confidence;
  final bool synthetic;
}

class GalCalibrationOcrGlyph {
  const GalCalibrationOcrGlyph({
    required this.sourceIndex,
    required this.charLength,
    required this.cellOffset,
    required this.lineIndex,
    required this.rect,
    required this.confidence,
    this.inkMeasured = false,
    this.visualMeasured = false,
    this.matchKind = 'exact',
    this.ocrTokenIndex,
    this.syntheticOcrPosition = false,
    this.ocrConfidence,
    this.ocrText,
  });

  final int sourceIndex;
  final int charLength;
  final int cellOffset;
  final int lineIndex;
  final OcrRect rect;
  final double confidence;
  final bool inkMeasured;

  /// A pixel-backed visual rectangle for a small punctuation mark. This is
  /// intentionally separate from [inkMeasured], which is reserved for the
  /// full-size anchors that establish the cell grid.
  final bool visualMeasured;

  /// The fixed-text/OCR relation that produced this position. Generic
  /// substitutions can preserve correspondence, but they are not geometry
  /// anchors.
  final String matchKind;

  /// Index in the source OCR line, when this glyph came from a real token.
  final int? ocrTokenIndex;

  /// True for positions synthesized from a line rectangle without token
  /// geometry. Synthetic positions are useful for a coarse diagnostic only.
  final bool syntheticOcrPosition;

  /// Original OCR confidence, before correspondence weighting.
  final double? ocrConfidence;
  final String? ocrText;
}

final RegExp _punctuationOrSymbolCharacter = RegExp(
  r'^[\p{P}\p{S}]$',
  unicode: true,
);

int? _singlePunctuationCodePoint(String text) {
  if (!_punctuationOrSymbolCharacter.hasMatch(text)) return null;
  final List<int> runes = text.runes.toList(growable: false);
  return runes.length == 1 && runes.single <= 0xffff ? runes.single : null;
}

class GalCalibrationOcrMatchedLine {
  const GalCalibrationOcrMatchedLine({
    required this.sourceStart,
    required this.sourceEnd,
    required this.cellCount,
    required this.lineIndex,
    required this.rect,
    required this.glyphs,
    this.ocrScore = 1,
    this.ocrTokenCount,
  });

  /// Indices are positions in the source's logical cell list, not UTF-16
  /// offsets.  The glyphs themselves retain the UTF-16 index used by Hook.
  final int sourceStart;
  final int sourceEnd;
  final int cellCount;
  final int lineIndex;
  final OcrRect rect;
  final List<GalCalibrationOcrGlyph> glyphs;
  final double ocrScore;
  final int? ocrTokenCount;
}

class GalCalibrationOcrAlignment {
  const GalCalibrationOcrAlignment({
    required this.lines,
    required this.confidence,
    this.reason,
  });

  final List<GalCalibrationOcrMatchedLine> lines;
  final double confidence;
  final String? reason;

  bool get accepted => reason == null && lines.isNotEmpty;
}

class _SourceUnit {
  const _SourceUnit({
    required this.value,
    required this.index,
    required this.length,
    required this.whitespace,
    this.hardBreakBefore = false,
  });

  final String value;
  final int index;
  final int length;
  final bool whitespace;
  final bool hardBreakBefore;
  bool get newline => value == '\n' || value == '\r';
}

class _OcrUnit {
  const _OcrUnit({
    required this.value,
    required this.rect,
    this.confidence = 1,
    this.ocrTokenIndex,
    this.synthetic = false,
  });

  final String value;
  final OcrRect rect;
  final double confidence;
  final int? ocrTokenIndex;
  final bool synthetic;
}

class _LineSpan {
  const _LineSpan(this.start, this.end);
  final int start;
  final int end;
}

class _TokenPair {
  const _TokenPair(this.source, this.ocr, this.cost, this.kind);
  final int source;
  final int ocr;
  final double cost;
  final String kind;
}

bool _isPitchException(String value) {
  // The frozen oracle classifies the first Unicode scalar, including symbols
  // outside the BMP; the legacy per-character-width helper remains separate.
  if (value.isNotEmpty &&
      _punctuationOrSymbolCharacter.hasMatch(
        String.fromCharCode(value.runes.first),
      )) {
    return true;
  }
  return value == '「' ||
      value == '」' ||
      value == '『' ||
      value == '』' ||
      'っッゃゅょぁぃぅぇぉゎヮヵヶ'.contains(value);
}

typedef _OcrLineSelection = ({
  List<GalCalibrationOcrLine> lines,
  List<_LineSpan> spans,
  double score,
});

String _foldOcrChar(String value) {
  if (value.isEmpty) return value;
  final String folded = value.runes
      .map((int rune) => _ocrNfkcScalars[rune] ?? String.fromCharCode(rune))
      .join()
      .toLowerCase();
  return '‐‑‒–—―−'.contains(folded) ? '-' : folded;
}

({String kind, double cost}) _characterRelation(
  String source,
  String observed,
) {
  if (source == observed) return (kind: 'exact', cost: 0);
  if (_foldOcrChar(source) == _foldOcrChar(observed)) {
    return (kind: 'normalised', cost: .08);
  }
  if ((source == 'っ' && observed == 'つ') ||
      (source == 'つ' && observed == 'っ') ||
      (source == 'ッ' && observed == 'ツ') ||
      (source == 'ツ' && observed == 'ッ') ||
      (source == 'ー' && observed == '一') ||
      (source == '一' && observed == 'ー')) {
    return (kind: 'known_confusion', cost: .18);
  }
  if ('、。！？!?，．'.contains(source) && '、。！？!?，．,.'.contains(observed)) {
    return (kind: 'punctuation_confusion', cost: .22);
  }
  if (source == '…' && '.・﹒…'.contains(observed)) {
    return (kind: 'ellipsis_confusion', cost: .20);
  }
  return (kind: 'substitution', cost: .48);
}

bool _reliableRelation(String kind) => const <String>{
  'exact',
  'normalised',
  'known_confusion',
  'punctuation_confusion',
  'ellipsis_confusion',
}.contains(kind);

bool _ocrWhitespace(String value) => value.trim().isEmpty;

List<_SourceUnit> _sourceUnits(String text) {
  final List<_SourceUnit> units = <_SourceUnit>[];
  int index = 0;
  bool hardBreak = false;
  for (final int rune in text.runes) {
    final String value = String.fromCharCode(rune);
    final int length = value.length;
    if (rune == 0x0a || rune == 0x0d) {
      units.add(
        _SourceUnit(
          value: value,
          index: index,
          length: length,
          whitespace: false,
        ),
      );
      index += length;
      hardBreak = true;
      continue;
    }
    final bool combining =
        (rune >= 0x0300 && rune <= 0x036f) ||
        (rune >= 0x1ab0 && rune <= 0x1aff) ||
        (rune >= 0x1dc0 && rune <= 0x1dff) ||
        (rune >= 0x20d0 && rune <= 0x20ff) ||
        (rune >= 0xfe00 && rune <= 0xfe0f) ||
        (rune >= 0xfe20 && rune <= 0xfe2f) ||
        (rune >= 0x1f3fb && rune <= 0x1f3ff) ||
        (rune >= 0xe0100 && rune <= 0xe01ef);
    if (combining && !hardBreak && units.isNotEmpty && !units.last.whitespace) {
      final _SourceUnit previous = units.removeLast();
      units.add(
        _SourceUnit(
          value: previous.value + value,
          index: previous.index,
          length: previous.length + length,
          whitespace: false,
          hardBreakBefore: previous.hardBreakBefore,
        ),
      );
      index += length;
      continue;
    }
    units.add(
      _SourceUnit(
        value: value,
        index: index,
        length: length,
        whitespace: value == ' ' || value == '\t' || value == '\u3000',
        hardBreakBefore: hardBreak,
      ),
    );
    index += length;
    hardBreak = false;
  }
  return units;
}

bool _rowsFollowHookLineBreaks(List<_SourceUnit> source, List<dynamic> ranges) {
  if (ranges.length < 2) return false;
  int previousEnd = 0;
  for (int row = 0; row < ranges.length; row++) {
    final Map<dynamic, dynamic> range = ranges[row] as Map;
    final int start = (range['sourceStart'] as num).toInt();
    final int end = (range['sourceEnd'] as num).toInt();
    if (start < previousEnd ||
        end <= start ||
        end > source.length ||
        source.sublist(start, end).any((unit) => unit.newline)) {
      return false;
    }
    if (row == 0 && source.take(start).any((unit) => unit.newline)) {
      return false;
    }
    if (row > 0) {
      final List<_SourceUnit> gap = source.sublist(previousEnd, start);
      final String breaks = gap
          .where((unit) => unit.newline)
          .map((unit) => unit.value)
          .join();
      if ((breaks != '\n' && breaks != '\r' && breaks != '\r\n') ||
          gap.any((unit) => !unit.newline && !unit.whitespace)) {
        return false;
      }
    }
    previousEnd = end;
  }
  return true;
}

List<_OcrUnit> _ocrUnits(GalCalibrationOcrLine line) {
  if (line.tokens.isNotEmpty) {
    final List<_OcrUnit> measured = <_OcrUnit>[];
    for (int tokenIndex = 0; tokenIndex < line.tokens.length; tokenIndex++) {
      final GalCalibrationOcrToken token = line.tokens[tokenIndex];
      final List<String> values = <String>[];
      for (final int rune in token.text.runes) {
        final String value = String.fromCharCode(rune);
        final int last = values.length - 1;
        if (_isCombiningRune(rune) &&
            last >= 0 &&
            !_ocrWhitespace(values[last])) {
          values[last] += value;
        } else {
          values.add(value);
        }
      }
      if (values.isEmpty) continue;
      final double width = token.rect.width / values.length;
      for (int i = 0; i < values.length; i++) {
        if (_isCombiningRune(values[i].runes.first) &&
            measured.isNotEmpty &&
            !_ocrWhitespace(measured.last.value)) {
          final _OcrUnit previous = measured.removeLast();
          measured.add(
            _OcrUnit(
              value: previous.value + values[i],
              rect: OcrRect(
                left: math.min(previous.rect.left, token.rect.left),
                top: math.min(previous.rect.top, token.rect.top),
                right: math.max(previous.rect.right, token.rect.right),
                bottom: math.max(previous.rect.bottom, token.rect.bottom),
              ),
              confidence: math.min(previous.confidence, token.confidence),
              ocrTokenIndex: previous.ocrTokenIndex,
              synthetic: previous.synthetic || token.synthetic,
            ),
          );
          continue;
        }
        measured.add(
          _OcrUnit(
            value: values[i],
            rect: OcrRect(
              left: token.rect.left + width * i,
              top: token.rect.top,
              right: token.rect.left + width * (i + 1),
              bottom: token.rect.bottom,
            ),
            confidence: token.confidence,
            ocrTokenIndex: tokenIndex,
            synthetic: token.synthetic,
          ),
        );
      }
    }
    // Keep zero-area tokens as correspondence evidence, as the frozen oracle
    // does. Dropping one here changes OCR indices and both row edge identities.
    return measured;
  }
  final List<String> values = <String>[];
  for (final int rune in line.text.runes) {
    if (_ocrWhitespace(String.fromCharCode(rune))) continue;
    final String value = String.fromCharCode(rune);
    final int last = values.length - 1;
    final bool combining =
        (rune >= 0x0300 && rune <= 0x036f) ||
        (rune >= 0x1ab0 && rune <= 0x1aff) ||
        (rune >= 0x1dc0 && rune <= 0x1dff) ||
        (rune >= 0x20d0 && rune <= 0x20ff) ||
        (rune >= 0xfe00 && rune <= 0xfe0f) ||
        (rune >= 0x1f3fb && rune <= 0x1f3ff) ||
        (rune >= 0xe0100 && rune <= 0xe01ef);
    if (combining && last >= 0 && !_ocrWhitespace(values[last])) {
      values[last] += value;
    } else {
      values.add(value);
    }
  }
  if (values.isEmpty || line.rect.width <= 0 || line.rect.height <= 0) {
    return const <_OcrUnit>[];
  }
  final double width = line.rect.width / values.length;
  return <_OcrUnit>[
    for (int i = 0; i < values.length; i++)
      _OcrUnit(
        value: values[i],
        rect: OcrRect(
          left: line.rect.left + width * i,
          top: line.rect.top,
          right: line.rect.left + width * (i + 1),
          bottom: line.rect.bottom,
        ),
        confidence: .22,
        synthetic: true,
      ),
  ];
}

bool _isCombiningRune(int rune) =>
    rune >= 0x0300 && rune <= 0x036f ||
    rune >= 0x1ab0 && rune <= 0x1aff ||
    rune >= 0x1dc0 && rune <= 0x1dff ||
    rune >= 0x20d0 && rune <= 0x20ff ||
    rune >= 0xfe00 && rune <= 0xfe0f ||
    rune >= 0xfe20 && rune <= 0xfe2f ||
    rune >= 0x1f3fb && rune <= 0x1f3ff ||
    rune >= 0xe0100 && rune <= 0xe01ef;

class _LineMatch {
  const _LineMatch({
    required this.lineIndex,
    required this.sourceStart,
    required this.sourceEnd,
    required this.pairs,
    required this.score,
  });
  final int lineIndex;
  final int sourceStart;
  final int sourceEnd;
  final List<_TokenPair> pairs;
  final double score;
}

double _visibleSourceCount(Iterable<_SourceUnit> units) =>
    units.where((u) => !u.whitespace && !u.newline).length.toDouble();

({double score, List<_TokenPair> pairs}) _alignSpan(
  List<_SourceUnit> source,
  int start,
  int end,
  List<_OcrUnit> tokens,
) {
  final int m = end - start, n = tokens.length;
  final List<List<double>> dp = List.generate(
    m + 1,
    (_) => List<double>.filled(n + 1, double.infinity),
  );
  final List<List<String?>> back = List.generate(
    m + 1,
    (_) => List<String?>.filled(n + 1, null),
  );
  dp[0][0] = 0;
  for (int i = 1; i <= m; i++) {
    dp[i][0] =
        dp[i - 1][0] +
        ((source[start + i - 1].whitespace || source[start + i - 1].newline)
            ? .035
            : .56);
    back[i][0] = 'source_gap';
  }
  for (int j = 1; j <= n; j++) {
    dp[0][j] = dp[0][j - 1] + .56;
    back[0][j] = 'ocr_gap';
  }
  for (int i = 1; i <= m; i++) {
    final _SourceUnit unit = source[start + i - 1];
    for (int j = 1; j <= n; j++) {
      final ({String kind, double cost}) relation =
          (unit.whitespace || unit.newline)
          ? (kind: 'whitespace_substitution', cost: .38)
          : _characterRelation(unit.value, tokens[j - 1].value);
      double best =
          dp[i - 1][j] + ((unit.whitespace || unit.newline) ? .035 : .56);
      String operation = 'source_gap';
      final double ocrGap = dp[i][j - 1] + .56;
      if (ocrGap < best) {
        best = ocrGap;
        operation = 'ocr_gap';
      }
      final double paired = dp[i - 1][j - 1] + relation.cost;
      if (paired < best) {
        best = paired;
        operation = relation.kind;
      }
      dp[i][j] = best;
      back[i][j] = operation;
    }
  }
  final List<_TokenPair> pairs = <_TokenPair>[];
  int i = m, j = n;
  while (i > 0 || j > 0) {
    final String? op = back[i][j];
    if (op == null) break;
    if (op == 'source_gap') {
      i--;
    } else if (op == 'ocr_gap') {
      j--;
    } else {
      pairs.add(_TokenPair(start + i - 1, j - 1, 0, op));
      i--;
      j--;
    }
  }
  final List<_TokenPair> ordered = pairs.reversed.toList();
  final double visible = _visibleSourceCount(source.sublist(start, end));
  final double pairedVisible = ordered
      .where((p) => !source[p.source].whitespace && !source[p.source].newline)
      .length
      .toDouble();
  final double coverage = pairedVisible / math.max(1, visible);
  final double ocrCoverage = ordered.length / math.max(1, n);
  final double score =
      dp[m][n] / math.max(1, math.max(visible, n)) +
      (1 - coverage) * .18 +
      (1 - ocrCoverage) * .10;
  return (score: score, pairs: ordered);
}

List<_OcrUnit> _lineOcrUnits(GalCalibrationOcrLine line) =>
    _ocrUnits(line).where((unit) => !_ocrWhitespace(unit.value)).toList();

bool _lineHasFixedTextAnchor(
  List<_SourceUnit> source,
  GalCalibrationOcrLine line,
) {
  final List<_OcrUnit> units = _lineOcrUnits(line);
  if (units.isEmpty) return false;
  for (final _OcrUnit observed in units) {
    for (final _SourceUnit expected in source) {
      if (!expected.whitespace &&
          !expected.newline &&
          _reliableRelation(
            _characterRelation(expected.value, observed.value).kind,
          )) {
        return true;
      }
    }
  }
  return false;
}

List<GalCalibrationOcrLine> _prepareOcrLines(
  List<_SourceUnit> source,
  List<GalCalibrationOcrLine> raw,
) => _mergeRowFragments(
  raw.where((line) => _lineHasFixedTextAnchor(source, line)).toList(),
);

List<_LineMatch> _lineCandidates(
  List<_SourceUnit> source,
  GalCalibrationOcrLine line,
  int lineIndex,
) {
  final List<_OcrUnit> tokens = _lineOcrUnits(line);
  if (tokens.isEmpty) return const <_LineMatch>[];
  final int tokenCount = tokens.length;
  final int minLength = math.max(1, tokenCount - 12);
  final int maxLength = math.min(source.length, tokenCount + 32);
  final List<_LineMatch> candidates = <_LineMatch>[];
  for (int start = 0; start < source.length; start++) {
    if (source[start].newline) continue;
    for (int length = minLength; length <= maxLength; length++) {
      final int end = start + length;
      if (end > source.length) break;
      final ({double score, List<_TokenPair> pairs}) aligned = _alignSpan(
        source,
        start,
        end,
        tokens,
      );
      final int visible = _visibleSourceCount(
        source.sublist(start, end),
      ).round();
      final int paired = aligned.pairs.length;
      final int minimumPairs = math
          .max(2, math.min(tokenCount, visible) * .22)
          .ceil();
      if (paired < minimumPairs) {
        continue;
      }
      if (!aligned.pairs.any(
        (pair) =>
            _reliableRelation(pair.kind) &&
            !source[pair.source].whitespace &&
            !source[pair.source].newline,
      )) {
        continue;
      }
      candidates.add(
        _LineMatch(
          lineIndex: lineIndex,
          sourceStart: start,
          sourceEnd: end,
          pairs: aligned.pairs,
          score: aligned.score,
        ),
      );
    }
  }
  candidates.sort(
    (a, b) => a.score != b.score
        ? a.score.compareTo(b.score)
        : b.pairs.length != a.pairs.length
        ? b.pairs.length.compareTo(a.pairs.length)
        : (a.sourceEnd - a.sourceStart) != (b.sourceEnd - b.sourceStart)
        ? (a.sourceEnd - a.sourceStart).compareTo(b.sourceEnd - b.sourceStart)
        : a.sourceStart.compareTo(b.sourceStart),
  );
  final List<_LineMatch> unique = <_LineMatch>[];
  final Set<String> seen = <String>{};
  for (final _LineMatch candidate in candidates) {
    final String key = '${candidate.sourceStart}:${candidate.sourceEnd}';
    if (!seen.add(key)) continue;
    unique.add(candidate);
    if (unique.length == 12) break;
  }
  return unique;
}

bool _forbiddenLineStart(String value) =>
    '、。，．！？!?：:；;、…‥⋯」』）)]｝〕〉》】］'.contains(value);

int? _firstVisibleSourcePosition(List<_SourceUnit> source, int start, int end) {
  for (int index = start; index < end; index++) {
    if (!source[index].whitespace && !source[index].newline) return index;
  }
  return null;
}

int? _lastVisibleSourcePosition(List<_SourceUnit> source, int start, int end) {
  for (int index = end - 1; index >= start; index--) {
    if (!source[index].whitespace && !source[index].newline) return index;
  }
  return null;
}

double _lineBoundaryPenalty(
  List<_SourceUnit> source,
  _LineMatch previous,
  _LineMatch candidate,
) {
  final int gapStart = previous.sourceEnd;
  final int gapEnd = candidate.sourceStart;
  final int? gapFirst = _firstVisibleSourcePosition(source, gapStart, gapEnd);
  final int? first =
      gapFirst ??
      _firstVisibleSourcePosition(
        source,
        candidate.sourceStart,
        candidate.sourceEnd,
      );
  final int? previousLast = _lastVisibleSourcePosition(
    source,
    previous.sourceStart,
    previous.sourceEnd,
  );
  if (first == null ||
      previousLast == null ||
      !_forbiddenLineStart(source[first].value)) {
    return 0;
  }
  return .86;
}

_OcrLineSelection? _selectOcrLineRun(
  List<_SourceUnit> source,
  List<GalCalibrationOcrLine> lines,
) {
  if (source.isEmpty || lines.isEmpty) return null;
  final List<List<_LineMatch>> candidates = <List<_LineMatch>>[
    for (int i = 0; i < lines.length; i++) _lineCandidates(source, lines[i], i),
  ];
  if (candidates.any((items) => items.isEmpty)) return null;
  Map<int, ({double cost, List<_LineMatch> path})> states = {
    0: (cost: 0, path: <_LineMatch>[]),
  };
  for (final List<_LineMatch> row in candidates) {
    final Map<int, ({double cost, List<_LineMatch> path})> next = {};
    for (final ({double cost, List<_LineMatch> path}) state in states.values) {
      for (final _LineMatch candidate in row) {
        if (state.path.isNotEmpty &&
            candidate.sourceStart < state.path.last.sourceEnd) {
          continue;
        }
        final int previousEnd = state.path.isEmpty
            ? 0
            : state.path.last.sourceEnd;
        // The Hook can include text before the captured sentence. Only gaps
        // between observed rows are correspondence evidence; penalising a
        // leading gap would prefer an incorrect, longer prefix match.
        final double gap = state.path.isEmpty
            ? 0
            : _visibleSourceCount(
                source.sublist(previousEnd, candidate.sourceStart),
              );
        final double total =
            state.cost +
            candidate.score +
            gap * .115 +
            (state.path.isEmpty
                ? 0
                : _lineBoundaryPenalty(source, state.path.last, candidate));
        final ({double cost, List<_LineMatch> path})? old =
            next[candidate.sourceEnd];
        if (old == null || total < old.cost) {
          next[candidate.sourceEnd] = (
            cost: total,
            path: <_LineMatch>[...state.path, candidate],
          );
        }
      }
    }
    if (next.isEmpty) return null;
    final List<MapEntry<int, ({double cost, List<_LineMatch> path})>> ordered =
        next.entries.toList()
          ..sort((a, b) => a.value.cost.compareTo(b.value.cost));
    states = {
      for (final MapEntry<int, ({double cost, List<_LineMatch> path})> item
          in ordered.take(32))
        item.key: item.value,
    };
  }
  final ({double cost, List<_LineMatch> path}) best = states.values.reduce((
    a,
    b,
  ) {
    final double aTail = _visibleSourceCount(
      source.sublist(a.path.isEmpty ? 0 : a.path.last.sourceEnd),
    );
    final double bTail = _visibleSourceCount(
      source.sublist(b.path.isEmpty ? 0 : b.path.last.sourceEnd),
    );
    return a.cost + aTail * .115 <= b.cost + bTail * .115 ? a : b;
  });
  if (best.path.isEmpty) return null;
  return (
    lines: List.unmodifiable([
      for (final _LineMatch match in best.path) lines[match.lineIndex],
    ]),
    spans: List.unmodifiable([
      for (final _LineMatch match in best.path)
        _LineSpan(match.sourceStart, match.sourceEnd),
    ]),
    score: best.cost / math.max(1, _visibleSourceCount(source)),
  );
}

/// Align OCR's imperfect text back to the exact Hook string and retain only
/// geometry-backed character hints. Recognition-frame positions are approximate;
/// text-only test/legacy callers may supply coarse uniformly spaced hints.
GalCalibrationOcrAlignment alignGalCalibrationOcrLines({
  required String sourceText,
  required List<GalCalibrationOcrLine> lines,
}) {
  final List<_SourceUnit> source = _sourceUnits(sourceText);
  if (source.length > 1024 || lines.length > 24) {
    return const GalCalibrationOcrAlignment(
      lines: [],
      confidence: 0,
      reason: 'ocr_region_too_large',
    );
  }
  final List<GalCalibrationOcrLine> usable = _prepareOcrLines(
    source,
    lines
        .where(
          (GalCalibrationOcrLine line) =>
              line.text.trim().isNotEmpty &&
              line.text.length <= 1024 &&
              line.score.isFinite &&
              line.rect.left.isFinite &&
              line.rect.top.isFinite &&
              line.rect.right.isFinite &&
              line.rect.bottom.isFinite &&
              line.rect.width > 0 &&
              line.rect.height > 0,
        )
        .toList(),
  );
  final _OcrLineSelection? selection = _selectOcrLineRun(source, usable);
  if (selection == null) {
    return GalCalibrationOcrAlignment(
      lines: <GalCalibrationOcrMatchedLine>[],
      confidence: 0,
      reason: usable.isEmpty
          ? 'ocr_anchor_insufficient'
          : 'text_correspondence_insufficient',
    );
  }
  final List<GalCalibrationOcrLine> selected = selection.lines;
  final List<_LineSpan> spans = selection.spans;
  final List<GalCalibrationOcrMatchedLine> matched = [];
  double confidence = 0;
  for (int lineIndex = 0; lineIndex < selected.length; lineIndex++) {
    final GalCalibrationOcrLine line = selected[lineIndex];
    final _LineSpan span = spans[lineIndex];
    final List<_OcrUnit> ocr = _lineOcrUnits(line);
    final List<_TokenPair> pairs = _alignSpan(
      source,
      span.start,
      span.end,
      ocr,
    ).pairs;
    final List<GalCalibrationOcrGlyph> glyphs = <GalCalibrationOcrGlyph>[];
    for (final _TokenPair pair in pairs) {
      final _SourceUnit sourceUnit = source[pair.source];
      final _OcrUnit ocrUnit = ocr[pair.ocr];
      final ({String kind, double cost}) relation = _characterRelation(
        sourceUnit.value,
        ocrUnit.value,
      );
      final double confidenceFactor = switch (relation.kind) {
        'exact' => 1.0,
        'normalised' => .95,
        'known_confusion' => .82,
        'punctuation_confusion' => .78,
        'ellipsis_confusion' => .75,
        _ => .45,
      };
      final int cellOffset = pair.source - span.start;
      glyphs.add(
        GalCalibrationOcrGlyph(
          sourceIndex: sourceUnit.index,
          charLength: sourceUnit.length,
          cellOffset: cellOffset,
          lineIndex: lineIndex,
          rect: ocrUnit.rect,
          confidence: ocrUnit.confidence * confidenceFactor,
          matchKind: pair.kind,
          ocrTokenIndex: ocrUnit.ocrTokenIndex,
          syntheticOcrPosition: ocrUnit.synthetic,
          ocrConfidence: ocrUnit.confidence,
          ocrText: ocrUnit.value,
        ),
      );
      confidence += ocrUnit.confidence * confidenceFactor;
    }
    matched.add(
      GalCalibrationOcrMatchedLine(
        sourceStart: span.start,
        sourceEnd: span.end,
        cellCount: span.end - span.start,
        lineIndex: lineIndex,
        rect: line.rect,
        glyphs: List.unmodifiable(glyphs),
        ocrScore: line.score,
        ocrTokenCount: line.tokens.isEmpty
            ? _ocrUnits(line).length
            : line.tokens.length,
      ),
    );
  }
  final int totalGlyphs = matched.fold<int>(
    0,
    (int count, GalCalibrationOcrMatchedLine line) =>
        count + line.glyphs.length,
  );
  final double normalized = totalGlyphs == 0 ? 0 : confidence / totalGlyphs;
  return GalCalibrationOcrAlignment(
    lines: List.unmodifiable(matched),
    confidence: normalized,
  );
}

// Detectors may split a horizontal row at spaces or changes of ink color.
// Join only nearby boxes on the same baseline; preserve measured token x's.
List<GalCalibrationOcrLine> _mergeRowFragments(
  List<GalCalibrationOcrLine> input,
) {
  if (input.isEmpty) return const <GalCalibrationOcrLine>[];
  final double rowHeight = _median(input.map((l) => l.rect.height).toList());
  final List<GalCalibrationOcrLine> ordered = input.toList()
    ..sort((a, b) => a.rect.centerY.compareTo(b.rect.centerY));
  final List<List<GalCalibrationOcrLine>> groups = [];
  for (final GalCalibrationOcrLine line in ordered) {
    if (groups.isNotEmpty) {
      final List<GalCalibrationOcrLine> group = groups.last;
      final double top = group.map((l) => l.rect.top).reduce(math.min);
      final double bottom = group.map((l) => l.rect.bottom).reduce(math.max);
      final double overlap = math.max(
        0,
        math.min(bottom, line.rect.bottom) - math.max(top, line.rect.top),
      );
      final double minHeight = math.max(
        1,
        math.min(bottom - top, line.rect.height),
      );
      if (overlap / minHeight >= .25 ||
          ((top + bottom) / 2 - line.rect.centerY).abs() <=
              math.max(4, rowHeight * .42)) {
        group.add(line);
        continue;
      }
    }
    groups.add([line]);
  }
  return [
    for (final List<GalCalibrationOcrLine> group in groups) _mergeOneRow(group),
  ];
}

GalCalibrationOcrLine _mergeOneRow(List<GalCalibrationOcrLine> row) {
  if (row.length == 1) return row.single;
  final List<_OcrUnit> tokens = [for (final line in row) ..._ocrUnits(line)]
    ..sort(
      (a, b) => a.rect.centerX != b.rect.centerX
          ? a.rect.centerX.compareTo(b.rect.centerX)
          : a.rect.centerY.compareTo(b.rect.centerY),
    );
  return GalCalibrationOcrLine(
    text: tokens.map((t) => t.value).join(),
    rect: OcrRect(
      left: row.map((l) => l.rect.left).reduce(math.min),
      right: row.map((l) => l.rect.right).reduce(math.max),
      top: row.map((l) => l.rect.top).reduce(math.min),
      bottom: row.map((l) => l.rect.bottom).reduce(math.max),
    ),
    score: _median(row.map((l) => l.score).toList()),
    tokens: [
      for (final token in tokens)
        GalCalibrationOcrToken(
          token.value,
          token.rect,
          token.confidence,
          synthetic: token.synthetic,
        ),
    ],
  );
}

double _median(List<double> values) {
  if (values.isEmpty) return double.nan;
  values.sort();
  final int middle = values.length ~/ 2;
  return values.length.isOdd
      ? values[middle]
      : (values[middle - 1] + values[middle]) / 2;
}

/// Translate frozen screenshot geometry into the reusable native grid. The
/// algorithm owns cells; this adapter checks that a regular runtime layout can
/// reproduce them and leaves all previous settings untouched on failure.
Future<GalCalibrationImageFit> fitGalCalibrationOcrGrid(
  GalLookupCalibrationDraft draft,
  List<GalCalibrationOcrAlignment> alignments, {
  required GalCalibrationPreviewBuilder build,
}) async {
  if (alignments.length != draft.samples.length || alignments.isEmpty) {
    return const GalCalibrationImageFit(reason: 'ocr_anchor_insufficient');
  }
  final List<List<_SourceUnit>> sources = [
    for (final sample in draft.samples) _sourceUnits(sample.capture.sourceText),
  ];
  final List<Map<String, dynamic>?> geometries = [];
  final List<int> training = [];
  int? reference;
  int referenceAnchors = -1;
  for (int i = 0; i < alignments.length; i++) {
    if (!alignments[i].accepted) {
      return GalCalibrationImageFit(
        reason: alignments[i].reason ?? 'ocr_anchor_insufficient',
        sampleIndex: i,
      );
    }
    final GalLookupReferenceClientV1 client =
        draft.samples[i].capture.referenceClient;
    final Map<String, dynamic> geometry = _v24FitGeometry(
      _V24GeometryInput(
        source: sources[i],
        alignment: alignments[i],
        selection: OcrRect(
          left: draft.searchRect.left * client.widthPx,
          top: draft.searchRect.top * client.heightPx,
          right: draft.searchRect.right * client.widthPx,
          bottom: draft.searchRect.bottom * client.heightPx,
        ),
        imageWidth: client.widthPx.toDouble(),
        imageHeight: client.heightPx.toDouble(),
      ),
    );
    if (geometry['ok'] != true) {
      // A one-row sample can validate a grid established by another sample;
      // it cannot manufacture a line spacing on its own.
      if (alignments[i].lines.length == 1 &&
          (geometry['reason'] == 'line_spacing_insufficient' ||
              geometry['reason'] == 'geometry_evidence_insufficient')) {
        geometries.add(null);
        continue;
      }
      return GalCalibrationImageFit(
        reason:
            geometry['reason'] as String? ?? 'geometry_evidence_insufficient',
        sampleIndex: i,
      );
    }
    geometries.add(geometry);
    if (!draft.samples[i].validation) {
      training.add(i);
      final int anchors = alignments[i].lines
          .expand((line) => line.glyphs)
          .where(
            (g) =>
                _reliableRelation(g.matchKind) &&
                !g.syntheticOcrPosition &&
                !_isPitchException(
                  draft.samples[i].capture.sourceText.substring(
                    g.sourceIndex,
                    g.sourceIndex + g.charLength,
                  ),
                ),
          )
          .length;
      if (anchors > referenceAnchors) {
        reference = i;
        referenceAnchors = anchors;
      }
    }
  }
  if (reference == null) {
    return const GalCalibrationImageFit(reason: 'line_spacing_insufficient');
  }
  final Map<String, dynamic> geometry = geometries[reference]!;
  final GalLookupCalibrationCapture referenceCapture =
      draft.samples[reference].capture;
  final GalLookupReferenceClientV1 refClient = referenceCapture.referenceClient;
  final double pxPitch = (geometry['pitch'] as num).toDouble();
  final double pxHeight = (geometry['cellHeight'] as num).toDouble();
  final double pxLineAdvance = (geometry['lineAdvance'] as num).toDouble();
  final List<double> origins = (geometry['origins'] as List)
      .map((v) => (v as num).toDouble())
      .toList();
  final double pitch = pxPitch / refClient.heightPx;
  final double height = pxHeight / refClient.heightPx;
  final double lineAdvance = pxLineAdvance / refClient.heightPx;
  final double indent = ((origins[1] - origins[0]) / pxPitch).roundToDouble();
  final double firstColumn = math.max(0, -indent);
  final double tailColumn = math.max(0, indent);
  final double left = (origins[0] - firstColumn * pxPitch) / refClient.widthPx;
  final List<GalCalibrationOcrMatchedLine> referenceLines =
      alignments[reference].lines;
  final double top = _median([
    for (int row = 0; row < referenceLines.length; row++)
      (referenceLines[row].rect.centerY - pxHeight / 2 - row * pxLineAdvance) /
          refClient.heightPx,
  ]);
  if (pxHeight > pxLineAdvance ||
      indent.abs() > 1 ||
      !pitch.isFinite ||
      !top.isFinite ||
      !left.isFinite) {
    return GalCalibrationImageFit(
      reason: 'ocr_geometry_conflict',
      detail: 'runtime_grid_not_representable',
      sampleIndex: reference,
    );
  }
  final List<_OcrRowEnd> rowEnds = [];
  bool trimWrapWhitespace = false;
  double observedHeight = 0;
  for (final int index in training) {
    final List<_SourceUnit> source = sources[index];
    final Map<String, dynamic> fitted = geometries[index]!;
    final List<dynamic> ranges = fitted['renderRanges'] as List;
    if (ranges.isEmpty) {
      return GalCalibrationImageFit(
        reason: 'text_correspondence_insufficient',
        sampleIndex: index,
      );
    }
    final Set<int> covered = {};
    for (int row = 0; row < ranges.length; row++) {
      final Map<dynamic, dynamic> range = ranges[row] as Map;
      final int start = (range['sourceStart'] as num).toInt();
      final int end = (range['sourceEnd'] as num).toInt();
      if (end <= start || start < 0 || end > source.length) {
        return GalCalibrationImageFit(
          reason: 'text_correspondence_insufficient',
          sampleIndex: index,
        );
      }
      covered.addAll(Iterable<int>.generate(end - start, (i) => start + i));
      final bool softWrap =
          row + 1 < ranges.length &&
          end < source.length &&
          !source[end].newline &&
          !source[end].hardBreakBefore;
      if (softWrap) {
        final int nextStart = ((ranges[row + 1] as Map)['sourceStart'] as num)
            .toInt();
        if (nextStart > end &&
            nextStart <= source.length &&
            source.sublist(end, nextStart).every((unit) => unit.whitespace)) {
          trimWrapWhitespace = true;
        }
      }
      rowEnds.add((
        width:
            (row == 0 ? firstColumn : tailColumn) +
            source.sublist(start, end).where((u) => !u.newline).length,
        lastWidth: 1,
        nextWidth: 1,
        softWrap: softWrap,
        punctuation: _hangingPunctuation(source[end - 1].value),
        sample: index,
      ));
    }
    // A screenshot's local span is valid algorithm input, but an incomplete
    // Hook sentence cannot establish a reusable runtime layout for the hidden
    // prefix/suffix. Preserve the pure result and return an explicit adapter
    // failure rather than shifting the visible text to the wrong indices.
    if (Iterable<int>.generate(source.length).any(
      (i) =>
          !source[i].whitespace && !source[i].newline && !covered.contains(i),
    )) {
      return GalCalibrationImageFit(
        reason: 'text_correspondence_insufficient',
        detail: 'runtime_source_not_fully_observed',
        sampleIndex: index,
      );
    }
    observedHeight = math.max(
      observedHeight,
      (ranges.length - 1) * lineAdvance + height,
    );
  }
  final ({double width, bool hanging})? capacity;
  if (rowEnds.any((row) => row.softWrap)) {
    capacity = _fitOcrRowCapacity(rowEnds);
  } else {
    final double longest = rowEnds.map((row) => row.width).reduce(math.max);
    final double selected =
        (draft.searchRect.right - left) * refClient.widthPx / pxPitch;
    final double width = math.max(longest, selected.floorToDouble());
    capacity = width >= 2 && width <= 128
        ? (width: width, hanging: false)
        : null;
  }
  if (capacity == null) {
    return const GalCalibrationImageFit(
      reason: 'ocr_geometry_conflict',
      detail: 'runtime_line_breaks_inconsistent',
    );
  }
  final int columns = capacity.width.ceil();
  final GalLookupCellGridV1 grid = GalLookupCellGridV1(
    advancePerClientHeight: pitch,
    lineAdvancePerClientHeight: lineAdvance,
    cellHeightPerClientHeight: height,
    columns: columns,
    lineWidthInCells: capacity.width == columns ? null : capacity.width,
    continuationIndent: indent,
    quotedContinuationIndent: indent,
    hangingPunctuation: capacity.hanging,
    trimWrapWhitespace: trimWrapWhitespace,
  );
  final int rows = math.max(
    referenceLines.length,
    ((draft.searchRect.bottom - top - height) / lineAdvance).ceil() + 1,
  );
  final double bodyHeight = math.max(
    observedHeight,
    (rows - 1) * lineAdvance + height,
  );
  final GalLookupNormalizedRectV1 rect = GalLookupNormalizedRectV1(
    left: left,
    top: top,
    width:
        ((capacity.width + (capacity.hanging ? 1 : 0)) * pxPitch + 1) /
        refClient.widthPx,
    height: math.min(1 - top, bodyHeight + 1 / refClient.heightPx),
  );
  final GalLookupTextLayoutV1 layout = GalLookupTextLayoutV1(
    fontFamily: draft.layout.fontFamily,
    fontSizePerClientHeight: draft.layout.fontSizePerClientHeight,
    letterSpacingPerClientHeight: draft.layout.letterSpacingPerClientHeight,
    lineHeight: draft.layout.lineHeight,
    textAlign: draft.layout.textAlign,
    verticalAlign: draft.layout.verticalAlign,
    paddingPerClientHeight: draft.layout.paddingPerClientHeight,
    cellGrid: grid,
    quotedTextOnly: draft.layout.quotedTextOnly,
  );
  if (!rect.isValid || !layout.isValid) {
    return const GalCalibrationImageFit(reason: 'selection_out_of_bounds');
  }
  final GalLookupCalibrationDraft result = GalLookupCalibrationDraft(
    rect: rect,
    searchRect: draft.searchRect,
    layout: layout,
    samples: draft.samples,
    slot: draft.slot,
    layoutReferenceClient: refClient,
    layoutCaptureMetadata: referenceCapture.captureMetadata,
  );
  for (int i = 0; i < draft.samples.length; i++) {
    final GalLookupCalibrationCapture capture = draft.samples[i].capture;
    final GalCalibrationPreview preview = await build(
      text: capture.sourceText,
      client: capture.referenceClient,
      rect: rect,
      layout: layout,
    );
    if (!preview.accepted) {
      return GalCalibrationImageFit(
        reason: 'ocr_geometry_conflict',
        detail: preview.reason ?? 'empty_preview',
        sampleIndex: i,
      );
    }
    final Map<String, dynamic>? expected = geometries[i];
    if (expected != null) {
      final double samplePitch = (expected['pitch'] as num).toDouble();
      // Hook breaks fix the rows; leave small OCR/grid offsets for manual edit.
      final bool approximateHardBreakGrid = _rowsFollowHookLineBreaks(
        sources[i],
        expected['renderRanges'] as List<dynamic>,
      );
      final Map<int, double> nativeRowTops = <int, double>{};
      for (final dynamic item in expected['boxes'] as List) {
        final Map<dynamic, dynamic> cell = item as Map;
        final int index = (cell['sourceIndex'] as num).toInt();
        final GalCalibrationBox? actual = preview.boxForIndex(index);
        if (actual == null ||
            actual.charIndex != index ||
            actual.charLength != (cell['length'] as num).toInt()) {
          return GalCalibrationImageFit(
            reason: 'ocr_geometry_conflict',
            detail: 'runtime_glyph_index_mismatch',
            sampleIndex: i,
          );
        }
        if (approximateHardBreakGrid) {
          final int row = (cell['line'] as num).toInt();
          final double? rowTop = nativeRowTops[row];
          if (rowTop != null && (actual.rect.top - rowTop).abs() > 2) {
            return GalCalibrationImageFit(
              reason: 'ocr_geometry_conflict',
              detail: 'runtime_row_breaks_differ_from_hook',
              sampleIndex: i,
            );
          }
          nativeRowTops[row] = actual.rect.top;
        }
        final double x = (cell['left'] as num).toDouble();
        final double y = (cell['top'] as num).toDouble();
        // Native bounds round to physical pixels; this is a translation check,
        // not a second OCR fitter allowed to reinterpret the selected grid.
        final double tolerance = math.max(2, samplePitch * .08);
        if (!approximateHardBreakGrid &&
            ((actual.rect.left - x).abs() > tolerance ||
                (actual.rect.top - y).abs() > tolerance ||
                (actual.rect.width - (cell['width'] as num)).abs() >
                    tolerance ||
                (actual.rect.height - (cell['height'] as num)).abs() >
                    tolerance)) {
          return GalCalibrationImageFit(
            reason: 'ocr_geometry_conflict',
            detail: 'runtime_grid_differs_from_fitted_cells',
            sampleIndex: i,
          );
        }
      }
      if (approximateHardBreakGrid) {
        final List<int> rows = nativeRowTops.keys.toList()..sort();
        if (rows.length != (expected['renderRanges'] as List).length ||
            rows.first != 0 ||
            rows.last != rows.length - 1 ||
            Iterable<int>.generate(rows.length - 1).any(
              (index) =>
                  nativeRowTops[rows[index + 1]]! <=
                  nativeRowTops[rows[index]]!,
            )) {
          return GalCalibrationImageFit(
            reason: 'ocr_geometry_conflict',
            detail: 'runtime_row_breaks_differ_from_hook',
            sampleIndex: i,
          );
        }
      }
    } else {
      for (final GalCalibrationOcrMatchedLine line in alignments[i].lines) {
        for (final GalCalibrationOcrGlyph glyph in line.glyphs) {
          if (!_reliableRelation(glyph.matchKind) ||
              glyph.syntheticOcrPosition ||
              _isPitchException(
                capture.sourceText.substring(
                  glyph.sourceIndex,
                  glyph.sourceIndex + glyph.charLength,
                ),
              )) {
            continue;
          }
          final GalCalibrationBox? box = preview.boxForIndex(glyph.sourceIndex);
          if (box == null ||
              (box.rect.center.dy - glyph.rect.centerY).abs() >
                  height * capture.referenceClient.heightPx * .5 + 1 ||
              (box.rect.center.dx - glyph.rect.centerX).abs() >
                  pitch * capture.referenceClient.heightPx * .5 + 1) {
            return GalCalibrationImageFit(
              reason: 'ocr_geometry_conflict',
              detail: 'validation_anchor_mismatch',
              sampleIndex: i,
            );
          }
        }
      }
    }
  }
  return GalCalibrationImageFit(draft: result);
}

bool _hangingPunctuation(String value) =>
    value.runes.length == 1 &&
    '」』）)]｝}】〕〉》、。，．！？!?ぁぃぅぇぉっゃゅょゎァィゥェォッャュョヮヵヶ'.contains(value);

/// Frozen calibration algorithm. OCR supplies evidence, never replacement text.
/// Geometry values and all three diagnostic layers use full-image pixels.
@visibleForTesting
Map<String, dynamic> fitGalCalibrationV24({
  required String sourceText,
  required List<GalCalibrationOcrLine> lines,
  required OcrRect selection,
  required GalLookupReferenceClientV1 client,
}) {
  if (!selection.left.isFinite ||
      !selection.top.isFinite ||
      !selection.right.isFinite ||
      !selection.bottom.isFinite ||
      selection.width <= 0 ||
      selection.height <= 0 ||
      selection.left < 0 ||
      selection.top < 0 ||
      selection.right > client.widthPx ||
      selection.bottom > client.heightPx) {
    return {'ok': false, 'reason': 'selection_out_of_bounds'};
  }
  final GalCalibrationOcrAlignment alignment = alignGalCalibrationOcrLines(
    sourceText: sourceText,
    lines: lines,
  );
  if (!alignment.accepted) {
    return {'ok': false, 'reason': alignment.reason};
  }
  return _v24FitGeometry(
    _V24GeometryInput(
      source: _sourceUnits(sourceText),
      alignment: alignment,
      selection: selection,
      imageWidth: client.widthPx.toDouble(),
      imageHeight: client.heightPx.toDouble(),
    ),
  );
}

class GalCalibrationOcrEngine {
  GalCalibrationOcrEngine._({required this.detector, required this.recognizer});

  @visibleForTesting
  GalCalibrationOcrEngine.forTesting({
    required PpOcrLineDetector detector,
    required PpOcrLineRecognizer recognizer,
  }) : this._(detector: detector, recognizer: recognizer);

  final PpOcrLineDetector detector;
  final PpOcrLineRecognizer recognizer;

  static Future<GalCalibrationOcrEngine> create({
    required Directory directory,
    OcrSessionFactory Function()? factoryBuilder,
  }) async {
    final OcrSessionFactory Function()? builder =
        factoryBuilder ?? ocrSessionFactoryBuilder;
    if (builder == null) throw StateError('ocr_session_factory_unavailable');
    final OcrSessionFactory factory = builder();
    Set<OcrExecutionProvider> available = const <OcrExecutionProvider>{};
    try {
      available = await factory.availableAcceleratedProviders();
    } catch (_) {
      // Calibration is a best-effort CPU job; provider probing must not block it.
    }
    final List<OcrExecutionProvider> detectionProviders =
        selectOcrExecutionProviders(
          kind: OcrModelKind.detection,
          platform: Platform.isWindows
              ? OcrPlatform.windows
              : Platform.isMacOS
              ? OcrPlatform.macos
              : Platform.isAndroid
              ? OcrPlatform.android
              : Platform.isIOS
              ? OcrPlatform.ios
              : OcrPlatform.linux,
          availableProviders: available,
        );
    final List<OcrExecutionProvider> recognitionProviders =
        selectOcrExecutionProviders(
          kind: OcrModelKind.recognition,
          platform: Platform.isWindows
              ? OcrPlatform.windows
              : Platform.isMacOS
              ? OcrPlatform.macos
              : Platform.isAndroid
              ? OcrPlatform.android
              : Platform.isIOS
              ? OcrPlatform.ios
              : OcrPlatform.linux,
          availableProviders: available,
        );
    final OcrSession detSession = await factory.createSession(
      p.join(directory.path, kPpOcrDetFileName),
      providers: detectionProviders,
    );
    OcrSession? recSession;
    try {
      recSession = await factory.createSession(
        p.join(directory.path, kPpOcrRecFileName),
        providers: recognitionProviders,
      );
      final String dict = await File(
        p.join(directory.path, kPpOcrRecDictFileName),
      ).readAsString();
      return GalCalibrationOcrEngine._(
        detector: PpOcrLineDetector(detSession),
        recognizer: PpOcrLineRecognizer(
          recSession,
          vocab: buildPpOcrCtcVocab(parsePpOcrCharacterDict(dict)),
        ),
      );
    } catch (_) {
      try {
        await recSession?.close();
      } finally {
        await detSession.close();
      }
      rethrow;
    }
  }

  Future<List<GalCalibrationOcrLine>> read(
    Uint8List pngBytes,
    GalLookupNormalizedRectV1 rect,
    GalLookupReferenceClientV1 client,
  ) async {
    final img.Image? decoded = await compute(img.decodePng, pngBytes);
    if (decoded == null ||
        decoded.width != client.widthPx ||
        decoded.height != client.heightPx) {
      throw const FormatException('ocr_capture_decode_failed');
    }
    // The visible search selection is authoritative. Never silently scan
    // names/buttons outside it to compensate for a clipped selection.
    final GalLookupNormalizedRectV1 searchRect = rect;
    final int left = (searchRect.left * decoded.width).floor().clamp(
      0,
      decoded.width - 1,
    );
    final int top = (searchRect.top * decoded.height).floor().clamp(
      0,
      decoded.height - 1,
    );
    final int right = (searchRect.right * decoded.width).ceil().clamp(
      left + 1,
      decoded.width,
    );
    final int bottom = (searchRect.bottom * decoded.height).ceil().clamp(
      top + 1,
      decoded.height,
    );
    final img.Image crop = img.copyCrop(
      decoded,
      x: left,
      y: top,
      width: right - left,
      height: bottom - top,
    );
    final int detectorPadding = _ocrEdgePadding(
      crop,
      maxPadding: _kMaxDetectorCropPadding,
    );
    final ({img.Image image, int padding}) detectorInput =
        _copyWithReplicatedEdge(crop, detectorPadding);
    // Manga's median-thickness filter can delete a short dialogue row.
    // Text matching below determines which detected rows belong to the Hook.
    final List<({PpTextLine line, OcrRect unpaddedRect})> detected =
        [
            for (final PpTextLine paddedLine in await detector.detect(
              detectorInput.image,
            ))
              if (_unpaddedDetectorRect(
                    paddedLine.rect,
                    detectorInput.padding,
                  ).clamp(crop.width.toDouble(), crop.height.toDouble()).width >
                  0)
                (
                  line: PpTextLine(
                    rect: _unpaddedDetectorRect(
                      paddedLine.rect,
                      detectorInput.padding,
                    ).clamp(crop.width.toDouble(), crop.height.toDouble()),
                    score: paddedLine.score,
                  ),
                  unpaddedRect: _unpaddedDetectorRect(
                    paddedLine.rect,
                    detectorInput.padding,
                  ),
                ),
          ]
          ..removeWhere((({PpTextLine line, OcrRect unpaddedRect}) item) {
            return item.line.vertical || item.line.rect.height <= 0;
          })
          ..sort(
            (
              ({PpTextLine line, OcrRect unpaddedRect}) a,
              ({PpTextLine line, OcrRect unpaddedRect}) b,
            ) => a.line.rect.centerY.compareTo(b.line.rect.centerY),
          );
    final List<GalCalibrationOcrLine> result = <GalCalibrationOcrLine>[];
    for (final ({PpTextLine line, OcrRect unpaddedRect}) detectedLine
        in detected) {
      final PpTextLine line = detectedLine.line;
      final int x = detectedLine.unpaddedRect.left.floor().clamp(
        0,
        crop.width - 1,
      );
      final int y = detectedLine.unpaddedRect.top.floor().clamp(
        0,
        crop.height - 1,
      );
      final int r = detectedLine.unpaddedRect.right.ceil().clamp(
        x + 1,
        crop.width,
      );
      final int b = detectedLine.unpaddedRect.bottom.ceil().clamp(
        y + 1,
        crop.height,
      );
      final img.Image lineCrop = img.copyCrop(
        crop,
        x: x,
        y: y,
        width: r - x,
        height: b - y,
      );
      final int linePadding = _ocrEdgePadding(
        lineCrop,
        maxPadding: _kMaxRecognizerLinePadding,
      );
      final ({img.Image image, int padding}) lineInput =
          _copyWithReplicatedEdge(lineCrop, linePadding);
      final PpOcrLineRecognition recognition = await recognizer
          .recognizeLineDetailed(lineInput.image);
      final String text = recognition.text;
      if (text.trim().isEmpty) continue;
      result.add(
        GalCalibrationOcrLine(
          text: text,
          rect: OcrRect(
            left: left + line.rect.left,
            top: top + line.rect.top,
            right: left + line.rect.right,
            bottom: top + line.rect.bottom,
          ),
          score: line.score,
          tokens: <GalCalibrationOcrToken>[
            for (final PpOcrCtcToken token in recognition.tokens)
              GalCalibrationOcrToken(
                token.text,
                OcrRect(
                  left:
                      left +
                      x +
                      (token.left == null
                          ? 0
                          : token.left! - lineInput.padding),
                  top: (top + y).toDouble(),
                  right:
                      left +
                      x +
                      (token.right == null
                          ? 0
                          : token.right! - lineInput.padding),
                  bottom: (top + b).toDouble(),
                ).clamp(decoded.width.toDouble(), decoded.height.toDouble()),
                token.hasPosition ? token.confidence : 0,
              ),
          ],
        ),
      );
    }
    return result;
  }

  Future<void> close() async {
    try {
      await recognizer.close();
    } finally {
      await detector.close();
    }
  }
}

const int _kMaxDetectorCropPadding = 8;
const int _kMaxRecognizerLinePadding = 4;

int _ocrEdgePadding(img.Image image, {required int maxPadding}) {
  final int shortest = math.min(image.width, image.height);
  return math.min(maxPadding, math.max(2, shortest ~/ 24));
}

/// Adds a small synthetic context made only from the crop's own edge pixels.
///
/// This is deliberately edge replication rather than an expanded source crop:
/// the selected rectangle remains the only source of real pixels.
({img.Image image, int padding}) _copyWithReplicatedEdge(
  img.Image source,
  int padding,
) {
  final img.Image result = img.Image(
    width: source.width + padding * 2,
    height: source.height + padding * 2,
    numChannels: 4,
  );
  for (int y = 0; y < result.height; y++) {
    final int sourceY = (y - padding).clamp(0, source.height - 1);
    for (int x = 0; x < result.width; x++) {
      final int sourceX = (x - padding).clamp(0, source.width - 1);
      final img.Pixel pixel = source.getPixel(sourceX, sourceY);
      result.setPixelRgba(x, y, pixel.r, pixel.g, pixel.b, pixel.a);
    }
  }
  return (image: result, padding: padding);
}

OcrRect _unpaddedDetectorRect(OcrRect rect, int padding) => OcrRect(
  left: rect.left - padding,
  top: rect.top - padding,
  right: rect.right - padding,
  bottom: rect.bottom - padding,
);

class GalCalibrationOcrRunner {
  GalCalibrationOcrRunner({
    GalCalibrationOcrModelStore? models,
    OcrSessionFactory Function()? factoryBuilder,
  }) : models = models ?? GalCalibrationOcrModelStore(),
       _factoryBuilder = factoryBuilder;

  final GalCalibrationOcrModelStore models;
  final OcrSessionFactory Function()? _factoryBuilder;
  bool _fitting = false;

  Future<GalCalibrationImageFit?> fit(
    GalLookupCalibrationDraft draft, {
    required GalCalibrationPreviewBuilder build,
  }) async {
    if (_fitting) return const GalCalibrationImageFit(reason: 'ocr_busy');
    _fitting = true;
    GalCalibrationOcrEngine? engine;
    try {
      final GalCalibrationOcrModelStatus status = await models.status();
      if (!status.ready) return null;
      engine = await GalCalibrationOcrEngine.create(
        directory: await models.directory(),
        factoryBuilder: _factoryBuilder,
      );
      final List<GalCalibrationOcrAlignment> alignments =
          <GalCalibrationOcrAlignment>[];
      for (int i = 0; i < draft.samples.length; i++) {
        final GalCalibrationSample sample = draft.samples[i];
        final List<GalCalibrationOcrLine> lines = await engine.read(
          sample.capture.pngBytes,
          draft.searchRect,
          sample.capture.referenceClient,
        );
        if (lines.isEmpty) {
          return GalCalibrationImageFit(
            reason: 'ocr_lines_not_found',
            sampleIndex: i,
          );
        }
        final GalCalibrationOcrAlignment alignment = await compute(
          _alignCapturedLines,
          (text: sample.capture.sourceText, lines: lines),
        );
        if (!alignment.accepted) {
          return GalCalibrationImageFit(
            reason: alignment.reason,
            sampleIndex: i,
          );
        }
        alignments.add(alignment);
      }
      return await fitGalCalibrationOcrGrid(draft, alignments, build: build);
    } finally {
      // A fit owns both sessions, including error/closed-dialog paths. No
      // unbounded app-global native session cache or concurrent use/disposal.
      try {
        await engine?.close();
      } finally {
        _fitting = false;
      }
    }
  }
}

GalCalibrationOcrAlignment _alignCapturedLines(
  ({String text, List<GalCalibrationOcrLine> lines}) input,
) => alignGalCalibrationOcrLines(sourceText: input.text, lines: input.lines);

final GalCalibrationOcrRunner defaultGalCalibrationOcrRunner =
    GalCalibrationOcrRunner();

Future<GalCalibrationOcrModelInfo> _calibrationOcrModelStatus() async {
  final GalCalibrationOcrModelStatus status =
      await defaultGalCalibrationOcrRunner.models.status();
  return GalCalibrationOcrModelInfo(
    ready: status.ready,
    obtainedBytes: status.obtainedBytes,
    totalBytes: status.totalBytes,
  );
}

Stream<GalCalibrationOcrDownloadProgress> _downloadCalibrationOcrModels() {
  return defaultGalCalibrationOcrRunner.models.download().map(
    (MangaOcrDownloadEvent event) => GalCalibrationOcrDownloadProgress(
      fileName: event.fileName,
      receivedBytes: event.receivedBytes,
      totalBytes: event.totalBytes,
      done: event.done,
    ),
  );
}

/// Called once by the Flutter host after the ORT bindings are installed.
void installGalCalibrationOcrAssist() {
  galCalibrationOcrAssist = defaultGalCalibrationOcrRunner.fit;
  galCalibrationOcrModelStatus = _calibrationOcrModelStatus;
  galCalibrationOcrModelDownloader = _downloadCalibrationOcrModels;
}
