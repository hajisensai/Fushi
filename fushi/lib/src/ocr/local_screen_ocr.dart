/// 桌面应用外悬浮球「截屏识字」的本机模型识别器：截屏识字引擎解析到本机模型时用它
/// （`screen_ocr_engine.dart`；Linux 没有系统 OCR，只能用它或 Lens）。
///
/// 用 Fushi 自己的本机 OCR 模型（设置里的 OCR 本机模型，离线、不上传），走「整帧
/// 当一块文字图」那条现成路径（[MangaOcrTextImageSession]：PP 行检测 + 逐行识别，
/// 不加载漫画检测器）——图形字幕整轨识别同一个入口；Steam Deck
/// 实测（2026-11-04，游戏画面 40 帧）中位约 0.5 s。
///
/// 对外仍是 [SystemOcrPlatform]：冻结层、命中测试、查词那一整套不分平台。模型没下
/// 载时抛 [SystemOcrUnavailableException]（[kSystemOcrModelUnavailableReason]），宿主
/// 在冻结层提示条上让用户去设置里下载。
///
/// 会话常驻复用（建会话约 0.7 s），空闲 [idleTimeout] 后关掉释放 ORT 内存。空闲
/// 计时只在没有识别在跑时走：关会话会让在跑的识别失败。
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';
import 'package:fushi/src/ocr/system_ocr_channel.dart';
import 'package:fushi_engine/ocr/manga_ocr_service.dart';
import 'package:fushi_engine/ocr/ocr_types.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

/// 一帧截图的像素上限（宽 × 高）：8K 以内。
const int kLocalScreenOcrMaxPixels = 7680 * 4320;

class LocalScreenOcr implements SystemOcrPlatform {
  LocalScreenOcr(
    this._service, {
    Directory? workDir,
    this.idleTimeout = const Duration(minutes: 1),
  }) : _workDir =
           workDir ??
           Directory(p.join(Directory.systemTemp.path, 'fushi_screen_ocr'));

  final MangaOcrService _service;
  final Directory _workDir;
  final Duration idleTimeout;

  Future<MangaOcrPageSession>? _session;
  Timer? _idleTimer;
  int _running = 0;

  @override
  Future<bool> isAvailable() async {
    final MangaOcrService service = _service;
    if (service is! MangaOcrPageService || !service.isSupportedPlatform) {
      return false;
    }
    return (await service.modelStatus()).recognizerReady;
  }

  /// [language] 不用：本机模型按日文训练，没有按语言挑识别器这一步。
  @override
  Future<SystemOcrPageResult> recognize(
    Uint8List imageBytes, {
    required String language,
    List<Rect> tiles = const <Rect>[],
  }) async {
    _idleTimer?.cancel();
    _idleTimer = null;
    _running++;
    try {
      if (!await isAvailable()) {
        throw const SystemOcrUnavailableException(
          kSystemOcrModelUnavailableReason,
        );
      }
      final _Rgba? frame = await Isolate.run(() => _decodeRgba(imageBytes));
      if (frame == null) {
        throw const FormatException('screenshot could not be decoded');
      }
      final MangaOcrTextImageSession session = await _textSession();
      final OcrRecognition result = await session.recognizeTextImage(
        frame.rgba,
        width: frame.width,
        height: frame.height,
      );
      return systemOcrPageFromRecognition(
        result,
        width: frame.width,
        height: frame.height,
      );
    } finally {
      _running--;
      if (_running == 0 && _session != null) _armIdleTimer();
    }
  }

  /// 释放会话（宿主销毁时）。
  Future<void> dispose() async {
    _idleTimer?.cancel();
    _idleTimer = null;
    await _closeSession();
  }

  Future<MangaOcrTextImageSession> _textSession() async {
    final Future<MangaOcrPageSession> session = _session ??= () async {
      await _workDir.create(recursive: true);
      return (_service as MangaOcrPageService).openPageSession(
        imageDirPath: _workDir.path,
        textImagesOnly: true,
      );
    }();
    try {
      final MangaOcrPageSession opened = await session;
      if (opened is! MangaOcrTextImageSession) {
        throw StateError('OCR session cannot read text images');
      }
      return opened as MangaOcrTextImageSession;
    } on Object {
      // 建会话失败不缓存：下次重建（模型可能刚下载好）。
      if (identical(_session, session)) _session = null;
      rethrow;
    }
  }

  void _armIdleTimer() {
    _idleTimer?.cancel();
    _idleTimer = Timer(idleTimeout, () => unawaited(_closeSession()));
  }

  Future<void> _closeSession() async {
    final Future<MangaOcrPageSession>? session = _session;
    _session = null;
    if (session == null) return;
    try {
      await (await session).close();
    } on Object {
      // 建会话本就失败了：没有可关的。
    }
  }
}

/// 识别结果 → 冻结层要的行（截图像素坐标）。有行几何时逐行给出；识别器只给了整块
/// 文字时退成一行、框为整张图（点哪都查这段文字的开头附近，好过什么都点不到）。
///
/// 识别器给了逐字命中格（[OcrRecognition.glyphBoxes]，区间按各行无分隔拼接记）时，
/// 切到各行、换成行内区间作词框（[SystemOcrTextLine.segments]）：点字按字格定位，
/// 与 Windows OCR 的词框同一条路径（BUG-4367），不再按整行等分估计。
@visibleForTesting
SystemOcrPageResult systemOcrPageFromRecognition(
  OcrRecognition result, {
  required int width,
  required int height,
}) {
  final List<SystemOcrTextLine> lines = <SystemOcrTextLine>[];
  final List<String>? texts = result.lines;
  final List<OcrRect>? boxes = result.lineBoxes;
  if (texts != null && boxes != null) {
    final List<OcrGlyphBox>? glyphs = result.glyphBoxes;
    int offset = 0;
    for (int i = 0; i < texts.length && i < boxes.length; i++) {
      final String raw = texts[i];
      final int lineStart = offset;
      offset += raw.length;
      final String text = raw.trim();
      final OcrRect box = boxes[i];
      if (text.isEmpty || box.right <= box.left || box.bottom <= box.top) {
        continue;
      }
      // trim 掉的行首空白：字格区间要跟着左移。
      final int lead = raw.length - raw.trimLeft().length;
      lines.add(
        SystemOcrTextLine(
          text: text,
          rect: Rect.fromLTRB(box.left, box.top, box.right, box.bottom),
          isVertical: result.vertical,
          segments: glyphs == null
              ? const <SystemOcrTextSegment>[]
              : _lineSegments(
                  glyphs,
                  from: lineStart + lead,
                  textLength: text.length,
                ),
        ),
      );
    }
  } else if (result.text.trim().isNotEmpty) {
    lines.add(
      SystemOcrTextLine(
        text: result.text.trim(),
        rect: Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
        isVertical: result.vertical,
      ),
    );
  }
  return SystemOcrPageResult(
    lines: lines,
    imageWidth: width,
    imageHeight: height,
  );
}

/// 落在 `[from, from + textLength)` 里的字格 → 行内区间的词框（按序、互不重叠；
/// 不满足的整行不带词框，退回按行等分）。
List<SystemOcrTextSegment> _lineSegments(
  List<OcrGlyphBox> glyphs, {
  required int from,
  required int textLength,
}) {
  final List<SystemOcrTextSegment> out = <SystemOcrTextSegment>[];
  int cursor = 0;
  for (final OcrGlyphBox glyph in glyphs) {
    final int start = glyph.start - from;
    final int end = glyph.end - from;
    if (start < 0 || end > textLength) continue;
    final OcrRect r = glyph.rect;
    if (r.right <= r.left || r.bottom <= r.top) continue;
    if (start < cursor || end <= start) return const <SystemOcrTextSegment>[];
    out.add(
      SystemOcrTextSegment(
        start: start,
        length: end - start,
        rect: Rect.fromLTRB(r.left, r.top, r.right, r.bottom),
      ),
    );
    cursor = end;
  }
  return out;
}

class _Rgba {
  const _Rgba(this.rgba, this.width, this.height);

  final Uint8List rgba;
  final int width;
  final int height;
}

/// null = not an image, truncated, or too large. The image package throws
/// (RangeError etc.) on malformed data instead of returning null.
_Rgba? _decodeRgba(Uint8List bytes) {
  final img.Image? image;
  try {
    final img.Decoder? decoder = img.findDecoderForData(bytes);
    if (decoder == null) return null;
    final img.DecodeInfo? info = decoder.startDecode(bytes);
    if (info == null || info.width * info.height > kLocalScreenOcrMaxPixels) {
      return null;
    }
    image = decoder.decode(bytes);
  } on Object {
    return null;
  }
  if (image == null) return null;
  final img.Image rgba = image.convert(numChannels: 4);
  return _Rgba(
    rgba.getBytes(order: img.ChannelOrder.rgba),
    rgba.width,
    rgba.height,
  );
}
