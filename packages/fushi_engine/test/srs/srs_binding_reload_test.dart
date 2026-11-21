// SrsDbStore 的绑定代号与绑定变化后的重读（G7-5b 复核修复）：
// - 重开不重复写三个内置实体（补盐换库之后也一样；内置 ID 是不带盐的规范 ID，G9-7。存量带盐内置实体的那一半在
//   srs_id_derivation_e2e_test.dart）；
// - RWKV 分数表的清空键在进程内换库（补盐）时也变、同一绑定重开不变；
// - 辅助进程重新激活时按绑定代号（含盐）发现变化；
// - 绑定变化后重读失败不吞掉已提交命令的回包，下一条命令之前补读；
// - 副本作废时关掉 bindingChanges。
import 'dart:async';
import 'dart:io';

import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import 'apkg/apkg_test_support.dart' show FakeFsrsEngine;

const String kProfileA = '01928c3e-0000-7000-8000-00000000000a';
const String kExtraSalt = '01928c3e-0000-7000-8000-0000000000ff';

void main() {
  final int now = DateTime.utc(2026, 11, 17, 3).millisecondsSinceEpoch;
  late Directory dir;
  final List<SrsStorage> opened = <SrsStorage>[];

  setUp(() {
    dir = Directory.systemTemp.createTempSync('srs_binding_reload_');
  });

  tearDown(() async {
    for (final SrsStorage s in opened.reversed) {
      await s.close();
    }
    opened.clear();
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows 句柄滞后：留给系统清理。
    }
  });

  Future<SrsStorage> storage(SrsOpenMode mode) async {
    final SrsStorage s = await SrsStorage.open(directory: dir.path, mode: mode);
    opened.add(s);
    return s;
  }

  Future<SrsDbStore> open(SrsStorage s, String profile) => SrsDbStore.open(
    core: s.core,
    profileUid: profile,
    deviceId: 'legacy-device-ignored',
    engine: const FakeFsrsEngine(),
    trustedClock: SrsTrustedClock(
      wallClockMs: () => now,
      bootClockMs: () => now,
      bootId: 'boot',
    ),
    fallbackRolloverHour: () => 4,
    localOffsetMin: () => 0,
  );

  Future<Map<String, Object?>> addSalt(SrsDbStore s) async =>
      (await s.sync2Command(<String, Object?>{
        'op': 'collection_salts_add',
        'salts': <String>[kExtraSalt],
        'now': now,
      })).map;

  test('重开不重复写内置实体：补盐换库之后也只认已有的那一份', () async {
    final SrsStorage primary = await storage(SrsOpenMode.primary);
    final SrsDbStore first = await open(primary, kProfileA);
    // G9-7 起 Dart 向内核要的内置 ID 就是规范 ID（不带盐），读回来的也是它。
    expect(first.kernelIds.defaultDeck, first.defaultDeckId);
    final String afterFirst = await first.changeFingerprint();
    final SrsDbStore second = await open(primary, kProfileA);
    expect(
      await second.changeFingerprint(),
      afterFirst,
      reason: 'reopening writes nothing: the builtins are already there',
    );
    // 补盐（`bindingChanged`，别的盐算出的成员也归过来）：内置 ID 不变，重开照样不写。
    expect((await addSalt(second))['outcome'], 'saltsAdded');
    expect(second.defaultDeckId, first.defaultDeckId);
    final String afterSalt = await second.changeFingerprint();
    final SrsDbStore third = await open(primary, kProfileA);
    expect(third.defaultDeckId, first.defaultDeckId);
    expect(
      await third.changeFingerprint(),
      afterSalt,
      reason: 'reopening after a salt was added writes nothing either',
    );
    final SrsDeckTree tree = await third.deckTree();
    expect(
      tree.decks.where((SrsDeckView d) => d.id == third.defaultDeckId),
      hasLength(1),
    );
  });

  test('RWKV 清空键：进程内补盐之后变，同一绑定重开不变', () async {
    final SrsStorage primary = await storage(SrsOpenMode.primary);
    final SrsDbStore a = await open(primary, kProfileA);
    final String clearBefore = a.rwkvScoresClearKey;
    final String bindingBefore = a.bindingKey!;
    final String collectionBefore = a.sync2Collection!;

    expect((await addSalt(a))['outcome'], 'saltsAdded');
    expect(a.sync2Collection, collectionBefore, reason: 'salts keep the col');
    expect(a.bindingKey, isNot(bindingBefore));
    expect(
      a.rwkvScoresClearKey,
      isNot(clearBefore),
      reason: 'the epoch does not change in-process; the binding key must',
    );

    final SrsDbStore again = await open(primary, kProfileA);
    expect(again.bindingKey, a.bindingKey);
    expect(again.rwkvScoresClearKey, a.rwkvScoresClearKey);
  });

  test('辅助进程重新激活：只补了盐（集合 / 目录没变）也按绑定变化处理', () async {
    final SrsStorage primary = await storage(SrsOpenMode.primary);
    final SrsDbStore a = await open(primary, kProfileA);
    final SrsStorage secondary = await storage(SrsOpenMode.secondary);
    final SrsDbStore readOnly = await open(secondary, kProfileA);
    expect(readOnly.bindingKey, a.bindingKey);

    await addSalt(a);
    await readOnly.refreshIdentity();
    expect(readOnly.debugBindingChanges, 1);
    expect(readOnly.bindingKey, a.bindingKey);
    expect(readOnly.defaultDeckId, a.defaultDeckId);

    // 再激活一次、没有变化：不报。
    await readOnly.refreshIdentity();
    expect(readOnly.debugBindingChanges, 1);
  });

  test('绑定变化后重读失败：已提交命令的回包照常返回，下一条命令之前补读', () async {
    final SrsStorage primary = await storage(SrsOpenMode.primary);
    final SrsDbStore a = await open(primary, kProfileA);
    final String bindingBefore = a.bindingKey!;
    a.debugBindingReloadFailure = StateError('injected reload failure');

    expect((await addSalt(a))['outcome'], 'saltsAdded');
    expect(a.debugBindingStale, isTrue);
    expect(a.bindingKey, bindingBefore, reason: 'not re-read yet');

    final SrsDeckTree tree = await a.deckTree();
    expect(a.debugBindingStale, isFalse);
    expect(a.bindingKey, isNot(bindingBefore));
    expect(tree.decks.map((SrsDeckView d) => d.id), contains(a.defaultDeckId));
  });

  test('副本作废时关掉 bindingChanges', () async {
    final SrsStorage primary = await storage(SrsOpenMode.primary);
    final SrsDbStore a = await open(primary, kProfileA);
    final Completer<void> done = Completer<void>();
    final StreamSubscription<void> sub = a.bindingChanges.listen(
      (_) {},
      onDone: done.complete,
    );
    addTearDown(sub.cancel);
    await a.retire<void>(() async {}, reason: 'test');
    await done.future.timeout(const Duration(seconds: 5));
    expect(done.isCompleted, isTrue);
  });
}
