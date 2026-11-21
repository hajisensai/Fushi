/// 远程复习的代际协商（docs/specs/2026-11-11-srs-generation-break.md；G7–G11 总规划 §1.8、拍板 D31）。
///
/// 复习库换到新代（协议 4）后，远程复习的线格式也换代：V1 搬物化输入、客户端用同一个内核重算视图；V2 搬主机
/// 内核算好的视图加每实体版本标签。两代互不兼容，所以两端先按 `GET /api/capabilities` 的能力位判定对方的代，
/// 对不上就明确提示该升级哪一边，不再把对不上的主机悄悄滤掉。
///
/// 这里只放协商：能力位、V2 端点前缀、请求体里的代号、主机的代与本机能说的线格式的配对规则。V2 的数据路径
/// （主机出视图、客户端解视图）在 srs_remote_store.dart / srs_remote_store_routes.dart（G10-2）。本构建只说 V2
/// （[kSrsRemoteClientWire]）；主机声明 V2，同时保留 V1 能力位当拒绝桩（D31）。新旧互拒的四个方向：
/// - 新客户端 → 旧主机：主机只声明 V1 → [SrsRemoteHostCompat.hostNeedsUpgrade]，不发调用；绕过探测直接调也只会碰到
///   旧主机不认的 V2 前缀（404），客户端把它报成 [SrsRemoteStoreError.upgradeRequired]（srs_remote_store_client.dart）。
/// - 旧客户端 → 新主机：旧客户端探到 V1 能力位、发 V1 请求，新主机一律 426 [SrsRemoteStoreError.upgradeRequired]；
///   探测到 V2 的旧客户端（G10-1 之后的构建）判 [SrsRemoteHostCompat.clientNeedsUpgrade]，不发调用。
/// - V2 请求的代号不对（缺键、类型不对、别的代）：426（[srsRemoteV2GenerationError]），给以后的代留口。
///
/// 不依赖 Flutter：app 与无头服务端共用。
library;

import 'package:fushi_engine/srs/srs_remote_store.dart'
    show SrsRemoteStoreError, kSrsRemoteStoreCapability;

/// 新代主机在 `GET /api/capabilities` 声明的能力位：它的远程复习说 V2 线格式。
///
/// 按拍板 D31，新代主机同时保留 [kSrsRemoteStoreCapability]（V1）当拒绝桩：旧客户端照旧探到 V1、发请求，
/// 主机一律回 426 [SrsRemoteStoreError.upgradeRequired]，旧客户端因此能显示出机读码，而不是看不到主机。
const String kSrsRemoteStoreCapabilityV2 = 'srsRemoteStoreV2';

/// V2 端点前缀（`POST <前缀>call`、`GET <前缀>media/<名字>`）。换前缀而不是沿用 V1 的：旧主机不认这个前缀，
/// 收到 V2 请求走 404，不会把它当成 V1 请求来答。
const String kSrsRemoteStoreV2PathPrefix = '/api/srs/remote2/';

/// V2 请求体里复习库代号的键。
const String kSrsRemoteGenerationKey = 'g';

/// V2 线格式对应的复习库代号（协议 4）。
const int kSrsRemoteStoreV2Generation = 4;

/// 远程复习的线格式版本。
enum SrsRemoteWireVersion {
  /// 搬物化输入（身份记录 + 修改记录），客户端用同一个内核重算视图（协议 3 及以前）。
  v1,

  /// 搬主机内核算好的视图 + 每实体版本标签（协议 4）。
  v2,
}

/// 本机这个构建的远程复习客户端说的线格式：V2（G10-2 接上数据路径）。[srsRemoteHostCompat] 据此把只说 V1 的主机判成
/// 「主机需要升级」。
const SrsRemoteWireVersion kSrsRemoteClientWire = SrsRemoteWireVersion.v2;

/// 一台主机按能力位判定出的远程复习代。
enum SrsRemoteHostGeneration {
  /// 没有声明远程复习（复习模块没开、或主机太旧没有这个功能）。
  none,

  /// 只声明 V1：协议 3 的主机。
  v1Only,

  /// 声明了 V2：新代主机（它可能同时声明 V1，那只是拒绝桩，见 [kSrsRemoteStoreCapabilityV2]）。
  v2,
}

/// 按 `GET /api/capabilities` 的回包判定主机的代：声明了 V2 就是 [SrsRemoteHostGeneration.v2]（V1 是否同时
/// 声明不影响），只声明 V1 是 [SrsRemoteHostGeneration.v1Only]，都没有是 [SrsRemoteHostGeneration.none]。
/// 能力位只认字面 `true`（与 `declaresCapability` 同一口径）。
SrsRemoteHostGeneration srsRemoteHostGenerationOf(
  Map<Object?, Object?> capabilities,
) {
  if (capabilities[kSrsRemoteStoreCapabilityV2] == true) {
    return SrsRemoteHostGeneration.v2;
  }
  if (capabilities[kSrsRemoteStoreCapability] == true) {
    return SrsRemoteHostGeneration.v1Only;
  }
  return SrsRemoteHostGeneration.none;
}

/// 本机与一台主机的远程复习能不能接上。
enum SrsRemoteHostCompat {
  /// 主机没有远程复习：不列。
  unavailable,

  /// 两边说同一代线格式：正常连。
  ready,

  /// 主机比本机旧（只说 V1，本机说 V2）：列出来，标「主机需要升级」，不发调用。
  hostNeedsUpgrade,

  /// 本机比主机旧（主机说 V2，本机只说 V1）：列出来，标「本机需要升级」，不发调用。主机上的 V1 只是拒绝桩，
  /// 连过去也只会拿到 426 [SrsRemoteStoreError.upgradeRequired]。
  clientNeedsUpgrade,
}

/// [host] 这一代的主机与说 [client] 线格式的本机能不能接上（默认按本机这个构建，[kSrsRemoteClientWire]）。
SrsRemoteHostCompat srsRemoteHostCompat(
  SrsRemoteHostGeneration host, {
  SrsRemoteWireVersion client = kSrsRemoteClientWire,
}) => switch ((host, client)) {
  (SrsRemoteHostGeneration.none, _) => SrsRemoteHostCompat.unavailable,
  (SrsRemoteHostGeneration.v1Only, SrsRemoteWireVersion.v1) ||
  (
    SrsRemoteHostGeneration.v2,
    SrsRemoteWireVersion.v2,
  ) => SrsRemoteHostCompat.ready,
  (SrsRemoteHostGeneration.v1Only, SrsRemoteWireVersion.v2) =>
    SrsRemoteHostCompat.hostNeedsUpgrade,
  (SrsRemoteHostGeneration.v2, SrsRemoteWireVersion.v1) =>
    SrsRemoteHostCompat.clientNeedsUpgrade,
};

/// 新代主机收到一份 V2 请求体时对代号的判定：[g] 不是 [kSrsRemoteStoreV2Generation] 就回 426
/// [SrsRemoteStoreError.upgradeRequired]（缺键、类型不对（含 `4.0`）、别的代一律如此，给以后的代留口）；
/// 对得上返回 null。
SrsRemoteStoreError? srsRemoteV2GenerationError(Object? g) =>
    g is int && g == kSrsRemoteStoreV2Generation
    ? null
    : const SrsRemoteStoreError(426, SrsRemoteStoreError.upgradeRequired);

/// 新代主机对 V1 端点（[kSrsRemoteStorePathPrefix] 下的一切请求）的统一回答：426
/// [SrsRemoteStoreError.upgradeRequired]，不碰库。
const SrsRemoteStoreError kSrsRemoteV1RefusedOnGen4 = SrsRemoteStoreError(
  426,
  SrsRemoteStoreError.upgradeRequired,
);
