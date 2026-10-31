import 'package:drift/native.dart';
import 'package:fushi_audio/src/audiobook/audiobook_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:test/test.dart';

/// BUG-3891：插图停留默认关（所有者 2026-10-31 拍板「默认关」，撤回同日的 2 秒默认）。
///
/// 偏好表没有这本书的行 → 0（关）；用户显式设过的秒数原样读回，且只影响那一本书。
void main() {
  late FushiDatabase db;
  late AudiobookRepository repo;

  setUp(() {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    repo = AudiobookRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  test('从未设置过的书默认关', () async {
    expect(AudiobookRepository.defaultImagePauseSec, 0);
    expect(
      await db.getPref('audiobook_image_pause_never'),
      isNull,
      reason: '前提：没有偏好行',
    );
    expect(await repo.readImagePauseSec('never'), 0);
  });

  test('显式设成 0（关闭）的书保持关闭', () async {
    await repo.updateImagePauseSec(bookKey: 'off', sec: 0);
    expect(await db.getPref('audiobook_image_pause_off'), 'i:0');
    expect(await repo.readImagePauseSec('off'), 0);
  });

  test('显式设过的其它秒数原样读回，且不影响别的书', () async {
    await repo.updateImagePauseSec(bookKey: 'seven', sec: 7);
    expect(await repo.readImagePauseSec('seven'), 7);
    expect(await repo.readImagePauseSec('other'), 0);
  });
}
