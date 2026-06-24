import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/drag_drop/drop_classification.dart';
import 'package:hibiki/src/media/drag_drop/import_dialog_drop.dart';

/// 三个导入对话框 `_handleDialogDrop` 抽出的纯函数行为守卫：给定一批拖入路径，
/// 断言「音频→音频字段、字幕→字幕字段、视频→视频字段、播放列表→播放列表字段」。
void main() {
  group('resolveBookDialogDrop', () {
    test('audio files land in audioPaths, subtitle in subtitlePath', () {
      final DroppedFiles files = classifyDroppedFiles(<String>[
        r'C:\b\book.epub',
        r'C:\b\book.srt',
        r'C:\b\book.mp3',
        r'C:\b\book 02.mp3',
      ]);
      final BookDialogDropResult r = resolveBookDialogDrop(files);
      expect(r.epubPath, r'C:\b\book.epub');
      expect(r.subtitlePath, r'C:\b\book.srt');
      expect(r.audioPaths, <String>[r'C:\b\book.mp3', r'C:\b\book 02.mp3']);
      expect(r.isEmpty, isFalse);
    });

    test('audio-only drop fills only audioPaths', () {
      final DroppedFiles files =
          classifyDroppedFiles(<String>[r'C:\b\track.flac']);
      final BookDialogDropResult r = resolveBookDialogDrop(files);
      expect(r.epubPath, isNull);
      expect(r.subtitlePath, isNull);
      expect(r.audioPaths, <String>[r'C:\b\track.flac']);
    });

    test('unrecognized-only drop is empty', () {
      final DroppedFiles files =
          classifyDroppedFiles(<String>[r'C:\b\notes.foobar']);
      expect(resolveBookDialogDrop(files).isEmpty, isTrue);
    });
  });

  group('resolveAudiobookDialogDrop', () {
    test('audios into audioPaths, first subtitle into alignmentPath', () {
      final DroppedFiles files = classifyDroppedFiles(<String>[
        r'C:\a\v1.mp3',
        r'C:\a\v2.mp3',
        r'C:\a\align.srt',
      ]);
      final AudiobookDialogDropResult r = resolveAudiobookDialogDrop(files);
      expect(r.audioPaths, <String>[r'C:\a\v1.mp3', r'C:\a\v2.mp3']);
      expect(r.alignmentPath, r'C:\a\align.srt');
      expect(r.isEmpty, isFalse);
    });

    test('subtitle-only drop fills only alignmentPath', () {
      final DroppedFiles files =
          classifyDroppedFiles(<String>[r'C:\a\only.vtt']);
      final AudiobookDialogDropResult r = resolveAudiobookDialogDrop(files);
      expect(r.audioPaths, isEmpty);
      expect(r.alignmentPath, r'C:\a\only.vtt');
    });
  });

  group('resolveVideoDialogDrop', () {
    test('playlist wins and is mutually exclusive with videoPath', () {
      final DroppedFiles files = classifyDroppedFiles(<String>[
        r'C:\v\series.m3u8',
        r'C:\v\ep1.mkv',
        r'C:\v\ep1.srt',
      ]);
      final VideoDialogDropResult r = resolveVideoDialogDrop(files);
      expect(r.playlistPath, r'C:\v\series.m3u8');
      expect(r.videoPath, isNull,
          reason: 'playlist path is one-shot, no video');
      expect(r.subtitlePath, isNull);
    });

    test('video + subtitle without playlist', () {
      final DroppedFiles files = classifyDroppedFiles(<String>[
        r'C:\v\movie.mkv',
        r'C:\v\movie.ass',
      ]);
      final VideoDialogDropResult r = resolveVideoDialogDrop(files);
      expect(r.playlistPath, isNull);
      expect(r.videoPath, r'C:\v\movie.mkv');
      expect(r.subtitlePath, r'C:\v\movie.ass');
    });

    test('subtitle-only drop fills only subtitlePath', () {
      final DroppedFiles files =
          classifyDroppedFiles(<String>[r'C:\v\sub.srt']);
      final VideoDialogDropResult r = resolveVideoDialogDrop(files);
      expect(r.videoPath, isNull);
      expect(r.subtitlePath, r'C:\v\sub.srt');
    });
  });
}
