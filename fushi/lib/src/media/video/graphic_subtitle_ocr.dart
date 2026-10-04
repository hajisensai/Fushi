/// 图形字幕（PGS / VobSub / DVB）查词：暂停时把当前帧连同 libmpv 自绘的字幕位图
/// 截下来做 OCR，把识别出的文字摆回画面上原位，点字即查词。
///
/// 图形字幕轨由 libmpv 直接画进画面，Dart 侧没有 cue（见
/// `VideoPlayerController.isPlayerRenderedSubtitleActive`），以前这一模式下只能看
/// 不能查。这里不另起一套 OCR：直接复用漫画在线直读的页级识别
/// （[prepareMangaStreamOcr]）——同一个引擎偏好、同一个 Lens 上传同意闸门，置信度
/// 低的块同样交给 [MangaStreamAiRefinement] 用视觉大模型重读（只在用户给「漫画
/// OCR」功能分配了 AI 供应商时启用，与漫画同一开关）。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Offset, Rect, Size;

import 'package:characters/characters.dart';
import 'package:flutter/painting.dart'
    show Alignment, BoxFit, FittedSizes, applyBoxFit;
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/manga/reader/manga_reader_stream_ocr.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';

/// 识别不可用的原因（[GraphicSubtitleOcrUnavailable.reason]）。
enum GraphicSubtitleOcrUnavailableReason {
  /// 本机没有可用的 OCR 引擎。
  noEngine,

  /// 选中的是 Lens，用户拒绝了上传同意。
  lensDeclined,

  /// 当前平台不支持选中的引擎。
  unsupported,
}

/// [GraphicSubtitleOcrSession.recognize] 在引擎不可用时抛出。
class GraphicSubtitleOcrUnavailable implements Exception {
  const GraphicSubtitleOcrUnavailable(this.reason);

  final GraphicSubtitleOcrUnavailableReason reason;

  @override
  String toString() => 'GraphicSubtitleOcrUnavailable($reason)';
}

/// 一个可点的字：所属整句、句内字素下标、在**帧图像素**坐标系下的矩形。
typedef GraphicSubtitleOcrChar = ({
  String sentence,
  int graphemeIndex,
  Rect rect,
});

/// 一帧的识别结果：帧图尺寸 + 可点的字。
class GraphicSubtitleOcrFrame {
  const GraphicSubtitleOcrFrame({required this.imageSize, required this.chars});

  final Size imageSize;
  final List<GraphicSubtitleOcrChar> chars;

  bool get isEmpty => chars.isEmpty;
}

/// 识别器构造：给一个临时目录，交回引擎（与 [prepareMangaStreamOcr] 同形）。
typedef GraphicSubtitleOcrPrepare =
    Future<MangaStreamOcrSetup> Function(String workDirPath);

/// 一次播放会话内的图形字幕识别器：引擎只解析一次，识别串行执行。
///
/// 每帧落成唯一文件名（递增序号）——本地 ONNX 页会话按相对 URL 缓存结果，同名
/// 文件会命中上一帧的旧结果。
class GraphicSubtitleOcrSession {
  GraphicSubtitleOcrSession({required GraphicSubtitleOcrPrepare prepare})
    : _prepare = prepare;

  final GraphicSubtitleOcrPrepare _prepare;
  Directory? _dir;
  Future<MangaStreamOcrSetup>? _setup;
  Future<void> _tail = Future<void>.value();
  int _frameSeq = 0;
  bool _closed = false;

  bool get isClosed => _closed;

  /// 识别一帧 [frameBytes]（PNG/JPEG）。本地结果直接返回；有 AI 重读时，重读出的
  /// 新结果经 [onRefined] 再交一次（没有替换任何块则不回调）。会话已关闭返回 null。
  Future<GraphicSubtitleOcrFrame?> recognize(
    Uint8List frameBytes, {
    void Function(GraphicSubtitleOcrFrame refined)? onRefined,
    void Function(Object error, StackTrace stack)? onRefineError,
  }) {
    final Completer<GraphicSubtitleOcrFrame?> done =
        Completer<GraphicSubtitleOcrFrame?>();
    _tail = _tail.then((_) async {
      try {
        done.complete(
          await _recognizeOne(frameBytes, onRefined, onRefineError),
        );
      } catch (error, stack) {
        done.completeError(error, stack);
      }
    });
    return done.future;
  }

  /// 识别一张图并**等待** AI 重读（整轨生成用：要的是最终文字，不是先给后换）。
  /// 返回重读后的页（没有替换任何块则是本地页）；会话已关闭返回 null。AI 失败时
  /// 保留本地文字，错误交 [onRefineError]。
  Future<MokuroImage?> recognizePage(
    Uint8List imageBytes, {
    void Function(Object error, StackTrace stack)? onRefineError,
  }) {
    final Completer<MokuroImage?> done = Completer<MokuroImage?>();
    _tail = _tail.then((_) async {
      try {
        done.complete(await _recognizePageOne(imageBytes, onRefineError));
      } catch (error, stack) {
        done.completeError(error, stack);
      }
    });
    return done.future;
  }

  Future<MokuroImage?> _recognizePageOne(
    Uint8List imageBytes,
    void Function(Object error, StackTrace stack)? onRefineError,
  ) async {
    if (_closed) return null;
    final MangaStreamOcrReady ready = await _ensureReady();
    if (_closed) return null;
    final File file = File(p.join(_dir!.path, 'frame_${_frameSeq++}.png'));
    await file.writeAsBytes(imageBytes, flush: true);
    try {
      final MokuroImage local = await ready.recognizer.recognize(file);
      final MangaStreamAiRefinement? ai = ready.ai;
      if (ai == null || _closed) return local;
      try {
        return await ai.refine(local, file) ?? local;
      } catch (error, stack) {
        onRefineError?.call(error, stack);
        return local;
      }
    } finally {
      await _deleteQuietly(file);
    }
  }

  Future<GraphicSubtitleOcrFrame?> _recognizeOne(
    Uint8List frameBytes,
    void Function(GraphicSubtitleOcrFrame refined)? onRefined,
    void Function(Object error, StackTrace stack)? onRefineError,
  ) async {
    if (_closed) return null;
    final MangaStreamOcrReady ready = await _ensureReady();
    if (_closed) return null;
    final File file = File(p.join(_dir!.path, 'frame_${_frameSeq++}.png'));
    await file.writeAsBytes(frameBytes, flush: true);
    final MokuroImage local = await ready.recognizer.recognize(file);
    final MangaStreamAiRefinement? ai = ready.ai;
    if (ai == null || _closed) {
      await _deleteQuietly(file);
      return graphicSubtitleOcrFrameOf(local);
    }
    // AI 重读不阻塞本地结果：先交本地文字层，重读完再热替换。
    unawaited(
      ai
          .refine(local, file)
          .then(
            (MokuroImage? refined) {
              if (refined != null && !_closed) {
                onRefined?.call(graphicSubtitleOcrFrameOf(refined));
              }
            },
            onError: (Object error, StackTrace stack) {
              if (!_closed) onRefineError?.call(error, stack);
            },
          )
          .whenComplete(() => _deleteQuietly(file)),
    );
    return graphicSubtitleOcrFrameOf(local);
  }

  Future<MangaStreamOcrReady> _ensureReady() async {
    final Future<MangaStreamOcrSetup> setup = _setup ??= _open();
    final MangaStreamOcrSetup resolved;
    try {
      resolved = await setup;
    } catch (_) {
      // 引擎探测本身出错（不是「没有引擎」）：下一次重新探测，而不是永远记住这次失败。
      if (identical(_setup, setup)) _setup = null;
      rethrow;
    }
    return switch (resolved) {
      MangaStreamOcrReady() => resolved,
      MangaStreamOcrNoEngine() => throw const GraphicSubtitleOcrUnavailable(
        GraphicSubtitleOcrUnavailableReason.noEngine,
      ),
      MangaStreamOcrLensDeclined() => throw const GraphicSubtitleOcrUnavailable(
        GraphicSubtitleOcrUnavailableReason.lensDeclined,
      ),
      MangaStreamOcrUnsupported() => throw const GraphicSubtitleOcrUnavailable(
        GraphicSubtitleOcrUnavailableReason.unsupported,
      ),
    };
  }

  Future<MangaStreamOcrSetup> _open() async {
    final Directory dir = _dir ??= await Directory.systemTemp.createTemp(
      'fushi_graphic_sub_ocr_',
    );
    return _prepare(dir.path);
  }

  /// 关闭识别器、中止 AI 请求并删除临时目录。幂等。
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final Future<MangaStreamOcrSetup>? setup = _setup;
    if (setup != null) {
      try {
        final MangaStreamOcrSetup resolved = await setup;
        if (resolved is MangaStreamOcrReady) {
          resolved.ai?.cancel();
          await resolved.recognizer.close();
        }
      } catch (_) {
        // 引擎探测失败：没有需要关闭的识别器。
      }
    }
    final Directory? dir = _dir;
    if (dir != null) {
      try {
        await dir.delete(recursive: true);
      } on FileSystemException {
        // 临时目录，删不掉留给系统清理。
      }
    }
  }
}

Future<void> _deleteQuietly(File file) async {
  try {
    await file.delete();
  } on FileSystemException {
    // 临时文件，随会话目录一起删。
  }
}

/// 把一页 OCR 结果摊成可点的字。
GraphicSubtitleOcrFrame graphicSubtitleOcrFrameOf(MokuroImage image) {
  final List<GraphicSubtitleOcrChar> chars = <GraphicSubtitleOcrChar>[
    for (final MokuroBlock block in image.blocks)
      ...graphicSubtitleOcrCharsOf(block),
  ];
  return GraphicSubtitleOcrFrame(
    imageSize: Size(image.size.width, image.size.height),
    chars: chars,
  );
}

/// 一个块里每个字的位置。整句是块内各行直接拼接（与漫画查词同一口径）。
///
/// 引擎给了字级区域（Lens）且覆盖全部字素时用它；否则按行把块均分（横排自上而下、
/// 竖排自右向左），行内按字素数沿主轴均分——字幕是单字体等宽排版，均分足够准。
List<GraphicSubtitleOcrChar> graphicSubtitleOcrCharsOf(MokuroBlock block) {
  final String sentence = block.lines.join();
  if (sentence.trim().isEmpty) return const <GraphicSubtitleOcrChar>[];
  final List<GraphicSubtitleOcrChar>? fromRegions = _charsFromRegions(
    block,
    sentence,
  );
  if (fromRegions != null) return fromRegions;
  final List<GraphicSubtitleOcrChar> out = <GraphicSubtitleOcrChar>[];
  final MokuroRect box = block.rectangle;
  final int lineCount = block.lines.length;
  int graphemeBase = 0;
  for (int line = 0; line < lineCount; line++) {
    final List<String> graphemes = block.lines[line].characters.toList();
    final Rect lineRect = _lineSlice(box, line, lineCount, block.isVertical);
    for (int i = 0; i < graphemes.length; i++) {
      if (graphemes[i].trim().isNotEmpty) {
        out.add((
          sentence: sentence,
          graphemeIndex: graphemeBase + i,
          rect: _charSlice(lineRect, i, graphemes.length, block.isVertical),
        ));
      }
    }
    graphemeBase += graphemes.length;
  }
  return out;
}

List<GraphicSubtitleOcrChar>? _charsFromRegions(
  MokuroBlock block,
  String sentence,
) {
  final List<MangaOcrTextRegion>? regions = block.regions;
  if (regions == null || regions.isEmpty) return null;
  // UTF-16 起点 → 字素下标。
  final Map<int, int> graphemeAtUtf16 = <int, int>{};
  int offset = 0;
  int index = 0;
  for (final String g in sentence.characters) {
    graphemeAtUtf16[offset] = index++;
    offset += g.length;
  }
  final List<GraphicSubtitleOcrChar> out = <GraphicSubtitleOcrChar>[];
  for (final MangaOcrTextRegion region in regions) {
    final int? grapheme = graphemeAtUtf16[region.utf16Start];
    // 区域与文字对不上（例如 AI 改写过文字）：整块退回均分。
    if (grapheme == null || region.utf16End > sentence.length) return null;
    final MokuroRect r = region.rectangle;
    out.add((
      sentence: sentence,
      graphemeIndex: grapheme,
      rect: Rect.fromLTRB(r.left, r.top, r.right, r.bottom),
    ));
  }
  return out;
}

Rect _lineSlice(MokuroRect box, int line, int count, bool vertical) {
  if (vertical) {
    // 竖排：第一行在最右。
    final double w = (box.right - box.left) / count;
    final double right = box.right - w * line;
    return Rect.fromLTRB(right - w, box.top, right, box.bottom);
  }
  final double h = (box.bottom - box.top) / count;
  final double top = box.top + h * line;
  return Rect.fromLTRB(box.left, top, box.right, top + h);
}

Rect _charSlice(Rect line, int index, int count, bool vertical) {
  if (vertical) {
    final double h = line.height / count;
    return Rect.fromLTWH(line.left, line.top + h * index, line.width, h);
  }
  final double w = line.width / count;
  return Rect.fromLTWH(line.left + w * index, line.top, w, line.height);
}

/// 帧图像素矩形 → 视频控件内的本地矩形。
///
/// 画面按 [fit] 居中摆进 [viewSize]；宽高比取 [displaySize]（播放器报告的显示尺寸，
/// 已含非方形像素校正），帧图坐标先按 [imageSize] 归一化——截图分辨率与显示尺寸
/// 不同（变形片源 / 缩放截图）时仍落在画面上的正确位置。
Rect graphicSubtitleImageRectToView({
  required Rect imageRect,
  required Size imageSize,
  required Size displaySize,
  required Size viewSize,
  required BoxFit fit,
}) {
  if (imageSize.isEmpty || viewSize.isEmpty) return Rect.zero;
  final Size source = displaySize.isEmpty ? imageSize : displaySize;
  // applyBoxFit 给的是「源子区域 → 目标区域」：cover 会裁源、destination 恒为视口。
  // 整帧的实际绘制尺寸 = 源尺寸 × (destination / 源子区域)，再居中（可超出视口）。
  final FittedSizes fitted = applyBoxFit(fit, source, viewSize);
  if (fitted.source.isEmpty) return Rect.zero;
  final Size painted = Size(
    source.width * fitted.destination.width / fitted.source.width,
    source.height * fitted.destination.height / fitted.source.height,
  );
  final Rect frame = Alignment.center.inscribe(painted, Offset.zero & viewSize);
  final double sx = frame.width / imageSize.width;
  final double sy = frame.height / imageSize.height;
  return Rect.fromLTRB(
    frame.left + imageRect.left * sx,
    frame.top + imageRect.top * sy,
    frame.left + imageRect.right * sx,
    frame.top + imageRect.bottom * sy,
  );
}
