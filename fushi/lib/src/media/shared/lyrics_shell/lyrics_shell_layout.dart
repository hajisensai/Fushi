// 歌词页外壳的几何（与有声书无关的部分，从 `media/audiobook/lyrics_player/` 原样抽出）。
//
// 有声书歌词模式（`lyrics_player_apple.dart` / `lyrics_player_md3.dart`）与音乐歌词页共用：
// 宽屏判据、Apple 风双栏 / 单栏几何、MD3 宽屏双栏几何与 mesh 背景底板。行为与像素不变。
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/utils/components/fushi_m3e_player.dart'
    show FushiMeshPlateResolver;

/// 宽屏（横屏 / 桌面窗口）才显示「左封面 + 控件、右歌词」双栏；手机竖屏或窄窗
/// 一律单栏：全屏歌词 + 底部紧凑控件条，不显示封面（放不下）。
bool lyricsPlayerIsWide(Size size) =>
    size.width >= 600 && size.width >= size.height;

// ---------------------------------------------------------------------------
// Apple 风几何：lyricsRect 与控件层必须出自同一份计算，否则歌词与面板会错位。
// ---------------------------------------------------------------------------

double _clampD(double value, double lo, double hi) =>
    math.min(math.max(value, lo), hi);

/// 宽屏双栏几何（Niratan `ReaderLyricsLayoutMetrics` + `playerPanel*` 系列）。
class LyricsShellAppleWideLayout {
  /// [mirror] = 左右互换进度：0 = 面板在左、歌词在右；1 = 歌词在左、面板在右；
  /// 中间值按比例线性插值两栏的左边（换位动画），各自宽度始终不变。
  factory LyricsShellAppleWideLayout(
    Size size,
    EdgeInsets padding, {
    double mirror = 0,
  }) {
    final double w = math.max(size.width, 1);
    final double h = math.max(size.height, 1);
    final double chromePad = _clampD(w * 0.038, 22, 34);
    final double headerTop = _clampD(h * 0.032, 14, 26);
    final double lyricsHPad = _clampD(w * 0.052, 22, 42);
    final double contentMaxWidth = _clampD(w - lyricsHPad * 2, 1, 920);
    final double left0 = padding.left + chromePad;
    final double top0 = padding.top + headerTop;
    final double avail = math.max(w - padding.horizontal - chromePad * 2, 1);
    final double availH = math.max(h - padding.vertical - headerTop * 2, 1);
    final double panelWidth = math.min(
      math.max(avail * 0.32, 220),
      math.min(430, avail * 0.44),
    );
    final double spacing = _clampD(avail * 0.06, 28, 96);
    final double lyricsWidth = math.max(
      math.min(contentMaxWidth, avail - panelWidth - spacing),
      260,
    );
    // Niratan 把「面板 + 间距 + 歌词」整体在内容区水平居中：铺满时与左对齐
    // 一致，超宽窗口两侧对称留白，而不是歌词贴左、右侧空一大片。
    final double total = panelWidth + spacing + lyricsWidth;
    final double startX = left0 + math.max(0, (avail - total) / 2);
    final double panelSpacing = _clampD(availH * 0.018, 8, 20);
    final double metadataHeight = _clampD(availH * 0.1, 50, 72);
    final double reserved =
        metadataHeight +
        kLyricsShellAppleScrubberHeight +
        64 +
        34 +
        panelSpacing * 4;
    final double artworkSize = math.min(
      panelWidth,
      math.max(availH - reserved, 96),
    );
    return LyricsShellAppleWideLayout._(
      chromePad: chromePad,
      headerTop: headerTop,
      panelLeft: startX + (lyricsWidth + spacing) * mirror,
      panelWidth: panelWidth,
      top: top0,
      height: availH,
      lyricsRect: Rect.fromLTWH(
        startX + (panelWidth + spacing) * (1 - mirror),
        top0,
        lyricsWidth,
        availH,
      ),
      panelSpacing: panelSpacing,
      metadataHeight: metadataHeight,
      artworkSize: artworkSize,
      controlSpacing: _clampD(panelWidth * 0.08, 16, 36),
    );
  }

  const LyricsShellAppleWideLayout._({
    required this.chromePad,
    required this.headerTop,
    required this.panelLeft,
    required this.panelWidth,
    required this.top,
    required this.height,
    required this.lyricsRect,
    required this.panelSpacing,
    required this.metadataHeight,
    required this.artworkSize,
    required this.controlSpacing,
  });

  final double chromePad;
  final double headerTop;
  final double panelLeft;
  final double panelWidth;
  final double top;
  final double height;
  final Rect lyricsRect;
  final double panelSpacing;
  final double metadataHeight;
  final double artworkSize;
  final double controlSpacing;
}

/// Niratan `ReaderLyricsVisualSpec.scrubberHeight`：进度条 + 时间两行的总高。
const double kLyricsShellAppleScrubberHeight = 34;

/// 窄屏（手机竖屏 / 窄窗）底部玻璃控制条高度：进度条 34 + 间距 4 + 按钮行 52
/// + 上下内边距 10×2。
const double kLyricsShellAppleNarrowBarHeight = 110;

/// 窄屏顶栏（书名 + 读数 + ✕）高度。
const double kLyricsShellAppleNarrowHeaderHeight = 44;

/// 窄屏单栏几何。
class LyricsShellAppleNarrowLayout {
  factory LyricsShellAppleNarrowLayout(Size size, EdgeInsets padding) {
    final double w = math.max(size.width, 1);
    final double h = math.max(size.height, 1);
    final double headerTop = padding.top + 8;
    // 有 home indicator 时贴着它上沿；没有安全区时离底 14（Apple Music 迷你条）。
    final double bottomGap = padding.bottom > 0 ? padding.bottom : 14;
    final double availW = math.max(w - padding.horizontal, 1);
    final double barWidth = math.min(availW - 24, 560);
    final double barLeft = padding.left + (availW - barWidth) / 2;
    final double barTop = h - bottomGap - kLyricsShellAppleNarrowBarHeight;
    final double lyricsTop =
        headerTop + kLyricsShellAppleNarrowHeaderHeight + 6;
    final double lyricsBottom = barTop - 6;
    return LyricsShellAppleNarrowLayout._(
      headerTop: headerTop,
      barRect: Rect.fromLTWH(
        barLeft,
        barTop,
        barWidth,
        kLyricsShellAppleNarrowBarHeight,
      ),
      lyricsRect: Rect.fromLTWH(
        padding.left + 8,
        lyricsTop,
        math.max(availW - 16, 1),
        math.max(lyricsBottom - lyricsTop, 1),
      ),
    );
  }

  const LyricsShellAppleNarrowLayout._({
    required this.headerTop,
    required this.barRect,
    required this.lyricsRect,
  });

  final double headerTop;
  final Rect barRect;
  final Rect lyricsRect;
}

// ---------------------------------------------------------------------------
// MD3 宽屏几何
// ---------------------------------------------------------------------------

/// 宽屏双栏几何。背景（画歌词底板）与 [Md3LyricsPlayerDesign.lyricsRect] /
/// 控件层共用同一份计算，三者才对得齐。
@immutable
class LyricsShellMd3WideGeometry {
  const LyricsShellMd3WideGeometry._({
    required this.panel,
    required this.plate,
    required this.lyrics,
  });

  /// [mirror] = 左右互换进度：0 = 封面栏在左、歌词底板在右；1 = 封面栏到右、
  /// 歌词底板到左；中间值把两端几何逐矩形线性插值（换位动画途中）。两栏宽度与
  /// 间距不变——换位置不会让歌词区变小。
  factory LyricsShellMd3WideGeometry.of(
    Size size,
    EdgeInsets padding, {
    double mirror = 0,
  }) {
    if (mirror <= 0) {
      return LyricsShellMd3WideGeometry._side(size, padding, mirrored: false);
    }
    if (mirror >= 1) {
      return LyricsShellMd3WideGeometry._side(size, padding, mirrored: true);
    }
    final LyricsShellMd3WideGeometry a = LyricsShellMd3WideGeometry._side(
      size,
      padding,
      mirrored: false,
    );
    final LyricsShellMd3WideGeometry b = LyricsShellMd3WideGeometry._side(
      size,
      padding,
      mirrored: true,
    );
    return LyricsShellMd3WideGeometry._(
      panel: Rect.lerp(a.panel, b.panel, mirror)!,
      plate: Rect.lerp(a.plate, b.plate, mirror)!,
      lyrics: Rect.lerp(a.lyrics, b.lyrics, mirror)!,
    );
  }

  factory LyricsShellMd3WideGeometry._side(
    Size size,
    EdgeInsets padding, {
    bool mirrored = false,
  }) {
    final double hPad = (size.width * 0.04).clamp(20.0, 56.0);
    final double left = padding.left + hPad;
    final double right = size.width - padding.right - hPad;
    final double top = padding.top + 20;
    final double bottom = math.max(top + 1, size.height - padding.bottom - 20);
    final double contentWidth = math.max(1, right - left);
    // 左栏比例参考 Niratan playerPanel（宽 32%、夹在 220–430），MD3 的控件更大
    // 一号，取 36% 夹在 260–440。
    final double maxPanel = math.min(440, contentWidth * 0.44);
    final double panelWidth = (contentWidth * 0.36).clamp(
      math.min(260.0, maxPanel),
      maxPanel,
    );
    final double gap = (contentWidth * 0.04).clamp(20.0, 64.0);
    final Rect panel = mirrored
        ? Rect.fromLTRB(right - panelWidth, top, right, bottom)
        : Rect.fromLTRB(left, top, left + panelWidth, bottom);
    final Rect plate = mirrored
        ? Rect.fromLTRB(left, top, math.max(left + 1, panel.left - gap), bottom)
        : Rect.fromLTRB(
            math.min(right - 1, panel.right + gap),
            top,
            right,
            bottom,
          );
    // 歌词矩形在底板里内缩：顶部留 64 给右上角关闭键（不让它压在首行上）。
    final Rect lyrics = Rect.fromLTRB(
      plate.left + 8,
      math.min(plate.bottom - 1, plate.top + 64),
      math.max(plate.left + 9, plate.right - 8),
      math.max(plate.top + 65, plate.bottom - 8),
    );
    return LyricsShellMd3WideGeometry._(
      panel: panel,
      plate: plate,
      lyrics: lyrics,
    );
  }

  final Rect panel;
  final Rect plate;
  final Rect lyrics;
}

/// 宽屏歌词底板（画在 mesh 背景里，WebView 在控件层下面）；窄屏不画。两个顶层
/// 函数而不是闭包：背景按解析器身份判断要不要重画。
Rect? _widePlateRect(Size page, EdgeInsets padding) => lyricsPlayerIsWide(page)
    ? LyricsShellMd3WideGeometry.of(page, padding).plate
    : null;

Rect? _widePlateRectMirrored(Size page, EdgeInsets padding) =>
    lyricsPlayerIsWide(page)
    ? LyricsShellMd3WideGeometry.of(page, padding, mirror: 1).plate
    : null;

/// 底板解析器：停在两端时返回上面两个顶层函数（身份稳定，背景不重画）；换位
/// 动画途中才返回按进度插值的闭包（每帧新身份 = 每帧重画，正是动画要的）。
FushiMeshPlateResolver lyricsShellMd3PlateResolver(double mirror) {
  if (mirror <= 0) return _widePlateRect;
  if (mirror >= 1) return _widePlateRectMirrored;
  return (Size page, EdgeInsets padding) => lyricsPlayerIsWide(page)
      ? LyricsShellMd3WideGeometry.of(page, padding, mirror: mirror).plate
      : null;
}
