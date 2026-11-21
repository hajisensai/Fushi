/// 服务端拒收一句（[TtsFailureCode.rejected]，HTTP 400/404/422）时拆开再合成。
///
/// 起因（反馈 d53TITyrPq）：自建 VPTTS 0.7.1 对恰好 86 字的整句固定返回 400
/// `unsupported_text`（「Text contains no pronounceable speech」），同一句重发多少次
/// 都一样；Fushi 分句上限是 200，句子本身没问题，是服务端对某些长度 / 写法的判定
/// 有缺陷。以前这类拒收只能停在那一句、提示用户，「重试」还是同一段文字，必然
/// 再失败，整本书在每个这样的句子上都要人工跳过。
///
/// 做法：同一段文字原样重发没有意义，但把它在最自然的停顿处拆成两半、各自合成、
/// 再按原顺序拼回同一段音频，对这类「服务端对整句判定有缺陷」的拒收几乎总能成功；
/// 播放器、缓存、cue 时间轴都只看到一段完整的句子音频，句内高亮的词边界按拆分
/// 位置平移回原句坐标。
///
/// 约束（不掩盖真实错误）：
/// - 只处理 [TtsFailureCode.rejected]；鉴权 / 网络 / 5xx / 未配置等照旧原样上报。
/// - 只拆到 [kTtsRejectSplitDepth] 层（最多 4 段）；太短（< [kTtsRejectSplitMinLength]）
///   或拆不出两段都含可读字符的文本不拆——真的「没有可读内容」的句子拆了也没用。
/// - 只拼接参数完全相同的 WAV（PCM / float，fmt 块逐字节一致）；MP3 等不能无损
///   拼接的格式不拆，照旧上报。自建服务（OpenAI 兼容 / VOICEVOX / GPT-SoVITS /
///   Irodori）都出 WAV，正是会遇到这类拒收的那一批。
/// - 任一段在拆到底后仍被拒：上报**原句**最初的那次拒收（调用方照旧停下提示），
///   不跳句、不吞失败。
///
/// 这也是**所有经引擎合成一句的唯一入口**（朗读调度、整书制作、补配、漫画配音、
/// Galgame 台词朗读、制作台 / 声音设置试听、制卡兜底）：纯标点 / 符号句
/// （[ttsTextIsSilent]，「……」「！」「♪」）在这里写一段静音、不送引擎——有的引擎对
/// 这种句子直接 400 拒收，拆也拆不出可读的片段，以前每个调用点各判一遍，漏判的入口
/// 就把它记成「未配音」失败。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_engine/tts/tts_direction.dart';
import 'package:fushi_engine/tts/tts_provider.dart';
import 'package:fushi_engine/tts/tts_silence.dart';
import 'package:fushi_engine/tts/tts_types.dart';

/// 被拒后最多拆几层（2 层 = 最多 4 段）。
const int kTtsRejectSplitDepth = 2;

/// 短于此长度（UTF-16 码元，去首尾空白）的文本被拒不再拆。
const int kTtsRejectSplitMinLength = 12;

/// 合成 [text]；服务端拒收时按停顿拆开分别合成，再拼回一段写到 [outputPath]。
/// 纯标点句（[ttsTextIsSilent]）不送引擎，写一段静音（[writeTtsSilentLine]）。
///
/// [direction] 只对整句生效；拆开的片段只保留种子（给定时长是整句的，不能原样
/// 套给半句）。
Future<TtsResult> ttsSynthesizeSplittingOnReject(
  TtsProvider provider,
  String text, {
  required String outputPath,
  required TtsCancelToken cancel,
  TtsDirection direction = TtsDirection.none,
}) async {
  if (ttsTextIsSilent(text)) {
    cancel.throwIfCancelled();
    return writeTtsSilentLine(text, outputPath);
  }
  try {
    return await synthesizeWithDirection(
      provider,
      text,
      outputPath: outputPath,
      cancel: cancel,
      direction: direction,
    );
  } on TtsFailure catch (original) {
    if (original.code != TtsFailureCode.rejected) rethrow;
    final TtsDirection pieceDirection = TtsDirection(seed: direction.seed);
    final _TtsPieceAudio? merged;
    try {
      merged = await _synthesizeSplit(
        provider,
        text,
        outputPath: outputPath,
        cancel: cancel,
        direction: pieceDirection,
        depth: kTtsRejectSplitDepth,
      );
    } on _TtsUnsplittable {
      throw original;
    } on TtsFailure catch (failure) {
      // 拆到底仍被拒：报原句的拒收。取消、断网等照实上报。
      if (failure.code == TtsFailureCode.rejected) throw original;
      rethrow;
    }
    if (merged == null) rethrow;
    await File(outputPath).writeAsBytes(merged.wav, flush: true);
    return TtsResult(format: TtsAudioFormat.wav, boundaries: merged.boundaries);
  }
}

/// 拆成两段分别合成并拼接；拆不开返回 null。片段再被拒时继续往下拆（[depth] 层内）。
Future<_TtsPieceAudio?> _synthesizeSplit(
  TtsProvider provider,
  String text, {
  required String outputPath,
  required TtsCancelToken cancel,
  required TtsDirection direction,
  required int depth,
}) async {
  if (depth <= 0) return null;
  final ({String head, String tail})? halves = splitTtsTextForRejection(text);
  if (halves == null) return null;
  final List<String> pieces = <String>[halves.head, halves.tail];
  final List<_TtsPieceAudio> audios = <_TtsPieceAudio>[];
  for (int i = 0; i < pieces.length; i++) {
    cancel.throwIfCancelled();
    final String piecePath = '$outputPath.$i.part';
    try {
      audios.add(
        await _synthesizePiece(
          provider,
          pieces[i],
          outputPath: piecePath,
          cancel: cancel,
          direction: direction,
          depth: depth - 1,
        ),
      );
    } finally {
      final File file = File(piecePath);
      if (await file.exists()) {
        try {
          await file.delete();
        } on FileSystemException {
          // 缓存目录里的残留 .part 由缓存层的淘汰扫掉。
        }
      }
    }
  }
  // 片段文本去过首尾空白：词边界要平移回 [text] 的坐标。
  final _TtsPieceAudio? merged = _concatWavPieces(
    audios[0],
    audios[1],
    headTextOffset: text.length - text.trimLeft().length,
    tailTextOffset: text.trimRight().length - halves.tail.length,
  );
  if (merged == null) {
    throw const _TtsUnsplittable();
  }
  return merged;
}

/// 合成一段；被拒且还能拆就继续拆，拆不开 / 拼不起来则把拒收抛给上层。
Future<_TtsPieceAudio> _synthesizePiece(
  TtsProvider provider,
  String text, {
  required String outputPath,
  required TtsCancelToken cancel,
  required TtsDirection direction,
  required int depth,
}) async {
  try {
    final TtsResult result = await synthesizeWithDirection(
      provider,
      text,
      outputPath: outputPath,
      cancel: cancel,
      direction: direction,
    );
    final Uint8List bytes = await File(outputPath).readAsBytes();
    final _TtsPieceAudio? piece = _TtsPieceAudio.parse(
      bytes,
      result.boundaries,
    );
    if (piece == null) {
      // 不是可拼接的 WAV（MP3 等）：没法无损拼回一段，整句按被拒处理。
      throw const _TtsUnsplittable();
    }
    return piece;
  } on TtsFailure catch (failure) {
    if (failure.code != TtsFailureCode.rejected) rethrow;
    final _TtsPieceAudio? merged = await _synthesizeSplit(
      provider,
      text,
      outputPath: outputPath,
      cancel: cancel,
      direction: direction,
      depth: depth,
    );
    if (merged == null) rethrow;
    return merged;
  }
}

/// 在最自然的停顿处把 [text] 拆成两段（纯函数）；拆不出两段都含可读字符时返回 null。
///
/// 优先级：句末标点（。！？…，连同紧跟的闭合括号）> 读点 / 逗号（、，,；;：:）>
/// 闭合括号 / 空白 > 正中间硬切。同一级里取离中点最近的位置；切点让较短的一段
/// 不足全长 1/5 时视为太偏、改看下一级（拆的目的是避开服务端对整句的判定，
/// 一头只剩一两个字的拆法起不到作用）。
({String head, String tail})? splitTtsTextForRejection(String text) {
  final String trimmed = text.trim();
  if (trimmed.length < kTtsRejectSplitMinLength) return null;
  final int n = trimmed.length;
  final int minPiece = n ~/ 5;
  bool usable(int cut) =>
      cut >= minPiece &&
      n - cut >= minPiece &&
      _speakable.hasMatch(trimmed.substring(0, cut)) &&
      _speakable.hasMatch(trimmed.substring(cut));

  int? best(Iterable<int> cuts) {
    int? chosen;
    for (final int cut in cuts) {
      if (!usable(cut)) continue;
      if (chosen == null || (cut - n / 2).abs() < (chosen - n / 2).abs()) {
        chosen = cut;
      }
    }
    return chosen;
  }

  // 切点 = 前一段的长度；紧跟的闭合括号归前一段。
  Iterable<int> cutsAfter(RegExp marks) sync* {
    for (int i = 0; i < n - 1; i++) {
      if (!marks.hasMatch(trimmed[i])) continue;
      int cut = i + 1;
      while (cut < n && _closers.hasMatch(trimmed[cut])) {
        cut++;
      }
      if (cut < n && marks.hasMatch(trimmed[cut])) continue; // 连续标点取最后一个
      yield cut;
    }
  }

  int? cut =
      best(cutsAfter(_sentenceEnds)) ??
      best(cutsAfter(_pauses)) ??
      best(cutsAfter(_softBreaks));
  if (cut == null) {
    int mid = n ~/ 2;
    // 不切开代理对。
    if (_isLowSurrogate(trimmed.codeUnitAt(mid))) mid++;
    if (usable(mid)) cut = mid;
  }
  if (cut == null) return null;
  final String head = trimmed.substring(0, cut).trim();
  final String tail = trimmed.substring(cut).trim();
  if (head.isEmpty || tail.isEmpty) return null;
  return (head: head, tail: tail);
}

final RegExp _speakable = RegExp(r'[\p{L}\p{N}]', unicode: true);
final RegExp _sentenceEnds = RegExp(r'[。．！？!?…‥]');
final RegExp _pauses = RegExp(r'[、，,；;：:]');
final RegExp _softBreaks = RegExp(r'[」』）)】〉》\s　]');
final RegExp _closers = RegExp(r'[」』）)】〉》"”’]');

/// 片段音频没法无损拼回一段（不是 WAV / 两段参数不同）：再拆也没用，直接报原句被拒。
class _TtsUnsplittable implements Exception {
  const _TtsUnsplittable();
}

bool _isLowSurrogate(int unit) => unit >= 0xDC00 && unit <= 0xDFFF;

/// 一段可拼接的 WAV：fmt 块原样 + 数据区 + 按本段坐标的词边界。
class _TtsPieceAudio {
  _TtsPieceAudio._(
    this.fmt,
    this.data,
    this.byteRate,
    this.blockAlign,
    this.boundaries,
  );

  final Uint8List fmt;
  final Uint8List data;
  final int byteRate;
  final int blockAlign;
  final List<TtsBoundary> boundaries;

  int get durationMs => (data.length * 1000 / byteRate).round();

  Uint8List get wav {
    final int fmtPad = fmt.length.isOdd ? 1 : 0;
    final int dataPad = data.length.isOdd ? 1 : 0;
    final int riffSize =
        4 + 8 + fmt.length + fmtPad + 8 + data.length + dataPad;
    final BytesBuilder b = BytesBuilder(copy: false);
    final ByteData u32 = ByteData(4);
    void ascii(String s) => b.add(s.codeUnits);
    void le32(int v) {
      u32.setUint32(0, v, Endian.little);
      b.add(Uint8List.fromList(u32.buffer.asUint8List()));
    }

    ascii('RIFF');
    le32(riffSize);
    ascii('WAVE');
    ascii('fmt ');
    le32(fmt.length);
    b.add(fmt);
    if (fmtPad == 1) b.addByte(0);
    ascii('data');
    le32(data.length);
    b.add(data);
    if (dataPad == 1) b.addByte(0);
    return b.toBytes();
  }

  /// 解析 PCM（1）/ float（3）/ extensible（0xFFFE）WAV；其它格式返回 null。
  static _TtsPieceAudio? parse(Uint8List bytes, List<TtsBoundary> boundaries) {
    if (bytes.length < 12 ||
        String.fromCharCodes(bytes, 0, 4) != 'RIFF' ||
        String.fromCharCodes(bytes, 8, 12) != 'WAVE') {
      return null;
    }
    final ByteData view = ByteData.sublistView(bytes);
    Uint8List? fmt;
    int offset = 12;
    while (offset + 8 <= bytes.length) {
      final String id = String.fromCharCodes(bytes, offset, offset + 4);
      int size = view.getUint32(offset + 4, Endian.little);
      final int body = offset + 8;
      if (id == 'fmt ') {
        if (size < 16 || body + size > bytes.length) return null;
        fmt = Uint8List.fromList(bytes.sublist(body, body + size));
      } else if (id == 'data') {
        if (fmt == null) return null;
        final ByteData f = ByteData.sublistView(fmt);
        final int tag = f.getUint16(0, Endian.little);
        if (tag != 1 && tag != 3 && tag != 0xFFFE) return null;
        final int byteRate = f.getUint32(8, Endian.little);
        final int blockAlign = f.getUint16(12, Endian.little);
        if (byteRate <= 0 || blockAlign <= 0) return null;
        // 流式写出的 WAV 常把 data 长度写成 0 或 0xFFFFFFFF：按实际剩余字节算。
        final int available = bytes.length - body;
        if (size == 0 || size > available) size = available;
        size -= size % blockAlign; // 只取整帧，拼接后声道不错位
        if (size <= 0) return null;
        return _TtsPieceAudio._(
          fmt,
          Uint8List.fromList(bytes.sublist(body, body + size)),
          byteRate,
          blockAlign,
          boundaries,
        );
      }
      offset = body + size + (size.isOdd ? 1 : 0);
    }
    return null;
  }
}

/// 把 [head]、[tail] 两段 WAV 拼成一段；参数不同返回 null（纯函数）。
/// [headTextOffset] / [tailTextOffset] 是两段在合并文本里的起点，用来平移词边界。
_TtsPieceAudio? _concatWavPieces(
  _TtsPieceAudio head,
  _TtsPieceAudio tail, {
  required int headTextOffset,
  required int tailTextOffset,
}) {
  if (!_sameBytes(head.fmt, tail.fmt)) return null;
  final int headMs = head.durationMs;
  return _TtsPieceAudio._(
    head.fmt,
    Uint8List.fromList(<int>[...head.data, ...tail.data]),
    head.byteRate,
    head.blockAlign,
    <TtsBoundary>[
      for (final TtsBoundary b in head.boundaries)
        TtsBoundary(
          textOffset: b.textOffset + headTextOffset,
          textLength: b.textLength,
          offsetMs: b.offsetMs,
          durationMs: b.durationMs,
        ),
      for (final TtsBoundary b in tail.boundaries)
        TtsBoundary(
          textOffset: b.textOffset + tailTextOffset,
          textLength: b.textLength,
          offsetMs: b.offsetMs + headMs,
          durationMs: b.durationMs,
        ),
    ],
  );
}

bool _sameBytes(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
