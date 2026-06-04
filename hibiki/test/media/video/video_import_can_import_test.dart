import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_import_dialog.dart'
    show videoImportCanImport;

void main() {
  group('videoImportCanImport (Phase 0: subtitle optional)', () {
    test('video selected, no subtitle -> can import (embedded fallback)', () {
      expect(
        videoImportCanImport(
          videoPath: '/v.mp4',
          subtitlePath: null,
          busy: false,
        ),
        isTrue,
      );
    });

    test('video + subtitle selected -> can import', () {
      expect(
        videoImportCanImport(
          videoPath: '/v.mp4',
          subtitlePath: '/v.srt',
          busy: false,
        ),
        isTrue,
      );
    });

    test('no video -> cannot import even with subtitle', () {
      expect(
        videoImportCanImport(
          videoPath: null,
          subtitlePath: '/v.srt',
          busy: false,
        ),
        isFalse,
      );
    });

    test('busy -> cannot import regardless of selection', () {
      expect(
        videoImportCanImport(
          videoPath: '/v.mp4',
          subtitlePath: '/v.srt',
          busy: true,
        ),
        isFalse,
      );
    });
  });
}
