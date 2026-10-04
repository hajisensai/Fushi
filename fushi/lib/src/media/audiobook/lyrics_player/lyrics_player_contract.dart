import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/widgets.dart';

/// 歌词播放覆盖层（Apple / MD3 两套样式）共用的数据契约。
///
/// 架构（2026-10-04 用户拍板，对齐 Niratan）：歌词模式是**盖在阅读器上的一层**。
/// 阅读器 WebView 在下面照常存活、照常跟随音频翻页 / 高亮、照常由它自己的
/// `_refreshProgress` → 阅读账本 / `StudyClock` 记统计；覆盖层只**显示**阅读器
/// 产出的读数（[LyricsPlayerStats]），自身不写任何统计。
///
/// 覆盖层由三层叠成（见 `lyrics_player_overlay.dart`）：
///  1. 背景（设计系统各自画：Apple 是强模糊封面，MD3 是封面动态取色渐变）；
///  2. 歌词 WebView，放在 [LyricsPlayerDesign.lyricsRect] 给出的矩形里（透明底，
///     背景透出来）——它在树里的位置恒定，换布局只改矩形、不重建平台视图；
///  3. 控件层（封面卡 / 标题 / 读数 / 进度条 / 播放键 / 关闭键）。控件层只在
///     自己画了东西的地方吃指针，空白处让给下面的歌词 WebView。

/// 宽屏（横屏 / 桌面窗口）才显示「左封面 + 控件、右歌词」双栏；手机竖屏或窄窗
/// 一律单栏：全屏歌词 + 底部紧凑控件条，不显示封面（放不下）。
bool lyricsPlayerIsWide(Size size) =>
    size.width >= 600 && size.width >= size.height;

/// 覆盖层要显示的阅读器读数快照。**只读**——数据来自阅读器的 `StudyClock`
/// （本次会话时长 / 字数）与进度状态（全书已读 / 总字数），覆盖层不写回。
@immutable
class LyricsPlayerStats {
  const LyricsPlayerStats({
    required this.sessionDurationMs,
    required this.sessionChars,
    required this.tracking,
    this.currentChars,
    this.totalChars,
  });

  static const LyricsPlayerStats empty = LyricsPlayerStats(
    sessionDurationMs: 0,
    sessionChars: 0,
    tracking: false,
  );

  /// 本次会话阅读时长（毫秒）。
  final int sessionDurationMs;

  /// 本次会话读过的字数。
  final int sessionChars;

  /// 计时器是否在走（手动暂停 / 后台时为 false）。
  final bool tracking;

  /// 全书已读到的字数（阅读器进度）；未就绪为 null。
  final int? currentChars;

  /// 全书总字数；未就绪为 null。
  final int? totalChars;

  /// 阅读速度（字 / 小时）。会话不足 1 秒时按 0。
  int get charsPerHour {
    if (sessionDurationMs < 1000) return 0;
    return (sessionChars * 3600000 / sessionDurationMs).round();
  }

  /// 全书进度百分比（0–100），未就绪为 null。
  double? get percent {
    final int? cur = currentChars;
    final int? total = totalChars;
    if (cur == null || total == null || total <= 0) return null;
    return (cur / total * 100).clamp(0.0, 100.0);
  }

  @override
  bool operator ==(Object other) =>
      other is LyricsPlayerStats &&
      other.sessionDurationMs == sessionDurationMs &&
      other.sessionChars == sessionChars &&
      other.tracking == tracking &&
      other.currentChars == currentChars &&
      other.totalChars == totalChars;

  @override
  int get hashCode => Object.hash(
    sessionDurationMs,
    sessionChars,
    tracking,
    currentChars,
    totalChars,
  );
}

/// 时长显示：`m:ss`，满 1 小时 `h:mm:ss`（与 Niratan `lyricsTimeText` 同口径）。
String formatLyricsPlayerTime(Duration d) {
  final int total = math.max(0, d.inSeconds);
  final int h = total ~/ 3600;
  final int m = total ~/ 60 % 60;
  final int s = total % 60;
  final String ss = s.toString().padLeft(2, '0');
  if (h > 0) return '$h:${m.toString().padLeft(2, '0')}:$ss';
  return '$m:$ss';
}

/// 覆盖层一帧的静态数据（换书 / 播放态 / 倍速变化时重建）。高频变化的播放位置与
/// 读数走 [LyricsPlayerClock]，由控件层自己按帧 / 按秒读，不经整页重建。
@immutable
class LyricsPlayerData {
  const LyricsPlayerData({
    required this.title,
    required this.cover,
    required this.isPlaying,
    required this.speed,
    required this.lyricsMasked,
    required this.clock,
  });

  /// 书名。
  final String title;

  /// 封面（无封面为 null，设计系统画占位）。
  final ImageProvider? cover;

  /// 是否正在播放。
  final bool isPlaying;

  /// 当前倍速。
  final double speed;

  /// 歌词遮罩（听力沉浸模糊，偏好 `lyrics_blur`）是否开着——👁 键的状态。
  final bool lyricsMasked;

  /// 高频读数来源。
  final LyricsPlayerClock clock;
}

/// 播放位置与读数的读口。控件层用 Ticker / 定时器轮询（只读、无副作用）。
abstract class LyricsPlayerClock {
  /// 全书播放位置（多文件有声书已换算成全书时间轴）。
  Duration get position;

  /// 全书总时长；未知为 [Duration.zero]。
  Duration get duration;

  /// 阅读器读数快照（只读）。
  LyricsPlayerStats get stats;
}

/// 覆盖层上的全部操作。全部由阅读器页面实现；覆盖层自己不碰播放器 / 统计。
@immutable
class LyricsPlayerCallbacks {
  const LyricsPlayerCallbacks({
    required this.onClose,
    required this.onPlayPause,
    required this.onPreviousCue,
    required this.onNextCue,
    required this.onSeek,
    required this.onToggleMask,
    required this.onOpenStatistics,
    required this.onSpeedChanged,
    required this.onMore,
    required this.onTapBackground,
  });

  /// 退出歌词模式（回到下面的阅读器）。
  final VoidCallback onClose;

  final VoidCallback onPlayPause;

  /// 上一句 / 下一句（有声书 cue）。
  final VoidCallback onPreviousCue;
  final VoidCallback onNextCue;

  /// 拖动进度条松手：跳到全书时间轴上的这一位置。
  final ValueChanged<Duration> onSeek;

  /// 👁：切换歌词遮罩（听力沉浸模糊）。
  final VoidCallback onToggleMask;

  /// 📈：打开阅读统计（阅读器的统计侧栏，只读展示）。
  final VoidCallback onOpenStatistics;

  /// 倍速选择。
  final ValueChanged<double> onSpeedChanged;

  /// ⋯：更多（阅读器的完整操作菜单：目录 / 设置 / 有声书面板 / 收藏…）。
  /// 参数是按钮的全局矩形，供菜单锚定。
  final ValueChanged<Rect> onMore;

  /// 点到背景空白处（关查词弹窗等）。
  final VoidCallback onTapBackground;
}

/// 可选的倍速档位（与有声书面板一致）。
const List<double> kLyricsPlayerSpeeds = <double>[
  0.5,
  0.75,
  1.0,
  1.25,
  1.5,
  1.75,
  2.0,
];

/// 一套设计系统的歌词播放器外观。实现只负责「画」，不持有业务状态。
abstract class LyricsPlayerDesign {
  const LyricsPlayerDesign();

  /// 歌词 WebView 在覆盖层里的矩形（覆盖层局部坐标）。[padding] 是系统安全区
  /// （状态栏 / 刘海 / 手势条）。宽屏 = 右栏，窄屏 = 顶栏与底部控件条之间。
  Rect lyricsRect(Size size, EdgeInsets padding);

  /// 背景层（铺满）。必须是不透明的——它就是歌词页的底色。
  Widget buildBackground(BuildContext context, LyricsPlayerData data);

  /// 控件层（铺满，透明处不吃指针）。[lyricsRect] 是 [lyricsRect] 算出的同一个矩形，
  /// 供控件避让 / 对齐。
  Widget buildChrome(
    BuildContext context,
    LyricsPlayerData data,
    LyricsPlayerCallbacks callbacks, {
    required Size size,
    required EdgeInsets padding,
    required Rect lyricsRect,
  });

  /// 歌词文档的配色与排版（下发给 HTML 的 CSS 变量）。
  LyricsHtmlTheme htmlTheme(BuildContext context, LyricsPlayerData data);
}

/// 歌词 HTML 的主题参数（`LyricsModeHtml` 渲染成 CSS 变量；运行期可热更）。
@immutable
class LyricsHtmlTheme {
  const LyricsHtmlTheme({
    required this.textColor,
    required this.currentColor,
    required this.accentColor,
    required this.selectionTextColor,
    required this.contextOpacities,
    required this.browsingOpacity,
    required this.deselectedScale,
    required this.anchorY,
    required this.edgeFade,
    required this.alignStart,
    required this.contextBlurPx,
    required this.rowRadius,
    required this.hoverFill,
  });

  /// 非当前行文字色（不含透明度，透明度由 [contextOpacities] 决定）。
  final Color textColor;

  /// 当前行文字色。
  final Color currentColor;

  /// 查词高亮 / 选区底色。
  final Color accentColor;

  /// 选区内文字色。
  final Color selectionTextColor;

  /// 跟随播放时，距当前行 1、2、3、4+ 行的不透明度（Niratan `contextLineOpacities`）。
  final List<double> contextOpacities;

  /// 用户手动滚动（脱离跟随）时非当前行的统一不透明度。
  final double browsingOpacity;

  /// 非当前行缩放（当前行 1.0）。
  final double deselectedScale;

  /// 当前行落在视口高度的哪个比例处（0–1，Niratan 0.46）。
  final double anchorY;

  /// 上下边缘渐隐占视口的比例（0 = 不渐隐）。
  final double edgeFade;

  /// 横排是否左对齐（false = 居中，旧歌词页观感）。
  final bool alignStart;

  /// 非当前行的轻模糊（px，0 = 不模糊）。
  final double contextBlurPx;

  /// 行悬停底块圆角（px）。
  final double rowRadius;

  /// 行悬停底块颜色（含透明度）。
  final Color hoverFill;

  @override
  bool operator ==(Object other) =>
      other is LyricsHtmlTheme &&
      other.textColor == textColor &&
      other.currentColor == currentColor &&
      other.accentColor == accentColor &&
      other.selectionTextColor == selectionTextColor &&
      listEquals(other.contextOpacities, contextOpacities) &&
      other.browsingOpacity == browsingOpacity &&
      other.deselectedScale == deselectedScale &&
      other.anchorY == anchorY &&
      other.edgeFade == edgeFade &&
      other.alignStart == alignStart &&
      other.contextBlurPx == contextBlurPx &&
      other.rowRadius == rowRadius &&
      other.hoverFill == hoverFill;

  @override
  int get hashCode => Object.hash(
    textColor,
    currentColor,
    accentColor,
    selectionTextColor,
    Object.hashAll(contextOpacities),
    browsingOpacity,
    deselectedScale,
    anchorY,
    edgeFade,
    alignStart,
    contextBlurPx,
    rowRadius,
    hoverFill,
  );
}
