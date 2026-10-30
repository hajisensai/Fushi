import 'package:fushi_music/fushi_music.dart' show MusicPluginManager;

import 'package:fushi/src/models/store_compliance.dart';

/// 在线音源插件（设置 › 音乐 › 插件音源、服务器曲库页的插件条目、插件曲目取流与歌词）
/// 是否存在：合规门（iOS 不带插件宿主）+ 本机原生库带插件运行时（iOS 伞形库不编入）。
///
/// 判据只写在这一处，消费端只问它——这条边界失效是静默的（本地与 CI 全绿、上架才被拒），
/// 守卫见 `test/build/ios_store_compliance_guard_test.dart`。
bool get isMusicPluginSourcesAvailable =>
    StoreRestrictedCapability.onlineMusicSource.isAvailable &&
    MusicPluginManager.isSupported;
