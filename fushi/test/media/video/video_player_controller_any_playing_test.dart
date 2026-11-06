import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';

/// [VideoPlayerController.anyPlaying]：后台空闲自动制卡据此判断「用户在看视频」（看视频时
/// 键鼠两分钟不动是常态，系统空闲判据挡不住）。
void main() {
  test('有控制器在播 → true；暂停 / dispose 后 → false', () {
    expect(VideoPlayerController.anyPlaying, isFalse);
    final VideoPlayerController a = VideoPlayerController();
    final VideoPlayerController b = VideoPlayerController();
    expect(VideoPlayerController.anyPlaying, isFalse);
    b.debugSetIsPlayingForTesting(true);
    expect(VideoPlayerController.anyPlaying, isTrue);
    b.debugSetIsPlayingForTesting(false);
    expect(VideoPlayerController.anyPlaying, isFalse);
    b.debugSetIsPlayingForTesting(true);
    b.dispose();
    expect(VideoPlayerController.anyPlaying, isFalse, reason: 'dispose 即注销');
    a.dispose();
  });
}
