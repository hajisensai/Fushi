/// 全屏歌词动画悬停条「AI 主题」按钮打开的面板：看本首主题（名字 / 描述 / 配色 / 关键词），
/// 生成 / 重新生成、撤销上一次改动、改回封面取色。没有可用提供商时说明并给「打开 AI 设置」。
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/ai/ai_failure_text.dart';
import 'package:fushi/src/ai/ai_music_visualizer_theme_assistant.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/ai_theme/lyric_visualizer_ai_theme_controller.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart'
    show FushiCircularProgressIndicator;
import 'package:fushi/src/utils/fushi_icons.dart';

/// 打开 AI 主题面板。
Future<void> showLyricVisualizerAiThemeSheet({
  required BuildContext context,
  required LyricVisualizerAiThemeController controller,
}) => adaptiveModalSheet<void>(
  context: context,
  builder: (BuildContext context) =>
      LyricVisualizerAiThemePanel(controller: controller),
);

/// 面板正文（单独公开，测试直接 pump）。
class LyricVisualizerAiThemePanel extends StatelessWidget {
  const LyricVisualizerAiThemePanel({super.key, required this.controller});

  final LyricVisualizerAiThemeController controller;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (BuildContext context, _) => _build(context),
  );

  Widget _build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final LyricVisualizerAiThemeStatus status = controller.status;
    final AiMusicVisualizerTheme? current = controller.current;
    final bool busy =
        status == LyricVisualizerAiThemeStatus.generating ||
        status == LyricVisualizerAiThemeStatus.loading;
    final Future<void> Function(BuildContext context)? openSettings =
        controller.openAiSettings;
    final List<Widget> body = <Widget>[
      if (status == LyricVisualizerAiThemeStatus.generating)
        Row(
          children: <Widget>[
            const SizedBox(
              width: 20,
              height: 20,
              child: FushiCircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 12),
            Expanded(child: Text(t.music_visualizer_ai_theme_generating)),
          ],
        )
      else if (status == LyricVisualizerAiThemeStatus.noProvider) ...<Widget>[
        Text(
          t.ai_assist_no_provider,
          key: const ValueKey<String>('music_visualizer_ai_theme_no_provider'),
        ),
        if (openSettings != null)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: FushiPressScale(
              child: FushiTextButton.icon(
                key: const ValueKey<String>(
                  'music_visualizer_ai_theme_open_settings',
                ),
                onPressed: () => unawaited(openSettings(context)),
                icon: const Icon(FushiIcons.settings),
                label: Text(t.music_visualizer_ai_theme_open_settings),
              ),
            ),
          ),
      ] else if (status == LyricVisualizerAiThemeStatus.failed)
        Text(
          controller.failure == 'empty' || controller.failure == null
              ? t.ai_assist_empty
              : t.ai_assist_failed(reason: aiFailureText(controller.failure!)),
          style: TextStyle(color: theme.colorScheme.error),
        ),
      if (current != null)
        _ThemePreview(variant: current.variantFor(theme.brightness))
      else if (!busy)
        Text(
          t.music_visualizer_ai_theme_none,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
    ];
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 4, 24, 16),
        child: FushiEntranceScope(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(
                t.music_visualizer_ai_theme,
                style: theme.textTheme.titleLarge,
              ),
              const SizedBox(height: 12),
              for (int i = 0; i < body.length; i++)
                FushiStaggeredEntrance(
                  index: i,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: body[i],
                  ),
                ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  FushiPressScale(
                    child: FushiFilledButton.icon(
                      key: const ValueKey<String>(
                        'music_visualizer_ai_theme_generate',
                      ),
                      onPressed: busy
                          ? null
                          : () => unawaited(controller.generate()),
                      icon: const Icon(FushiIcons.aiAssistant),
                      label: Text(
                        current == null
                            ? t.ai_assist_generate
                            : t.music_visualizer_ai_theme_regenerate,
                      ),
                    ),
                  ),
                  FushiPressScale(
                    child: FushiTextButton.icon(
                      key: const ValueKey<String>(
                        'music_visualizer_ai_theme_revert',
                      ),
                      onPressed: busy || !controller.record.hasPrevious
                          ? null
                          : () => unawaited(controller.revert()),
                      icon: const Icon(FushiIcons.undo),
                      label: Text(t.music_visualizer_ai_theme_revert),
                    ),
                  ),
                  FushiPressScale(
                    child: FushiTextButton.icon(
                      key: const ValueKey<String>(
                        'music_visualizer_ai_theme_clear',
                      ),
                      onPressed: busy || current == null
                          ? null
                          : () => unawaited(controller.clear()),
                      icon: const Icon(FushiIcons.close),
                      label: Text(t.music_visualizer_ai_theme_clear),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 名字 / 描述 + 配色色块 + 前几个关键词（用各自的颜色画在主题背景上）。
class _ThemePreview extends StatelessWidget {
  const _ThemePreview({required this.variant});

  final AiVisualizerThemeVariant variant;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return DecoratedBox(
      key: const ValueKey<String>('music_visualizer_ai_theme_preview'),
      decoration: BoxDecoration(
        color: variant.background,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            if (variant.name.isNotEmpty)
              Text(
                variant.name,
                style: text.titleMedium?.copyWith(color: variant.text),
              ),
            if (variant.description.isNotEmpty)
              Text(
                variant.description,
                style: text.bodyMedium?.copyWith(color: variant.secondary),
              ),
            const SizedBox(height: 10),
            Row(
              children: <Widget>[
                for (final Color c in <Color>[
                  variant.text,
                  variant.accent,
                  variant.secondary,
                ])
                  Padding(
                    padding: const EdgeInsetsDirectional.only(end: 6),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: c,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: variant.text.withValues(alpha: 0.3),
                        ),
                      ),
                      child: const SizedBox(width: 18, height: 18),
                    ),
                  ),
              ],
            ),
            if (variant.wordColors.isNotEmpty) ...<Widget>[
              const SizedBox(height: 10),
              Wrap(
                spacing: 10,
                runSpacing: 4,
                children: <Widget>[
                  for (final MapEntry<String, Color> e
                      in variant.wordColors.entries.take(12))
                    Text(
                      e.key,
                      style: text.bodyMedium?.copyWith(
                        color: e.value,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
