// TyranoScript DOM 帧 → attached surface 实测排版载荷（纯函数）。
//
// 坐标契约（runner `attached_measured_layout.h`）：原点是游戏顶层窗口客户区左上角，物理
// 像素，right/bottom 不含；[GalAttachedMeasuredPayload.clientWidth]/[clientHeight] 是
// 「整数 CSS 视口 × devicePixelRatio」推出来的，与真实客户区物理尺寸最多差不到一个 CSS
// 像素（小数 dpr 下的取整：Electron 全屏 150% 时客户区 3840x2159、视口 2560x1440 CSS →
// 3840x2160）。这份量化容差随载荷一起交给 runner
// （[GalAttachedMeasuredPayload.clientSizeTolerance]），超出容差 runner 拒收
// （`measured_client_size_mismatch`）——这里不猜偏移（Electron 菜单栏等让视口比客户区小
// 几十像素时就是拒收 + 诊断）。
//
// 文本契约：查词命中回调要求 `hit.sourceText == texthooker 最新行文本`（见
// `GalHookTextOverlayController._onAttachedLookupText`），而 DOM 行进 texthooker 时
// `TexthookerService.appendLine` 会做 `<br>` 归一、注音标记剥离与 trim。所以载荷文本取
// 同一收口的结果，字形下标按 trim 掉的前导偏移平移；收口做了 trim 以外的改写（注音标记）
// 时不给几何——宁可这一句不能点，也不让下标错位。

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:fushi/src/mining/tyrano_dom/tyrano_dom_frame.dart';
import 'package:fushi/src/platform/gal_hook_text_overlay_channel.dart';
import 'package:fushi/src/sync/texthooker_service.dart'
    show normalizeTexthookerLineBreaks;
import 'package:fushi/src/utils/misc/ruby_markup.dart';

/// 一次 `attachedUpdateMeasuredText` 的内容。
@immutable
class GalAttachedMeasuredPayload {
  /// 创建载荷。
  const GalAttachedMeasuredPayload({
    required this.sourceText,
    required this.glyphs,
    required this.clientWidth,
    required this.clientHeight,
    required this.clientSizeTolerance,
  });

  /// 清空当前行（撤掉旧句的命中框）。
  const GalAttachedMeasuredPayload.clear()
    : sourceText = '',
      glyphs = const <GalAttachedMeasuredGlyph>[],
      clientWidth = 0,
      clientHeight = 0,
      clientSizeTolerance = 0;

  /// 当前行文本（与 texthooker 行文本逐字一致）。
  final String sourceText;

  /// 只含已显示字形；下标是 [sourceText] 的 UTF-16 区间。
  final List<GalAttachedMeasuredGlyph> glyphs;

  /// 测量时的视口物理宽。
  final int clientWidth;

  /// 测量时的视口物理高。
  final int clientHeight;

  /// [clientWidth]/[clientHeight] 与真实客户区之间允许的取整误差（物理像素），见
  /// [galAttachedMeasuredClientSizeTolerance]。
  final int clientSizeTolerance;

  /// 是否为清空。
  bool get isClear => sourceText.isEmpty;

  @override
  bool operator ==(Object other) {
    if (other is! GalAttachedMeasuredPayload ||
        other.sourceText != sourceText) {
      return false;
    }
    // 清空不带几何，尺寸无意义。
    if (isClear) return true;
    return other.clientWidth == clientWidth &&
        other.clientHeight == clientHeight &&
        other.clientSizeTolerance == clientSizeTolerance &&
        listEquals(other.glyphs, glyphs);
  }

  @override
  int get hashCode => isClear
      ? sourceText.hashCode
      : Object.hash(
          sourceText,
          clientWidth,
          clientHeight,
          clientSizeTolerance,
          Object.hashAll(glyphs),
        );
}

/// 「整数 CSS 视口 × [devicePixelRatio]」推出的客户区物理尺寸相对真实客户区的最大取整
/// 误差（物理像素）。
///
/// Chromium 把物理客户区 P 换成整数 CSS 视口 V（向上 / 就近取整），所以
/// `|V × dpr − P| < dpr`；Dart 再 `round(V × dpr)`。整数 dpr 时误差是整数，最多
/// `dpr − 1`（dpr = 1 时为 0，逐像素相等）；小数 dpr 时取整后最多 `ceil(dpr)`。
int galAttachedMeasuredClientSizeTolerance(double devicePixelRatio) {
  if (!devicePixelRatio.isFinite || devicePixelRatio <= 0) return 0;
  final int ceiled = devicePixelRatio.ceil();
  return devicePixelRatio == ceiled ? ceiled - 1 : ceiled;
}

/// DOM 正文进 texthooker 后的行文本（`appendLine` 同一收口）；收口带出注音 span 时返回 null。
String? tyranoDomTexthookerText(String domText) {
  final RubyMarkupText parsed = parseRubyMarkup(
    normalizeTexthookerLineBreaks(domText),
  ).trimmed();
  if (parsed.spans.isNotEmpty) return null;
  return parsed.text;
}

/// 把一帧转成实测排版载荷。
///
/// 只有 `complete` 帧带几何：逐字显示中的帧一律清空。理由（「点击查词不推进」与正确性）：
/// - 逐字显示期间玩家点击的本意是「跳过打字」，此时字形框若在，点击会被吞掉去查词，
///   玩家就推不动游戏；
/// - 保留上一句的框更错：上一句已不在画面上，点到的是旧句的字；
/// - 显示中的半句查词会截断词语，结果不可信。
///
/// 字形矩形 left/top 向下取整、right/bottom 向上取整（框只会略大不会漏字），再夹进
/// `[0, clientWidth] x [0, clientHeight]`；只发 `shown` 的字形，空框丢弃。
GalAttachedMeasuredPayload galAttachedMeasuredPayloadForFrame(
  TyranoDomFrame frame,
) {
  const GalAttachedMeasuredPayload clear = GalAttachedMeasuredPayload.clear();
  final int width = frame.clientWidth;
  final int height = frame.clientHeight;
  if (!frame.complete || width <= 0 || height <= 0) return clear;
  final String? lineText = tyranoDomTexthookerText(frame.text);
  if (lineText == null || lineText.isEmpty) return clear;
  // 收口只做了 trim 时 lineText 是原文的子串，首个匹配就是真实前导偏移（前面被
  // 切掉的全是空白，lineText 首字符不是空白）。
  final int lead = frame.text.indexOf(lineText);
  if (lead < 0) return clear;
  final int end = lead + lineText.length;
  final List<GalAttachedMeasuredGlyph> glyphs = <GalAttachedMeasuredGlyph>[];
  for (final TyranoDomGlyph glyph in frame.glyphs) {
    if (!glyph.shown || glyph.textLength <= 0) continue;
    final int start = glyph.textStart;
    if (start < lead || start + glyph.textLength > end) continue;
    final int left = math.max(0, glyph.rect.left.floor());
    final int top = math.max(0, glyph.rect.top.floor());
    final int right = math.min(
      width,
      (glyph.rect.left + glyph.rect.width).ceil(),
    );
    final int bottom = math.min(
      height,
      (glyph.rect.top + glyph.rect.height).ceil(),
    );
    if (right <= left || bottom <= top) continue;
    glyphs.add(
      GalAttachedMeasuredGlyph(
        start: start - lead,
        length: glyph.textLength,
        left: left,
        top: top,
        right: right,
        bottom: bottom,
      ),
    );
  }
  if (glyphs.isEmpty) return clear;
  return GalAttachedMeasuredPayload(
    sourceText: lineText,
    glyphs: List<GalAttachedMeasuredGlyph>.unmodifiable(glyphs),
    clientWidth: width,
    clientHeight: height,
    clientSizeTolerance: galAttachedMeasuredClientSizeTolerance(
      frame.devicePixelRatio,
    ),
  );
}
