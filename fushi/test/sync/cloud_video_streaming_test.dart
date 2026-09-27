import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show DebugPrintCallback, debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/cloud_remote_video_client.dart';
import 'package:fushi/src/sync/cloud_video_stream_relay.dart';
import 'package:fushi/src/sync/sync_asset_range_reader.dart';
import 'package:fushi/src/sync/sync_backend.dart'
    show SyncAuthError, SyncBackendError, SyncBackendType;
import 'package:fushi/src/sync/sync_obfuscator.dart';
import 'package:fushi/src/sync/sync_orchestrator.dart'
    show kSyncVideosNamespace, kSyncVideosManifestName;
import 'package:fushi/src/sync/video_manifest.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:http/http.dart' as http;

import 'fake_asset_store.dart';

/// 云盘视频流播（对齐 SenPlayer 网盘直连）：区间读 + 解混淆 + 预签名直链现取 /
/// 过期重取 + loopback 中继 + 流播 client。上游云盘用本地假 HTTP 服务模拟
/// （Graph item 元数据 / Dropbox get_temporary_link / 预签名内容主机）。
void main() {
  final Uint8List plain = Uint8List.fromList(
      List<int>.generate(5000, (int i) => (i * 31 + 7) & 0xff));
  final Uint8List obfuscated = SyncObfuscator.obfuscateBytes(plain);

  group('DeobfuscatingAssetRangeReader', () {
    test('混淆资产任意区间还原成明文，总长扣掉魔数', () async {
      final _MemoryRangeReader raw =
          _MemoryRangeReader(<String, List<int>>{'a': obfuscated});
      final DeobfuscatingAssetRangeReader reader =
          DeobfuscatingAssetRangeReader(raw);
      for (final (int, int?) r in <(int, int?)>[
        (0, 9),
        (33, 70),
        (4990, null),
        (1234, 99999),
      ]) {
        final SyncAssetRange range =
            await reader.openAssetRange('a', start: r.$1, end: r.$2);
        final int last =
            r.$2 == null || r.$2! >= plain.length ? plain.length - 1 : r.$2!;
        expect(range.start, r.$1);
        expect(range.end, last);
        expect(range.totalBytes, plain.length);
        expect(await _collect(range.bytes), plain.sublist(r.$1, last + 1));
      }
      // 魔数探测只做一次（1 次探测 + 4 次正文）。
      expect(raw.opens, 5);
    });

    test('无魔数的旧明文原样透传', () async {
      final DeobfuscatingAssetRangeReader reader =
          DeobfuscatingAssetRangeReader(
              _MemoryRangeReader(<String, List<int>>{'p': plain}));
      final SyncAssetRange range =
          await reader.openAssetRange('p', start: 100, end: 199);
      expect(range.totalBytes, plain.length);
      expect(await _collect(range.bytes), plain.sublist(100, 200));
    });

    test('起点越过文件尾：416 语义，总长按明文报', () async {
      final DeobfuscatingAssetRangeReader reader =
          DeobfuscatingAssetRangeReader(
              _MemoryRangeReader(<String, List<int>>{'a': obfuscated}));
      await expectLater(
        reader.openAssetRange('a', start: plain.length),
        throwsA(isA<SyncAssetRangeNotSatisfiable>().having(
            (SyncAssetRangeNotSatisfiable e) => e.totalBytes,
            'totalBytes',
            plain.length)),
      );
    });

    test('只能整文件下载的后端没有流播视图', () {
      expect(plainAssetRangeReaderOf(FakeAssetStore()), isNull);
      expect(plainAssetRangeReaderOf(_RangeAssetStore()), isNotNull);
    });
  });

  group('预签名直链现取 / 过期重取（假 Graph / Dropbox）', () {
    late _FakeCloud cloud;
    late http.Client client;

    setUp(() async {
      cloud = await _FakeCloud.start(obfuscated);
      client = http.Client();
    });

    tearDown(() async {
      client.close();
      await cloud.close();
    });

    /// 与 OneDriveSyncBackend._fetchDownloadLink 同形：读 item 元数据里的
    /// `@microsoft.graph.downloadUrl`。
    Future<Uri> graphLink(String itemId) async {
      final http.Response resp =
          await client.get(cloud.api.resolve('/v1.0/me/drive/items/$itemId'));
      final Map<String, dynamic> meta =
          jsonDecode(resp.body) as Map<String, dynamic>;
      return Uri.parse(meta['@microsoft.graph.downloadUrl'] as String);
    }

    /// 与 DropboxSyncBackend._fetchTemporaryLink 同形。
    Future<Uri> dropboxLink(String path) async {
      final http.Response resp = await client.post(
        cloud.api.resolve('/2/files/get_temporary_link'),
        body: jsonEncode(<String, String>{'path': path}),
      );
      final Map<String, dynamic> json =
          jsonDecode(resp.body) as Map<String, dynamic>;
      return Uri.parse(json['link'] as String);
    }

    test('有效期内多次 seek 共用一条直链', () async {
      final PresignedLinkCache cache =
          PresignedLinkCache(ttl: const Duration(minutes: 15));
      for (final int start in <int>[0, 2000, 4000]) {
        final SyncAssetRange range = await openPresignedAssetRange(
          client: client,
          cache: cache,
          assetId: 'item1',
          fetchLink: () => graphLink('item1'),
          start: start,
          end: start + 99,
        );
        expect(await _collect(range.bytes),
            obfuscated.sublist(start, start + 100));
        expect(range.totalBytes, obfuscated.length);
      }
      expect(cloud.linkFetches, 1);
      expect(cloud.rangeHeaders, <String>[
        'bytes=0-99',
        'bytes=2000-2099',
        'bytes=4000-4099',
      ]);
    });

    test('直链过期（上游 403）：作废缓存、现取一条再试一次', () async {
      final PresignedLinkCache cache =
          PresignedLinkCache(ttl: const Duration(hours: 3));
      Future<SyncAssetRange> read(int start) => openPresignedAssetRange(
            client: client,
            cache: cache,
            assetId: '/fushi-data/__videos__/v.mp4',
            fetchLink: () => dropboxLink('/fushi-data/__videos__/v.mp4'),
            start: start,
          );
      await _collect((await read(0)).bytes);
      cloud.expireLinks(); // 服务端让之前签发的直链全部失效。
      final SyncAssetRange range = await read(4096);
      expect(await _collect(range.bytes), obfuscated.sublist(4096));
      expect(cloud.linkFetches, 2);
      expect(cloud.rejected, 1);
    });

    test('本地 TTL 到期即现取，不等上游拒绝', () async {
      DateTime now = DateTime(2026, 9, 27, 12);
      final PresignedLinkCache cache = PresignedLinkCache(
          ttl: const Duration(minutes: 15), clock: () => now);
      Future<void> read() async => _collect((await openPresignedAssetRange(
            client: client,
            cache: cache,
            assetId: 'item1',
            fetchLink: () => graphLink('item1'),
            start: 0,
            end: 9,
          ))
              .bytes);
      await read();
      now = now.add(const Duration(minutes: 16));
      await read();
      expect(cloud.linkFetches, 2);
      expect(cloud.rejected, 0);
    });

    test('上游忽略 Range 回 200：自己裁出请求区间', () async {
      cloud.ignoreRange = true;
      final SyncAssetRange range = await openPresignedAssetRange(
        client: client,
        cache: PresignedLinkCache(ttl: const Duration(minutes: 15)),
        assetId: 'item1',
        fetchLink: () => graphLink('item1'),
        start: 1000,
        end: 1099,
      );
      expect(range.start, 1000);
      expect(range.end, 1099);
      expect(await _collect(range.bytes), obfuscated.sublist(1000, 1100));
    });

    test('起点越界：上游 416 → SyncAssetRangeNotSatisfiable(总长)', () async {
      await expectLater(
        openPresignedAssetRange(
          client: client,
          cache: PresignedLinkCache(ttl: const Duration(minutes: 15)),
          assetId: 'item1',
          fetchLink: () => graphLink('item1'),
          start: obfuscated.length + 10,
        ),
        throwsA(isA<SyncAssetRangeNotSatisfiable>().having(
            (SyncAssetRangeNotSatisfiable e) => e.totalBytes,
            'totalBytes',
            obfuscated.length)),
      );
    });

    test('持续被拒只重取一次；错误信息不带直链 / 签名', () async {
      cloud.rejectAll = true;
      Object? error;
      try {
        await openPresignedAssetRange(
          client: client,
          cache: PresignedLinkCache(ttl: const Duration(minutes: 15)),
          assetId: 'item1',
          fetchLink: () => graphLink('item1'),
          start: 0,
        );
      } on Object catch (e) {
        error = e;
      }
      expect(error, isA<SyncBackendError>());
      expect(cloud.linkFetches, 2);
      expect('$error', isNot(contains('tempauth')));
      expect('$error', isNot(contains('127.0.0.1')));
      expect('$error', contains('403'));
    });
  });

  test('retryAfterAuthRefresh：token 过期先刷新再重试一次', () async {
    int calls = 0;
    int refreshes = 0;
    final String out = await retryAfterAuthRefresh(
      () async => refreshes++,
      () async {
        calls++;
        if (calls == 1) throw SyncAuthError('expired');
        return 'link';
      },
    );
    expect(out, 'link');
    expect(calls, 2);
    expect(refreshes, 1);
  });

  group('CloudVideoStreamRelay', () {
    late CloudVideoStreamRelay relay;
    late HttpClient http1;
    late DeobfuscatingAssetRangeReader reader;

    setUp(() async {
      relay = await CloudVideoStreamRelay.start();
      http1 = HttpClient();
      reader = DeobfuscatingAssetRangeReader(
          _MemoryRangeReader(<String, List<int>>{'asset-1': obfuscated}));
    });

    tearDown(() async {
      http1.close(force: true);
      await relay.close();
    });

    Future<({int status, Map<String, String> headers, List<int> body})> get(
      Uri url, {
      String? range,
      String method = 'GET',
    }) async {
      final HttpClientRequest req = await http1.openUrl(method, url);
      if (range != null) req.headers.set(HttpHeaders.rangeHeader, range);
      final HttpClientResponse resp = await req.close();
      final Map<String, String> headers = <String, String>{};
      resp.headers.forEach((String k, List<String> v) => headers[k] = v.join());
      return (
        status: resp.statusCode,
        headers: headers,
        body: await _collect(resp),
      );
    }

    Uri register([SyncAssetRangeReader? other]) => relay.register(
        reader: other ?? reader,
        source: 'cloud:oneDrive',
        assetId: 'asset-1',
        fileName: 'vid1.mkv');

    test('无 Range → 200 整个明文；地址是 loopback，不含上游信息', () async {
      final Uri url = register();
      expect(url.host, '127.0.0.1');
      expect(url.pathSegments.last, 'vid1.mkv');
      expect(url.toString(), isNot(contains('asset-1')));
      final r = await get(url);
      expect(r.status, 200);
      expect(r.headers['content-length'], '${plain.length}');
      expect(r.headers['accept-ranges'], 'bytes');
      expect(r.headers['content-type'], 'video/x-matroska');
      expect(r.body, plain);
    });

    test('seek（Range）→ 206 + Content-Range，字节是明文', () async {
      final Uri url = register();
      final r = await get(url, range: 'bytes=4000-');
      expect(r.status, 206);
      expect(r.headers['content-range'], 'bytes 4000-4999/${plain.length}');
      expect(r.body, plain.sublist(4000));
      final r2 = await get(url, range: 'bytes=10-19');
      expect(r2.body, plain.sublist(10, 20));
    });

    test('HEAD 只报总长；越界 Range → 416；未知 token → 404', () async {
      final Uri url = register();
      final head = await get(url, method: 'HEAD');
      expect(head.status, 200);
      expect(head.headers['content-length'], '${plain.length}');
      final bad = await get(url, range: 'bytes=${plain.length}-');
      expect(bad.status, 416);
      expect(bad.headers['content-range'], 'bytes */${plain.length}');
      final missing = await get(
          url.replace(pathSegments: <String>['cloud', 'nope', 'vid1.mkv']));
      expect(missing.status, 404);
    });

    test('同一资产重复登记复用同一地址', () {
      final Uri a = register();
      final Uri b = register();
      expect(a, b);
    });

    test('每次刷新新建 reader 也复用同一地址、登记表不增长，且改用最新 reader', () async {
      // 视频页每次刷新都新建 CloudRemoteVideoClient → 新的 reader 实例。按 reader
      // 实例去重会让同一资产每刷一次多一条登记（只增不删）。
      final Uri first = register();
      final _MemoryRangeReader fresh =
          _MemoryRangeReader(<String, List<int>>{'asset-1': obfuscated});
      Uri? last;
      for (int i = 0; i < 10; i++) {
        last = register(DeobfuscatingAssetRangeReader(fresh));
      }
      expect(last, first);
      expect(relay.entryCount, 1);
      expect((await get(first, range: 'bytes=0-9')).body, plain.sublist(0, 10));
      expect(fresh.opens, greaterThan(0), reason: '请求走的是最后登记的 reader');

      // 另一个云盘上的同 id 资产是另一条登记。
      final Uri other = relay.register(
          reader: reader,
          source: 'cloud:dropbox',
          assetId: 'asset-1',
          fileName: 'vid1.mkv');
      expect(other, isNot(first));
      expect(relay.entryCount, 2);
    });

    test('登记表有上限：淘汰最久没用的，在播的（刚被请求过的）留着', () async {
      final Uri playing = register();
      Uri? oldest;
      for (int i = 0; i < CloudVideoStreamRelay.maxEntries - 1; i++) {
        final Uri u = relay.register(
            reader: reader,
            source: 'cloud:oneDrive',
            assetId: 'filler-$i',
            fileName: 'f$i.mkv');
        oldest ??= u;
      }
      expect(relay.entryCount, CloudVideoStreamRelay.maxEntries);
      // 在播的流每个 Range 请求都会把自己挪到最新。
      expect((await get(playing, range: 'bytes=0-9')).status, 206);
      relay.register(
          reader: reader,
          source: 'cloud:oneDrive',
          assetId: 'one-more',
          fileName: 'x.mkv');
      expect(relay.entryCount, CloudVideoStreamRelay.maxEntries);
      expect((await get(oldest!, range: 'bytes=0-9')).status, 404,
          reason: '最久没用的那条被淘汰');
      expect((await get(playing, range: 'bytes=0-9')).status, 206,
          reason: '刚请求过的在播流不被淘汰');
    });

    test('背压：内核停止读取后，上游只被拉走几 MiB，而不是整个文件', () async {
      // libmpv 发开区间 `bytes=0-`，前向缓存满了就不再读。中继若不背压，会把
      // 64MiB 全部拉下来堆进 Dart 堆。
      const int total = 64 * 1024 * 1024;
      final _CountingRangeReader counting = _CountingRangeReader(total);
      final Uri url = relay.register(
          reader: counting,
          source: 'cloud:oneDrive',
          assetId: 'big',
          fileName: 'big.mkv');
      final Socket socket =
          await Socket.connect(InternetAddress.loopbackIPv4, url.port);
      addTearDown(socket.destroy);
      socket.write('GET ${url.path} HTTP/1.1\r\n'
          'Host: 127.0.0.1:${url.port}\r\n'
          'Range: bytes=0-\r\n\r\n');
      await socket.flush();
      int received = 0;
      final Completer<void> gotSome = Completer<void>();
      late final StreamSubscription<Uint8List> sub;
      sub = socket.listen((Uint8List data) {
        received += data.length;
        if (received >= 64 * 1024 && !gotSome.isCompleted) {
          sub.pause(); // 客户端读了几十 KB 后不再消费。
          gotSome.complete();
        }
      }, onError: (Object _) {});
      addTearDown(sub.cancel);
      await gotSome.future.timeout(const Duration(seconds: 10));
      // 给中继足够时间：不背压的话这段时间里它会把 64MiB 全部拉完。
      int settled = -1;
      for (int i = 0; i < 40 && settled != counting.pulledBytes; i++) {
        settled = counting.pulledBytes;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(counting.pulledBytes, lessThan(16 * 1024 * 1024),
          reason: '上游被拉走 ${counting.pulledBytes} 字节（总 $total）');
      expect(counting.pulledBytes, greaterThanOrEqualTo(received - 1024));

      // 客户端走掉（mpv seek / 关闭）→ 中继停止上游。
      socket.destroy();
      for (int i = 0; i < 100 && !counting.cancelled; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(counting.cancelled, isTrue, reason: '客户端断开后上游订阅被取消');
      expect(counting.pulledBytes, lessThan(16 * 1024 * 1024));
    });
  });

  group('直链不进日志（传输层异常映射 + 中继脱敏）', () {
    late _FakeCloud cloud;
    late http.Client client;

    setUp(() async {
      cloud = await _FakeCloud.start(obfuscated);
      client = http.Client();
    });

    tearDown(() async {
      client.close();
      await cloud.close();
    });

    Future<SyncAssetRange> openVia(Future<Uri> Function() link,
            {int start = 0, int? end}) =>
        openPresignedAssetRange(
          client: client,
          cache: PresignedLinkCache(ttl: const Duration(minutes: 15)),
          assetId: 'item1',
          fetchLink: link,
          start: start,
          end: end,
        );

    test('连接失败：SyncBackendError 只带原因，不带 uri', () async {
      final ServerSocket closed =
          await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final int port = closed.port;
      await closed.close();
      Object? error;
      try {
        await openVia(() async => Uri.parse(
            'http://127.0.0.1:$port/cd/0/get/PATHSECRET/file?tempauth=QSECRET'));
      } on Object catch (e) {
        error = e;
      }
      expect(error, isA<SyncBackendError>());
      expect('$error', isNot(contains('PATHSECRET')));
      expect('$error', isNot(contains('QSECRET')));
      expect('$error', isNot(contains('uri=')));
    });

    test('上游中途断开：流错误是 SyncBackendError，不带 uri', () async {
      cloud.dropMidStream = true;
      final SyncAssetRange range =
          await openVia(() async => Uri.parse(cloud.signedLinkForTest()));
      Object? error;
      try {
        await _collect(range.bytes);
      } on Object catch (e) {
        error = e;
      }
      expect(error, isA<SyncBackendError>());
      expect('$error', isNot(contains('tempauth')));
      expect('$error', isNot(contains('/content/')));
    });

    test('上游中途断开时中继打印的内容不含直链', () async {
      final List<String> logs = <String>[];
      final DebugPrintCallback original = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null) logs.add(message);
      };
      addTearDown(() => debugPrint = original);

      cloud.dropMidStream = true;
      final CloudVideoStreamRelay relay = await CloudVideoStreamRelay.start();
      addTearDown(relay.close);
      final Uri url = relay.register(
        reader: _PresignedReader(
          client,
          () async => Uri.parse(cloud.signedLinkForTest()),
        ),
        source: 'cloud:oneDrive',
        assetId: 'item1',
        fileName: 'v.mkv',
      );
      final HttpClient c = HttpClient();
      addTearDown(() => c.close(force: true));
      final HttpClientRequest req = await c.getUrl(url);
      req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-');
      final HttpClientResponse resp = await req.close();
      expect(resp.statusCode, 206);
      await expectLater(_collect(resp), throwsA(anything),
          reason: '中继把上游的中途断开传成断连');
      for (int i = 0; i < 100 && logs.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      final String relayLogs =
          logs.where((String l) => l.contains('cloud-stream-relay')).join('\n');
      expect(relayLogs, isNotEmpty);
      expect(relayLogs, isNot(contains('tempauth')));
      expect(relayLogs, isNot(contains('SIG')));
      expect(relayLogs, isNot(contains('/content/')));
    });

    test('206 但 Content-Range 解析不了：报错，不按 200 整文件裁剪', () async {
      cloud.malformedContentRange = true;
      await expectLater(
        openVia(() async => Uri.parse(cloud.signedLinkForTest()),
            start: 1000, end: 1099),
        throwsA(isA<SyncBackendError>()),
      );
    });

    test('PresignedLinkCache.clear()（退出登录）后现取新直链', () async {
      final PresignedLinkCache cache =
          PresignedLinkCache(ttl: const Duration(hours: 3));
      int fetches = 0;
      Future<Uri> fetch() async =>
          Uri.parse('https://example.com/${++fetches}');
      expect(await cache.link('a', fetch), Uri.parse('https://example.com/1'));
      expect(await cache.link('a', fetch), Uri.parse('https://example.com/1'));
      cache.clear();
      expect(await cache.link('a', fetch), Uri.parse('https://example.com/2'));
    });
  });

  group('CloudStreamVideoClient', () {
    late CloudVideoStreamRelay relay;
    late _RangeAssetStore store;

    setUp(() async {
      relay = await CloudVideoStreamRelay.start();
      store = _RangeAssetStore();
      final String ns = await store.ensureNamespace(kSyncVideosNamespace);
      await store.putJsonAsset(
        ns,
        kSyncVideosManifestName,
        const RemoteVideoManifest(videos: <RemoteVideoManifestEntry>[
          RemoteVideoManifestEntry(
            uid: 'cloud/vid1',
            title: 'Cloud Vid',
            videoAsset: 'cloud_vid1.mp4',
            sizeBytes: 5000,
          ),
        ]).toJson(),
      );
      final Directory tmp =
          Directory.systemTemp.createTempSync('cloud_stream_client');
      final File f = File('${tmp.path}/blob')..writeAsBytesSync(obfuscated);
      await store.putAsset(ns, 'cloud_vid1.mp4', f);
      tmp.deleteSync(recursive: true);
    });

    tearDown(() async => relay.close());

    test('流地址经中继读出明文；起播 / 重开地址稳定；无服务端断点', () async {
      final CloudRemoteVideoClient cloud = CloudRemoteVideoClient(
        backend: store,
        backendType: SyncBackendType.oneDrive,
        relay: () async => relay,
      );
      final CloudStreamVideoClient streaming = cloud.streamingClient()!;
      expect(cloud.streamingClient(), same(streaming));
      expect(streaming.remoteLibrarySourceId, cloud.remoteLibrarySourceId);

      final RemoteVideoStreamUrls urls =
          await streaming.remoteVideoStreamUrls('cloud/vid1');
      final Uri url = Uri.parse(urls.streamUrl);
      expect(url.host, '127.0.0.1');
      expect(urls.subtitleUrl, isNull);
      expect(urls.streamIsOriginalContainer, isTrue);
      final RemoteVideoStreamUrls again =
          await streaming.remoteVideoStreamUrls('cloud/vid1');
      expect(again.streamUrl, urls.streamUrl);

      final HttpClient c = HttpClient();
      addTearDown(() => c.close(force: true));
      final HttpClientRequest req = await c.getUrl(url);
      req.headers.set(HttpHeaders.rangeHeader, 'bytes=100-299');
      final HttpClientResponse resp = await req.close();
      expect(resp.statusCode, 206);
      expect(await _collect(resp), plain.sublist(100, 300));

      expect(await streaming.remoteVideoPosition('cloud/vid1'),
          (positionMs: 0, updatedAtMs: 0));
      await streaming.putRemoteVideoPosition('cloud/vid1', 42000, 1);
    });

    test('视频页每次刷新新建 client：同一资产仍是同一地址，登记表不增长', () async {
      final Set<String> urls = <String>{};
      for (int i = 0; i < 5; i++) {
        final CloudStreamVideoClient streaming = CloudRemoteVideoClient(
          backend: store,
          backendType: SyncBackendType.oneDrive,
          relay: () async => relay,
        ).streamingClient()!;
        urls.add(
            (await streaming.remoteVideoStreamUrls('cloud/vid1')).streamUrl);
      }
      expect(urls, hasLength(1));
      expect(relay.entryCount, 1);
    });

    test('登录失效：起播前的预读把 SyncAuthError 原样抛给播放页，不交出中继地址', () async {
      store.failWith = SyncAuthError('Token refresh failed: 400');
      final CloudStreamVideoClient streaming = CloudRemoteVideoClient(
        backend: store,
        backendType: SyncBackendType.dropbox,
        relay: () async => relay,
      ).streamingClient()!;
      await expectLater(streaming.remoteVideoStreamUrls('cloud/vid1'),
          throwsA(isA<SyncAuthError>()));
      expect(relay.entryCount, 0, reason: '读不了就不登记');
    });

    test('清单里没有的 uid → SyncBackendError', () async {
      final CloudStreamVideoClient streaming = CloudRemoteVideoClient(
        backend: store,
        backendType: SyncBackendType.dropbox,
        relay: () async => relay,
      ).streamingClient()!;
      await expectLater(streaming.remoteVideoStreamUrls('cloud/missing'),
          throwsA(isA<SyncBackendError>()));
    });

    test('WebDAV 等整文件后端不给流播视图', () {
      expect(
        CloudRemoteVideoClient(
          backend: FakeAssetStore(),
          backendType: SyncBackendType.webDav,
        ).streamingClient(),
        isNull,
      );
    });
  });
}

Future<List<int>> _collect(Stream<List<int>> stream) async {
  final BytesBuilder b = BytesBuilder(copy: false);
  await for (final List<int> chunk in stream) {
    b.add(chunk);
  }
  return b.takeBytes();
}

/// 云端原样字节的内存区间读（按请求切块吐出，模拟网络分块）。
class _MemoryRangeReader implements SyncAssetRangeReader {
  _MemoryRangeReader(this.files);

  final Map<String, List<int>> files;
  int opens = 0;

  @override
  Future<SyncAssetRange> openAssetRange(
    String assetId, {
    required int start,
    int? end,
  }) async {
    opens++;
    final List<int> bytes = files[assetId]!;
    if (start >= bytes.length) {
      throw SyncAssetRangeNotSatisfiable(bytes.length);
    }
    final int last =
        end == null || end >= bytes.length ? bytes.length - 1 : end;
    final List<int> slice = bytes.sublist(start, last + 1);
    return SyncAssetRange(
      start: start,
      end: last,
      totalBytes: bytes.length,
      bytes: Stream<List<int>>.fromIterable(<List<int>>[
        for (int i = 0; i < slice.length; i += 777)
          slice.sublist(i, i + 777 > slice.length ? slice.length : i + 777),
      ]),
    );
  }
}

/// 按被拉取量计数的合成大文件（全零字节，惰性逐块生成）：[pulledBytes] 只统计
/// 下游真正拉走的块，用来断言中继有没有背压。
class _CountingRangeReader implements SyncAssetRangeReader {
  _CountingRangeReader(this.totalBytes);

  final int totalBytes;
  int pulledBytes = 0;
  bool cancelled = false;
  final Uint8List _block = Uint8List(64 * 1024);

  @override
  Future<SyncAssetRange> openAssetRange(String assetId,
      {required int start, int? end}) async {
    final int last = end == null || end >= totalBytes ? totalBytes - 1 : end;
    return SyncAssetRange(
      start: start,
      end: last,
      totalBytes: totalBytes,
      bytes: _generate(start, last),
    );
  }

  Stream<List<int>> _generate(int start, int last) async* {
    try {
      for (int offset = start; offset <= last; offset += _block.length) {
        final int n = min(_block.length, last - offset + 1);
        pulledBytes += n;
        yield n == _block.length ? _block : Uint8List.sublistView(_block, 0, n);
      }
    } finally {
      cancelled = true;
    }
  }
}

/// 走真实 [openPresignedAssetRange] 的区间读（形同 OneDrive / Dropbox 后端）。
class _PresignedReader implements SyncAssetRangeReader {
  _PresignedReader(this._client, this._fetchLink);

  final http.Client _client;
  final Future<Uri> Function() _fetchLink;
  final PresignedLinkCache _cache =
      PresignedLinkCache(ttl: const Duration(minutes: 15));

  @override
  Future<SyncAssetRange> openAssetRange(String assetId,
          {required int start, int? end}) =>
      openPresignedAssetRange(
        client: _client,
        cache: _cache,
        assetId: assetId,
        fetchLink: _fetchLink,
        start: start,
        end: end,
      );
}

/// 同时是资产库与区间读的假云盘（形同 OneDrive / Dropbox 后端）。
class _RangeAssetStore extends FakeAssetStore implements SyncAssetRangeReader {
  final Map<String, List<int>> _bytes = <String, List<int>>{};

  /// 非 null 时区间读一律抛它（模拟 refresh token 失效等）。
  Exception? failWith;

  @override
  Future<void> putAsset(String namespaceId, String name, File file,
      {void Function(double progress)? onProgress}) async {
    await super.putAsset(namespaceId, name, file, onProgress: onProgress);
    _bytes['$namespaceId/$name'] = await file.readAsBytes();
  }

  @override
  Future<SyncAssetRange> openAssetRange(String assetId,
      {required int start, int? end}) async {
    final Exception? failure = failWith;
    if (failure != null) throw failure;
    return _MemoryRangeReader(_bytes)
        .openAssetRange(assetId, start: start, end: end);
  }
}

/// 假云盘：一个 API 主机（Graph item 元数据 / Dropbox get_temporary_link，签发
/// 带代数的预签名直链）+ 同一端口上的内容路径（只认当前代数的直链，支持 Range）。
class _FakeCloud {
  _FakeCloud._(this._server, this._content);

  static Future<_FakeCloud> start(List<int> content) async {
    final HttpServer server =
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final _FakeCloud cloud = _FakeCloud._(server, content);
    server.listen(cloud._handle);
    return cloud;
  }

  final HttpServer _server;
  final List<int> _content;
  int _generation = 1;
  int linkFetches = 0;
  int rejected = 0;
  bool ignoreRange = false;
  bool rejectAll = false;

  /// 回 206 + 完整 Content-Length，但只发一半正文就断开连接。
  bool dropMidStream = false;

  /// 回 206，但 Content-Range 是解析不了的垃圾。
  bool malformedContentRange = false;
  final List<String> rangeHeaders = <String>[];

  Uri get api => Uri.parse('http://127.0.0.1:${_server.port}');

  void expireLinks() => _generation++;

  Future<void> close() => _server.close(force: true);

  /// 直接签发一条当前代数的直链（不经 API 路由）。
  String signedLinkForTest() => _signedLink();

  String _signedLink() {
    linkFetches++;
    return 'http://127.0.0.1:${_server.port}/content/$_generation'
        '?tempauth=SIG$_generation';
  }

  Future<void> _handle(HttpRequest request) async {
    final HttpResponse response = request.response;
    final List<String> seg = request.uri.pathSegments;
    if (seg.length >= 4 && seg[0] == 'v1.0' && seg[2] == 'drive') {
      response.headers.contentType = ContentType.json;
      response.write(jsonEncode(<String, String>{
        'id': seg.last,
        '@microsoft.graph.downloadUrl': _signedLink(),
      }));
      await response.close();
      return;
    }
    if (request.uri.path == '/2/files/get_temporary_link') {
      await utf8.decoder.bind(request).join();
      response.headers.contentType = ContentType.json;
      response.write(jsonEncode(<String, Object>{
        'metadata': <String, String>{},
        'link': _signedLink(),
      }));
      await response.close();
      return;
    }
    if (seg.length == 2 && seg[0] == 'content') {
      if (rejectAll || seg[1] != '$_generation') {
        rejected++;
        response.statusCode = HttpStatus.forbidden;
        await response.close();
        return;
      }
      final String? range = request.headers.value(HttpHeaders.rangeHeader);
      if (range != null) rangeHeaders.add(range);
      final RegExpMatch? m =
          range == null ? null : RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range);
      if (ignoreRange || m == null) {
        response.contentLength = _content.length;
        response.add(_content);
        await response.close();
        return;
      }
      final int start = int.parse(m.group(1)!);
      if (start >= _content.length) {
        response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        response.headers
            .set(HttpHeaders.contentRangeHeader, 'bytes */${_content.length}');
        await response.close();
        return;
      }
      final int end = m.group(2)!.isEmpty
          ? _content.length - 1
          : int.parse(m.group(2)!).clamp(start, _content.length - 1);
      if (dropMidStream) {
        final Socket socket = await response.detachSocket(writeHeaders: false);
        socket.add(utf8.encode('HTTP/1.1 206 Partial Content\r\n'
            'Content-Range: bytes $start-$end/${_content.length}\r\n'
            'Content-Length: ${end - start + 1}\r\n\r\n'));
        socket.add(_content.sublist(start, start + (end - start + 1) ~/ 2));
        await socket.flush();
        socket.destroy();
        return;
      }
      if (malformedContentRange) {
        response.statusCode = HttpStatus.partialContent;
        response.headers.set(HttpHeaders.contentRangeHeader, 'bytes garbage');
        response.contentLength = end - start + 1;
        response.add(_content.sublist(start, end + 1));
        await response.close();
        return;
      }
      response.statusCode = HttpStatus.partialContent;
      response.headers.set(HttpHeaders.contentRangeHeader,
          'bytes $start-$end/${_content.length}');
      response.contentLength = end - start + 1;
      response.add(_content.sublist(start, end + 1));
      await response.close();
      return;
    }
    response.statusCode = HttpStatus.notFound;
    await response.close();
  }
}
