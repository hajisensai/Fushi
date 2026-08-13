import 'package:flutter/material.dart';

/// 弹幕基准字号（`fontScale = 1.0` 时的 px）。
///
/// 这是**字号唯一真相源**：渲染（[videoDanmakuTextStyle]）与几何测量
/// （[VideoDanmakuTextMetrics]）共用，避免「按 18px 估宽、按 20px 渲染」这类
/// 两份真相导致弹幕没滑出屏幕就被判过期而突然截断消失。
const double kVideoDanmakuBaseFontSize = 20.0;

/// 描边阴影的偏移与模糊半径（px）。单独抽出来是因为它们不只是外观：阴影会画到字形
/// 之外，滚动弹幕的行程必须把这一段也走完（见 [kVideoDanmakuShadowOverflow]）。
const double _kVideoDanmakuShadowOffset = 1.0;
const double _kVideoDanmakuShadowBlur = 3.0;

/// 阴影相对文本框向外溢出的最大距离（px）。
///
/// 文本框右边缘刚压到视口左边界时，阴影还在屏内留着一道 [kVideoDanmakuShadowOverflow]
/// 宽的残影——那一帧过后弹幕离开活动集，这道残影就是被「抹掉」而不是「走出去」的。
/// 滚动行程多走这一段，退场才真的发生在屏幕之外。
const double kVideoDanmakuShadowOverflow =
    _kVideoDanmakuShadowOffset + _kVideoDanmakuShadowBlur;

/// 弹幕文本样式。渲染与测量必须走这同一个构造函数——测量用的字号/字重一旦与渲染
/// 不一致，出屏时刻就会算错。[color] 不影响几何，测量时传任意值即可。
///
/// `inherit: false` 是几何正确性的一部分，不是风格偏好：默认的 `inherit: true` 会
/// 让 `Text` 把宿主的 `DefaultTextStyle` 合并进来（Material 的 `letterSpacing: 0.25`
/// 就能让一条 22 字的弹幕多出 5.5px），而纯函数的测量侧拿不到那份主题，两边立刻
/// 漂开。弹幕外观自给自足，也顺带不再随宿主主题变形。
TextStyle videoDanmakuTextStyle({
  required Color color,
  required double fontScale,
}) {
  return TextStyle(
    inherit: false,
    color: color,
    fontSize: kVideoDanmakuBaseFontSize * fontScale,
    fontWeight: FontWeight.w700,
    shadows: const <Shadow>[
      Shadow(
        color: Colors.black,
        blurRadius: _kVideoDanmakuShadowBlur,
        offset: Offset(_kVideoDanmakuShadowOffset, _kVideoDanmakuShadowOffset),
      ),
      Shadow(
        color: Colors.black,
        blurRadius: _kVideoDanmakuShadowBlur,
        offset:
            Offset(-_kVideoDanmakuShadowOffset, -_kVideoDanmakuShadowOffset),
      ),
    ],
  );
}

/// 弹幕文本**实测**宽度（含缓存）。
///
/// 滚动弹幕的出屏位置是 `x = 视口宽 - (视口宽 + 文本宽) * progress`：`progress`
/// 走到 1 的同一刻该条弹幕就会离开活动集，所以「文本宽」必须是真实渲染宽度，
/// 否则文本右半截还留在画面内就被整条抹掉（观感=弹幕走到一半突然消失）。
///
/// 每帧最多测几十条且文本高度重复，按 `(fontScale, text)` 缓存后热路径只是一次
/// Map 查找；缓存超过 [maxEntries] 整体清空（活动窗口只有几十条，重建代价可忽略），
/// 避免长片累积几万条文本把内存吃掉。
class VideoDanmakuTextMetrics {
  VideoDanmakuTextMetrics({this.maxEntries = 512});

  /// 进程级共享实例（弹幕样式全局唯一，缓存跨视频复用即可）。
  static final VideoDanmakuTextMetrics shared = VideoDanmakuTextMetrics();

  final int maxEntries;

  final Map<String, double> _cache = <String, double>{};

  /// 单行高度只随 [fontScale] 变，与文本无关，单独缓存（键极少，不参与整体清空）。
  final Map<double, double> _lineHeightCache = <double, double>{};

  final TextPainter _painter = TextPainter(
    textDirection: TextDirection.ltr,
    maxLines: 1,
    textScaler: TextScaler.noScaling,
  );

  /// [text] 在 [fontScale] 下的真实渲染宽度（px）。
  double widthOf(String text, double fontScale) {
    if (text.isEmpty) return 0;
    final String key = '${fontScale.toStringAsFixed(3)}$text';
    final double? cached = _cache[key];
    if (cached != null) return cached;
    _painter
      ..text = TextSpan(
        text: text,
        style: videoDanmakuTextStyle(
          color: const Color(0xFFFFFFFF),
          fontScale: fontScale,
        ),
      )
      ..layout();
    final double width = _painter.width;
    if (_cache.length >= maxEntries) _cache.clear();
    _cache[key] = width;
    return width;
  }

  /// [fontScale] 下弹幕单行的真实渲染高度（px）。
  ///
  /// 它是行距的下限：行比字还矮，上下两行就直接糊在一起。样本混排汉字与拉丁字母，
  /// 取字体实际报告的行高，而不是「字号 × 拍脑袋系数」。
  double lineHeight(double fontScale) {
    final double? cached = _lineHeightCache[fontScale];
    if (cached != null) return cached;
    _painter
      ..text = TextSpan(
        text: 'あA',
        style: videoDanmakuTextStyle(
          color: const Color(0xFFFFFFFF),
          fontScale: fontScale,
        ),
      )
      ..layout();
    final double height = _painter.height;
    _lineHeightCache[fontScale] = height;
    return height;
  }

  @visibleForTesting
  void clearCache() {
    _cache.clear();
    _lineHeightCache.clear();
  }
}
