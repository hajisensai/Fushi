// 同步 v2 的一轮（docs/specs/2026-10-25-srs-sync-v2-design.md §6.2）在真实 SrsDbStore（各自一份 srs.db）上：
// 两台设备经哑存储（内存 / 本地文件夹 / 现有后端接口包的本地目录）互通；离线并发复习同一张卡，合并后
// 每一次复习都算数、两端状态逐字节相同、摘要相同。
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_engine/srs/sync2/srs_location_store.dart';
import 'package:fushi_engine/srs/sync2/srs_sync2_round.dart';
import 'package:fushi_engine/sync/local_directory_asset_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import '../support/srs_test_storage.dart';

const String kProfile = '01928c3e-0000-7000-8000-0000000000dd';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  Future<SrsDbStore> device(String id) async {
    final SrsStorage st = await openTestSrsStorage();
    return SrsDbStore.open(
      db: st.db,
      core: st.core,
      profileUid: kProfile,
      deviceId: id,
      engine: FfiFsrsEngine.tryCreate(),
    );
  }

  Future<String> addNote(SrsDbStore s, String expression) => s.createNote(
    noteTypeId: s.lapisNoteTypeId,
    fieldsById: <String, String>{
      srsLapisFieldId(kProfile, 'Expression'): expression,
    },
  );

  Future<SrsSync2Report> round(SrsDbStore s, SrsLocationStore loc) =>
      srsSync2Round(
        host: s,
        location: loc,
        locationId: 'loc',
        nowMs: () => DateTime.now().millisecondsSinceEpoch,
      );

  Future<String> stateOf(SrsDbStore s, String card) async =>
      srsCanonicalJson((await s.history(card)).state.toJson());

  for (final (String name, SrsLocationStore Function(Directory) make)
      in <(String, SrsLocationStore Function(Directory))>[
        ('memory', (_) => SrsMemoryLocationStore()),
        ('local folder', (Directory d) => SrsDirectoryLocationStore(d)),
        (
          'SyncAssetStore adapter',
          (Directory d) => SrsAssetLocationStore(
            store: LocalDirectoryAssetStore(d),
            profileUid: kProfile,
          ),
        ),
      ]) {
    test('$name：两台设备收敛，离线并发复习同一张卡三次都算数', () async {
      final Directory dir = Directory.systemTemp.createTempSync('srs2_loc_');
      addTearDown(() {
        try {
          dir.deleteSync(recursive: true);
        } on FileSystemException {
          // 句柄滞后。
        }
      });
      final SrsLocationStore loc = make(dir);
      final SrsDbStore a = await device('A');
      final SrsDbStore b = await device('B');
      final String note = await addNote(a, '雪');
      await round(a, loc);
      await round(b, loc);
      expect(await b.note(note), isNotNull, reason: 'B received the note');
      final String card = (await a.cardsOfNote(note)).first.id;
      expect(<String>[
        for (final c in await b.cardsOfNote(note)) c.id,
      ], contains(card));

      // 离线：A 复习一次，B 复习一次，A 再复习一次。
      await a.answer(card, 3);
      await b.answer(card, 2);
      await a.answer(card, 1);
      for (int i = 0; i < 2; i++) {
        await round(a, loc);
        await round(b, loc);
      }
      final String sa = await stateOf(a, card);
      expect(await stateOf(b, card), sa);
      expect((await a.history(card)).effective.length, 3);
      expect(
        (await a.sync2Digest())['digest'],
        (await b.sync2Digest())['digest'],
      );
      final Map<String, Object?> status = await a.sync2Status();
      expect(status['pending'], 0);
    });
  }

  test('哑存储：head 先于段可见 / 段暂时列不到，只少收、不坏，下一轮补齐', () async {
    final _FlakyStore loc = _FlakyStore();
    final SrsDbStore a = await device('A');
    final SrsDbStore b = await device('B');
    final String note = await addNote(a, '雨');
    await round(a, loc);
    loc.hideSegments = true;
    final SrsSync2Report r = await round(b, loc);
    expect(r.applied, 0);
    expect(await b.note(note), isNull);
    loc.hideSegments = false;
    await round(b, loc);
    expect(await b.note(note), isNotNull);
  });

  // 反馈：iPhone 连着 Windows host 时复习同步一轮接一轮不停——每轮都写新 head（再删旧 head），host 按 head 写入
  // 推进长轮询令牌，写的设备自己被唤醒再跑一轮。没变的一轮不能往位置写任何东西。
  test('没有新东西的一轮不写 head、不删旧 head；head 不见了才补写', () async {
    final _CountingStore loc = _CountingStore();
    final SrsDbStore a = await device('A');
    final SrsDbStore b = await device('B');
    await addNote(a, '風');
    await round(a, loc);
    await round(b, loc);
    // 各自再跑到稳定（B 收了 A 的数据，ack 变了要发一次；A 收到 B 的 ack 也一样）。
    for (int i = 0; i < 2; i++) {
      await round(a, loc);
      await round(b, loc);
    }
    loc.writes.clear();
    final SrsSync2Report quiet = await round(a, loc);
    expect(loc.writes, isEmpty, reason: 'nothing changed: no put / delete');
    expect(quiet.uploaded, 0);
    expect(quiet.serverTimeMs, isNull);

    // 本机有新操作：段与 head 照发。
    await addNote(a, '光');
    await round(a, loc);
    expect(
      loc.writes.where((String w) => w.contains('/head-')),
      isNotEmpty,
      reason: 'a new op publishes a new head',
    );

    // 位置上本机的 head 被清掉了（写之前断网 / 别的工具删了）：没变也补写。
    loc.files.removeWhere(
      (String path, Uint8List _) =>
          path.contains('/head-') && path.contains(a.sync2Device!),
    );
    loc.writes.clear();
    await round(a, loc);
    expect(
      loc.writes.where(
        (String w) => w.startsWith('put') && w.contains('/head-'),
      ),
      isNotEmpty,
    );
  });
}

/// 记下全部写 / 删（`put <path>` / `delete <path>`）。
class _CountingStore extends SrsMemoryLocationStore {
  final List<String> writes = <String>[];

  @override
  Future<void> put(String path, Uint8List bytes) {
    writes.add('put $path');
    return super.put(path, bytes);
  }

  @override
  Future<void> delete(String path) {
    writes.add('delete $path');
    return super.delete(path);
  }
}

/// 模拟最终一致的列目录：段文件暂时读不到（head 已可见）。
class _FlakyStore extends SrsMemoryLocationStore {
  bool hideSegments = false;

  @override
  Future<Uint8List?> get(String path) async =>
      hideSegments && path.contains('/seg-') ? null : super.get(path);
}
