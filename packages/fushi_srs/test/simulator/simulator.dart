import 'dart:math';

import 'package:fushi_srs/fushi_srs.dart';

import '../support/fake_engine.dart';
import 'memory_directory.dart';

const String kProfile = 'profile-1';
const int kStart = 1700000000000;
const int kMinute = 60000;
const int kDay = 24 * 60 * kMinute;

/// 模拟的一台设备。
class SimDevice {
  SimDevice(this.world, this.id, this.skewMs) {
    replica = SrsMemoryReplica(deviceId: id, trustedNow: now);
    engine = SrsSyncEngine(
      directory: world.dir,
      replica: replica,
      options: const SrsSyncOptions(snapshotEveryBatches: 3),
    );
  }

  final SimWorld world;
  final String id;
  int skewMs;
  bool anchored = false;
  late SrsMemoryReplica replica;
  late SrsSyncEngine engine;
  SrsBackup? savedBackup;

  (int, SrsTimeSource) now() => anchored
      ? (world.trueNow, SrsTimeSource.anchored)
      : (world.trueNow + skewMs, SrsTimeSource.wall);

  SrsLogContext logContext() => SrsLogContext(
    profileUid: kProfile,
    clock: replica.clock,
    now: now,
    day: const SrsDayContext(utcOffsetMin: 0, rolloverHour: 4),
    newId: (int ms) => world.nextId('log'),
  );

  Future<SrsSyncReport> sync() async {
    final SrsSyncReport r = await engine.syncOnce();
    if (r.error == null) anchored = true;
    return r;
  }

  SrsFieldEdit? edit(String entityId, String key, Object? value) {
    final SrsFieldEdit? e = replica.edit(
      kProfile,
      SrsEntityKind.note,
      entityId,
      key,
      value,
    );
    if (e != null) world.ledger.add(e);
    return e;
  }

  SrsReviewLog rate(String cardId, int rating) {
    final SrsReviewLog log = const SrsCardOps(engine: _engine).answer(
      cardId: cardId,
      history: replica.store.historyOf(cardId),
      rating: rating,
      config: const SrsSchedulingConfig(),
      ctx: logContext(),
    );
    replica.addLog(log);
    return log;
  }

  SrsReviewLog? undo(String cardId) {
    final SrsCardHistory h = replica.store.historyOf(cardId);
    final SrsReviewLog? last = h.lastEffective;
    if (last == null) return null;
    final SrsReviewLog? u = const SrsCardOps(
      engine: _engine,
    ).undo(cardId: cardId, history: h, targetLogId: last.id, ctx: logContext());
    if (u != null) replica.addLog(u);
    return u;
  }
}

const FakeFsrsEngine _engine = FakeFsrsEngine();

/// 模拟世界：真实时间、云盘目录、设备、全部修改记录的台账。
class SimWorld {
  SimWorld({Random? random}) {
    dir = MemorySyncDirectory(serverNow: () => trueNow, random: random);
  }

  int trueNow = kStart;
  late final MemorySyncDirectory dir;
  final Map<String, SimDevice> devices = <String, SimDevice>{};
  final List<SrsFieldEdit> ledger = <SrsFieldEdit>[];
  int _ids = 0;

  String nextId(String p) => '$p-${(_ids++).toString().padLeft(6, '0')}';

  SimDevice add(String id, {int skewMs = 0}) =>
      devices[id] = SimDevice(this, id, skewMs);

  /// 全部设备反复同步，直到没有任何发布 / 应用（没有列表延迟时最多几轮）。
  Future<void> quiesce({int maxRounds = 12}) async {
    final double delay = dir.listDelay;
    dir.listDelay = 0;
    int quiet = 0;
    for (int round = 0; round < maxRounds && quiet < 2; round++) {
      int activity = 0;
      for (final SimDevice d in devices.values) {
        final SrsSyncReport r = await d.sync();
        activity += r.published + r.applied;
      }
      quiet = activity == 0 ? quiet + 1 : 0;
    }
    dir.listDelay = delay;
  }

  /// 五条断言；返回违反项（空 = 通过）。
  List<String> check() {
    final List<String> problems = <String>[];
    final List<SimDevice> ds = devices.values.toList();
    final String d0 = ds.first.replica.store.digest();
    for (final SimDevice d in ds.skip(1)) {
      if (d.replica.store.digest() != d0) {
        problems.add('① not converged: ${ds.first.id} vs ${d.id}');
      }
    }
    // ④ 同一事件 ID 在所有端内容一致。
    final Map<String, String> seen = <String, String>{};
    for (final SimDevice d in ds) {
      for (final SrsEvent e in d.replica.store.allEvents()) {
        final String c = e.canonical();
        final String? prev = seen.putIfAbsent(e.id, () => c);
        if (prev != c) problems.add('④ event ${e.id} differs');
      }
      if (d.replica.store.diagnostics.isNotEmpty) {
        problems.add(
          '④ diagnostics on ${d.id}: ${d.replica.store.diagnostics}',
        );
      }
    }
    // ⑤ 任何修改记录都不会在没有冲突记录的情况下消失：要么还在寄存器里，要么被看见过它的记录支配。
    final SrsEventStore s0 = ds.first.replica.store;
    for (final SrsFieldEdit e in ledger) {
      final SrsRegister reg = s0.editsOf(e.entityKind, e.entityId)[e.fieldKey]!;
      final bool kept = reg.live.any(
        (SrsFieldEdit l) => l.id == e.id || l.ctx.contains(e.dot),
      );
      if (!kept) problems.add('⑤ edit ${e.id} (${e.registerKey}) vanished');
    }
    return problems;
  }
}

// ---------------------------------------------------------------- 随机操作

sealed class SimOp {
  const SimOp();
}

class OpEdit extends SimOp {
  const OpEdit(this.dev, this.note, this.key, this.value);
  final String dev;
  final int note;
  final int key;
  final String value;
  @override
  String toString() => 'edit($dev, n$note.k$key=$value)';
}

class OpDelete extends SimOp {
  const OpDelete(this.dev, this.note, {required this.restore});
  final String dev;
  final int note;
  final bool restore;
  @override
  String toString() => '${restore ? 'undelete' : 'delete'}($dev, n$note)';
}

class OpRate extends SimOp {
  const OpRate(this.dev, this.card, this.rating);
  final String dev;
  final int card;
  final int rating;
  @override
  String toString() => 'rate($dev, c$card, $rating)';
}

class OpUndo extends SimOp {
  const OpUndo(this.dev, this.card);
  final String dev;
  final int card;
  @override
  String toString() => 'undo($dev, c$card)';
}

class OpSync extends SimOp {
  const OpSync(this.dev);
  final String dev;
  @override
  String toString() => 'sync($dev)';
}

class OpAdvance extends SimOp {
  const OpAdvance(this.ms);
  final int ms;
  @override
  String toString() => 'advance(${ms ~/ kMinute}m)';
}

class OpBackup extends SimOp {
  const OpBackup(this.dev);
  final String dev;
  @override
  String toString() => 'backup($dev)';
}

class OpRestore extends SimOp {
  const OpRestore(this.dev);
  final String dev;
  @override
  String toString() => 'restore($dev)';
}

class OpReboot extends SimOp {
  const OpReboot(this.dev, this.skewMs);
  final String dev;
  final int skewMs;
  @override
  String toString() => 'reboot($dev, skew=${skewMs ~/ kMinute}m)';
}

const List<int> kSkews = <int>[
  0,
  0,
  5 * kMinute,
  -5 * kMinute,
  -kDay,
  365 * kDay,
];

List<SimOp> generateOps(int seed, {int steps = 60, int devices = 3}) {
  final Random r = Random(seed);
  String dev() => 'd${r.nextInt(devices)}';
  final List<SimOp> ops = <SimOp>[];
  for (int i = 0; i < steps; i++) {
    final int k = r.nextInt(100);
    if (k < 28) {
      ops.add(OpEdit(dev(), r.nextInt(3), r.nextInt(2), 'v${r.nextInt(4)}'));
    } else if (k < 32) {
      ops.add(OpDelete(dev(), r.nextInt(3), restore: r.nextInt(4) == 0));
    } else if (k < 50) {
      ops.add(OpRate(dev(), r.nextInt(3), 1 + r.nextInt(4)));
    } else if (k < 55) {
      ops.add(OpUndo(dev(), r.nextInt(3)));
    } else if (k < 78) {
      ops.add(OpSync(dev()));
    } else if (k < 88) {
      ops.add(OpAdvance((1 + r.nextInt(120)) * kMinute));
    } else if (k < 91) {
      ops.add(OpBackup(dev()));
    } else if (k < 94) {
      ops.add(OpRestore(dev()));
    } else if (k < 97) {
      ops.add(OpReboot(dev(), kSkews[r.nextInt(kSkews.length)]));
    } else {
      ops.add(const OpAdvance(100 * kDay));
    }
  }
  return ops;
}

/// 跑一组操作，返回违反项。
Future<List<String>> runOps(
  List<SimOp> ops, {
  int devices = 3,
  int seed = 0,
  double listDelay = 0.2,
}) async {
  final Random r = Random(seed);
  final SimWorld w = SimWorld(random: r);
  w.dir.listDelay = listDelay;
  for (int i = 0; i < devices; i++) {
    w.add('d$i', skewMs: kSkews[(seed + i) % kSkews.length]);
  }
  String noteId(int n) => 'note-$n';
  String cardId(int c) => 'card-$c';
  for (final SimOp op in ops) {
    w.trueNow += 1000;
    switch (op) {
      case OpEdit(
        :final String dev,
        :final int note,
        :final int key,
        :final String value,
      ):
        w.devices[dev]!.edit(noteId(note), 'f/fld$key', value);
      case OpDelete(:final String dev, :final int note, :final bool restore):
        w.devices[dev]!.edit(
          noteId(note),
          SrsFieldKeys.deleted,
          restore ? null : w.trueNow,
        );
      case OpRate(:final String dev, :final int card, :final int rating):
        w.devices[dev]!.rate(cardId(card), rating);
      case OpUndo(:final String dev, :final int card):
        w.devices[dev]!.undo(cardId(card));
      case OpSync(:final String dev):
        await w.devices[dev]!.sync();
      case OpAdvance(:final int ms):
        w.trueNow += ms;
      case OpBackup(:final String dev):
        w.devices[dev]!.savedBackup = w.devices[dev]!.replica.backup();
      case OpRestore(:final String dev):
        final SimDevice d = w.devices[dev]!;
        final SrsBackup? b = d.savedBackup;
        if (b != null) {
          // 备份之后产生、还没发布的本机改动随恢复丢失：从台账里去掉（它们从未离开过这台设备）。
          final Set<String> kept = <String>{
            for (final SrsEvent e in b.events) e.id,
          };
          final Set<String> lost = <String>{
            for (final SrsEvent e in await d.replica.unpublishedEvents())
              if (!kept.contains(e.id)) e.id,
          };
          w.ledger.removeWhere((SrsFieldEdit e) => lost.contains(e.id));
          d.replica.restore(b);
          d.anchored = false;
        }
      case OpReboot(:final String dev, :final int skewMs):
        w.devices[dev]!
          ..anchored = false
          ..skewMs = skewMs;
    }
  }
  await w.quiesce();
  return w.check();
}

/// 失败时自动缩减成最小复现序列（逐个删操作，仍失败就保留删除）。
Future<List<SimOp>> shrink(
  List<SimOp> ops, {
  required int seed,
  int devices = 3,
}) async {
  List<SimOp> cur = List<SimOp>.of(ops);
  bool progress = true;
  while (progress) {
    progress = false;
    for (int i = 0; i < cur.length; i++) {
      final List<SimOp> trial = List<SimOp>.of(cur)..removeAt(i);
      if ((await runOps(trial, devices: devices, seed: seed)).isNotEmpty) {
        cur = trial;
        progress = true;
        break;
      }
    }
  }
  return cur;
}
