import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_resource_check.dart';
import 'package:fushi_engine/media/video/dvd/dvd_title_path.dart';
import 'package:path/path.dart' as p;

/// A DVD title's library path is virtual (`<disc>/VIDEO_TS/TITLE_nn.dvdtitle`):
/// the page's "missing resource" gate must ask whether the disc is still there,
/// not whether a file exists at that path (it never does). Found by the DVD menu
/// integration test: every DVD row opened into the "video missing" dialog.
void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('fushi-dvd-resource-');
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('a DVD title is present while its VIDEO_TS.IFO is', () async {
    final Directory videoTs = Directory(p.join(root.path, 'VIDEO_TS'))
      ..createSync();
    File(p.join(videoTs.path, 'VIDEO_TS.IFO')).writeAsBytesSync(<int>[0]);
    final String title = dvdTitlePath(root.path, 1);
    expect(File(title).existsSync(), isFalse, reason: 'the path is virtual');
    expect(await isLocalVideoResourceMissing(title), isFalse);

    File(p.join(videoTs.path, 'VIDEO_TS.IFO')).deleteSync();
    expect(await isLocalVideoResourceMissing(title), isTrue);
  });

  test('an ISO-backed DVD title is present while the image is', () async {
    final File iso = File(p.join(root.path, 'show.iso'))
      ..writeAsBytesSync(<int>[0]);
    final String title = dvdTitlePath(iso.path, 2);
    expect(await isLocalVideoResourceMissing(title), isFalse);
    iso.deleteSync();
    expect(await isLocalVideoResourceMissing(title), isTrue);
  });

  test('ordinary files keep the plain existence check', () async {
    final File video = File(p.join(root.path, 'a.mkv'))
      ..writeAsBytesSync(<int>[0]);
    expect(await isLocalVideoResourceMissing(video.path), isFalse);
    video.deleteSync();
    expect(await isLocalVideoResourceMissing(video.path), isTrue);
  });
}
