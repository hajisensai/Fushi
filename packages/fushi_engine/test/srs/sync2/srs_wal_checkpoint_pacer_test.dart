import 'package:fushi_engine/srs/sync2/srs_wal_checkpoint_pacer.dart';
import 'package:test/test.dart';

/// 收段的 WAL 并回节奏：第一片之后先并一次量出每片的量，之后攒到目标页数再并；每片写得多就更勤，有读者挡着
/// WAL 回绕（`log` 累计）也只会更勤，不会让 WAL 失控。
void main() {
  /// 按每片写 [perSlice] 页跑 [slices] 片，返回各次并回时 WAL 里的帧数（每次并回后 WAL 回绕）。
  List<int> run(SrsWalCheckpointPacer p, int perSlice, int slices) {
    final List<int> logs = <int>[];
    int wal = 0;
    for (int i = 0; i < slices; i++) {
      wal += perSlice;
      if (p.afterSlice()) {
        logs.add(wal);
        p.checkpointed(wal);
        wal = 0;
      }
    }
    return logs;
  }

  test('measures after the first slice, then checkpoints near the target', () {
    final SrsWalCheckpointPacer p = SrsWalCheckpointPacer(targetPages: 8192);
    final List<int> logs = run(p, 2285, 60);
    expect(logs.first, 2285);
    expect(p.every, 3);
    expect(logs.skip(1), everyElement(lessThanOrEqualTo(8192)));
    expect(logs.length, lessThan(60 ~/ 2));
  });

  test(
    'a slice that alone exceeds the target checkpoints after every slice',
    () {
      final SrsWalCheckpointPacer p = SrsWalCheckpointPacer(targetPages: 8192);
      run(p, 20000, 5);
      expect(p.every, 1);
    },
  );

  test('tiny slices are capped at maxEvery', () {
    final SrsWalCheckpointPacer p = SrsWalCheckpointPacer(
      targetPages: 8192,
      maxEvery: 64,
    );
    run(p, 1, 10);
    expect(p.every, 64);
    p.checkpointed(0);
    expect(p.every, 64);
  });

  test(
    'a cumulative log (readers blocking the WAL reset) only shortens the interval',
    () {
      final SrsWalCheckpointPacer p = SrsWalCheckpointPacer(targetPages: 8192);
      expect(p.afterSlice(), isTrue);
      p.checkpointed(2000);
      expect(p.every, 4);
      for (int i = 0; i < 3; i++) {
        expect(p.afterSlice(), isFalse);
      }
      expect(p.afterSlice(), isTrue);
      // WAL 没回绕：报的是累计 10000 帧（上次 2000 + 这 4 片 8000）。
      p.checkpointed(10000);
      expect(p.every, lessThan(4));
    },
  );
}
