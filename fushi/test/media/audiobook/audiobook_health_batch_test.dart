import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';

/// 书架为每本有声书各查一次 `readHealthOverlay`（= 一条真 SELECT）是 N+1；
/// [AudiobookRepository.resolveAllHealth] 一条前缀查询取完。守：批量口径与单本
/// `resolveHealth` 逐本一致——有覆盖用覆盖、无覆盖按行自身推导、覆盖损坏回退。
void main() {
  late FushiDatabase db;
  late AudiobookRepository repo;

  setUp(() {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    repo = AudiobookRepository(db);
  });

  tearDown(() => db.close());

  Future<void> insertAudiobook(String bookKey, {int? matchRatePct}) =>
      db.upsertAudiobook(AudiobooksCompanion.insert(
        bookKey: bookKey,
        alignmentFormat: 'lrc',
        alignmentPath: '/tmp/$bookKey.lrc',
        matchRatePct: Value<int?>(matchRatePct),
      ));

  test('resolveAllHealth equals per-book resolveHealth', () async {
    await insertAudiobook('with-overlay', matchRatePct: 10);
    await insertAudiobook('no-overlay', matchRatePct: 95);
    await insertAudiobook('broken-overlay', matchRatePct: 50);
    await repo.updateHealthOverlay(
      bookKey: 'with-overlay',
      health: AudiobookHealth.fromRatePct(ratePct: 99, reason: 'rerun'),
    );
    await db.setPref('audiobook_health_overlay_broken-overlay', '{not json');

    final Map<String, Audiobook> byKey = await repo.buildBookKeyMap();
    final Map<String, AudiobookHealth> batch =
        await repo.resolveAllHealth(byKey);

    expect(batch.keys.toSet(), byKey.keys.toSet());
    for (final MapEntry<String, Audiobook> e in byKey.entries) {
      final AudiobookHealth single = await repo.resolveHealth(e.value);
      expect(batch[e.key]!.kind, single.kind, reason: e.key);
      expect(batch[e.key]!.ratePct, single.ratePct, reason: e.key);
      expect(batch[e.key]!.reason, single.reason, reason: e.key);
    }
    expect(batch['with-overlay']!.kind, HealthKind.ok,
        reason: '覆盖（99%）压过行自身的 10%');
    expect(batch['with-overlay']!.reason, 'rerun');
  });

  test('readAllHealthOverlays strips the key prefix and skips junk', () async {
    await repo.updateHealthOverlay(
      bookKey: 'k1',
      health: AudiobookHealth.fromRatePct(ratePct: 80),
    );
    await db.setPref('audiobook_health_overlay_junk', '');
    await db.setPref('unrelated_pref', '{"kind":"ok"}');

    final Map<String, AudiobookHealth> overlays =
        await repo.readAllHealthOverlays();

    expect(overlays.keys.toSet(), <String>{'k1'});
    expect(overlays['k1']!.ratePct, 80);
  });
}
