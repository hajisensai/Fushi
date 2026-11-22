// How long a queued run is still going to wait for a slot, from what holds
// the slots and what queues ahead of it, at the run times this machine's
// history (heavy_history.dart) says such runs take.
//
// Used to give up early under an explicit wait limit (heavy.dart
// --wait-max-min=N): a run that the queue already says will not get a slot
// within N minutes leaves now instead of waiting the N minutes out and then
// leaving anyway (owner, 2026-11-22: "排队的测试太多了，已经可以预测
// 15/30 分钟肯定弄不完，那不弄不是更好"). The prediction leans short on
// purpose, so that it only gives up on a wait that is long for sure: a
// holder already past its typical run counts as finishing now, a run of a
// kind without enough history counts as taking no time, and the memory
// budget (which can only add to the wait) is left out.
import 'heavy_history.dart';

/// How many recent runs of one kind here it takes to call their median
/// typical.
const int kHeavyTypicalMinRuns = 5;

/// How far back the typical run times look.
const Duration kHeavyTypicalWindow = Duration(days: 7);

/// The median time a run of each kind held its slot here (kind name ->
/// duration), from [entries]; a kind with fewer than [kHeavyTypicalMinRuns]
/// such runs is left out. Runs cancelled because their caller was gone are
/// not runs of their kind's length.
Map<String, Duration> heavyTypicalRuns(List<HeavyHistoryEntry> entries) {
  final Map<String, List<int>> byKind = <String, List<int>>{};
  for (final HeavyHistoryEntry e in entries) {
    if (e.where != HeavyRanWhere.here || e.exitCode == kHeavyCallerGoneExit) {
      continue;
    }
    (byKind[e.kind] ??= <int>[]).add(e.ran.inMilliseconds);
  }
  return <String, Duration>{
    for (final MapEntry<String, List<int>> k in byKind.entries)
      if (k.value.length >= kHeavyTypicalMinRuns)
        k.key: Duration(milliseconds: heavyPercentile(k.value, 0.5)),
  };
}

/// One run that holds a slot now: how long it has held it and how long such
/// runs take (null: unknown).
typedef HeavyRunningNow = ({Duration held, Duration? typical});

/// The predicted wait until a slot is free for a run queued behind [ahead]
/// (the typical run of each earlier waiter, oldest first; null: unknown)
/// while [running] hold slots out of [slots]: list scheduling, each slot
/// taken in turn by the next waiter as soon as it frees. Leans short (see
/// the file comment): unknown and overdue runs count as no time left.
Duration heavyPredictedWait({
  required int slots,
  required List<HeavyRunningNow> running,
  required List<Duration?> ahead,
}) {
  if (slots <= 0) return Duration.zero;
  final List<Duration> freeAt = <Duration>[
    for (final HeavyRunningNow r in running.take(slots))
      _left(r.typical, r.held),
    for (int i = running.length; i < slots; i++) Duration.zero,
  ];
  for (final Duration? run in ahead) {
    freeAt.sort();
    freeAt[0] += run ?? Duration.zero;
  }
  freeAt.sort();
  return freeAt.first;
}

Duration _left(Duration? typical, Duration held) {
  if (typical == null || held >= typical) return Duration.zero;
  return typical - held;
}
