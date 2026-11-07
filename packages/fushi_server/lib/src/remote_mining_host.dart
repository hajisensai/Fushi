/// 互联「制卡到服务端」：对端（手机 / 浏览器扩展）把制卡请求发到 `/api/mine`、
/// `/api/mine/forward`，服务端用**自己的** Anki 设置渲染并写进本机的 Anki 同步客户端
/// 库（[ServerAnkiLanding] 那一份 `fushi-anki-sync` 会话），再随常规同步上到 AnkiWeb /
/// 自建同步服务器。
///
/// 与 app 的 `_AppModelRemoteLookupService` 的挖词部分一一对应；差别都是服务端的
/// 真实能力边界：
/// * 沉浸制卡（截图 / 动图 / 句子音频要从视频流现裁）依赖 app 里的
///   `ImmersionMiningEngine`，服务端不做 —— 回明确的失败原因；
/// * 没有 Anki 桌面程序：「在 Anki 中打开这个词」恒 failed，笔记类型模板读写与
///   collection.media 去重同 app 的同步客户端后端一样不支持（null / false）。
library;

import 'dart:convert';

import 'package:fushi_anki/fushi_anki_core.dart';
import 'package:fushi_engine/anki_sync/anki_sync_miner.dart';
import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/sync/forwarded_mine_materialize.dart';
import 'package:fushi_engine/sync/forwarded_mine_payload.dart';
import 'package:fushi_engine/sync/fushi_remote_lookup_service.dart';
import 'package:fushi_engine/sync/immersion_mine_payload.dart';
import 'package:fushi_engine/sync/remote_mining_target.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_miner.dart';
import 'package:fushi_srs/fushi_srs.dart' show SrsDeckTree, SrsDeckView;
import 'package:fushi_server/src/anki_landing.dart';
import 'package:fushi_server/src/config/server_srs_config.dart';
import 'package:fushi_server/src/dictionary_host.dart';
import 'package:fushi_server/src/server_srs.dart';

/// 落一张卡：未渲染的载荷 JSON + 制卡上下文 → 结果。
typedef ServerMineCard =
    Future<MineOutcome> Function(
      String rawPayloadJson,
      AnkiMiningContext context,
    );

/// 沉浸制卡在服务端不可用时回给对端的原因。
const String kServerImmersionMiningUnsupported =
    '服务端不支持沉浸制卡（截图 / 动图 / 句子音频需在客户端裁好后用「制卡到服务端」转发）';

/// 把一次 [MineOutcome] 映射成 wire 结果，失败写进服务端日志（与 app 的
/// `remoteMineResultFromOutcome` 同一语义：error 带原因、success 带部分成功的音频警告与
/// 实际落卡牌组）。
RemoteMineResult serverRemoteMineResult(
  MineOutcome outcome, {
  String source = 'ServerMining',
}) {
  switch (outcome.result) {
    case MineResult.error:
      final String reason = outcome.errorDetail ?? 'Mining failed';
      engineLog.log(source, outcome.error ?? reason, outcome.stackTrace);
      return RemoteMineResult(
        result: outcome.result.name,
        message: reason,
        detail: outcome.errorDetail,
      );
    case MineResult.success:
      final String? warn = outcome.audioWarning;
      return RemoteMineResult(
        result: outcome.result.name,
        message: warn != null && warn.isNotEmpty ? warn : null,
        deckName: outcome.deckName,
      );
    case MineResult.duplicate:
    case MineResult.notConfigured:
    case MineResult.queued:
      return RemoteMineResult(result: outcome.result.name);
  }
}

/// 落到哪：解析好的目标（[ServerRemoteMiningService._resolve]）。
/// [fellBack]：手机点名的那一类 / profile 服务端没有，退回了默认。
typedef _ServerLanding = ({
  String kind,
  String? profile,
  String? deck,
  bool fellBack,
});

/// 互联制卡在服务端的落点分派（docs/specs/2026-11-05-server-srs-design.md §4.8）：
/// - Anki：[ServerAnkiLanding] 的同步客户端库（老行为）；
/// - Fushi 复习：[ServerSrs] 里某份 profile 的复习库（[SrsMiner]）；
/// - 手机可在请求里带 `target` 挑落点（[FushiRemoteMiningTargetService]），不带 = 服务端默认
///   （`srs.mining_target`；`auto` = 选了复习库且 Anki 没配好时进复习，否则进 Anki）。复习默认落到手机自己那份
///   profile（`target.profile`，新客户端会带），服务端没有那份就落默认 profile。
class ServerRemoteMiningService
    implements
        FushiRemoteMiningService,
        FushiRemoteMiningTargetService,
        FushiRemoteMiningAvailability {
  ServerRemoteMiningService({
    ServerMineCard? mineCard,
    Future<bool> Function(String expression)? isDuplicateExpression,
    Future<void> Function(String dictionaryMediaJson)? writeDictionaryMedia,
    ServerSrs? srs,
    ServerSrsConfig Function()? srsConfig,
    AnkiSettings Function()? ankiSettings,
    bool Function()? ankiReady,
  }) : _mineCard = mineCard,
       _isDuplicateExpression = isDuplicateExpression,
       _writeDictionaryMedia = writeDictionaryMedia,
       _srs = srs,
       _srsConfig = srsConfig ?? (() => const ServerSrsConfig()),
       _ankiSettings = ankiSettings ?? (() => const AnkiSettings()),
       _ankiReady = ankiReady ?? (() => mineCard != null);

  /// 生产装配：Anki 走 [landing]（带了 `fushi-anki-sync` 才有），复习走 [srs]；词典外字从 [dictionaries]
  /// （服务端装了词典引擎时）落进媒体缓存。
  factory ServerRemoteMiningService.forHost({
    required ServerAnkiLanding landing,
    required ServerSrs srs,
    required ServerSrsConfig Function() srsConfig,
    ServerDictionaryHost? dictionaries,
  }) => ServerRemoteMiningService(
    mineCard: landing.available ? landing.mineCard : null,
    isDuplicateExpression: landing.available
        ? (String expression) => landingIsDuplicate(landing, expression)
        : null,
    writeDictionaryMedia: dictionaries != null && dictionaries.available
        ? dictionaries.writeDictionaryMediaCache
        : null,
    srs: srs,
    srsConfig: srsConfig,
    ankiSettings: () => landing.settings,
    // 登录过、拉到过牌组清单 = Anki 配好了（auto 据此判断）。
    ankiReady: () =>
        landing.available && landing.settings.availableDecks.isNotEmpty,
  );

  /// 只有 Anki 落地的装配（测试与没有复习库的场合）。
  factory ServerRemoteMiningService.forLanding(
    ServerAnkiLanding landing, {
    ServerDictionaryHost? dictionaries,
  }) => ServerRemoteMiningService(
    mineCard: landing.mineCard,
    isDuplicateExpression: (String expression) =>
        landingIsDuplicate(landing, expression),
    writeDictionaryMedia: dictionaries != null && dictionaries.available
        ? dictionaries.writeDictionaryMediaCache
        : null,
  );

  final ServerMineCard? _mineCard;
  final Future<bool> Function(String expression)? _isDuplicateExpression;
  final Future<void> Function(String dictionaryMediaJson)?
  _writeDictionaryMedia;
  final ServerSrs? _srs;
  final ServerSrsConfig Function() _srsConfig;
  final AnkiSettings Function() _ankiSettings;
  final bool Function() _ankiReady;

  bool get _reviewAvailable => _srs?.defaultProfile != null;

  /// 没带 Anki helper、也没有可用的复习库：制卡路由当没接线（`capabilities.mining: false`）。
  @override
  bool get miningAvailable => _ankiAvailable || _reviewAvailable;
  bool get _ankiAvailable => _mineCard != null;

  /// 服务端默认落到哪一类。
  String _defaultKind() {
    switch (_srsConfig().miningTarget) {
      case ServerMiningTarget.anki:
        return kRemoteMiningKindAnki;
      case ServerMiningTarget.review:
        return kRemoteMiningKindReview;
      case ServerMiningTarget.auto:
        return _reviewAvailable && !_ankiReady()
            ? kRemoteMiningKindReview
            : kRemoteMiningKindAnki;
    }
  }

  /// [target] → 实际落点：所选的那一类没有就退到另一类；复习的 profile 没提供就落默认 profile。
  _ServerLanding? _resolve(RemoteMiningTarget? target) {
    String kind = target?.kind ?? _defaultKind();
    final String? askedKind = target?.kind;
    if (kind == kRemoteMiningKindReview && !_reviewAvailable) {
      kind = kRemoteMiningKindAnki;
    } else if (kind == kRemoteMiningKindAnki &&
        !_ankiAvailable &&
        _reviewAvailable) {
      kind = kRemoteMiningKindReview;
    }
    if (kind == kRemoteMiningKindAnki) {
      if (!_ankiAvailable) return null;
      return (
        kind: kind,
        profile: null,
        // 从复习退到 Anki 时不沿用复习的牌组名。
        deck: askedKind == null || askedKind == kind ? target?.deck : null,
        fellBack: askedKind != null && askedKind != kind,
      );
    }
    final ServerSrs srs = _srs!;
    final String? asked = target?.profile;
    final String uid = asked != null && srs.storeFor(asked) != null
        ? asked
        : srs.defaultProfile!.uid;
    // 牌组只对点名的那份 profile 有意义：退到默认 profile 时不沿用别人那份的牌组名。
    final bool kindKept = askedKind == null || askedKind == kind;
    final String? askedDeck = kindKept && (asked == null || asked == uid)
        ? target?.deck
        : null;
    // 手机没点名牌组：用配置给这份定的制卡牌组（全名；空 = 默认牌组）。
    final String? configured = _srsConfig().miningDecks[uid];
    final String? deck =
        askedDeck ??
        (configured == null || configured.isEmpty ? null : configured);
    return (
      kind: kind,
      profile: uid,
      deck: deck,
      // 手机默认带自己的 profile uid（不点名类别 / 牌组）：服务端没有那份就落默认，这是「服务端默认」的
      // 本义，不算退回。点名了类别或牌组才算手机的显式选择。
      fellBack:
          !kindKept ||
          (asked != null &&
              asked != uid &&
              (askedKind != null || target?.deck != null)),
    );
  }

  /// 把「落到哪个牌组」写进载荷的单卡覆盖（与「高级制卡」同一个键）；单卡已经选了牌组的不动。
  /// [own] = 这张卡自己选了牌组（这时实际牌组与 [deck] 不同是预期内的）。
  static ({String raw, bool own}) _withDeck(
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

  Future<RemoteMineLanding> _mineTo(
    RemoteMiningTarget? target,
    String rawPayloadJson,
    AnkiMiningContext context,
    String source,
  ) async {
    final _ServerLanding? to = _resolve(target);
    if (to == null) {
      return RemoteMineLanding(
        RemoteMineResult(result: MineResult.notConfigured.name),
      );
    }
    final ({String raw, bool own}) withDeck = _withDeck(
      rawPayloadJson,
      to.deck,
    );
    final String raw = withDeck.raw;
    final MineOutcome outcome;
    if (to.kind == kRemoteMiningKindAnki) {
      outcome = await _mineCard!(raw, context);
    } else {
      final SrsMiner? miner = _srs!.minerFor(to.profile!);
      outcome = miner == null
          ? MineOutcome.failure('Fushi review is not available on the server')
          : await miner.mine(
              settings: _ankiSettings(),
              rawPayloadJson: raw,
              context: context,
            );
      if (outcome.result == MineResult.success) {
        _srs.notifyWrite(to.profile!);
      }
    }
    return RemoteMineLanding(
      serverRemoteMineResult(outcome, source: source),
      landed: RemoteMiningTarget(
        kind: to.kind,
        profile: to.profile,
        deck: outcome.deckName ?? to.deck,
      ),
      // 手机点名的牌组主机没有（被删 / 改名）：卡落进了默认牌组，如实说，手机据此退回主机默认。
      targetUnavailable:
          to.fellBack ||
          (outcome.result == MineResult.success &&
              !withDeck.own &&
              target?.deck != null &&
              to.deck == target!.deck &&
              outcome.deckName != null &&
              outcome.deckName != to.deck),
    );
  }

  @override
  Future<RemoteMineResult> mineEntry({
    required Map<String, String> fields,
    required String sentence,
  }) async => (await mineEntryTo(fields: fields, sentence: sentence)).result;

  @override
  Future<RemoteMineLanding> mineEntryTo({
    required Map<String, String> fields,
    required String sentence,
    RemoteMiningTarget? target,
  }) async {
    // 弹窗把外字登记进 fields.dictionaryMedia 并渲染成占位 <img>；先把字节落缓存，
    // 渲染时才替换得上（与 app 的 BUG-2190 同一步骤）。
    await _writeDictionaryMedia?.call(fields['dictionaryMedia'] ?? '');
    return _mineTo(
      target,
      jsonEncode(fields),
      AnkiMiningContext(sentence: sentence),
      'ServerMining.mineEntry',
    );
  }

  @override
  Future<RemoteMineResult> mineForwarded(ForwardedMinePayload payload) async =>
      (await mineForwardedTo(payload)).result;

  @override
  Future<RemoteMineLanding> mineForwardedTo(
    ForwardedMinePayload payload, {
    RemoteMiningTarget? target,
  }) async {
    try {
      return await withMaterializedMiningContext<RemoteMineLanding>(
        payload,
        (String raw, AnkiMiningContext context) =>
            _mineTo(target, raw, context, 'ServerMining.mineForwarded'),
        // 客户端经本服务端查词时词典只在这里：搬不来字节的插图由本机词典补齐，
        // 与 [mineEntry] 同一步骤（反馈 PDgaHL5qmj）。
        writeHostDictionaryMedia: _writeDictionaryMedia,
      );
    } catch (e, st) {
      engineLog.log('ServerMining.mineForwarded', e, st);
      return RemoteMineLanding(
        RemoteMineResult(
          result: MineResult.error.name,
          message: '服务端制卡失败',
          detail: '$e',
        ),
      );
    }
  }

  @override
  Future<RemoteMineResult> mineImmersion(ImmersionMinePayload payload) async {
    engineLog.logDiagnostic(
      'ServerMining.mineImmersion',
      kServerImmersionMiningUnsupported,
    );
    return RemoteMineResult(
      result: MineResult.error.name,
      message: kServerImmersionMiningUnsupported,
      detail: 'immersion mining needs the app-side media pipeline',
    );
  }

  @override
  Future<bool> isDuplicate({
    required String expression,
    required String reading,
  }) => isDuplicateIn(expression: expression, reading: reading);

  @override
  Future<bool> isDuplicateIn({
    required String expression,
    required String reading,
    RemoteMiningTarget? target,
  }) async {
    if (expression.isEmpty) return false;
    try {
      final _ServerLanding? to = _resolve(target);
      if (to == null) return false;
      if (to.kind == kRemoteMiningKindReview) {
        final SrsMiner? miner = _srs!.minerFor(to.profile!);
        return miner != null && await miner.isDuplicate(expression, reading);
      }
      return await _isDuplicateExpression?.call(expression) ?? false;
    } catch (e, st) {
      // 查重是每次查词都跑的高频探测：后端没登录 / helper 起不来回「不重复」，真正制卡时
      // mineEntry 会把原因报给用户（与 app 的同步客户端后端同口径）。
      engineLog.log('ServerMining.isDuplicate', e, st);
      return false;
    }
  }

  @override
  Future<Map<String, Object?>> miningTargets() async {
    final _ServerLanding? def = _resolve(null);
    final List<Map<String, Object?>> review = <Map<String, Object?>>[];
    for (final ServerSrsProfile prof
        in _srs?.readyProfiles ?? const <ServerSrsProfile>[]) {
      final SrsDbStore? store = prof.store;
      if (store == null) continue;
      final SrsDeckTree tree = await store.deckTree();
      review.add(<String, Object?>{
        'profile': prof.uid,
        'name': prof.name,
        'decks': <String>[
          for (final SrsDeckView d in tree.decks) tree.fullName(d.id),
        ]..sort(),
      });
    }
    return <String, Object?>{
      'default': def == null
          ? null
          : RemoteMiningTarget(
              kind: def.kind,
              profile: def.profile,
              deck: def.deck,
            ).toJson(),
      'review': review,
      if (_ankiAvailable)
        'anki': <String, Object?>{
          'decks': <String>[
            for (final AnkiDeck d in _ankiSettings().availableDecks) d.name,
          ],
        },
    };
  }

  @override
  Future<AnkiOpenWordOutcome> openWordInAnki({
    required String expression,
    required String reading,
  }) async => AnkiOpenWordOutcome.failed;

  @override
  Future<AnkiNoteTypeDefinition?> readNoteTypeDefinition(
    String modelName,
  ) async => null;

  @override
  Future<bool> updateNoteTypeStyling(String modelName, String css) async =>
      false;

  @override
  Future<bool> updateNoteTypeTemplates(
    String modelName,
    List<AnkiCardTemplate> templates,
  ) async => false;

  @override
  Future<bool> probeMediaMaintenance() async => false;

  @override
  Future<AnkiMediaDedupReport?> runMediaDedup({bool dryRun = true}) async =>
      null;
}

/// 用落地会话查重：按服务端设置选中的笔记类型、以表记为首字段（与 app 的
/// `AnkiSyncClientRepository.isDuplicate` 同口径）。没有 helper / 没选笔记类型 → false。
Future<bool> landingIsDuplicate(
  ServerAnkiLanding landing,
  String expression,
) async {
  final AnkiSyncMiner? miner = landing.miner;
  if (miner == null || expression.isEmpty) return false;
  final AnkiNoteType? noteType = miner.selectedNoteType(landing.settings);
  if (noteType == null) return false;
  return miner.session.isDuplicate(
    notetype: noteType.name,
    firstField: expression,
  );
}
