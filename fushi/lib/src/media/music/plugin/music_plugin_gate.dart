import 'package:fushi_music/fushi_music.dart' show MusicPluginManager;

import 'package:fushi/src/models/store_compliance.dart';

/// 本机**自己跑**在线音源插件（曲库「来源」页的插件管理与安装、把插件包共享给别的设备、替别的
/// 设备中继）：合规门（iOS 不带插件宿主）+ 本机原生库带插件运行时（iOS 伞形库不编入）。
///
/// 判据只写在这一处，消费端只问它——这条边界失效是静默的（本地与 CI 全绿、上架才被拒），
/// 守卫见 `test/build/ios_store_compliance_guard_test.dart`。
bool get isMusicPluginSourcesAvailable =>
    StoreRestrictedCapability.onlineMusicSource.isAvailable &&
    MusicPluginManager.isSupported;

/// 本机不跑插件，经 Fushi 互联用「我的设备」host 上的插件（插件中继，拍板台 wOMR4_Er7s
/// 方案 b）：本机自己能跑时不走中继（插件包另经「来源共享」装到本机）。
bool get isMusicPluginRelayClient =>
    !isMusicPluginSourcesAvailable && interconnectPluginRelayAvailable;

/// 本机能**用**插件音源（自己跑或经中继）：插件来源的搜索 / 浏览、插件曲目取流、插件歌词、
/// 平台「喜欢」与取流音质设置都问它。安装 / 管理入口仍只问 [isMusicPluginSourcesAvailable]。
bool get isMusicPluginSourcesUsable =>
    isMusicPluginSourcesAvailable || isMusicPluginRelayClient;
