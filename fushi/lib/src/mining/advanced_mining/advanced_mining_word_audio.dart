import 'package:fushi/src/mining/advanced_mining/advanced_mining_capabilities.dart';
import 'package:fushi/src/utils/misc/lookup_audio_playback.dart';
import 'package:fushi/src/utils/misc/tts_channel.dart';

/// 组装「高级制卡」的单词音频分区（两条开窗车道共用）。
///
/// [listChoices] 是查词弹窗那层的 `listWordAudioChoices`——与弹窗 ♪「选择音频源」
/// 菜单同一个数据源（`[{name, variant, url}]`，url 是弹窗可播的 `http(s)` / `data:`）。
/// 试听走查词发音的同一个宿主播放器（[playWordAudioUrlNatively]：Android 原生
/// MediaPlayer、桌面单词音频播放器），音量同查词发音；对话框打开时弹窗停在屏外，
/// 不能借弹窗的 `<audio>`。
AdvancedMiningWordAudioSection buildAdvancedMiningWordAudioSection({
  required Future<List<Map<String, String>>> Function() listChoices,
}) {
  return AdvancedMiningWordAudioSection(
    listChoices: () async => <AdvancedMiningWordAudioChoice>[
      for (final Map<String, String> m in await listChoices())
        if ((m['url'] ?? '').isNotEmpty)
          AdvancedMiningWordAudioChoice(
            name: m['name'] ?? '',
            variant: m['variant'] ?? '',
            url: m['url']!,
          ),
    ],
    preview: (String url) async {
      // 新试听先掐上一段（与弹窗 ♪ 的 interrupt 行为一致）。
      await TtsChannel.instance.stop();
      return playWordAudioUrlNatively(url);
    },
    stopPreview: TtsChannel.instance.stop,
  );
}
