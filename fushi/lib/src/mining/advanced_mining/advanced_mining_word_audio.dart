import 'package:fushi/src/mining/advanced_mining/advanced_mining_capabilities.dart';
import 'package:fushi/src/models/audio_source_config.dart';
import 'package:fushi/src/utils/misc/lookup_audio_playback.dart';
import 'package:fushi/src/utils/misc/tts_channel.dart';

/// 组装「高级制卡」的单词音频分区（两条开窗车道共用）。
///
/// [listChoices] 是查词弹窗那层的 `listWordAudioChoices`——与弹窗 ♪「选择音频源」
/// 菜单同一个数据源（`[{name, variant, url, sourceIndex, kind}]`，url 是弹窗可播的
/// `http(s)` / `data:`）。[refreshSource] 只重新解析某一个源（确认时刷新互联源的
/// 短时令牌用）。
/// 试听走查词发音的同一个宿主播放器（[playWordAudioUrlNatively]：Android 原生
/// MediaPlayer、桌面单词音频播放器），音量同查词发音；对话框打开时弹窗停在屏外，
/// 不能借弹窗的 `<audio>`。
AdvancedMiningWordAudioSection buildAdvancedMiningWordAudioSection({
  required Future<List<Map<String, String>>> Function() listChoices,
  Future<List<Map<String, String>>> Function(int sourceIndex)? refreshSource,
}) {
  return AdvancedMiningWordAudioSection(
    listChoices: () async => wordAudioChoicesFromWire(await listChoices()),
    refreshSource: refreshSource == null
        ? null
        : (int sourceIndex) async =>
              wordAudioChoicesFromWire(await refreshSource(sourceIndex)),
    preview: (String url) async {
      // 新试听先掐上一段（与弹窗 ♪ 的 interrupt 行为一致）。
      await TtsChannel.instance.stop();
      return playWordAudioUrlNatively(url);
    },
    stopPreview: TtsChannel.instance.stop,
  );
}

/// 桥返回的候选 map（[listWordAudioWebViewChoices] 的形状）→ 对话框候选。没有可播
/// URL 的项跳过；缺 `sourceIndex` 的（别的设备给的默认一条）按 -1、不刷新。
List<AdvancedMiningWordAudioChoice> wordAudioChoicesFromWire(
  List<Map<String, String>> wire,
) => <AdvancedMiningWordAudioChoice>[
  for (final Map<String, String> m in wire)
    if ((m['url'] ?? '').isNotEmpty)
      AdvancedMiningWordAudioChoice(
        name: m['name'] ?? '',
        variant: m['variant'] ?? '',
        url: m['url']!,
        sourceIndex:
            int.tryParse(m[kWordAudioChoiceSourceIndexKey] ?? '') ?? -1,
        refreshAtConfirm:
            m[kWordAudioChoiceKindKey] == AudioSourceKind.fushiRemote.name,
      ),
];
