import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Source-scan guards for TODO-903: video opened via the OS "open with"
/// (file association / drag-onto-exe / CLI argv) must (1) carry a shelf cover,
/// (2) dedup against an already-imported copy of the same physical file instead
/// of inserting a second row under the `video/ext/<sha1>` identity, and
/// (3) validate the file actually exists before inserting.
///
/// `_openExternalVideo` runs on the global navigator from the widget tree, so a
/// full behaviour test would need the whole app + a navigator + a real DB. The
/// repository dedup half (findByVideoPath / isVideoPathReferenced same-source
/// semantics) is covered by a real behaviour test in
/// test/media/video/video_book_repository_test.dart; here we pin the call-site
/// wiring at the source level so a future refactor can't silently drop one of
/// the three fixes.
void main() {
  String readMain() => File('lib/main.dart').readAsStringSync();

  String openExternalVideoBody() {
    final String src = readMain();
    const String marker = 'Future<void> _openExternalVideo(';
    final int start = src.indexOf(marker);
    expect(start, isNonNegative,
        reason: '_openExternalVideo must exist in lib/main.dart');
    // Grab a generous window covering the whole method body.
    final int end =
        src.indexOf('\n  void _scheduleWindowsUpdateHandoff', start);
    return end > start ? src.substring(start, end) : src.substring(start);
  }

  group('TODO-903 external "open with" video entry', () {
    test('① extracts a cover for newly-created external video rows', () {
      expect(openExternalVideoBody(), contains('extractVideoCover('),
          reason: 'file-open path must reuse the import dialog cover extractor '
              'so externally-opened videos are not coverless');
    });

    test('② dedups by videoPath via the repository single source', () {
      final String body = openExternalVideoBody();
      expect(body, contains('findByVideoPath('),
          reason: 'must reuse the repository videoPath comparison (same source '
              'as isVideoPathReferenced) to reuse an already-imported bookUid '
              'instead of inserting a second video/ext/<sha1> row');
    });

    test('③ validates the file exists before inserting', () {
      final String body = openExternalVideoBody();
      expect(body, contains('File(videoPath).exists('),
          reason: 'the cold-start argv existsSync in main() can go stale '
              'before this first-frame insert; the entry must re-verify '
              'existence and not silently swallow a missing file');
      expect(body, contains('video_file_not_found'),
          reason: 'a missing file must surface user feedback, consistent with '
              'other failure paths');
    });
  });
}
