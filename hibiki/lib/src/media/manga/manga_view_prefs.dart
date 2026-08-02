/// 漫画阅读器「观看偏好」的值域与枚举（缩放范围、灵敏度、翻页动画）。
///
/// 刻意做成**无依赖的叶子文件**：偏好仓库（`preferences_repository.dart`）、设置
/// schema、阅读器页面与 WebView 文档生成器四处都要用同一组边界值，此前这些数字
/// 被各自硬编码（`clamp(50, 200)` 在 Dart 侧 4 处 + JS 侧 2 处各写一遍），改一次
/// 范围要同步 6 个地方，漏一个就表现为「设置里能调到 400% 但阅读器里被打回 200%」。
library;

/// 漫画缩放百分比下限 / 上限（单一真相源）。
///
/// 上限从旧的 200% 提到 400%：200% 对高分屏上的小开本单页漫画根本不够（用户反馈
/// 「缩放极其不灵敏」的一半是这个天花板，而不是步长）。下限保持 50%。
const int kMangaZoomMinPercent = 50;
const int kMangaZoomMaxPercent = 400;

/// 缩放灵敏度倍率（百分比）。100 = 基准手感，越大滚轮/捏合每一步缩放越多。
const int kMangaZoomSensitivityMin = 25;
const int kMangaZoomSensitivityMax = 400;
const int kMangaZoomSensitivityDefault = 100;

/// 翻页动画样式。
///
/// 存字符串键而非 enum index：重排枚举不得破坏已落盘的偏好。
enum MangaPageAnimation { none, slide, fade }

extension MangaPageAnimationKey on MangaPageAnimation {
  String get key {
    switch (this) {
      case MangaPageAnimation.none:
        return 'none';
      case MangaPageAnimation.slide:
        return 'slide';
      case MangaPageAnimation.fade:
        return 'fade';
    }
  }

  /// 动画时长（毫秒）。`none` 恒 0，供 CSS `transition-duration` 直接使用。
  int get durationMs {
    switch (this) {
      case MangaPageAnimation.none:
        return 0;
      case MangaPageAnimation.slide:
        return 180;
      case MangaPageAnimation.fade:
        return 160;
    }
  }

  /// 未知值一律回落 [MangaPageAnimation.slide]（旧版本行为 = 有滑动过渡）。
  static MangaPageAnimation fromKey(String raw) {
    switch (raw) {
      case 'none':
        return MangaPageAnimation.none;
      case 'fade':
        return MangaPageAnimation.fade;
      case 'slide':
      default:
        return MangaPageAnimation.slide;
    }
  }
}
