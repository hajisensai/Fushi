// WebAdblockService 端到端（偏好闭包 → 假下载器 → 真原生库编译 → 接线判定）。
// 原生库取 FUSHI_ADBLOCK_LIB 或本仓 native/fushi_adblock/prebuilt 产物，找不到就 skip
// （库缺失是正常部署形态，已由 packages/fushi_adblock 的测试与 CI 构建步骤覆盖）。
import 'dart:io';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/web_adblock/web_adblock_capability.dart';
import 'package:fushi/src/web_adblock/web_adblock_service.dart';
import 'package:fushi/src/web_adblock/web_adblock_wiring.dart';
import 'package:fushi_adblock/fushi_adblock.dart';

FushiAdblockLibrary? _loadLib() {
  final String sep = Platform.pathSeparator;
  final String name = Platform.isWindows
      ? 'windows-x64${sep}fushi_adblock.dll'
      : Platform.isMacOS
      ? 'macos${sep}libfushi_adblock.dylib'
      : 'linux-x64${sep}libfushi_adblock.so';
  final String path =
      Platform.environment[kFushiAdblockLibEnv] ??
      File(
        '..${sep}native${sep}fushi_adblock${sep}prebuilt$sep$name',
      ).absolute.path;
  return FushiAdblockLibrary.tryLoad(libraryPath: path);
}

void main() {
  final FushiAdblockLibrary? lib = _loadLib();

  test('loads selected lists, honours switch and allowlist live', () async {
    final Directory tmp = Directory.systemTemp.createTempSync('fadb_svc_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    bool enabled = true;
    String allowlist = '';
    final List<Uri> fetched = <Uri>[];
    final WebAdblockService service = WebAdblockService(
      cacheDir: () => tmp,
      readEnabled: () => enabled,
      readListIds: () => <String>['easylist', 'unknown_id'],
      readAllowlist: () => allowlist,
      library: lib,
      mode: WebAdblockNetworkMode.perRequest,
      fetcher: (Uri url, {String? etag, String? lastModified}) async {
        fetched.add(url);
        return const AdblockFetchResponse(
          statusCode: 200,
          body: '||ads.example.com^\n',
        );
      },
    );
    addTearDown(service.dispose);

    expect(service.isActive, isFalse);
    await Future.wait(<Future<void>>[
      service.ensureLoaded(),
      service.ensureLoaded(),
    ]);
    expect(fetched, hasLength(1), reason: 'unknown ids ignored, one load');
    expect(service.status, WebAdblockStatus.ready);
    expect(service.isActive, isTrue);
    expect(service.lastUpdatedAt, isNotNull);

    final WebAdblockWiring w = applyAdblockTo(
      InAppWebViewSettings(),
      policy: service,
      mode: WebAdblockNetworkMode.perRequest,
    )..onLoadStart(WebUri('https://news.test/'));
    WebResourceResponse? check() => w.interceptForAdblock(
      WebResourceRequest(
        url: WebUri('https://ads.example.com/a.js'),
        isForMainFrame: false,
      ),
    );
    expect(check(), isNotNull);

    allowlist = 'news.test';
    expect(check(), isNull);
    allowlist = '';
    enabled = false;
    expect(check(), isNull);
    enabled = true;
    expect(check(), isNotNull);

    await service.reload();
    expect(service.isActive, isTrue);
    expect(fetched, hasLength(1), reason: 'reload reuses fresh list cache');
  }, skip: lib == null ? 'fushi_adblock native library not found' : null);
}
