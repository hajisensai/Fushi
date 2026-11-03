import 'package:flutter/foundation.dart' show debugPrint;
import 'package:fushi_engine/sync/video_remote_service.dart'
    show videoRemoteActionUnsupported, videoRemoteCapabilityOpenDiscMenu;

import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/sync/video_remote_client.dart';
import 'package:fushi/src/sync/video_remote_targets.dart'
    show interconnectHostPeerFor;

/// 「在 PC 上打开」（远端原盘第二期第 1 项）：复用视频遥控通道，让提供这个远端库的
/// 那台电脑自己进原盘会话——电脑上盘就在本地，菜单一定开得了，手机只当遥控。
///
/// [hostIdentity] 是互联库当前所连 host 的身份（`InterconnectSyncBackend
/// .connectedHostIdentity`：配对 hostId，老条目是地址）。找不到同一台 host 的已配对
/// 地址（或缺凭据）返回 null。
Future<FushiClientUrl?> interconnectHostPeerForHost(
  SyncRepository repository,
  String hostIdentity,
) async {
  final List<FushiClientUrl> urls = await repository.getFushiClientUrls();
  final String? fallbackToken = await repository.getFushiClientToken();
  for (final FushiClientUrl u in urls) {
    if (!u.enabled) continue;
    final bool same = u.hostId != null && u.hostId!.isNotEmpty
        ? u.hostId == hostIdentity
        : u.url == hostIdentity;
    if (!same || interconnectTokenFor(u, fallbackToken) == null) continue;
    return interconnectHostPeerFor(u, urls, fallbackToken);
  }
  return null;
}

/// 这台 host 能不能被遥控着打开原盘菜单：遥控快照里声明了 `openDiscMenu`。老 host
/// 不认 `discMenu`，会把标题当普通视频直接播——所以必须先问，不能盲发。快照会占住
/// 遥控会话，问完即释放（不挡别的遥控器）。
Future<bool> hostCanOpenDiscMenu(VideoRemoteClient client) async {
  try {
    return _advertisesDiscMenu(await client.snapshot());
  } finally {
    await _release(client);
  }
}

/// 让 host 打开 [videoId]（盘上任一条标题）所在的原盘会话：先取快照（占住遥控会话
/// 并确认能力），再发 `openVideo` + `discMenu`，最后释放会话。失败抛
/// [VideoRemoteError]（`video_missing` / `host_busy` / `action_unsupported`）。
Future<void> openDiscOnHost(VideoRemoteClient client, String videoId) async {
  try {
    if (!_advertisesDiscMenu(await client.snapshot())) {
      throw const VideoRemoteError(videoRemoteActionUnsupported);
    }
    await client.call('openVideo', <String, dynamic>{
      'bookUid': videoId,
      'discMenu': true,
    });
  } finally {
    await _release(client);
  }
}

bool _advertisesDiscMenu(Map<String, dynamic> snapshot) {
  final Object? capabilities = snapshot['capabilities'];
  return capabilities is List &&
      capabilities.contains(videoRemoteCapabilityOpenDiscMenu);
}

Future<void> _release(VideoRemoteClient client) async {
  try {
    await client.disconnect();
  } on Object catch (error) {
    // 主动作（问能力 / 打开）的结果已定，释放失败不改变它；host 侧遥控会话空闲
    // 也会自己过期。记下来而不是静默。
    debugPrint(
      '[remote-disc] releasing the remote-control session failed: $error',
    );
  } finally {
    client.cancelPending();
  }
}
