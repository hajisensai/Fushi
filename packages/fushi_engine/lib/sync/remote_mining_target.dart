/// 互联「制卡到已配对设备」时，手机挑卡落到主机的哪里（docs/specs/2026-11-05-server-srs-design.md §4.8）。
///
/// - `POST /api/mine/targets`（空请求体）：主机能落到哪些地方（它的默认、Fushi 复习的各份 profile 与牌组、Anki 的牌组）；
/// - `/api/mine`、`/api/mine/forward`、`/api/duplicate` 可带 `target: {kind?, profile?, deck?}`：缺项 = 主机默认；
///   回包带 `landed: {kind, profile?, deck?}` 说实际落到了哪；主机没有所点名的就退回默认并带 `targetUnavailable: true`。
///
/// 全是可选字段：老主机不认 `target` 照旧落到自己的默认，老客户端不发 `target` 照旧。
library;

import 'package:fushi_engine/sync/forwarded_mine_payload.dart';
import 'package:fushi_engine/sync/fushi_remote_lookup_service.dart';

/// 落到 Anki。
const String kRemoteMiningKindAnki = 'anki';

/// 落到 Fushi 复习。
const String kRemoteMiningKindReview = 'review';

/// 请求里的目标 / 回包里的实际落点。全部为 null = 主机默认。[deck] 是牌组全名（Anki 的牌组名全库唯一；复习用
/// 牌组树里的全名），与「高级制卡」的单卡牌组覆盖（`miningOverrides.deck`）同一口径。
class RemoteMiningTarget {
  const RemoteMiningTarget({this.kind, this.profile, this.deck});

  /// 解析请求体里的 `target`；不是对象 / 全空 → null（= 主机默认）。
  static RemoteMiningTarget? fromJson(Object? raw) {
    if (raw is! Map) return null;
    String? text(Object? v) =>
        v is String && v.trim().isNotEmpty ? v.trim() : null;
    final String? kind = text(raw['kind']);
    final RemoteMiningTarget t = RemoteMiningTarget(
      kind: kind == kRemoteMiningKindAnki || kind == kRemoteMiningKindReview
          ? kind
          : null,
      profile: text(raw['profile']),
      deck: text(raw['deck']),
    );
    return t.isEmpty ? null : t;
  }

  final String? kind;
  final String? profile;
  final String? deck;

  bool get isEmpty => kind == null && profile == null && deck == null;

  Map<String, Object?> toJson() => <String, Object?>{
    'kind': ?kind,
    'profile': ?profile,
    'deck': ?deck,
  };

  @override
  bool operator ==(Object other) =>
      other is RemoteMiningTarget &&
      other.kind == kind &&
      other.profile == profile &&
      other.deck == deck;

  @override
  int get hashCode => Object.hash(kind, profile, deck);

  @override
  String toString() => 'RemoteMiningTarget(${toJson()})';
}

/// 一次制卡的结果 + 实际落点。
class RemoteMineLanding {
  const RemoteMineLanding(
    this.result, {
    this.landed,
    this.targetUnavailable = false,
  });

  final RemoteMineResult result;
  final RemoteMiningTarget? landed;

  /// 请求点名的落点主机没有（不再提供那份 profile / 没有那一类），卡落到了主机默认。手机据此把「保存到」
  /// 退回主机默认并提示（回包字段 `targetUnavailable: true`）。
  final bool targetUnavailable;
}

/// 主机能让手机挑落点（服务端；桌面 host 之后也可以实现）。路由在 [FushiRemoteMiningService] 同时实现它时
/// 才把请求里的 `target` 交进来、才挂 `POST /api/mine/targets`；没实现的主机行为与以前逐字节一致。
abstract interface class FushiRemoteMiningTargetService {
  /// `POST /api/mine/targets` 的回包：
  /// `{default: {kind, profile?, deck?}, review: [{profile, name, decks: [name]}], anki?: {decks: [name]}}`。
  Future<Map<String, Object?>> miningTargets();

  Future<RemoteMineLanding> mineEntryTo({
    required Map<String, String> fields,
    required String sentence,
    RemoteMiningTarget? target,
  });

  Future<RemoteMineLanding> mineForwardedTo(
    ForwardedMinePayload payload, {
    RemoteMiningTarget? target,
  });

  Future<bool> isDuplicateIn({
    required String expression,
    required String reading,
    RemoteMiningTarget? target,
  });
}

/// 制卡此刻能不能落到任何地方（服务端：没带 Anki helper、也没选复习库时不能）。实现它的 service 在不可用时，主机的
/// 制卡路由一律当没接线（404、`capabilities.mining: false`）；可用性随配置变化即时生效，不必重启。
abstract interface class FushiRemoteMiningAvailability {
  bool get miningAvailable;
}

/// [service] 此刻可用就是它，否则 null（没实现 [FushiRemoteMiningAvailability] 的一律算可用）。
FushiRemoteMiningService? activeRemoteMiningService(
  FushiRemoteMiningService? service,
) => switch (service) {
  final FushiRemoteMiningAvailability a when !a.miningAvailable => null,
  _ => service,
};
