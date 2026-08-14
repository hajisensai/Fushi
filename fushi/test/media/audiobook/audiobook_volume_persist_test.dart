import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';

/// 音量按书持久化（BUG-031）：speed/delay/imagePause 都有 repo 读写键，唯独
/// volume 之前完全没有。这条覆盖新加的 `readVolume`/`updateVolume` 往复，确保
/// 退出重开书时音量能从 DB 恢复（运行期接线由源码守卫测试兜底）。
Future<FushiDatabase> _openDb() async {
  final Directory dir =
      await Directory.systemTemp.createTemp('hibiki_volume_test_');
  addTearDown(() async {
    await dir.delete(recursive: true);
  });
  final FushiDatabase db = FushiDatabase(dir.path);
  addTearDown(db.close);
  return db;
}

void main() {
  test('AudiobookRepository persists per-book volume and round-trips',
      () async {
    final FushiDatabase db = await _openDb();
    final AudiobookRepository repo = AudiobookRepository(db);

    // 未写过时回退默认 1.0。
    expect(await repo.readVolume('book-A'), 1.0);

    await repo.updateVolume(bookKey: 'book-A', volume: 0.4);
    await repo.updateVolume(bookKey: 'book-B', volume: 1.7);

    expect(await repo.readVolume('book-A'), closeTo(0.4, 1e-9));
    expect(await repo.readVolume('book-B'), closeTo(1.7, 1e-9));
    // 不串味：未写过的另一本书仍是默认。
    expect(await repo.readVolume('book-C'), 1.0);

    // 覆写后读回最新值。
    await repo.updateVolume(bookKey: 'book-A', volume: 1.0);
    expect(await repo.readVolume('book-A'), 1.0);
  });

  test('updateDelayMs 同步盖 audiobook_delay_at_ 时间戳（互联 LWW 载体）', () async {
    final FushiDatabase db = await _openDb();
    final AudiobookRepository repo = AudiobookRepository(db);

    final int before = DateTime.now().millisecondsSinceEpoch;
    await repo.updateDelayMs(bookKey: 'book-A', ms: -1500);
    final int after = DateTime.now().millisecondsSinceEpoch;

    expect(await repo.readDelayMs('book-A'), -1500);
    final int at = await db.getPrefTyped<int>('audiobook_delay_at_book-A', 0);
    expect(at, inInclusiveRange(before, after),
        reason: '值与时间戳必须一起写：本机调轴无戳恒 0，'
            '会在互联 LWW 里永远输给对端旧戳、再也传不出去');
  });

  test('fine-grained (1%) volume values round-trip unchanged', () async {
    // 音量滑条细化到 1% 一档（AudiobookVolumeRow.sliderDivisions = 200）后，
    // 0.87 这类非 10% 网格值也要原样写穿/读回；存储本就是裸 double 字符串，
    // 旧的 10% 网格存量值（如 0.4）同样继续有效 —— 双向兼容。
    final FushiDatabase db = await _openDb();
    final AudiobookRepository repo = AudiobookRepository(db);

    await repo.updateVolume(bookKey: 'book-fine', volume: 0.87);
    expect(await repo.readVolume('book-fine'), closeTo(0.87, 1e-9));

    await repo.updateVolume(bookKey: 'book-fine', volume: 1.05);
    expect(await repo.readVolume('book-fine'), closeTo(1.05, 1e-9));
  });
}
