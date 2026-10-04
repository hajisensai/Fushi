import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:fushi/src/media/video/online/anime_episode_downloader.dart';
import 'package:fushi/src/sync/interconnect_download_manager.dart';
import 'package:fushi/src/sync/remote_video_client.dart'
    show RemoteDownloadCancelled;
import 'package:fushi/src/utils/misc/error_log_service.dart';
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

    AnimeEpisodeDownloader downloader(
      FfmpegBackend ffmpeg, {
      Duration stallTimeout = kAnimeEpisodeStallTimeout,
    }) => AnimeEpisodeDownloader(
      httpClientFactory: plainClient,
      ffmpeg: () => ffmpeg,
      stallTimeout: stallTimeout,
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

    const String mediaText =
        '#EXTM3U\n'
        '#EXT-X-TARGETDURATION:4\n'
        '#EXT-X-MEDIA-SEQUENCE:7\n'
        '#EXT-X-KEY:METHOD=AES-128,URI="key.bin"\n'
        '#EXTINF:4,\n'
        'seg1.ts\n'
        '#EXT-X-KEY:METHOD=NONE\n'
        '#EXTINF:4,\n'
        'seg2.png\n'
        '#EXT-X-ENDLIST\n';

    /// [installHls] 那条流的指纹（与下载器按同一个函数算）。
    String installedFingerprint({String mediaPath = '/hls/media.m3u8'}) {
      final Uri uri = Uri.parse(server.url(mediaPath));
      return hlsStreamFingerprint(uri, parseHlsMediaPlaylist(mediaText, uri));
    }

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
      server.routes[mediaPath] = _text(mediaText);
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
      // TS → mp4：-c copy + ADTS 转换；只映射音视频（TS 里的 ID3 / SCTE-35 数据流
      // mp4 装不下，-map 0 会让整次转封装失败）。
      final List<String> args = ffmpeg.calls.single;
      expect(args, containsAllInOrder(<String>['-c', 'copy']));
      expect(
        args,
        containsAllInOrder(<String>['-map', '0:v?', '-map', '0:a?']),
      );
      expect(args, isNot(contains('0')));
      expect(args, contains('aac_adtstoasc'));
      expect(args[args.indexOf('-i') + 1], '${dest.path}.hls.part');
      expect(args.last, '${dest.path}.remux.mp4');
      // 转封装失败不当下载失败，但要进错误日志（用户拿到的是 TS 不是 mp4）。
      expect(
        ErrorLogService.instance.entries.map((ErrorLogEntry e) => e.source),
        contains('AnimeEpisodeDownloader.remux'),
      );
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
        await File('${dest.path}.hls.progress').writeAsString(
          HlsDownloadProgress(
            stream: installedFingerprint(),
            segments: 1,
            bytes: first.length,
          ).encode(),
        );
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
      final HlsDownloadProgress record = HlsDownloadProgress.tryParse(
        await File('${dest.path}.hls.progress').readAsString(),
      )!;
      expect(record.stream, installedFingerprint());
      expect(record.segments, 1);
      expect(record.bytes, 188 * 4);
      expect(await File('${dest.path}.hls.part').length(), 188 * 4);
    });

    /// 下到第二片时暂停：留下「第一片已写完」的 part 与断点记录。
    Future<File> cancelAtSecondSegment() async {
      final Completer<void> seg2Arrived = Completer<void>();
      final Completer<void> release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      final _Handler seg2 = server.routes['/hls/seg2.png']!;
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
      server.routes['/hls/seg2.png'] = seg2;
      server.requests.clear();
      return dest;
    }

    test('resuming the same stream after a pause fetches only the missing '
        'segment', () async {
      final Uint8List expected = installHls();
      final File dest = await cancelAtSecondSegment();
      await downloader(_FakeFfmpeg.failing()).download(
        url: server.url('/hls/master.m3u8'),
        headers: const <String, String>{},
        dest: dest,
      );
      expect(await dest.readAsBytes(), expected);
      expect(server.requests.map((_Req r) => r.path), <String>[
        '/hls/master.m3u8',
        '/hls/media.m3u8',
        '/hls/seg2.png',
      ]);
    });

    test('the extension handing out another stream after a pause restarts '
        'from zero instead of splicing two streams', () async {
      installHls();
      final File dest = await cancelAtSecondSegment();
      // 这次取流拿到的是另一条线路：master 指向另一个媒体播放列表、另一组分片。
      final Uint8List other1 = _tsPackets(3, seed: 11);
      final Uint8List other2 = _tsPackets(2, seed: 13);
      server.routes['/hls/master.m3u8'] = _text(
        '#EXTM3U\n'
        '#EXT-X-STREAM-INF:BANDWIDTH=2400000\n'
        'alt/media.m3u8\n',
      );
      server.routes['/hls/alt/media.m3u8'] = _text(
        '#EXTM3U\n#EXTINF:4,\na.ts\n#EXTINF:4,\nb.ts\n#EXT-X-ENDLIST\n',
      );
      server.routes['/hls/alt/a.ts'] = _bytes(other1);
      server.routes['/hls/alt/b.ts'] = _bytes(other2);
      await downloader(_FakeFfmpeg.failing()).download(
        url: server.url('/hls/master.m3u8'),
        headers: const <String, String>{},
        dest: dest,
      );
      // 从 0 下：旧流的第一片一个字节都不留。
      expect(await dest.readAsBytes(), <int>[...other1, ...other2]);
      expect(server.requests.map((_Req r) => r.path), <String>[
        '/hls/master.m3u8',
        '/hls/alt/media.m3u8',
        '/hls/alt/a.ts',
        '/hls/alt/b.ts',
      ]);
      expect(await File('${dest.path}.hls.progress').exists(), isFalse);
    });

    test('a progress record of another stream, or a legacy one without a '
        'fingerprint, restarts from zero', () async {
      final Uint8List expected = installHls();
      final File dest = File(p.join(tmp.path, 'ep1.mp4'));
      final Uint8List first = Uint8List.sublistView(expected, 0, 188 * 4);
      for (final String record in <String>[
        HlsDownloadProgress(
          stream: installedFingerprint(mediaPath: '/hls/other.m3u8'),
          segments: 1,
          bytes: first.length,
        ).encode(),
        '1,${first.length}',
      ]) {
        // part 里是「别的流」的字节：续上去就是坏片。
        await File(
          '${dest.path}.hls.part',
        ).writeAsBytes(List<int>.filled(first.length, 0x47));
        await File('${dest.path}.hls.progress').writeAsString(record);
        if (await dest.exists()) await dest.delete();
        server.requests.clear();
        await downloader(_FakeFfmpeg.failing()).download(
          url: server.url('/hls/master.m3u8'),
          headers: const <String, String>{},
          dest: dest,
        );
        expect(await dest.readAsBytes(), expected, reason: record);
        expect(
          server.requests.map((_Req r) => r.path),
          contains('/hls/seg1.ts'),
          reason: record,
        );
      }
    });

    test('a stalled segment fails with TimeoutException and keeps the '
        'resume record', () async {
      installHls();
      final Completer<void> release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      server.routes['/hls/seg2.png'] = (HttpRequest request) async {
        await release.future;
        await request.response.close();
      };
      final File dest = File(p.join(tmp.path, 'ep1.mp4'));
      await expectLater(
        downloader(
          _FakeFfmpeg.failing(),
          stallTimeout: const Duration(milliseconds: 300),
        ).download(
          url: server.url('/hls/master.m3u8'),
          headers: const <String, String>{},
          dest: dest,
        ),
        throwsA(isA<TimeoutException>()),
      );
      expect(
        HlsDownloadProgress.tryParse(
          await File('${dest.path}.hls.progress').readAsString(),
        )!.segments,
        1,
      );
    });

    group('direct resume', () {
      final Uint8List body = Uint8List.fromList(
        List<int>.generate(300000, (int i) => (i * 7) & 0xff),
      );
      const int half = 150000;

      /// 第一趟：服务器发完前一半就不动了，客户端收到一半时暂停。
      Future<File> pauseHalfway() async {
        final Completer<void> release = Completer<void>();
        addTearDown(() {
          if (!release.isCompleted) release.complete();
        });
        server.routes['/video.mp4'] = (HttpRequest request) async {
          request.response.headers.set(HttpHeaders.etagHeader, '"v1"');
          request.response.contentLength = body.length;
          request.response.add(Uint8List.sublistView(body, 0, half));
          await request.response.flush();
          await release.future;
          await request.response.close();
        };
        final File dest = File(p.join(tmp.path, 'ep1.mp4'));
        final Completer<void> cancel = Completer<void>();
        await expectLater(
          downloader(_FakeFfmpeg.failing()).download(
            url: server.url('/video.mp4'),
            headers: const <String, String>{},
            dest: dest,
            onBytes: (int received, int? total) {
              if (received >= half && !cancel.isCompleted) cancel.complete();
            },
            cancelSignal: cancel.future,
          ),
          throwsA(isA<RemoteDownloadCancelled>()),
        );
        expect(await File('${dest.path}.part').length(), half);
        server.requests.clear();
        return dest;
      }

      test('the same ETag continues from the part with If-Range', () async {
        final File dest = await pauseHalfway();
        expect(
          await File('${dest.path}$kAnimeDirectValidatorSuffix').exists(),
          isTrue,
        );
        server.routes['/video.mp4'] = _rangeFile(body, etag: '"v1"');
        await downloader(_FakeFfmpeg.failing()).download(
          url: server.url('/video.mp4'),
          headers: const <String, String>{},
          dest: dest,
        );
        expect(await dest.readAsBytes(), body);
        final _Req request = server.requests.single;
        expect(request.range, 'bytes=$half-');
        expect(request.ifRange, '"v1"');
        expect(await File('${dest.path}.part').exists(), isFalse);
        expect(
          await File('${dest.path}$kAnimeDirectValidatorSuffix').exists(),
          isFalse,
        );
      });

      test('a changed ETag makes the server answer 200 and the download '
          'restarts from zero', () async {
        final File dest = await pauseHalfway();
        final Uint8List changed = Uint8List.fromList(
          List<int>.generate(260000, (int i) => (i * 3 + 1) & 0xff),
        );
        server.routes['/video.mp4'] = _rangeFile(changed, etag: '"v2"');
        await downloader(_FakeFfmpeg.failing()).download(
          url: server.url('/video.mp4'),
          headers: const <String, String>{},
          dest: dest,
        );
        expect(await dest.readAsBytes(), changed);
        expect(server.requests.single.ifRange, '"v1"');
      });

      test('a server ignoring If-Range whose file length changed is caught '
          'by the validator and restarted from zero', () async {
        final File dest = await pauseHalfway();
        final Uint8List changed = Uint8List.fromList(
          List<int>.generate(280000, (int i) => (i * 5 + 2) & 0xff),
        );
        // 不发 ETag、无视 If-Range，照回 206：只剩总长能看出换了文件。
        server.routes['/video.mp4'] = _rangeFile(changed, honorIfRange: false);
        await downloader(_FakeFfmpeg.failing()).download(
          url: server.url('/video.mp4'),
          headers: const <String, String>{},
          dest: dest,
        );
        expect(await dest.readAsBytes(), changed);
        // 第一次带 Range 拿到 206 被作废，第二次不带 Range 从 0 下。
        expect(server.requests.map((_Req r) => r.range), <String?>[
          'bytes=$half-',
          null,
        ]);
      });

      test('a part without a validator sidecar is not resumed', () async {
        final File dest = File(p.join(tmp.path, 'ep1.mp4'));
        await File(
          '${dest.path}.part',
        ).writeAsBytes(List<int>.filled(half, 0xEE));
        server.routes['/video.mp4'] = _rangeFile(body, etag: '"v1"');
        await downloader(_FakeFfmpeg.failing()).download(
          url: server.url('/video.mp4'),
          headers: const <String, String>{},
          dest: dest,
        );
        expect(await dest.readAsBytes(), body);
        expect(server.requests.single.range, isNull);
      });

      test('a stalled body fails with TimeoutException and keeps the part '
          'and its validator for a resume', () async {
        final Completer<void> release = Completer<void>();
        addTearDown(() {
          if (!release.isCompleted) release.complete();
        });
        server.routes['/video.mp4'] = (HttpRequest request) async {
          request.response.headers.set(HttpHeaders.etagHeader, '"v1"');
          request.response.contentLength = body.length;
          request.response.add(Uint8List.sublistView(body, 0, half));
          await request.response.flush();
          await release.future;
          await request.response.close();
        };
        final File dest = File(p.join(tmp.path, 'ep1.mp4'));
        await expectLater(
          downloader(
            _FakeFfmpeg.failing(),
            stallTimeout: const Duration(milliseconds: 300),
          ).download(
            url: server.url('/video.mp4'),
            headers: const <String, String>{},
            dest: dest,
          ),
          throwsA(isA<TimeoutException>()),
        );
        expect(await File('${dest.path}.part').length(), half);
        final DirectStreamValidator validator = DirectStreamValidator.tryParse(
          await File('${dest.path}$kAnimeDirectValidatorSuffix').readAsString(),
        )!;
        expect(validator.etag, '"v1"');
        expect(validator.totalBytes, body.length);
      });
    });

    test('discarding a failed episode download in the download center '
        'removes every leftover next to its destination', () async {
      final File dest = File(p.join(tmp.path, 'ep1.mp4'));
      final List<File> leftovers = animeEpisodeDownloadLeftovers(dest);
      expect(
        leftovers.map((File f) => p.basename(f.path)),
        containsAll(<String>[
          'ep1.mp4.part',
          'ep1.mp4$kAnimeDirectValidatorSuffix',
          'ep1.mp4.hls.part',
          'ep1.mp4.hls.progress',
          'ep1.mp4.remux.mp4',
        ]),
      );
      final InterconnectDownloadManager manager = InterconnectDownloadManager();
      addTearDown(manager.dispose);
      await expectLater(
        manager.startVideoDownload(
          id: 'anime-source:x:1:/ep/1',
          title: 'Episode 1',
          dest: dest,
          run:
              (
                File target, {
                void Function(double progress)? onProgress,
                void Function(int received, int? total)? onBytes,
                Future<void>? cancelSignal,
              }) async {
                for (final File f in leftovers) {
                  await f.writeAsBytes(<int>[1]);
                }
                throw const HttpException('HTTP 403');
              },
        ),
        throwsA(isA<HttpException>()),
      );
      expect(await manager.discard('anime-source:x:1:/ep/1'), isTrue);
      for (final File f in leftovers) {
        expect(await f.exists(), isFalse, reason: f.path);
      }
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

/// 支持 `Range: bytes=N-` 的静态文件。[honorIfRange] 为真时按 RFC 9110 处理
/// `If-Range`（验证器不符就回 200 全量）；为假时模拟无视 `If-Range` 的服务器。
_Handler _rangeFile(Uint8List body, {String? etag, bool honorIfRange = true}) =>
    (HttpRequest request) async {
      final HttpResponse response = request.response;
      if (etag != null) response.headers.set(HttpHeaders.etagHeader, etag);
      final String? range = request.headers.value(HttpHeaders.rangeHeader);
      final String? ifRange = request.headers.value(HttpHeaders.ifRangeHeader);
      final RegExpMatch? match = range == null
          ? null
          : RegExp(r'^bytes=(\d+)-$').firstMatch(range);
      final bool partial =
          match != null &&
          (!honorIfRange || ifRange == null || ifRange == etag);
      if (partial) {
        final int start = int.parse(match.group(1)!);
        response.statusCode = HttpStatus.partialContent;
        response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-${body.length - 1}/${body.length}',
        );
        response.contentLength = body.length - start;
        response.add(Uint8List.sublistView(body, start));
      } else {
        response.contentLength = body.length;
        response.add(body);
      }
      await response.close();
    };

class _Req {
  const _Req(this.path, this.referer, {this.range, this.ifRange});

  final String path;
  final String? referer;
  final String? range;
  final String? ifRange;
}

class _FixtureServer {
  _FixtureServer._(this._server) {
    _server.listen((HttpRequest request) async {
      requests.add(
        _Req(
          request.uri.path,
          request.headers.value(HttpHeaders.refererHeader),
          range: request.headers.value(HttpHeaders.rangeHeader),
          ifRange: request.headers.value(HttpHeaders.ifRangeHeader),
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
  /// 查询类命令（BUG-2938 新增原语）：本假件不区分，交给 [run]。
  @override
  Future<FfmpegRunResult> runQuery(List<String> args, Duration timeout) =>
      run(args, timeout);

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
