// Tyrano DOM 快照：观察脚本推回的 JSON（CSS 像素、视口坐标）→ 客户区物理像素的帧。
//
// 坐标约定：页面视口原点 = 游戏窗口客户区原点（Electron / NW.js 无菜单栏时成立；实测
// ユリアリス 客户区 1904x1041 == innerWidth/innerHeight）。物理像素 = CSS 像素 ×
// devicePixelRatio（dpr 已含页面缩放；150% 缩放机器上 dpr=1.5）。若宿主窗口在视口上方
// 另有 Electron 菜单栏，客户区物理高度会大于 [TyranoDomFrame.clientHeight]，差值即视口
// 在客户区里的纵向偏移，由消费端自行比较补上。

import 'dart:convert';
import 'dart:math' show Rectangle;

/// 观察脚本推送 JSON 的格式版本（payload 的 `v`）。
const int kTyranoDomPayloadVersion = 1;

/// 一个字形：在 [TyranoDomFrame.text] 里的 UTF-16 区间与客户区物理像素矩形。
class TyranoDomGlyph {
  /// 创建字形。
  const TyranoDomGlyph({
    required this.textStart,
    required this.textLength,
    required this.rect,
    required this.shown,
  });

  /// 在 [TyranoDomFrame.text] 里的起始下标（UTF-16）。
  final int textStart;

  /// UTF-16 长度（一般为 1，代理对为 2）。
  final int textLength;

  /// 客户区物理像素矩形（ruby 字只含 rb 部分）。
  final Rectangle<double> rect;

  /// 逐字显示动画里是否已显示（opacity > 0 且非 hidden）。
  final bool shown;

  @override
  bool operator ==(Object other) =>
      other is TyranoDomGlyph &&
      other.textStart == textStart &&
      other.textLength == textLength &&
      other.rect == rect &&
      other.shown == shown;

  @override
  int get hashCode => Object.hash(textStart, textLength, rect, shown);
}

/// 一帧快照。
class TyranoDomFrame {
  /// 创建快照。
  const TyranoDomFrame({
    required this.text,
    required this.generation,
    required this.complete,
    required this.speaker,
    required this.glyphs,
    required this.devicePixelRatio,
    required this.clientWidth,
    required this.clientHeight,
    required this.vertical,
    this.documentId = '',
    this.lineSeq = 0,
    this.voiceDeclared = false,
  });

  /// 台词正文：可见消息层（`messageN_fore`，display != none）里的字形按 DOM 顺序拼接，
  /// 不含 `<rt>` 注音。
  final String text;

  /// 正文变化才 +1（从 1 起；会话第一帧正文为空时为 0）。
  final int generation;

  /// 本句已显示完：`is_adding_text == false` 且所有非空白字形都已显示。
  final bool complete;

  /// 角色名（`.chara_name_area`，可能为空串）。
  final String speaker;

  /// 字形，与 [text] 一一覆盖（按顺序首尾相接）。
  final List<TyranoDomGlyph> glyphs;

  /// 页面的 devicePixelRatio。
  final double devicePixelRatio;

  /// 视口的物理像素宽（`round(innerWidth × dpr)`）。
  final int clientWidth;

  /// 视口的物理像素高（`round(innerHeight × dpr)`）。
  final int clientHeight;

  /// TyranoScript 纵排（`TYRANO.kag.config.vertical == "true"`）。
  final bool vertical;

  /// 观察脚本实例的文档 id（页面重载 / 重注入后变化；[lineSeq] 只在同一 id 内可比）。
  final String documentId;

  /// 脚本侧句序号：正文从非空变成「不是上一份的延续」时 +1。语音事件带同一计数，
  /// Dart 据此把语音归到它所属的那一句（见 tyrano_dom_observer_script.dart）。
  final int lineSeq;

  /// 引擎声明了语音缓冲区（`stat.map_vo.vobuf` 非空，即用了 `[voconfig]`）：此时
  /// 「这句有没有语音、是哪条」由 DOM 语音事件权威给出。
  final bool voiceDeclared;
}

/// 脚本推回的单个字形（CSS 像素、视口坐标），解析的中间结果。
class TyranoDomRawGlyph {
  /// 创建原始字形。
  const TyranoDomRawGlyph({
    required this.text,
    required this.left,
    required this.top,
    required this.width,
    required this.height,
    required this.shown,
  });

  /// 字形文本（不含 rt）。
  final String text;

  /// CSS 像素左。
  final double left;

  /// CSS 像素上。
  final double top;

  /// CSS 像素宽。
  final double width;

  /// CSS 像素高。
  final double height;

  /// 是否已显示。
  final bool shown;
}

/// 脚本推回的一次快照（未分配 generation）。
class TyranoDomPayload {
  /// 创建快照载荷。
  const TyranoDomPayload({
    required this.adding,
    required this.vertical,
    required this.devicePixelRatio,
    required this.viewportWidth,
    required this.viewportHeight,
    required this.speaker,
    required this.glyphs,
    this.documentId = '',
    this.lineSeq = 0,
    this.voiceDeclared = false,
  });

  /// 文档 id（`doc`）。
  final String documentId;

  /// 句序号（`ln`）。
  final int lineSeq;

  /// 声明了语音缓冲区（`vo`）。
  final bool voiceDeclared;

  /// `TYRANO.kag.stat.is_adding_text`。
  final bool adding;

  /// 纵排。
  final bool vertical;

  /// devicePixelRatio（非正数时按 1）。
  final double devicePixelRatio;

  /// `innerWidth`（CSS 像素）。
  final double viewportWidth;

  /// `innerHeight`（CSS 像素）。
  final double viewportHeight;

  /// 角色名。
  final String speaker;

  /// 字形。
  final List<TyranoDomRawGlyph> glyphs;
}

/// 解析 `Runtime.bindingCalled` 的 payload 字符串；格式不对返回 null。
TyranoDomPayload? parseTyranoDomPayload(String payload) {
  final Object? decoded;
  try {
    decoded = jsonDecode(payload);
  } on FormatException {
    return null;
  }
  if (decoded is! Map<String, Object?>) return null;
  return parseTyranoDomPayloadMap(decoded);
}

/// [parseTyranoDomPayload] 的已解码版本（会话先解码一次再分派快照 / 语音消息）。
TyranoDomPayload? parseTyranoDomPayloadMap(Map<String, Object?> decoded) {
  if (decoded['v'] != kTyranoDomPayloadVersion) return null;
  // 带 `k` 的是别的消息（语音事件，见 parseTyranoDomVoicePayload），不是快照。
  if (decoded.containsKey('k')) return null;
  final Object? rawGlyphs = decoded['glyphs'];
  if (rawGlyphs is! List<Object?>) return null;
  final List<TyranoDomRawGlyph> glyphs = <TyranoDomRawGlyph>[];
  for (final Object? item in rawGlyphs) {
    if (item is! Map<String, Object?>) return null;
    final Object? text = item['t'];
    final double? x = _number(item['x']);
    final double? y = _number(item['y']);
    final double? w = _number(item['w']);
    final double? h = _number(item['h']);
    if (text is! String || x == null || y == null || w == null || h == null) {
      return null;
    }
    if (text.isEmpty) continue;
    glyphs.add(
      TyranoDomRawGlyph(
        text: text,
        left: x,
        top: y,
        width: w < 0 ? 0 : w,
        height: h < 0 ? 0 : h,
        shown: item['s'] == true,
      ),
    );
  }
  final double dpr = _number(decoded['dpr']) ?? 1;
  return TyranoDomPayload(
    adding: decoded['adding'] == true,
    vertical: decoded['vertical'] == true,
    devicePixelRatio: dpr > 0 ? dpr : 1,
    viewportWidth: _number(decoded['vw']) ?? 0,
    viewportHeight: _number(decoded['vh']) ?? 0,
    speaker: decoded['speaker'] is String ? decoded['speaker']! as String : '',
    glyphs: glyphs,
    documentId: decoded['doc'] is String ? decoded['doc']! as String : '',
    lineSeq: decoded['ln'] is int && (decoded['ln']! as int) >= 0
        ? decoded['ln']! as int
        : 0,
    voiceDeclared: decoded['vo'] == true,
  );
}

double? _number(Object? value) {
  if (value is num && value.isFinite) return value.toDouble();
  return null;
}

/// CSS 像素矩形（视口坐标）→ 客户区物理像素矩形。
Rectangle<double> tyranoCssRectToPhysical({
  required double left,
  required double top,
  required double width,
  required double height,
  required double devicePixelRatio,
}) => Rectangle<double>(
  left * devicePixelRatio,
  top * devicePixelRatio,
  width * devicePixelRatio,
  height * devicePixelRatio,
);

/// 把载荷序列装配成帧，持有 generation 状态（一个会话一个）。
class TyranoDomFrameAssembler {
  String _lastText = '';
  int _generation = 0;

  /// 当前 generation。
  int get generation => _generation;

  /// 装配一帧：正文与上一帧不同才把 generation +1。
  TyranoDomFrame assemble(TyranoDomPayload payload) {
    final double dpr = payload.devicePixelRatio;
    final StringBuffer text = StringBuffer();
    final List<TyranoDomGlyph> glyphs = <TyranoDomGlyph>[];
    bool allShown = true;
    for (final TyranoDomRawGlyph raw in payload.glyphs) {
      glyphs.add(
        TyranoDomGlyph(
          textStart: text.length,
          textLength: raw.text.length,
          rect: tyranoCssRectToPhysical(
            left: raw.left,
            top: raw.top,
            width: raw.width,
            height: raw.height,
            devicePixelRatio: dpr,
          ),
          shown: raw.shown,
        ),
      );
      text.write(raw.text);
      // 半角空格的 span.char 在 TyranoScript 里一直是 opacity:0，不参与完成判定。
      if (!raw.shown && raw.text.trim().isNotEmpty) allShown = false;
    }
    final String fullText = text.toString();
    if (fullText != _lastText) {
      _lastText = fullText;
      _generation++;
    }
    return TyranoDomFrame(
      text: fullText,
      generation: _generation,
      complete: !payload.adding && allShown,
      speaker: payload.speaker,
      glyphs: List<TyranoDomGlyph>.unmodifiable(glyphs),
      devicePixelRatio: dpr,
      clientWidth: (payload.viewportWidth * dpr).round(),
      clientHeight: (payload.viewportHeight * dpr).round(),
      vertical: payload.vertical,
      documentId: payload.documentId,
      lineSeq: payload.lineSeq,
      voiceDeclared: payload.voiceDeclared,
    );
  }
}
