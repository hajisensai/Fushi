import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-970 source-scan guard: Android book/video sentence audio must be cut by
/// **ffmpeg** (the same path as desktop), never by the native MediaChannel
/// `extractAudioSegment` handler (androidx.media3 Transformer +
/// AacAdtsCueAudioRewriter).
///
/// Root cause of "Android book cards have no sentence audio": the old Android
/// branch routed `TtsChannel.extractAudioSegment` to the native handler, whose
/// two-stage implementation has three structural failure modes —
///   #1 Transformer needs the device MediaCodec to decode the input container
///      (.m4b/.opus/.flac/HE-AAC routinely fail);
///   #2 the hand-written non-fragmented-MP4 box parser fails when any box is
///      missing and can emit a broken file for HE-AAC SBR;
///   #3 the bare ADTS .aac output is unplayable in some Anki clients.
/// Desktop never hit these because it cuts the clip with ffmpeg. Routing Android
/// through the existing FfmpegBackend (KitFfmpegBackend = self-built ffmpeg-kit,
/// same contract as the desktop CLI backend) eliminates #1/#2 — ffmpeg decodes
/// any container/codec. The output stays `.aac` (adts) because that is the only
/// audio container the desktop bundled ffmpeg-min build can mux (BUG-460: no
/// mp4/ipod/m4a muxer); keeping one suffix keeps both platforms working.
void main() {
  String libFile(String relative) =>
      File(relative).readAsStringSync().replaceAll('\r\n', '\n');

  group('sentence-audio ffmpeg routing guard (TODO-970)', () {
    test('TtsChannel.extractAudioSegment routes to ffmpeg on all platforms', () {
      final String source = libFile('lib/src/utils/misc/tts_channel.dart');

      // Pin the method body window so the assertions are scoped to it.
      final int start = source.indexOf('Future<String?> extractAudioSegment({');
      expect(start, greaterThanOrEqualTo(0),
          reason: 'extractAudioSegment must still exist on TtsChannel.');
      final int next = source.indexOf('Future<', start + 1);
      final String body =
          next > start ? source.substring(start, next) : source.substring(start);

      expect(body, contains('extractAudioSegmentViaFfmpeg('),
          reason: 'Sentence-audio cutting must delegate to the ffmpeg path so '
              'Android stops using the native Transformer handler (TODO-970).');
      expect(body.contains("invokeMethod('extractAudioSegment'"), isFalse,
          reason: 'The native MethodChannel sentence-audio handler '
              '(Transformer + AacAdtsCueAudioRewriter) must no longer be called '
              'from Dart — it caused the Android no-sentence-audio bug '
              '(#1 Transformer decode failure, #2 MP4 box parse failure). '
              'TODO-970.');
      expect(body.contains('if (!_isSupported)'), isFalse,
          reason: 'extractAudioSegment must not branch on platform anymore; '
              'both desktop and Android share the single ffmpeg path.');
    });

    test('book sentence-audio output is .aac (adts), the cross-platform muxer',
        () {
      final String source = libFile(
        'lib/src/pages/implementations/reader_hibiki/mining.part.dart',
      );
      expect(source, contains("p.join(sasayakiTempDir.path, 'sentence.aac')"),
          reason: 'Book sentence audio must be written to .aac (adts). The '
              'desktop ffmpeg-min build has no mp4/ipod/m4a muxer; .m4a would '
              'exit -22 there (BUG-460). adts is the one container both the '
              'desktop bundled build and the Android ffmpeg-kit can mux.');
      expect(source.contains("'sentence.m4a'"), isFalse,
          reason: 'Do not switch book sentence audio to .m4a: the bundled '
              'desktop ffmpeg-min cannot mux it (BUG-460).');
    });

    test('video sentence-audio output is .aac (adts), the cross-platform muxer',
        () {
      final String source = libFile(
        'lib/src/pages/implementations/video_hibiki/lookup_mining.part.dart',
      );
      expect(source, contains("'\${tmp.path}/video_mine_audio.aac'"),
          reason: 'Video sentence audio must stay .aac (adts) for the same '
              'cross-platform muxer reason as the book path (BUG-460).');
      expect(source.contains('video_mine_audio.m4a'), isFalse,
          reason: 'Do not switch video sentence audio to .m4a (no desktop '
              'm4a/ipod muxer, BUG-460).');
    });
  });
}
