import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

/// BUG-3507 收尾：media_kit 补丁把 `on_load` / `on_unload` 钩子体与
/// `observeProperty`（FORMAT_NONE）的取值都挪出了事件循环、改走 `mpv_*_async`，
/// 钩子的注册 / 放行（`mpv_hook_add` / `mpv_hook_continue`，libmpv 没有异步版、
/// 会拿内核锁）挪到辅助 isolate。这里用真 libmpv 钉住行为没有因此走样：
///
/// - `Media.httpHeaders` 仍在 on_load 里写进 `http-header-fields`，请求真带上头；
/// - `Media.start` 仍在 on_load 里生效（钩子放行之后才开始播放）；
/// - `observeProperty` 的监听仍收到值，且不在事件分发的同一同步段里读（异步回包）。
///
/// 需要真实 libmpv：`FUSHI_TEST_LIBMPV` 指向 libmpv-2.dll，或先构建 Windows Debug。
String? _libmpvPath() {
  final String? override = Platform.environment['FUSHI_TEST_LIBMPV'];
  final String path = override ?? 'build/windows/x64/runner/Debug/libmpv-2.dll';
  return File(path).existsSync() ? File(path).absolute.path : null;
}

/// 8 kHz 单声道 16 位静音 WAV，[seconds] 秒。
Uint8List _silentWav(int seconds) {
  const int rate = 8000;
  final int dataBytes = rate * 2 * seconds;
  final ByteData b = ByteData(44 + dataBytes);
  void ascii(int offset, String s) {
    for (int i = 0; i < s.length; i++) {
      b.setUint8(offset + i, s.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  b.setUint32(4, 36 + dataBytes, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  b.setUint32(16, 16, Endian.little);
  b.setUint16(20, 1, Endian.little); // PCM
  b.setUint16(22, 1, Endian.little); // mono
  b.setUint32(24, rate, Endian.little);
  b.setUint32(28, rate * 2, Endian.little);
  b.setUint16(32, 2, Endian.little);
  b.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  b.setUint32(40, dataBytes, Endian.little);
  return b.buffer.asUint8List();
}

void main() {
  final String? libmpv = _libmpvPath();
  final String? skip = libmpv == null
      ? 'Build Windows Debug or set FUSHI_TEST_LIBMPV to libmpv-2.dll'
      : null;

  setUpAll(() {
    if (libmpv != null) MediaKit.ensureInitialized(libmpv: libmpv);
  });

  Future<(Player, dynamic)> openPlayer() async {
    final Player player = Player();
    final dynamic native = player.platform;
    addTearDown(() async {
      if (native.disposed == false) {
        await player.dispose();
      }
    });
    await native.setProperty('vo', 'null');
    await native.setProperty('ao', 'null');
    return (player, native);
  }

  test(
    'on_load still applies Media.httpHeaders and Media.start',
    () async {
      final Uint8List wav = _silentWav(20);
      final List<String?> seenHeaders = <String?>[];
      final HttpServer server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(() => server.close(force: true));
      server.listen((HttpRequest request) async {
        seenHeaders.add(request.headers.value('x-fushi-hook'));
        // 支持 Range：start 要靠 seek 生效，不可 seek 的流 mpv 会忽略它。
        final HttpResponse response = request.response;
        response.headers.contentType = ContentType('audio', 'wav');
        response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
        int from = 0;
        final Match? range = RegExp(
          r'bytes=(\d+)-',
        ).firstMatch(request.headers.value(HttpHeaders.rangeHeader) ?? '');
        if (range != null) {
          from = int.parse(range.group(1)!).clamp(0, wav.length);
          response.statusCode = HttpStatus.partialContent;
          response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes $from-${wav.length - 1}/${wav.length}',
          );
        }
        response.contentLength = wav.length - from;
        response.add(Uint8List.sublistView(wav, from));
        await response.close();
      });

      final (Player player, dynamic native) = await openPlayer();
      final Completer<void> playing = Completer<void>();
      final StreamSubscription<Duration> sub = player.stream.position.listen((
        Duration p,
      ) {
        if (p > Duration.zero && !playing.isCompleted) playing.complete();
      });
      addTearDown(sub.cancel);

      await player.open(
        Media(
          'http://127.0.0.1:${server.port}/silence.wav',
          httpHeaders: const <String, String>{'X-Fushi-Hook': 'bug-3507'},
          start: const Duration(seconds: 7),
        ),
      );
      await playing.future.timeout(const Duration(seconds: 30));

      expect(seenHeaders, isNotEmpty, reason: 'libmpv 根本没发请求');
      expect(
        seenHeaders.first,
        'bug-3507',
        reason: 'on_load 钩子必须在放行前把 http-header-fields 写进去',
      );
      final double timePos = double.parse(
        await native.getPropertyAsync('time-pos') as String,
      );
      expect(
        timePos,
        greaterThanOrEqualTo(6.5),
        reason: 'on_load 钩子必须在放行前把 start 写进去（从 7 s 起播）',
      );
    },
    skip: skip,
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'observeProperty listener receives the value through an async reply',
    () async {
      final (Player _, dynamic native) = await openPlayer();
      final List<String> values = <String>[];
      final Completer<void> got = Completer<void>();
      await native.observeProperty('volume', (String v) async {
        values.add(v);
        if (double.tryParse(v) == 42 && !got.isCompleted) got.complete();
      });
      await native.setProperty('volume', '42');
      await got.future.timeout(const Duration(seconds: 10));
      expect(double.parse(values.last), 42);
      await native.unobserveProperty('volume');
    },
    skip: skip,
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
