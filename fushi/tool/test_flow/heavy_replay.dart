// Replays the recorded runs (heavy_history.dart) through the lease's own
// admission rules (heavy_budget.dart) under other slot counts, budgets or
// bookings: `dart tool/heavy.dart --replay[=days]` (2026-11-18).
//
// A change to the lease used to be judged by how the queue felt afterwards.
// The history has when each run was submitted, how long it ran and what it
// booked, which is enough to ask "how long would these same runs have queued
// under that rule" before the rule ships.
//
// What the replay cannot know, so its totals are for comparing two rules on
// the same runs, not a forecast:
//   * a run takes as long as it did (more runs at once make each slower);
//   * holders that write no history (pre_push_check, flutter_test_failures,
//     dist_test's local worker) and the per-worktree lock are left out;
//   * a run another machine took leaves the queue when it did then, unless
//     the replay admits it here first.
//
// Pure; unit-tested (test/tools/heavy_replay_test.dart).
import 'heavy_budget.dart';
import 'heavy_history.dart';

/// How long each replayed run queued, by its index in the entries given to
/// [replayHeavyHistory]. Runs another machine took at once are not in it.
typedef HeavyReplay = Map<int, Duration>;

class _Job {
  _Job(
    this.index,
    this.submitMs,
    this.ranMs,
    this.bookMb,
    this.light,
    this.takenAtMs,
  );
  final int index;
  final int submitMs;
  final int ranMs;
  final int bookMb;
  final bool light;

  /// When another machine took it (it then left the queue here), or null.
  final int? takenAtMs;
}

class _Running {
  _Running(this.endMs, this.holder);
  final int endMs;
  final HeavyHolder holder;
}

/// Queues [entries] again in the order they were submitted: [slots] regular
/// slots, [lightSlots] for analyze, bookings ([bookOf]) within [budgetMb],
/// first come first served with [heavyMayGoAhead], every waiter looking
/// again each [poll] as the lease does.
HeavyReplay replayHeavyHistory(
  List<HeavyHistoryEntry> entries, {
  required int slots,
  required int budgetMb,
  required int Function(HeavyHistoryEntry entry) bookOf,
  int lightSlots = kLightSlotCount,
  Duration poll = const Duration(seconds: 5),
}) {
  final List<_Job> jobs = <_Job>[];
  for (int i = 0; i < entries.length; i++) {
    final HeavyHistoryEntry e = entries[i];
    final bool elsewhere = e.where == HeavyRanWhere.elsewhere;
    // Taken there before it ever queued here: no part of this queue.
    if (elsewhere && e.queued == Duration.zero) continue;
    final int startMs = e.at.millisecondsSinceEpoch - e.ran.inMilliseconds;
    jobs.add(
      _Job(
        i,
        startMs - e.queued.inMilliseconds,
        e.ran.inMilliseconds,
        bookOf(e),
        e.kind == HeavyKind.analyze.name,
        elsewhere ? startMs : null,
      ),
    );
  }
  jobs.sort((_Job a, _Job b) {
    final int byTime = a.submitMs.compareTo(b.submitMs);
    return byTime != 0 ? byTime : a.index.compareTo(b.index);
  });
  final HeavyReplay waited = <int, Duration>{};
  if (jobs.isEmpty) return waited;

  final List<_Job> waiting = <_Job>[];
  final List<_Running> running = <_Running>[];
  int next = 0;
  int now = jobs.first.submitMs;
  while (next < jobs.length || waiting.isNotEmpty) {
    if (waiting.isEmpty && next < jobs.length && jobs[next].submitMs > now) {
      now = jobs[next].submitMs;
    }
    while (next < jobs.length && jobs[next].submitMs <= now) {
      waiting.add(jobs[next++]);
    }
    running.removeWhere((_Running r) => r.endMs <= now);
    waiting.removeWhere((_Job j) {
      final int? taken = j.takenAtMs;
      if (taken == null || taken > now) return false;
      waited[j.index] = Duration(milliseconds: taken - j.submitMs);
      return true;
    });
    // One admission at a time, oldest waiter first, until nobody else fits.
    while (true) {
      final _Job? admitted = _nextAdmitted(
        waiting,
        running,
        slots: slots,
        lightSlots: lightSlots,
        budgetMb: budgetMb,
      );
      if (admitted == null) break;
      waiting.remove(admitted);
      waited[admitted.index] = Duration(milliseconds: now - admitted.submitMs);
      running.add(
        _Running(
          now + admitted.ranMs,
          HeavyHolder(
            slot: admitted.light ? kLightSlotBase : 0,
            pid: 0,
            startedAtMs: now,
            label: '',
            cwd: '',
            capMb: admitted.bookMb,
          ),
        ),
      );
    }
    // A run looks the moment it is submitted, then everyone again each poll.
    final int tick = now + poll.inMilliseconds;
    now = next < jobs.length && jobs[next].submitMs < tick
        ? jobs[next].submitMs
        : tick;
  }
  return waited;
}

/// The oldest waiter the lease would admit right now, or null.
_Job? _nextAdmitted(
  List<_Job> waiting,
  List<_Running> running, {
  required int slots,
  required int lightSlots,
  required int budgetMb,
}) {
  final List<HeavyHolder> holders = <HeavyHolder>[
    for (final _Running r in running) r.holder,
  ];
  final List<int> held = <int>[for (final HeavyHolder h in holders) h.bookedMb];
  final int lightBusy = holders
      .where((HeavyHolder h) => h.slot == kLightSlotBase)
      .length;
  final int regularBusy = running.length - lightBusy;
  final List<HeavyEarlier> earlier = <HeavyEarlier>[];
  for (final _Job j in waiting) {
    final bool fits =
        heavyBudgetBlocker(
          needMb: j.bookMb,
          heldCapsMb: held,
          budgetMb: budgetMb,
        ) ==
        null;
    if (j.light) {
      // Analyze holds no ticket: a free light slot and room in the budget.
      if (fits && lightBusy < lightSlots) return j;
      continue;
    }
    final bool turn =
        earlier.isEmpty ||
        heavyMayGoAhead(
          needMb: j.bookMb,
          earlier: earlier,
          holders: holders,
          budgetMb: budgetMb,
        );
    if (turn && fits && regularBusy < slots) return j;
    earlier.add((bookedMb: j.bookMb, enqueuedUs: j.submitMs * 1000));
  }
  return null;
}

/// The booking a run had when bookings were fixed per kind and closure: its
/// class ([HeavyHistoryEntry.bookingClassMb]), or the largest ceiling for a
/// run that recorded none (a build).
int heavyReplayStaticBook(HeavyHistoryEntry e) =>
    e.bookingClassMb ?? kUnknownHolderCapMb;

/// The booking each of [entries] gets when its class is measured
/// ([heavyMeasuredBookMb]) from the runs that ended before it was submitted,
/// by index; the fixed booking where there were too few.
List<int> heavyReplayMeasuredBooks(List<HeavyHistoryEntry> entries) => <int>[
  for (final HeavyHistoryEntry e in entries)
    e.bookingClassMb == null
        ? kUnknownHolderCapMb
        : heavyMeasuredBookMb(
                entries,
                kind: e.kind,
                staticMb: e.bookingClassMb!,
                capMb: _capOf(e.kind),
                now: e.at.subtract(e.ran + e.queued),
              ) ??
              e.bookingClassMb!,
];

int _capOf(String kind) {
  for (final HeavyKind k in HeavyKind.values) {
    if (k.name == kind) return heavyNeedFor(k).capMb;
  }
  return kUnknownHolderCapMb;
}

String _span(int seconds) => seconds < 120
    ? '${seconds}s'
    : seconds < 7200
    ? '${seconds ~/ 60}m${(seconds % 60).toString().padLeft(2, '0')}s'
    : '${seconds ~/ 3600}h${((seconds % 3600) ~/ 60).toString().padLeft(2, '0')}m';

/// One line per kind for each named replay: how long the runs that ended up
/// on this machine queued (p50 / p90 / max) and what all runs queued in all.
String renderHeavyReplay(
  List<HeavyHistoryEntry> entries,
  Map<String, HeavyReplay> replays,
) {
  final StringBuffer out = StringBuffer();
  for (final MapEntry<String, HeavyReplay> r in replays.entries) {
    final int all = r.value.values.fold<int>(
      0,
      (int s, Duration d) => s + d.inSeconds,
    );
    out.writeln('${r.key}: ${_span(all)} queued in all');
    final Map<String, List<int>> byKind = <String, List<int>>{};
    for (final MapEntry<int, Duration> w in r.value.entries) {
      final HeavyHistoryEntry e = entries[w.key];
      if (e.where != HeavyRanWhere.here) continue;
      byKind.putIfAbsent(e.kind, () => <int>[]).add(w.value.inSeconds);
    }
    for (final String kind in byKind.keys.toList()..sort()) {
      final List<int> q = byKind[kind]!;
      out.writeln(
        '  ${kind.padRight(8)} ${'${q.length}'.padLeft(4)} run(s) here  '
        'queued p50 ${_span(heavyPercentile(q, 0.5))} / '
        'p90 ${_span(heavyPercentile(q, 0.9))} / '
        'max ${_span(q.reduce((int a, int b) => a > b ? a : b))}, '
        '${_span(q.fold<int>(0, (int s, int v) => s + v))} in all',
      );
    }
  }
  return out.toString();
}
