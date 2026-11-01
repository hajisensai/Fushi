import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/mining/advanced_mining/advanced_mining_capabilities.dart';
import 'package:fushi/src/mining/advanced_mining/advanced_mining_controller.dart';
import 'package:fushi/src/mining/advanced_mining/advanced_mining_sections.dart'
    show AdvancedMiningChoiceChip;
import 'package:fushi/src/mining/sentence_audio_source_text.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_engine/mining/sentence_audio_source.dart'
    show SentenceAudioSourcePick;

/// 高级制卡「句子音频」分区里的来源选择（反馈 pNF2ZL7Kfc）：当前播放音轨 / 中置声道 /
/// 这个视频的第 N 条音轨。只对这一张卡生效（写进覆盖项，不改设置）；宿主没给
/// [AdvancedMiningAudioSection.sources] 时不渲染。
///
/// 试听仍是播放器播放当前音轨的那一段——播放器放不出「只有中置声道」或另一条轨，
/// 所以试听与写卡在来源上可能不同；区间（起止）照旧同源。
class AdvancedMiningAudioSourceChips extends StatelessWidget {
  const AdvancedMiningAudioSourceChips({super.key, required this.controller});

  final AdvancedMiningController controller;

  @override
  Widget build(BuildContext context) {
    final AdvancedMiningController c = controller;
    final AdvancedMiningAudioSources? sources = c.audioSection?.sources;
    final SentenceAudioSourcePick? selected = c.audioSource;
    if (sources == null || selected == null || c.omitAudio) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            t.video_mining_audio_source,
            style: context.fushiType.labelMedium.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: <Widget>[
              for (final SentenceAudioSourcePick pick in sources.choices)
                AdvancedMiningChoiceChip(
                  label: sentenceAudioSourceLabel(pick),
                  selected: pick == selected,
                  onSelected: c.locked ? null : () => c.setAudioSource(pick),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
