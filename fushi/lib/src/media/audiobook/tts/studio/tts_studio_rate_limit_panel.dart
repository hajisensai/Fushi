/// 「制作有声书」的在线服务限流面板（11-20 反馈 #9）：原来只是一行「在线服务合成
/// 整本书可能被限流」，现在直接给出可调的制作参数——同时请求数、每句间隔、被限流
/// 时怎么办——外加两个替代方案（改用本机声音 / 只做选中的章节）。
///
/// 只在用到在线声音时出现（制作台按 `_usesOnlineVoice` 决定挂不挂）。参数随任务
/// 存进清单（`TtsRenderJob.onlineConcurrency` / `sentenceGapMs` / `rateLimitAction`），
/// 制作流程按它调度（`ttsRenderVoicePacing` / `ttsRenderRetryPolicy`）。
library;

import 'package:fushi_engine/tts/render/tts_render_queue.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/audiobook/tts/studio/tts_studio_text.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

class TtsStudioRateLimitPanel extends StatelessWidget {
  const TtsStudioRateLimitPanel({
    required this.sentences,
    required this.concurrency,
    required this.sentenceGapMs,
    required this.action,
    required this.onConcurrencyChanged,
    required this.onGapChanged,
    required this.onActionChanged,
    required this.onUseLocalVoice,
    required this.onSelectedChaptersOnly,
    super.key,
  });

  /// 选中章节的句数（估算用）。
  final int sentences;

  /// 当前生效的在线并发（任务参数，或声音预设自己的并发）。
  final int concurrency;
  final int sentenceGapMs;
  final TtsRateLimitAction action;
  final ValueChanged<int> onConcurrencyChanged;
  final ValueChanged<int> onGapChanged;
  final ValueChanged<TtsRateLimitAction> onActionChanged;
  final VoidCallback onUseLocalVoice;
  final VoidCallback onSelectedChaptersOnly;

  @override
  Widget build(BuildContext context) {
    final int minutes = ttsStudioEstimateMinutes(
      sentences: sentences,
      concurrency: concurrency,
      gapMs: sentenceGapMs,
    );
    return AdaptiveSettingsSection(
      key: const ValueKey<String>('tts-studio-online-warning'),
      children: <Widget>[
        AdaptiveSettingsRow(
          key: const ValueKey<String>('tts-studio-rate-limit-title'),
          icon: FushiIcons.warning,
          showIcon: true,
          title: t.audiobook_studio_online_warning,
          subtitle: sentences == 0
              ? null
              : t.audiobook_studio_rate_limit_estimate(
                  n: sentences,
                  minutes: minutes,
                ),
        ),
        AdaptiveSettingsSegmentedRow<int>(
          key: const ValueKey<String>('tts-studio-rate-limit-concurrency'),
          title: t.audiobook_studio_rate_limit_concurrency,
          segments: <ButtonSegment<int>>[
            for (final int n in kTtsRenderOnlineConcurrencyChoices)
              ButtonSegment<int>(value: n, label: Text('$n')),
          ],
          selected: ttsStudioConcurrencyChoice(concurrency),
          onChanged: onConcurrencyChanged,
        ),
        AdaptiveSettingsSliderRow(
          key: const ValueKey<String>('tts-studio-rate-limit-gap'),
          title: t.audiobook_studio_rate_limit_gap,
          readout: t.audiobook_studio_rate_limit_gap_value(ms: sentenceGapMs),
          value: sentenceGapMs.toDouble(),
          max: kTtsRenderMaxSentenceGapMs.toDouble(),
          divisions: kTtsRenderMaxSentenceGapMs ~/ kTtsStudioGapStepMs,
          step: kTtsStudioGapStepMs.toDouble(),
          onChanged: (double v) => onGapChanged(
            (v / kTtsStudioGapStepMs).round() * kTtsStudioGapStepMs,
          ),
        ),
        AdaptiveSettingsSegmentedRow<TtsRateLimitAction>(
          key: const ValueKey<String>('tts-studio-rate-limit-action'),
          title: t.audiobook_studio_rate_limit_action,
          segments: <ButtonSegment<TtsRateLimitAction>>[
            ButtonSegment<TtsRateLimitAction>(
              value: TtsRateLimitAction.waitRetry,
              label: Text(t.audiobook_studio_rate_limit_wait),
            ),
            ButtonSegment<TtsRateLimitAction>(
              value: TtsRateLimitAction.pause,
              label: Text(t.audiobook_studio_rate_limit_pause),
            ),
          ],
          selected: action,
          onChanged: onActionChanged,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              FushiPressScale(
                child: FushiFilledButton.tonalIcon(
                  key: const ValueKey<String>('tts-studio-rate-limit-local'),
                  onPressed: onUseLocalVoice,
                  icon: const FushiIcon(FushiIcons.devices),
                  label: Text(t.audiobook_studio_rate_limit_use_local),
                ),
              ),
              FushiPressScale(
                child: FushiOutlinedButton.icon(
                  key: const ValueKey<String>(
                    'tts-studio-rate-limit-selected-only',
                  ),
                  onPressed: onSelectedChaptersOnly,
                  icon: const FushiIcon(FushiIcons.checklist),
                  label: Text(t.audiobook_studio_rate_limit_selected_only),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
