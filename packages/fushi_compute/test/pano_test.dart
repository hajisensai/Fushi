// ffc_pano_*（媒体库全景胖核心）的 FFI 契约：建图校验、批次覆盖全部精灵、分享动画锁定后
// 目标居中且占视口 62% 高、其余变暗到 10%、交互拖拽 / 拾取、释放后不可再用。
@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:fushi_compute/fushi_compute.dart';
import 'package:test/test.dart';

/// n 部作品（封面格 0..n-1，页 0）+ 每部 m 个词 + u 个无主词；每词 2 字形（细 / 字心 / 描边 3 格，页 1）。
FfcPanoScene _scene(int n, int m, int u) {
  final int cells = n + 3;
  final Float32List rects = Float32List(cells * 4);
  final Int32List pages = Int32List(cells);
  final Float32List works = Float32List(n * 3);
  final Int32List workCells = Int32List(n);
  for (int i = 0; i < n; i++) {
    rects.setAll(i * 4, <double>[i * 130.0, 0, 120, 160]);
    works.setAll(i * 3, <double>[0.7, 100, i / n]);
    workCells[i] = i;
  }
  rects.setAll(n * 4, <double>[0, 200, 32, 32]);
  rects.setAll((n + 1) * 4, <double>[32, 200, 32, 32]);
  rects.setAll((n + 2) * 4, <double>[64, 200, 40, 40]);
  pages.fillRange(n, cells, 1);
  final int total = n * m + u;
  final Int32List words = Int32List(total * 3);
  final Int32List glyphCells = Int32List(total * 2 * 3);
  final Float32List adv = Float32List(total * 2)..fillRange(0, total * 2, 1);
  for (int w = 0; w < total; w++) {
    words.setAll(w * 3, <int>[if (w < n * m) w ~/ m else -1, w * 2, 2]);
    for (int g = 0; g < 2; g++) {
      glyphCells.setAll((w * 2 + g) * 3, <int>[n, n + 1, n + 2]);
    }
  }
  return FfcPanoScene(
    cellRects: rects,
    cellPages: pages,
    workParams: works,
    workCells: workCells,
    words: words,
    glyphCells: glyphCells,
    glyphAdvances: adv,
    glyphEmPx: 32,
    seed: 3,
  );
}

void main() {
  test('rejects a work pointing at a missing cell', () {
    final FfcPanoScene ok = _scene(4, 2, 2);
    final FfcPanoScene bad = FfcPanoScene(
      cellRects: ok.cellRects,
      cellPages: ok.cellPages,
      workParams: ok.workParams,
      workCells: Int32List.fromList(<int>[0, 1, 2, 99]),
      words: ok.words,
      glyphCells: ok.glyphCells,
      glyphAdvances: ok.glyphAdvances,
      glyphEmPx: 32,
    );
    expect(
      () => FfcPanorama.create(bad),
      throwsA(
        isA<FfcPanoException>().having(
          (FfcPanoException e) => e.status,
          'status',
          FfcStatus.invalidArgument,
        ),
      ),
    );
  });

  test('batches partition the sprites in draw order', () {
    final FfcPanorama p = FfcPanorama.create(_scene(40, 6, 30));
    addTearDown(p.dispose);
    final FfcPanoFrame f = p.frame(t: 0, dt: 0, width: 1280, height: 720);
    expect(f.sprites, greaterThan(0));
    int sum = 0;
    for (int b = 0; b < f.batches; b++) {
      expect(f.batchStart(b), sum);
      sum += f.batchCount(b);
      if (b > 0) expect(f.batchPage(b), isNot(f.batchPage(b - 1)));
    }
    expect(sum, f.sprites);
    expect(f.sprites, lessThanOrEqualTo(p.capacity));
  });

  test('cinematic lock: target centred at 62% height, others dimmed', () {
    final FfcPanorama p = FfcPanorama.create(_scene(60, 3, 10));
    addTearDown(p.dispose);
    p.setMode(FfcPanoMode.cinematic, target: 17);
    final FfcPanoFrame f = p.frame(t: 13.6, dt: 1 / 60, width: 1000, height: 800);
    expect(f.handoff, isTrue);
    expect(f.targetVisible, isTrue);
    final Float32List i = f.info;
    final double x = i[FfcPanoInfo.targetRect];
    final double y = i[FfcPanoInfo.targetRect + 1];
    final double w = i[FfcPanoInfo.targetRect + 2];
    final double h = i[FfcPanoInfo.targetRect + 3];
    expect(x + w / 2, closeTo(500, 1));
    expect(y + h / 2, closeTo(400, 1));
    expect(h, closeTo(0.62 * 800, 2));
    expect(w / h, closeTo(0.7, 1e-3));
    expect(i[FfcPanoInfo.dim], closeTo(0.1, 1e-4));
  });

  test('interactive: drag changes the view, tap picks a card', () {
    final FfcPanorama p = FfcPanorama.create(_scene(30, 0, 0));
    addTearDown(p.dispose);
    final Float32List before = Float32List.fromList(
      p.frame(t: 0, dt: 0, width: 800, height: 600).info.sublist(4, 7),
    );
    p
      ..input(FfcPanoInput.drag, 200, 0)
      ..input(FfcPanoInput.release, 0, 0);
    final FfcPanoFrame f = p.frame(t: 0.016, dt: 0.016, width: 800, height: 600);
    expect(f.info.sublist(4, 7), isNot(equals(before)));
    // 第一个可见封面的中心能拾到它。
    final int s = 0;
    final double k = f.transforms[s * 4];
    final double cx = f.transforms[s * 4 + 2] + k * 60;
    final double cy = f.transforms[s * 4 + 3] + k * 80;
    expect(p.pick(cx, cy), greaterThanOrEqualTo(0));
    expect(p.pick(-50, -50), -1);
  });

  test('dispose is idempotent and blocks further use', () {
    final FfcPanorama p = FfcPanorama.create(_scene(2, 0, 0));
    p
      ..dispose()
      ..dispose();
    expect(p.isDisposed, isTrue);
    expect(
      () => p.frame(t: 0, dt: 0, width: 10, height: 10),
      throwsStateError,
    );
  });
}
