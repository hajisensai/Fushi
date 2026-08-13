import 'package:flutter/widgets.dart';

import 'package:fushi/src/media/video/video_asbplayer_config.dart';
import 'package:fushi/src/media/video/video_control_customization.dart';
import 'package:fushi/src/media/video/video_danmaku_model.dart';
import 'package:fushi/src/media/video/video_mpv_config.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/media/video/video_immersive_mode.dart';
import 'package:fushi/src/media/video/video_shader_tier.dart';
import 'package:fushi/src/media/video/video_subtitle_obscure_mode.dart';
import 'package:fushi/src/media/video/video_subtitle_style.dart';
import 'package:fushi/src/settings/video_settings_host.dart';
import 'package:fushi_audio/fushi_audio.dart';

/// 视频播放页挂到 [SettingsContext.video] 的类型化能力槽（阶段 B）。
///
/// 承载 schema 投影的视频项在「播放中」需要的一切页面回调：即时应用到活播放器
/// （倍速 / mpv / 字幕样式实时预览）、页面级持久化（`_setSpeed` / `_setAsbConfig`
/// 等既有方法）与仅播放中才有的数据源（音/字幕轨、波形对轴输入）。全局设置页不
/// 构造本对象（`SettingsContext.video == null`），控制器绑定行据此自然隐藏；纯
/// pref 行在无 host 时退化为直接读写 appModel（与旧首页行为一致）。
///
/// 刻意不 import media_kit：所有播放器交互都以回调闭包进来（由视频页在构造时
/// 捕获 controller），settings/ 与 schema 依赖图保持无播放器类型。
class VideoQuickSettingsHost extends VideoSettingsHost {
  const VideoQuickSettingsHost({
    required this.uiScale,
    required this.isTouchControls,
    required this.delayMs,
    required this.onSetDelay,
    this.secondaryDelayMs,
    this.onSetSecondaryDelay,
    this.hasSecondarySubtitle,
    this.onAutoAlign,
    this.subtitleWaveformCues = const <AudioCue>[],
    this.videoDurationMs = 0,
    this.loadSubtitleWaveform,
    this.onPlaySubtitleCue,
    this.subtitleIsPlaying,
    this.onToggleSubtitlePlayPause,
    this.subtitleAlignShortcuts,
    this.onSeekSubtitleWaveform,
    this.subtitlePositionListenable,
    this.currentSubtitlePositionMs,
    required this.speed,
    required this.onPreviewSpeed,
    required this.onSetSpeed,
    required this.onSetSubtitleObscureMode,
    required this.onSetSecondarySubtitleObscureMode,
    required this.subtitleStyle,
    required this.onSubtitleStylePreview,
    required this.onSubtitleStyleCommit,
    this.onEnterSubtitleDragAdjust,
    this.onRespectAssStyleChanged,
    required this.onAsbConfigChanged,
    required this.onMpvConfigChanged,
    required this.onApplyShaders,
    required this.onSelectShaderTier,
    this.onMpvShaderDirChanged,
    required this.onLockWindowAspectRatioChanged,
    required this.onVideoFitModeChanged,
    required this.onImmersiveModeChanged,
    required this.controlLayout,
    this.onControlLayoutChanged,
    this.qualityOptionCount = 0,
    this.qualityCurrentLabel,
    this.onOpenQuality,
    this.onSwitchToSkiaRenderer,
    this.onDanmakuEnabledChanged,
    this.onDanmakuOnlineEnabledChanged,
    this.onDanmakuMaxActiveChanged,
    required this.danmakuStyle,
    this.onDanmakuStylePreview,
    this.onDanmakuStyleCommit,
    this.onDanmakuBlockRulesChanged,
    this.onManualDanmakuMatch,
    this.audioTrackSection,
    this.subtitleTrackSection,
    this.onSubtitleCategoryShown,
  });

  /// 实际 app UI scale。视频路由把 [FushiAppUiScale] 中和为 1.0，面板内继承的
  /// scale 不代表全局设置值，故显式带入（字幕字重/阴影按它 resolve）。
  final double uiScale;

  /// 触屏控件（无右键菜单兜底）：控件编辑器禁止把「设置」按钮拖入 hidden（TODO-554）。
  final bool isTouchControls;

  // ── 字幕调轴（A/V 延迟，per-media DB 持久化，仅播放中有意义）──────────────
  final int Function() delayMs;
  final Future<void> Function(int delayMs) onSetDelay;

  /// TODO-2837：副字幕独立调轴当前值（null = 跟随主字幕）。三件套（本值 /
  /// [onSetSecondaryDelay] / [hasSecondarySubtitle]）齐备且副字幕轨激活时，
  /// 调轴行才显示副轨独立一段；不齐（全局设置页等无播放器上下文）自然隐藏。
  final int? Function()? secondaryDelayMs;

  /// TODO-2837：设置副字幕独立调轴（null = 重置为跟随主字幕）。
  final Future<void> Function(int? delayMs)? onSetSecondaryDelay;

  /// TODO-2837：副字幕轨当前是否激活（cue 流非空）。活值 getter——面板内切换
  /// 副字幕轨后经 [subtitlePositionListenable]（controller）的通知即时显隐。
  final bool Function()? hasSecondarySubtitle;

  final Future<int?> Function()? onAutoAlign;
  final List<AudioCue> subtitleWaveformCues;
  final int videoDurationMs;
  final Future<List<double>> Function()? loadSubtitleWaveform;
  final Future<void> Function(int startMs)? onPlaySubtitleCue;
  final bool Function()? subtitleIsPlaying;
  final Future<void> Function()? onToggleSubtitlePlayPause;
  final Map<ShortcutActivator, VoidCallback>? subtitleAlignShortcuts;
  final Future<void> Function(int positionMs)? onSeekSubtitleWaveform;
  final Listenable? subtitlePositionListenable;
  final int Function()? currentSubtitlePositionMs;

  // ── 倍速（拖动实时预览不落盘，松手提交）──────────────────────────────────
  final double Function() speed;
  final Future<void> Function(double speed) onPreviewSpeed;
  final Future<void> Function(double speed) onSetSpeed;

  // ── 字幕遮蔽 / 外观（页面持久化 + overlay 即时刷新 / 实时预览）───────────
  final Future<void> Function(VideoSubtitleObscureMode mode)
      onSetSubtitleObscureMode;
  final Future<void> Function(VideoSubtitleObscureMode mode)
      onSetSecondarySubtitleObscureMode;

  /// 页面当前生效的字幕样式（含拖动中的预览态），schema 滑条以它为权威值回显。
  final VideoSubtitleStyle Function() subtitleStyle;
  final void Function(VideoSubtitleStyle style) onSubtitleStylePreview;
  final Future<void> Function(VideoSubtitleStyle style) onSubtitleStyleCommit;

  /// 进入「拖拽调整字幕位置」模式（TODO-2838）：页面关设置侧栏 + 打开拖拽模式，
  /// 字幕 overlay 显示可拖指示、竖直拖动写回位置偏好。null = 面板不显示该入口
  /// （全局设置页 / 无播放器场景）。
  final VoidCallback? onEnterSubtitleDragAdjust;
  final Future<void> Function(bool value)? onRespectAssStyleChanged;

  // ── 手势/播放行为 JSON pref（页面持久化 + 即时生效）──────────────────────
  final Future<void> Function(VideoAsbplayerConfig config) onAsbConfigChanged;

  // ── mpv 配置（页面持久化 + applyMpvConfig 实时应用）──────────────────────
  final Future<void> Function(VideoMpvConfig config) onMpvConfigChanged;

  // ── 着色器（下载/勾选/一键选档，仅播放中实时应用）────────────────────────
  final Future<void> Function(List<String> enabledNames) onApplyShaders;
  final Future<void> Function(
    VideoShaderTier tier,
    bool highQuality,
    List<String> enabledNames,
  ) onSelectShaderTier;
  final Future<void> Function(String dir)? onMpvShaderDirChanged;

  // ── 画面/窗口/沉浸（页面持久化 + 重建 Video / 原生窗口联动）──────────────
  final Future<void> Function(bool value) onLockWindowAspectRatioChanged;
  final Future<void> Function(VideoFitMode mode) onVideoFitModeChanged;
  final Future<void> Function(VideoImmersiveMode mode) onImmersiveModeChanged;

  // ── 控制条 9 槽位布局 ─────────────────────────────────────────────────────
  final VideoControlLayout Function() controlLayout;
  final Future<void> Function(VideoControlLayout layout)?
      onControlLayoutChanged;

  // ── HLS 画质入口 / Skia 降级入口（仅特定流/机型出现）─────────────────────
  final int qualityOptionCount;
  final String? qualityCurrentLabel;
  final VoidCallback? onOpenQuality;
  final VoidCallback? onSwitchToSkiaRenderer;

  // ── 弹幕（页面持久化 + 弹幕层即时刷新 / 实时预览）────────────────────────
  final Future<void> Function(bool value)? onDanmakuEnabledChanged;
  final Future<void> Function(bool value)? onDanmakuOnlineEnabledChanged;
  final Future<void> Function(int value)? onDanmakuMaxActiveChanged;

  /// 页面当前生效的弹幕样式（含拖动中的预览态）。
  final VideoDanmakuStyle Function() danmakuStyle;
  final ValueChanged<VideoDanmakuStyle>? onDanmakuStylePreview;
  final Future<void> Function(VideoDanmakuStyle style)? onDanmakuStyleCommit;
  final Future<void> Function(String rulesText)? onDanmakuBlockRulesChanged;
  final VoidCallback? onManualDanmakuMatch;

  // ── 轨切换区（TODO-1351：由视频页构建，随页面 rebuild 刷新选中态）────────
  final Widget? audioTrackSection;
  final Widget? subtitleTrackSection;
  final VoidCallback? onSubtitleCategoryShown;
}
