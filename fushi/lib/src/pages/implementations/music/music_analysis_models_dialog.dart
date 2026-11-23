// 设置 › 音乐 › 歌词动画：整首音频分析的模型（Beat This! 节拍 + htdemucs 鼓点 / 人声）。
//
// 模型按需下载、不随包；没下时分析只跑 DSP（节拍 / 包络照样有，鼓点 / 人声是近似值）。
// 状态直接听 [MusicAudioAnalysisService.models]，下载进度实时刷新。

import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/music/analysis/music_audio_analysis_service.dart'
    show MusicAnalysisModelState, MusicAudioAnalysisService;
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart'
    show showFushiConfirmDialog;
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart'
    show FushiLinearProgressIndicator;
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart'
    show FushiAlertDialog;
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/fushi_byte_format.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';

/// 打开模型管理对话框。
Future<void> showMusicAnalysisModelsDialog(
  BuildContext context, {
  MusicAudioAnalysisService? service,
}) async {
  final MusicAudioAnalysisService s =
      service ?? MusicAudioAnalysisService.instance;
  unawaited(s.refreshModels());
  await showAppDialog<void>(
    context: context,
    builder: (BuildContext dialogContext) =>
        MusicAnalysisModelsDialog(service: s),
  );
}

/// 模型管理对话框本体（测试可直接 pump）。
class MusicAnalysisModelsDialog extends StatelessWidget {
  const MusicAnalysisModelsDialog({super.key, required this.service});

  final MusicAudioAnalysisService service;

  Future<void> _download(BuildContext context) async {
    final bool ok = await showFushiConfirmDialog(
      context: context,
      title: t.music_visualizer_models_download,
      message: t.music_visualizer_models_download_confirm(
        size: FushiByteFormat.bytes(service.requiredModelBytes),
      ),
      icon: FushiIcons.download,
      confirmLabel: t.music_visualizer_models_download,
    );
    if (ok) unawaited(service.downloadModels());
  }

  Future<void> _delete(BuildContext context) async {
    final bool ok = await showFushiConfirmDialog(
      context: context,
      title: t.music_visualizer_models_delete,
      message: t.music_visualizer_models_delete_confirm,
      icon: FushiIcons.delete,
      confirmLabel: t.music_visualizer_models_delete,
      destructive: true,
    );
    if (ok) await service.deleteModels();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<MusicAnalysisModelState>(
      valueListenable: service.models,
      builder: (BuildContext context, MusicAnalysisModelState m, _) {
        final TextTheme text = Theme.of(context).textTheme;
        final double? progress = m.downloading && m.totalBytes > 0
            ? (m.receivedBytes / m.totalBytes).clamp(0.0, 1.0)
            : null;
        return FushiAlertDialog(
          title: Text(t.music_visualizer_models_title),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(t.music_visualizer_models_intro),
              const SizedBox(height: 12),
              Text(
                m.installed
                    ? t.music_visualizer_models_installed
                    : m.downloading
                    ? t.music_visualizer_models_downloading(
                        done: FushiByteFormat.bytes(m.receivedBytes),
                        total: FushiByteFormat.bytes(m.totalBytes),
                      )
                    : t.music_visualizer_models_missing(
                        size: FushiByteFormat.bytes(service.requiredModelBytes),
                      ),
                key: const ValueKey<String>('music_analysis_models_state'),
                style: text.bodyMedium,
              ),
              if (m.downloading) ...<Widget>[
                const SizedBox(height: 8),
                FushiLinearProgressIndicator(value: progress),
              ],
              if (m.error != null && !m.downloading) ...<Widget>[
                const SizedBox(height: 8),
                Text(
                  t.music_visualizer_models_failed,
                  style: text.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ],
            ],
          ),
          actions: <Widget>[
            if (m.installed)
              FushiTextButton(
                key: const ValueKey<String>('music_analysis_models_delete'),
                onPressed: () => unawaited(_delete(context)),
                child: Text(t.music_visualizer_models_delete),
              )
            else if (!m.downloading)
              FushiFilledButton(
                key: const ValueKey<String>('music_analysis_models_download'),
                onPressed: () => unawaited(_download(context)),
                child: Text(t.music_visualizer_models_download),
              ),
            FushiTextButton(
              autofocus: true,
              onPressed: () => Navigator.of(context).pop(),
              child: Text(t.dialog_close),
            ),
          ],
        );
      },
    );
  }
}
