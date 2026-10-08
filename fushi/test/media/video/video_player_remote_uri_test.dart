import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';

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

  // SMB / NAS 共享上的视频：包成 file URI 会丢主机名（`file:///NAS/…`），
  // media_kit 再还原成 `\\?\\NAS\…` → libmpv 打不开，页面报「打不开该视频」。
  test('Windows UNC share path is passed to media_kit as a raw path', () {
    const String unc = r'\\NAS\Video\番剧 A\S01E01.mkv';
    expect(mediaUriForVideoPath(unc, windows: true), unc);
    const String slashed = '//NAS/Video/S01E01.mkv';
    expect(mediaUriForVideoPath(slashed, windows: true), slashed);
  });

  test('UNC detection excludes device namespaces and non-Windows', () {
    expect(isWindowsUncPath(r'\\NAS\Video\a.mkv', windows: true), isTrue);
    expect(isWindowsUncPath('//NAS/Video/a.mkv', windows: true), isTrue);
    expect(isWindowsUncPath(r'\\?\C:\Video\a.mkv', windows: true), isFalse);
    expect(isWindowsUncPath(r'\\.\pipe\x', windows: true), isFalse);
    expect(isWindowsUncPath(r'C:\Video\a.mkv', windows: true), isFalse);
    expect(isWindowsUncPath('/mnt/nas/a.mkv', windows: true), isFalse);
    expect(isWindowsUncPath('//NAS/Video/a.mkv', windows: false), isFalse);
  });
}
