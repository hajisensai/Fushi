/// 复习页 ⋯「复习选项 › 朗读」（拍板台 YmWT1x57XV，维护者选 A + B）：
///
/// - 识别模板里的 Anki `{{tts}}` 标签（渲染成朗读键）；
/// - 选中文字时可以朗读；
/// - 没有音频的字段显示朗读键（例句 / 词头可选）；
/// - 自动播放也念朗读键；
/// - 朗读声音（与查词 / 制卡的 TTS 兜底声音同一项）。
///
/// 改了立即生效（按 profile 的偏好 `srs_review_tts`，srs_review_tts.dart）：复习页监听渲染选项，
/// 当前卡原地重渲。合成的音频怎么缓存见 srs_card_tts_audio.dart。
library;

import 'package:fushi_engine/srs/srs_card_tts.dart' show kSrsSentenceAudioField;
import 'package:fushi_anki/fushi_anki_core.dart' show FushiCardFields;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/creator/mining_tts_fallback.dart';
import 'package:fushi/src/creator/mining_tts_fallback_picker.dart';
import 'package:fushi/src/media/audiobook/tts/tts_services.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/srs/srs_review_tts.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_animated_size.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_toggles.dart'
    show FushiSegmentedButton;
import 'package:fushi/src/utils/components/settings_shared.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// 打开「朗读」面板。
Future<void> showSrsReviewTtsSheet(BuildContext context) =>
    adaptiveModalSheet<void>(
      context: context,
      builder: (BuildContext context) => const SrsReviewTtsSheet(),
    );

/// 「朗读」面板正文。
class SrsReviewTtsSheet extends ConsumerStatefulWidget {
  const SrsReviewTtsSheet({super.key});

  @override
  ConsumerState<SrsReviewTtsSheet> createState() => _SrsReviewTtsSheetState();
}

class _SrsReviewTtsSheetState extends ConsumerState<SrsReviewTtsSheet> {
  AppModel get _app => ref.read(appProvider);

  TtsServices get _services => TtsServices.of(_app.prefsRepo);

  void _set(SrsReviewTts value) => _app.setSrsReviewTts(value);

  Future<void> _pickVoice() async {
    final MiningTtsFallbackVoice? picked =
        await showMiningTtsFallbackVoicePicker(
          context,
          _services,
          current: miningTtsFallbackVoiceOf(_app.prefsRepo),
        );
    if (picked == null) return;
    await setMiningTtsFallbackVoice(_app.prefsRepo, picked);
    // 声音偏好不经 provider：这里自己刷新摘要。
    if (mounted) setState(() {});
  }

  String _voiceSummary() {
    final MiningTtsFallbackVoice configured = miningTtsFallbackVoiceOf(
      _app.prefsRepo,
    );
    // 「不使用」管的是查词 / 制卡的自动兜底；卡面上的朗读键按系统语音念（srsTtsPlanOf）。
    final MiningTtsFallbackVoice effective =
        configured.kind == MiningTtsFallbackKind.none
        ? const MiningTtsFallbackVoice.system()
        : configured;
    final String summary = miningTtsFallbackSummary(
      choice: effective,
      presets: _services.store.loadPresets(),
      descriptorOf: (String id) => _services.registry[id],
      systemEngineName: systemTtsEngineName(),
    );
    return '$summary\n${t.srs_review_tts_voice_shared}';
  }

  @override
  Widget build(BuildContext context) {
    final SrsReviewTts tts = ref.watch(srsReviewTtsProvider);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    int step = 0;
    Widget stagger(Widget child) =>
        FushiStaggeredEntrance(index: step++, child: child);
    return FushiModalSheetFrame(
      title: t.srs_review_tts_title,
      leadingIcon: FushiIcons.volumeUp,
      scrollable: true,
      body: FushiEntranceScope(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            stagger(
              AdaptiveSettingsSwitchRow(
                key: const ValueKey<String>('srs-review-tts-template-tags'),
                title: t.srs_review_tts_template_tags,
                subtitle: t.srs_review_tts_template_tags_hint,
                subtitleMaxLines: 3,
                value: tts.templateTags,
                onChanged: (bool v) => _set(tts.copyWith(templateTags: v)),
              ),
            ),
            stagger(
              AdaptiveSettingsSwitchRow(
                key: const ValueKey<String>('srs-review-tts-selection'),
                title: t.srs_review_tts_selection,
                subtitle: t.srs_review_tts_selection_hint,
                subtitleMaxLines: 3,
                value: tts.speakSelection,
                onChanged: (bool v) => _set(tts.copyWith(speakSelection: v)),
              ),
            ),
            stagger(
              AdaptiveSettingsSwitchRow(
                key: const ValueKey<String>('srs-review-tts-fill'),
                title: t.srs_review_tts_fill,
                subtitle: t.srs_review_tts_fill_hint,
                subtitleMaxLines: 4,
                value: tts.fillMissing,
                onChanged: (bool v) => _set(tts.copyWith(fillMissing: v)),
              ),
            ),
            stagger(
              FushiAnimatedSize(
                duration: fushiMotionDuration(context, FushiMotion.short),
                curve: FushiMotion.standard,
                child: tts.fillMissing
                    ? Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: tokens.spacing.page,
                          vertical: tokens.spacing.gap,
                        ),
                        child: FushiSegmentedButton<String>(
                          key: const ValueKey<String>('srs-review-tts-fields'),
                          multiSelectionEnabled: true,
                          emptySelectionAllowed: true,
                          selected: tts.fillFields,
                          segments: <ButtonSegment<String>>[
                            for (final String f in kSrsReviewTtsFillFieldOrder)
                              ButtonSegment<String>(
                                value: f,
                                label: Text(_fieldLabel(f)),
                              ),
                          ],
                          onSelectionChanged: (Set<String> v) =>
                              _set(tts.copyWith(fillFields: v)),
                        ),
                      )
                    : const SizedBox(width: double.infinity),
              ),
            ),
            stagger(
              AdaptiveSettingsSwitchRow(
                key: const ValueKey<String>('srs-review-tts-autoplay'),
                title: t.srs_review_tts_autoplay,
                subtitle: t.srs_review_tts_autoplay_hint,
                subtitleMaxLines: 3,
                value: tts.autoplay,
                onChanged: (bool v) => _set(tts.copyWith(autoplay: v)),
              ),
            ),
            stagger(
              AdaptiveSettingsNavigationRow(
                key: const ValueKey<String>('srs-review-tts-voice'),
                title: t.srs_review_tts_voice,
                subtitle: _voiceSummary(),
                icon: FushiIcons.voice,
                showIcon: true,
                onTap: () => _pickVoice(),
              ),
            ),
            stagger(
              Padding(
                padding: EdgeInsets.fromLTRB(
                  tokens.spacing.page,
                  tokens.spacing.gap,
                  tokens.spacing.page,
                  0,
                ),
                child: Text(
                  t.srs_review_tts_cache_note,
                  key: const ValueKey<String>('srs-review-tts-cache-note'),
                  style: context.fushiType.bodySmall.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _fieldLabel(String field) => switch (field) {
  kSrsSentenceAudioField => t.srs_review_tts_field_sentence,
  FushiCardFields.termAudio => t.srs_review_tts_field_term,
  _ => field,
};
