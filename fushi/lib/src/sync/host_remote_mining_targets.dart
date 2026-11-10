/// 桌面 / 移动 app 当互联主机时，手机「制卡到已配对设备」的「保存到」（docs/specs/2026-11-05-server-srs-design.md
/// §4.8）：`POST /api/mine/targets` 列出本机真能写的地方，`/api/mine`、`/api/mine/forward`、`/api/duplicate` 的
/// `target` 按它落卡 / 查重。
///
/// 本机能写的地方：
/// - **主机默认**：本机挖词目标（激活配置；复习模块开着且目标是 Fushi 复习 → 复习，否则 Anki）。照旧走
///   [HostRemoteMiningTargets.defaultRepository]（`hostMiningAnkiRepository` 那条链），老客户端行为逐字节不变；
/// - **Fushi 复习**：复习模块开着时，本机各配置在 srs.db 里已有的复习副本（激活配置恒在列），每份列出它的牌组全名；
/// - **Anki**：本机 Anki 后端（AnkiConnect / AnkiDroid / 同步客户端……由平台决定）拉到过牌组清单时才列出。
///
/// 解析语义与服务端同一份（[resolveRemoteMiningTarget]）：缺项 = 主机默认；只带手机自己的 profile uid（= 「主机
/// 默认」）而本机没有那份不算退回；显式点名的类别 / profile / 牌组给不了就落主机默认并报 `targetUnavailable`。
library;

import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/srs/srs_miner.dart';
import 'package:fushi_engine/sync/fushi_remote_lookup_service.dart';
import 'package:fushi_engine/sync/remote_mining_target.dart';
import 'package:fushi_srs/fushi_srs.dart' show SrsDeckTree, SrsDeckView;

/// 本机复习里的一份配置。
class HostReviewMiningProfile {
  const HostReviewMiningProfile({required this.uid, required this.name});

  /// 配置的全局 uid（与手机同一份同步配置相同）。
  final String uid;

  /// 配置名（手机列表里显示）。
  final String name;
}

/// 本机复习此刻能落到哪些配置。null（见 [HostRemoteMiningTargets.reviewCatalog]）= 复习不可用。
class HostReviewMiningCatalog {
  const HostReviewMiningCatalog({
    required this.activeProfile,
    required this.profiles,
  });

  /// App 激活配置的 uid：复习的主机默认落这里。
  final String activeProfile;

  /// 可选的配置（含激活配置）。
  final List<HostReviewMiningProfile> profiles;

  bool serves(String uid) =>
      profiles.any((HostReviewMiningProfile p) => p.uid == uid);
}

/// 一次按目标落卡用的仓库 + 落点。
typedef _HostLanding = ({
  RemoteMiningResolution? to,
  BaseAnkiRepository? repository,
});

/// 主机侧的落点分派（依赖全部注入，AppModel 装配，测试直接构造）。
class HostRemoteMiningTargets {
  HostRemoteMiningTargets({
    required String Function() defaultKind,
    required BaseAnkiRepository Function() defaultRepository,
    required BaseAnkiRepository Function() ankiRepository,
    required Future<HostReviewMiningCatalog?> Function() reviewCatalog,
    required Future<BaseAnkiRepository?> Function(String profileUid)
    reviewRepository,
    required Future<SrsMiner?> Function(String profileUid) reviewMiner,
    required RemoteMineResult Function(MineOutcome outcome) toResult,
  }) : _defaultKind = defaultKind,
       _defaultRepository = defaultRepository,
       _ankiRepository = ankiRepository,
       _reviewCatalog = reviewCatalog,
       _reviewRepository = reviewRepository,
       _reviewMiner = reviewMiner,
       _toResult = toResult;

  /// 本机挖词目标此刻是哪一类（[kRemoteMiningKindAnki] / [kRemoteMiningKindReview]）。
  final String Function() _defaultKind;

  /// 主机默认那条链（本机挖词目标决定落 Anki 还是激活配置的复习）。
  final BaseAnkiRepository Function() _defaultRepository;

  /// 裸本机 Anki 后端（激活配置的 Anki 设置）。
  final BaseAnkiRepository Function() _ankiRepository;

  /// 复习不可用（模块关着 / 还没装配）时为 null。
  final Future<HostReviewMiningCatalog?> Function() _reviewCatalog;

  /// 落进 [profileUid] 那份复习的仓库（制卡 / 查重）；打不开时为 null。
  final Future<BaseAnkiRepository?> Function(String profileUid)
  _reviewRepository;

  /// [profileUid] 那份复习的制卡器（列牌组、算默认牌组）；打不开时为 null。
  final Future<SrsMiner?> Function(String profileUid) _reviewMiner;

  /// [MineOutcome] → wire 结果（失败写错误日志，app 用 `remoteMineResultFromOutcome`）。
  final RemoteMineResult Function(MineOutcome outcome) _toResult;

  static const String _reviewUnavailable = 'Fushi review is not available.';

  /// 本机 Anki 拉到过的牌组名（没连过 Anki = 空）。
  Future<List<String>> _ankiDecks() async {
    try {
      return <String>[
        for (final AnkiDeck d
            in (await _ankiRepository().loadSettings()).availableDecks)
          d.name,
      ];
    } catch (e, st) {
      engineLog.log('HostMiningTargets.ankiDecks', e, st);
      return const <String>[];
    }
  }

  Future<HostReviewMiningCatalog?> _catalog() async {
    try {
      return await _reviewCatalog();
    } catch (e, st) {
      engineLog.log('HostMiningTargets.reviewCatalog', e, st);
      return null;
    }
  }

  /// [target] → 落点。复习不可用时主机默认只能是 Anki；Anki 这条路「能写」= 它就是主机默认、或复习不可用
  /// （Anki 是唯一的路）、或拉到过牌组清单。
  ///
  /// 复习的配置清单只在可能落复习时才读（主机默认是复习，或手机点名复习）：查重每次查词都跑，主机默认是
  /// Anki 时手机带来的 `{profile}` 用不上它。[listing] = 列「保存到」，一律读。
  Future<(RemoteMiningResolution?, HostReviewMiningCatalog?, String)> _resolve(
    RemoteMiningTarget? target, {
    bool listing = false,
  }) async {
    final String hostKind = _defaultKind();
    final HostReviewMiningCatalog? catalog =
        listing ||
            hostKind == kRemoteMiningKindReview ||
            target?.kind == kRemoteMiningKindReview
        ? await _catalog()
        : null;
    final String defaultKind = catalog == null
        ? kRemoteMiningKindAnki
        : hostKind;
    final bool ankiAvailable =
        catalog == null ||
        defaultKind == kRemoteMiningKindAnki ||
        (await _ankiDecks()).isNotEmpty;
    // 点名的牌组没有了（被删 / 改名）→ 整个退回主机默认（引擎同一规则，与服务端一致）。
    final RemoteMiningResolution? to = await resolveRemoteMiningTarget(
      target,
      defaultKind: defaultKind,
      ankiAvailable: ankiAvailable,
      defaultReviewProfile: catalog?.activeProfile,
      servesReviewProfile: (String uid) => catalog?.serves(uid) ?? false,
      ankiDeckExists: (String deck) async {
        final List<String> decks = await _ankiDecks();
        // 没拉到过牌组清单：无从判断，交给 Anki 落卡时自己回落（回包仍按实际牌组报）。
        return decks.isEmpty || decks.contains(deck);
      },
      reviewDeckExists: (String uid, String deck) async =>
          (await _reviewDecks(uid))?.decks.contains(deck) ?? false,
    );
    // 第三项是本机挖词目标本身（不是退到 Anki 后的那个）：主机默认那条链按它落卡，判断「落点是不是主机默认」
    // 必须拿它比。
    return (to, catalog, hostKind);
  }

  /// [target] 落到哪、用哪个仓库。不带 `target`（老客户端 / 浏览器扩展）照旧走主机默认那条链、不解析；落点就是
  /// 主机默认那一处（同一类；复习则同一份激活配置）时同样用那条链；否则按落点现建。
  Future<_HostLanding> _landingFor(RemoteMiningTarget? target) async {
    if (target == null) return (to: null, repository: _defaultRepository());
    final (
      RemoteMiningResolution? to,
      HostReviewMiningCatalog? catalog,
      String hostKind,
    ) = await _resolve(
      target,
    );
    if (to == null) return (to: null, repository: _defaultRepository());
    final bool hostDefault =
        to.kind == hostKind &&
        (to.kind == kRemoteMiningKindAnki ||
            to.profile == catalog?.activeProfile);
    if (hostDefault) return (to: to, repository: _defaultRepository());
    if (to.kind == kRemoteMiningKindAnki) {
      return (to: to, repository: _ankiRepository());
    }
    return (to: to, repository: await _reviewRepository(to.profile!));
  }

  /// 按 [target] 落一张卡（[rawPayloadJson] 未渲染载荷，牌组经单卡覆盖写进去）。
  Future<RemoteMineLanding> mine(
    RemoteMiningTarget? target, {
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async {
    final _HostLanding landing = await _landingFor(target);
    final RemoteMiningResolution? to = landing.to;
    final BaseAnkiRepository? repo = landing.repository;
    final ({String raw, bool own}) withDeck = withRemoteMiningDeck(
      rawPayloadJson,
      to?.deck,
    );
    final MineOutcome outcome = repo == null
        ? MineOutcome.failure(_reviewUnavailable)
        : await repo.mineEntry(rawPayloadJson: withDeck.raw, context: context);
    final RemoteMineResult result = _toResult(outcome);
    if (to == null) return RemoteMineLanding(result);
    return remoteMineLandingFor(
      result,
      outcome: outcome,
      to: to,
      target: target,
      ownDeck: withDeck.own,
    );
  }

  /// 「已经有卡」按卡要去的那个地方判（Anki 按本机 Anki 的查重范围，复习按那份配置的复习）。fail-soft。
  Future<bool> isDuplicate(
    RemoteMiningTarget? target, {
    required String expression,
    required String reading,
  }) async {
    if (expression.isEmpty) return false;
    try {
      final BaseAnkiRepository? repo = (await _landingFor(target)).repository;
      return repo != null && await repo.isDuplicate(expression, reading);
    } catch (e, st) {
      // 查重是每次查词都跑的高频探测：回「不重复」，真正制卡时会把原因报给用户。
      engineLog.log('HostMiningTargets.isDuplicate', e, st);
      return false;
    }
  }

  /// `POST /api/mine/targets` 的回包（形状见 [FushiRemoteMiningTargetService.miningTargets]）。
  Future<Map<String, Object?>> targets() async {
    final (
      RemoteMiningResolution? def,
      HostReviewMiningCatalog? catalog,
      String _,
    ) = await _resolve(
      null,
      listing: true,
    );
    final List<Map<String, Object?>> review = <Map<String, Object?>>[];
    String? defaultReviewDeck;
    for (final HostReviewMiningProfile profile
        in catalog?.profiles ?? const <HostReviewMiningProfile>[]) {
      final ({List<String> decks, String? defaultDeck})? decks =
          await _reviewDecks(profile.uid);
      if (decks == null) continue;
      if (def?.profile == profile.uid) defaultReviewDeck = decks.defaultDeck;
      review.add(<String, Object?>{
        'profile': profile.uid,
        'name': profile.name,
        'decks': decks.decks,
      });
    }
    final List<String> ankiDecks = await _ankiDecks();
    return <String, Object?>{
      'default': def == null
          ? null
          : RemoteMiningTarget(
              kind: def.kind,
              profile: def.profile,
              deck: def.deck ?? defaultReviewDeck,
            ).toJson(),
      'review': review,
      if (ankiDecks.isNotEmpty) 'anki': <String, Object?>{'decks': ankiDecks},
    };
  }

  /// [uid] 那份复习的牌组全名（排序）+ 它的制卡牌组（被删回落默认牌组）；打不开时 null（不列这份）。
  Future<({List<String> decks, String? defaultDeck})?> _reviewDecks(
    String uid,
  ) async {
    try {
      final SrsMiner? miner = await _reviewMiner(uid);
      if (miner == null) return null;
      final SrsDeckTree tree = await miner.store.deckTree();
      final SrsResolvedMiningDestination resolved =
          await resolveSrsMiningDestination(miner.store, miner.destination);
      return (
        decks: <String>[
          for (final SrsDeckView d in tree.decks) tree.fullName(d.id),
        ]..sort(),
        defaultDeck: resolved.deckName,
      );
    } catch (e, st) {
      engineLog.log('HostMiningTargets.reviewDecks', e, st);
      return null;
    }
  }
}
