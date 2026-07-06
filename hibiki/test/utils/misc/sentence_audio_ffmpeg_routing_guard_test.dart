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
/// any container/codec. The output suffix still must be selected by platform:
/// iOS AnkiMobile needs `.m4a`, while desktop/Android keep `.aac` for the
/// bundled ffmpeg-min adts-only muxer (BUG-460 / BUG-569).
void main() {
  String libFile(String relative) =>
      File(relative).readAsStringSync().replaceAll('\r\n', '\n');

  group('sentence-audio ffmpeg routing guard (TODO-970)', () {
    test('TtsChannel.extractAudioSegment routes to ffmpeg on all platforms',
        () {
      final String source = libFile('lib/src/utils/misc/tts_channel.dart');

      // Pin the method body window so the assertions are scoped to it.
      final int start = source.indexOf('Future<String?> extractAudioSegment({');
      expect(start, greaterThanOrEqualTo(0),
          reason: 'extractAudioSegment must still exist on TtsChannel.');
      final int next = source.indexOf('Future<', start + 1);
      final String body = next > start
          ? source.substring(start, next)
          : source.substring(start);

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

    test(
        'book sentence-audio container is platform-aware '
        '(iOS .m4a / desktop+Android .aac), BUG-569', () {
      final String source = libFile(
        'lib/src/pages/implementations/reader_hibiki/mining.part.dart',
      );
      expect(source, contains(r"'sentence.${immersionMiningAudioExtension()}'"),
          reason: 'Book/audiobook sentence audio must derive its container '
              'from immersionMiningAudioExtension() too. iOS AnkiMobile leaves '
              'raw .aac localhost URLs as visible text, while desktop '
              'ffmpeg-min still needs .aac/adts (BUG-460 / BUG-569).');
      expect(source.contains("'sentence.aac'"), isFalse,
          reason: 'Do not hardcode .aac for book sentence audio: iOS '
              'AnkiMobile leaves the localhost URL visible instead of '
              'embedding playable media (BUG-569).');
      expect(source.contains("'sentence.m4a'"), isFalse,
          reason: 'Do not switch book sentence audio to .m4a: the bundled '
              'desktop ffmpeg-min cannot mux it (BUG-460).');
    });

    test(
        'video sentence-audio container is platform-aware '
        '(iOS .m4a / desktop+Android .aac), TODO-1217', () {
      // TODO-1000: video sentence-audio cutting moved out of _mineVideoCard
      // (lookup_mining.part.dart) into the shared ImmersionMiningEngine, which
      // cuts the clip via extractAudioSegmentViaFfmpeg.
      //
      // TODO-1217 regression fix: the container extension is now chosen at
      // runtime by immersionMiningAudioExtension() — iOS gets `.m4a` (AnkiMobile
      // only auto-downloads media-recognized URLs; ffmpeg-kit has the ipod
      // muxer), desktop/Android get `.aac` (the desktop bundled ffmpeg-min has
      // NO ipod/mp4 muxer, so a hardcoded `.m4a` exits -22 → null audio →
      // silent Netflix/YouTube/in-app cards). Hardcoding either suffix breaks
      // one platform; the engine must go through the helper, never a literal.
      final String engine =
          libFile('lib/src/mining/immersion_mining_engine.dart');
      expect(
          engine,
          contains(
              r"'$tempDir/immersion_audio.${immersionMiningAudioExtension()}'"),
          reason: 'Immersion sentence audio must derive its container from '
              'immersionMiningAudioExtension() (iOS m4a / desktop+Android aac), '
              'never a hardcoded suffix — a literal .m4a exits -22 on the '
              'desktop ffmpeg-min build (TODO-1217).');
      expect(engine.contains("immersion_audio.m4a'"), isFalse,
          reason: 'Do not hardcode .m4a for immersion sentence audio: the '
              'bundled desktop ffmpeg-min cannot mux it (no ipod muxer) → '
              'exit -22 → silent cards (TODO-1217/BUG-460).');
      expect(engine.contains("immersion_audio.aac'"), isFalse,
          reason: 'Do not hardcode .aac either: iOS AnkiMobile leaves a raw '
              '.aac localhost URL as visible text (da22cd42a). Use the '
              'platform-aware helper.');
      expect(engine, contains('await _audio('),
          reason: 'Sentence audio must be cut via the ffmpeg audio extractor '
              '(_audio defaults to extractAudioSegmentViaFfmpeg), TODO-1000.');
      expect(engine.contains('extractAudioSegmentViaFfmpeg'), isTrue,
          reason: 'The engine audio extractor default must be the ffmpeg path '
              '(never the native Transformer handler), TODO-970/TODO-1000.');
    });
  });
}
