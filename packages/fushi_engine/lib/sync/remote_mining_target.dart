/// 互联「制卡到已配对设备」时，手机挑卡落到主机的哪里（docs/specs/2026-11-05-server-srs-design.md §4.8）。
///
/// - `POST /api/mine/targets`（空请求体）：主机能落到哪些地方（它的默认、Fushi 复习的各份 profile 与牌组、Anki 的牌组）；
/// - `/api/mine`、`/api/mine/forward`、`/api/duplicate` 可带 `target: {kind?, profile?, deck?}`：缺项 = 主机默认；
///   回包带 `landed: {kind, profile?, deck?}` 说实际落到了哪；主机没有所点名的就退回默认并带 `targetUnavailable: true`。
///
/// 全是可选字段：老主机不认 `target` 照旧落到自己的默认，老客户端不发 `target` 照旧。
library;

import 'dart:convert';

import 'package:fushi_anki/fushi_anki_core.dart'
    show MineOutcome, MineResult, MiningRequestOverrides;
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

/// 主机能让手机挑落点（服务端 `ServerRemoteMiningService`、桌面 host `HostRemoteMiningTargets`）。路由在 [FushiRemoteMiningService] 同时实现它时
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

/// 一次请求解析好的落点（[resolveRemoteMiningTarget]）。[fellBack]：手机**显式**点名的那一类 / profile / 牌组
/// 主机给不了，落到了主机默认（回包据此带 `targetUnavailable: true`）。
class RemoteMiningResolution {
  const RemoteMiningResolution({
    required this.kind,
    this.profile,
    this.deck,
    this.fellBack = false,
  });

  /// [kRemoteMiningKindAnki] / [kRemoteMiningKindReview]。
  final String kind;

  /// 复习落进哪份 profile（uid）；Anki 恒 null。
  final String? profile;

  /// 写进单卡牌组覆盖的牌组全名；null = 那一处自己的默认牌组。
  final String? deck;

  final bool fellBack;

  RemoteMiningTarget get landing =>
      RemoteMiningTarget(kind: kind, profile: profile, deck: deck);

  @override
  bool operator ==(Object other) =>
      other is RemoteMiningResolution &&
      other.kind == kind &&
      other.profile == profile &&
      other.deck == deck &&
      other.fellBack == fellBack;

  @override
  int get hashCode => Object.hash(kind, profile, deck, fellBack);

  @override
  String toString() =>
      'RemoteMiningResolution(${landing.toJson()}, fellBack: $fellBack)';
}

/// 把请求里的 [target] 解析成主机实际的落点（服务端与桌面 host 同一套语义，§4.8）：
/// - 缺项 = 主机默认：类别取 [defaultKind]；复习的 profile 取手机带来的 uid（主机有那份时），否则
///   [defaultReviewProfile]；牌组取 [configuredReviewDeck]（null = 那份 profile 自己的制卡牌组）；
/// - 所选的那一类主机没有就退到另一类；所点名的 profile 主机没有就落默认 profile，牌组只对点名的那份
///   profile 有意义（退了就不沿用）；
/// - 只带 `{profile}`（手机自己的 uid，即「主机默认」）而主机没有那份不算退回；点名了类别或牌组才算。
///
/// - 显式点名的牌组主机那一处没有（被删 / 改名）：**整个**退回真正的主机默认（与不带 `target` 同一落点，
///   不是那份 profile 自己的默认牌组），报退回——卡、转发与查重都落在手机随后会用的同一个地方（拍板
///   2026-11-08：此前卡进了点名 profile 的默认牌组，手机却已退回主机默认，那张卡查重看不见）。
///
/// [ankiAvailable]：Anki 这条路能不能写；[defaultReviewProfile] 为 null = 复习不可用。两者都不可用 → null。
/// [ankiDeckExists] / [reviewDeckExists]：点名的牌组在不在（Anki 全名；复习按那份 profile 的牌组树全名）；
/// null = 不查（按存在处理）。
Future<RemoteMiningResolution?> resolveRemoteMiningTarget(
  RemoteMiningTarget? target, {
  required String defaultKind,
  required bool ankiAvailable,
  required String? defaultReviewProfile,
  required bool Function(String uid) servesReviewProfile,
  String? Function(String uid)? configuredReviewDeck,
  Future<bool> Function(String deck)? ankiDeckExists,
  Future<bool> Function(String profileUid, String deck)? reviewDeckExists,
}) async {
  RemoteMiningResolution? resolve(RemoteMiningTarget? t) =>
      _resolveRemoteMiningTarget(
        t,
        defaultKind: defaultKind,
        ankiAvailable: ankiAvailable,
        defaultReviewProfile: defaultReviewProfile,
        servesReviewProfile: servesReviewProfile,
        configuredReviewDeck: configuredReviewDeck,
      );
  final RemoteMiningResolution? to = resolve(target);
  final String? asked = target?.deck;
  // 只查点名的、确实被带进落点的牌组（退了类别 / profile 时牌组已经丢掉）。
  if (to == null || asked == null || to.deck != asked) return to;
  final bool exists = to.kind == kRemoteMiningKindAnki
      ? await ankiDeckExists?.call(asked) ?? true
      : await reviewDeckExists?.call(to.profile!, asked) ?? true;
  if (exists) return to;
  final RemoteMiningResolution? def = resolve(null);
  return def == null
      ? null
      : RemoteMiningResolution(
          kind: def.kind,
          profile: def.profile,
          deck: def.deck,
          fellBack: true,
        );
}

RemoteMiningResolution? _resolveRemoteMiningTarget(
  RemoteMiningTarget? target, {
  required String defaultKind,
  required bool ankiAvailable,
  required String? defaultReviewProfile,
  required bool Function(String uid) servesReviewProfile,
  String? Function(String uid)? configuredReviewDeck,
}) {
  final bool reviewAvailable = defaultReviewProfile != null;
  final String? askedKind = target?.kind;
  String kind = askedKind ?? defaultKind;
  if (kind == kRemoteMiningKindReview && !reviewAvailable) {
    kind = kRemoteMiningKindAnki;
  } else if (kind == kRemoteMiningKindAnki &&
      !ankiAvailable &&
      reviewAvailable) {
    kind = kRemoteMiningKindReview;
  }
  final bool kindKept = askedKind == null || askedKind == kind;
  if (kind == kRemoteMiningKindAnki) {
    if (!ankiAvailable) return null;
    return RemoteMiningResolution(
      kind: kind,
      // 从复习退到 Anki 时不沿用复习的牌组名。
      deck: kindKept ? target?.deck : null,
      fellBack: !kindKept,
    );
  }
  final String? asked = target?.profile;
  final String uid = asked != null && servesReviewProfile(asked)
      ? asked
      : defaultReviewProfile!;
  // 牌组只对点名的那份 profile 有意义：退到默认 profile 时不沿用别人那份的牌组名。
  final String? askedDeck = kindKept && (asked == null || asked == uid)
      ? target?.deck
      : null;
  final String? configured = configuredReviewDeck?.call(uid);
  return RemoteMiningResolution(
    kind: kind,
    profile: uid,
    deck:
        askedDeck ??
        (configured == null || configured.isEmpty ? null : configured),
    // 手机默认带自己的 profile uid（不点名类别 / 牌组）：主机没有那份就落默认，这是「主机默认」的本义，
    // 不算退回。点名了类别或牌组才算手机的显式选择。
    fellBack:
        !kindKept ||
        (asked != null &&
            asked != uid &&
            (askedKind != null || target?.deck != null)),
  );
}

/// 把「落到哪个牌组」写进载荷的单卡覆盖（与「高级制卡」同一个键 [MiningRequestOverrides.wireKey]）；
/// 单卡已经选了牌组的不动。[own] = 这张卡自己选了牌组（这时实际牌组与 [deck] 不同是预期内的）。
({String raw, bool own}) withRemoteMiningDeck(
  String rawPayloadJson,
  String? deck,
) {
  if (deck == null || deck.isEmpty) return (raw: rawPayloadJson, own: false);
  final Object? decoded = jsonDecode(rawPayloadJson);
  if (decoded is! Map) return (raw: rawPayloadJson, own: false);
  final Map<String, dynamic> fields = Map<String, dynamic>.from(decoded);
  final MiningRequestOverrides? existing = MiningRequestOverrides.readFrom(
    fields,
  );
  if ((existing?.deckName ?? '').isNotEmpty) {
    return (raw: rawPayloadJson, own: true);
  }
  fields[MiningRequestOverrides.wireKey] = jsonEncode(<String, Object?>{
    ...?existing?.toJson(),
    'deck': deck,
  });
  return (raw: jsonEncode(fields), own: false);
}

/// 一次按 [to] 落卡的回包：实际落点 + 是否退回。[target] 点名的牌组主机没有（被删 / 改名）、卡落进了
/// 默认牌组时同样如实报 `targetUnavailable`（[ownDeck] = 这张卡自己选了牌组，不算）。
RemoteMineLanding remoteMineLandingFor(
  RemoteMineResult result, {
  required MineOutcome outcome,
  required RemoteMiningResolution to,
  required RemoteMiningTarget? target,
  required bool ownDeck,
}) => RemoteMineLanding(
  result,
  landed: RemoteMiningTarget(
    kind: to.kind,
    profile: to.profile,
    deck: outcome.deckName ?? to.deck,
  ),
  targetUnavailable:
      to.fellBack ||
      (outcome.result == MineResult.success &&
          !ownDeck &&
          target?.deck != null &&
          to.deck == target!.deck &&
          outcome.deckName != null &&
          outcome.deckName != to.deck),
);
