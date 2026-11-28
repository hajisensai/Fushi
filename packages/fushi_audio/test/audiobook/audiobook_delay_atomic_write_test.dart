import 'package:drift/native.dart';
import 'package:fushi_audio/src/audiobook/audiobook_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:test/test.dart';

/// BUG-5610：有声书调轴 `audiobook_delay_<key>` 与它的 LWW 戳
/// `audiobook_delay_at_<key>` 是一对，本机写与对端落地都必须「同一事务比较后
/// 写入」。旧实现 [AudiobookRepository.updateDelayMs] 是两次独立 `setPrefTyped`，
/// 同步侧 / host PUT 是「先读后写」。
void main() {
  late FushiDatabase db;
  late AudiobookRepository repo;

  const String valueKey = 'audiobook_delay_Book';
  const String stampKey = 'audiobook_delay_at_Book';

  setUp(() {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    repo = AudiobookRepository(db);
  });

  tearDown(() => db.close());

  Future<int> prefsVersion() =>
      db.getPrefTyped<int>(FushiDatabase.prefsVersionKey, 0);

  group('本机调轴 updateDelayMs', () {
    test('戳写失败时值一起回滚（值与戳同事务）', () async {
      await repo.updateDelayMs(bookKey: 'Book', ms: 300);
      final int stamp = await repo.readDelayUpdatedAtMs('Book');
      expect(stamp, greaterThan(0));
      await db.customStatement(
        'CREATE TRIGGER fail_stamp BEFORE INSERT ON preferences '
        "WHEN NEW.key = '$stampKey' "
        "BEGIN SELECT RAISE(ABORT, 'injected'); END",
      );

      await expectLater(
        repo.updateDelayMs(bookKey: 'Book', ms: -500),
        throwsA(anything),
      );

      await db.customStatement('DROP TRIGGER fail_stamp');
      expect(await repo.readDelayMs('Book'), 300, reason: '调轴值不能脱离它的戳单独落库');
      expect(await repo.readDelayUpdatedAtMs('Book'), stamp);
    });

    test('一次调轴是一次提交：偏好版本号只自增一次', () async {
      final int v0 = await prefsVersion();
      await repo.updateDelayMs(bookKey: 'Book', ms: 300);
      expect(await prefsVersion() - v0, 1);
      expect(await repo.readDelayMs('Book'), 300);
      expect(await repo.readDelayUpdatedAtMs('Book'), greaterThan(0));
    });

    test('值没变不重盖戳（否则会无故压过对端真实的更新调轴）', () async {
      await repo.updateDelayMs(bookKey: 'Book', ms: 300);
      final int stamp = await repo.readDelayUpdatedAtMs('Book');
      final int version = await prefsVersion();

      await repo.updateDelayMs(bookKey: 'Book', ms: 300);

      expect(await repo.readDelayUpdatedAtMs('Book'), stamp);
      expect(await prefsVersion(), version);
    });

    test('已存戳来自时钟偏快的对端时，本机新调轴的戳仍严格更新', () async {
      final int future = DateTime.now().millisecondsSinceEpoch + 4 * 60 * 1000;
      await db.setPrefs(<String, String>{
        valueKey: PrefCodec.encode(800),
        stampKey: PrefCodec.encode(future),
      });

      await repo.updateDelayMs(bookKey: 'Book', ms: -200);

      expect(await repo.readDelayMs('Book'), -200);
      expect(
        await repo.readDelayUpdatedAtMs('Book'),
        greaterThan(future),
        reason: '戳不比对端旧戳新，下一轮 LWW 会把用户刚调的值拉回 800',
      );
    });
  });

  group('对端落地 applyStampedIntPrefIfNewer', () {
    test('旧戳写入不覆盖新值', () async {
      await repo.updateDelayMs(bookKey: 'Book', ms: 300);
      final int stamp = await repo.readDelayUpdatedAtMs('Book');

      final bool wrote = await db.applyStampedIntPrefIfNewer(
        valueKey: valueKey,
        stampKey: stampKey,
        value: 9000,
        stampMs: stamp - 1,
      );

      expect(wrote, isFalse);
      expect(await repo.readDelayMs('Book'), 300);
      expect(await repo.readDelayUpdatedAtMs('Book'), stamp);
    });

    test('平局保留已存值', () async {
      await repo.updateDelayMs(bookKey: 'Book', ms: 300);
      final int stamp = await repo.readDelayUpdatedAtMs('Book');

      expect(
        await db.applyStampedIntPrefIfNewer(
          valueKey: valueKey,
          stampKey: stampKey,
          value: 9000,
          stampMs: stamp,
        ),
        isFalse,
      );
      expect(await repo.readDelayMs('Book'), 300);
    });

    test('严格较新的对端值连同它的戳一次提交落地', () async {
      await repo.updateDelayMs(bookKey: 'Book', ms: 300);
      final int stamp = await repo.readDelayUpdatedAtMs('Book');
      final int v0 = await prefsVersion();

      expect(
        await db.applyStampedIntPrefIfNewer(
          valueKey: valueKey,
          stampKey: stampKey,
          value: -1200,
          stampMs: stamp + 10,
        ),
        isTrue,
      );
      expect(await repo.readDelayMs('Book'), -1200);
      expect(await repo.readDelayUpdatedAtMs('Book'), stamp + 10);
      expect(await prefsVersion() - v0, 1);
    });

    test('与本机调轴并发：拿着过期快照的对端值盖不掉本机刚写的新值', () async {
      await repo.updateDelayMs(bookKey: 'Book', ms: 300);
      final int snapshotStamp = await repo.readDelayUpdatedAtMs('Book');

      // 本机调轴先发出；对端值的戳只比快照新，比本机这次写入旧。
      final Future<void> local = repo.updateDelayMs(bookKey: 'Book', ms: 700);
      final Future<bool> remote = db.applyStampedIntPrefIfNewer(
        valueKey: valueKey,
        stampKey: stampKey,
        value: 9000,
        stampMs: snapshotStamp + 1,
      );
      await local;

      expect(await remote, isFalse);
      expect(await repo.readDelayMs('Book'), 700);
    });
  });
}
