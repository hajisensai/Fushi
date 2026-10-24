// 确定性多设备模拟器（A-6，PR2 数据契约冻结门）。
//
// 固定用例：第六轮审查（9.txt）第 1、2、3、5 条，7.md A-1 / A-2，HBK-AUDIT-001 / 002 / 009；
// 随机用例：固定种子的操作序列 + 投递顺序 + 时钟偏差 + 备份恢复 + 退役回归，断言五件事，失败时自动缩减。
import 'dart:typed_data';

import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import 'simulator/memory_directory.dart';
import 'simulator/simulator.dart';

SrsEditEvent _ev(SrsFieldEdit e) => SrsEditEvent(e);

SrsFieldEdit _mk(
  SrsEditWriter w,
  HlcClock c,
  int t,
  String value, {
  String key = 'f/x',
}) => w.create(
  profileUid: kProfile,
  entityKind: SrsEntityKind.note,
  entityId: 'n',
  fieldKey: key,
  value: value,
  hlc: c.tick(t),
  timeSource: SrsTimeSource.wall,
);

void main() {
  group('第六轮审查第 1 条：支配必须可传递', () {
    test('a ← b ← c，两台设备以不同顺序收到，结果都只剩 c', () {
      final SrsEditWriter a = SrsEditWriter(writerId: 'A');
      final SrsEditWriter b = SrsEditWriter(writerId: 'B');
      final SrsEditWriter c = SrsEditWriter(writerId: 'C');
      final HlcClock ca = HlcClock('A'), cb = HlcClock('B'), cc = HlcClock('C');
      final SrsFieldEdit ea = _mk(a, ca, 1000, 'a');
      b.apply(ea);
      final SrsFieldEdit eb = _mk(b, cb, 2000, 'b');
      // C 只读到了 B 的批次、还没读 A 的。
      c.apply(eb);
      final SrsFieldEdit ec = _mk(c, cc, 3000, 'c');
      expect(
        ec.ctx.contains(ea.dot),
        isTrue,
        reason: '因果闭包：c 的上下文必须含 b 看见过的 a',
      );

      final SrsEventStore dev1 = SrsEventStore()
        ..apply(_ev(ea))
        ..apply(_ev(eb))
        ..apply(_ev(ec));
      final SrsEventStore dev2 = SrsEventStore()
        ..apply(_ev(ec))
        ..apply(_ev(ea))
        ..apply(_ev(eb));
      for (final SrsEventStore s in <SrsEventStore>[dev1, dev2]) {
        final SrsRegister r = s.editsOf(SrsEntityKind.note, 'n')['f/x']!;
        expect(r.live.map((SrsFieldEdit e) => e.value), <Object?>['c']);
        expect(r.conflicted, isFalse);
      }
      expect(dev1.digest(), dev2.digest());
    });
  });

  group('第六轮审查第 2 条：不连续的 dot', () {
    test('由新化身重新发布的旧 dot，之后看见它的修改能支配它', () async {
      final SimWorld w = SimWorld();
      final SimDevice d = w.add('d');
      final SimDevice x = w.add('x');
      await d.sync();
      await x.sync();
      // d 改了字段，还没发布就做了备份；之后整机数据丢失，从备份恢复。
      final SrsFieldEdit old = d.edit('n', 'f/x', 'old')!;
      final SrsBackup backup = d.replica.backup();
      d.replica.restore(backup);
      expect(d.replica.writerId, isNot(old.dot.writerId));
      w.trueNow += kMinute;
      await w.quiesce();
      // x 看见了旧 dot（d#1:1，由 d#2 重新发布），再改同一字段。
      final SrsFieldEdit newer = x.edit('n', 'f/x', 'new')!;
      expect(newer.ctx.contains(old.dot), isTrue);
      await w.quiesce();
      for (final SimDevice dev in w.devices.values) {
        final SrsRegister r = dev.replica.store.editsOf(
          SrsEntityKind.note,
          'n',
        )['f/x']!;
        expect(r.live.map((SrsFieldEdit e) => e.value), <Object?>['new']);
      }
      expect(w.check(), isEmpty);
    });

    test('改回 / 确认的记录覆盖全部并发候选（含具体 dot）', () {
      final SrsEditWriter a = SrsEditWriter(writerId: 'A');
      final SrsEditWriter b = SrsEditWriter(writerId: 'B');
      final HlcClock ca = HlcClock('A'), cb = HlcClock('B');
      final SrsFieldEdit ea = _mk(a, ca, 1000, 'a');
      final SrsFieldEdit eb = _mk(b, cb, 1000, 'b');
      final SrsEventStore s = SrsEventStore()
        ..apply(_ev(ea))
        ..apply(_ev(eb));
      expect(s.editsOf(SrsEntityKind.note, 'n')['f/x']!.conflicted, isTrue);
      a.adopt(s.seenContext);
      final SrsFieldEdit resolve = _mk(a, ca, 2000, 'b');
      s.apply(_ev(resolve));
      final SrsRegister r = s.editsOf(SrsEntityKind.note, 'n')['f/x']!;
      expect(r.live, hasLength(1));
      expect(r.conflicted, isFalse);
    });
  });

  group('第六轮审查第 3 条：收到对端 HLC 先钳位', () {
    test('时钟快一年的对端不会把本机 HLC 推到一年后', () {
      const int s = kStart;
      final HlcClock local = HlcClock('L');
      local.receive(
        const Hlc(kStart + 365 * kDay, 0, 'fast'),
        serverTimeMs: s,
        trustedNowMs: kStart,
      );
      expect(local.last.physical, lessThanOrEqualTo(s + srsClockToleranceMs));
      final HlcClock local2 = HlcClock('L2');
      local2.receive(
        const Hlc(kStart + 365 * kDay, 0, 'fast'),
        trustedNowMs: kStart,
      );
      expect(
        local2.last.physical,
        lessThanOrEqualTo(kStart + srsClockToleranceMs),
        reason: 'S 未知时只推进到本机可信时间加容差',
      );
    });

    test('快钟设备发布后超过 10 分钟的正常修改胜出（钳位只保证这个）', () async {
      final SimWorld w = SimWorld();
      final SimDevice fast = w.add('fast', skewMs: 365 * kDay);
      final SimDevice ok = w.add('ok');
      fast.edit('n', 'f/x', 'fast');
      await fast.sync();
      w.trueNow += 20 * kMinute;
      // ok 没读过 fast 的批次：两条修改并发，按排序键定生效值。
      ok.edit('n', 'f/x', 'ok');
      await w.quiesce();
      final SrsRegister r = ok.replica.store.editsOf(
        SrsEntityKind.note,
        'n',
      )['f/x']!;
      expect(r.conflicted, isTrue);
      expect(r.value, 'ok', reason: '超前事件在排序里被钳到 S + 10 分钟');
      expect(r.visibleLosers.single.value, 'fast', reason: '被覆盖的值进冲突记录');
      expect(w.check(), isEmpty);
    });
  });

  group('第六轮审查第 5 条：锚点与它自己那条 revlog 同刻', () {
    test('锚点恒排在同一毫秒的来源 revlog 之后', () {
      const int t = kStart;
      for (int i = 0; i < 50; i++) {
        final String cardId = uuidV5(srsNamespace, 'card-$i');
        final SrsReviewLog revlog = SrsReviewLog(
          id: SrsIds.importedRevlog(cardId, t),
          profileUid: kProfile,
          cardId: cardId,
          kind: SrsLogKind.review,
          rating: 3,
          hlc: srsImportedRevlogHlc(t),
          occurredAt: t,
          timeSource: SrsTimeSource.wall,
          origin: SrsLogOrigin.anki,
          reviewType: SrsReviewType.review,
          ankiRevlogId: t,
          result: const SrsScheduleResult(queue: SrsQueue.review, dueDay: 1),
        );
        final SrsReviewLog anchor = SrsReviewLog(
          id: SrsIds.importAnchor(cardId, t),
          profileUid: kProfile,
          cardId: cardId,
          kind: SrsLogKind.importAnchor,
          hlc: srsImportAnchorHlc(t),
          occurredAt: t,
          timeSource: SrsTimeSource.wall,
          origin: SrsLogOrigin.anki,
          reviewType: SrsReviewType.manual,
          result: const SrsScheduleResult(queue: SrsQueue.review, dueDay: 99),
        );
        final SrsCardHistory h = SrsCardHistory(<SrsReviewLog>[anchor, revlog]);
        expect(h.lastEffective!.id, anchor.id, reason: 'eventId 哈希不能决定先后');
        expect(h.state.dueDay, 99);
      }
    });
  });

  group('7.md A-1 / A-2：不拒收、不改事件', () {
    test('时钟走错的批次照常应用、cursor 照常推进', () async {
      final SimWorld w = SimWorld();
      final SimDevice bad = w.add('bad', skewMs: 365 * kDay);
      final SimDevice ok = w.add('ok');
      bad.edit('n', 'f/x', 'v');
      await w.quiesce();
      expect(ok.replica.syncState.cursors['bad#1'], greaterThan(0));
      expect(w.check(), isEmpty);
    });

    test('发布、快照前后事件字节相同', () async {
      final SimWorld w = SimWorld();
      final SimDevice d = w.add('d');
      final SimDevice e = w.add('e');
      final SrsReviewLog log = d.rate('card-0', 3);
      final String before = SrsLogEvent(log).canonical();
      for (int i = 0; i < 5; i++) {
        d.edit('n', 'f/x', 'v$i');
        await d.sync();
      }
      await w.quiesce();
      final SrsReviewLog got = e.replica.store.logs['card-0']![log.id]!;
      expect(SrsLogEvent(got).canonical(), before);
    });
  });

  group('HBK-AUDIT-001：起步读全部快照', () {
    test('旧目录被删后新设备仍拿到它的数据', () async {
      final SimWorld w = SimWorld();
      final SimDevice a = w.add('a');
      final SimDevice b = w.add('b');
      final SimDevice c = w.add('c');
      a.edit('n', 'f/a', 'from-a');
      await w.quiesce();
      // a 退役：之后不再同步；b / c 继续工作很久并写快照。
      w.devices.remove('a');
      for (int i = 0; i < 6; i++) {
        w.trueNow += 20 * kDay;
        b.edit('n', 'f/b', 'b$i');
        c.edit('n', 'f/c', 'c$i');
        await w.quiesce();
      }
      expect(
        w.dir.files.containsKey(a.replica.writerId),
        isFalse,
        reason: '满足两个条件后退役目录被删',
      );
      final SimDevice fresh = w.add('fresh');
      await w.quiesce();
      expect(
        fresh.replica.store.editsOf(SrsEntityKind.note, 'n')['f/a']?.value,
        'from-a',
      );
      expect(w.check(), isEmpty);
    });
  });

  group('HBK-AUDIT-002：旧备份不让已删数据复活', () {
    test('删除之后合并删除之前的备份，行仍是已删', () async {
      final SimWorld w = SimWorld();
      final SimDevice a = w.add('a');
      final SimDevice b = w.add('b');
      a.edit('n', 'f/x', 'v1');
      await w.quiesce();
      final SrsBackup oldBackup = b.replica.backup();
      a.edit('n', SrsFieldKeys.deleted, w.trueNow);
      await w.quiesce();
      // b 恢复旧备份（新化身），再同步。
      b.replica.restore(oldBackup);
      await w.quiesce();
      for (final SimDevice d in w.devices.values) {
        expect(
          d.replica.store.editsOf(SrsEntityKind.note, 'n').deletedAt,
          isNotNull,
        );
      }
      expect(w.check(), isEmpty);
    });
  });

  group('HBK-AUDIT-009：cursor 不越过缺口', () {
    test('b+1 不可见时停在 b', () async {
      // 不写快照：这里只看批次的缺口规则（有覆盖缺口的快照时见下一条）。
      final SimWorld w = SimWorld(
        options: const SrsSyncOptions(snapshotEveryBatches: 100),
      );
      final SimDevice a = w.add('a');
      final SimDevice b = w.add('b');
      // b 先同步一次成为活跃对端，a 才不会在它读完之前清理批次。
      await a.sync();
      await b.sync();
      for (int i = 0; i < 3; i++) {
        a.edit('n', 'f/x', 'v$i');
        await a.sync();
      }
      // 删掉第 2 批模拟「列表延迟 / 还没上传完」。
      final String aw = a.replica.writerId;
      final Uint8List hidden = w.dir.files[aw]!.remove(srsBatchName(2))!;
      await b.sync();
      expect(b.replica.syncState.cursors[aw], 1);
      w.dir.files[aw]![srsBatchName(2)] = hidden;
      await b.sync();
      expect(b.replica.syncState.cursors[aw], 3);
    });

    test('b+1 不在、但有覆盖到更后面的快照：读快照，不卡在 b', () async {
      // 写入者在这个目录里用快照补齐过（本机留存不够）时，缺口之后不会再有那几批。
      final SimWorld w = SimWorld();
      final SimDevice a = w.add('a');
      final SimDevice b = w.add('b');
      await a.sync();
      await b.sync();
      for (int i = 0; i < 3; i++) {
        a.edit('n', 'f/x$i', 'v');
        await a.sync();
      }
      final String aw = a.replica.writerId;
      expect(w.dir.files[aw]!.keys, contains(srsSnapshotName(3)));
      w.dir.files[aw]!.remove(srsBatchName(2));
      await b.sync();
      expect(b.replica.syncState.cursors[aw], 3);
      expect(b.replica.store.digest(), a.replica.store.digest());
    });

    test('截断的批次视为不存在', () async {
      final SimWorld w = SimWorld();
      final SimDevice a = w.add('a');
      final SimDevice b = w.add('b');
      a.edit('n', 'f/x', 'v');
      await a.sync();
      final String aw = a.replica.writerId;
      final Uint8List full = w.dir.files[aw]![srsBatchName(1)]!;
      w.dir.files[aw]![srsBatchName(1)] = Uint8List.sublistView(
        full,
        0,
        full.length - 3,
      );
      await b.sync();
      expect(b.replica.syncState.cursors[aw] ?? 0, 0);
      w.dir.files[aw]![srsBatchName(1)] = full;
      await b.sync();
      expect(b.replica.syncState.cursors[aw], 1);
    });
  });

  group('铁律 H：冲突分级', () {
    test('机器产出的并发参数组不进冲突列表（第六轮审查第 10 条）', () {
      final SrsEditWriter a = SrsEditWriter(writerId: 'A');
      final SrsEditWriter b = SrsEditWriter(writerId: 'B');
      SrsFieldEdit mk(SrsEditWriter w, String v) => w.create(
        profileUid: kProfile,
        entityKind: SrsEntityKind.deck,
        entityId: 'd',
        fieldKey: SrsFieldKeys.deckFsrs7Params,
        value: v,
        hlc: Hlc(1000, 0, w.writerId),
        timeSource: SrsTimeSource.anchored,
        machine: true,
      );
      final SrsRegister r = SrsEntityEdits.build(<SrsFieldEdit>[
        mk(a, 'pa'),
        mk(b, 'pb'),
      ])[SrsFieldKeys.deckFsrs7Params]!;
      expect(r.conflicted, isTrue);
      expect(r.visibleLosers, isEmpty);
    });

    test('删除与并发修改：删除优先、修改留作待裁决', () {
      final SrsEditWriter a = SrsEditWriter(writerId: 'A');
      final SrsEditWriter b = SrsEditWriter(writerId: 'B');
      final HlcClock ca = HlcClock('A'), cb = HlcClock('B');
      final SrsFieldEdit del = _mk(a, ca, 1000, 'x', key: SrsFieldKeys.deleted);
      final SrsFieldEdit delReal = a.create(
        profileUid: kProfile,
        entityKind: SrsEntityKind.note,
        entityId: 'n2',
        fieldKey: SrsFieldKeys.deleted,
        value: 1000,
        hlc: ca.tick(1100),
        timeSource: SrsTimeSource.wall,
      );
      final SrsFieldEdit change = b.create(
        profileUid: kProfile,
        entityKind: SrsEntityKind.note,
        entityId: 'n2',
        fieldKey: 'f/x',
        value: 'edited offline',
        hlc: cb.tick(1200),
        timeSource: SrsTimeSource.wall,
      );
      expect(del, isNotNull);
      final SrsEntityEdits edits = SrsEntityEdits.build(<SrsFieldEdit>[
        delReal,
        change,
      ]);
      expect(edits.deletedAt, 1000);
      final SrsNoteView note = srsMaterializeNotes(<SrsEntitySource>[
        SrsEntitySource.record(
          const SrsEntityRecord(
            id: 'n2',
            profileUid: kProfile,
            kind: SrsEntityKind.note,
            payload: <String, Object?>{'noteTypeId': 't', 'guid': 'g'},
          ),
          <SrsEditItem>[
            SrsEditItem.of(delReal, null),
            SrsEditItem.of(change, null),
          ],
        ),
      ]).single;
      expect(note.hasPendingDecision, isTrue);
    });
  });

  group('随机模拟（固定种子）', () {
    for (int seed = 1; seed <= 120; seed++) {
      test('seed $seed', () async {
        final List<SimOp> ops = generateOps(seed);
        final List<String> problems = await runOps(ops, seed: seed);
        if (problems.isNotEmpty) {
          final List<SimOp> minimal = await shrink(ops, seed: seed);
          fail(
            'seed $seed: $problems\n'
            'minimal repro (${minimal.length} ops): $minimal',
          );
        }
      });
    }
  });

  group('多目录（云盘 + 互联 host）', () {
    test('同一批次传到每个目录；轮流同步不来回换化身', () async {
      final SimWorld w = SimWorld(directories: 2);
      final SimDevice a = w.add('a', uses: <String>['dir0', 'dir1']);
      final SimDevice b = w.add('b', uses: <String>['dir1']);
      final SimDevice c = w.add('c', uses: <String>['dir0']);
      final String writer = a.replica.writerId;
      for (int i = 0; i < 4; i++) {
        a.edit('n', 'f/x', 'v$i');
        expect((await a.syncDir('dir0')).reincarnated, isFalse);
        expect((await a.syncDir('dir1')).reincarnated, isFalse);
        await b.sync();
        await c.sync();
        expect(b.replica.store.digest(), a.replica.store.digest());
        expect(c.replica.store.digest(), a.replica.store.digest());
      }
      expect(a.replica.writerId, writer);
      expect(w.dirs['dir0']!.files[writer]!.keys, contains(srsBatchName(4)));
      expect(w.dirs['dir1']!.files[writer]!.keys, contains(srsBatchName(4)));
    });

    test('桥：只连云盘与只连 host 的设备经两边都连的设备互通（含桥接之前的历史）', () async {
      final SimWorld w = SimWorld(directories: 2);
      final SimDevice cloud = w.add('cloud', uses: <String>['dir0']);
      final SimDevice phone = w.add('phone', uses: <String>['dir1']);
      cloud.edit('n1', 'f/x', 'from-cloud');
      phone.edit('n2', 'f/x', 'from-phone');
      await cloud.sync();
      await phone.sync();
      // 桥在两边都已有数据之后才加入。
      w.add('bridge', uses: <String>['dir0', 'dir1']);
      await w.quiesce();
      expect(w.check(), isEmpty);
      // 之后的增量经转发接上。
      cloud.edit('n1', 'f/x', 'later-cloud');
      phone.edit('n3', 'f/x', 'later-phone');
      await w.quiesce();
      expect(w.check(), isEmpty);
      expect(
        phone.replica.store
            .editsOf(SrsEntityKind.note, 'n1')['f/x']!
            .live
            .single
            .value,
        'later-cloud',
      );
    });

    test('落后得比本机留存还久的目录用快照补齐', () async {
      final SimWorld w = SimWorld(
        directories: 2,
        options: const SrsSyncOptions(
          snapshotEveryBatches: 100,
          maxSentBatches: 2,
        ),
      );
      final SimDevice a = w.add('a', uses: <String>['dir0', 'dir1']);
      final SimDevice b = w.add('b', uses: <String>['dir1']);
      await a.syncDir('dir1');
      for (int i = 0; i < 6; i++) {
        a.edit('n', 'f/x$i', 'v');
        await a.syncDir('dir0');
      }
      final SrsSyncReport r = await a.syncDir('dir1');
      expect(r.snapshotWritten, isTrue);
      await b.sync();
      expect(b.replica.store.digest(), a.replica.store.digest());
    });

    test('还没传过的目录：补齐，不换化身', () async {
      final SimWorld w = SimWorld(directories: 2);
      final SimDevice a = w.add('a', uses: <String>['dir0', 'dir1']);
      a.edit('n', 'f/x', 'v');
      await a.syncDir('dir0');
      final String writer = a.replica.writerId;
      final SrsSyncReport r = await a.syncDir('dir1');
      expect(r.reincarnated, isFalse);
      expect(a.replica.writerId, writer);
      // 从没同步过的目录不拖住本机留存：第 1 批已不再留存，用快照补齐。
      expect(r.snapshotWritten, isTrue);
      final SimDevice b = w.add('b', uses: <String>['dir1']);
      await b.sync();
      expect(b.replica.store.digest(), a.replica.store.digest());
    });

    test('同步过的目录拖住留存：之后的批次逐批补传，不写快照', () async {
      final SimWorld w = SimWorld(
        directories: 2,
        options: const SrsSyncOptions(snapshotEveryBatches: 100),
      );
      final SimDevice a = w.add('a', uses: <String>['dir0', 'dir1']);
      await a.syncDir('dir0');
      await a.syncDir('dir1');
      for (int i = 0; i < 3; i++) {
        a.edit('n', 'f/x$i', 'v');
        await a.syncDir('dir0');
      }
      final SrsSyncReport r = await a.syncDir('dir1');
      expect(r.snapshotWritten, isFalse);
      final String writer = a.replica.writerId;
      expect(w.dirs['dir1']!.files[writer]!.keys, contains(srsBatchName(3)));
    });

    test('在某个目录里被当作退役清理过：换新化身', () async {
      final SimWorld w = SimWorld(directories: 2);
      final SimDevice a = w.add('a', uses: <String>['dir0', 'dir1']);
      a.edit('n', 'f/x', 'v');
      await a.syncDir('dir0');
      await a.syncDir('dir1');
      final String old = a.replica.writerId;
      w.dirs['dir1']!.files.remove(old);
      final SrsSyncReport r = await a.syncDir('dir1');
      expect(r.reincarnated, isTrue);
      expect(a.replica.writerId, isNot(old));
    });

    test('旧版本的本机状态（不分目录记账）：找不到本写入者的目录按退役处理', () async {
      final SimWorld w = SimWorld(directories: 2);
      final SimDevice a = w.add('a', uses: <String>['dir0', 'dir1']);
      a.edit('n', 'f/x', 'v');
      await a.syncDir('dir0');
      final SrsSyncLocalState st = a.replica.syncState
        ..directories.clear()
        ..legacyDirectories = true;
      await a.replica.saveSyncState(st);
      final String old = a.replica.writerId;
      expect((await a.syncDir('dir0')).reincarnated, isFalse);
      expect((await a.syncDir('dir1')).reincarnated, isTrue);
      expect(a.replica.writerId, isNot(old));
      expect(a.replica.syncState.legacyDirectories, isFalse);
      final SimDevice b = w.add('b', uses: <String>['dir1']);
      await w.quiesce();
      expect(b.replica.store.digest(), a.replica.store.digest());
    });
  });

  for (final (String name, SimTopology topology) in <(String, SimTopology)>[
    ('桥接拓扑', kBridgeTopology),
    ('三台都连两个目录', kDualTopology),
  ]) {
    group('随机模拟（固定种子，$name）', () {
      for (int seed = 1; seed <= 60; seed++) {
        test('seed $seed', () async {
          final List<SimOp> ops = generateOps(seed);
          final List<String> problems = await runOps(
            ops,
            seed: seed,
            topology: topology,
          );
          if (problems.isNotEmpty) {
            final List<SimOp> minimal = await shrink(
              ops,
              seed: seed,
              topology: topology,
            );
            fail(
              'seed $seed: $problems\n'
              'minimal repro (${minimal.length} ops): $minimal',
            );
          }
        });
      }
    });
  }

  group('发件箱按 maxEventsPerBatch 切批', () {
    test('一轮里多于上限的事件切成连续几批，对端逐批应用后收敛', () async {
      final SimWorld w = SimWorld(
        options: const SrsSyncOptions(
          snapshotEveryBatches: 100,
          maxEventsPerBatch: 2,
        ),
      );
      final SimDevice a = w.add('a');
      final SimDevice b = w.add('b');
      for (int i = 0; i < 5; i++) {
        a.edit('n$i', 'f/x', 'v$i');
      }
      await a.sync();
      final String aw = a.replica.writerId;
      final Iterable<int> nos = w.dir.files[aw]!.keys
          .map(srsParseBatchName)
          .whereType<int>();
      expect(nos.length, greaterThanOrEqualTo(3));
      for (final int n in nos) {
        final SrsBatch batch = SrsBatch.decode(
          w.dir.files[aw]![srsBatchName(n)]!,
        )!;
        expect(batch.events.length, lessThanOrEqualTo(2));
      }
      await b.sync();
      expect(b.replica.store.digest(), a.replica.store.digest());
    });

    for (final (String name, SimTopology? topology) in <(String, SimTopology?)>[
      ('单目录', null),
      ('三台都连两个目录', kDualTopology),
    ]) {
      group('随机模拟（固定种子，每批 1 条，$name）', () {
        for (int seed = 1; seed <= 30; seed++) {
          test('seed $seed', () async {
            final List<String> problems = await runOps(
              generateOps(seed),
              seed: seed,
              topology: topology,
              options: const SrsSyncOptions(
                snapshotEveryBatches: 3,
                maxEventsPerBatch: 1,
              ),
            );
            expect(problems, isEmpty, reason: 'seed $seed');
          });
        }
      });
    }
  });

  test('目录：探针文件写在写入者自己的目录', () async {
    final MemorySyncDirectory dir = MemorySyncDirectory(serverNow: () => 1);
    await dir.serverTime('w1');
    expect(dir.files['w1']!.containsKey(srsProbeName), isTrue);
    expect(dir.files.keys, <String>['w1']);
  });
}
