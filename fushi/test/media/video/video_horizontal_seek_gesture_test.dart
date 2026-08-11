import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_horizontal_seek_gesture.dart';

/// BUG-1485：移动端横滑 seek 的像素→时间换算模型。
///
/// 真实手势在 headless widget 测试里驱动不了（同 `video_horizontal_seek_test.dart`
/// 的说明），故把整个换算收进纯函数直接单测：短片 / 长片 / 小位移 / 大位移 / 边界
/// 钳制 / 三档灵敏度全覆盖。
void main() {
  // 典型手机竖屏视频区宽度（逻辑像素）。
  const double width = 400.0;

  Duration delta({
    required double dx,
    required Duration duration,
    Duration position = const Duration(minutes: 5),
    VideoSeekSensitivity sensitivity = VideoSeekSensitivity.medium,
    double surfaceWidth = width,
  }) {
    return VideoHorizontalSeekGesture.resolveDelta(
      dragDx: dx,
      surfaceWidth: surfaceWidth,
      duration: duration,
      position: position,
      sensitivity: sensitivity,
    );
  }

  group('BUG-1485: 灵敏度与视频总时长解耦', () {
    test('拖满整屏：24 分钟番剧与 2 小时电影跨越同一段时间（默认档 90 秒）', () {
      final Duration anime =
          delta(dx: width, duration: const Duration(minutes: 24));
      final Duration movie = delta(
        dx: width,
        duration: const Duration(hours: 2),
        position: const Duration(minutes: 30),
      );
      expect(anime, const Duration(seconds: 90));
      // 2 小时片触发「总时长 3% 地板」：7200 * 0.03 = 216 秒 > 90 秒基准。
      expect(movie, const Duration(seconds: 216));
      // 关键回归点：旧模型下 2 小时片拖满整屏 = 48 分钟（2880 秒）。
      expect(movie.inSeconds, lessThan(2880 ~/ 10));
    });

    test('旧模型的「越长越飞」被消除：时长翻 5 倍，同一位移的跨度远不到 5 倍', () {
      final Duration short =
          delta(dx: 100, duration: const Duration(minutes: 24));
      final Duration long = delta(
        dx: 100,
        duration: const Duration(minutes: 120),
        position: const Duration(minutes: 30),
      );
      expect(long.inMilliseconds, lessThan(short.inMilliseconds * 3));
    });
  });

  group('BUG-1485: 非线性阻尼（小位移更细、大位移更快）', () {
    const Duration duration = Duration(minutes: 24);

    test('小位移可做秒级微调', () {
      // 20px（整屏 5%）在默认档下只有约 1 秒。
      final Duration tiny = delta(dx: 20, duration: duration);
      expect(tiny.inMilliseconds, greaterThan(0));
      expect(tiny.inMilliseconds, lessThan(2000));
    });

    test('位移翻倍，跨度增长快于翻倍（gamma > 1）', () {
      final Duration half = delta(dx: 100, duration: duration);
      final Duration full = delta(dx: 200, duration: duration);
      expect(
        full.inMilliseconds,
        greaterThan(half.inMilliseconds * 2),
        reason: '阻尼指数必须 > 1，否则是线性映射、微调不可用',
      );
    });

    test('端点不变：拖满整屏恰好等于档位跨度（阻尼只改中段分布）', () {
      expect(
        delta(dx: width, duration: duration),
        VideoSeekSensitivity.medium.fullWidthSpan,
      );
    });

    test('单调：位移越大跨度越大', () {
      Duration previous = Duration.zero;
      for (double dx = 20; dx <= width; dx += 20) {
        final Duration current = delta(dx: dx, duration: duration);
        expect(current, greaterThanOrEqualTo(previous));
        previous = current;
      }
    });
  });

  group('BUG-1485: 方向与对称', () {
    const Duration duration = Duration(minutes: 24);

    test('向右为正（快进）、向左为负（快退），大小对称', () {
      final Duration forward = delta(dx: 150, duration: duration);
      final Duration backward = delta(dx: -150, duration: duration);
      expect(forward, greaterThan(Duration.zero));
      expect(backward, lessThan(Duration.zero));
      expect(backward, -forward);
    });

    test('位移为 0（拖回原点）= 不 seek', () {
      expect(delta(dx: 0, duration: duration), Duration.zero);
    });
  });

  group('BUG-1485: 灵敏度档位', () {
    const Duration duration = Duration(minutes: 24);

    test('低 < 中 < 高（同一位移）', () {
      final Duration low = delta(
        dx: 200,
        duration: duration,
        sensitivity: VideoSeekSensitivity.low,
      );
      final Duration medium = delta(
        dx: 200,
        duration: duration,
        sensitivity: VideoSeekSensitivity.medium,
      );
      final Duration high = delta(
        dx: 200,
        duration: duration,
        sensitivity: VideoSeekSensitivity.high,
      );
      expect(low, lessThan(medium));
      expect(medium, lessThan(high));
    });

    test('三档整屏跨度分别是 45 / 90 / 180 秒', () {
      expect(
        VideoSeekSensitivity.low.fullWidthSpan,
        const Duration(seconds: 45),
      );
      expect(
        VideoSeekSensitivity.medium.fullWidthSpan,
        const Duration(seconds: 90),
      );
      expect(
        VideoSeekSensitivity.high.fullWidthSpan,
        const Duration(seconds: 180),
      );
    });

    test('最高档也远钝于旧模型：2 小时片拖满整屏 < 旧模型的 1/3', () {
      final Duration high = delta(
        dx: width,
        duration: const Duration(hours: 2),
        position: const Duration(minutes: 30),
        sensitivity: VideoSeekSensitivity.high,
      );
      expect(high.inSeconds, lessThan(2880 ~/ 3));
    });

    test('fromName：往返 + 未知/null 回落 medium', () {
      for (final VideoSeekSensitivity value in VideoSeekSensitivity.values) {
        expect(VideoSeekSensitivity.fromName(value.name), value);
      }
      expect(VideoSeekSensitivity.fromName(null), VideoSeekSensitivity.medium);
      expect(VideoSeekSensitivity.fromName(''), VideoSeekSensitivity.medium);
      expect(
        VideoSeekSensitivity.fromName('bogus'),
        VideoSeekSensitivity.medium,
      );
    });
  });

  group('BUG-1485: 超短 / 超长视频的跨度钳制', () {
    test('超短片（60 秒）：整屏跨度被总时长 50% 天花板压到 30 秒', () {
      expect(
        delta(
          dx: width,
          duration: const Duration(seconds: 60),
          position: const Duration(seconds: 10),
          sensitivity: VideoSeekSensitivity.high,
        ),
        const Duration(seconds: 30),
      );
    });

    test('极短片（10 秒）：地板被总时长兜住，整屏最多跨越全片', () {
      expect(
        delta(
          dx: width,
          duration: const Duration(seconds: 10),
          position: Duration.zero,
        ),
        const Duration(seconds: 10),
      );
    });

    test('超长片（8 小时）：3% 地板保证粗调仍可用', () {
      expect(
        delta(
          dx: width,
          duration: const Duration(hours: 8),
          position: const Duration(hours: 1),
        ),
        const Duration(minutes: 14, seconds: 24),
      );
    });

    test('低档在超长片上同样吃地板（地板高于档位基准时档位不再区分）', () {
      const Duration duration = Duration(hours: 8);
      final Duration low = delta(
        dx: width,
        duration: duration,
        position: const Duration(hours: 1),
        sensitivity: VideoSeekSensitivity.low,
      );
      final Duration high = delta(
        dx: width,
        duration: duration,
        position: const Duration(hours: 1),
        sensitivity: VideoSeekSensitivity.high,
      );
      expect(low, high);
    });
  });

  group('BUG-1485: 边界与退化输入', () {
    test('目标 clamp 到 [0, duration]：向后拖不越过片头', () {
      const Duration duration = Duration(minutes: 24);
      final Duration d = delta(
        dx: -width,
        duration: duration,
        position: const Duration(seconds: 10),
      );
      expect(d, const Duration(seconds: -10));
      expect(
        VideoHorizontalSeekGesture.resolveTarget(
          dragDx: -width,
          surfaceWidth: width,
          duration: duration,
          position: const Duration(seconds: 10),
          sensitivity: VideoSeekSensitivity.medium,
        ),
        Duration.zero,
      );
    });

    test('目标 clamp 到 [0, duration]：向前拖不越过片尾', () {
      const Duration duration = Duration(minutes: 24);
      const Duration position = Duration(minutes: 23, seconds: 30);
      expect(
        delta(dx: width, duration: duration, position: position),
        const Duration(seconds: 30),
      );
      expect(
        VideoHorizontalSeekGesture.resolveTarget(
          dragDx: width,
          surfaceWidth: width,
          duration: duration,
          position: position,
          sensitivity: VideoSeekSensitivity.medium,
        ),
        duration,
      );
    });

    test('位移超出屏宽（多指/超界）不会溢出：仍按整屏跨度封顶', () {
      const Duration duration = Duration(minutes: 24);
      expect(
        delta(dx: width * 3, duration: duration),
        delta(dx: width, duration: duration),
      );
    });

    test('时长未知 / 非正（直播、未加载）不 seek', () {
      expect(delta(dx: 200, duration: Duration.zero), Duration.zero);
      expect(
        delta(dx: 200, duration: const Duration(seconds: -1)),
        Duration.zero,
      );
    });

    test('画面宽度非正 / 非有限位移不 seek（不除零、不抛）', () {
      expect(
        delta(dx: 200, duration: const Duration(minutes: 24), surfaceWidth: 0),
        Duration.zero,
      );
      expect(
        delta(
          dx: 200,
          duration: const Duration(minutes: 24),
          surfaceWidth: -400,
        ),
        Duration.zero,
      );
      expect(
        delta(dx: double.nan, duration: const Duration(minutes: 24)),
        Duration.zero,
      );
      expect(
        delta(dx: double.infinity, duration: const Duration(minutes: 24)),
        Duration.zero,
      );
    });

    test('起点位置越界（负 / 超片尾）先被 clamp，再算增量', () {
      const Duration duration = Duration(minutes: 24);
      expect(
        VideoHorizontalSeekGesture.resolveTarget(
          dragDx: width,
          surfaceWidth: width,
          duration: duration,
          position: const Duration(seconds: -30),
          sensitivity: VideoSeekSensitivity.medium,
        ),
        const Duration(seconds: 90),
      );
      expect(
        VideoHorizontalSeekGesture.resolveTarget(
          dragDx: width,
          surfaceWidth: width,
          duration: duration,
          position: const Duration(minutes: 30),
          sensitivity: VideoSeekSensitivity.medium,
        ),
        duration,
      );
    });

    test('resolveTarget 恒等于 position + resolveDelta（clamp 后）', () {
      const Duration duration = Duration(minutes: 24);
      const Duration position = Duration(minutes: 5);
      for (final double dx in <double>[-400, -137, -1, 0, 1, 137, 400]) {
        expect(
          VideoHorizontalSeekGesture.resolveTarget(
            dragDx: dx,
            surfaceWidth: width,
            duration: duration,
            position: position,
            sensitivity: VideoSeekSensitivity.medium,
          ),
          position + delta(dx: dx, duration: duration, position: position),
        );
      }
    });
  });
}
