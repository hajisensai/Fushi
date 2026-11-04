/// 浏览器扩展「抓图取词」（`POST /api/ocr/image`）：扩展把 canvas 渲染的阅读器
/// （BookWalker 等，正文是 `<canvas>` 像素、页面里没有文本节点）截下来交给 app 识别，
/// 回每个字在截图里的位置，扩展按指针命中字、走既有查词弹窗。
///
/// 不另起一套 OCR：识别会话就是视频暂停帧查词那一份（[GraphicSubtitleOcrSession]，
/// 底下是漫画在线直读的页级识别 `prepareMangaStreamOcr`）——同一个引擎偏好、同一份
/// 字级几何。差别只在「用户不在 app 里」：不弹任何询问框（Lens 只在本机已同意过
/// 上传漫画页面时才用），不做大模型重读（一次请求只回一次结果，没有热替换的去处）。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:fushi/src/media/video/graphic_subtitle_ocr.dart';

/// 扩展抓图识别端点。
const String kExtensionOcrImagePath = '/api/ocr/image';

/// 一张截图解码后的字节上限。扩展侧已把长边压到 2048 px 以内（PNG 至多几 MB），
/// 超过这个数只可能是坏请求，不往识别器里送。
const int kExtensionOcrImageMaxBytes = 16 * 1024 * 1024;

/// 识别一张截图（PNG / JPEG 字节）。引擎不可用时抛 [GraphicSubtitleOcrUnavailable]。
typedef ExtensionImageOcr =
    Future<GraphicSubtitleOcrFrame> Function(Uint8List image);

/// 请求体里的 `image`（裸 base64 或 `data:image/...;base64,` 串）→ 字节；不是合法
/// base64 / 空串返回 null。
Uint8List? decodeExtensionOcrImage(Object? raw) {
  if (raw is! String) return null;
  String data = raw.trim();
  if (data.startsWith('data:')) {
    final int comma = data.indexOf(',');
    if (comma < 0 || !data.substring(0, comma).endsWith(';base64')) return null;
    data = data.substring(comma + 1);
  }
  if (data.isEmpty) return null;
  try {
    final Uint8List bytes = base64Decode(data);
    return bytes.isEmpty ? null : bytes;
  } on FormatException {
    return null;
  }
}

/// 识别结果 → 扩展消费的 JSON：
///
/// ```json
/// {"width": 800, "height": 600,
///  "blocks": [{"text": "吾輩は猫である", "chars": [{"i": 0, "x": 1, "y": 2, "w": 3, "h": 4}]}]}
/// ```
///
/// `blocks` 一块一句（与漫画查词同一口径：块内各行直接拼接），`chars[].i` 是该字在
/// `text` 里的字素下标，坐标是截图像素。[GraphicSubtitleOcrFrame.chars] 按块顺序
/// 摊平，相邻同句、下标递增的字归同一块。
Map<String, dynamic> extensionOcrFrameJson(GraphicSubtitleOcrFrame frame) {
  final List<Map<String, dynamic>> blocks = <Map<String, dynamic>>[];
  String? currentText;
  int lastIndex = -1;
  List<Map<String, dynamic>>? currentChars;
  for (final GraphicSubtitleOcrChar c in frame.chars) {
    if (currentChars == null ||
        c.sentence != currentText ||
        c.graphemeIndex <= lastIndex) {
      currentChars = <Map<String, dynamic>>[];
      currentText = c.sentence;
      blocks.add(<String, dynamic>{'text': c.sentence, 'chars': currentChars});
    }
    lastIndex = c.graphemeIndex;
    currentChars.add(<String, dynamic>{
      'i': c.graphemeIndex,
      'x': c.rect.left,
      'y': c.rect.top,
      'w': c.rect.width,
      'h': c.rect.height,
    });
  }
  return <String, dynamic>{
    'width': frame.imageSize.width,
    'height': frame.imageSize.height,
    'blocks': blocks,
  };
}

/// app 侧的抓图识别服务：持有一个识别会话（引擎只解析一次，本地 ONNX 模型常驻），
/// 设置变了（[configKey] 变）就换新会话。
///
/// 引擎不可用（没装模型 / 选了 Lens 但本机没同意过上传）时丢掉这个会话：
/// [GraphicSubtitleOcrSession] 会把「没有引擎」的探测结果记住，而用户装好模型后
/// 下一次请求应当重新探测，不能永远回「不可用」。
class ExtensionImageOcrService {
  ExtensionImageOcrService({
    required GraphicSubtitleOcrPrepare prepare,
    required String Function() configKey,
  }) : _prepare = prepare,
       _configKey = configKey;

  final GraphicSubtitleOcrPrepare _prepare;
  final String Function() _configKey;
  GraphicSubtitleOcrSession? _session;
  String? _sessionKey;

  /// 识别 [image]。引擎不可用抛 [GraphicSubtitleOcrUnavailable]。
  Future<GraphicSubtitleOcrFrame> recognize(Uint8List image) async {
    final String key = _configKey();
    GraphicSubtitleOcrSession? session = _session;
    if (session == null || key != _sessionKey) {
      final GraphicSubtitleOcrSession? stale = session;
      session = _session = GraphicSubtitleOcrSession(prepare: _prepare);
      _sessionKey = key;
      // 先关旧会话（释放上一个模型的 isolate）再开新的，免得两份模型同时常驻。
      if (stale != null) await stale.close();
    }
    try {
      final GraphicSubtitleOcrFrame? frame = await session.recognize(image);
      // 会话在这次识别途中被关掉（设置刚改 / app 在拆）：这次请求如实失败，
      // 扩展照常提示「识别失败」，下一次指针移动按新会话识别。
      if (frame == null) throw StateError('extension OCR session closed');
      return frame;
    } on GraphicSubtitleOcrUnavailable {
      if (identical(_session, session)) {
        _session = null;
        _sessionKey = null;
      }
      await session.close();
      rethrow;
    }
  }

  /// 关掉会话（释放模型 isolate、删临时目录）。之后再 [recognize] 会新开会话。
  Future<void> close() async {
    final GraphicSubtitleOcrSession? session = _session;
    _session = null;
    _sessionKey = null;
    await session?.close();
  }
}
