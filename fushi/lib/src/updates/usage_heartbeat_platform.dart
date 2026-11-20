// 安装统计心跳的平台判据（纯函数，叶子文件）：服务端通知（notice_feed.dart）与心跳同口径
// 判平台，单独成文件免得它为一个判据 import 整个心跳服务。

/// 发心跳的平台（与服务端 `PING_PLATFORMS` 一致）。
const Set<String> kUsageHeartbeatPlatforms = <String>{
  'android',
  'windows',
  'macos',
  'linux',
};

/// **纯函数**：[operatingSystem]（`Platform.operatingSystem` 口径）在心跳里的平台键；
/// iOS 与其它平台返回 null（不发心跳、反馈也不带安装 id）。
String? usageHeartbeatPlatformFor(String operatingSystem) =>
    kUsageHeartbeatPlatforms.contains(operatingSystem) ? operatingSystem : null;
