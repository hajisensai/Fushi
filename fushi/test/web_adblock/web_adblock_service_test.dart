// WebAdblockService 端到端（真原生库：Rust 胖核心持有订阅 / 缓存 / 开关 / 白名单；假下载器
// 给字节）。原生库是硬依赖：找不到库（FUSHI_WEB_CORE_LIB 或本仓 native/fushi_web_core 的编译产物，
// 由 test/flutter_test_config.dart 定位）测试直接失败，不 skip。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/web_adblock/web_adblock_capability.dart';
import 'package:fushi/src/web_adblock/web_adblock_service.dart';
import 'package:fushi/src/web_adblock/web_adblock_wiring.dart';
import 'package:fushi_web_core/fushi_web_core.dart';

const String _list = '''
||ads.example.com^
example.com##.ad-banner
##.generic-ad
''';

/// 直接用 Rust 核心把订阅集设成只有 [id]（不触发同步），再交给服务。
void _selectOnly(Directory dir, String id) {
  final AdblockCore core = AdblockCore.open(dir.path);
  for (final AdblockCatalogEntry e in AdblockCore.catalog()) {
    core.setListEnabled(e.id, e.id == id);
  }
  core.close();
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('fwc_svc_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  WebAdblockService service(
    List<Uri> fetched, {
    WebAdblockNetworkMode? mode,
    bool disposeOnTearDown = true,
  }) {
    final WebAdblockService s = WebAdblockService(
      dataDir: () => tmp,
      mode: mode ?? WebAdblockNetworkMode.perRequest,
      fetcher: (Uri url, {String? etag, String? lastModified}) async {
        fetched.add(url);
        return AdblockFetchResponse(
          statusCode: 200,
          body: Uint8List.fromList(utf8.encode(_list)),
        );
      },
    );
    if (disposeOnTearDown) addTearDown(s.dispose);
    return s;
  }

  test('settings commands go to Rust; snapshot is the only state', () async {
    final List<Uri> fetched = <Uri>[];
    final WebAdblockService s = service(fetched);
    int notified = 0;
    s.addListener(() => notified++);

    _selectOnly(tmp, 'easylist');
    expect(s.snapshot.status, AdblockEngineStatus.idle);
    await s.ensureLoaded();
    expect(s.snapshot.isListEnabled('easylist'), isTrue);
    expect(s.snapshot.isListEnabled('easyprivacy'), isFalse);
    expect(fetched, <Uri>[
      Uri.parse('https://easylist.to/easylist/easylist.txt'),
    ]);
    expect(s.snapshot.status, AdblockEngineStatus.ready);
    expect(s.isActive, isTrue);
    expect(s.snapshot.lastUpdatedAt, isNotNull);
    expect(notified, greaterThan(0));

    // 并发 ensureLoaded：缓存新鲜、引擎已是最新，不再联网。
    await Future.wait(<Future<void>>[s.ensureLoaded(), s.ensureLoaded()]);
    expect(fetched, hasLength(1));

    final WebAdblockWiring w = applyAdblockTo(
      InAppWebViewSettings(),
      policy: s,
      mode: WebAdblockNetworkMode.perRequest,
    )..onLoadStart(WebUri('https://news.test/'));
    WebResourceResponse? check() => w.interceptForAdblock(
      WebResourceRequest(
        url: WebUri('https://ads.example.com/a.js'),
        isForMainFrame: false,
      ),
    );
    expect(check(), isNotNull);

    s.setAllowlist('news.test');
    expect(s.snapshot.allowlistHosts, <String>['news.test']);
    expect(check(), isNull, reason: 'allowlist applies on the next request');
    s.setAllowlist('');
    await s.setEnabled(false);
    expect(s.snapshot.enabled, isFalse);
    expect(check(), isNull);
    await s.setEnabled(true);
    expect(check(), isNotNull);

    // 「立即更新」：强制联网核对。
    expect(await s.updateNow(), isTrue);
    expect(fetched, hasLength(2));
  });

  test(
    'state persists across service instances (Rust owns the disk)',
    () async {
      _selectOnly(tmp, 'easylist');
      final WebAdblockService first = service(
        <Uri>[],
        disposeOnTearDown: false,
      );
      await first.setListEnabled('adguard_japanese', true);
      await first.setListEnabled('easylist', false);
      first.setAllowlist('keep.test');
      first.dispose();

      final List<Uri> fetched = <Uri>[];
      final WebAdblockService second = service(fetched);
      expect(second.snapshot.allowlist, 'keep.test');
      expect(second.snapshot.isListEnabled('adguard_japanese'), isTrue);
      expect(second.snapshot.isListEnabled('easylist'), isFalse);
      await second.ensureLoaded();
      expect(fetched, isEmpty, reason: 'fresh cache from the first instance');
      expect(second.snapshot.status, AdblockEngineStatus.ready);
      expect(second.snapshot.fromCache, isTrue);
    },
  );

  test('content-blocker platforms get filtered WebKit rules', () async {
    final WebAdblockService s = service(
      <Uri>[],
      mode: WebAdblockNetworkMode.contentBlockers,
    );
    _selectOnly(tmp, 'easylist');
    await s.ensureLoaded();
    expect(s.contentBlockingRules, isNotEmpty);
    for (final Map<String, Object?> r in s.contentBlockingRules) {
      final Object? type = (r['action']! as Map<String, Object?>)['type'];
      expect(type, anyOf('block', 'ignore-previous-rules'));
    }
  });
}
