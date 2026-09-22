import 'package:flutter/widgets.dart';

/// 播放器 chrome 的「小窗表面」种类：视频当前被摆在什么形态的窗口里。
///
/// 三态互斥，**不是**布尔「是不是小窗」——两种小窗的 chrome 归属完全相反：
/// 桌面小窗里 chrome 由本 app 画（系统只给一个无边框窗口），系统画中画里
/// chrome 由**系统**画（Android 在 PiP 窗口上叠自己的播放控件），app 再画一套
/// 就是两层按钮叠在一起。故 [pictureInPicture] 下本仓一律不画任何 chrome。
enum VideoMiniSurface {
  /// 常规窗口 / 常规全屏。
  none,

  /// 桌面「小窗模式」：主窗被缩成无边框置顶小窗（见 DesktopMiniWindowMode）。
  desktopMiniWindow,

  /// Android 系统画中画。系统自带播放控件，app 侧 chrome 必须全部让位。
  pictureInPicture;

  /// 系统已经在画自己的控件 → 本仓一个像素的 chrome 都不许再画。
  bool get systemOwnsChrome => this == VideoMiniSurface.pictureInPicture;
}

/// 控制条密度档位：按**播放区宽度**（不是屏幕宽度）分三档。
///
/// 只看宽度、不看高度，是为了不误伤移动端：视频页在手机上全程强制横屏，
/// 典型 844×390 的横屏高度只有 390，任何「高度 < N 就算小」的判据都会
/// 把正常手机播放判成小窗、把控件凭空缩掉一圈（纯回归）。宽度判据下
/// 手机横屏（最窄 iPhone SE 568）落在 [compact]，只吃一点点缩放；
/// [mini] 只有真·小窗或被拖到 480 逻辑像素以下的桌面窗口才够得着。
enum VideoControlsDensity { full, compact, mini }

/// 低于此宽度（逻辑像素）进 [VideoControlsDensity.mini]。
///
/// 取 480 是因为桌面主窗的常规最小尺寸就是 360×480（DesktopWindowPlacement
/// .minimumSize）：窗口被拖到比这更窄时，56px 的按钮行 + 进度条 + 顶栏标题
/// 已经占掉画面的一半以上，此时退化成「只剩画面 + 底部细进度条」才有意义。
const double kVideoControlsMiniWidth = 480;

/// 低于此宽度进 [VideoControlsDensity.compact]（控件整体等比缩小）。
const double kVideoControlsCompactWidth = 800;

/// 一档密度对应的 chrome 取舍。纯值对象，页面按字段分支，不在页面里散写阈值。
@immutable
class VideoControlsDensitySpec {
  const VideoControlsDensitySpec({
    required this.density,
    required this.scale,
    required this.showSeekBar,
    required this.showSeekLabels,
    required this.showTopBar,
    required this.showBottomButtonBar,
    required this.showCenterTransport,
  });

  final VideoControlsDensity density;

  /// 控制条尺寸乘数，叠在既有的「界面大小」缩放（`_videoUiScale`）之上。
  ///
  /// 页面的按钮行高 / 图标 / 播放键 / 进度条几何 getter 全部再乘本值，而字幕
  /// 避让的 reserve 读的**就是同一批 getter**，所以字幕会自动跟着一起上移/下移，
  /// 不需要第二条缩放链（多一条就必然漂，见 videoSubtitleControlsReserve 注释）。
  final double scale;

  /// 是否渲染 media_kit 自带的完整进度条。[VideoControlsDensity.mini] 下关掉，
  /// 进度指示改由视频最下方那条细线承担（见 videoSlimProgressBarVisible）。
  final bool showSeekBar;

  /// ±10 秒按钮是否带文字标注。窄屏退化成纯图标是既有行为（`_hasRoomyVideoBottomBar`
  /// 的 600 阈值），本字段只额外保证 mini 档一定不带标注。
  final bool showSeekLabels;

  /// 是否渲染顶栏（标题 + 右上角菜单）。
  final bool showTopBar;

  /// 是否渲染底部按钮行。mini 档整行让位给居中三键。
  final bool showBottomButtonBar;

  /// 是否渲染 mini 档专用的「居中大三键」（±10 秒 + 播放/暂停），即系统画中画
  /// 那种观感。只有 [VideoControlsDensity.mini] 且 chrome 归本仓时才为真。
  final bool showCenterTransport;

  /// mini 档（含桌面小窗与被拖窄的窗口）。
  bool get isMini => density == VideoControlsDensity.mini;
}

const VideoControlsDensitySpec _fullSpec = VideoControlsDensitySpec(
  density: VideoControlsDensity.full,
  scale: 1,
  showSeekBar: true,
  showSeekLabels: true,
  showTopBar: true,
  showBottomButtonBar: true,
  showCenterTransport: false,
);

const VideoControlsDensitySpec _compactSpec = VideoControlsDensitySpec(
  density: VideoControlsDensity.compact,
  scale: 0.88,
  showSeekBar: true,
  showSeekLabels: true,
  showTopBar: true,
  showBottomButtonBar: true,
  showCenterTransport: false,
);

const VideoControlsDensitySpec _miniSpec = VideoControlsDensitySpec(
  density: VideoControlsDensity.mini,
  scale: 0.72,
  showSeekBar: false,
  showSeekLabels: false,
  showTopBar: false,
  showBottomButtonBar: false,
  showCenterTransport: true,
);

/// 系统画中画：密度按 mini 算（字幕字号等仍该跟着缩），但 chrome 一律不画。
const VideoControlsDensitySpec _pictureInPictureSpec = VideoControlsDensitySpec(
  density: VideoControlsDensity.mini,
  scale: 0.72,
  showSeekBar: false,
  showSeekLabels: false,
  showTopBar: false,
  showBottomButtonBar: false,
  showCenterTransport: false,
);

/// 由播放区尺寸 + 小窗表面解出该用哪档 chrome。纯函数，页面与测试同源。
///
/// [playerSize] 传**播放区**尺寸而不是屏幕尺寸：字幕跳转侧栏是 push-aside 的
/// 真 `Row` 子列，开着它时画面会被挤窄，控件该跟着画面缩而不是跟着屏幕不动。
/// 尺寸非有限或 <= 0（首帧前 constraints 尚未落定）时退回 [VideoControlsDensity.full]，
/// 绝不在测量未就绪时闪一下 mini 形态。
VideoControlsDensitySpec resolveVideoControlsDensity({
  required Size playerSize,
  required VideoMiniSurface surface,
}) {
  if (surface == VideoMiniSurface.pictureInPicture) {
    return _pictureInPictureSpec;
  }
  if (surface == VideoMiniSurface.desktopMiniWindow) return _miniSpec;
  final double width = playerSize.width;
  if (!width.isFinite || width <= 0) return _fullSpec;
  if (width < kVideoControlsMiniWidth) return _miniSpec;
  if (width < kVideoControlsCompactWidth) return _compactSpec;
  return _fullSpec;
}

/// mini 档那套本仓自绘 chrome（顶部拖动带 + 退出钮、居中大三键）此刻该不该显形。
/// 纯函数，页面与测试同源。
///
/// **[revealed] 是唯一的动态输入，hover 不是**——这正是本函数存在的全部意义。
/// 小窗是「挂在屏幕角落一直开着」的形态：鼠标从它上面扫过去（甚至只是路过）就
/// 弹出一层按钮，在 300×170 的窗口里等于把画面盖掉一半，用户报「太乱」。故小窗
/// 常态只剩画面 + 字幕（字幕悬停制卡照常工作）+ 底部那条细线，整套 chrome 改由
/// [ShortcutAction.videoToggleMiniChrome] 显式唤出，且唤出后**不自动淡出**
/// （淡出会让「拖动窗口」变成和计时器赛跑）。
///
/// [spec] 那条门保证它只在**本仓负责画 chrome** 的那一档生效：常规档 chrome 归
/// media_kit（hover 唤起是那边的既有语义，不受本函数管），系统画中画下 chrome 归
/// 系统（[VideoControlsDensitySpec.showCenterTransport] 恒假，本仓一个像素都不画）。
///
/// [surface] 是第二道门：「只认显式唤出」只对**桌面小窗**成立。常规窗口被挤窄到
/// mini 档（字幕列表 push-aside、用户把窗口拉小）时 surface 仍是 none，media_kit
/// 那层顶栏 / 底栏 / seek bar 已整套关掉，本仓的三键是画面上**唯一**的控件——那时
/// 若也只认快捷键，鼠标悬停一个按钮都不出现（#1596 时 hover 还能唤出），Shift+M
/// 唤出后右上角「退出小窗」钮又是死的。故 none 表面保留 hover（[controlsVisible]）
/// 语义（PR #1600 审查）。
bool videoMiniChromeVisible({
  required VideoControlsDensitySpec spec,
  required VideoMiniSurface surface,
  required bool revealed,
  required bool controlsVisible,
}) {
  if (!spec.showCenterTransport) return false;
  if (surface == VideoMiniSurface.desktopMiniWindow) return revealed;
  return controlsVisible;
}

/// 视频最下方那条细进度条此刻该不该显形。纯函数，页面与测试同源。
///
/// 三条规则，按优先级：
///  1. 系统画中画里系统自己画进度，本仓再画一条就是重影 → 恒不显。
///  2. mini 档没有常规进度条（[VideoControlsDensitySpec.showSeekBar] 为假），
///     细线是**唯一**进度指示 → 恒显，不受开关管（开关管的是「常规档控制条
///     隐藏后要不要留一条」，而不是「小窗里要不要有进度」）。
///  3. 常规档：开关开着、且控制条已淡出时才显——控制条在场时它自己就有完整
///     进度条，两条并存是重影。
bool videoSlimProgressBarVisible({
  required VideoControlsDensitySpec spec,
  required VideoMiniSurface surface,
  required bool preferenceEnabled,
  required bool controlsVisible,
}) {
  if (surface.systemOwnsChrome) return false;
  if (!spec.showSeekBar) return true;
  return preferenceEnabled && !controlsVisible;
}
