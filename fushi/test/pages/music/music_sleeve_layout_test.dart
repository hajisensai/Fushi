// 播放页 A 布局封面 + 唱片的几何（用户 2026-11-22 手绘草图：封面左斜、唱片在
// 右边垫在封面后面，两者重心在同一条水平线上）。
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/music/music_lyrics_page.dart';

void main() {
  for (final double base in <double>[180, 260, 360]) {
    test('基准边 $base：唱片圆心与封面中心同一水平线、只交叠一小块、整组装得下', () {
      final MusicSleeveLayout l = MusicSleeveLayout.of(base);
      final Offset disc = l.coverCenter + Offset(l.discReach, 0);
      // 同一条水平线。
      expect(disc.dy, l.coverCenter.dy);
      // 倾斜后封面最靠右的点（角）在唱片左缘右边：有交叠，唱片垫在后面像抽出来；
      // 但封面未倾斜时的右缘在唱片圆心左边很远：交叠只是一小块，盘面大半露在外面。
      const double a = 10 * math.pi / 180;
      final double coverRight =
          l.coverCenter.dx + l.coverSide * (math.cos(a) + math.sin(a)) / 2;
      expect(coverRight, greaterThan(disc.dx - l.discSize / 2));
      expect(
        l.coverCenter.dx + l.coverSide / 2,
        lessThan(disc.dx - 0.2 * l.coverSide),
      );
      // 整组宽高装得下封面外接框与唱片。
      expect(l.width, closeTo(disc.dx + l.discSize / 2, 1e-9));
      expect(l.coverCenter.dx, closeTo(coverRight - l.coverCenter.dx, 1e-9));
      expect(l.height, greaterThanOrEqualTo(l.discSize));
    });
  }
}
