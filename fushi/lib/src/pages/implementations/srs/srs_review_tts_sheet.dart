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
///
/// 当前值、写回与朗读声音的选择器由打开它的「复习选项」注入（不 import AppModel / provider / 声音
/// 选择器：本文件不进 AppModel 的 import 环，test/build/import_cycle_guard_test.dart）。
library;

import 'package:fushi_engine/srs/srs_card_tts.dart' show kSrsSentenceAudioField;
import 'package:fushi_anki/fushi_anki_core.dart' show FushiCardFields;
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
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

/// 打开「朗读」面板。[initial] 是当前设置，[onChanged] 写回偏好；朗读声音那一行的摘要与选择器由
/// [voiceSummary] / [pickVoice] 给（「复习选项」接到 TTS 兜底声音的选择器上）。
Future<void> showSrsReviewTtsSheet(
  BuildContext context, {
  required SrsReviewTts initial,
  required ValueChanged<SrsReviewTts> onChanged,
  required String Function() voiceSummary,
  required Future<void> Function(BuildContext context) pickVoice,
}) => adaptiveModalSheet<void>(
  context: context,
  builder: (BuildContext context) => SrsReviewTtsSheet(
    initial: initial,
    onChanged: onChanged,
    voiceSummary: voiceSummary,
    pickVoice: pickVoice,
  ),
);

/// 「朗读」面板正文。
class SrsReviewTtsSheet extends StatefulWidget {
  const SrsReviewTtsSheet({
    super.key,
    required this.initial,
    required this.onChanged,
    required this.voiceSummary,
    required this.pickVoice,
  });

  final SrsReviewTts initial;
  final ValueChanged<SrsReviewTts> onChanged;

  /// 朗读声音的当前选择（设置行副标题）。
  final String Function() voiceSummary;

  /// 弹出声音选择器并写回（取消时什么也不做）。
  final Future<void> Function(BuildContext context) pickVoice;

  @override
  State<SrsReviewTtsSheet> createState() => _SrsReviewTtsSheetState();
}

class _SrsReviewTtsSheetState extends State<SrsReviewTtsSheet> {
  late SrsReviewTts _tts = widget.initial;

  void _set(SrsReviewTts value) {
    setState(() => _tts = value);
    widget.onChanged(value);
  }

  Future<void> _pickVoice() async {
    await widget.pickVoice(context);
    // 声音偏好不经 provider：选完自己刷新摘要。
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final SrsReviewTts tts = _tts;
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
                subtitle: widget.voiceSummary(),
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
