import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/webdav_ops.dart';
import 'package:fushi_engine/utils/net/app_proxy.dart';

void main() {
  test('public WebDAV uses proxy while local WebDAV bypasses it', () async {
    final String Function() savedMode = appUserProxyModeReader;
    final String Function() savedProxy = appUserProxyReader;
    final HttpServer proxy = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final HttpServer local = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final List<Uri> proxied = <Uri>[];
    int localRequests = 0;
    proxy.listen((HttpRequest request) async {
      proxied.add(request.uri);
      request.response.statusCode = 207;
      await request.response.close();
    });
    local.listen((HttpRequest request) async {
      localRequests++;
      request.response.statusCode = 207;
      await request.response.close();
    });
    appUserProxyModeReader = () => kProxyModeManual;
    appUserProxyReader = () => '127.0.0.1:${proxy.port}';
    final WebDavOps remoteOps = WebDavOps(
      baseUrl: 'http://webdav.invalid/dav',
      username: '',
      password: '',
    );
    final WebDavOps localOps = WebDavOps(
      baseUrl: 'http://127.0.0.1:${local.port}/dav',
      username: '',
      password: '',
    );
    try {
      await remoteOps.testConnection();
      await localOps.testConnection();
      expect(proxied.single.host, 'webdav.invalid');
      expect(localRequests, 1);
    } finally {
      remoteOps.close(force: true);
      localOps.close(force: true);
      appUserProxyModeReader = savedMode;
      appUserProxyReader = savedProxy;
      await proxy.close(force: true);
      await local.close(force: true);
    }
  });
}
