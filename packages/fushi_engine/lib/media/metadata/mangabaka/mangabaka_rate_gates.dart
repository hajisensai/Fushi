/// MangaBaka 按 IP 计的两档限流（搜索 30 次/分、其他 180 次/分）在本进程里的**唯一**
/// 计数点。
///
/// 两个调用方共用这一组闸，不各自计数：
/// - 追踪插件 `moe.fushi.tracking.mangabaka`：插件管理器为它取 [search]（插件的每个
///   请求都按最严的搜索档计，上限即插件清单的 30 次/分）；
/// - 书 / 漫画「每卷封面 + 横幅」刮削：搜索走 [search]，按 id 取 / 拉图片列表走
///   [other]。
///
/// [other] 定成 150：插件那份请求只记在 [search] 上（最多 30 次/分），两边加起来不超过
/// 官方的 180。各自另建单例互不知道对方，留余量也协调不了（审查意见 8）。
library;

import 'package:fushi_engine/media/tracking/tracking_rate_gate.dart';

/// MangaBaka API 的 host（限流按它共享）。
const String kMangaBakaApiHost = 'api.mangabaka.org';

/// 一组 MangaBaka 限流闸。
final class MangaBakaRateGates {
  MangaBakaRateGates({TrackingRateGate? search, TrackingRateGate? other})
    : search = search ?? TrackingRateGate(maxRequests: 30),
      other = other ?? TrackingRateGate(maxRequests: 150);

  /// 进程级共享实例。
  static final MangaBakaRateGates shared = MangaBakaRateGates();

  /// `/v1/series/search`（以及追踪插件的全部请求）。
  final TrackingRateGate search;

  /// 其余 API 请求（`/v1/series/{id}`、`/v1/series/{id}/images`）。
  final TrackingRateGate other;
}
