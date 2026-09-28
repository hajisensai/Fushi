// 书架增量同步：本机书架（local_shelf.dart）→ 服务端 POST /v1/shelf。
//
// 状态模型（[LeaderboardSyncState]，app 按 Profile 落本机文件）：
// - entries：localKey → 上次成功上报时的内容 hash 与服务端落到的 workId；
// - daily：上次成功上报的每日字数；
// - shelfCount：上次响应里服务端的书架行数（null = 从没成功同步过）。
//
// 一次同步：
// 1. 从没同步过，或 `me().shelfCount` 与 state 里不同 workId 的个数对不上（别处改过、
//    中途失败留下了孤儿行）→ reset 全量重传；否则只传 hash 变了的条目与变了的日期；
// 2. put / daily 按 500 / 400 分批，reset 只在第一批带；每批成功后立即推进 state；
// 3. 全部 put 完成后，旧 state 里出现过、新 state 里已无人映射的 workId（本地删了的、
//    put 后落到了新 workId 的）按 500 一批 remove——「谁还映射它」要等 put 响应回来才
//    知道，所以 remove 放在最后，一条规则同时覆盖删除与 workId 变更。
// 中途失败抛 [LeaderboardSyncException]，携带已推进的 state：调用方存下它，下次从断点续。
//
// 另外三条规则：
// - 已知映射到同一 workId 的多个本地条目先合并成一条再 put（[groupShelfEntries]）；
// - 单批遇 409 `conflict`（同账户并发写入，服务端已整体回滚）原样重发，最多 3 次；
// - 每账户只有一台「上传设备」：本机不是时抛 [LeaderboardUploadOwnedElsewhere]，用户
//   选择接管后以 `claim: true`（强制 reset）全量同步。

import 'dart:typed_data';

import 'package:fushi_engine/leaderboard/leaderboard_client.dart';
import 'package:fushi_engine/leaderboard/leaderboard_models.dart';
import 'package:fushi_engine/leaderboard/local_shelf.dart';

/// 一条已同步条目。[hash] 为空串 = 需要重传（例如封面补传失败，下次 put 时服务端会
/// 再次回 needsCover）。
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

class LeaderboardSyncState {
  const LeaderboardSyncState({
    this.entries = const <String, SyncedEntry>{},
    this.daily = const <String, int>{},
    this.shelfCount,
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
      );
    } on TypeError catch (e) {
      throw FormatException('bad leaderboard sync state: $e');
    }
  }

  final Map<String, SyncedEntry> entries;
  final Map<String, int> daily;
  final int? shelfCount;

  /// 从没成功同步过。
  bool get neverSynced => shelfCount == null;

  /// state 认为服务端书架上有的 workId（多个 localKey 可能映射到同一个）。
  Set<String> get workIds =>
      entries.values.map((SyncedEntry e) => e.workId).toSet();

  Map<String, dynamic> toJson() => <String, dynamic>{
    'entries': <String, dynamic>{
      for (final MapEntry<String, SyncedEntry> e in entries.entries)
        e.key: e.value.toJson(),
    },
    'daily': daily,
    if (shelfCount != null) 'shelfCount': shelfCount,
  };
}

/// 一个 put 条目：一个或多个本地条目合并成的上报。多个 localKey 已知映射到同一 workId
/// 时（state 里记录过）先合并再 put——服务端按 (账户, 作品) 覆盖写，分开传会互相覆盖。
class ShelfSyncItem {
  const ShelfSyncItem({required this.entry, required this.localKeys});

  /// 合并后的条目（localKey = 组内第一个，localCoverPath = 组内第一个非空）。
  final LocalShelfEntry entry;

  /// 组内全部 localKey（升序）；响应的 workId 与合并后的 hash 记到每一个上。
  final List<String> localKeys;

  String get localKey => entry.localKey;
}

/// 一次上报请求的内容。[put] 里第 i 条对应响应 `works[].i == i`。
class ShelfSyncBatch {
  const ShelfSyncBatch({
    required this.reset,
    required this.put,
    required this.daily,
  });

  final bool reset;
  final List<ShelfSyncItem> put;
  final List<DailyCharsUpload> daily;
}

class ShelfSyncPlan {
  const ShelfSyncPlan({
    required this.reset,
    required this.batches,
    required this.droppedLocalKeys,
  });

  final bool reset;

  /// put + daily 批次（reset 时第一批带 reset；无事可做且不 reset 时为空）。
  final List<ShelfSyncBatch> batches;

  /// 本地已消失的 localKey（put 全部完成后从 state 里去掉，再算孤儿 workId）。
  final List<String> droppedLocalKeys;
}

/// 纯函数：把已知映射到同一 workId 的本地条目合并（读完取最晚、chars/ms 相加、
/// refs / 标题 / 作者 / 种类取组内第一个，封面取第一个非空）。未知映射的条目各自成组
/// ——首次上报后服务端会告诉我们它们落在哪，下次同步再合并。
List<ShelfSyncItem> groupShelfEntries(
  LocalShelf local,
  LeaderboardSyncState state,
) {
  final Map<String, List<LocalShelfEntry>> byWork =
      <String, List<LocalShelfEntry>>{};
  final List<List<LocalShelfEntry>> groups = <List<LocalShelfEntry>>[];
  for (final LocalShelfEntry e in local.entries) {
    final String? workId = state.entries[e.localKey]?.workId;
    if (workId == null) {
      groups.add(<LocalShelfEntry>[e]);
      continue;
    }
    final List<LocalShelfEntry>? group = byWork[workId];
    if (group != null) {
      group.add(e);
    } else {
      final List<LocalShelfEntry> fresh = <LocalShelfEntry>[e];
      byWork[workId] = fresh;
      groups.add(fresh);
    }
  }
  return <ShelfSyncItem>[
    for (final List<LocalShelfEntry> g in groups)
      ShelfSyncItem(
        entry: g.length == 1 ? g.single : _merge(g),
        localKeys: List<String>.unmodifiable(
          g.map((LocalShelfEntry e) => e.localKey),
        ),
      ),
  ];
}

LocalShelfEntry _merge(List<LocalShelfEntry> group) {
  final ShelfEntryUpload first = group.first.upload;
  ShelfEntryUpload? latest;
  for (final LocalShelfEntry e in group) {
    final int? at = e.upload.finishedAt;
    if (at != null && (latest == null || at > latest.finishedAt!)) {
      latest = e.upload;
    }
  }
  final bool finished = group.any((LocalShelfEntry e) => e.upload.finished);
  int chars = 0;
  int ms = 0;
  for (final LocalShelfEntry e in group) {
    chars += e.upload.chars;
    ms += e.upload.ms;
  }
  return LocalShelfEntry(
    localKey: group.first.localKey,
    localCoverPath: group
        .map((LocalShelfEntry e) => e.localCoverPath)
        .whereType<String>()
        .firstOrNull,
    upload: ShelfEntryUpload(
      kind: first.kind,
      refs: first.refs,
      title: first.title,
      author: first.author,
      coverUrl:
          first.coverUrl ??
          group
              .map((LocalShelfEntry e) => e.upload.coverUrl)
              .whereType<String>()
              .firstOrNull,
      nsfw: group.any((LocalShelfEntry e) => e.upload.nsfw),
      finished: finished,
      finishedAt: latest?.finishedAt,
      finishedDate: latest?.finishedDate,
      chars: chars,
      ms: ms,
    ),
  );
}

/// 纯函数：由本机书架与上次状态算出要上报的批次。
///
/// [reset] = 全量重传（服务端先清空）：全部条目、全部非零日期。否则只 put 合并后 hash
/// 与组内任一 localKey 的记录不同（或组内有新 localKey）的条目，daily 只发变了的日期，
/// state 里有、本地没了的日期发 0（早于 [LocalShelf.dailyFrom] 的除外——服务端只收
/// 最近 10 年，过期日期直接从 state 里忘掉）。
ShelfSyncPlan planShelfSync(
  LocalShelf local,
  LeaderboardSyncState state, {
  required bool reset,
}) {
  final List<ShelfSyncItem> put = <ShelfSyncItem>[
    for (final ShelfSyncItem item in groupShelfEntries(local, state))
      if (reset ||
          item.localKeys.any(
            (String k) =>
                state.entries[k]?.hash != item.entry.upload.contentHash(),
          ))
        item,
  ];
  final Map<String, int> localDaily = <String, int>{
    for (final DailyCharsUpload d in local.daily) d.date: d.chars,
  };
  final String? dailyFrom = local.dailyFrom;
  final List<DailyCharsUpload> daily = <DailyCharsUpload>[
    for (final DailyCharsUpload d in local.daily)
      if (reset || state.daily[d.date] != d.chars) d,
    if (!reset)
      for (final String date in state.daily.keys.toList()..sort())
        if (!localDaily.containsKey(date) &&
            state.daily[date] != 0 &&
            (dailyFrom == null || date.compareTo(dailyFrom) >= 0))
          DailyCharsUpload(date: date, chars: 0),
  ];
  final Set<String> localKeys = <String>{
    for (final LocalShelfEntry e in local.entries) e.localKey,
  };
  final List<String> dropped = reset
      ? const <String>[]
      : (state.entries.keys.where((String k) => !localKeys.contains(k)).toList()
          ..sort());

  final int putBatches = _ceilDiv(put.length, kLeaderboardMaxPut);
  final int dailyBatches = _ceilDiv(daily.length, kLeaderboardMaxDaily);
  final int n = putBatches > dailyBatches ? putBatches : dailyBatches;
  final int batchCount = n == 0 && reset ? 1 : n;
  return ShelfSyncPlan(
    reset: reset,
    droppedLocalKeys: List<String>.unmodifiable(dropped),
    batches: List<ShelfSyncBatch>.unmodifiable(<ShelfSyncBatch>[
      for (int i = 0; i < batchCount; i++)
        ShelfSyncBatch(
          reset: reset && i == 0,
          put: _slice(put, i, kLeaderboardMaxPut),
          daily: _slice(daily, i, kLeaderboardMaxDaily),
        ),
    ]),
  );
}

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

int _ceilDiv(int a, int b) => (a + b - 1) ~/ b;

List<T> _slice<T>(List<T> all, int batch, int size) {
  final int start = batch * size;
  if (start >= all.length) return List<T>.unmodifiable(<T>[]);
  final int end = start + size > all.length ? all.length : start + size;
  return List<T>.unmodifiable(all.sublist(start, end));
}

/// 同步中途失败。[partialState] 是已成功推进到的状态（调用方应落盘，下次从这里续）；
/// [error] / [stackTrace] 是原始失败（429 / 503 / 网络错误等都走这里）。
class LeaderboardSyncException implements Exception {
  const LeaderboardSyncException(
    this.partialState,
    this.error,
    this.stackTrace,
  );

  final LeaderboardSyncState partialState;
  final Object error;
  final StackTrace stackTrace;

  @override
  String toString() => 'LeaderboardSyncException($error)';
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

bool _isOwnedElsewhere(Object e) =>
    e is LeaderboardApiException &&
    e.status == 409 &&
    e.code == 'upload_owned_by_other_device';

bool _isConflict(Object e) =>
    e is LeaderboardApiException && e.status == 409 && e.code == 'conflict';

/// 发一批；409 `conflict`（服务端已整体回滚）原样重发，最多 [kLeaderboardConflictRetries] 次。
Future<ShelfUploadResult> _uploadWithConflictRetry(
  Future<ShelfUploadResult> Function() send,
) async {
  for (int attempt = 0; ; attempt++) {
    try {
      return await send();
    } on LeaderboardApiException catch (e) {
      if (!_isConflict(e) || attempt >= kLeaderboardConflictRetries) rethrow;
    }
  }
}

/// 把 [local] 同步到服务端，返回新状态。
///
/// [claim] = 由本设备接管上传：强制 reset 全量，第一批带 `claim: true`。
///
/// [coverThumb]：服务端回 needsCover 的条目调它取缩略图字节（返回 null = 本地没有封面，
/// 跳过）。封面补传失败不打断书架同步：该组条目 hash 记成空串（下次重 put、服务端会再要
/// 封面），全部批次完成后再以 [LeaderboardSyncException] 报出第一个封面错误。
///
/// 上传设备不是本机时抛 [LeaderboardUploadOwnedElsewhere]；其余失败抛
/// [LeaderboardSyncException]（带已推进的状态）。
Future<LeaderboardSyncState> syncShelf(
  LeaderboardClient client,
  LocalShelf local,
  LeaderboardSyncState state, {
  bool claim = false,
  Future<Uint8List?> Function(LocalShelfEntry entry)? coverThumb,
}) async {
  LeaderboardSyncState current = state;
  Object? coverError;
  StackTrace? coverStack;
  try {
    bool reset = claim || state.neverSynced;
    if (!reset) {
      final LeaderboardSelf self = await client.me();
      if (self.uploadDevice == false) {
        throw const LeaderboardUploadOwnedElsewhere();
      }
      final int? serverCount = self.shelfCount;
      reset = serverCount != null && serverCount != state.workIds.length;
    }
    final ShelfSyncPlan plan = planShelfSync(local, state, reset: reset);
    final Map<String, SyncedEntry> before = state.entries;
    for (final ShelfSyncBatch batch in plan.batches) {
      final ShelfUploadResult result = await _uploadWithConflictRetry(
        () => client.uploadShelfDelta(
          reset: batch.reset,
          claim: claim && batch.reset,
          put: <ShelfEntryUpload>[
            for (final ShelfSyncItem item in batch.put) item.entry.upload,
          ],
          daily: batch.daily,
        ),
      );
      final Map<String, SyncedEntry> entries = batch.reset
          ? <String, SyncedEntry>{}
          : Map<String, SyncedEntry>.of(current.entries);
      final Map<String, int> daily = batch.reset
          ? <String, int>{}
          : Map<String, int>.of(current.daily);
      for (final DailyCharsUpload d in batch.daily) {
        if (d.chars == 0) {
          daily.remove(d.date);
        } else {
          daily[d.date] = d.chars;
        }
      }
      for (final UploadedWork w in result.works) {
        if (w.i < 0 || w.i >= batch.put.length) continue;
        final ShelfSyncItem item = batch.put[w.i];
        String hash = item.entry.upload.contentHash();
        if (w.needsCover && coverThumb != null) {
          try {
            final Uint8List? bytes = await coverThumb(item.entry);
            if (bytes != null && bytes.isNotEmpty) {
              await client.uploadCover(w.workId, bytes);
            }
          } on Object catch (err, st) {
            hash = '';
            coverError ??= err;
            coverStack ??= st;
          }
        }
        for (final String k in item.localKeys) {
          entries[k] = SyncedEntry(hash: hash, workId: w.workId);
        }
      }
      current = LeaderboardSyncState(
        entries: Map<String, SyncedEntry>.unmodifiable(entries),
        daily: Map<String, int>.unmodifiable(daily),
        shelfCount: result.shelfCount,
      );
    }
    if (!plan.reset) {
      final Map<String, SyncedEntry> after =
          Map<String, SyncedEntry>.of(current.entries)..removeWhere(
            (String k, SyncedEntry _) => plan.droppedLocalKeys.contains(k),
          );
      final List<String> orphans = orphanedWorkIds(before, after);
      for (int i = 0; i < orphans.length; i += kLeaderboardMaxRemove) {
        final List<String> chunk = orphans.sublist(
          i,
          i + kLeaderboardMaxRemove > orphans.length
              ? orphans.length
              : i + kLeaderboardMaxRemove,
        );
        final ShelfUploadResult result = await _uploadWithConflictRetry(
          () => client.uploadShelfDelta(remove: chunk),
        );
        current = LeaderboardSyncState(
          entries: current.entries,
          daily: current.daily,
          shelfCount: result.shelfCount,
        );
      }
      current = LeaderboardSyncState(
        entries: Map<String, SyncedEntry>.unmodifiable(after),
        daily: current.daily,
        shelfCount: current.shelfCount,
      );
    }
    // 过了服务端 10 年窗口的日期：不再发 0（会被 400），直接从 state 里忘掉。
    final String? dailyFrom = local.dailyFrom;
    if (dailyFrom != null &&
        current.daily.keys.any((String d) => d.compareTo(dailyFrom) < 0)) {
      current = LeaderboardSyncState(
        entries: current.entries,
        daily: Map<String, int>.unmodifiable(
          Map<String, int>.of(current.daily)
            ..removeWhere((String d, int _) => d.compareTo(dailyFrom) < 0),
        ),
        shelfCount: current.shelfCount,
      );
    }
  } on LeaderboardUploadOwnedElsewhere {
    rethrow;
  } on Object catch (e, st) {
    if (_isOwnedElsewhere(e)) throw const LeaderboardUploadOwnedElsewhere();
    throw LeaderboardSyncException(current, e, st);
  }
  if (coverError != null) {
    throw LeaderboardSyncException(
      current,
      coverError,
      coverStack ?? StackTrace.empty,
    );
  }
  return current;
}
