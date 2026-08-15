import 'package:drift/drift.dart' show QueryRow, Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

/// v84（BUG-1502）：`preferences` 加 `updated_at`，让「是内容的偏好行」——书改名的
/// `override_title://` 覆盖行——能跨端 last-write-wins。
///
/// 本文件守两件事：
///  1. **迁移无损 + 存量行戳 0**。0 =「时刻未知」是刻意取舍：填迁移时刻会让跨端
///     「谁赢」由两台设备各自的升级时间决定（后升级的一侧无条件覆盖先升级的一侧，
///     用户什么都没做），取 0 则存量行彼此平局 → LWW 平局规则「保留本机」正好等于
///     升级前的 insert-if-absent 行为，零回归。
///  2. **[FushiDatabase.setPrefIfNewer] 的三条裁决**（严格更新才写 / 平局保留本机 /
///     行不存在无条件采纳），以及本地写入 [FushiDatabase.setPref] 恒戳 now。
const String _overrideKey =
    'src:reader_fushi:override_title://fushi://book/MyBook';

/// v83 形状的 `preferences`：**只有 key/value 两列**。
void _seedV83(dynamic rawDb) {
  rawDb.execute('''
CREATE TABLE preferences (
  key TEXT NOT NULL PRIMARY KEY,
  value TEXT NOT NULL
)
''');
  rawDb.execute(
    'INSERT INTO preferences (key, value) VALUES '
    "('$_overrideKey', 's:母设备改的名'), "
    "('theme', 's:dark')",
  );
  rawDb.execute('PRAGMA user_version = 83');
}

Future<int> _updatedAtOf(FushiDatabase db, String key) async {
  final QueryRow row = await db.customSelect(
    'SELECT updated_at FROM preferences WHERE key = ?',
    variables: <Variable<Object>>[Variable<String>(key)],
  ).getSingle();
  return row.read<int>('updated_at');
}

void main() {
  FushiDatabase openUpgraded() {
    final FushiDatabase db =
        FushiDatabase.forTesting(NativeDatabase.memory(setup: _seedV83));
    addTearDown(db.close);
    return db;
  }

  test('v83 -> v84：加列无损，存量偏好行一条不丢且戳 0（=时刻未知）', () async {
    final FushiDatabase db = openUpgraded();

    final QueryRow version =
        await db.customSelect('PRAGMA user_version').getSingle();
    expect(version.read<int>('user_version'), 87);
    expect(db.schemaVersion, 87);

    // 存量行零丢失——改名是用户数据，迁移丢一行就是丢一个书名。
    expect(await db.getPref(_overrideKey), 's:母设备改的名');
    expect(await db.getPref('theme'), 's:dark');

    // 取舍断言：存量行 = 0，不是迁移时刻。
    expect(
      await _updatedAtOf(db, _overrideKey),
      0,
      reason: '存量行戳迁移时刻会让「谁赢」由两台设备的升级时间决定',
    );
    expect(await _updatedAtOf(db, 'theme'), 0);
  });

  test('本地写入恒戳 now：setPref / setPrefs / compareAndSetPref', () async {
    final FushiDatabase db = openUpgraded();
    final int before = DateTime.now().millisecondsSinceEpoch;

    await db.setPref(_overrideKey, 's:本机改的名');
    final int stamped = await _updatedAtOf(db, _overrideKey);
    expect(stamped, greaterThanOrEqualTo(before));

    await db.setPrefs(<String, String>{'a': 's:1', 'b': 's:2'});
    expect(await _updatedAtOf(db, 'a'), greaterThanOrEqualTo(before));
    // 一组多键是一个逻辑设置，戳必须一致。
    expect(await _updatedAtOf(db, 'a'), await _updatedAtOf(db, 'b'));

    expect(
      await db.compareAndSetPref('a', expectedValue: 's:1', newValue: 's:9'),
      isTrue,
    );
    expect(await _updatedAtOf(db, 'a'), greaterThanOrEqualTo(before));
  });

  test('setPrefIfNewer：严格更新才写 / 平局保留本机 / 更旧不写', () async {
    final FushiDatabase db = openUpgraded();
    await db.setPrefIfNewer(_overrideKey, 's:本机', updatedAt: 1000);

    // 更旧 → 不写。
    expect(
      await db.setPrefIfNewer(_overrideKey, 's:更旧的对端', updatedAt: 999),
      isFalse,
    );
    expect(await db.getPref(_overrideKey), 's:本机');

    // 平局 → 保留本机（确定性，不是「随便谁赢」）。
    expect(
      await db.setPrefIfNewer(_overrideKey, 's:同戳的对端', updatedAt: 1000),
      isFalse,
    );
    expect(await db.getPref(_overrideKey), 's:本机');

    // 严格更新 → 写，且戳落成**对端的**戳而不是 now（戳 now 会让本机永远最新，
    // 对端的下一次改名再也进不来 —— 正是 BUG-1488 留下的缺口）。
    expect(
      await db.setPrefIfNewer(_overrideKey, 's:更新的对端', updatedAt: 2000),
      isTrue,
    );
    expect(await db.getPref(_overrideKey), 's:更新的对端');
    expect(await _updatedAtOf(db, _overrideKey), 2000);
  });

  test('setPrefIfNewer：本机没有该行时无条件采纳，戳 0 的旧对端也采纳', () async {
    final FushiDatabase db = openUpgraded();
    const String fresh = 'src:reader_fushi:override_title://fushi://book/New';

    expect(
      await db.setPrefIfNewer(fresh, 's:旧对端的名', updatedAt: 0),
      isTrue,
      reason: '本机从没给这本书起过名，旧对端不带戳也该采纳',
    );
    expect(await db.getPref(fresh), 's:旧对端的名');
    expect(await _updatedAtOf(db, fresh), 0);
  });

  test('升级后的存量行（戳 0）挡不住真改名，但挡得住同样没戳的旧对端', () async {
    final FushiDatabase db = openUpgraded();
    // 场景：本机 v84 前就改过名（戳 0），母设备升级后又改了一次（戳 > 0）。
    expect(
      await db.setPrefIfNewer(_overrideKey, 's:母设备第二次改的名',
          updatedAt: 1700000000000),
      isTrue,
    );
    expect(await db.getPref(_overrideKey), 's:母设备第二次改的名');

    // 反向：旧对端（无戳 → 0）不得覆盖本机行。
    expect(
      await db.setPrefIfNewer(_overrideKey, 's:旧对端的名', updatedAt: 0),
      isFalse,
    );
    expect(await db.getPref(_overrideKey), 's:母设备第二次改的名');
  });

  test('setPrefIfNewer 真写入时 bump prefs 版本，被拒时不 bump', () async {
    final FushiDatabase db = openUpgraded();
    await db.setPrefIfNewer(_overrideKey, 's:本机', updatedAt: 1000);
    final int afterWrite =
        await db.getPrefTyped<int>(FushiDatabase.prefsVersionKey, 0);

    expect(
      await db.setPrefIfNewer(_overrideKey, 's:更旧', updatedAt: 500),
      isFalse,
    );
    expect(
      await db.getPrefTyped<int>(FushiDatabase.prefsVersionKey, 0),
      afterWrite,
      reason: '没写就不该 bump——否则每轮同步都无谓地作废各进程的偏好缓存',
    );

    await db.setPrefIfNewer(_overrideKey, 's:更新', updatedAt: 2000);
    expect(
      await db.getPrefTyped<int>(FushiDatabase.prefsVersionKey, 0),
      greaterThan(afterWrite),
    );
  });

  test('getPrefUpdatedAt：行不存在 null，存在则给戳', () async {
    final FushiDatabase db = openUpgraded();
    expect(await db.getPrefUpdatedAt('nope'), isNull);
    expect(await db.getPrefUpdatedAt(_overrideKey), 0);
    await db.setPrefIfNewer(_overrideKey, 's:x', updatedAt: 4242);
    expect(await db.getPrefUpdatedAt(_overrideKey), 4242);
  });
}
