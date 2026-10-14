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
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Offset, Rect, Size;

import 'package:characters/characters.dart';
import 'package:flutter/painting.dart'
    show Alignment, BoxFit, FittedSizes, applyBoxFit;
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/manga/manga_overlay_html.dart'
    show mangaEffectiveTextRegions;
import 'package:fushi/src/media/manga/ocr/manga_ocr_engine.dart';
import 'package:fushi/src/media/manga/reader/manga_reader_stream_ocr.dart';
import 'package:fushi_engine/media/video/bitmap_subtitle/bitmap_subtitle_cue.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi_engine/ocr/manga_ai_ocr_refiner.dart'
    show
        MangaAiOcrCropRequest,
        applyMangaAiOcrText,
        cropMangaAiOcrBlocks,
        kMangaAiOcrBlocksPerRequest,
        kMangaAiOcrMaxNearbyLines;
import 'package:fushi_engine/ocr/ocr_types.dart' show OcrRecognition, OcrRect;

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

/// 本会话实际用的引擎：识别引擎 + AI 重读来源（供应商 · 模型；没开为 null）。
typedef GraphicSubtitleOcrEngineInfo = ({
  MangaOcrEngineId engine,
  String? aiProvider,
});

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

  /// 解析引擎并返回本会话实际用的识别引擎与 AI 重读来源（没开 AI 重读为 null）。
  /// 会触发 [GraphicSubtitleOcrPrepare]（含 Lens 上传同意）；不可用抛
  /// [GraphicSubtitleOcrUnavailable]。整轨转文字在识别前调它，把「用的是哪个引擎、
  /// AI 开没开」如实告诉用户。
  Future<GraphicSubtitleOcrEngineInfo> resolveEngine() async {
    final MangaStreamOcrReady ready = await _ensureReady();
    return (engine: ready.engine, aiProvider: ready.ai?.providerLabel);
  }

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

  // ── 整轨字幕识别（边看边识别）──────────────────────────────────────────────

  final Map<String, _SubtitleEntry> _subtitleEntries =
      <String, _SubtitleEntry>{};
  final List<_SubtitleAiItem> _aiQueue = <_SubtitleAiItem>[];
  final Set<Future<void>> _aiRunning = <Future<void>>{};
  Timer? _aiFlushTimer;
  int _aiTotal = 0;
  int _aiDone = 0;

  /// 最近识别出的几条台词（本地结果，识别完成序）：随大模型请求当「附近文字」带上，
  /// 帮它分辨形近字。只留 [kMangaAiOcrMaxNearbyLines] 条。
  final List<String> _recentSubtitleLines = <String>[];
  Completer<void>? _aiChanged;

  /// 大模型重读进度：(已回, 已排队)。没开大模型恒为 (0, 0)。
  ({int done, int total}) get subtitleAiProgress =>
      (done: _aiDone, total: _aiTotal);

  /// 整轨识别同时可在途几条：本机 ONNX 走文字图会话池，其它引擎（Lens / 系统
  /// OCR）逐条串行。会触发引擎解析。
  Future<int> subtitleParallelism() async {
    final MangaStreamOcrReady ready = await _ensureReady();
    final MangaStreamPageRecognizer recognizer = ready.recognizer;
    return recognizer is MangaStreamTextImageRecognizer
        ? math.max(
            1,
            (recognizer as MangaStreamTextImageRecognizer).parallelism,
          )
        : 1;
  }

  /// 识别一条字幕位图（整轨用）。本地文字立即返回；开了大模型重读且这条按档位
  /// 该送时，排进**跨条批量**队列（多条拼一次请求、几批并发），读回的新文字经
  /// [onRefined] 再交一次——本地识别与大模型互不等待。
  ///
  /// 内容相同的位图（[BitmapSubtitleImage.contentKey]）只识别、只重读一次：后来的
  /// 同图直接拿前一次的结果（已重读过就直接是重读后的文字）。会话已关闭返回 null。
  Future<String?> recognizeSubtitleImage(
    BitmapSubtitleImage image, {
    void Function(String refined)? onRefined,
    void Function(Object error, StackTrace stack)? onRefineError,
  }) async {
    if (_closed) return null;
    final String key = image.contentKey;
    final _SubtitleEntry? known = _subtitleEntries[key];
    if (known != null) {
      final String? refined = known.refined;
      if (refined != null) return refined;
      if (onRefined != null) known.listeners.add(onRefined);
      return known.local;
    }
    final _SubtitleEntry entry = _SubtitleEntry();
    if (onRefined != null) entry.listeners.add(onRefined);
    _subtitleEntries[key] = entry;
    final Future<String?> local = _recognizeSubtitleLocal(
      image,
      entry,
      onRefineError,
    );
    entry.local = local;
    try {
      return await local;
    } catch (_) {
      // 失败的不留在去重表里，同图下次重试。
      if (identical(_subtitleEntries[key], entry)) _subtitleEntries.remove(key);
      rethrow;
    }
  }

  Future<String?> _recognizeSubtitleLocal(
    BitmapSubtitleImage image,
    _SubtitleEntry entry,
    void Function(Object error, StackTrace stack)? onRefineError,
  ) async {
    final MangaStreamOcrReady ready = await _ensureReady();
    if (_closed) return null;
    final MangaStreamPageRecognizer recognizer = ready.recognizer;
    final MokuroRect full = MokuroRect.fromLTRB(
      0,
      0,
      image.width.toDouble(),
      image.height.toDouble(),
    );
    final String text;
    final MokuroBlock block;
    if (recognizer case final MangaStreamTextImageRecognizer textual) {
      final OcrRecognition read = await textual.recognizeTextImage(
        image.rgba,
        width: image.width,
        height: image.height,
      );
      if (_closed) return null;
      text = read.text.trim();
      double lineHeight = 0;
      for (final OcrRect box in read.lineBoxes ?? const <OcrRect>[]) {
        lineHeight = math.max(lineHeight, box.height);
      }
      block = MokuroBlock(
        rectangle: full,
        isVertical: read.vertical,
        fontSize: lineHeight > 0 ? lineHeight : image.height * 0.6,
        zIndex: 0,
        lines: read.lines ?? <String>[text],
        confidence: read.confidence,
      );
    } else {
      // Lens / 系统 OCR：只认图片文件，走页级入口。
      final Uint8List png = await Isolate.run(image.encodePng);
      if (_closed) return null;
      final File file = File(p.join(_dir!.path, 'frame_${_frameSeq++}.png'));
      await file.writeAsBytes(png, flush: true);
      try {
        final MokuroImage page = await recognizer.recognize(file);
        if (_closed) return null;
        text = page.blocks
            .map((MokuroBlock b) => b.lines.join().trim())
            .where((String s) => s.isNotEmpty)
            .join('\n');
      } finally {
        await _deleteQuietly(file);
      }
      block = MokuroBlock(
        rectangle: full,
        isVertical: false,
        fontSize: image.height * 0.6,
        zIndex: 0,
        lines: <String>[text],
      );
    }
    if (text.isNotEmpty) {
      _recentSubtitleLines.add(text);
      if (_recentSubtitleLines.length > kMangaAiOcrMaxNearbyLines) {
        _recentSubtitleLines.removeAt(0);
      }
    }
    final MangaStreamAiRefinement? ai = ready.ai;
    if (ai != null && text.isNotEmpty && ai.wants(block)) {
      _enqueueAi(
        _SubtitleAiItem(
          entry: entry,
          block: block,
          crop: Isolate.run(() => graphicSubtitleAiCrop(image)),
          onError: onRefineError,
          localText: text,
        ),
        ai,
      );
    }
    return text;
  }

  void _enqueueAi(_SubtitleAiItem item, MangaStreamAiRefinement ai) {
    _aiQueue.add(item);
    _aiTotal++;
    _signalAi();
    if (_aiQueue.length >= kMangaAiOcrBlocksPerRequest) {
      _flushAi(ai);
    } else {
      _aiFlushTimer ??= Timer(kGraphicSubtitleAiBatchDelay, () => _flushAi(ai));
    }
  }

  /// 攒满一批或等够 [kGraphicSubtitleAiBatchDelay] 就发；同时在途最多
  /// [kGraphicSubtitleAiConcurrency] 批。
  void _flushAi(MangaStreamAiRefinement ai) {
    _aiFlushTimer?.cancel();
    _aiFlushTimer = null;
    while (_aiQueue.isNotEmpty &&
        _aiRunning.length < kGraphicSubtitleAiConcurrency &&
        !_closed) {
      final int n = math.min(kMangaAiOcrBlocksPerRequest, _aiQueue.length);
      final List<_SubtitleAiItem> batch = _aiQueue.sublist(0, n);
      _aiQueue.removeRange(0, n);
      late final Future<void> running;
      running = _runAiBatch(batch, ai).whenComplete(() {
        _aiRunning.remove(running);
        _signalAi();
        if (_aiQueue.isNotEmpty) _flushAi(ai);
      });
      _aiRunning.add(running);
    }
  }

  Future<void> _runAiBatch(
    List<_SubtitleAiItem> batch,
    MangaStreamAiRefinement ai,
  ) async {
    try {
      final List<Uint8List?> crops = await Future.wait(<Future<Uint8List?>>[
        for (final _SubtitleAiItem item in batch) item.crop,
      ]);
      final List<int> sent = <int>[
        for (int i = 0; i < batch.length; i++)
          if (crops[i] != null) i,
      ];
      if (sent.isEmpty || _closed) return;
      // 附近文字不重复本批自己的本地猜测（那些已逐条写在请求里）。
      final Set<String> own = <String>{
        for (final _SubtitleAiItem item in batch) item.localText,
      };
      final List<String?> texts = await ai.refineCrops(
        <MangaAiOcrCropRequest>[
          for (final int i in sent)
            MangaAiOcrCropRequest(crop: crops[i]!, block: batch[i].block),
        ],
        nearby: <String>[
          for (final String line in _recentSubtitleLines)
            if (!own.contains(line)) line,
        ],
      );
      if (_closed) return;
      for (int k = 0; k < sent.length; k++) {
        final String? raw = texts[k];
        if (raw == null) continue;
        final _SubtitleAiItem item = batch[sent[k]];
        final String refined = applyMangaAiOcrText(
          item.block,
          raw,
        ).lines.join().trim();
        if (refined.isEmpty) continue;
        item.entry.refined = refined;
        for (final void Function(String) listener in item.entry.listeners) {
          listener(refined);
        }
      }
    } catch (error, stack) {
      if (!_closed) batch.first.onError?.call(error, stack);
    } finally {
      _aiDone += batch.length;
    }
  }

  void _signalAi() {
    final Completer<void>? changed = _aiChanged;
    _aiChanged = null;
    changed?.complete();
  }

  /// 等排队与在途的大模型重读全部回来（整轨收尾写 SRT 前调用）。[onProgress] 在
  /// 每批回来时报 (已回, 总数)。会话关闭立即返回。
  Future<void> drainSubtitleRefinements({
    void Function(int done, int total)? onProgress,
  }) async {
    while (!_closed && (_aiQueue.isNotEmpty || _aiRunning.isNotEmpty)) {
      if (_aiQueue.isNotEmpty && _aiRunning.isEmpty) {
        final MangaStreamAiRefinement? ai = (await _ensureReady()).ai;
        if (ai == null) break;
        _flushAi(ai);
      }
      onProgress?.call(_aiDone, _aiTotal);
      final Completer<void> changed = _aiChanged ??= Completer<void>();
      await changed.future;
    }
    onProgress?.call(_aiDone, _aiTotal);
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
    _aiFlushTimer?.cancel();
    _aiFlushTimer = null;
    _aiQueue.clear();
    _signalAi();
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

/// 字幕大模型重读：攒批的最长等待。攒满 [kMangaAiOcrBlocksPerRequest] 条立即发。
const Duration kGraphicSubtitleAiBatchDelay = Duration(milliseconds: 800);

/// 字幕大模型重读：同时在途的批数（每批一次请求）。
const int kGraphicSubtitleAiConcurrency = 3;

class _SubtitleEntry {
  Future<String?>? local;
  String? refined;
  final List<void Function(String refined)> listeners =
      <void Function(String refined)>[];
}

class _SubtitleAiItem {
  _SubtitleAiItem({
    required this.entry,
    required this.block,
    required this.crop,
    required this.onError,
    required this.localText,
  });

  final _SubtitleEntry entry;
  final MokuroBlock block;

  /// 本地识别出的整条文字（与 [GraphicSubtitleOcrSession] 记进最近台词的同一串）。
  final String localText;
  final Future<Uint8List?> crop;
  final void Function(Object error, StackTrace stack)? onError;
}

/// 字幕位图 → 交给大模型的裁图（与漫画同一套外扩 / 缩放规则）。顶层函数：给
/// `Isolate.run` 用。
Uint8List? graphicSubtitleAiCrop(BitmapSubtitleImage image) =>
    cropMangaAiOcrBlocks(
      image.encodePng(),
      pageWidth: image.width.toDouble(),
      pageHeight: image.height.toDouble(),
      boxes: <MokuroRect>[
        MokuroRect.fromLTRB(
          0,
          0,
          image.width.toDouble(),
          image.height.toDouble(),
        ),
      ],
    ).single;

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
/// 字级几何与漫画覆盖层同一份（[mangaEffectiveTextRegions]）：引擎给了字级区域
/// （Lens）就用它；否则按识别器交回的每行框（`linesCoords`）切行、行内按字素分格。
/// 不能按行数均分整个块：字幕带振假名时检测框把注音也框进来，注音行又比正文矮得多，
/// 均分后每个可点框都偏离真实的字（BUG-3314）。
///
/// 引擎给的字级区域只要有一个对不上文字（例如大模型改写过文字、区域还是旧文字的
/// 偏移），整块改走行几何——判据在 [mangaEffectiveTextRegions] 里与漫画覆盖层共用
/// 同一份；逐个丢掉对不上的区域会留下残缺的可点框，有的字点不到。
List<GraphicSubtitleOcrChar> graphicSubtitleOcrCharsOf(MokuroBlock block) {
  final String sentence = block.lines.join();
  if (sentence.trim().isEmpty) return const <GraphicSubtitleOcrChar>[];
  // UTF-16 起点 → 字素下标。区域已保证落在字素边界上。
  final Map<int, int> graphemeAtUtf16 = <int, int>{};
  int offset = 0;
  int index = 0;
  for (final String g in sentence.characters) {
    graphemeAtUtf16[offset] = index++;
    offset += g.length;
  }
  return <GraphicSubtitleOcrChar>[
    for (final MangaOcrTextRegion region in mangaEffectiveTextRegions(block))
      (
        sentence: sentence,
        graphemeIndex: graphemeAtUtf16[region.utf16Start]!,
        rect: Rect.fromLTRB(
          region.bounds.left,
          region.bounds.top,
          region.bounds.right,
          region.bounds.bottom,
        ),
      ),
  ];
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
