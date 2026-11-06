/// 浏览器扩展抓图取词的识别会话持有者（`POST /api/ocr/image` 的 app 侧实现）。
///
/// 与端点协议（`extension_image_ocr.dart`）分开：这里要拿识别会话
/// [GraphicSubtitleOcrSession]（→ 漫画 OCR 引擎 → AppModel），只给 AppModel 装配用；
/// 扩展 API 核心只依赖协议那一半，不被拖进 AppModel 的 import 环。
library;

import 'dart:typed_data';

import 'package:fushi/src/media/video/graphic_subtitle_ocr.dart';

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
