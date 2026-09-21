/// 互联 host「允许为对端实时转码视频」开关的**读侧单一入口**：app 的
/// `PreferencesRepository` 与无头服务端的 `ServerPrefs` 都是 [PrefStore]，读同一张
/// `preferences` 表，默认值只能有一份（与 `video_resource_prefs.dart` 同范式）。
library;

import 'package:fushi_engine/foundation/pref_store.dart';

/// host 是否允许对端请求实时转码（弱网降码率播放）。
///
/// 默认**开**：这是个纯按需能力——对端不请求画质档就一个 ffmpeg 都不会起，行为与
/// 从前逐字节相同。关掉它的是「host 是台不想被烤的低功耗机器」这种明确意愿，那应该
/// 由用户显式表达，而不是让所有人默认得不到弱网可用性。
const String kInterconnectTranscodeEnabledPref =
    'interconnect_transcode_enabled';

/// 读 host 转码开关。缺省（老库、从没设过）按开处理。
bool readInterconnectTranscodeEnabled(PrefStore? prefs) {
  if (prefs == null) return true;
  final Object? raw = prefs.getPref(
    kInterconnectTranscodeEnabledPref,
    defaultValue: true,
  );
  if (raw is bool) return raw;
  // 历史上 `preferences` 表存过字符串化的 bool（不同写入路径），读侧一并认。
  if (raw is String) return raw.toLowerCase() != 'false';
  return true;
}
