import 'package:fushi/src/sync/interconnect_sync_backend.dart';

/// 假互联后端（不连真 host）的基线作用域（BUG-4434）：固定落在老条目作用域
/// （无 hostId → 存储维度 = 逻辑维度，旧行不动），不核对 host 钉住。按逻辑维度读写
/// `sync_baselines` 的既有断言因此不用改。
mixin LegacyInterconnectHostScope on InterconnectSyncBackend {
  @override
  Future<InterconnectHostScope> liveHostScope() async =>
      const InterconnectHostScope(
        pin: InterconnectHostPin(hostId: null, serial: 0),
        adoption: LegacyBaselineAdoption.keep,
      );

  @override
  void checkHostPin(InterconnectHostPin pin) {}

  @override
  Future<void> verifyHostPin(InterconnectHostPin pin) async {}
}
