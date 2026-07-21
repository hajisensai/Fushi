import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';

import 'package:hibiki/src/media/video/video_asbplayer_config.dart';
import 'package:hibiki/src/media/video/video_control_customization.dart';
import 'package:hibiki/src/media/video/video_control_layout_editor.dart';
import 'package:hibiki/src/media/video/video_danmaku_model.dart';
import 'package:hibiki/src/media/video/video_immersive_mode.dart';
import 'package:hibiki/src/media/video/video_mpv_config.dart';
import 'package:hibiki/src/media/video/video_quick_settings_host.dart';
import 'package:hibiki/src/media/video/video_shader_manager.dart';
import 'package:hibiki/src/media/video/video_shader_tier.dart';
import 'package:hibiki/src/media/video/video_subtitle_obscure_mode.dart';
import 'package:hibiki/src/media/video/video_subtitle_style.dart';
import 'package:hibiki/src/media/video/video_subtitle_sync_row.dart';
import 'package:hibiki/src/models/preferences_repository.dart';
import 'package:hibiki/src/pages/implementations/video_shader_dialog.dart';
import 'package:hibiki/src/settings/settings_context.dart';
import 'package:hibiki/utils.dart';

/// 视频 schema 项的双路写穿层（阶段 B）：同一条 item 声明服务两个宿主——
/// 全局设置页（`SettingsContext.video == null`，直接读写 appModel 纯 pref、下次
/// 播放生效）与播放页快捷面板（挂 [VideoQuickSettingsHost]，经页面回调持久化 +
/// 实时应用到活播放器）。host 分支复刻旧手写面板逐项行为；pref 分支与旧首页
/// 行为一致。控制器绑定行的 builder 也集中在本文件，settings/ 不引入播放器依赖。
VideoQuickSettingsHost? videoQuickSettingsHostOf(SettingsContext context) {
  final Object? host = context.video;
  return host is VideoQuickSettingsHost ? host : null;
}

/// 播放中才可见的行的统一门控。
bool videoHostVisible(SettingsContext context) =>
    videoQuickSettingsHostOf(context) != null;

// ── videoAsbplayerConfig（手势/播放行为 JSON pref）────────────────────────────

VideoAsbplayerConfig currentVideoAsbConfig(SettingsContext context) {
  return VideoAsbplayerConfig.decode(context.appModel.videoAsbplayerConfig);
}

/// 读改写 videoAsbplayerConfig：host 在场走页面回调（持久化 + 即时应用手势配置），
/// 否则直接落 pref（下次播放生效）。
Future<void> commitVideoAsbConfig(
  SettingsContext context,
  VideoAsbplayerConfig Function(VideoAsbplayerConfig config) mutate,
) async {
  final VideoAsbplayerConfig next = mutate(currentVideoAsbConfig(context));
  final VideoQuickSettingsHost? host = videoQuickSettingsHostOf(context);
  if (host != null) {
    await host.onAsbConfigChanged(next);
  } else {
    await context.appModel.setVideoAsbplayerConfig(
      VideoAsbplayerConfig.encode(next),
    );
  }
  context.refresh();
}

// ── videoMpvConfig ────────────────────────────────────────────────────────────

VideoMpvConfig currentVideoMpvConfig(SettingsContext context) {
  return VideoMpvConfig.decode(context.appModel.videoMpvConfig);
}

/// 读改写 videoMpvConfig：host 在场走页面回调（持久化 + applyMpvConfig 实时应用，
/// 与旧面板「即改即生效」一致），否则直接落 pref。
Future<void> commitVideoMpvConfig(
  SettingsContext context,
  VideoMpvConfig Function(VideoMpvConfig config) mutate,
) async {
  final VideoMpvConfig next = mutate(currentVideoMpvConfig(context));
  final VideoQuickSettingsHost? host = videoQuickSettingsHostOf(context);
  if (host != null) {
    await host.onMpvConfigChanged(next);
  } else {
    await context.appModel.setVideoMpvConfig(VideoMpvConfig.encode(next));
  }
  context.refresh();
}

// ── videoSubtitleStyle（字幕外观，播放中带实时预览）──────────────────────────

/// 当前生效字幕样式：播放中取页面权威值（含拖动中的预览态），否则读 pref。
VideoSubtitleStyle currentVideoSubtitleStyle(SettingsContext context) {
  final VideoQuickSettingsHost? host = videoQuickSettingsHostOf(context);
  if (host != null) return host.subtitleStyle();
  return VideoSubtitleStyle.decode(context.appModel.videoSubtitleStyle);
}

/// 字幕字重/阴影 resolve 用的 UI scale：视频路由把 [HibikiAppUiScale] 中和为 1.0，
/// 播放中必须用 host 显式带入的实际 scale；全局设置页用 appModel 值。
double videoSubtitleUiScale(SettingsContext context) {
  final VideoQuickSettingsHost? host = videoQuickSettingsHostOf(context);
  return host?.uiScale ?? context.appModel.appUiScale;
}

/// 拖动中的实时预览（不落盘）：仅播放中有 overlay 可预览，无 host 时为 no-op。
void previewVideoSubtitleStyle(
  SettingsContext context,
  VideoSubtitleStyle Function(VideoSubtitleStyle style) mutate,
) {
  final VideoQuickSettingsHost? host = videoQuickSettingsHostOf(context);
  if (host == null) return;
  host.onSubtitleStylePreview(mutate(host.subtitleStyle()));
  context.refresh();
}

/// 定稿落盘：host 在场先同步页面预览态再 commit（复刻旧面板 `_applySubtitleStyle`
/// 语义，重置/无背景等离散动作也即时刷新 overlay），否则直接落 pref。
Future<void> commitVideoSubtitleStyle(
  SettingsContext context,
  VideoSubtitleStyle Function(VideoSubtitleStyle style) mutate,
) async {
  final VideoSubtitleStyle next = mutate(currentVideoSubtitleStyle(context));
  final VideoQuickSettingsHost? host = videoQuickSettingsHostOf(context);
  if (host != null) {
    host.onSubtitleStylePreview(next);
    await host.onSubtitleStyleCommit(next);
  } else {
    await context.appModel.setVideoSubtitleStyle(
      VideoSubtitleStyle.encode(next),
    );
  }
  context.refresh();
}

// ── 弹幕 ─────────────────────────────────────────────────────────────────────

VideoDanmakuStyle currentVideoDanmakuStyle(SettingsContext context) {
  final VideoQuickSettingsHost? host = videoQuickSettingsHostOf(context);
  return host?.danmakuStyle() ?? context.appModel.videoDanmakuStyle;
}

void previewVideoDanmakuStyle(
  SettingsContext context,
  VideoDanmakuStyle Function(VideoDanmakuStyle style) mutate,
) {
  final VideoQuickSettingsHost? host = videoQuickSettingsHostOf(context);
  if (host == null) return;
  host.onDanmakuStylePreview?.call(mutate(host.danmakuStyle()).normalized());
  context.refresh();
}

Future<void> commitVideoDanmakuStyle(
  SettingsContext context,
  VideoDanmakuStyle Function(VideoDanmakuStyle style) mutate,
) async {
  final VideoDanmakuStyle next =
      mutate(currentVideoDanmakuStyle(context)).normalized();
  final VideoQuickSettingsHost? host = videoQuickSettingsHostOf(context);
  if (host?.onDanmakuStyleCommit != null) {
    await host!.onDanmakuStyleCommit!(next);
  } else {
    await context.appModel.setVideoDanmakuStyle(next);
  }
  context.refresh();
}

Future<void> setVideoDanmakuEnabledDual(
  SettingsContext context,
  bool value,
) async {
  final VideoQuickSettingsHost? host = videoQuickSettingsHostOf(context);
  if (host?.onDanmakuEnabledChanged != null) {
    await host!.onDanmakuEnabledChanged!(value);
  } else {
    await context.appModel.setVideoDanmakuEnabled(value);
  }
}

Future<void> setVideoDanmakuOnlineEnabledDual(
  SettingsContext context,
  bool value,
) async {
  final VideoQuickSettingsHost? host = videoQuickSettingsHostOf(context);
  if (host?.onDanmakuOnlineEnabledChanged != null) {
    await host!.onDanmakuOnlineEnabledChanged!(value);
  } else {
    await context.appModel.setVideoDanmakuOnlineEnabled(value);
  }
}

Future<void> setVideoDanmakuMaxActiveDual(
  SettingsContext context,
  int value,
) async {
  final int next = normalizeVideoDanmakuMaxActive(value);
  final VideoQuickSettingsHost? host = videoQuickSettingsHostOf(context);
  if (host?.onDanmakuMaxActiveChanged != null) {
    await host!.onDanmakuMaxActiveChanged!(next);
  } else {
    await context.appModel.setVideoDanmakuMaxActive(next);
  }
}

// ── 遮蔽 / 画面 / 沉浸 / 窗口 / 控件（单值 pref 的双路写穿）──────────────────

Future<void> setVideoSubtitleObscureModeDual(
  SettingsContext context,
  VideoSubtitleObscureMode mode,
) async {
  final VideoQuickSettingsHost? host = videoQuickSettingsHostOf(context);
  if (host != null) {
    await host.onSetSubtitleObscureMode(mode);
  } else {
    await context.appModel.setVideoSubtitleObscureMode(mode);
  }
}

Future<void> setVideoSecondarySubtitleObscureModeDual(
  SettingsContext context,
  VideoSubtitleObscureMode mode,
) async {
  final VideoQuickSettingsHost? host = videoQuickSettingsHostOf(context);
  if (host != null) {
    await host.onSetSecondarySubtitleObscureMode(mode);
  } else {
    await context.appModel.setVideoSecondarySubtitleObscureMode(mode);
  }
}

Future<void> setVideoRespectAssStyleDual(
  SettingsContext context,
  bool value,
) async {
  final VideoQuickSettingsHost? host = videoQuickSettingsHostOf(context);
  if (host?.onRespectAssStyleChanged != null) {
    await host!.onRespectAssStyleChanged!(value);
  } else {
    await context.appModel.setVideoRespectAssStyle(value);
  }
}

Future<void> setVideoFitModeDual(
  SettingsContext context,
  VideoFitMode mode,
) async {
  final VideoQuickSettingsHost? host = videoQuickSettingsHostOf(context);
  if (host != null) {
    await host.onVideoFitModeChanged(mode);
  } else {
    await context.appModel.setVideoFitMode(mode);
  }
}

Future<void> setVideoLockWindowAspectRatioDual(
  SettingsContext context,
  bool value,
) async {
  final VideoQuickSettingsHost? host = videoQuickSettingsHostOf(context);
  if (host != null) {
    await host.onLockWindowAspectRatioChanged(value);
  } else {
    await context.appModel.setVideoLockWindowAspectRatio(value);
  }
}

Future<void> setVideoImmersiveModeDual(
  SettingsContext context,
  VideoImmersiveMode mode,
) async {
  final VideoQuickSettingsHost? host = videoQuickSettingsHostOf(context);
  if (host != null) {
    await host.onImmersiveModeChanged(mode);
  } else {
    await context.appModel.setVideoImmersiveMode(mode);
  }
}

Future<void> resetVideoControlLayoutDual(SettingsContext context) async {
  final VideoQuickSettingsHost? host = videoQuickSettingsHostOf(context);
  if (host?.onControlLayoutChanged != null) {
    await host!.onControlLayoutChanged!(VideoControlLayout.currentChrome);
  } else {
    await context.appModel.setVideoControlLayout(
      VideoControlLayout.currentChrome,
    );
  }
  context.refresh();
}

// ── 倍速吸附 ─────────────────────────────────────────────────────────────────

/// 把滑条浮点值吸附到 0.1 档并夹进 0.5–2.0（消除二进制浮点尾差如 0.7000000000000001，
/// 旧持久化的档位间值也归到最近档）。
double snapVideoSpeed(double v) =>
    ((v * 10).roundToDouble() / 10).clamp(0.5, 2.0).toDouble();

double snapVideoLongPressSpeed(double v) =>
    ((v * 10).roundToDouble() / 10).clamp(1.0, 4.0).toDouble();

// ── 播放中专属行的 builder（SettingsCustomItem 用，均 host 门控）─────────────

/// TODO-1158：HLS 多档画质入口（仅当前流是 HLS master 时显示）。点开画质侧栏。
Widget buildVideoQualityEntryRow(SettingsContext context) {
  final VideoQuickSettingsHost host = videoQuickSettingsHostOf(context)!;
  return ListTile(
    dense: true,
    leading: const Icon(Icons.high_quality_outlined),
    title: Text(t.video_quality),
    subtitle: host.qualityCurrentLabel != null
        ? Text(host.qualityCurrentLabel!)
        : null,
    trailing: const Icon(Icons.chevron_right),
    onTap: host.onOpenQuality,
  );
}

/// TODO-1232 / BUG-597：视频黑屏（有声无画）降级入口——仅当页面判定本次跑
/// Impeller 且渲染 channel 已接线（Android）时接线。点按 → 确认弹窗 → 关
/// Impeller 走 Skia + 重启。
Widget buildVideoSkiaFallbackRow(SettingsContext context) {
  final VideoQuickSettingsHost host = videoQuickSettingsHostOf(context)!;
  return ListTile(
    dense: true,
    leading: const Icon(Icons.animation_outlined),
    title: Text(t.video_render_skia_fix_title),
    subtitle: Text(t.video_render_skia_fix_hint),
    trailing: const Icon(Icons.restart_alt),
    onTap: host.onSwitchToSkiaRenderer,
  );
}

/// TODO-1351：「音频」分类的音轨切换区。内容由视频页构建（读 controller 的
/// audioTracks + 当前轨 + 切轨回调），空时显示占位。
Widget buildVideoAudioTrackSection(SettingsContext context) {
  final VideoQuickSettingsHost host = videoQuickSettingsHostOf(context)!;
  final Widget? section = host.audioTrackSection;
  if (section != null) return section;
  return ListTile(
    dense: true,
    leading: const Icon(Icons.audiotrack),
    title: Text(t.video_audio_track_empty),
    enabled: false,
  );
}

/// TODO-1351：「字幕」分类顶部的字幕轨/字幕源切换区（外挂字幕 + 打开字幕文件 +
/// 关闭 + 内嵌/远端源），由视频页构建。
Widget buildVideoSubtitleTrackSection(SettingsContext context) {
  return videoQuickSettingsHostOf(context)!.subtitleTrackSection!;
}

/// 字幕调轴行（A/V 延迟 + 自动对轴 + 波形对轴入口）。
Widget buildVideoSubtitleSyncRow(SettingsContext context) {
  return VideoSubtitleSyncRow(host: videoQuickSettingsHostOf(context)!);
}

/// 一行「点开调色盘取任意色」的字幕颜色设置行（TODO-1326 文字色 / TODO-1059 背景
/// 色）。行尾显示当前色色块，点整行开对话框内嵌 [ColorPicker]：拖动经 [onPreview]
/// 实时预览背后字幕，关闭时经 [onCommit] 落盘一次。
Widget _buildSubtitleColorRow(
  SettingsContext context, {
  required String title,
  required IconData icon,
  required Color current,
  required void Function(Color color) onPreview,
  required void Function(Color color) onCommit,
}) {
  final BuildContext buildContext = context.context;
  return AdaptiveSettingsRow(
    title: title,
    icon: icon,
    showIcon: true,
    trailing: HibikiColorSwatch(
      color: current,
      size: 24,
      borderColor: Theme.of(buildContext).dividerColor,
    ),
    onTap: () => unawaited(_pickSubtitleColor(
      buildContext,
      title: title,
      initial: current,
      onPreview: onPreview,
      onCommit: onCommit,
    )),
  );
}

/// 弹字幕颜色对话框：内嵌 [ColorPicker] 取任意色。字幕文字/背景色都存**不透明**
/// ARGB（背景实际可见透明度另由 backgroundOpacity 滑条控制），故这里强制不透明、
/// 关闭 alpha 通道。拖动经 [onPreview] 实时预览（不落盘），点「完成」或关闭时经
/// [onCommit] 落盘一次（避免拖动过程每帧写 DB）。
Future<void> _pickSubtitleColor(
  BuildContext context, {
  required String title,
  required Color initial,
  required void Function(Color color) onPreview,
  required void Function(Color color) onCommit,
}) async {
  Color picked = initial;
  await showDialog<void>(
    context: context,
    builder: (BuildContext dialogContext) {
      return AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(
          child: ColorPicker(
            pickerColor: initial,
            onColorChanged: (Color c) {
              // 强制不透明：字幕文字透明无意义；背景透明度另由滑条控制。
              picked = Color(0xFF000000 | (c.toARGB32() & 0xFFFFFF));
              onPreview(picked);
            },
            portraitOnly: true,
            enableAlpha: false,
            displayThumbColor: true,
            hexInputBar: true,
            labelTypes: const <ColorLabelType>[],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(t.dialog_done),
          ),
        ],
      );
    },
  );
  onCommit(picked);
}

/// 字幕**文字**颜色取色行（TODO-1326）。与「尊重 .ass 自带样式」协调：respect 开且
/// cue 带主色时 overlay 用 ASS 主色，本项作为统一外观基线在 respect 关 / ASS 无主
/// 色时生效。文字色默认白（非 null），取色器初值即当前色。
Widget buildVideoSubtitleTextColorRow(SettingsContext context) {
  final VideoSubtitleStyle style = currentVideoSubtitleStyle(context);
  return _buildSubtitleColorRow(
    context,
    title: t.video_setting_subtitle_text_color,
    icon: Icons.format_color_text,
    current: style.textColor ?? const Color(0xFFFFFFFF),
    onPreview: (Color c) => previewVideoSubtitleStyle(
      context,
      (VideoSubtitleStyle s) => s.copyWith(textColor: c),
    ),
    onCommit: (Color c) => unawaited(commitVideoSubtitleStyle(
      context,
      (VideoSubtitleStyle s) => s.copyWith(textColor: c),
    )),
  );
}

/// TODO-1059：字幕背景**颜色**取色行。背景默认 null 走
/// [kDefaultSubtitleBackgroundColor] 固定黑，取色器初值即该固定黑。选背景色不直接
/// 改透明度，但透明度为 0 时用户看不到颜色变化，故把透明度从 0 顶到可见基线
/// （0.6），让「选了色」立刻生效。
Widget buildVideoSubtitleBgColorRow(SettingsContext context) {
  final VideoSubtitleStyle style = currentVideoSubtitleStyle(context);
  VideoSubtitleStyle applyColor(VideoSubtitleStyle s, Color c) => s.copyWith(
        backgroundColor: c,
        backgroundOpacity: s.backgroundOpacity <= 0 ? 0.6 : s.backgroundOpacity,
      );
  return _buildSubtitleColorRow(
    context,
    title: t.video_setting_subtitle_bg_color,
    icon: Icons.format_color_fill_outlined,
    current: style.backgroundColor ?? kDefaultSubtitleBackgroundColor,
    onPreview: (Color c) => previewVideoSubtitleStyle(
      context,
      (VideoSubtitleStyle s) => applyColor(s, c),
    ),
    onCommit: (Color c) => unawaited(commitVideoSubtitleStyle(
      context,
      (VideoSubtitleStyle s) => applyColor(s, c),
    )),
  );
}

/// 着色器内嵌管理视图（导入/发现/下载/勾选/一键选档）。启用集 / 画质增强开关 /
/// mpv 目录均以 pref 为权威（页面回调持久化后同步缓存立即可读），切分类重建后回显
/// 正确，无需面板级本地镜像。
Widget buildVideoShaderManager(SettingsContext context) {
  final VideoQuickSettingsHost host = videoQuickSettingsHostOf(context)!;
  return VideoShaderManagerView(
    initialEnabled: decodeEnabledShaders(context.appModel.videoShadersEnabled),
    qualityEnhancementEnabled: currentVideoMpvConfig(context).highQuality,
    onQualityEnhancementChanged: (bool value) => unawaited(commitVideoMpvConfig(
      context,
      (VideoMpvConfig c) => c.copyWith(highQuality: value),
    )),
    onApply: (List<String> names) async {
      await host.onApplyShaders(names);
      context.refresh();
    },
    onSelectTier: (
      VideoShaderTier tier,
      bool highQuality,
      List<String> enabledNames,
    ) async {
      await host.onSelectShaderTier(tier, highQuality, enabledNames);
      context.refresh();
    },
    initialMpvDir: context.appModel.videoMpvShaderDir,
    titlePlacement: SettingsSectionTitlePlacement.inside,
    onMpvDirChanged: (String dir) async {
      await host.onMpvShaderDirChanged?.call(dir);
      context.refresh();
    },
  );
}

/// 原始 mpv.conf 多行逃生口（AdaptiveSettingsTextField 不支持多行故用原生
/// TextField）。TODO-561：标题用 TextField 上方独立、可换行、完整显示的 Text（不挂
/// InputDecoration.labelText 单行浮动 label）。
Widget buildVideoMpvRawConfField(SettingsContext context) {
  return _VideoMpvRawConfField(settingsContext: context);
}

class _VideoMpvRawConfField extends StatefulWidget {
  const _VideoMpvRawConfField({required this.settingsContext});

  final SettingsContext settingsContext;

  @override
  State<_VideoMpvRawConfField> createState() => _VideoMpvRawConfFieldState();
}

class _VideoMpvRawConfFieldState extends State<_VideoMpvRawConfField> {
  late final TextEditingController _controller = TextEditingController(
    text: currentVideoMpvConfig(widget.settingsContext).rawConf,
  );

  @override
  void didUpdateWidget(_VideoMpvRawConfField oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 外部重置（「恢复 mpv 默认」action 清空 rawConf）后回填输入框；正常键入路径
    // pref 值与输入框文本一致，不会误触发回写打断光标。
    // 契约依赖：页面 onMpvConfigChanged 在其第一个 await 前同步落 pref 缓存
    // （currentVideoMpvConfig 立即读到刚键入的值）——否则键入后的 rebuild 会在
    // 这里读到旧值并回写输入框、打断光标。改动持久化时序前先看这里。
    final String external =
        currentVideoMpvConfig(widget.settingsContext).rawConf;
    if (external != _controller.text) _controller.text = external;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.gap + tokens.spacing.gap / 2,
        tokens.spacing.gap,
        tokens.spacing.gap + tokens.spacing.gap / 2,
        tokens.spacing.gap + tokens.spacing.gap / 2,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            t.video_setting_mpv_raw,
            style: Theme.of(context).textTheme.titleSmall,
          ),
          SizedBox(height: tokens.spacing.gap / 2),
          TextField(
            controller: _controller,
            minLines: 3,
            maxLines: 8,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
            decoration: InputDecoration(
              helperText: t.video_setting_mpv_raw_hint,
              helperMaxLines: 4,
              border: const OutlineInputBorder(),
            ),
            onChanged: (String v) => unawaited(commitVideoMpvConfig(
              widget.settingsContext,
              (VideoMpvConfig c) => c.copyWith(rawConf: v),
            )),
          ),
        ],
      ),
    );
  }
}

/// TODO-1376：弹幕屏蔽词/正则过滤（多行文本，每行一条，`/pattern/` 为正则）。
Widget buildVideoDanmakuBlockRulesField(SettingsContext context) {
  return _VideoDanmakuBlockRulesField(settingsContext: context);
}

class _VideoDanmakuBlockRulesField extends StatefulWidget {
  const _VideoDanmakuBlockRulesField({required this.settingsContext});

  final SettingsContext settingsContext;

  @override
  State<_VideoDanmakuBlockRulesField> createState() =>
      _VideoDanmakuBlockRulesFieldState();
}

class _VideoDanmakuBlockRulesFieldState
    extends State<_VideoDanmakuBlockRulesField> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.settingsContext.appModel.videoDanmakuBlockRulesText,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _commit(String value) async {
    final VideoQuickSettingsHost? host =
        videoQuickSettingsHostOf(widget.settingsContext);
    if (host?.onDanmakuBlockRulesChanged != null) {
      await host!.onDanmakuBlockRulesChanged!(value);
    } else {
      await widget.settingsContext.appModel
          .setVideoDanmakuBlockRulesText(value);
    }
  }

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.gap + tokens.spacing.gap / 2,
        tokens.spacing.gap,
        tokens.spacing.gap + tokens.spacing.gap / 2,
        tokens.spacing.gap + tokens.spacing.gap / 2,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            t.video_setting_danmaku_block_rules_hint,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
          SizedBox(height: tokens.spacing.gap / 2),
          TextField(
            key: const Key('danmaku-block-rules-field'),
            controller: _controller,
            minLines: 3,
            maxLines: 8,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
            decoration: InputDecoration(
              hintText: t.video_setting_danmaku_block_rules_placeholder,
              border: const OutlineInputBorder(),
            ),
            onChanged: (String v) => unawaited(_commit(v)),
          ),
        ],
      ),
    );
  }
}

/// 控制条 9 槽位拖拽编辑器（TODO-274/312 phase 2）。
Widget buildVideoControlLayoutEditor(SettingsContext context) {
  final VideoQuickSettingsHost host = videoQuickSettingsHostOf(context)!;
  return VideoControlLayoutEditor(
    layout: host.controlLayout(),
    onLayoutChanged: host.onControlLayoutChanged,
    isTouchControls: host.isTouchControls,
  );
}
