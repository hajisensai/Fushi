/// 「还没认出来」的统一模型：视频、书 / 漫画、游戏共用一套待确认身份队列。
///
/// 之前只有视频有完整的待确认体验（补刮调度、库页提醒条、带原因的待确认清单与
/// 忽略）；书 / 漫画与游戏由 AI 库管家自动刮削，没认出来的条目只落进运行记录的
/// `pendingItems`，界面上哪里都看不到，用户也无从处理（BUG-5283）。
///
/// 这里定义与媒体无关的一层：
/// * [PendingIdentityEntry]：一条没认出来的条目（媒体、稳定键、显示名、原因、
///   候选数、上次尝试时刻）；
/// * [PendingIdentityCause] / [PendingIdentityAiOutcome]：原因与 AI 结论（从视频的
///   挂起标记推广而来，**落库值不变**，`VideoScrapePendingCause` /
///   `VideoScrapeAiOutcome` 是它们的别名）；
/// * [PendingIdentitySource]：每种媒体一个数据源（视频适配补刮调度，书 / 游戏从库管家
///   运行记录 + 当前库状态派生，见 `video_pending_identity.dart` /
///   `curator_pending_identity.dart`）；
/// * 忽略的持久化：每个忽略域一个偏好键（JSON 字符串数组），视频沿用既有的
///   `video_scrape_ignored_works`，已有的忽略数据原样有效。
///
/// 纯 Dart（无 flutter）。
library;

import 'dart:convert';

import 'package:fushi_core/fushi_core.dart';

/// 条目停在「没有身份」的原因。[wire] 是落库值（视频刮削运行记录里的
/// `pending:<wire>` 标记），改枚举名不能改它。
enum PendingIdentityCause {
  /// 成员的 AniDB 文件哈希分属不同作品，又没法自动拆开（仅视频）。
  hashConflict('hash_conflict'),

  /// 资料源给出了候选，但没有一个能换成可直拉的身份。
  noUsableCandidate('no_usable_candidate'),

  /// 多个 / 需复核的候选，AI 没收敛，且这一趟没有人工确认（后台 / 自动路径）。
  awaitingConfirmation('awaiting_confirmation'),

  /// 弹给用户确认，用户取消了。
  dismissed('dismissed'),

  /// 标题、类型、年份或季号都没通过严格校验 / 资料源查无。
  notFound('not_found'),

  /// 资料源不可用（网络 / 凭据 / 限流 / 封禁）。
  providerUnavailable('provider_unavailable'),

  /// 刮这一条时出错（异常 / 没有结论的失败）。
  error('error');

  const PendingIdentityCause(this.wire);

  final String wire;

  static PendingIdentityCause? fromWire(String value) {
    for (final PendingIdentityCause cause in values) {
      if (cause.wire == value) return cause;
    }
    return null;
  }
}

/// 挂起时 AI 身份消解的结果。[wire] 是落库值。
enum PendingIdentityAiOutcome {
  /// 这条分支走不到 AI（哈希冲突、查无、源不可用、候选不可用、单个弱候选）。
  notAsked('not_asked'),

  /// 没有装配 AI 决策器（无头服务端等）。
  unavailable('unavailable'),

  /// 「作品识别」没有指派可用的 AI 提供商（视频与书 / 游戏共用这一项指派）。
  unassigned('unassigned'),

  /// AI 调用失败。
  failed('failed'),

  /// AI 认为没有候选成立，或置信度不到自动采用门槛。
  declined('declined'),

  /// AI 采用了一个候选（条目随即被认出，不会留在待确认里）。
  accepted('accepted');

  const PendingIdentityAiOutcome(this.wire);

  final String wire;

  static PendingIdentityAiOutcome? fromWire(String value) {
    for (final PendingIdentityAiOutcome outcome in values) {
      if (outcome.wire == value) return outcome;
    }
    return null;
  }
}

/// 书 / 漫画忽略域的偏好键（见 [PendingIdentityIgnoreDomain.book]）。
const String kBookScrapeIgnoredPrefKey = 'book_scrape_ignored_works';

/// 游戏忽略域的偏好键（见 [PendingIdentityIgnoreDomain.game]）。
const String kGameScrapeIgnoredPrefKey = 'game_scrape_ignored_works';

/// 忽略记在哪一个域里（一个域一个偏好键）。书与漫画同一个域：它们是库管家同一个
/// 刮削阶段（`scrape.books`）的单元，键空间相同。
enum PendingIdentityIgnoreDomain {
  video('video_scrape_ignored_works'),
  book(kBookScrapeIgnoredPrefKey),
  game(kGameScrapeIgnoredPrefKey);

  const PendingIdentityIgnoreDomain(this.prefKey);

  /// 偏好键（值：JSON 字符串数组，元素是条目稳定键）。视频的键是既有的
  /// `video_scrape_ignored_works`，不改名。三个键里都是本机自增 id / 本机 uid
  /// 拼的键，属于设备本地状态（app 侧 `SyncRepository.deviceLocalPrefKeys`）。
  final String prefKey;
}

/// 条目属于哪种媒体（决定在哪个库页的提醒条上计数）。
enum PendingIdentityMediaKind {
  video('video', PendingIdentityIgnoreDomain.video),
  book('book', PendingIdentityIgnoreDomain.book),
  manga('manga', PendingIdentityIgnoreDomain.book),
  game('game', PendingIdentityIgnoreDomain.game);

  const PendingIdentityMediaKind(this.wire, this.ignoreDomain);

  final String wire;
  final PendingIdentityIgnoreDomain ignoreDomain;
}

/// 一条还没认出来的条目。
class PendingIdentityEntry {
  const PendingIdentityEntry({
    required this.kind,
    required this.key,
    required this.title,
    this.cause,
    this.aiOutcome,
    this.candidateCount = 0,
    this.lastAttemptAt,
    this.detail,
    this.memberKeys = const <String>[],
  });

  final PendingIdentityMediaKind kind;

  /// 稳定键（忽略、重试、列表 key 都按它对号）：视频 = 作品 stableKey
  /// （`collection:<id>` / `book:<uid>`），书 = 库管家刮削单元 id
  /// （`collection:<id>` / `book:<bookKey>`），游戏 = `game:<id>`。
  final String key;

  final String title;

  /// 最近一次尝试留下的原因；近期记录里没有（从没试过 / 记录已滚出窗口）为 null。
  final PendingIdentityCause? cause;

  /// 最近一次尝试的 AI 结论；没记录为 null。
  final PendingIdentityAiOutcome? aiOutcome;

  /// 最近一次尝试的候选数（没记录为 0）。
  final int candidateCount;

  /// 最近一次尝试的时刻；没记录为 null。
  final DateTime? lastAttemptAt;

  /// 补充原文（视频挂起标记里的 resolver reason 等），可空。
  final String? detail;

  /// 条目包含的成员键：书 = 各卷 bookKey（系列单元有多卷），游戏 = 游戏 id，视频为空
  /// （视频的动作直接用 [key] 对应的作品单元）。
  final List<String> memberKeys;
}

/// 一种媒体的待确认 + 已忽略两份清单。
class PendingIdentityListing {
  const PendingIdentityListing({
    this.pending = const <PendingIdentityEntry>[],
    this.ignored = const <PendingIdentityEntry>[],
  });

  static const PendingIdentityListing empty = PendingIdentityListing();

  final List<PendingIdentityEntry> pending;
  final List<PendingIdentityEntry> ignored;

  /// 只留 [kind] 的条目（书与漫画共用一个数据源，各自的书架只数自己的）。
  PendingIdentityListing only(PendingIdentityMediaKind kind) =>
      PendingIdentityListing(
        pending: <PendingIdentityEntry>[
          for (final PendingIdentityEntry e in pending)
            if (e.kind == kind) e,
        ],
        ignored: <PendingIdentityEntry>[
          for (final PendingIdentityEntry e in ignored)
            if (e.kind == kind) e,
        ],
      );
}

/// 一种媒体的待确认身份数据源。
abstract interface class PendingIdentitySource {
  /// 当前待确认 + 已忽略（只读，不发起任何刮削）。
  Future<PendingIdentityListing> load();

  /// 忽略（[ignored] = true）或撤销忽略这些条目（按 [PendingIdentityEntry.key]）。
  /// 永久生效直到撤销；忽略的条目不计入提醒条，各处都不再列为待确认。
  Future<void> setIgnored(Iterable<String> keys, {required bool ignored});
}

// ─────────────────────────────────────────────────────────────────────────
// 忽略的持久化
// ─────────────────────────────────────────────────────────────────────────

/// 读 [domain] 已忽略的键集合。值缺失 / 损坏一律当作空集（= 不忽略任何条目：
/// 宁可多提醒，也不静默吞掉待确认条目）。
Future<Set<String>> loadPendingIdentityIgnored(
  FushiDatabase database,
  PendingIdentityIgnoreDomain domain,
) async => decodePendingIdentityIgnored(await database.getPref(domain.prefKey));

/// [loadPendingIdentityIgnored] 的纯解码部分。
Set<String> decodePendingIdentityIgnored(String? raw) {
  if (raw == null || raw.isEmpty) return <String>{};
  try {
    final Object? decoded = jsonDecode(raw);
    if (decoded is! List<Object?>) return <String>{};
    return <String>{
      for (final Object? key in decoded)
        if (key is String && key.isNotEmpty) key,
    };
  } on FormatException {
    return <String>{};
  }
}

/// 把 [keys] 在 [domain] 里标为忽略（[ignored] = true）或撤销忽略。读改写在一个
/// 事务里，并发的两次切换不会互相覆盖。集合变空时删键，不留空数组。
Future<void> setPendingIdentityIgnored(
  FushiDatabase database,
  PendingIdentityIgnoreDomain domain,
  Iterable<String> keys, {
  required bool ignored,
}) => database.transaction(() async {
  final Set<String> current = await loadPendingIdentityIgnored(
    database,
    domain,
  );
  final int before = current.length;
  final List<String> changed = keys
      .where((String key) => key.isNotEmpty)
      .toList(growable: false);
  if (ignored) {
    current.addAll(changed);
  } else {
    current.removeAll(changed);
  }
  if (current.length == before) return;
  if (current.isEmpty) {
    await database.deletePref(domain.prefKey);
    return;
  }
  final List<String> sorted = current.toList()..sort();
  await database.setPref(domain.prefKey, jsonEncode(sorted));
});
