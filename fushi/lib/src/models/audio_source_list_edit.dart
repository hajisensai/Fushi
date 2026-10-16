/// 「管理音频来源」列表的编辑规则（纯函数）：校验、加互联源、重排、恢复默认。
///
/// 设置页的音频来源对话框（`AudioSourcesDialog`）与控制通道
/// （`fushi_cli config items lookup.audio_sources.items …`）共用这一份，
/// 两边对同一份列表做的是同一种改动；落盘都走 `AppModel.setAudioSourceConfigs`。
library;

import 'package:fushi_engine/utils/net/url_input_normalizer.dart';

import 'package:fushi/src/models/audio_source_config.dart';

/// 自定义远端音频 URL 合法性：必须是 http(s) 链接，且至少含一个
/// `{term}` / `{reading}` 占位符（否则播放时无法代入查词参数）。
bool isValidRemoteAudioUrl(String text) {
  // 折全角后再判：否则合法模板会被拒，而错误提示只说「地址无效」，
  // 用户完全看不出问题出在标点上（BUG-1807）。
  final String value = normalizeUrlInput(text);
  final Uri? uri = Uri.tryParse(value);
  if (uri == null || !uri.hasAuthority) return false;
  if (uri.scheme != 'http' && uri.scheme != 'https') return false;
  return value.contains('{term}') || value.contains('{reading}');
}

/// 列表里是否已有 Fushi 互联源（它只能有一条）。
bool hasFushiRemoteAudioSource(List<AudioSourceConfig> sources) =>
    sources.any((AudioSourceConfig s) => s.kind == AudioSourceKind.fushiRemote);

/// 把第 [from] 条挪到第 [to] 位（下标按挪动后的列表算，越界夹紧）。
List<AudioSourceConfig> moveAudioSource(
  List<AudioSourceConfig> sources,
  int from,
  int to,
) {
  if (from < 0 || from >= sources.length) {
    throw RangeError.index(from, sources, 'from');
  }
  final List<AudioSourceConfig> next = List<AudioSourceConfig>.of(sources);
  final AudioSourceConfig item = next.removeAt(from);
  next.insert(to.clamp(0, next.length), item);
  return next;
}

/// 「重置」：保留互联源（原来有的话）与全部本地库，远端只剩内置的 Anki 预设
/// （默认关闭，与新装一致）。[ankiLocalAudioUrl] = `AppModel.ankiLocalAudioUrl`。
List<AudioSourceConfig> resetAudioSourcesToDefaults(
  List<AudioSourceConfig> sources, {
  required String ankiLocalAudioUrl,
}) => <AudioSourceConfig>[
  if (hasFushiRemoteAudioSource(sources)) AudioSourceConfig.fushiRemote(),
  AudioSourceConfig.remoteAudio(
    url: ankiLocalAudioUrl,
    label: 'Anki',
    enabled: false,
  ),
  ...sources.where(
    (AudioSourceConfig s) => s.kind == AudioSourceKind.localAudio,
  ),
];
