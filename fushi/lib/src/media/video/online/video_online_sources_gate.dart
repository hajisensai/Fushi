import 'package:fushi/src/media/manga/mihon/mihon_runtime_factory.dart';
import 'package:fushi/src/models/store_compliance.dart';

/// 视频「导入」视图里的在线源三段（仓库 / 扩展 / 在线源）是否该出现：合规门
/// （iOS 不带在线源宿主）+ 运行时平台门（Linux 没有 Mihon 宿主）。两个都过才有。
///
/// 判据只写在这一处，消费端只问它——这条边界失效是静默的（本地与 CI 全绿、
/// 上架才被拒），守卫见 `test/build/ios_store_compliance_guard_test.dart`。
bool get isVideoOnlineSourcesAvailable =>
    StoreRestrictedCapability.onlineVideoSource.isAvailable &&
    MihonRuntimeFactory.isSupported;
