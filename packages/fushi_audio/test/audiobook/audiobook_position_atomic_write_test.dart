import 'package:drift/native.dart';
import 'package:fushi_audio/src/audiobook/audiobook_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:test/test.dart';

/// BUG-4825：有声书播放位置与它的时间戳是一对，必须同一次提交。
///
/// 旧实现是「读位置 → 写位置 → 写时间戳」三次独立的库操作：同步侧的「比较后写入」
/// （[FushiDatabase.runIfIntPrefUnchanged]）把这两个键当一对，能插进两次写之间；
/// 进程死在两次写之间则落下「新位置 + 旧时间戳」。
void main() {
  late FushiDatabase db;
  late AudiobookRepository repo;

  setUp(() {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    repo = AudiobookRepository(db);
  });

  tearDown(() => db.close());

  Future<int> prefsVersion() =>
      db.getPrefTyped<int>(FushiDatabase.prefsVersionKey, 0);

  test('a stamp write that fails takes the position write down with '
      'it', () async {
    await repo.updatePositionMs(bookKey: 'Book', positionMs: 1000);
    final int stamp = await repo.readPositionUpdatedAtMs('Book');
    expect(stamp, greaterThan(0));
    await db.customStatement(
      'CREATE TRIGGER fail_stamp BEFORE INSERT ON preferences '
      "WHEN NEW.key = 'audiobook_pos_at_Book' "
      "BEGIN SELECT RAISE(ABORT, 'injected'); END",
    );

    await expectLater(
      repo.updatePositionMs(bookKey: 'Book', positionMs: 2000),
      throwsA(anything),
    );

    await db.customStatement('DROP TRIGGER fail_stamp');
    expect(await repo.readPositionMs('Book'), 1000, reason: '位置不能脱离它的时间戳单独落库');
    expect(await repo.readPositionUpdatedAtMs('Book'), stamp);
  });

  test('one position change is one commit: a single prefs-version '
      'bump', () async {
    final int v0 = await prefsVersion();
    await repo.updatePositionMs(bookKey: 'Book', positionMs: 1000);
    final int v1 = await prefsVersion();
    expect(v1 - v0, 1);
    expect(await repo.readPositionMs('Book'), 1000);
    expect(await repo.readPositionUpdatedAtMs('Book'), greaterThan(0));
  });

  test('an unchanged position writes nothing (BUG-2328)', () async {
    await repo.updatePositionMs(bookKey: 'Book', positionMs: 1000);
    final int stamp = await repo.readPositionUpdatedAtMs('Book');
    final int version = await prefsVersion();

    await repo.updatePositionMs(bookKey: 'Book', positionMs: 1000);

    expect(await repo.readPositionUpdatedAtMs('Book'), stamp);
    expect(await prefsVersion(), version);
  });

  test('a compare-and-write on the stamp never lands between the two '
      'halves', () async {
    await repo.updatePositionMs(bookKey: 'Book', positionMs: 1000);
    final int stamp = await repo.readPositionUpdatedAtMs('Book');

    // 同步侧按旧时间戳做「比较后写入」，与本机播放器的写入并发发出。
    final Future<void> local = repo.updatePositionMs(
      bookKey: 'Book',
      positionMs: 2000,
    );
    final Future<bool> remote = db.runIfIntPrefUnchanged(
      stampKey: 'audiobook_pos_at_Book',
      expectedStamp: stamp,
      write: () => db.setPrefs(<String, String>{
        'audiobook_pos_Book': PrefCodec.encode(9000),
        'audiobook_pos_at_Book': PrefCodec.encode(stamp + 1),
      }),
    );
    await local;

    // 本机的「比 → 写 → 写」是一个事务、先发出就先整段跑完：对端重读时间戳时
    // 已经看得到本机这次写入，旧决策作废。
    expect(await remote, isFalse);
    expect(await repo.readPositionMs('Book'), 2000);
  });
}
