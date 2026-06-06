import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-087: large content uploads (EPUB / dictionary / audiobook / local-audio
/// packages — multi-GB in the wild) must use resumable CHUNKED upload, not a
/// single multipart POST that a flaky link drops (timeout) and the _call retry
/// restarts from byte 0, never completing. A real Drive upload can't run in a
/// unit test, so guard the source.
void main() {
  late String src;
  setUpAll(() {
    src = File('lib/src/sync/google_drive_handler.dart').readAsStringSync();
  });

  test('uploadContentFile uploads via resumable chunked upload', () {
    final int at = src.indexOf('Future<void> uploadContentFile(');
    expect(at, greaterThanOrEqualTo(0));
    // Fixed window over the method body (it is ~50 lines); a brace-based end
    // marker is fragile because the multi-line parameter list also closes with
    // "  })".
    final String body =
        src.substring(at, (at + 2200).clamp(0, src.length));

    expect(body, contains('ResumableUploadOptions'),
        reason: 'large uploads must be resumable, not single multipart');
    // Both the update (existing file) and create (new file) paths must pass it.
    final int optCount = 'uploadOptions:'.allMatches(body).length;
    expect(optCount, greaterThanOrEqualTo(2),
        reason: 'both files.update and files.create must pass uploadOptions');
    // Chunked: a real chunk size (multiple of 256 KB) so a hiccup loses only a
    // chunk, and the token can refresh between chunks.
    expect(body, contains('chunkSize:'),
        reason: 'must set an explicit chunk size for chunked upload');
  });
}
