// 坏文件（自校验通过、内容解不出来）不能拖垮整轮同步（BUG-3563 的 host 一侧）。
//
// host 读的是所有已配对设备写进来的文件：以前某台设备写出头部字段类型不对的批次，`SrsBatch.decode`
// 抛 TypeError，整轮 syncOnce 中止，此后每一轮都中止在同一个文件上。现在：解码返回 SrsFileMalformed，
// 引擎跳过它、记进报告，其它写入者照常同步；坏批次本身不跳过（跳过 = 丢数据还谎报 cursor），
// 有覆盖它的快照时改读快照接上。
import 'dart:convert';
import 'dart:typed_data';

import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import 'simulator/simulator.dart';

/// 把一个完好文件的头部字段改坏：正文不动，自校验（长度 + 正文 SHA-256）照样通过。
Uint8List _corruptHeader(Uint8List valid, String key, Object? value) {
  final int nl = valid.indexOf(0x0a);
  final Map<String, Object?> header =
      (jsonDecode(utf8.decode(valid.sublist(0, nl))) as Map)
          .cast<String, Object?>();
  header[key] = value;
  return Uint8List.fromList(<int>[
    ...utf8.encode(jsonEncode(header)),
    ...valid.sublist(nl),
  ]);
}

void main() {
  group('解码：不完整与内容坏了分开报', () {
    test('头部字段类型不对 → SrsFileMalformed（不抛）；截断 → SrsFileIncomplete', () {
      final Uint8List ok = const SrsBatch(
        writerId: 'w#1',
        no: 1,
        serverTimeMs: 5,
        events: <SrsEvent>[],
      ).encode();
      expect(SrsBatch.tryDecode(ok), isA<SrsFileOk<SrsBatch>>());
      final Uint8List bad = _corruptHeader(ok, 'no', 'one');
      expect(SrsBatch.tryDecode(bad), isA<SrsFileMalformed<SrsBatch>>());
      expect(SrsBatch.decode(bad), isNull);
      final Uint8List badFs = _corruptHeader(ok, 'fs', <String, Object?>{
        'e': 'x',
      });
      expect(SrsBatch.tryDecode(badFs), isA<SrsFileMalformed<SrsBatch>>());
      expect(
        SrsBatch.tryDecode(Uint8List.sublistView(ok, 0, ok.length - 1)),
        isA<SrsFileIncomplete<SrsBatch>>(),
      );
      final Uint8List cursor = const SrsCursorFile(
        writerId: 'w#1',
        cursors: <String, int>{'x': 1},
        updatedAtMs: 1,
      ).encode();
      expect(
        SrsCursorFile.tryDecode(_corruptHeader(cursor, 'at', 'late')),
        isA<SrsFileMalformed<SrsCursorFile>>(),
      );
    });
  });

  group('引擎：坏文件跳过、记报告、不阻塞其它写入者', () {
    test('坏批次：整轮不中止，别的写入者照常应用；坏批次处停住，修好后接上', () async {
      final SimWorld w = SimWorld(
        options: const SrsSyncOptions(snapshotEveryBatches: 100),
      );
      final SimDevice a = w.add('a');
      final SimDevice c = w.add('c');
      final SimDevice b = w.add('b');
      await a.sync();
      await c.sync();
      await b.sync();
      for (int i = 0; i < 3; i++) {
        a.edit('n', 'f/x', 'v$i');
        await a.sync();
      }
      c.edit('m', 'f/y', 'from c');
      await c.sync();
      final String aw = a.replica.writerId;
      final String cw = c.replica.writerId;
      final Uint8List good = w.dir.files[aw]![srsBatchName(2)]!;
      w.dir.files[aw]![srsBatchName(2)] = _corruptHeader(good, 's', 'noon');

      final SrsSyncReport r = await b.sync();
      expect(r.error, isNull);
      expect(r.skippedFiles, contains(startsWith('$aw/${srsBatchName(2)}: ')));
      expect(b.replica.syncState.cursors[aw], 1, reason: '不跳过坏批次');
      expect(b.replica.syncState.cursors[cw], greaterThanOrEqualTo(1));
      // 本机自己的发布也照常完成（cursor 文件写出 = 走完了整轮）。
      expect(w.dir.files[b.replica.writerId]!.keys, contains(srsCursorName));
      // 坏文件不删。
      expect(w.dir.files[aw]![srsBatchName(2)], isNot(good));

      w.dir.files[aw]![srsBatchName(2)] = good;
      final SrsSyncReport r2 = await b.sync();
      expect(r2.skippedFiles, isEmpty);
      expect(b.replica.syncState.cursors[aw], 3);
    });

    test('坏批次之后有覆盖它的快照：改读快照接上', () async {
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
      w.dir.files[aw]![srsBatchName(2)] = _corruptHeader(
        w.dir.files[aw]![srsBatchName(2)]!,
        'writer',
        42,
      );
      final SrsSyncReport r = await b.sync();
      expect(r.skippedFiles, isNotEmpty);
      expect(b.replica.syncState.cursors[aw], 3);
      expect(b.replica.store.digest(), a.replica.store.digest());
    });

    test('坏的 cursor 文件：按没有 cursor 文件处理，整轮照常', () async {
      final SimWorld w = SimWorld();
      final SimDevice a = w.add('a');
      final SimDevice b = w.add('b');
      a.edit('n', 'f/x', 'v');
      await a.sync();
      final String aw = a.replica.writerId;
      w.dir.files[aw]![srsCursorName] = _corruptHeader(
        w.dir.files[aw]![srsCursorName]!,
        'at',
        'yesterday',
      );
      final SrsSyncReport r = await b.sync();
      expect(r.error, isNull);
      expect(r.skippedFiles, contains(startsWith('$aw/$srsCursorName: ')));
      expect(b.replica.syncState.cursors[aw], 1);
    });
  });
}
