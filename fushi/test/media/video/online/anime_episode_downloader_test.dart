import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:fushi/src/media/video/online/anime_episode_downloader.dart';
import 'package:fushi/src/sync/remote_video_client.dart'
    show RemoteDownloadCancelled;
import 'package:fushi/src/utils/net/hls_relay_normalizer.dart'
    show kTransportStreamPacketLength;
import 'package:path/path.dart' as p;
import 'package:pointycastle/export.dart';

/// 浏览阶段 2b：在线视频源一集的整片下载（直链 / HLS 分片 + AES-128 + 图片伪装
/// 前缀 + 断点续传 + 取消）。HLS 与直链都打本机回环 HttpServer，ffmpeg 转封装注入假件。
void main() {
  group('parseHlsMediaPlaylist', () {
    final Uri base = Uri.parse('https://cdn.example/show/ep1/index.m3u8?t=1');

    test('segments resolve against the playlist url and count from '
        'MEDIA-SEQUENCE', () {
      final HlsMediaPlaylist playlist = parseHlsMediaPlaylist(
        '#EXTM3U\n'
        '#EXT-X-VERSION:3\n'
        '#EXT-X-TARGETDURATION:10\n'
        '#EXT-X-MEDIA-SEQUENCE: 5\n'
        '#EXTINF:10.0,\n'
        'seg5.ts\n'
        '\n'
        '#EXTINF:10.0,\n'
        '/abs/seg6.ts?sig=x\n'
        '#EXTINF:10.0,\n'
        'https://other.example/seg7.ts\n'
        '#EXT-X-ENDLIST\n',
        base,
      );
      expect(playlist.segments.map((HlsSegment s) => s.uri.toString()), [
        'https://cdn.example/show/ep1/seg5.ts',
        'https://cdn.example/abs/seg6.ts?sig=x',
        'https://other.example/seg7.ts',
      ]);
      expect(playlist.segments.map((HlsSegment s) => s.sequence), [5, 6, 7]);
      expect(playlist.segments.every((HlsSegment s) => s.key == null), isTrue);
      expect(playlist.isFragmentedMp4, isFalse);
    });

    test('no MEDIA-SEQUENCE starts at 0; CRLF line endings are fine', () {
      final HlsMediaPlaylist playlist = parseHlsMediaPlaylist(
        '#EXTM3U\r\n#EXTINF:4,\r\na.ts\r\n#EXTINF:4,\r\nb.ts\r\n',
        base,
      );
      expect(playlist.segments.map((HlsSegment s) => s.sequence), [0, 1]);
      expect(playlist.segments.last.uri.path, '/show/ep1/b.ts');
    });

    test('AES-128 keys with and without IV; METHOD=NONE clears the key', () {
      final HlsMediaPlaylist playlist = parseHlsMediaPlaylist(
        '#EXTM3U\n'
        '#EXT-X-MEDIA-SEQUENCE:10\n'
        '#EXT-X-KEY:METHOD=AES-128,URI="key1.bin",IV=0x000102030405060708090A0B0C0D0E0F\n'
        '#EXTINF:4,\n'
        'a.ts\n'
        '#EXT-X-KEY:METHOD=AES-128,URI="https://keys.example/k2?a=1,b=2"\n'
        '#EXTINF:4,\n'
        'b.ts\n'
        '#EXT-X-KEY:METHOD=AES-128,URI="k3",IV=0xABC\n'
        '#EXTINF:4,\n'
        'c.ts\n'
        '#EXT-X-KEY:METHOD=NONE\n'
        '#EXTINF:4,\n'
        'd.ts\n',
        base,
      );
      final List<HlsSegment> s = playlist.segments;
      expect(s[0].key!.uri.toString(), 'https://cdn.example/show/ep1/key1.bin');
      expect(s[0].key!.iv, List<int>.generate(16, (int i) => i));
      // 带引号的 URI 里的逗号不能把属性切断。
      expect(s[1].key!.uri.toString(), 'https://keys.example/k2?a=1,b=2');
      expect(s[1].key!.iv, isNull);
      // 短 IV 左侧补零到 16 字节。
      expect(s[2].key!.iv, <int>[...List<int>.filled(14, 0), 0x0A, 0xBC]);
      expect(s[3].key, isNull);
      expect(s.map((HlsSegment x) => x.sequence), [10, 11, 12, 13]);
    });

    test('EXT-X-MAP init section applies to following segments', () {
      final HlsMediaPlaylist playlist = parseHlsMediaPlaylist(
        '#EXTM3U\n'
        '#EXTINF:4,\n'
        'pre.m4s\n'
        '#EXT-X-MAP:URI="init.mp4"\n'
        '#EXTINF:4,\n'
        'a.m4s\n'
        '#EXTINF:4,\n'
        'b.m4s\n',
        base,
      );
      expect(playlist.segments.first.initSection, isNull);
      expect(
        playlist.segments[1].initSection.toString(),
        'https://cdn.example/show/ep1/init.mp4',
      );
      expect(
        playlist.segments[2].initSection,
        playlist.segments[1].initSection,
      );
      expect(playlist.isFragmentedMp4, isTrue);
    });

    test('byte ranges and SAMPLE-AES are reported as unsupported', () {
      Matcher unsupported(String reason) => throwsA(
        isA<AnimeEpisodeDownloadUnsupported>().having(
          (AnimeEpisodeDownloadUnsupported e) => e.reason,
          'reason',
          contains(reason),
        ),
      );
      expect(
        () => parseHlsMediaPlaylist(
          '#EXTM3U\n#EXTINF:4,\n#EXT-X-BYTERANGE:1000@0\nall.ts\n',
          base,
        ),
        unsupported('byte-range'),
      );
      expect(
        () => parseHlsMediaPlaylist(
          '#EXTM3U\n#EXT-X-MAP:URI="all.mp4",BYTERANGE="800@0"\n'
          '#EXTINF:4,\na.m4s\n',
          base,
        ),
        unsupported('byte-range'),
      );
      expect(
        () => parseHlsMediaPlaylist(
          '#EXTM3U\n#EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://x"\n'
          '#EXTINF:4,\na.ts\n',
          base,
        ),
        unsupported('SAMPLE-AES'),
      );
    });
  });

  group('hlsSequenceIv', () {
    test('big-endian media sequence in a 16-byte IV', () {
      expect(hlsSequenceIv(0), Uint8List(16));
      expect(hlsSequenceIv(1), <int>[...List<int>.filled(15, 0), 1]);
      expect(hlsSequenceIv(0x0102), <int>[
        ...List<int>.filled(14, 0),
        0x01,
        0x02,
      ]);
      expect(hlsSequenceIv(0x0A0B0C0D), <int>[
        ...List<int>.filled(12, 0),
        0x0A,
        0x0B,
        0x0C,
        0x0D,
      ]);
      expect(hlsSequenceIv(7).length, 16);
    });
  });

  group('decryptHlsSegment', () {
    test('round-trips AES-128-CBC with PKCS7 padding', () {
      final Uint8List key = Uint8List.fromList(
        List<int>.generate(16, (int i) => i * 7),
      );
      final Uint8List iv = hlsSequenceIv(42);
      for (final int length in <int>[1, 15, 16, 17, 188 * 3]) {
        final Uint8List plain = Uint8List.fromList(
          List<int>.generate(length, (int i) => (i * 31) & 0xff),
        );
        final Uint8List cipher = _encrypt(plain, key, iv);
        expect(cipher.length % 16, 0);
        expect(cipher.length, greaterThan(length));
        expect(decryptHlsSegment(cipher, key, iv), plain, reason: '$length');
      }
    });

    test('a wrong key does not silently yield the plaintext', () {
      final Uint8List key = Uint8List(16);
      final Uint8List wrong = Uint8List(16)..[0] = 1;
      final Uint8List plain = _tsPackets(2);
      final Uint8List cipher = _encrypt(plain, key, hlsSequenceIv(0));
      Uint8List? out;
      try {
        out = decryptHlsSegment(cipher, wrong, hlsSequenceIv(0));
      } on Object {
        out = null; // 填充校验失败抛出也可接受。
      }
      expect(out, isNot(plain));
    });
  });

  group('unwrapHlsSegmentPayload', () {
    test('strips a PNG disguise in front of MPEG-TS', () {
      final Uint8List ts = _tsPackets(6);
      expect(unwrapHlsSegmentPayload(_pngDisguised(ts)), ts);
    });

    test('plain TS and a real image are returned unchanged', () {
      final Uint8List ts = _tsPackets(4);
      expect(identical(unwrapHlsSegmentPayload(ts), ts), isTrue);
      final Uint8List image = _pngDisguised(Uint8List(0));
      expect(unwrapHlsSegmentPayload(image), image);
    });
  });

  group('AnimeEpisodeDownloader', () {
    late Directory tmp;
    late _FixtureServer server;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('hibiki-anime-dl-');
      server = await _FixtureServer.start();
    });

    tearDown(() async {
      await server.close();
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    HttpClient plainClient() => HttpClient()..findProxy = (_) => 'DIRECT';

    AnimeEpisodeDownloader downloader(FfmpegBackend ffmpeg) =>
        AnimeEpisodeDownloader(
          httpClientFactory: plainClient,
          ffmpeg: () => ffmpeg,
        );

    test('direct file download writes the body and forwards headers', () async {
      final Uint8List body = Uint8List.fromList(
        List<int>.generate(200000, (int i) => (i * 13) & 0xff),
      );
      server.routes['/video.mp4'] = (HttpRequest request) async {
        request.response.headers.contentType = ContentType('video', 'mp4');
        request.response.contentLength = body.length;
        request.response.add(body);
        await request.response.close();
      };
      final File dest = File(p.join(tmp.path, 'out', 'ep1.mp4'));
      final List<double> progress = <double>[];
      final _FakeFfmpeg ffmpeg = _FakeFfmpeg.failing();
      await downloader(ffmpeg).download(
        url: server.url('/video.mp4'),
        headers: <String, String>{'Referer': 'https://site.example/'},
        dest: dest,
        onProgress: progress.add,
      );
      expect(await dest.readAsBytes(), body);
      expect(await File('${dest.path}.part').exists(), isFalse);
      expect(server.requests.single.path, '/video.mp4');
      expect(server.requests.single.referer, 'https://site.example/');
      expect(progress, isNotEmpty);
      expect(progress.last, closeTo(1.0, 1e-9));
      expect(ffmpeg.calls, isEmpty);
    });

    /// master → media → 两个分片：第一片 AES-128（IV = 媒体序号），第二片 PNG 伪装。
    Uint8List installHls({String mediaPath = '/hls/media.m3u8'}) {
      final Uint8List key = Uint8List.fromList(
        List<int>.generate(16, (int i) => 0xA0 + i),
      );
      final Uint8List ts1 = _tsPackets(4, seed: 3);
      final Uint8List ts2 = _tsPackets(5, seed: 5);
      server.routes['/hls/master.m3u8'] = _text(
        '#EXTM3U\n'
        '#EXT-X-STREAM-INF:BANDWIDTH=400000\n'
        'low.m3u8\n'
        '#EXT-X-STREAM-INF:BANDWIDTH=2400000\n'
        'media.m3u8\n',
      );
      server.routes[mediaPath] = _text(
        '#EXTM3U\n'
        '#EXT-X-TARGETDURATION:4\n'
        '#EXT-X-MEDIA-SEQUENCE:7\n'
        '#EXT-X-KEY:METHOD=AES-128,URI="key.bin"\n'
        '#EXTINF:4,\n'
        'seg1.ts\n'
        '#EXT-X-KEY:METHOD=NONE\n'
        '#EXTINF:4,\n'
        'seg2.png\n'
        '#EXT-X-ENDLIST\n',
      );
      final String dir = p.url.dirname(mediaPath);
      server.routes['$dir/key.bin'] = _bytes(key);
      server.routes['$dir/seg1.ts'] = _bytes(
        _encrypt(ts1, key, hlsSequenceIv(7)),
      );
      server.routes['$dir/seg2.png'] = _bytes(_pngDisguised(ts2));
      return Uint8List.fromList(<int>[...ts1, ...ts2]);
    }

    test('HLS master picks the highest variant; failed remux keeps the '
        'decrypted, unwrapped TS at dest', () async {
      final Uint8List expected = installHls();
      final File dest = File(p.join(tmp.path, 'ep1.mp4'));
      final List<double> progress = <double>[];
      final _FakeFfmpeg ffmpeg = _FakeFfmpeg.failing();
      await downloader(ffmpeg).download(
        url: server.url('/hls/master.m3u8'),
        headers: <String, String>{'Referer': 'https://site.example/'},
        dest: dest,
        onProgress: progress.add,
      );
      expect(await dest.readAsBytes(), expected);
      expect(await File('${dest.path}.hls.part').exists(), isFalse);
      expect(await File('${dest.path}.hls.progress').exists(), isFalse);
      expect(await File('${dest.path}.remux.mp4').exists(), isFalse);
      expect(server.requests.map((_Req r) => r.path), <String>[
        '/hls/master.m3u8',
        '/hls/media.m3u8',
        '/hls/seg1.ts',
        '/hls/key.bin',
        '/hls/seg2.png',
      ]);
      expect(
        server.requests.every((_Req r) => r.referer == 'https://site.example/'),
        isTrue,
      );
      expect(progress, <double>[0.5, 1.0]);
      // TS → mp4：-c copy + ADTS 转换。
      final List<String> args = ffmpeg.calls.single;
      expect(args, containsAllInOrder(<String>['-c', 'copy']));
      expect(args, contains('aac_adtstoasc'));
      expect(args[args.indexOf('-i') + 1], '${dest.path}.hls.part');
      expect(args.last, '${dest.path}.remux.mp4');
    });

    test('successful remux replaces dest with the remuxed file', () async {
      installHls();
      final File dest = File(p.join(tmp.path, 'ep1.mp4'));
      await downloader(_FakeFfmpeg.succeeding(utf8.encode('REMUXED'))).download(
        url: server.url('/hls/master.m3u8'),
        headers: const <String, String>{},
        dest: dest,
      );
      expect(await dest.readAsString(), 'REMUXED');
      expect(await File('${dest.path}.hls.part').exists(), isFalse);
      expect(await File('${dest.path}.hls.progress').exists(), isFalse);
      expect(await File('${dest.path}.remux.mp4').exists(), isFalse);
    });

    test('a playlist behind an extension-less url is sniffed and '
        'downloaded as HLS', () async {
      final Uint8List expected = installHls(mediaPath: '/hls/stream');
      final File dest = File(p.join(tmp.path, 'ep1.mp4'));
      await downloader(_FakeFfmpeg.failing()).download(
        url: server.url('/hls/stream'),
        headers: const <String, String>{},
        dest: dest,
      );
      expect(await dest.readAsBytes(), expected);
      expect(server.requests.map((_Req r) => r.path), <String>[
        '/hls/stream', // 直链尝试：拿到的是播放列表文本
        '/hls/stream', // 改走分片下载
        '/hls/seg1.ts',
        '/hls/key.bin',
        '/hls/seg2.png',
      ]);
    });

    test(
      'resumes from .hls.progress: only the missing segment is fetched',
      () async {
        final Uint8List expected = installHls();
        final File dest = File(p.join(tmp.path, 'ep1.mp4'));
        final Uint8List first = Uint8List.sublistView(expected, 0, 188 * 4);
        // 上次写完第一片后又写了半片垃圾就被杀：part 比记录长，要截回。
        await File(
          '${dest.path}.hls.part',
        ).writeAsBytes(<int>[...first, ...List<int>.filled(100, 0xEE)]);
        await File(
          '${dest.path}.hls.progress',
        ).writeAsString('1,${first.length}');
        final List<double> progress = <double>[];
        await downloader(_FakeFfmpeg.failing()).download(
          url: server.url('/hls/master.m3u8'),
          headers: const <String, String>{},
          dest: dest,
          onProgress: progress.add,
        );
        expect(await dest.readAsBytes(), expected);
        expect(server.requests.map((_Req r) => r.path), <String>[
          '/hls/master.m3u8',
          '/hls/media.m3u8',
          '/hls/seg2.png',
        ]);
        expect(progress, <double>[1.0]);
      },
    );

    test(
      'a progress record without its part file restarts from zero',
      () async {
        final Uint8List expected = installHls();
        final File dest = File(p.join(tmp.path, 'ep1.mp4'));
        await File('${dest.path}.hls.progress').writeAsString('1,752');
        await downloader(_FakeFfmpeg.failing()).download(
          url: server.url('/hls/master.m3u8'),
          headers: const <String, String>{},
          dest: dest,
        );
        expect(await dest.readAsBytes(), expected);
        expect(
          server.requests.map((_Req r) => r.path),
          contains('/hls/seg1.ts'),
        );
      },
    );

    test('cancel mid-way throws RemoteDownloadCancelled and keeps the '
        'resume record', () async {
      installHls();
      final Completer<void> seg2Arrived = Completer<void>();
      final Completer<void> release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      server.routes['/hls/seg2.png'] = (HttpRequest request) async {
        seg2Arrived.complete();
        await release.future;
        await request.response.close();
      };
      final File dest = File(p.join(tmp.path, 'ep1.mp4'));
      final Completer<void> cancel = Completer<void>();
      final Future<void> run = downloader(_FakeFfmpeg.failing()).download(
        url: server.url('/hls/master.m3u8'),
        headers: const <String, String>{},
        dest: dest,
        cancelSignal: cancel.future,
      );
      await seg2Arrived.future;
      cancel.complete();
      await expectLater(run, throwsA(isA<RemoteDownloadCancelled>()));
      expect(await dest.exists(), isFalse);
      expect(
        await File('${dest.path}.hls.progress').readAsString(),
        '1,${188 * 4}',
      );
      expect(await File('${dest.path}.hls.part').length(), 188 * 4);
    });

    test('HTTP errors on a segment surface as failures, not cancels', () async {
      installHls();
      server.routes['/hls/seg2.png'] = (HttpRequest request) async {
        request.response.statusCode = 403;
        await request.response.close();
      };
      final File dest = File(p.join(tmp.path, 'ep1.mp4'));
      await expectLater(
        downloader(_FakeFfmpeg.failing()).download(
          url: server.url('/hls/master.m3u8'),
          headers: const <String, String>{},
          dest: dest,
        ),
        throwsA(isA<HttpException>()),
      );
      expect(await dest.exists(), isFalse);
    });
  });
}

Uint8List _encrypt(Uint8List plain, Uint8List key, Uint8List iv) {
  final PaddedBlockCipher cipher =
      PaddedBlockCipherImpl(PKCS7Padding(), CBCBlockCipher(AESEngine()))..init(
        true,
        PaddedBlockCipherParameters<CipherParameters, CipherParameters?>(
          ParametersWithIV<KeyParameter>(KeyParameter(key), iv),
          null,
        ),
      );
  return cipher.process(plain);
}

/// MPEG-TS 包：每包 0x47 起头，包内不出现假同步字节。
Uint8List _tsPackets(int count, {int seed = 1}) {
  final Uint8List out = Uint8List(kTransportStreamPacketLength * count);
  for (int packet = 0; packet < count; packet++) {
    final int base = packet * kTransportStreamPacketLength;
    out[base] = 0x47;
    for (int i = 1; i < kTransportStreamPacketLength; i++) {
      out[base + i] = (i * seed + packet) & 0xff;
      if (out[base + i] == 0x47) out[base + i] = 0x48;
    }
  }
  return out;
}

/// 真流形状（BUG-2609）：1×1 PNG 垫零到 252 字节，之后才是媒体。
Uint8List _pngDisguised(Uint8List media) {
  final List<int> png = <int>[
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
    0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, //
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00,
    0x00, 0x1F, 0x15, 0xC4, 0x89, //
    0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
  ];
  final Uint8List prefix = Uint8List(252)..setRange(0, png.length, png);
  return Uint8List.fromList(<int>[...prefix, ...media]);
}

typedef _Handler = Future<void> Function(HttpRequest request);

_Handler _text(String body) => (HttpRequest request) async {
  request.response.headers.contentType = ContentType(
    'application',
    'vnd.apple.mpegurl',
  );
  request.response.write(body);
  await request.response.close();
};

_Handler _bytes(Uint8List body) => (HttpRequest request) async {
  request.response.contentLength = body.length;
  request.response.add(body);
  await request.response.close();
};

class _Req {
  const _Req(this.path, this.referer);

  final String path;
  final String? referer;
}

class _FixtureServer {
  _FixtureServer._(this._server) {
    _server.listen((HttpRequest request) async {
      requests.add(
        _Req(
          request.uri.path,
          request.headers.value(HttpHeaders.refererHeader),
        ),
      );
      final _Handler? handler = routes[request.uri.path];
      if (handler == null) {
        request.response.statusCode = 404;
        await request.response.close();
        return;
      }
      try {
        await handler(request);
      } on Object {
        // 客户端被强制关闭时写响应会失败：测试只看客户端侧。
      }
    });
  }

  static Future<_FixtureServer> start() async =>
      _FixtureServer._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  final HttpServer _server;
  final Map<String, _Handler> routes = <String, _Handler>{};
  final List<_Req> requests = <_Req>[];

  String url(String path) => 'http://127.0.0.1:${_server.port}$path';

  Future<void> close() => _server.close(force: true);
}

class _FakeFfmpeg implements FfmpegBackend {
  _FakeFfmpeg.failing() : _output = null;
  _FakeFfmpeg.succeeding(List<int> output) : _output = output;

  final List<int>? _output;
  final List<List<String>> calls = <List<String>>[];

  @override
  Future<FfmpegRunResult> run(List<String> args, Duration timeout) async {
    calls.add(args);
    final List<int>? output = _output;
    if (output == null) {
      return const FfmpegRunResult(returnCode: 1, output: 'no muxer');
    }
    await File(args.last).writeAsBytes(output);
    return const FfmpegRunResult(returnCode: 0, output: '');
  }

  @override
  Future<FfmpegRunResult> runProbe(List<String> args, Duration timeout) =>
      throw UnimplementedError();
}
