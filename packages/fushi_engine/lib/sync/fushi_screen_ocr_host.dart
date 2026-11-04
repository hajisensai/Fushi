/// 截屏识字：互联对端（Steam Deck 游戏内识字插件等）把一帧截图交给 host，host 用
/// 本机 OCR 读出逐行文字、行框与逐字框，对端据此画框、点字查词。
///
/// 端点（走 FushiSyncServer 的既有鉴权，不豁免）：
/// - `POST /api/ocr/screen[?region=x,y,w,h]`，body = 截图字节（JPEG / PNG / WebP）
///   → `{width, height, ms, vertical, lines: [{text, box, glyphs?}]}`
///
/// 识别走「整帧当一块文字图」那条现成路径（[MangaOcrTextImageSession]：PP 行检测 +
/// 逐行识别，不建漫画检测器）——Steam Deck 实测（2026-11-04，CHAOS;HEAD NOAH 40 帧）
/// 中位 0.5 s、逐字准确，漫画整页管线反而漏掉淡色字。会话常驻复用（建会话约 0.7 s），
/// 空闲 [idleTimeout] 后关掉释放 ORT 内存，下次请求再建。
///
/// 独立文件而非写进 `fushi_sync_server.dart`：server 是共享热点，只留路由分发与
/// capabilities 两处接线。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:shelf/shelf.dart' as shelf;

import 'package:fushi_engine/ocr/manga_ocr_service.dart';
import 'package:fushi_engine/ocr/ocr_types.dart';

/// 互联路径与 capabilities 键（wire 冻结）。
const String kScreenOcrPath = '/api/ocr/screen';
const String kScreenOcrCapability = 'screenOcrV1';

/// 一帧截图的字节上限：4K JPEG 约 1 MB、PNG 约 9 MB，16 MB 足够且挡住误传大文件。
const int kScreenOcrMaxBodyBytes = 16 * 1024 * 1024;

/// 解码后的像素上限（宽 × 高）：8K 以内，挡住解压炸弹。
const int kScreenOcrMaxPixels = 7680 * 4320;

/// 识别区域（截图像素坐标，左上原点）。
class ScreenOcrRegion {
  const ScreenOcrRegion({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  final int x;
  final int y;
  final int width;
  final int height;

  /// 解析 `x,y,w,h`；格式错返回 null。是否落在图内由调用方按图尺寸再判。
  static ScreenOcrRegion? tryParse(String value) {
    final List<String> parts = value.split(',');
    if (parts.length != 4) return null;
    final List<int?> v = <int?>[
      for (final String part in parts) int.tryParse(part.trim()),
    ];
    if (v.any((int? n) => n == null)) return null;
    final ScreenOcrRegion region = ScreenOcrRegion(
      x: v[0]!,
      y: v[1]!,
      width: v[2]!,
      height: v[3]!,
    );
    if (region.x < 0 || region.y < 0 || region.width < 1 || region.height < 1) {
      return null;
    }
    return region;
  }

  bool fitsIn(int imageWidth, int imageHeight) =>
      x + width <= imageWidth && y + height <= imageHeight;
}

/// 一行识别结果（坐标都是整张截图的像素坐标）。
class ScreenOcrLine {
  const ScreenOcrLine({required this.text, required this.box, this.glyphs});

  final String text;
  final OcrRect box;

  /// 逐字框，`start` / `end` 是 [text] 内的 UTF-16 区间；null = 这一行没有字级几何
  /// （竖排行等），对端退回按行均分。
  final List<OcrGlyphBox>? glyphs;

  Map<String, Object?> toJson() => <String, Object?>{
    'text': text,
    'box': box.toJson(),
    if (glyphs != null)
      'glyphs': <Map<String, dynamic>>[
        for (final OcrGlyphBox glyph in glyphs!) glyph.toJson(),
      ],
  };
}

/// 把整块识别结果拆成逐行：块文字是各行无分隔拼接，逐字框的区间按拼接后的文字记，
/// 这里按行切开并改成行内区间；坐标平移 [dx] / [dy]（区域识别时回到整张截图）。
///
/// 没有行几何（识别器只给整块文字）时整块当一行、框取 [fallbackBox]。
List<ScreenOcrLine> screenOcrLines(
  OcrRecognition result, {
  required OcrRect fallbackBox,
  double dx = 0,
  double dy = 0,
}) {
  OcrRect shift(OcrRect r) => OcrRect(
    left: r.left + dx,
    top: r.top + dy,
    right: r.right + dx,
    bottom: r.bottom + dy,
  );
  final List<String>? lines = result.lines;
  final List<OcrRect>? boxes = result.lineBoxes;
  if (lines == null || boxes == null) {
    if (result.text.isEmpty) return const <ScreenOcrLine>[];
    return <ScreenOcrLine>[
      ScreenOcrLine(text: result.text, box: shift(fallbackBox)),
    ];
  }
  final List<OcrGlyphBox>? glyphs = result.glyphBoxes;
  final List<ScreenOcrLine> out = <ScreenOcrLine>[];
  int offset = 0;
  for (int i = 0; i < lines.length; i++) {
    final String text = lines[i];
    final int end = offset + text.length;
    List<OcrGlyphBox>? lineGlyphs;
    if (glyphs != null) {
      lineGlyphs = <OcrGlyphBox>[
        for (final OcrGlyphBox g in glyphs)
          if (g.start >= offset && g.end <= end)
            OcrGlyphBox(
              start: g.start - offset,
              end: g.end - offset,
              rect: shift(g.rect),
            ),
      ];
      if (lineGlyphs.isEmpty) lineGlyphs = null;
    }
    out.add(
      ScreenOcrLine(text: text, box: shift(boxes[i]), glyphs: lineGlyphs),
    );
    offset = end;
  }
  return out;
}

/// 解码好的 RGBA 帧（在后台 isolate 里解，避免占住 server 的事件循环）。
class _DecodedFrame {
  const _DecodedFrame(
    this.rgba,
    this.width,
    this.height, {
    required this.imageWidth,
    required this.imageHeight,
  });

  /// 识别用的像素（有区域时是区域裁图）。
  final Uint8List rgba;
  final int width;
  final int height;

  /// 整张截图的尺寸。
  final int imageWidth;
  final int imageHeight;
}

/// 解码失败 / 过大（返回 null 时调用方报 400）。
_DecodedFrame? _decodeFrame(Uint8List bytes, ScreenOcrRegion? region) {
  final img.Decoder? decoder = img.findDecoderForData(bytes);
  if (decoder == null) return null;
  final img.DecodeInfo? info = decoder.startDecode(bytes);
  if (info == null || info.width * info.height > kScreenOcrMaxPixels) {
    return null;
  }
  img.Image? image = decoder.decode(bytes);
  if (image == null) return null;
  final int imageWidth = image.width;
  final int imageHeight = image.height;
  if (region != null) {
    if (!region.fitsIn(image.width, image.height)) return null;
    image = img.copyCrop(
      image,
      x: region.x,
      y: region.y,
      width: region.width,
      height: region.height,
    );
  }
  final img.Image rgba = image.convert(numChannels: 4);
  return _DecodedFrame(
    rgba.getBytes(order: img.ChannelOrder.rgba),
    rgba.width,
    rgba.height,
    imageWidth: imageWidth,
    imageHeight: imageHeight,
  );
}

/// 截屏识字的 host 侧：持有一个常驻文字图会话，处理 [kScreenOcrPath]。
class ScreenOcrHost {
  ScreenOcrHost({
    required MangaOcrService service,
    required Directory workDir,
    this.idleTimeout = const Duration(minutes: 5),
  }) : _service = service,
       _workDir = workDir;

  final MangaOcrService _service;

  /// 会话要一个图片目录参数（文字图会话不读写它），给 host 自己的工作目录。
  final Directory _workDir;

  /// 最后一次请求后多久关掉常驻会话。
  final Duration idleTimeout;

  Future<MangaOcrPageSession>? _session;
  Timer? _idleTimer;
  bool _disposed = false;

  /// capabilities 用：本平台能跑、模型已下载、服务支持文字图会话。
  Future<bool> isAvailable() async {
    final MangaOcrService service = _service;
    if (service is! MangaOcrPageService) return false;
    if (!service.isSupportedPlatform) return false;
    return (await service.modelStatus()).allReady;
  }

  Future<MangaOcrTextImageSession> _textSession() async {
    final Future<MangaOcrPageSession> session = _session ??= () async {
      final MangaOcrService service = _service;
      if (service is! MangaOcrPageService) {
        throw StateError('OCR service has no page sessions');
      }
      await _workDir.create(recursive: true);
      return (service as MangaOcrPageService).openPageSession(
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
      // 建会话失败不缓存：下次请求重建（模型可能刚下载好）。
      if (identical(_session, session)) _session = null;
      rethrow;
    }
  }

  void _armIdleTimer() {
    _idleTimer?.cancel();
    _idleTimer = Timer(idleTimeout, () => unawaited(_closeSession()));
  }

  Future<void> _closeSession() async {
    _idleTimer?.cancel();
    _idleTimer = null;
    final Future<MangaOcrPageSession>? session = _session;
    _session = null;
    if (session == null) return;
    try {
      await (await session).close();
    } on Object {
      // 建会话就失败了的会话无需关闭。
    }
  }

  /// server stop 时调用：关掉常驻会话、之后的请求一律 503。
  Future<void> dispose() async {
    _disposed = true;
    await _closeSession();
  }

  /// 识别一帧（区域可选）。图解不开 / 区域越界抛 [FormatException]。
  Future<Map<String, Object?>> recognize(
    Uint8List bytes, {
    ScreenOcrRegion? region,
  }) async {
    final Stopwatch watch = Stopwatch()..start();
    final _DecodedFrame? frame = await Isolate.run(
      () => _decodeFrame(bytes, region),
    );
    if (frame == null) {
      throw const FormatException(
        'image could not be decoded, is too large, or region is outside it',
      );
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
    final double dx = (region?.x ?? 0).toDouble();
    final double dy = (region?.y ?? 0).toDouble();
    final List<ScreenOcrLine> lines = screenOcrLines(
      result,
      fallbackBox: OcrRect(
        left: 0,
        top: 0,
        right: frame.width.toDouble(),
        bottom: frame.height.toDouble(),
      ),
      dx: dx,
      dy: dy,
    );
    return <String, Object?>{
      'width': frame.imageWidth,
      'height': frame.imageHeight,
      if (region != null)
        'region': <String, int>{
          'x': region.x,
          'y': region.y,
          'width': region.width,
          'height': region.height,
        },
      'ms': watch.elapsedMilliseconds,
      'vertical': result.vertical,
      'lines': <Map<String, Object?>>[
        for (final ScreenOcrLine line in lines) line.toJson(),
      ],
    };
  }

  /// shelf 路由处理（路径已由 server 匹配为 [kScreenOcrPath]）。
  Future<shelf.Response> handle(shelf.Request request) async {
    if (request.method != 'POST') return shelf.Response(405);
    if (_disposed) return shelf.Response(503, body: 'Screen OCR stopped');
    if (!await isAvailable()) {
      return shelf.Response(503, body: 'OCR models are not ready on this host');
    }
    ScreenOcrRegion? region;
    final String? regionParam = request.url.queryParameters['region'];
    if (regionParam != null) {
      region = ScreenOcrRegion.tryParse(regionParam);
      if (region == null) {
        return shelf.Response(400, body: 'region must be x,y,w,h');
      }
    }
    final int? declared = request.contentLength;
    if (declared != null && declared > kScreenOcrMaxBodyBytes) {
      return shelf.Response(413);
    }
    final BytesBuilder body = BytesBuilder(copy: false);
    await for (final List<int> chunk in request.read()) {
      body.add(chunk);
      if (body.length > kScreenOcrMaxBodyBytes) return shelf.Response(413);
    }
    if (body.isEmpty) return shelf.Response(400, body: 'empty body');
    try {
      final Map<String, Object?> result = await recognize(
        body.takeBytes(),
        region: region,
      );
      return shelf.Response.ok(
        jsonEncode(result),
        headers: <String, String>{'content-type': 'application/json'},
      );
    } on FormatException catch (e) {
      return shelf.Response(400, body: e.message);
    }
  }
}
