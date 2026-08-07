import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/immersion_mining_request.dart';

/// BUG-460 source-scan guard: the audiobook clip-export pipeline must only emit
/// containers the bundled "ffmpeg-min" desktop build can actually mux.
///
/// Root cause: the desktop bundled ffmpeg is built with `--disable-everything`
/// (tool/ffmpeg-min/build-ffmpeg-min.sh) and only enables a tiny muxer
/// whitelist. It has NO `ipod`/`mov`/`mp4`/`m4a` muxer. The clip pipeline wrote
/// the sentence audio to `.m4a` (which auto-selects the absent ipod/mov muxer)
/// → ffmpeg `exit -22` (EINVAL), crashing every audiobook clip export. The text
/// + audio synthesis stage further wrote `.mov` — a video+audio container that
/// the whitelist never contained at all (adts/gif/image2/mjpeg are all
/// single-stream).
///
/// Fix (contract-level, no symptom patch):
///   1. Audio clip output `.m4a` → `.aac` (adts muxer, already whitelisted and
///      the ffmpeg-min spec's contracted sentence-audio container).
///   2. Add `mov` to the build whitelist so the designed mjpeg+aac `.mov` clip
///      video can actually be muxed (LGPL, tiny; AAC-in-mov auto-uses the
///      already-enabled `aac_adtstoasc` bsf).
///
/// A real cross-platform ffmpeg build can't run in CI here, so this guards the
/// *mechanism*: the build whitelist carries `mov`, and the Dart pipeline never
/// emits a `.m4a`/`.mp4` the bundled build can't produce.
void main() {
  // Tests run with CWD = `hibiki/`; the build script lives at the workspace root.
  String workspaceFile(String relative) =>
      File('../$relative').readAsStringSync();

  String libFile(String relative) => File(relative).readAsStringSync();

  test('ffmpeg-min build whitelist enables the mov muxer for clip export', () {
    final String script = workspaceFile('tool/ffmpeg-min/build-ffmpeg-min.sh');
    final RegExp muxers = RegExp(r'^MUXERS="([^"]*)"', multiLine: true);
    final RegExpMatch? m = muxers.firstMatch(script);
    expect(m, isNotNull,
        reason: 'build-ffmpeg-min.sh must declare a MUXERS whitelist');
    final List<String> list = m!.group(1)!.split(',');
    expect(list, contains('mov'),
        reason: 'clip video synth writes .mov (mjpeg+aac); without the mov '
            'muxer ffmpeg exits -22 (EINVAL). BUG-460.');
    expect(list, contains('adts'),
        reason: 'sentence audio clip writes .aac (adts container).');
  });

  test('ffmpeg-min build keeps the aac_adtstoasc bsf (AAC into mov)', () {
    final String script = workspaceFile('tool/ffmpeg-min/build-ffmpeg-min.sh');
    final RegExp bsfs = RegExp(r'^BSFS="([^"]*)"', multiLine: true);
    final RegExpMatch? b = bsfs.firstMatch(script);
    expect(b, isNotNull);
    expect(b!.group(1)!.split(','), contains('aac_adtstoasc'),
        reason: 'muxing ADTS AAC into a .mov requires the aac_adtstoasc bsf.');
  });

  test('ffmpeg-min build whitelist enables the mp4 muxer for video clips', () {
    // BUG-917: video clip export writes .mp4 (was: the source container). The
    // bundled ffmpeg-min has NO matroska/webm/avi/mpegts muxer, so following the
    // source extension (mkv/webm/…) auto-selected an absent muxer → exit -22.
    final String script = workspaceFile('tool/ffmpeg-min/build-ffmpeg-min.sh');
    final RegExp muxers = RegExp(r'^MUXERS="([^"]*)"', multiLine: true);
    final List<String> list = muxers.firstMatch(script)!.group(1)!.split(',');
    expect(list, contains('mp4'),
        reason: 'video clip export targets .mp4 (h264/hevc copy or libx264 '
            're-encode); without the mp4 muxer it exits -22. BUG-917.');
    expect(list, isNot(contains('matroska')),
        reason: 'ffmpeg-min has no matroska muxer — proof the clip export must '
            'NOT follow a .mkv source extension. BUG-917.');
  });

  test('ffmpeg-min build enables libx264 for the clip re-encode fallback', () {
    // The copy→re-encode fallback (BUG-917) needs libx264; the build turns it on
    // via --enable-gpl --enable-libx264 (TODO-1257).
    final String script = workspaceFile('tool/ffmpeg-min/build-ffmpeg-min.sh');
    expect(script, contains('--enable-libx264'),
        reason: 'clip re-encode fallback muxes libx264 into .mp4. BUG-917.');
    final String encoders = RegExp(r'^ENCODERS="([^"]*)"', multiLine: true)
        .firstMatch(script)!
        .group(1)!;
    expect(encoders.split(','), contains('libx264'));
  });

  test('video clip export names the output .mp4, never the source container',
      () {
    // Source-scan guard: the clip export path must build a .mp4 filename and
    // must not derive the extension from the input path (BUG-917 regression).
    final String clip = libFile(
      'lib/src/pages/implementations/video_hibiki/clip_export.part.dart',
    );
    expect(clip.contains(".mp4'"), isTrue,
        reason: 'clip export must write .mp4 (ffmpeg-min muxable + universal). '
            'BUG-917.');
    expect(clip.contains('p.extension(inputPath)'), isFalse,
        reason: 'clip output extension must NOT follow the source container — '
            'mkv/webm/avi/ts have no muxer in ffmpeg-min → exit -22. BUG-917.');
  });

  test('audiobook clip pipeline emits .aac audio, never .m4a/.mp4', () {
    final String pipeline = libFile(
      'lib/src/pages/implementations/reader_fushi/audiobook.part.dart',
    );
    // The audio clip output path passed to extractAudioSegmentViaFfmpeg.
    expect(pipeline, contains(r"outputPath: '$base.aac'"),
        reason: 'sentence audio must be written to .aac (adts); .m4a needs the '
            'absent ipod/mov muxer → exit -22. BUG-460.');
    expect(pipeline.contains(r"'$base.m4a'"), isFalse,
        reason: 'clip pipeline must not write .m4a (no m4a/ipod muxer in the '
            'bundled ffmpeg-min build). BUG-460.');
    expect(pipeline.contains(r"'$base.mp4'"), isFalse,
        reason: 'clip pipeline must not write .mp4 (no mp4 muxer). BUG-460.');
  });

  // TODO-1217: the immersion mining engine (Netflix/YouTube/in-app video cards)
  // shares the same desktop ffmpeg-min constraint. da22cd42a hardcoded the clip
  // audio to `.m4a` for iOS AnkiMobile, but the desktop bundled build cannot mux
  // ipod/mp4 → `.m4a` exits -22 → null audio → silent cards. The fix routes the
  // container through immersionMiningAudioExtension() (iOS m4a / desktop+Android
  // aac). These guards pin both the helper's mapping and that the engine + the
  // Netflix capture channel go through it (never a hardcoded suffix).
  test('immersion audio extension is desktop/Android=aac, iOS=m4a', () {
    expect(immersionMiningAudioExtensionFor(isIOS: false), 'aac',
        reason: 'Desktop + Android must use .aac (adts): the bundled '
            'ffmpeg-min has no ipod/mp4 muxer, so .m4a exits -22 (TODO-1217).');
    expect(immersionMiningAudioExtensionFor(isIOS: true), 'm4a',
        reason: 'iOS AnkiMobile only auto-downloads media-recognized URLs; it '
            'needs .m4a, and iOS ffmpeg-kit has the ipod muxer (da22cd42a).');
  });

  test('the desktop immersion audio container is muxable by ffmpeg-min', () {
    // The desktop/Android branch container (.aac → adts muxer) MUST be in the
    // build whitelist, otherwise desktop immersion cards go silent (TODO-1217).
    final String script = workspaceFile('tool/ffmpeg-min/build-ffmpeg-min.sh');
    final RegExp muxers = RegExp(r'^MUXERS="([^"]*)"', multiLine: true);
    final List<String> list = muxers.firstMatch(script)!.group(1)!.split(',');
    // desktop/Android extension .aac is muxed by 'adts'.
    expect(immersionMiningAudioExtensionFor(isIOS: false), 'aac');
    expect(list, contains('adts'),
        reason: 'desktop immersion clip audio writes .aac (adts container); '
            'without the adts muxer the card has no audio (TODO-1217).');
    expect(list, isNot(contains('ipod')),
        reason: 'ffmpeg-min still has no ipod muxer — proof the desktop branch '
            'must NOT use .m4a (TODO-1217).');
  });

  test(
      'immersion engine + capture channel derive the audio container from the '
      'platform-aware helper, never a hardcoded .m4a/.mp4', () {
    final String engine =
        libFile('lib/src/mining/immersion_mining_engine.dart');
    final String capture =
        libFile('lib/src/mining/immersion_capture_channel.dart');
    for (final MapEntry<String, String> e in <String, String>{
      'immersion_mining_engine.dart': engine,
      'immersion_capture_channel.dart': capture,
    }.entries) {
      expect(e.value.contains(r'.${immersionMiningAudioExtension()}'), isTrue,
          reason: '${e.key} must build the clip audio filename from '
              'immersionMiningAudioExtension() (TODO-1217).');
      expect(
          e.value.contains('immersion_audio.m4a') ||
              e.value.contains('clip.m4a') ||
              e.value.contains('netflix_audio.m4a'),
          isFalse,
          reason: '${e.key} must not hardcode a .m4a clip audio name — the '
              'desktop ffmpeg-min cannot mux it → exit -22 → silent cards '
              '(TODO-1217/BUG-460).');
    }
  });
}
