import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/galgame_window_gif.dart';

void main() {
  test('unknown duration keeps the baseline frame count', () {
    expect(
      galAnimatedFrameBudget(
        baseFrames: 10,
        fps: 8,
        target: null,
        pending: false,
      ),
      10,
    );
    expect(
      galAnimatedFrameBudget(
        baseFrames: 10,
        fps: 8,
        target: Duration.zero,
        pending: false,
      ),
      10,
    );
  });

  test('covers the whole sentence audio at playback fps', () {
    // 3.19 s 语音（SGRE 真机样本）× 8 fps → 26 帧（向上取整），不再是 10 帧 / 1.25 s。
    expect(
      galAnimatedFrameBudget(
        baseFrames: 10,
        fps: 8,
        target: const Duration(milliseconds: 3190),
        pending: false,
      ),
      26,
    );
    // 比基线短的语音不缩水。
    expect(
      galAnimatedFrameBudget(
        baseFrames: 10,
        fps: 8,
        target: const Duration(milliseconds: 600),
        pending: false,
      ),
      10,
    );
  });

  test('caps at the maximum animated duration', () {
    final int maxFrames = kGalAnimatedMaxDuration.inSeconds * 8;
    expect(
      galAnimatedFrameBudget(
        baseFrames: 10,
        fps: 8,
        target: const Duration(seconds: 30),
        pending: false,
      ),
      maxFrames,
    );
    // 时长未知期间维持采样，直到撞上限。
    expect(
      galAnimatedFrameBudget(
        baseFrames: 10,
        fps: 8,
        target: null,
        pending: true,
      ),
      maxFrames,
    );
  });
}
