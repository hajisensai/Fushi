// 书架增量同步：本机书架（local_shelf.dart）→ 服务端 POST /v1/shelf。
//
// 状态模型（[LeaderboardSyncState]，app 按 Profile 落本机文件）：
// - entries：localKey → 上次成功上报时的内容 hash 与服务端落到的 workId；
// - daily：上次成功上报的每日字数；
// - shelfCount：上次响应里服务端的书架行数（null = 从没成功同步过）；
// - coverVotes：workId → 本账户上次给该作品投的封面（来源 + 哈希），见下面第 7 步。
//
// 服务端按 (账户, 作品) 覆盖写，同一批里映射到同一作品的多条由服务端合并（读完取最晚、
// 字数 / 时长相加，shelf.js resolveUpload）。所以客户端**不预合并**，每条带自己的 refs
// 原样上报，只保证一件事：**映射到同一 workId 的条目总在同一批里一起发**——否则后一批
// 只带部分成员，会把前一批合并出的整行覆盖掉。
//
// 一次同步：
// 1. 从没同步过，或 `me().shelfCount` 与 state 里不同 workId 的个数对不上 → reset 全量；
// 2. 本地书架先按服务端上限 8000 截断（读完优先、其次最近活动），超出的不上传；
// 3. 非 reset：state 里某作品任一成员变了 / 本地没了，该作品在本地的全部成员整组重发；
//    从没上报过的新条目各自单发，排在所有已同步条目之后、单独成批，且不带 daily——书架
//    满（413 `shelf_full`）时只丢新条目，已同步条目的更新与每日字数不受连累；
// 4. 所有成员都已从本地消失的作品在 put 之前先 remove（腾出书架行数）；
// 5. put 响应回来后若发现某作品的成员分散在不同批里（新条目落到了已有作品上、reset 分批
//    劈开了同一作品），把这些作品整组补发一轮；仍劈开的记空 hash，下次同步整组重传；
// 6. 其余孤儿 workId（put 后改落别处的）最后 remove；
// 7. 封面投票（服务端按人数选封面，services/leaderboard/src/cover_votes.js）：每部作品本账户
//    一票。条目带 coverUrl → 投该 URL（白名单外的 URL 退回本地封面）；否则用本地封面生成缩略图、
//    算 dHash（cover_hash.dart）投票，服务端命中相近候选就只记票，没命中再带字节上传。
//    coverVotes 记着上次投的来源（URL / 本地封面文件指纹）：来源没变就不再投；本地更正了刮削、
//    封面文件变了 → 重新投，服务端随之移票。遇到第一个 429 / 5xx / 网络错误立即停止本轮，
//    剩下的下次再投。封面问题不算同步失败（[ShelfSyncOutcome.coverError]）。
//    **确认票**（cover_compare.dart）：按哈希命中已有候选时不直接投，先 `check` 拿到候选缩略图，
//    在后台 isolate 里与本地缩略图强比对——同一张图才投确认票（只有确认票计入服务端的替换门槛），
//    不是就报「不符」并去看下一个候选 / 上传自己的图另立候选。同一作品同一候选（同一本地封面）
//    只比一次，结论存在 coverChecks 里；下载 / 网络失败不投、不记账，下次重试。
// 中途失败抛 [LeaderboardSyncException]，携带已推进的 state：调用方存下它，下次从断点续。
//
// 另外两条规则：
// - 单批遇 409 `conflict`（同账户并发写入，服务端已整体回滚）原样重发，最多 3 次；
// - 每账户只有一台「上传设备」：本机不是时抛 [LeaderboardUploadOwnedElsewhere]，用户
//   选择接管后以 `claim: true`（强制 reset）全量同步。

import 'dart:typed_data';

import 'package:fushi_engine/leaderboard/cover_compare.dart';
import 'package:fushi_engine/leaderboard/cover_hash.dart';
import 'package:fushi_engine/leaderboard/leaderboard_client.dart';
import 'package:fushi_engine/leaderboard/leaderboard_models.dart';
import 'package:fushi_engine/leaderboard/local_shelf.dart';

/// 一条已同步条目。[hash] 为空串 = 需要整组重传。
class SyncedEntry {
  const SyncedEntry({required this.hash, required this.workId});

  factory SyncedEntry.fromJson(Map<String, dynamic> j) =>
      SyncedEntry(hash: j['h'] as String? ?? '', workId: j['w'] as String);

  final String hash;
  final String workId;

  Map<String, dynamic> toJson() => <String, dynamic>{'h': hash, 'w': workId};

  @override
  bool operator ==(Object other) =>
      other is SyncedEntry && other.hash == hash && other.workId == workId;

  @override
  int get hashCode => Object.hash(hash, workId);
}

/// 本账户给一部作品投过的封面。[source] = `u:<url>`（投的白名单 URL）、`f:<本地封面指纹>`，
/// 或 `-`（没有可投的封面）；[hash] = 投的缩略图 dHash（URL 票 / 没投成的本地封面为 null）；
/// [rejectedUrl] = 服务端判为白名单外的 coverUrl（同一个 URL 不再重试，直接用本地封面）。
class CoverVoteRecord {
  const CoverVoteRecord({
    required this.source,
    this.hash,
    this.rejectedUrl,
    this.confirmed = false,
  });

  factory CoverVoteRecord.fromJson(Map<String, dynamic> j) => CoverVoteRecord(
    source: j['s'] as String,
    hash: j['h'] as String?,
    rejectedUrl: j['x'] as String?,
    confirmed: j['c'] == true,
  );

  final String source;
  final String? hash;
  final String? rejectedUrl;

  /// 缩略图票是确认票（本机比对通过 / 自己上传建的候选）。旧版本记下的缩略图票没有这一位：
  /// 下次同步补一次本机比对（服务端的替换门槛只数确认票）。
  final bool confirmed;

  /// 这条记录已经不用再处理：不是缩略图票（URL / 没投成），或缩略图票已确认。
  bool get settled => hash == null || confirmed;

  Map<String, dynamic> toJson() => <String, dynamic>{
    's': source,
    if (hash != null) 'h': hash,
    if (rejectedUrl != null) 'x': rejectedUrl,
    if (confirmed) 'c': true,
  };

  @override
  bool operator ==(Object other) =>
      other is CoverVoteRecord &&
      other.source == source &&
      other.hash == hash &&
      other.rejectedUrl == rejectedUrl &&
      other.confirmed == confirmed;

  @override
  int get hashCode => Object.hash(source, hash, rejectedUrl, confirmed);
}

class LeaderboardSyncState {
  const LeaderboardSyncState({
    this.entries = const <String, SyncedEntry>{},
    this.daily = const <String, int>{},
    this.shelfCount,
    this.coverVotes = const <String, CoverVoteRecord>{},
    this.coverChecks = const <String, bool>{},
  });

  static const LeaderboardSyncState empty = LeaderboardSyncState();

  /// 坏数据（形状不对）抛 [FormatException]，调用方按「没同步过」处理即可。
  factory LeaderboardSyncState.fromJson(Map<String, dynamic> j) {
    try {
      final Map<String, dynamic> entries =
          (j['entries'] as Map<Object?, Object?>? ?? const <Object?, Object?>{})
              .cast<String, dynamic>();
      final Map<String, dynamic> daily =
          (j['daily'] as Map<Object?, Object?>? ?? const <Object?, Object?>{})
              .cast<String, dynamic>();
      // 旧版本的 `covers`（待补封面的 localKey）不再使用：新版按 coverVotes 判断要不要投票，
      // 没有记录的作品都会补投一次。
      final Map<String, dynamic> votes =
          (j['coverVotes'] as Map<Object?, Object?>? ??
                  const <Object?, Object?>{})
              .cast<String, dynamic>();
      final Map<String, dynamic> checks =
          (j['coverChecks'] as Map<Object?, Object?>? ??
                  const <Object?, Object?>{})
              .cast<String, dynamic>();
      return LeaderboardSyncState(
        entries: Map<String, SyncedEntry>.unmodifiable(<String, SyncedEntry>{
          for (final MapEntry<String, dynamic> e in entries.entries)
            e.key: SyncedEntry.fromJson(
              (e.value as Map<Object?, Object?>).cast<String, dynamic>(),
            ),
        }),
        daily: Map<String, int>.unmodifiable(<String, int>{
          for (final MapEntry<String, dynamic> e in daily.entries)
            e.key: (e.value as num).toInt(),
        }),
        shelfCount: (j['shelfCount'] as num?)?.toInt(),
        coverVotes:
            Map<String, CoverVoteRecord>.unmodifiable(<String, CoverVoteRecord>{
              for (final MapEntry<String, dynamic> e in votes.entries)
                e.key: CoverVoteRecord.fromJson(
                  (e.value as Map<Object?, Object?>).cast<String, dynamic>(),
                ),
            }),
        coverChecks: Map<String, bool>.unmodifiable(<String, bool>{
          for (final MapEntry<String, dynamic> e in checks.entries)
            e.key: e.value as bool,
        }),
      );
    } on TypeError catch (e) {
      throw FormatException('bad leaderboard sync state: $e');
    }
  }

  final Map<String, SyncedEntry> entries;
  final Map<String, int> daily;
  final int? shelfCount;

  /// workId → 本账户上次给它投的封面。
  final Map<String, CoverVoteRecord> coverVotes;

  /// 本机比对的结论缓存：`<workId>|<候选 id>|<本地封面来源>` → 是不是同一张图。投票还没落地（确认 /
  /// 不符请求失败）时下次同步直接用它，不再下载、解码一遍。该作品的投票落地后清掉。
  final Map<String, bool> coverChecks;

  /// 从没成功同步过。
  bool get neverSynced => shelfCount == null;

  /// state 认为服务端书架上有的 workId（多个 localKey 可能映射到同一个）。
  Set<String> get workIds =>
      entries.values.map((SyncedEntry e) => e.workId).toSet();

  LeaderboardSyncState copyWith({
    Map<String, SyncedEntry>? entries,
    Map<String, int>? daily,
    int? shelfCount,
    Map<String, CoverVoteRecord>? coverVotes,
    Map<String, bool>? coverChecks,
  }) => LeaderboardSyncState(
    entries: entries == null
        ? this.entries
        : Map<String, SyncedEntry>.unmodifiable(entries),
    daily: daily == null ? this.daily : Map<String, int>.unmodifiable(daily),
    shelfCount: shelfCount ?? this.shelfCount,
    coverVotes: coverVotes == null
        ? this.coverVotes
        : Map<String, CoverVoteRecord>.unmodifiable(coverVotes),
    coverChecks: coverChecks == null
        ? this.coverChecks
        : Map<String, bool>.unmodifiable(coverChecks),
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'entries': <String, dynamic>{
      for (final MapEntry<String, SyncedEntry> e in entries.entries)
        e.key: e.value.toJson(),
    },
    'daily': daily,
    if (shelfCount != null) 'shelfCount': shelfCount,
    if (coverVotes.isNotEmpty)
      'coverVotes': <String, dynamic>{
        for (final MapEntry<String, CoverVoteRecord> e in coverVotes.entries)
          e.key: e.value.toJson(),
      },
    if (coverChecks.isNotEmpty) 'coverChecks': coverChecks,
  };
}

/// 一次上报请求的内容。[put] 里第 i 条对应响应 `works[].i == i`。
class ShelfSyncBatch {
  const ShelfSyncBatch({
    required this.reset,
    required this.put,
    required this.daily,
    this.newEntriesOnly = false,
  });

  final bool reset;
  final List<LocalShelfEntry> put;
  final List<DailyCharsUpload> daily;

  /// 本批只有从没上报过的新条目（不带 daily）：遇 413 `shelf_full` 时整批放弃而不报错。
  final bool newEntriesOnly;
}

class ShelfSyncPlan {
  const ShelfSyncPlan({
    required this.reset,
    required this.entries,
    required this.batches,
    required this.droppedLocalKeys,
    required this.preRemoveWorkIds,
    required this.droppedForShelfLimit,
  });

  final bool reset;

  /// 截断到服务端上限后参与同步的本地条目（保持本地顺序）。
  final List<LocalShelfEntry> entries;

  /// put + daily 批次（reset 时第一批带 reset；无事可做且不 reset 时为空）。
  final List<ShelfSyncBatch> batches;

  /// state 里有、这次不再上报的 localKey（本地没了或被截断；put 完成后从 state 去掉）。
  final List<String> droppedLocalKeys;

  /// 全部成员都已不再上报的作品：put 之前先删，腾出书架行数。
  final List<String> preRemoveWorkIds;

  /// 超出服务端书架上限、本次不上传的本地条目数。
  final int droppedForShelfLimit;
}

/// 读完的在前；同组内越近越靠前（读完时刻 / 最后活动取较晚者）；最后按 localKey 定序。
int _shelfPriority(LocalShelfEntry a, LocalShelfEntry b) {
  if (a.upload.finished != b.upload.finished) {
    return a.upload.finished ? -1 : 1;
  }
  final int byRecency = _recency(b).compareTo(_recency(a));
  return byRecency != 0 ? byRecency : a.localKey.compareTo(b.localKey);
}

int _recency(LocalShelfEntry e) {
  final int finished = e.upload.finishedAt ?? 0;
  final int active = e.lastActiveAt ?? 0;
  return finished > active ? finished : active;
}

/// 纯函数：本地书架截到服务端上限 [max] 条（读完的优先、其次最近活动），返回保留的
/// 条目（保持原顺序）与丢掉的条数。
(List<LocalShelfEntry>, int) capShelfEntries(
  List<LocalShelfEntry> entries, {
  int max = kLeaderboardMaxShelfRows,
}) {
  if (entries.length <= max) return (entries, 0);
  final Set<String> keep =
      (List<LocalShelfEntry>.of(entries)..sort(_shelfPriority))
          .take(max)
          .map((LocalShelfEntry e) => e.localKey)
          .toSet();
  return (
    List<LocalShelfEntry>.unmodifiable(
      entries.where((LocalShelfEntry e) => keep.contains(e.localKey)),
    ),
    entries.length - max,
  );
}

/// 纯函数：把条目组装进批，每组整组落在同一批（单组超过 [size] 时只能拆开）。
List<List<LocalShelfEntry>> packShelfGroups(
  List<List<LocalShelfEntry>> groups,
  int size,
) {
  final List<List<LocalShelfEntry>> out = <List<LocalShelfEntry>>[];
  List<LocalShelfEntry> current = <LocalShelfEntry>[];
  for (final List<LocalShelfEntry> group in groups) {
    if (current.isNotEmpty && current.length + group.length > size) {
      out.add(current);
      current = <LocalShelfEntry>[];
    }
    for (final LocalShelfEntry e in group) {
      if (current.length == size) {
        out.add(current);
        current = <LocalShelfEntry>[];
      }
      current.add(e);
    }
  }
  if (current.isNotEmpty) out.add(current);
  return <List<LocalShelfEntry>>[
    for (final List<LocalShelfEntry> b in out)
      List<LocalShelfEntry>.unmodifiable(b),
  ];
}

/// 纯函数：由本机书架与上次状态算出要上报的批次（规则见文件头 2–4）。
///
/// daily 只发变了的日期；state 里有、本地没了的日期发 0（早于 [LocalShelf.dailyFrom]
/// 的除外——服务端只收最近 3650 天，过期日期直接从 state 里忘掉）。
ShelfSyncPlan planShelfSync(
  LocalShelf local,
  LeaderboardSyncState state, {
  required bool reset,
  int maxShelfRows = kLeaderboardMaxShelfRows,
}) {
  final (List<LocalShelfEntry> kept, int overflow) = capShelfEntries(
    local.entries,
    max: maxShelfRows,
  );
  final List<DailyCharsUpload> daily = _dailyChanges(local, state, reset);
  if (reset) {
    return ShelfSyncPlan(
      reset: true,
      entries: kept,
      batches: _assemble(
        groups: <List<LocalShelfEntry>>[
          for (final LocalShelfEntry e in kept) <LocalShelfEntry>[e],
        ],
        fresh: const <LocalShelfEntry>[],
        daily: daily,
        reset: true,
      ),
      droppedLocalKeys: const <String>[],
      preRemoveWorkIds: const <String>[],
      droppedForShelfLimit: overflow,
    );
  }
  final Map<String, LocalShelfEntry> byKey = <String, LocalShelfEntry>{
    for (final LocalShelfEntry e in kept) e.localKey: e,
  };
  final Set<String> dirtyWorks = <String>{};
  final Map<String, List<String>> membersOf = <String, List<String>>{};
  for (final MapEntry<String, SyncedEntry> s in state.entries.entries) {
    (membersOf[s.value.workId] ??= <String>[]).add(s.key);
    final LocalShelfEntry? e = byKey[s.key];
    if (e == null || e.upload.contentHash() != s.value.hash) {
      dirtyWorks.add(s.value.workId);
    }
  }
  final Map<String, List<LocalShelfEntry>> groupOf =
      <String, List<LocalShelfEntry>>{};
  final List<List<LocalShelfEntry>> groups = <List<LocalShelfEntry>>[];
  final List<LocalShelfEntry> fresh = <LocalShelfEntry>[];
  for (final LocalShelfEntry e in kept) {
    final String? workId = state.entries[e.localKey]?.workId;
    if (workId == null) {
      fresh.add(e);
    } else if (dirtyWorks.contains(workId)) {
      final List<LocalShelfEntry>? g = groupOf[workId];
      if (g != null) {
        g.add(e);
      } else {
        groups.add(groupOf[workId] = <LocalShelfEntry>[e]);
      }
    }
  }
  return ShelfSyncPlan(
    reset: false,
    entries: kept,
    batches: _assemble(
      groups: groups,
      fresh: fresh,
      daily: daily,
      reset: false,
    ),
    droppedLocalKeys: List<String>.unmodifiable(
      state.entries.keys.where((String k) => !byKey.containsKey(k)).toList()
        ..sort(),
    ),
    preRemoveWorkIds: List<String>.unmodifiable(
      membersOf.entries
          .where(
            (MapEntry<String, List<String>> m) =>
                m.value.every((String k) => !byKey.containsKey(k)),
          )
          .map((MapEntry<String, List<String>> m) => m.key)
          .toList()
        ..sort(),
    ),
    droppedForShelfLimit: overflow,
  );
}

List<DailyCharsUpload> _dailyChanges(
  LocalShelf local,
  LeaderboardSyncState state,
  bool reset,
) {
  final Map<String, int> localDaily = <String, int>{
    for (final DailyCharsUpload d in local.daily) d.date: d.chars,
  };
  final String? dailyFrom = local.dailyFrom;
  return <DailyCharsUpload>[
    for (final DailyCharsUpload d in local.daily)
      if (reset || state.daily[d.date] != d.chars) d,
    if (!reset)
      for (final String date in state.daily.keys.toList()..sort())
        if (!localDaily.containsKey(date) &&
            state.daily[date] != 0 &&
            (dailyFrom == null || date.compareTo(dailyFrom) >= 0))
          DailyCharsUpload(date: date, chars: 0),
  ];
}

/// 已同步作品的组在前（daily 跟着它们走，多出来的 daily 单独成批），新条目最后单独成批。
List<ShelfSyncBatch> _assemble({
  required List<List<LocalShelfEntry>> groups,
  required List<LocalShelfEntry> fresh,
  required List<DailyCharsUpload> daily,
  required bool reset,
}) {
  final List<List<LocalShelfEntry>> known = packShelfGroups(
    groups,
    kLeaderboardMaxPut,
  );
  final List<List<DailyCharsUpload>> dailyChunks = _chunks(
    daily,
    kLeaderboardMaxDaily,
  );
  final int head = known.length > dailyChunks.length
      ? known.length
      : dailyChunks.length;
  final List<ShelfSyncBatch> batches = <ShelfSyncBatch>[
    for (int i = 0; i < head; i++)
      ShelfSyncBatch(
        reset: reset && i == 0,
        put: i < known.length ? known[i] : const <LocalShelfEntry>[],
        daily: i < dailyChunks.length
            ? dailyChunks[i]
            : const <DailyCharsUpload>[],
      ),
    for (final List<LocalShelfEntry> put in _chunks(fresh, kLeaderboardMaxPut))
      ShelfSyncBatch(
        reset: false,
        put: put,
        daily: const <DailyCharsUpload>[],
        newEntriesOnly: true,
      ),
  ];
  if (reset && batches.isEmpty) {
    // 本地为空也要发一个空的 reset 批（清空服务端）。
    return const <ShelfSyncBatch>[
      ShelfSyncBatch(
        reset: true,
        put: <LocalShelfEntry>[],
        daily: <DailyCharsUpload>[],
      ),
    ];
  }
  return List<ShelfSyncBatch>.unmodifiable(batches);
}

List<List<T>> _chunks<T>(List<T> all, int size) => <List<T>>[
  for (int i = 0; i < all.length; i += size)
    List<T>.unmodifiable(
      all.sublist(i, i + size > all.length ? all.length : i + size),
    ),
];

/// 纯函数：[before] 里出现过、[after] 里已无任何 localKey 映射的 workId（升序）。
List<String> orphanedWorkIds(
  Map<String, SyncedEntry> before,
  Map<String, SyncedEntry> after,
) {
  final Set<String> alive = after.values
      .map((SyncedEntry e) => e.workId)
      .toSet();
  return before.values
      .map((SyncedEntry e) => e.workId)
      .toSet()
      .where((String w) => !alive.contains(w))
      .toList()
    ..sort();
}

/// 同步中途失败。[partialState] 是已成功推进到的状态（调用方应落盘，下次从这里续）；
/// [error] / [stackTrace] 是原始失败（429 / 503 / 网络错误等都走这里）。
/// [anyBatchAccepted] = 失败前至少有一批书架请求被服务端接受（本机仍是上传设备）。
class LeaderboardSyncException implements Exception {
  const LeaderboardSyncException(
    this.partialState,
    this.error,
    this.stackTrace, {
    this.anyBatchAccepted = false,
    this.droppedForShelfLimit = 0,
  });

  final LeaderboardSyncState partialState;
  final Object error;
  final StackTrace stackTrace;
  final bool anyBatchAccepted;
  final int droppedForShelfLimit;

  @override
  String toString() => 'LeaderboardSyncException($error)';
}

/// 一次成功同步的结果。
class ShelfSyncOutcome {
  const ShelfSyncOutcome({
    required this.state,
    this.droppedForShelfLimit = 0,
    this.coverError,
    this.coverStackTrace,
  });

  final LeaderboardSyncState state;

  /// 超出服务端书架上限、没有上传的本地条目数（本地截断 + 服务端判满放弃的新条目）。
  final int droppedForShelfLimit;

  /// 封面投票遇到的第一个错误（不影响书架同步结果；没投成的下次再投）。
  final Object? coverError;
  final StackTrace? coverStackTrace;
}

/// 本账户的「上传设备」是另一台设备（服务端 409 `upload_owned_by_other_device`，或
/// `me().uploadDevice == false`）。不重试、不推进也不作废本机进度：用户在本机选择
/// 「由本设备接管上传」后以 `syncShelf(claim: true)` 全量接管。
class LeaderboardUploadOwnedElsewhere implements Exception {
  const LeaderboardUploadOwnedElsewhere();

  @override
  String toString() => 'LeaderboardUploadOwnedElsewhere';
}

/// 同一账户另一批并发写入改了书架版本（409 `conflict`，本批已整体回滚）时，单批最多
/// 重发的次数。
const int kLeaderboardConflictRetries = 3;

/// put 后发现同一作品的成员分散在不同批里时，整组补发的最多轮数。
const int kLeaderboardRepairRounds = 2;

bool _isOwnedElsewhere(Object e) =>
    e is LeaderboardApiException &&
    e.status == 409 &&
    e.code == 'upload_owned_by_other_device';

bool _isConflict(Object e) =>
    e is LeaderboardApiException && e.status == 409 && e.code == 'conflict';

bool _isShelfFull(Object e) =>
    e is LeaderboardApiException && e.status == 413 && e.code == 'shelf_full';

/// 封面投票该不该就此停下：429 / 5xx、404（服务端还是不认投票接口的旧版本），或没拿到响应
/// （网络错误 / 超时）。停下的不记账，下次再投。
bool _stopsCoverRound(Object e) => e is LeaderboardApiException
    ? e.status == 429 || e.status >= 500 || e.status == 404
    : true;

bool _isCandidateGone(Object e) =>
    e is _CoverRoundsExhausted ||
    (e is LeaderboardApiException &&
        e.status == 409 &&
        e.code == 'cover_candidate_gone');

bool _isBadCoverUrl(Object e) =>
    e is LeaderboardApiException &&
    e.status == 400 &&
    e.code == 'bad_cover_url';

/// 把 [local] 同步到服务端（规则见文件头）。
///
/// [claim] = 由本设备接管上传：强制 reset 全量，第一批带 `claim: true`。
/// [coverThumb]：取条目的缩略图字节（返回 null = 本地没有封面）；不给则不处理封面。
/// [coverFingerprint]：本地封面的指纹（默认 [localCoverFingerprint]：路径 + 大小 + 修改时刻），
/// 指纹没变就不重新生成缩略图。[coverHash]：缩略图的 dHash（默认在当前 isolate 里跑
/// [coverDHash]；app 传后台 isolate 版本）。[coverCompare]：本地缩略图与候选缩略图的强比对
/// （默认 [compareCoverBytesInBackground]；返回 null = 本地图解不开）。
///
/// 上传设备不是本机时抛 [LeaderboardUploadOwnedElsewhere]；其余失败抛
/// [LeaderboardSyncException]（带已推进的状态）。
Future<ShelfSyncOutcome> syncShelf(
  LeaderboardClient client,
  LocalShelf local,
  LeaderboardSyncState state, {
  bool claim = false,
  Future<Uint8List?> Function(LocalShelfEntry entry)? coverThumb,
  Future<String?> Function(LocalShelfEntry entry)? coverFingerprint,
  Future<String?> Function(Uint8List thumb)? coverHash,
  Future<CoverSimilarity?> Function(Uint8List local, Uint8List remote)?
  coverCompare,
}) => _ShelfSyncRun(
  client,
  local,
  state,
  claim,
  coverThumb,
  coverFingerprint ?? localCoverFingerprint,
  coverHash ?? _hashHere,
  coverCompare ?? compareCoverBytesInBackground,
).run();

/// 一部作品的确认票流程里最多看几个候选（每看一个不符就换下一个）；超过就留待下次同步。
const int kCoverConfirmMaxCandidates = 4;

Future<String?> _hashHere(Uint8List thumb) async => coverDHash(thumb);

class _ShelfSyncRun {
  _ShelfSyncRun(
    this.client,
    this.local,
    this.current,
    this.claim,
    this.coverThumb,
    this.coverFingerprint,
    this.coverHash,
    this.coverCompare,
  );

  final LeaderboardClient client;
  final LocalShelf local;
  final bool claim;
  final Future<Uint8List?> Function(LocalShelfEntry entry)? coverThumb;
  final Future<String?> Function(LocalShelfEntry entry) coverFingerprint;
  final Future<String?> Function(Uint8List thumb) coverHash;
  final Future<CoverSimilarity?> Function(Uint8List local, Uint8List remote)
  coverCompare;

  /// 本次同步发现服务端还不认识确认票协议（响应里没有 `confirmed`）：其余作品不再为补确认重投。
  bool _legacyCoverServer = false;

  /// 本机比对结论缓存（见 [LeaderboardSyncState.coverChecks]），本轮在它上面增删。
  Map<String, bool> _checks = <String, bool>{};

  LeaderboardSyncState current;
  bool accepted = false;
  int droppedForShelfLimit = 0;

  /// 本次参与同步的本地条目。
  Map<String, LocalShelfEntry> byKey = <String, LocalShelfEntry>{};

  /// localKey → 本次同步里它随哪一批（序号）发出。
  final Map<String, int> sentIn = <String, int>{};
  final Map<String, String> _hashes = <String, String>{};
  int _batchSeq = 0;

  String _hashOf(LocalShelfEntry e) =>
      _hashes[e.localKey] ??= e.upload.contentHash();

  Future<ShelfSyncOutcome> run() async {
    try {
      final ShelfSyncPlan plan = planShelfSync(
        local,
        current,
        reset: await _decideReset(),
      );
      droppedForShelfLimit = plan.droppedForShelfLimit;
      byKey = <String, LocalShelfEntry>{
        for (final LocalShelfEntry e in plan.entries) e.localKey: e,
      };
      final Map<String, SyncedEntry> before = current.entries;
      await _remove(plan.preRemoveWorkIds);
      await _putBatches(plan);
      await _repairSplits();
      if (!plan.reset) {
        await _removeOrphans(
          before,
          plan.droppedLocalKeys,
          plan.preRemoveWorkIds,
        );
      }
      _forgetExpiredDaily();
    } on LeaderboardUploadOwnedElsewhere {
      rethrow;
    } on Object catch (e, st) {
      if (_isOwnedElsewhere(e)) throw const LeaderboardUploadOwnedElsewhere();
      throw LeaderboardSyncException(
        current,
        e,
        st,
        anyBatchAccepted: accepted,
        droppedForShelfLimit: droppedForShelfLimit,
      );
    }
    final (Object? coverError, StackTrace? coverStack) = await _voteCovers();
    return ShelfSyncOutcome(
      state: current,
      droppedForShelfLimit: droppedForShelfLimit,
      coverError: coverError,
      coverStackTrace: coverStack,
    );
  }

  Future<bool> _decideReset() async {
    if (claim || current.neverSynced) return true;
    final LeaderboardSelf self = await client.me();
    if (self.uploadDevice == false) {
      throw const LeaderboardUploadOwnedElsewhere();
    }
    final int? serverCount = self.shelfCount;
    return serverCount != null && serverCount != current.workIds.length;
  }

  /// 发一批；409 `conflict`（服务端已整体回滚）原样重发，最多
  /// [kLeaderboardConflictRetries] 次。
  Future<ShelfUploadResult> _upload({
    bool reset = false,
    List<LocalShelfEntry> put = const <LocalShelfEntry>[],
    List<String> remove = const <String>[],
    List<DailyCharsUpload> daily = const <DailyCharsUpload>[],
  }) async {
    for (int attempt = 0; ; attempt++) {
      try {
        final ShelfUploadResult result = await client.uploadShelfDelta(
          reset: reset,
          claim: claim && reset,
          put: <ShelfEntryUpload>[
            for (final LocalShelfEntry e in put) e.upload,
          ],
          remove: remove,
          daily: daily,
        );
        accepted = true;
        return result;
      } on LeaderboardApiException catch (e) {
        if (!_isConflict(e) || attempt >= kLeaderboardConflictRetries) rethrow;
      }
    }
  }

  Future<void> _putBatches(ShelfSyncPlan plan) async {
    for (int i = 0; i < plan.batches.length; i++) {
      final ShelfSyncBatch batch = plan.batches[i];
      final ShelfUploadResult result;
      try {
        result = await _upload(
          reset: batch.reset,
          put: batch.put,
          daily: batch.daily,
        );
      } on LeaderboardApiException catch (e) {
        if (!batch.newEntriesOnly || !_isShelfFull(e)) rethrow;
        // 书架满：本批及其后都是从没上报过的新条目（排在最后），整体放弃。
        for (final ShelfSyncBatch rest in plan.batches.skip(i)) {
          droppedForShelfLimit += rest.put.length;
        }
        return;
      }
      _applyPut(batch, result);
    }
  }

  void _applyPut(ShelfSyncBatch batch, ShelfUploadResult result) {
    final int seq = _batchSeq++;
    final Map<String, SyncedEntry> entries = batch.reset
        ? <String, SyncedEntry>{}
        : Map<String, SyncedEntry>.of(current.entries);
    final Map<String, int> daily = batch.reset
        ? <String, int>{}
        : Map<String, int>.of(current.daily);
    final Map<String, CoverVoteRecord> votes = Map<String, CoverVoteRecord>.of(
      current.coverVotes,
    );
    // 服务端处理这批时顺带按条目的 coverUrl 投了票（coverVote == 'url'）：记成已投，
    // 省掉一次投票请求。挑的 URL 与服务端合并规则一致——同一作品里第一个带 coverUrl 的条目。
    final Map<String, String?> putVote = <String, String?>{};
    final Map<String, String> firstUrl = <String, String>{};
    for (final DailyCharsUpload d in batch.daily) {
      if (d.chars == 0) {
        daily.remove(d.date);
      } else {
        daily[d.date] = d.chars;
      }
    }
    for (final UploadedWork w in result.works) {
      if (w.i < 0 || w.i >= batch.put.length) continue;
      final LocalShelfEntry e = batch.put[w.i];
      entries[e.localKey] = SyncedEntry(hash: _hashOf(e), workId: w.workId);
      sentIn[e.localKey] = seq;
      putVote[w.workId] = w.coverVote;
      final String? url = e.upload.coverUrl;
      if (url != null) firstUrl.putIfAbsent(w.workId, () => url);
    }
    for (final MapEntry<String, String?> v in putVote.entries) {
      final String? url = firstUrl[v.key];
      if (v.value == 'url' && url != null) {
        votes[v.key] = CoverVoteRecord(source: 'u:$url');
      } else if (v.value != 'hash' &&
          (votes[v.key]?.source.startsWith('u:') ?? false)) {
        // 服务端说本账户在这部作品上已没有 URL 票：忘掉旧记录，交给投票轮重新判断。
        votes.remove(v.key);
      }
    }
    current = LeaderboardSyncState(
      entries: Map<String, SyncedEntry>.unmodifiable(entries),
      daily: Map<String, int>.unmodifiable(daily),
      shelfCount: result.shelfCount,
      coverVotes: Map<String, CoverVoteRecord>.unmodifiable(votes),
    );
  }

  /// 本次发过、但成员分散在不同批（或有成员没随它发）的作品，按本地顺序整组返回。
  List<List<LocalShelfEntry>> _splitGroups() {
    final Map<String, List<LocalShelfEntry>> members =
        <String, List<LocalShelfEntry>>{};
    for (final LocalShelfEntry e in byKey.values) {
      final String? workId = current.entries[e.localKey]?.workId;
      if (workId != null) (members[workId] ??= <LocalShelfEntry>[]).add(e);
    }
    return <List<LocalShelfEntry>>[
      for (final List<LocalShelfEntry> group in members.values)
        if (_isSplit(group)) group,
    ];
  }

  bool _isSplit(List<LocalShelfEntry> group) {
    final Set<int?> seqs = group
        .map((LocalShelfEntry e) => sentIn[e.localKey])
        .toSet();
    return seqs.length > 1 && seqs.any((int? s) => s != null);
  }

  Future<void> _repairSplits() async {
    for (int round = 0; round < kLeaderboardRepairRounds; round++) {
      final List<List<LocalShelfEntry>> groups = _splitGroups();
      if (groups.isEmpty) return;
      for (final List<LocalShelfEntry> put in packShelfGroups(
        groups,
        kLeaderboardMaxPut,
      )) {
        final ShelfSyncBatch batch = ShelfSyncBatch(
          reset: false,
          put: put,
          daily: const <DailyCharsUpload>[],
        );
        _applyPut(batch, await _upload(put: put));
      }
    }
    final List<List<LocalShelfEntry>> left = _splitGroups();
    if (left.isEmpty) return;
    // 仍劈开：记空 hash，下次同步按 state 整组重传。
    final Map<String, SyncedEntry> entries = Map<String, SyncedEntry>.of(
      current.entries,
    );
    for (final List<LocalShelfEntry> group in left) {
      for (final LocalShelfEntry e in group) {
        entries[e.localKey] = SyncedEntry(
          hash: '',
          workId: entries[e.localKey]!.workId,
        );
      }
    }
    current = current.copyWith(entries: entries);
  }

  Future<void> _remove(List<String> workIds) async {
    for (final List<String> chunk in _chunks(workIds, kLeaderboardMaxRemove)) {
      final ShelfUploadResult result = await _upload(remove: chunk);
      final Set<String> gone = chunk.toSet();
      final Map<String, SyncedEntry> entries = Map<String, SyncedEntry>.of(
        current.entries,
      )..removeWhere((String _, SyncedEntry s) => gone.contains(s.workId));
      current = current.copyWith(
        entries: entries,
        shelfCount: result.shelfCount,
      );
    }
  }

  Future<void> _removeOrphans(
    Map<String, SyncedEntry> before,
    List<String> droppedLocalKeys,
    List<String> alreadyRemoved,
  ) async {
    final Set<String> dropped = droppedLocalKeys.toSet();
    final Map<String, SyncedEntry> after = Map<String, SyncedEntry>.of(
      current.entries,
    )..removeWhere((String k, SyncedEntry _) => dropped.contains(k));
    final Set<String> removed = alreadyRemoved.toSet();
    await _remove(
      orphanedWorkIds(
        before,
        after,
      ).where((String w) => !removed.contains(w)).toList(),
    );
    current = current.copyWith(entries: after);
  }

  /// 过了服务端 3650 天窗口的日期：不再发 0（会被 400），直接从 state 里忘掉。
  void _forgetExpiredDaily() {
    final String? dailyFrom = local.dailyFrom;
    if (dailyFrom == null ||
        !current.daily.keys.any((String d) => d.compareTo(dailyFrom) < 0)) {
      return;
    }
    current = current.copyWith(
      daily: Map<String, int>.of(current.daily)
        ..removeWhere((String d, int _) => d.compareTo(dailyFrom) < 0),
    );
  }

  /// 封面投票轮（文件头第 7 步）。遇到第一个 429 / 5xx / 404 / 网络错误立即停止，剩下的留待
  /// 下次；409 `conflict`（并发回滚）跳过这部、不记账；其余失败（本地缩略图出错、其它 4xx）记下
  /// 来源，本地封面不变就不再重试。返回第一个错误。
  ///
  /// nsfw 条目**从不**提交本地封面（服务端虽会模糊 nsfw 封面，但宁可不传）；它们带的白名单 URL
  /// 照常投（上报时本来就带着）。
  Future<(Object?, StackTrace?)> _voteCovers() async {
    final Future<Uint8List?> Function(LocalShelfEntry entry)? thumb =
        coverThumb;
    final Set<String> live = current.workIds;
    final Map<String, CoverVoteRecord> votes = Map<String, CoverVoteRecord>.of(
      current.coverVotes,
    )..removeWhere((String w, CoverVoteRecord _) => !live.contains(w));
    _checks = Map<String, bool>.of(current.coverChecks)
      ..removeWhere((String k, bool _) => !live.contains(_checkWork(k)));
    if (thumb == null) {
      current = current.copyWith(coverVotes: votes, coverChecks: _checks);
      return (null, null);
    }
    final Map<String, List<LocalShelfEntry>> byWork =
        <String, List<LocalShelfEntry>>{};
    for (final LocalShelfEntry e in byKey.values) {
      final String? workId = current.entries[e.localKey]?.workId;
      if (workId != null) (byWork[workId] ??= <LocalShelfEntry>[]).add(e);
    }
    Object? error;
    StackTrace? stack;
    for (final MapEntry<String, List<LocalShelfEntry>> w in byWork.entries) {
      final _CoverAttempt attempt = _CoverAttempt();
      try {
        final CoverVoteRecord? done = await _voteCover(
          w.key,
          w.value,
          votes[w.key],
          thumb,
          attempt,
        );
        if (done != null) {
          votes[w.key] = done;
          _checks.removeWhere((String k, bool _) => _checkWork(k) == w.key);
        }
      } on Object catch (e, st) {
        error ??= e;
        stack ??= st;
        if (e is! _CoverThumbFailure && _stopsCoverRound(e)) break;
        // 409 `conflict`：与本账户的书架上报交错、服务端整批回滚（账户级 CAS）；409
        // `cover_candidate_gone`：要确认的候选刚被清理。都是临时失败——不记账，下次同步照常
        // 重投这部作品；本轮继续投后面的。
        if (_isConflict(e) || _isCandidateGone(e)) continue;
        final String? source = attempt.source;
        if (source != null) {
          votes[w.key] = CoverVoteRecord(
            source: source,
            rejectedUrl: attempt.rejectedUrl,
          );
        }
      }
    }
    current = current.copyWith(coverVotes: votes, coverChecks: _checks);
    return (error is _CoverThumbFailure ? error.error : error, stack);
  }

  static String _checkWork(String key) => key.substring(0, key.indexOf('|'));

  /// 给一部作品投票；返回新的投票记录（null = 不用投 / 没有可投的封面）。
  Future<CoverVoteRecord?> _voteCover(
    String workId,
    List<LocalShelfEntry> members,
    CoverVoteRecord? previous,
    Future<Uint8List?> Function(LocalShelfEntry entry) thumb,
    _CoverAttempt attempt,
  ) async {
    String? url;
    for (final LocalShelfEntry e in members) {
      url ??= e.upload.coverUrl;
    }
    String? rejected = url != null && previous?.rejectedUrl == url ? url : null;
    if (url != null && rejected == null) {
      final String source = 'u:$url';
      if (previous?.source == source) return null;
      attempt.source = source;
      try {
        await client.voteCover(workId, url: url);
        return CoverVoteRecord(source: source);
      } on LeaderboardApiException catch (e) {
        // 白名单外的图床：记下它，退回本地封面。
        if (!_isBadCoverUrl(e)) rethrow;
        rejected = url;
      }
    }
    attempt.rejectedUrl = rejected;
    for (final LocalShelfEntry e in members) {
      if (e.upload.nsfw) continue;
      final String? fingerprint = await coverFingerprint(e);
      if (fingerprint == null) continue;
      final String source = 'f:$fingerprint';
      if (previous?.source == source &&
          previous?.rejectedUrl == rejected &&
          (previous!.settled || _legacyCoverServer)) {
        return null;
      }
      attempt.source = source;
      final Uint8List? bytes;
      final String? hash;
      try {
        bytes = await thumb(e);
        hash = bytes == null || bytes.isEmpty ? null : await coverHash(bytes);
      } on Object catch (err) {
        throw _CoverThumbFailure(err);
      }
      if (bytes == null || hash == null) {
        return CoverVoteRecord(source: source, rejectedUrl: rejected);
      }
      // 文件被改动过但还是同一张图（距离在阈值内）、且服务端那票已确认：只更新指纹。
      final String? before = previous?.hash;
      if (before != null &&
          (previous!.confirmed || _legacyCoverServer) &&
          coverHashDistance(before, hash) <= kCoverHashMaxDistance) {
        return CoverVoteRecord(
          source: source,
          hash: before,
          rejectedUrl: rejected,
          confirmed: previous.confirmed,
        );
      }
      final bool confirmed = await _voteThumb(workId, source, bytes, hash);
      return CoverVoteRecord(
        source: source,
        hash: hash,
        rejectedUrl: rejected,
        confirmed: confirmed,
      );
    }
    // 没有可投的本地封面：URL 被拒时也记下来，免得每次同步都重试同一个 URL。
    if (rejected != null && previous?.rejectedUrl != rejected) {
      return CoverVoteRecord(source: '-', rejectedUrl: rejected);
    }
    return null;
  }

  /// 缩略图的确认票流程（文件头第 7 步）。返回最终的票是不是确认票。服务端不认识确认票协议
  /// （旧版本）时退化为旧行为：按哈希投了一张未确认票，返回 false。
  ///
  /// 网络 / 下载失败原样抛出（调用方不记账，下次重试）；本地缩略图解不开抛 [_CoverThumbFailure]。
  Future<bool> _voteThumb(
    String workId,
    String source,
    Uint8List bytes,
    String hash,
  ) async {
    CoverVoteResult r;
    try {
      r = await client.checkCover(workId, hash);
    } on LeaderboardApiException catch (err) {
      if (!isCoverBytesRequired(err)) rethrow;
      r = await client.uploadCoverChecked(workId, bytes, hash: hash);
    }
    for (int i = 0; i < kCoverConfirmMaxCandidates; i++) {
      if (r.legacyServer) {
        _legacyCoverServer = true;
        return false;
      }
      final CoverCandidateRef? candidate = r.candidate;
      if (r.confirmed || candidate == null) return r.confirmed;
      final String key = '$workId|${candidate.id}|$source';
      bool? same = _checks[key];
      if (same == null) {
        final Uint8List remote;
        try {
          remote = await client.fetchCoverImage(candidate.image);
        } on LeaderboardApiException catch (err) {
          // 缩略图 404 = 候选在 check 之后被清理了（不是服务端不认接口）：按临时失败跳过这部，
          // 不停本轮、不记账，下次同步重新 check。
          if (err.status == 404) {
            throw const LeaderboardApiException(409, 'cover_candidate_gone');
          }
          rethrow;
        }
        final CoverSimilarity? sim = await coverCompare(bytes, remote);
        if (sim == null) {
          throw _CoverThumbFailure(
            const FormatException('local cover thumbnail is not decodable'),
          );
        }
        same = sim.sameImage;
        _checks[key] = same;
      }
      if (same) {
        return (await client.confirmCover(
          workId,
          hash,
          candidate.id,
        )).confirmed;
      }
      try {
        r = await client.rejectCover(workId, hash, candidate.id);
      } on LeaderboardApiException catch (err) {
        if (!isCoverBytesRequired(err)) rethrow;
        r = await client.uploadCoverChecked(workId, bytes, hash: hash);
      }
    }
    // 连着几个候选都不符还没落地：留待下次同步（不记账）。
    throw const _CoverRoundsExhausted();
  }
}

/// 一部作品看了 [kCoverConfirmMaxCandidates] 个候选仍没投成（临时状态，不记账）。
class _CoverRoundsExhausted implements Exception {
  const _CoverRoundsExhausted();
}

/// 本次正在尝试的封面来源（出错时据此记账，免得本地封面没变时反复重试）。
class _CoverAttempt {
  String? source;
  String? rejectedUrl;
}

/// 本地缩略图生成失败（与上传失败区分：它不停止本轮补传）。
class _CoverThumbFailure implements Exception {
  const _CoverThumbFailure(this.error);

  final Object error;
}
