/// Apple（Cupertino，iOS 27 / macOS 27）设计系统的圆角刻度令牌。
///
/// 与 M3E 的 `FushiM3eShape` / `FushiBorderRadius` 平行、互不混用：Apple 专属文件
/// 与混写文件的 Apple 分支只从这里取圆角，M3E 分支仍走 M3E 形状令牌
/// （`apple_design_tokens_guard_test.dart` 咬住）。
///
/// 按 [FushiAppleMetrics] 分两档：iOS 档取 iOS 27 的数值；macOS 档取 macOS 27 的
/// 数值并乘 [FushiAppleMetrics.scale]（Windows / Linux 宽窗放大，Mac 1.0），与字号、
/// 行高同一套放大系数。只有输入框与选中底两档数值不同，其余同值。
///
/// 不在刻度里的两类圆角保持派生写法，不进令牌：胶囊（`extent / 2`）与随尺寸
/// 成比例的连续曲率方块（应用图标式 `side * 0.22`）。纯度量，不渲染任何东西。
library;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart';

/// Apple 圆角刻度（见库注释）。[FushiAppleRadii.of] 取当前档。
@immutable
class FushiAppleRadii {
  const FushiAppleRadii._(this._metrics);

  /// 当前上下文的档位（与 [FushiAppleMetrics.of] 同一判据）。
  factory FushiAppleRadii.of(BuildContext context) =>
      FushiAppleRadii._(FushiAppleMetrics.of(context));

  /// 固定 iOS 档刻度（[FushiAppleMetrics.ios]）：只给自带固定度量、不随档位
  /// 换算的媒体面用，其余一律 [FushiAppleRadii.of]。
  static const FushiAppleRadii ios = FushiAppleRadii._(FushiAppleMetrics.ios);

  final FushiAppleMetrics _metrics;

  /// macOS 档（桌面平台宽窗）。
  bool get desktop => _metrics.desktop;

  /// macOS 档放大系数（[fushiAppleMacScale]），iOS 档恒 1.0。
  double get scale => _metrics.scale;

  /// 图表格 / 色阶块等小色块的角：2。
  double get mark => 2 * scale;

  /// 描边小徽标（Explicit 标记、按键帽式小标签）：4。
  double get badge => 4 * scale;

  /// 小缩略图（列表行封面、海报占位、来源条小封面）：6。
  double get thumbnail => 6 * scale;

  /// 中等封面 / 插图卡（迷你播放条封面、歌词页小插图与封面位）：8。
  double get cover => 8 * scale;

  /// 列表行的选中底 / 键盘焦点框：macOS 源列表选中 6，iOS 单元格高亮 10。
  double get selection => (desktop ? 6 : 10) * scale;

  /// 按下高亮 / 小控件的点按面（段头、组件内小行、提示卡动作）：8。
  double get highlight => 8 * scale;

  /// 输入框与读数框（UITextField / NSTextField 外壳）：macOS 6，iOS 10。
  double get field => (desktop ? 6 : 10) * scale;

  /// 宫格小方块（推荐页图标块）：10。
  double get tile => 10 * scale;

  /// 大封面（播放器主封面、书封卡）：12。
  double get artwork => 12 * scale;

  /// 浮在内容上的卡片（插图浮窗、行内弹出菜单）：14。
  double get popover => 14 * scale;

  /// 分组 / 卡片容器：即 [FushiAppleMetrics.groupRadius]（iOS 26 / macOS 10）。
  double get group => _metrics.groupRadius;

  BorderRadius get markRadius => BorderRadius.circular(mark);
  BorderRadius get badgeRadius => BorderRadius.circular(badge);
  BorderRadius get thumbnailRadius => BorderRadius.circular(thumbnail);
  BorderRadius get coverRadius => BorderRadius.circular(cover);
  BorderRadius get selectionRadius => BorderRadius.circular(selection);
  BorderRadius get highlightRadius => BorderRadius.circular(highlight);
  BorderRadius get fieldRadius => BorderRadius.circular(field);
  BorderRadius get tileRadius => BorderRadius.circular(tile);
  BorderRadius get artworkRadius => BorderRadius.circular(artwork);
  BorderRadius get popoverRadius => BorderRadius.circular(popover);
  BorderRadius get groupRadius => BorderRadius.circular(group);
}
