import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_player_controller.dart';

void main() {
  test('HTTP video source is passed to media_kit as HTTP URL', () {
    const String remote =
        'http://127.0.0.1:8765/api/library/videos/file?uid=video%2Fdemo';

    expect(mediaUriForVideoPath(remote), remote);
  });

  test('local video path is passed to media_kit as file URI', () {
    final String path = File('sample.mp4').absolute.path;

    expect(mediaUriForVideoPath(path), File(path).uri.toString());
  });
}
