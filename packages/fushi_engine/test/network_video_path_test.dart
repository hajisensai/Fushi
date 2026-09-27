// 「只在网络上 / 没有媒体字节」两条判据与有上限读取（纯 Dart，引擎包自测）：
// - isNetworkOnlyVideoPath：http(s) 与 rtsp / rtmp / udp … 直播协议，`.strm` 不算；
// - lacksLocalMediaFile：网络流 + `.strm` 流指针；
// - isAppleUnsupportedStreamUrl：rtsps / rtmps / rtmpe；
// - readBoundedBytes：超限即停，不读完整个流。
import 'dart:async';

import 'package:fushi_engine/media/video/strm_file.dart';
import 'package:fushi_engine/utils/net/bounded_read.dart';
import 'package:test/test.dart';

void main() {
  group('isNetworkOnlyVideoPath', () {
    test('http(s) 与直播协议（大小写 / 首尾空白不敏感）', () {
      for (final String path in <String>[
        'http://a.example/v.mp4',
        'HTTPS://a.example/v.m3u8',
        '  rtsp://cam.example/1',
        'rtmp://live.example/app',
        'udp://@239.0.0.1:1234',
        'srt://h.example:9000',
      ]) {
        expect(isNetworkOnlyVideoPath(path), isTrue, reason: path);
      }
    });

    test('本地路径、.strm、未知协议与空值都不算', () {
      for (final String? path in <String?>[
        null,
        '',
        r'D:\videos\ep01.mkv',
        'D://videos/ep01.mkv',
        '/home/u/ep01.mp4',
        r'\\nas\share\ep01.mkv',
        '/lib/Show S01E01.strm',
        'file:///home/u/ep01.mp4',
        'smb://nas/share/a.mkv',
        'httpfoo/ep.mp4',
      ]) {
        expect(isNetworkOnlyVideoPath(path), isFalse, reason: path);
      }
    });
  });

  test('lacksLocalMediaFile：网络流 + .strm 流指针', () {
    expect(lacksLocalMediaFile('rtsp://cam.example/1'), isTrue);
    expect(lacksLocalMediaFile('https://a.example/v.mp4'), isTrue);
    expect(lacksLocalMediaFile(r'D:\lib\Show S01E01.strm'), isTrue);
    expect(lacksLocalMediaFile('https://nas/dav/a.strm?x=1'), isTrue);
    expect(lacksLocalMediaFile(r'D:\lib\a.mkv'), isFalse);
    expect(lacksLocalMediaFile(null), isFalse);
  });

  test('isAppleUnsupportedStreamUrl：只认 rtsps / rtmps / rtmpe', () {
    expect(isAppleUnsupportedStreamUrl('rtsps://cam/1'), isTrue);
    expect(isAppleUnsupportedStreamUrl('RTMPS://live/app'), isTrue);
    expect(isAppleUnsupportedStreamUrl('rtmpe://live/app'), isTrue);
    expect(isAppleUnsupportedStreamUrl('rtsp://cam/1'), isFalse);
    expect(isAppleUnsupportedStreamUrl('https://a/v.m3u8'), isFalse);
    expect(isAppleUnsupportedStreamUrl(r'C:\a.mkv'), isFalse);
  });

  group('readBoundedBytes', () {
    test('上限内原样返回', () async {
      final List<int> bytes = await readBoundedBytes(
        Stream<List<int>>.fromIterable(<List<int>>[
          <int>[1, 2],
          <int>[3],
        ]),
        3,
      );
      expect(bytes, <int>[1, 2, 3]);
    });

    test('越过上限即抛，且不再继续拉取', () async {
      int pulled = 0;
      final Stream<List<int>> stream = Stream<List<int>>.fromIterable(
        Iterable<List<int>>.generate(1000, (_) {
          pulled++;
          return List<int>.filled(10, 0);
        }),
      );
      await expectLater(
        readBoundedBytes(stream, 25),
        throwsA(isA<BodyTooLargeException>()),
      );
      expect(pulled, lessThan(10));
    });

    test('超限时取消上游订阅', () async {
      bool cancelled = false;
      final StreamController<List<int>> controller =
          StreamController<List<int>>(onCancel: () => cancelled = true);
      final Future<List<int>> read = readBoundedBytes(controller.stream, 4);
      controller.add(<int>[1, 2, 3]);
      controller.add(<int>[4, 5]);
      await expectLater(read, throwsA(isA<BodyTooLargeException>()));
      expect(cancelled, isTrue);
      await controller.close();
    });
  });
}
