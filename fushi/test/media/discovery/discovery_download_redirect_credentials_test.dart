/// 下载重定向的**凭据边界契约**：跨 origin 必须剥掉 `Authorization`/`Cookie`，
/// 同 origin 必须保留，`Referer` 这类防盗链头恒转发。
///
/// 这条不变式只在**真实 HTTP 栈**上成立或失败——`openOverride` 测试缝整个
/// 绕过了 `_openViaHttpClient`，用它测等于什么都没测。所以这里起真的
/// `HttpServer`（127.0.0.1，两个不同端口 = 两个不同 origin）跑真下载。
///
/// ## 这是契约测试，不是实现测试
///
/// 当前实现**没有**手写这套剥离逻辑：实测 Dart `HttpClient` 的
/// `followRedirects` 自己就是这个语义（跨 origin 剥凭据、同 origin 保留）。
/// 曾经在 `_openViaHttpClient` 里手写过一遍等价的重定向循环，变异测试证明它
/// 与平台行为**逐字重合**（把 `followRedirects` 改回 true，这两条断言依然全绿），
/// 于是删掉了——重复平台已经保证的东西只是多一份会漂移的代码。
///
/// 保留本文件的理由是它锁的是**结果**而不是实现：换成 `package:http` / dio
/// （两者都会把 header 原样转发到重定向目标）会让第一条断言立刻变红。
/// 两条断言缺一不可——只测「剥掉了」会让「同源也剥掉」这种把私有目录
/// 整个下不动的退化悄悄通过。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/discovery/discovery_download_queue.dart';
import 'package:fushi/src/media/discovery/discovery_models.dart';

Future<DiscoveryPayload> _resolver(DiscoveryResourceItem item) async =>
    item.payload!;

Future<void> _waitFor(bool Function() condition) async {
  for (int i = 0; i < 500 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(condition(), isTrue, reason: '下载没有在预期时间内结束');
}

DiscoveryResourceItem _item(String url, Map<String, String> headers) =>
    DiscoveryResourceItem(
      sourceId: 'opds-test',
      title: 'Book',
      id: 'id-1',
      kind: DiscoveryMediaKind.novel,
      payloadKind: DiscoveryPayloadKind.httpFile,
      payload: DiscoveryHttpPayload(
        url: url,
        headers: headers,
        fileName: 'book.epub',
      ),
    );

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('opds_redirect_test');
  });

  tearDown(() async {
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {
      // Windows 偶发句柄未释放，不让清理弄红测试。
    }
  });

  test('跨 origin 重定向剥掉 Authorization/Cookie，但保留防盗链头', () async {
    // 终点服务器：记录它实际收到的请求头。
    final Map<String, String?> received = <String, String?>{};
    final HttpServer target = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    addTearDown(() => target.close(force: true));
    unawaited(() async {
      await for (final HttpRequest request in target) {
        received['authorization'] =
            request.headers.value(HttpHeaders.authorizationHeader);
        received['cookie'] = request.headers.value(HttpHeaders.cookieHeader);
        received['referer'] = request.headers.value('referer');
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType.binary
          ..add(utf8.encode('epub-bytes'));
        await request.response.close();
      }
    }());

    // 起点服务器：302 到**另一个端口**（= 另一个 origin）。
    final HttpServer origin = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    addTearDown(() => origin.close(force: true));
    unawaited(() async {
      await for (final HttpRequest request in origin) {
        request.response
          ..statusCode = HttpStatus.found
          ..headers.set(
            HttpHeaders.locationHeader,
            'http://127.0.0.1:${target.port}/file',
          );
        await request.response.close();
      }
    }());

    final DiscoveryDownloadQueue queue = DiscoveryDownloadQueue(
      resolvePayload: _resolver,
      importer: (DiscoveryDownloadTask task, File file) async =>
          const DiscoveryImportOutcome(importedCount: 1, summary: 'ok'),
    );
    addTearDown(queue.dispose);

    queue.enqueue(
      _item('http://127.0.0.1:${origin.port}/start', <String, String>{
        'Authorization': 'Basic c2VjcmV0',
        'Cookie': 'session=secret',
        'Referer': 'http://127.0.0.1:${origin.port}/',
      }),
      destinationDir: tempDir.path,
    );

    await _waitFor(
      () => queue.tasks.isNotEmpty && queue.tasks.single.isFinished,
    );
    expect(queue.tasks.single.status, DiscoveryDownloadStatus.done,
        reason: '下载本身必须成功——剥的是凭据，不是把请求打挂');

    expect(received['authorization'], isNull,
        reason: '用户的服务器密码绝不能被转发给第三方 origin');
    expect(received['cookie'], isNull);
    // Referer/UA 不是凭据，且恰恰是重定向后仍然需要的（防盗链）。
    expect(received['referer'], isNotNull, reason: '防盗链头不该被误伤');
  });

  test('同 origin 重定向保留 Authorization（否则私有目录根本下不动）', () async {
    String? seenAtFinal;
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    addTearDown(() => server.close(force: true));
    unawaited(() async {
      await for (final HttpRequest request in server) {
        if (request.uri.path == '/start') {
          request.response
            ..statusCode = HttpStatus.found
            ..headers.set(HttpHeaders.locationHeader, '/file');
          await request.response.close();
          continue;
        }
        seenAtFinal = request.headers.value(HttpHeaders.authorizationHeader);
        request.response
          ..statusCode = 200
          ..add(utf8.encode('epub-bytes'));
        await request.response.close();
      }
    }());

    final DiscoveryDownloadQueue queue = DiscoveryDownloadQueue(
      resolvePayload: _resolver,
      importer: (DiscoveryDownloadTask task, File file) async =>
          const DiscoveryImportOutcome(importedCount: 1, summary: 'ok'),
    );
    addTearDown(queue.dispose);

    queue.enqueue(
      _item('http://127.0.0.1:${server.port}/start', <String, String>{
        'Authorization': 'Basic c2VjcmV0',
      }),
      destinationDir: tempDir.path,
    );

    await _waitFor(
      () => queue.tasks.isNotEmpty && queue.tasks.single.isFinished,
    );
    expect(queue.tasks.single.status, DiscoveryDownloadStatus.done);
    expect(seenAtFinal, 'Basic c2VjcmV0',
        reason: '同一台服务器内部的重定向必须继续带认证，否则私有 OPDS 目录下不动');
  });
}
