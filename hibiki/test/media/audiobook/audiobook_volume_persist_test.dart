import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// 音量按书持久化（BUG-031）：speed/delay/imagePause 都有 repo 读写键，唯独
/// volume 之前完全没有。这条覆盖新加的 `readVolume`/`updateVolume` 往复，确保
/// 退出重开书时音量能从 DB 恢复（运行期接线由源码守卫测试兜底）。
Future<HibikiDatabase> _openDb() async {
  final Directory dir =
      await Directory.systemTemp.createTemp('hibiki_volume_test_');
  addTearDown(() async {
    await dir.delete(recursive: true);
  });
  final HibikiDatabase db = HibikiDatabase(dir.path);
  addTearDown(db.close);
  return db;
}

void main() {
  test('AudiobookRepository persists per-book volume and round-trips',
      () async {
    final HibikiDatabase db = await _openDb();
    final AudiobookRepository repo = AudiobookRepository(db);

    // 未写过时回退默认 1.0。
    expect(await repo.readVolume('book-A'), 1.0);

    await repo.updateVolume(bookUid: 'book-A', volume: 0.4);
    await repo.updateVolume(bookUid: 'book-B', volume: 1.7);

    expect(await repo.readVolume('book-A'), closeTo(0.4, 1e-9));
    expect(await repo.readVolume('book-B'), closeTo(1.7, 1e-9));
    // 不串味：未写过的另一本书仍是默认。
    expect(await repo.readVolume('book-C'), 1.0);

    // 覆写后读回最新值。
    await repo.updateVolume(bookUid: 'book-A', volume: 1.0);
    expect(await repo.readVolume('book-A'), 1.0);
  });
}
