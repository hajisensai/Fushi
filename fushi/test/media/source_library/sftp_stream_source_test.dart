// SFTP 来源库视频原地流播（与 WebDAV / AList 同等待遇）：
//  (1) 地址命名空间：`sftp://host:port` + 解码态远端路径，往返不经 Uri（真名带
//      `%` / 空格 / 中文都不被改写）；端口缺省 22。
//  (2) 判据：`sftp://` 行是「只在网络上」的流媒体行，但**不是**播放内核能直接开的
//      网络流（不能被 `.strm` 原样交给内核）。
//  (3) 扫描期命名空间换装：列表换成 `sftp://` 地址，读/下载转回远端路径。
//  (4) 起播期解析器：`sftp://` 地址（视频与 sidecar 字幕）换成回环中继地址，Range
//      读到的字节就是远端文件对应区间；别的地址原样返回；close 关掉 SSH 连接。

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/source_library/sftp_stream_source.dart';
import 'package:fushi/src/media/source_library/source_file_system.dart';
import 'package:fushi/src/sync/cloud_video_stream_relay.dart';
import 'package:fushi_engine/media/video/strm_file.dart';

const String _root = 'sftp://nas.local:2222';

/// 不连真服务器的 SFTP 文件系统：只替换区间读与关闭，别的契约照真实现。
class _FakeSftpFs extends NetworkSourceFileSystem {
  _FakeSftpFs(this.files)
      : super(const NetworkSourceConfig(
          transport: 'sftp',
          host: 'nas.local',
          port: 2222,
          username: 'u',
        ));

  final Map<String, Uint8List> files;
  final List<String> rangeRequests = <String>[];
  int closeCalls = 0;

  @override
  Future<({int totalBytes, int start, int end, Stream<List<int>> bytes})>
      openSftpRange(String filePath, {required int start, int? end}) async {
    rangeRequests.add(filePath);
    final Uint8List data = files[filePath]!;
    if (start >= data.length) {
      throw RangeError.range(start, 0, data.length - 1, 'start');
    }
    final int last =
        (end == null || end >= data.length) ? data.length - 1 : end;
    return (
      totalBytes: data.length,
      start: start,
      end: last,
      bytes: Stream<List<int>>.value(data.sublist(start, last + 1)),
    );
  }

  @override
  Future<void> close() async {
    closeCalls++;
  }
}

/// 扫描期命名空间换装测试用的内层 fs：只记下收到的路径。
class _RecordingFs implements SourceFileSystem {
  final List<String> seen = <String>[];

  @override
  bool get isLocal => false;

  @override
  Future<List<SourceFileEntry>> listFiles(
    String dirPath, {
    bool recursive = false,
  }) async {
    seen.add('list:$dirPath');
    return const <SourceFileEntry>[
      SourceFileEntry(
        name: '50% off.mkv',
        path: '/srv/video/第1話/50% off.mkv',
        isDirectory: false,
        sizeBytes: 10,
      ),
    ];
  }

  @override
  Future<List<String>> listSiblingNames(String filePath) async {
    seen.add('siblings:$filePath');
    return const <String>[];
  }

  @override
  Future<String> readText(String filePath) async {
    seen.add('read:$filePath');
    return '';
  }

  @override
  Future<String> copyToLocal(String filePath, String destDir) async {
    seen.add('copy:$filePath');
    return destDir;
  }
}

void main() {
  group('address namespace', () {
    test('round-trips decoded paths without touching % / spaces / CJK', () {
      const String remote = '/srv/video/第1話/50% off p%20a.mkv';
      final String url = sftpSourceUrlOf(remote, _root);
      expect(url, 'sftp://nas.local:2222/srv/video/第1話/50% off p%20a.mkv');
      expect(sftpRemotePathOf(url, _root), remote);
      expect(sftpRemotePathOf('sftp://other:22/srv/a.mkv', _root), isNull);
      expect(sftpRemotePathOf('https://nas.local/srv/a.mkv', _root), isNull);
    });

    test('url root follows configJson; port defaults to 22', () {
      expect(
        sftpSourceUrlRootForConfig(<String, Object?>{
          'host': 'nas.local',
          'port': 2222,
        }),
        _root,
      );
      expect(
        sftpSourceUrlRootForConfig(<String, Object?>{'host': 'h'}),
        'sftp://h:22',
      );
    });
  });

  group('path predicates', () {
    test('sftp:// rows are network-only stream rows, not kernel-openable', () {
      const String path = 'sftp://nas.local:2222/srv/video/a.mkv';
      expect(isSourceLibrarySftpVideoPath(path), isTrue);
      expect(isSourceLibrarySftpVideoPath('  SFTP://h:22/a.mkv'), isTrue);
      expect(isSourceLibrarySftpVideoPath('/srv/video/a.mkv'), isFalse);
      expect(isSourceLibrarySftpVideoPath(null), isFalse);
      expect(isNetworkOnlyVideoPath(path), isTrue,
          reason: '本机没有这个文件：不能 stat / 抽帧 / 打包进备份');
      expect(lacksLocalMediaFile(path), isTrue);
      expect(isNetworkStreamUrl(path), isFalse,
          reason: '内核开不了 sftp://，必须经来源的播放期解析器');
    });
  });

  group('SftpUrlNamespaceFileSystem', () {
    test('lists in sftp:// namespace and maps calls back to remote paths',
        () async {
      final _RecordingFs inner = _RecordingFs();
      final SftpUrlNamespaceFileSystem fs =
          SftpUrlNamespaceFileSystem(inner, urlRoot: _root);

      expect(fs.isLocal, isFalse);
      final List<SourceFileEntry> entries =
          await fs.listFiles('/srv/video', recursive: true);
      expect(entries.single.path,
          'sftp://nas.local:2222/srv/video/第1話/50% off.mkv');
      expect(entries.single.name, '50% off.mkv');
      expect(entries.single.sizeBytes, 10);

      await fs.readText('$_root/srv/video/a.m3u8');
      await fs.copyToLocal('$_root/srv/video/a.srt', '/tmp');
      await fs.listSiblingNames('$_root/srv/video/a.mkv');
      await fs.listFiles('$_root/srv/video');
      expect(inner.seen, <String>[
        'list:/srv/video',
        'read:/srv/video/a.m3u8',
        'copy:/srv/video/a.srt',
        'siblings:/srv/video/a.mkv',
        'list:/srv/video',
      ]);
    });
  });

  group('SftpStreamUrlResolver over the loopback relay', () {
    late CloudVideoStreamRelay relay;
    late HttpClient client;
    final Uint8List video =
        Uint8List.fromList(List<int>.generate(4096, (int i) => i & 0xff));

    setUp(() async {
      relay = await CloudVideoStreamRelay.start();
      client = HttpClient();
    });
    tearDown(() async {
      client.close(force: true);
      await relay.close();
    });

    Future<(int, List<int>, String?)> fetch(
      String url, {
      String? range,
      String method = 'GET',
    }) async {
      final HttpClientRequest req =
          await client.openUrl(method, Uri.parse(url));
      if (range != null) req.headers.set(HttpHeaders.rangeHeader, range);
      final HttpClientResponse resp = await req.close();
      final List<int> body = <int>[
        for (final List<int> chunk in await resp.toList()) ...chunk,
      ];
      return (
        resp.statusCode,
        body,
        resp.headers.value(HttpHeaders.contentRangeHeader),
      );
    }

    test('sftp:// video and sidecar resolve to loopback URLs serving ranges',
        () async {
      final _FakeSftpFs fs = _FakeSftpFs(<String, Uint8List>{
        '/srv/video/第1話 50%.mkv': video,
        '/srv/video/第1話 50%.srt': Uint8List.fromList('1\n'.codeUnits),
      });
      final SftpStreamUrlResolver resolver = SftpStreamUrlResolver(
        sourceId: 7,
        urlRoot: _root,
        fs: fs,
        relay: () async => relay,
      );

      final String videoUrl =
          await resolver.resolve('$_root/srv/video/第1話 50%.mkv');
      final Uri local = Uri.parse(videoUrl);
      expect(local.scheme, 'http');
      expect(local.host, InternetAddress.loopbackIPv4.address);
      expect(videoUrl, isNot(contains('nas.local')),
          reason: '交给内核的地址不带远端主机 / 凭据');

      final (int status, List<int> body, String? contentRange) =
          await fetch(videoUrl, range: 'bytes=100-199');
      expect(status, HttpStatus.partialContent);
      expect(body, video.sublist(100, 200));
      expect(contentRange, 'bytes 100-199/4096');

      final (int fullStatus, List<int> full, _) = await fetch(videoUrl);
      expect(fullStatus, HttpStatus.ok);
      expect(full, video);

      final (int beyond, _, _) = await fetch(videoUrl, range: 'bytes=9999-');
      expect(beyond, HttpStatus.requestedRangeNotSatisfiable);

      final String subUrl =
          await resolver.resolve('$_root/srv/video/第1話 50%.srt');
      final (int subStatus, List<int> sub, _) = await fetch(subUrl);
      expect(subStatus, HttpStatus.ok);
      expect(sub, '1\n'.codeUnits);
      expect(fs.rangeRequests, contains('/srv/video/第1話 50%.srt'));

      // 同一条目重复解析复用同一本地地址（播放页刷新不会把登记表撑大）。
      expect(await resolver.resolve('$_root/srv/video/第1話 50%.mkv'), videoUrl);
    });

    test(
        'addresses outside this source pass through unchanged; close '
        'releases the SSH connection', () async {
      final _FakeSftpFs fs = _FakeSftpFs(<String, Uint8List>{});
      final SftpStreamUrlResolver resolver = SftpStreamUrlResolver(
        sourceId: 7,
        urlRoot: _root,
        fs: fs,
        relay: () async => relay,
      );
      const String thirdParty = 'https://cdn.example.com/a.mkv';
      expect(await resolver.resolve(thirdParty), thirdParty);
      const String otherHost = 'sftp://other:22/srv/a.mkv';
      expect(await resolver.resolve(otherHost), otherHost);
      expect(fs.rangeRequests, isEmpty);

      resolver.close();
      await Future<void>.delayed(Duration.zero);
      expect(fs.closeCalls, 1);
    });
  });
}
