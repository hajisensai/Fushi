/// 服务端身份：设备 id、共享 host token（legacy Basic 密码）、admin token。
///
/// 三个值都只生成一次、落 `preferences` 表（键与 app 的 `SyncRepository` 同名，
/// 让同一份数据目录能被桌面 Fushi 接管时身份不变）。
library;

import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi_server/src/server_prefs.dart';

class ServerIdentity {
  ServerIdentity._({
    required this.deviceId,
    required this.hostToken,
  });

  /// 与 app `SyncRepository._keyDeviceId` 同键。
  static const String kDeviceIdKey = 'sync_device_id';

  /// 与 app `SyncRepository` 的 host 密码键同键（`sync_server_password`）。
  static const String kHostTokenKey = 'sync_server_password';

  final String deviceId;

  /// 共享 host token：老客户端的 Basic 密码；新客户端配对后拿 per-peer token。
  final String hostToken;

  static Future<ServerIdentity> loadOrCreate(ServerPrefs prefs) async {
    String? deviceId = await prefs.getRaw(kDeviceIdKey);
    if (deviceId == null || deviceId.isEmpty) {
      deviceId = FushiSyncServer.generateToken();
      await prefs.setRaw(kDeviceIdKey, deviceId);
    }
    String? hostToken = await prefs.getRaw(kHostTokenKey);
    if (hostToken == null || hostToken.isEmpty) {
      hostToken = FushiSyncServer.generateToken();
      await prefs.setRaw(kHostTokenKey, hostToken);
    }
    return ServerIdentity._(deviceId: deviceId, hostToken: hostToken);
  }
}
