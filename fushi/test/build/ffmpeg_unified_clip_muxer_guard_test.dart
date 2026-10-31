import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/mining/immersion_mining_request.dart';

/// Containers the clip / mining / audiobook pipelines emit must be muxable by
/// the unified FFmpeg on every platform (BUG-460, BUG-917, TODO-1217).
///
/// History: the desktop used to ship "ffmpeg-min", a `--disable-everything`
/// whitelist build without ipod/mov/mp4 muxers; writing `.m4a` / `.mov` or
/// following a `.mkv` source extension made ffmpeg exit -22 and silently lost
/// card audio / clips. Since the unified FFmpeg (tool/ffmpeg-unified, the same
/// build the player links) the build is a full component set, and
/// `capabilities.json` is the floor every platform's artifact is verified
/// against (verify_ffmpeg_capabilities.py on desktop, verify_mobile_outputs.py
/// on mobile). This guard pins that the floor keeps what these pipelines write,
/// and that the Dart pipelines keep their container contracts.
void main() {
  // Tests run with CWD = `fushi/`; the recipe lives at the workspace root.
  final Map<String, dynamic> caps =
      jsonDecode(
            File('../tool/ffmpeg-unified/capabilities.json').readAsStringSync(),
          )
          as Map<String, dynamic>;
  Set<String> floor(String key) =>
      (caps[key] as List<dynamic>).cast<String>().toSet();

  String libFile(String relative) => File(relative).readAsStringSync();

  test('capability floor keeps the clip export muxers (mov / adts / mp4)', () {
    expect(
      floor('muxers'),
      containsAll(<String>['mov', 'adts', 'mp4']),
      reason:
          'clip video synth writes .mov (mjpeg+aac), sentence audio .aac '
          '(adts), video clips .mp4; a missing muxer exits -22. BUG-460/917.',
    );
    expect(
      floor('bsfs'),
      contains('aac_adtstoasc'),
      reason: 'muxing ADTS AAC into a .mov requires the aac_adtstoasc bsf.',
    );
    expect(
      floor('encoders'),
      containsAll(<String>['libx264', 'aac', 'mjpeg']),
      reason: 'clip re-encode fallback muxes libx264 into .mp4. BUG-917.',
    );
  });

  test(
    'video clip export names the output .mp4, never the source container',
    () {
      // The output stays .mp4 (universally playable) even though the unified
      // FFmpeg now has matroska/webm muxers: the contract is about the exported
      // file, not about what the build could mux (BUG-917).
      final String clip = libFile(
        'lib/src/pages/implementations/video_fushi/clip_export.part.dart',
      );
      expect(
        clip.contains(".mp4'"),
        isTrue,
        reason: 'clip export must write .mp4 (universally playable). BUG-917.',
      );
      expect(
        clip.contains('p.extension(inputPath)'),
        isFalse,
        reason:
            'clip output extension must NOT follow the source container. '
            'BUG-917.',
      );
    },
  );

  test('audiobook clip pipeline emits .aac audio, never .m4a/.mp4', () {
    final String pipeline = libFile(
      'lib/src/pages/implementations/reader_fushi/audiobook.part.dart',
    );
    expect(
      pipeline,
      contains(r"outputPath: '$base.aac'"),
      reason: 'sentence audio is written to .aac (adts). BUG-460.',
    );
    expect(
      pipeline.contains(r"'$base.m4a'"),
      isFalse,
      reason: 'clip pipeline must not write .m4a. BUG-460.',
    );
    expect(
      pipeline.contains(r"'$base.mp4'"),
      isFalse,
      reason: 'clip pipeline must not write .mp4. BUG-460.',
    );
  });

  // TODO-1217: iOS AnkiMobile only auto-downloads media-recognized URLs and
  // needs .m4a; desktop + Android stay on .aac (adts), which every build muxes.
  test('immersion audio extension is desktop/Android=aac, iOS=m4a', () {
    expect(immersionMiningAudioExtensionFor(isIOS: false), 'aac');
    expect(immersionMiningAudioExtensionFor(isIOS: true), 'm4a');
    expect(
      floor('muxers'),
      containsAll(<String>['adts', 'ipod']),
      reason: '.aac needs adts, iOS .m4a needs the ipod muxer (TODO-1217).',
    );
  });

  test('capability floor carries the audiobook studio loudness + M4B set', () {
    // Audiobook studio export: EBU R128 loudness normalisation (loudnorm two
    // pass, ebur128 measure, volume trim, alimiter true-peak guard, apad /
    // anullsrc silence) and an .m4b (ipod muxer) with chapters/metadata from an
    // ;FFMETADATA1 side input (ffmetadata demuxer) plus a jpg/png cover.
    expect(
      floor('filters'),
      containsAll(<String>[
        'loudnorm',
        'ebur128',
        'volume',
        'alimiter',
        'apad',
        'anullsrc',
        'aresample',
      ]),
    );
    expect(floor('muxers'), containsAll(<String>['ipod', 'mp4']));
    expect(floor('demuxers'), containsAll(<String>['ffmetadata', 'image2']));
    expect(floor('decoders'), containsAll(<String>['mjpeg', 'png']));
    expect(floor('encoders'), contains('aac'));
  });

  test('immersion engine + capture channel derive the audio container from the '
      'platform-aware helper, never a hardcoded .m4a/.mp4', () {
    final String engine = libFile(
      'lib/src/mining/immersion_mining_engine.dart',
    );
    final String capture = libFile(
      'lib/src/mining/immersion_capture_channel.dart',
    );
    for (final MapEntry<String, String> e in <String, String>{
      'immersion_mining_engine.dart': engine,
      'immersion_capture_channel.dart': capture,
    }.entries) {
      expect(
        e.value.contains(r'.${immersionMiningAudioExtension()}'),
        isTrue,
        reason:
            '${e.key} must build the clip audio filename from '
            'immersionMiningAudioExtension() (TODO-1217).',
      );
      expect(
        e.value.contains('immersion_audio.m4a') ||
            e.value.contains('clip.m4a') ||
            e.value.contains('netflix_audio.m4a'),
        isFalse,
        reason:
            '${e.key} must not hardcode a .m4a clip audio name '
            '(TODO-1217/BUG-460).',
      );
    }
  });
}
