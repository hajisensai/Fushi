import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-1214 / TODO-1257 source-scan guard: the desktop bundled "ffmpeg-min"
/// build (tool/ffmpeg-min/build-ffmpeg-min.sh) must carry the network + H.264
/// capabilities the runtime relies on.
///
/// Root cause (before this change): the build used `--disable-network` +
/// `PROTOCOLS="file,pipe"` and had no libx264 encoder / mp4 muxer. Two features
/// broke on desktop:
///   1. YouTube / remote immersion mining feeds ffmpeg an http(s) googlevideo
///      stream and adds `-reconnect*` input options
///      (buildFfmpegRemoteInputArgs, desktop_audio_clipper.dart). Without the
///      http/https protocol those options fail with AVERROR_OPTION_NOT_FOUND
///      and the stream can't be opened at all (TODO-1214, BUG-528/529).
///   2. Clip export to a universally-openable H.264 .mp4 (TODO-1257) needs the
///      libx264 encoder + mp4 muxer, neither of which was enabled.
///
/// A real cross-platform ffmpeg build can't run in CI here, so this guards the
/// *build recipe*: enable-network + http/https/tls protocols + libx264 + mp4,
/// plus a per-platform TLS backend (Windows schannel), and the CI workflow that
/// installs the required dev packages.
void main() {
  String workspaceFile(String relative) =>
      File('../$relative').readAsStringSync();

  String buildScript() => workspaceFile('tool/ffmpeg-min/build-ffmpeg-min.sh');

  List<String> listVar(String script, String name) {
    final RegExp re = RegExp('^$name="([^"]*)"', multiLine: true);
    final RegExpMatch? m = re.firstMatch(script);
    expect(m, isNotNull, reason: 'build-ffmpeg-min.sh must declare $name');
    return m!.group(1)!.split(',');
  }

  test('ffmpeg-min build enables network (never --disable-network)', () {
    final String script = buildScript();
    expect(script.contains('--enable-network'), isTrue,
        reason: 'YouTube/remote mining needs http(s) protocols; without '
            '--enable-network the -reconnect options fail with '
            'AVERROR_OPTION_NOT_FOUND (TODO-1214).');
    expect(script.contains('--disable-network'), isFalse,
        reason: 'a lingering --disable-network would strip all protocols and '
            'break YouTube mining (TODO-1214).');
  });

  test('ffmpeg-min PROTOCOLS whitelist carries http/https/tls/tcp', () {
    final List<String> protocols = listVar(buildScript(), 'PROTOCOLS');
    for (final String p in <String>[
      'file',
      'pipe',
      'http',
      'https',
      'tcp',
      'tls'
    ]) {
      expect(protocols, contains(p),
          reason: 'protocol "$p" is required for http(s) googlevideo stream '
              'input (TODO-1214).');
    }
  });

  test('ffmpeg-min enables libx264 (H.264) + mp4 for clip export', () {
    final String script = buildScript();
    expect(script.contains('--enable-gpl'), isTrue,
        reason: 'libx264 is GPL, so the build must pass --enable-gpl '
            '(TODO-1257).');
    expect(script.contains('--enable-libx264'), isTrue,
        reason: 'H.264 clip export needs the libx264 encoder (TODO-1257).');
    expect(listVar(script, 'ENCODERS'), contains('libx264'),
        reason: 'with --disable-everything the libx264 encoder must be '
            'explicitly enabled (TODO-1257).');
    expect(listVar(script, 'MUXERS'), contains('mp4'),
        reason: 'H.264 clip export writes .mp4; the mp4 muxer must be enabled '
            '(TODO-1257).');
  });

  test('ffmpeg-min selects a per-platform native TLS backend', () {
    final String script = buildScript();
    // https(googlevideo) needs a TLS backend for the tls protocol. Windows uses
    // schannel (system secur32, no external DLL); macOS SecureTransport; Linux
    // gnutls (LGPL). Windows is the only shipped desktop binary, so schannel is
    // the load-bearing one.
    expect(script.contains('--enable-schannel'), isTrue,
        reason: 'Windows (the shipped desktop ffmpeg-min) must use the native '
            'schannel TLS backend for https input (TODO-1214).');
    expect(script.contains('--enable-securetransport'), isTrue,
        reason: 'macOS build uses the native SecureTransport TLS backend.');
    expect(script.contains('--enable-gnutls'), isTrue,
        reason: 'Linux build uses the LGPL gnutls TLS backend.');
  });

  test('ffmpeg-min smoke test exercises network + libx264/mp4', () {
    final String smoke = workspaceFile('tool/ffmpeg-min/smoke-test.sh');
    expect(smoke.contains('-protocols'), isTrue,
        reason:
            'smoke test must assert the http/https/tls protocols exist so a '
            'dropped --enable-network fails the build, not the user (TODO-1214).');
    expect(smoke.contains('libx264'), isTrue,
        reason: 'smoke test must assert the libx264 encoder is present '
            '(TODO-1257).');
    expect(smoke.contains(r'"$WORK/clip.mp4"'), isTrue,
        reason: 'smoke test must actually encode a real .mp4 with libx264 and '
            'validate it (a compile alone is insufficient, TODO-1257).');
  });

  test('ffmpeg-min CI workflow installs x264 + TLS dev packages', () {
    final String workflow = workspaceFile('.github/workflows/ffmpeg-min.yml');
    // Linux: libx264-dev + gnutls; macOS: brew x264 (securetransport built-in);
    // Windows: mingw x264 (schannel built-in).
    expect(workflow.contains('libx264-dev'), isTrue,
        reason:
            'Linux CI must install libx264-dev to link libx264 (TODO-1257).');
    expect(workflow.contains('libgnutls28-dev'), isTrue,
        reason: 'Linux CI must install gnutls dev for the tls protocol '
            '(TODO-1214).');
    expect(workflow.contains('mingw-w64-x86_64-x264'), isTrue,
        reason: 'Windows MSYS2 CI must install x264 so the shipped ffmpeg.exe '
            'links libx264 (TODO-1257).');
  });
}
