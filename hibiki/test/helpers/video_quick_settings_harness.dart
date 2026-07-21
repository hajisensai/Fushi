import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:hibiki_core/hibiki_core.dart';

import 'package:hibiki/models.dart';
import 'package:hibiki/src/media/video/video_asbplayer_config.dart';
import 'package:hibiki/src/media/video/video_control_customization.dart';
import 'package:hibiki/src/media/video/video_danmaku_model.dart';
import 'package:hibiki/src/media/video/video_immersive_mode.dart';
import 'package:hibiki/src/media/video/video_mpv_config.dart';
import 'package:hibiki/src/media/video/video_quick_settings_host.dart';
import 'package:hibiki/src/media/video/video_quick_settings_sheet.dart';
import 'package:hibiki/src/media/video/video_shader_tier.dart';
import 'package:hibiki/src/media/video/video_subtitle_obscure_mode.dart';
import 'package:hibiki/src/media/video/video_subtitle_style.dart';
import 'package:hibiki/src/models/preferences_repository.dart';

import 'test_platform_services.dart';

/// 视频快捷设置面板（schema 投影版）widget 测试 harness：内存 DB + 最小 AppModel
/// （prefsRepo 已 wire，schema 项的 pref 读写真实写穿），再配一个可变状态的
/// [VideoQuickSettingsHost]（页面权威值的测试替身：preview/commit 回调会更新本地
/// getter，复刻真实视频页「回调里 setState → 面板重读」的数据流）。
class VideoSheetHarness {
  VideoSheetHarness._(this.db, this.appModel, this._tmpDir);

  final HibikiDatabase db;
  final AppModel appModel;
  final Directory _tmpDir;

  static Future<VideoSheetHarness> create() async {
    final HibikiDatabase db =
        HibikiDatabase.forTesting(NativeDatabase.memory());
    final PreferencesRepository prefsRepo = PreferencesRepository(db);
    await prefsRepo.loadFromDb();
    final Directory tmpDir =
        Directory.systemTemp.createTempSync('hibiki_video_sheet_');
    final AppModel appModel = AppModel(testPlatformServices())
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(
          prefsRepo: prefsRepo, databaseDirectory: tmpDir);
    return VideoSheetHarness._(db, appModel, tmpDir);
  }

  Future<void> dispose() async {
    await db.close();
    try {
      _tmpDir.deleteSync(recursive: true);
    } catch (_) {}
  }
}

/// 测试版能力槽：页面权威值（倍速/延迟/字幕样式/弹幕样式/控件布局）以可变字段模拟，
/// preview/commit 回调先更新本地值再转发测试传入的探针回调——与真实视频页
/// `_setSpeed` / `onSubtitleStylePreview` 等「更新 State → 面板 getter 重读」同构。
class TestVideoHostState {
  TestVideoHostState({
    this.delayMs = 0,
    this.speed = 1.0,
    VideoSubtitleStyle? subtitleStyle,
    VideoDanmakuStyle? danmakuStyle,
    VideoControlLayout? controlLayout,
  })  : subtitleStyle = subtitleStyle ?? VideoSubtitleStyle.defaults,
        danmakuStyle = danmakuStyle ?? VideoDanmakuStyle.defaults,
        controlLayout = controlLayout ?? VideoControlLayout.currentChrome;

  int delayMs;
  double speed;
  VideoSubtitleStyle subtitleStyle;
  VideoDanmakuStyle danmakuStyle;
  VideoControlLayout controlLayout;
}

VideoQuickSettingsHost buildTestVideoHost({
  TestVideoHostState? state,
  double uiScale = 1.0,
  bool isTouchControls = false,
  void Function(int delayMs)? onSetDelay,
  Future<int?> Function()? onAutoAlign,
  List<AudioCue> subtitleWaveformCues = const <AudioCue>[],
  int videoDurationMs = 60000,
  Future<List<double>> Function()? loadSubtitleWaveform,
  void Function(double speed)? onPreviewSpeed,
  void Function(double speed)? onSetSpeed,
  void Function(VideoSubtitleObscureMode mode)? onSetSubtitleObscureMode,
  void Function(VideoSubtitleObscureMode mode)?
      onSetSecondarySubtitleObscureMode,
  void Function(VideoSubtitleStyle style)? onSubtitleStylePreview,
  void Function(VideoSubtitleStyle style)? onSubtitleStyleCommit,
  void Function(bool value)? onRespectAssStyleChanged,
  void Function(VideoAsbplayerConfig config)? onAsbConfigChanged,
  void Function(VideoMpvConfig config)? onMpvConfigChanged,
  Future<void> Function(List<String> enabledNames)? onApplyShaders,
  void Function(VideoShaderTier tier, bool highQuality)? onSelectShaderTier,
  void Function(String dir)? onMpvShaderDirChanged,
  void Function(bool value)? onLockWindowAspectRatioChanged,
  void Function(VideoFitMode mode)? onVideoFitModeChanged,
  void Function(VideoImmersiveMode mode)? onImmersiveModeChanged,
  void Function(VideoControlLayout layout)? onControlLayoutChanged,
  int qualityOptionCount = 0,
  String? qualityCurrentLabel,
  VoidCallback? onOpenQuality,
  VoidCallback? onSwitchToSkiaRenderer,
  void Function(bool value)? onDanmakuEnabledChanged,
  void Function(bool value)? onDanmakuOnlineEnabledChanged,
  void Function(int value)? onDanmakuMaxActiveChanged,
  void Function(VideoDanmakuStyle style)? onDanmakuStylePreview,
  void Function(VideoDanmakuStyle style)? onDanmakuStyleCommit,
  void Function(String rulesText)? onDanmakuBlockRulesChanged,
  VoidCallback? onManualDanmakuMatch,
  Widget? audioTrackSection,
  Widget? subtitleTrackSection,
  VoidCallback? onSubtitleCategoryShown,
}) {
  final TestVideoHostState s = state ?? TestVideoHostState();
  return VideoQuickSettingsHost(
    uiScale: uiScale,
    isTouchControls: isTouchControls,
    delayMs: () => s.delayMs,
    onSetDelay: (int v) async {
      s.delayMs = v;
      onSetDelay?.call(v);
    },
    onAutoAlign: onAutoAlign,
    subtitleWaveformCues: subtitleWaveformCues,
    videoDurationMs: videoDurationMs,
    loadSubtitleWaveform: loadSubtitleWaveform,
    speed: () => s.speed,
    onPreviewSpeed: (double v) async {
      s.speed = v;
      onPreviewSpeed?.call(v);
    },
    onSetSpeed: (double v) async {
      s.speed = v;
      onSetSpeed?.call(v);
    },
    onSetSubtitleObscureMode: (VideoSubtitleObscureMode mode) async {
      onSetSubtitleObscureMode?.call(mode);
    },
    onSetSecondarySubtitleObscureMode: (VideoSubtitleObscureMode mode) async {
      onSetSecondarySubtitleObscureMode?.call(mode);
    },
    subtitleStyle: () => s.subtitleStyle,
    onSubtitleStylePreview: (VideoSubtitleStyle style) {
      s.subtitleStyle = style;
      onSubtitleStylePreview?.call(style);
    },
    onSubtitleStyleCommit: (VideoSubtitleStyle style) async {
      s.subtitleStyle = style;
      onSubtitleStyleCommit?.call(style);
    },
    onRespectAssStyleChanged: (bool value) async {
      onRespectAssStyleChanged?.call(value);
    },
    onAsbConfigChanged: (VideoAsbplayerConfig config) async {
      onAsbConfigChanged?.call(config);
    },
    onMpvConfigChanged: (VideoMpvConfig config) async {
      onMpvConfigChanged?.call(config);
    },
    onApplyShaders: (List<String> enabledNames) async {
      await onApplyShaders?.call(enabledNames);
    },
    onSelectShaderTier: (
      VideoShaderTier tier,
      bool highQuality,
      List<String> enabledNames,
    ) async {
      onSelectShaderTier?.call(tier, highQuality);
    },
    onMpvShaderDirChanged: (String dir) async {
      onMpvShaderDirChanged?.call(dir);
    },
    onLockWindowAspectRatioChanged: (bool value) async {
      onLockWindowAspectRatioChanged?.call(value);
    },
    onVideoFitModeChanged: (VideoFitMode mode) async {
      onVideoFitModeChanged?.call(mode);
    },
    onImmersiveModeChanged: (VideoImmersiveMode mode) async {
      onImmersiveModeChanged?.call(mode);
    },
    controlLayout: () => s.controlLayout,
    onControlLayoutChanged: (VideoControlLayout layout) async {
      s.controlLayout = layout;
      onControlLayoutChanged?.call(layout);
    },
    qualityOptionCount: qualityOptionCount,
    qualityCurrentLabel: qualityCurrentLabel,
    onOpenQuality: onOpenQuality,
    onSwitchToSkiaRenderer: onSwitchToSkiaRenderer,
    onDanmakuEnabledChanged: onDanmakuEnabledChanged == null
        ? null
        : (bool value) async => onDanmakuEnabledChanged(value),
    onDanmakuOnlineEnabledChanged: onDanmakuOnlineEnabledChanged == null
        ? null
        : (bool value) async => onDanmakuOnlineEnabledChanged(value),
    onDanmakuMaxActiveChanged: onDanmakuMaxActiveChanged == null
        ? null
        : (int value) async => onDanmakuMaxActiveChanged(value),
    danmakuStyle: () => s.danmakuStyle,
    onDanmakuStylePreview: (VideoDanmakuStyle style) {
      s.danmakuStyle = style;
      onDanmakuStylePreview?.call(style);
    },
    onDanmakuStyleCommit: (VideoDanmakuStyle style) async {
      s.danmakuStyle = style;
      onDanmakuStyleCommit?.call(style);
    },
    onDanmakuBlockRulesChanged: onDanmakuBlockRulesChanged == null
        ? null
        : (String rulesText) async => onDanmakuBlockRulesChanged(rulesText),
    onManualDanmakuMatch: onManualDanmakuMatch,
    audioTrackSection: audioTrackSection,
    subtitleTrackSection: subtitleTrackSection,
    onSubtitleCategoryShown: onSubtitleCategoryShown,
  );
}

/// 把面板包进 ProviderScope + Consumer（拿真实 [WidgetRef]），供 pumpWidget。
Widget buildVideoSheetUnderTest({
  required VideoSheetHarness harness,
  required VideoQuickSettingsHost host,
  String? initialCategory,
}) {
  return ProviderScope(
    child: Consumer(
      builder: (BuildContext context, WidgetRef ref, Widget? _) {
        return VideoQuickSettingsSheet(
          appModel: harness.appModel,
          ref: ref,
          host: host,
          initialCategory: initialCategory,
        );
      },
    ),
  );
}
