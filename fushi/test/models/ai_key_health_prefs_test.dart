// AI 多 key 冷却记录的偏好表落库：按条（指纹）合并，不拿进程缓存整份覆盖。
//
// 生产里主进程与 Android `:popup` 进程各有一份 PreferencesRepository 缓存，共用同一
// 张 preferences 表。这里用同一个库上的两个仓库实例模拟两个进程：各自 loadFromDb
// 之后缓存就互不相知，正是覆盖写回会互相抹掉对方冷却记录的形状。
import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/ai/ai_key_rotation.dart';

AiKeyHealth _health(int failures, {String reason = 'rate_limited'}) =>
    AiKeyHealth(
      cooldownUntil: DateTime.utc(
        2026,
        10,
        13,
        12,
      ).add(Duration(minutes: failures)),
      failures: failures,
      reason: reason,
    );

void main() {
  late FushiDatabase db;

  setUp(() {
    db = FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));
  });

  tearDown(() async {
    // loadFromDb 把全局装配点换成了偏好表实现；还原，别让它指向已关闭的库。
    aiKeyHealthStore = InMemoryAiKeyHealthStore();
    await db.close();
  });

  Future<PreferencesRepository> process() async {
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    return prefs;
  }

  Future<Map<String, AiKeyHealth>> persisted() async =>
      (await process()).aiKeyHealth;

  test('两个进程各记一把 key：互不抹掉对方的冷却', () async {
    final PreferencesRepository primary = await process();
    final PreferencesRepository popup = await process();

    await primary.updateAiKeyHealth('fp-main', (_) => _health(1));
    // popup 的缓存在主进程写之前就加载了，看不到 fp-main。
    expect(popup.aiKeyHealth.containsKey('fp-main'), isFalse);

    await popup.updateAiKeyHealth('fp-popup', (_) => _health(2));

    final Map<String, AiKeyHealth> stored = await persisted();
    expect(stored.keys, unorderedEquals(<String>['fp-main', 'fp-popup']));
    expect(stored['fp-main'], _health(1));
    expect(stored['fp-popup'], _health(2));
    // 写完的一方缓存对齐到持久值，顺带收进了对方的条目。
    expect(
      popup.aiKeyHealth.keys,
      containsAll(<String>['fp-main', 'fp-popup']),
    );
  });

  test('update 在最新持久值上重算：旧缓存里的成功不清掉别的进程刚记的冷却', () async {
    final PreferencesRepository primary = await process();
    final PreferencesRepository popup = await process();

    await primary.updateAiKeyHealth('fp', (_) => _health(1));
    // popup 发请求时缓存里没有这条（seen = null）；它的成功落账时，持久值里已经
    // 有主进程刚记的失败——那不是它看到过的状态，不能清。
    await popup.updateAiKeyHealth(
      'fp',
      (AiKeyHealth? current) =>
          aiKeyHealthAfterSuccess(seen: null, current: current),
    );
    expect((await persisted())['fp'], _health(1));
    expect(popup.aiKeyHealth['fp'], _health(1));
  });

  test('并发失败在持久值上合并：别的进程刚记过的同一阵限流不再累加', () async {
    final PreferencesRepository primary = await process();
    final PreferencesRepository popup = await process();
    final DateTime now = DateTime.utc(2026, 10, 13, 12);
    AiKeyHealthUpdate fail(AiKeyHealth? seen) =>
        (AiKeyHealth? current) => aiKeyHealthAfterFailure(
          seen: seen,
          current: current,
          reason: 'rate_limited',
          retryAfter: null,
          now: now,
        );

    await primary.updateAiKeyHealth('fp', fail(null));
    await popup.updateAiKeyHealth('fp', fail(null));

    final AiKeyHealth stored = (await persisted())['fp']!;
    expect(stored.failures, 1);
    expect(stored.cooldownUntil, now.add(kAiKeyBaseCooldown));
  });

  test('清掉一条只删这一条；清空后落成空串', () async {
    final PreferencesRepository primary = await process();
    final PreferencesRepository popup = await process();
    await primary.updateAiKeyHealth('fp-a', (_) => _health(1));
    await primary.updateAiKeyHealth('fp-b', (_) => _health(2));

    // popup 的缓存是空的，但清 fp-a 仍只动 fp-a。
    await popup.updateAiKeyHealth('fp-a', (_) => null);
    expect((await persisted()).keys, <String>['fp-b']);

    await popup.updateAiKeyHealth('fp-b', (_) => null);
    expect(await persisted(), isEmpty);
    expect(
      await db.getPref(PreferencesRepository.aiKeyHealthPrefKey),
      PrefCodec.encode(''),
    );
  });

  test('值没变不落库（成功且本来就没有记录）', () async {
    final PreferencesRepository primary = await process();
    await primary.updateAiKeyHealth(
      'fp',
      (AiKeyHealth? current) =>
          aiKeyHealthAfterSuccess(seen: null, current: current),
    );
    expect(await db.getPref(PreferencesRepository.aiKeyHealthPrefKey), isNull);
  });
}
