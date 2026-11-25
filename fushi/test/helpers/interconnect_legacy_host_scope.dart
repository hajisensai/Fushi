import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi_engine/sync/sync_channel_scope.dart';

/// 假互联后端（不连真 host）的基线作用域（BUG-4434）：固定无作用域
/// （存储维度 = 逻辑维度，旧行不动），不核对 host 钉住。按逻辑维度读写
/// `sync_baselines` 的既有断言因此不用改。
mixin LegacyInterconnectHostScope on InterconnectSyncBackend {
  @override
  Future<InterconnectHostScope> liveHostScope() async =>
      const InterconnectHostScope(
        pin: InterconnectHostPin(identity: null, serial: 0),
        adoption: LegacyBaselineAdoption.keep,
      );

  @override
  void checkHostPin(InterconnectHostPin pin) {}

  @override
  Future<void> verifyHostPin(InterconnectHostPin pin) async {}
}

/// 真互联后端连着认不出 hostId 的老条目（明文 http 地址、无 hostId）时，逻辑维度
/// [logical] 的存储维度（BUG-4434 残留①）：按它使用的配对凭据 [token] 分槽。
/// 这类测试读基线要读这一槽——无后缀维度在绑定时已被搬空，对它断言 `isNull`
/// 是空转。
String credentialScopedDimension(String logical, String token) =>
    remoteScopedKey(logical, InterconnectScopeIdentity.credential(token).tag);
