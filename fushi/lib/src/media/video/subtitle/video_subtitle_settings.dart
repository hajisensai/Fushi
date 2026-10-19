/// 「设置 › 模型 › 视频日语字幕」子页：分段方式、MOSS 后端、MOSS 运行库与模型的
/// 状态与下载。
///
/// 放成「语音转录」旁边的独立一行而不是塞进那一页：语音转录子页是模型管理正文
/// （`AsrModelsSettingsSection`）独占的页，不挂 schema 分组（守卫
/// `test/settings/settings_schema_information_architecture_test.dart`，避免卡片套卡片）。
///
/// 偏好全部设备本地（`SyncRepository.deviceLocalPrefKeys`）：能不能跑 MOSS 取决于这台
/// 机器的显卡。AI 校对的开关不放这里：它要先说明会发送什么（面板首次开启时弹），
/// 设置页 / `config set` 那条路绕得过说明。
library;

import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:fushi_asr_core/asr_core.dart' show ModelDownloadEvent;
import 'package:fushi_engine/media/video/subtitle/asr_proofread/video_subtitle_recognizer_factory.dart';

import 'package:fushi/src/asr_host/asr_host.dart' show isAsrSupported;
import 'package:fushi/src/media/video/subtitle/video_subtitle_generate_sheet.dart'
    show videoSubtitleMossProblemText;
import 'package:fushi/src/media/video/subtitle/video_subtitle_model_ports.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// MOSS 只有 Windows / Linux 的 audio.cpp 构建（spec 第 4 节平台矩阵）。
bool get videoSubtitleMossPlatformSupported =>
    Platform.isWindows || Platform.isLinux;

String videoSubtitleSegmenterLabel(VideoSubtitleSegmenterMode mode) =>
    switch (mode) {
      VideoSubtitleSegmenterMode.auto => t.video_subtitle_ai_segmenter_auto,
      VideoSubtitleSegmenterMode.moss => t.video_subtitle_ai_segmenter_moss,
      VideoSubtitleSegmenterMode.window => t.video_subtitle_ai_segmenter_window,
    };

String videoSubtitleMossBackendLabel(MossBackendPreference backend) =>
    switch (backend) {
      MossBackendPreference.auto => t.video_subtitle_ai_moss_backend_auto,
      MossBackendPreference.cuda => 'CUDA',
      MossBackendPreference.vulkan => 'Vulkan',
      MossBackendPreference.cpu => 'CPU',
    };

/// 子页本体。**零参、构造期只读 i18n 常量**（schema 按 locale 缓存）。
SettingsDestination buildVideoSubtitleModelsDestination() {
  return SettingsDestination(
    id: SettingsDestinationId.models,
    visible: (_) => isAsrSupported,
    title: t.video_subtitle_ai_settings_title,
    icon: FushiIcons.subtitles,
    sections: <SettingsSection>[
      SettingsSection(
        id: 'models.video_subtitle.section.segmenter',
        presentation: SettingsSectionPresentation.alwaysExpanded,
        footer: t.video_subtitle_ai_settings_footer,
        items: <SettingsItem>[
          SettingsSegmentedItem<VideoSubtitleSegmenterMode>(
            id: 'models.video_subtitle.segmenter',
            title: t.video_subtitle_ai_segmenter_label,
            subtitle: t.video_subtitle_ai_segmenter_hint,
            icon: FushiIcons.subtitles,
            options: <SettingsSegmentOption<VideoSubtitleSegmenterMode>>[
              for (final VideoSubtitleSegmenterMode mode
                  in VideoSubtitleSegmenterMode.values)
                SettingsSegmentOption<VideoSubtitleSegmenterMode>(
                  value: mode,
                  label: videoSubtitleSegmenterLabel(mode),
                ),
            ],
            selected: (SettingsContext c) =>
                c.appModel.prefsRepo.videoSubtitleSegmenter,
            onChanged: (SettingsContext c, VideoSubtitleSegmenterMode v) =>
                c.appModel.prefsRepo.setVideoSubtitleSegmenter(v),
            defaultValue: VideoSubtitleSegmenterMode.auto,
          ),
          SettingsSegmentedItem<MossBackendPreference>(
            id: 'models.video_subtitle.moss_backend',
            title: t.video_subtitle_ai_moss_backend_label,
            subtitle: t.video_subtitle_ai_moss_backend_hint,
            icon: FushiIcons.modelTraining,
            visible: (_) => videoSubtitleMossPlatformSupported,
            options: <SettingsSegmentOption<MossBackendPreference>>[
              for (final MossBackendPreference backend
                  in MossBackendPreference.values)
                SettingsSegmentOption<MossBackendPreference>(
                  value: backend,
                  label: videoSubtitleMossBackendLabel(backend),
                ),
            ],
            selected: (SettingsContext c) =>
                c.appModel.prefsRepo.videoSubtitleMossBackend,
            onChanged: (SettingsContext c, MossBackendPreference v) =>
                c.appModel.prefsRepo.setVideoSubtitleMossBackend(v),
            defaultValue: MossBackendPreference.auto,
          ),
          SettingsCustomItem(
            id: 'models.video_subtitle.moss_files',
            searchTitle: t.video_subtitle_ai_moss_files,
            visible: (_) => videoSubtitleMossPlatformSupported,
            builder: (SettingsContext c) => VideoSubtitleMossSettingsRow(
              backend: c.appModel.prefsRepo.videoSubtitleMossBackend,
            ),
          ),
        ],
      ),
    ],
  );
}

/// MOSS 运行库与模型的状态行：已就绪 / 缺多少 + 下载（带进度）。
class VideoSubtitleMossSettingsRow extends StatefulWidget {
  const VideoSubtitleMossSettingsRow({
    super.key,
    required this.backend,
    this.port = const AppVideoSubtitleMossPort(),
  });

  final MossBackendPreference backend;
  final VideoSubtitleMossPort port;

  @override
  State<VideoSubtitleMossSettingsRow> createState() =>
      _VideoSubtitleMossSettingsRowState();
}

class _VideoSubtitleMossSettingsRowState
    extends State<VideoSubtitleMossSettingsRow> {
  VideoSubtitleMossState? _state;
  ModelDownloadEvent? _download;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  @override
  void didUpdateWidget(VideoSubtitleMossSettingsRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.backend != widget.backend) unawaited(_refresh());
  }

  Future<void> _refresh() async {
    try {
      final VideoSubtitleMossState state = await widget.port.status(
        widget.backend,
      );
      if (mounted) setState(() => _state = state);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  Future<void> _ensure() async {
    setState(() {
      _error = null;
      _download = const ModelDownloadEvent(
        fileName: '',
        receivedBytes: 0,
        totalBytes: 0,
      );
    });
    try {
      await for (final ModelDownloadEvent e in widget.port.ensure(
        widget.backend,
      )) {
        if (mounted) setState(() => _download = e);
      }
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _download = null);
      await _refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final VideoSubtitleMossState? state = _state;
    final ModelDownloadEvent? download = _download;
    final String subtitle = _error != null
        ? _error!
        : state == null
        ? t.video_subtitle_ai_moss_checking
        : state.unavailableReason != null
        ? videoSubtitleMossProblemText(
            VideoSubtitleMossProblem(
              code: state.unavailableCode,
              reason: state.unavailableReason!,
            ),
          )
        : state.ready
        ? t.video_subtitle_ai_moss_ready
        : t.video_subtitle_ai_moss_missing(
            size: FushiByteFormat.bytes(state.remainingBytes),
          );
    final bool canDownload =
        state != null &&
        !state.ready &&
        state.unavailableReason == null &&
        download == null;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        AdaptiveSettingsRow(
          key: const ValueKey<String>('video-subtitle-moss-files'),
          title: t.video_subtitle_ai_moss_files,
          subtitle: subtitle,
          icon: FushiIcons.download,
          trailing: canDownload
              ? FushiOutlinedButton(
                  key: const ValueKey<String>(
                    'video-subtitle-moss-files-download',
                  ),
                  onPressed: () => unawaited(_ensure()),
                  child: Text(t.audiobook_transcribe_model_download),
                )
              : null,
        ),
        if (download != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: FushiLinearProgressIndicator(
              value: download.totalBytes > 0
                  ? download.receivedBytes / download.totalBytes
                  : null,
            ),
          ),
      ],
    );
  }
}

/// 「模型」分类里的入口行（语音转录旁边）。
SettingsNavigationItem videoSubtitleModelsNavigationItem() =>
    SettingsNavigationItem(
      id: 'models.video_subtitle',
      title: t.video_subtitle_ai_settings_title,
      subtitle: t.video_subtitle_ai_settings_summary,
      icon: FushiIcons.subtitles,
      visible: (_) => isAsrSupported,
      child: buildVideoSubtitleModelsDestination,
    );
