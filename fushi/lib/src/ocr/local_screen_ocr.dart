/// 桌面应用外悬浮球「截屏识字」在 Linux 上的识别器。
///
/// Linux 没有系统 OCR（macOS Vision / Windows.Media.Ocr / Android ML Kit 那一档），
/// 所以截屏识字改用 Fushi 自己的本机 OCR 模型（设置里的漫画 OCR 本机模型，离线、
/// 不上传）。走「整帧当一块文字图」那条现成路径（[MangaOcrTextImageSession]：PP 行
/// 检测 + 逐行识别，不加载漫画检测器）——图形字幕整轨识别同一个入口；Steam Deck
/// 实测（2026-11-04，游戏画面 40 帧）中位约 0.5 s。
///
/// 对外仍是 [SystemOcrPlatform]：冻结层、命中测试、查词那一整套不分平台。模型没下
/// 载时抛 [SystemOcrUnavailableException]（[kSystemOcrModelUnavailableReason]），宿主
/// 在冻结层提示条上让用户去设置里下载。
///
/// 会话常驻复用（建会话约 0.7 s），空闲 [idleTimeout] 后关掉释放 ORT 内存。
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
    final OcrRecognition result;
    try {
      result = await session.recognizeTextImage(
        frame.rgba,
        width: frame.width,
        height: frame.height,
      );
    } finally {
      _armIdleTimer();
    }
    return systemOcrPageFromRecognition(
      result,
      width: frame.width,
      height: frame.height,
    );
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
    for (int i = 0; i < texts.length && i < boxes.length; i++) {
      final String text = texts[i].trim();
      final OcrRect box = boxes[i];
      if (text.isEmpty || box.right <= box.left || box.bottom <= box.top) {
        continue;
      }
      lines.add(
        SystemOcrTextLine(
          text: text,
          rect: Rect.fromLTRB(box.left, box.top, box.right, box.bottom),
          isVertical: result.vertical,
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
