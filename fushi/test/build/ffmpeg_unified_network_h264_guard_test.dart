import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-1214 / TODO-1257 / BUG-2630 guard: the unified FFmpeg (tool/ffmpeg-unified,
/// shared by the player and mining on every platform) must carry the network +
/// H.264 capabilities the runtime relies on:
///   1. YouTube / remote immersion mining feeds ffmpeg an http(s) stream with
///      `-reconnect*` input options (buildFfmpegRemoteInputArgs); without the
///      http/https/tls protocols the stream cannot be opened (TODO-1214).
///   2. Clip export to a universally-openable H.264 .mp4 needs libx264 + the mp4
///      muxer (TODO-1257).
///   3. Interconnect HLS transcode writes MPEG-TS segments (BUG-2630).
///
/// The capability floor (capabilities.json) is what every built artifact is
/// verified against; this pins the floor and each platform recipe's TLS backend
/// / GPL x264 switches, plus that smoke-test.sh exercises the real shapes.
void main() {
  String workspaceFile(String relative) =>
      File('../$relative').readAsStringSync();

  final Map<String, dynamic> caps =
      jsonDecode(workspaceFile('tool/ffmpeg-unified/capabilities.json'))
          as Map<String, dynamic>;
  Set<String> floor(String key) =>
      (caps[key] as List<dynamic>).cast<String>().toSet();

  test('capability floor carries http/https/tls/tcp/crypto protocols', () {
    expect(
      floor('protocols'),
      containsAll(<String>[
        'file',
        'pipe',
        'http',
        'https',
        'tcp',
        'tls',
        'crypto',
      ]),
      reason: 'http(s) googlevideo / HLS (AES-128) input (TODO-1214).',
    );
    expect(
      floor('tls_options'),
      contains('tls_pin_sha256'),
      reason: 'remote self-signed Fushi hosts are pinned (BUG-891).',
    );
  });

  test('capability floor carries libx264 + mp4 + mpegts', () {
    expect(floor('encoders'), contains('libx264'), reason: 'TODO-1257');
    expect(
      floor('muxers'),
      containsAll(<String>['mp4', 'mpegts']),
      reason: 'clip export .mp4 (TODO-1257), transcode segments (BUG-2630).',
    );
  });

  test('every platform recipe enables GPL x264 and a TLS backend', () {
    // Windows: MSYS2-parity build, gnutls (the backend libmpv used before too).
    final String windows = workspaceFile(
      'tool/ffmpeg-unified/windows/build_ffmpeg_msys2.sh',
    );
    for (final String flag in <String>[
      '--enable-gpl',
      '--enable-libx264',
      '--enable-gnutls',
    ]) {
      expect(windows, contains(flag), reason: 'Windows unified FFmpeg: $flag');
    }
    expect(windows.contains('--disable-network'), isFalse);
    expect(
      windows.contains('--disable-everything'),
      isFalse,
      reason: 'unified builds are full component sets (player + mining).',
    );

    // Android / iOS / macOS: FFmpegKitNext with OpenSSL.
    final String kit = workspaceFile(
      'tool/ffmpeg-unified/mobile/kit_options.sh',
    );
    for (final String flag in <String>[
      '--enable-gpl',
      '--enable-lib-x264',
      '--enable-lib-openssl',
    ]) {
      expect(kit, contains(flag), reason: 'FFmpegKitNext options: $flag');
    }
  });

  test('smoke test exercises network + libx264/mp4 + MPEG-TS segments', () {
    final String smoke = workspaceFile('tool/ffmpeg-unified/smoke-test.sh');
    expect(smoke.contains('-protocols'), isTrue, reason: 'TODO-1214');
    expect(smoke.contains('libx264'), isTrue, reason: 'TODO-1257');
    expect(
      smoke.contains(r'"$WORK/clip.mp4"'),
      isTrue,
      reason: 'a real .mp4 must be encoded and validated (TODO-1257).',
    );
    expect(smoke.contains('-f mpegts'), isTrue, reason: 'BUG-2630');
    expect(smoke.contains('-output_ts_offset'), isTrue, reason: 'BUG-2630');
    expect(smoke.contains(r'"$WORK/seg.ts"'), isTrue, reason: 'BUG-2630');
    // BUG-2630 third finding: compare the first video keyframe DTS of two
    // segments against their nominal starts, with B-frames off.
    expect(smoke.contains('-bf 0'), isTrue, reason: 'BUG-2630');
    expect(smoke.contains(r'"$WORK/seg2.ts"'), isTrue, reason: 'BUG-2630');
    expect(smoke.contains('dts_time'), isTrue, reason: 'BUG-2630');
  });
}
