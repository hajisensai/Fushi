// applyAdblockTo 接线 helper 的最小演示 + 测试：假 AdblockMatcher 注入，不加载原生库。
//
// 覆盖：平台模式判定、逐请求拦截（含与页面原有拦截器组合、顶层导航不拦、白名单、
// redirect 替身）、contentBlockers 转换（动作过滤、未知资源类型、截断只丢拦截规则）、
// cosmetic 两个 JS handler、资源类型推断、白名单解析。
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/web_adblock/web_adblock_capability.dart';
import 'package:fushi/src/web_adblock/web_adblock_service.dart';
import 'package:fushi/src/web_adblock/web_adblock_wiring.dart';
import 'package:fushi_adblock/fushi_adblock.dart';

class _FakeMatcher implements AdblockMatcher {
  final List<({String url, String? source, AdblockRequestType type})> checks =
      <({String url, String? source, AdblockRequestType type})>[];

  @override
  AdblockDecision check(
    String url, {
    String? sourceUrl,
    AdblockRequestType type = AdblockRequestType.other,
  }) {
    checks.add((url: url, source: sourceUrl, type: type));
    if (url.contains('redirect.test')) return AdblockDecision.redirect;
    if (url.contains('ads.')) return AdblockDecision.block;
    return AdblockDecision.allow;
  }

  @override
  AdblockCheckResult checkDetailed(
    String url, {
    String? sourceUrl,
    AdblockRequestType type = AdblockRequestType.other,
  }) => AdblockCheckResult(
    decision: check(url, sourceUrl: sourceUrl, type: type),
    redirect:
        'data:application/javascript;base64,${base64Encode(utf8.encode('(function(){})();'))}',
  );

  @override
  AdblockCosmeticResources cosmetic(String url) => AdblockCosmeticResources(
    hideSelectors: <String>['.site-ad'],
    exceptions: <String>['.keep-me'],
    generichide: url.contains('nogeneric'),
  );

  @override
  List<String> genericSelectors({
    Iterable<String> classes = const <String>[],
    Iterable<String> ids = const <String>[],
    Iterable<String> exceptions = const <String>[],
  }) => <String>[
    for (final String c in classes)
      if (!exceptions.contains('.$c')) '.$c',
  ];
}

class _FakePolicy implements WebAdblockPolicy {
  _FakePolicy({
    this.active = true,
    this.rules = const <Map<String, Object?>>[],
  });

  bool active;
  Set<String> allow = <String>{};
  final _FakeMatcher fake = _FakeMatcher();
  final List<Map<String, Object?>> rules;

  @override
  bool get isActive => active;

  @override
  AdblockMatcher? get matcher => fake;

  @override
  bool isAllowlisted(Uri? pageUrl) =>
      pageUrl != null && webAdblockHostAllowlisted(pageUrl.host, allow);

  @override
  List<Map<String, Object?>> get contentBlockingRules => rules;
}

WebResourceRequest _req(
  String url, {
  bool mainFrame = false,
  Map<String, String>? headers,
}) => WebResourceRequest(
  url: WebUri(url),
  isForMainFrame: mainFrame,
  headers: headers,
);

void main() {
  test('platform capability table', () {
    expect(
      webAdblockNetworkModeFor(TargetPlatform.android),
      WebAdblockNetworkMode.perRequest,
    );
    expect(
      webAdblockNetworkModeFor(TargetPlatform.windows),
      WebAdblockNetworkMode.perRequest,
    );
    expect(
      webAdblockNetworkModeFor(TargetPlatform.linux),
      WebAdblockNetworkMode.cosmeticOnly,
    );
    for (final TargetPlatform p in <TargetPlatform>[
      TargetPlatform.iOS,
      TargetPlatform.macOS,
    ]) {
      expect(
        webAdblockNetworkModeFor(p),
        WebAdblockNetworkMode.contentBlockers,
      );
    }
  });

  group('per-request platforms', () {
    test('turns on useShouldInterceptRequest, adds cosmetic user script', () {
      final InAppWebViewSettings original = InAppWebViewSettings();
      final WebAdblockWiring w = applyAdblockTo(
        original,
        policy: _FakePolicy(),
        mode: WebAdblockNetworkMode.perRequest,
      );
      expect(w.settings.useShouldInterceptRequest, isTrue);
      expect(original.useShouldInterceptRequest, isNot(isTrue));
      expect(w.shouldInterceptRequest, isNotNull);
      expect(w.userScripts.single.groupName, kWebAdblockUserScriptGroup);
      expect(
        w.userScripts.single.injectionTime,
        UserScriptInjectionTime.AT_DOCUMENT_START,
      );
      expect(w.userScripts.single.forMainFrameOnly, isFalse);
    });

    test('blocks ad subresource with page as source, allows others', () {
      final _FakePolicy policy = _FakePolicy();
      final WebAdblockWiring w = applyAdblockTo(
        InAppWebViewSettings(),
        policy: policy,
        mode: WebAdblockNetworkMode.perRequest,
      )..onLoadStart(WebUri('https://news.test/article'));

      final WebResourceResponse? blocked = w.interceptForAdblock(
        _req(
          'https://ads.example.com/x.js',
          headers: <String, String>{'Sec-Fetch-Dest': 'script'},
        ),
      );
      expect(blocked, isNotNull);
      expect(blocked!.statusCode, 403);
      expect(policy.fake.checks.last.source, 'https://news.test/article');
      expect(policy.fake.checks.last.type, AdblockRequestType.script);

      expect(w.interceptForAdblock(_req('https://cdn.test/app.js')), isNull);
      expect(w.blockedCount, 1);
    });

    test('top-level navigation and non-http schemes are never checked', () {
      final _FakePolicy policy = _FakePolicy();
      final WebAdblockWiring w = applyAdblockTo(
        InAppWebViewSettings(),
        policy: policy,
        mode: WebAdblockNetworkMode.perRequest,
      );
      expect(
        w.interceptForAdblock(
          _req('https://ads.example.com/', mainFrame: true),
        ),
        isNull,
      );
      expect(
        w.interceptForAdblock(_req('http://fushi.local/ads.example.com/a.css')),
        isNotNull, // http 照常判定（fushi.local 由页面原有拦截器先接走，见下一条）
      );
      expect(w.interceptForAdblock(_req('data:text/plain,ads.')), isNull);
      expect(
        policy.fake.checks.where((c) => c.url.startsWith('data:')),
        isEmpty,
      );
    });

    test('page interceptor runs first; adblock only sees the rest', () async {
      final List<String> seenByPage = <String>[];
      final WebResourceResponse own = WebResourceResponse(
        contentType: 'text/css',
        data: Uint8List(0),
      );
      final WebAdblockWiring w = applyAdblockTo(
        InAppWebViewSettings(),
        policy: _FakePolicy(),
        mode: WebAdblockNetworkMode.perRequest,
        shouldInterceptRequest: (_, WebResourceRequest r) async {
          seenByPage.add(r.url.toString());
          return r.url.host == 'fushi.local' ? own : null;
        },
      );
      // 原有拦截器的结果原样返回；controller 在本测试路径里不会被用到。
      Future<WebResourceResponse?> call(WebResourceRequest r) =>
          w.shouldInterceptRequest!(_NoController.instance, r);
      expect(await call(_req('http://fushi.local/ads.css')), same(own));
      expect(await call(_req('https://ads.example.com/a.js')), isNotNull);
      expect(await call(_req('https://ok.test/a.js')), isNull);
      expect(seenByPage, hasLength(3));
    });

    test('inactive policy / allowlisted page pass everything through', () {
      final _FakePolicy policy = _FakePolicy(active: false);
      final WebAdblockWiring w = applyAdblockTo(
        InAppWebViewSettings(),
        policy: policy,
        mode: WebAdblockNetworkMode.perRequest,
      )..onLoadStart(WebUri('https://shop.example.org/'));
      expect(w.interceptForAdblock(_req('https://ads.example.com/a')), isNull);

      policy
        ..active = true
        ..allow = parseWebAdblockAllowlist(
          'https://example.org/path, foo.test',
        );
      expect(w.interceptForAdblock(_req('https://ads.example.com/a')), isNull);
      expect(w.cosmeticFor('https://shop.example.org/'), isNull);

      w.onUpdateVisitedHistory(WebUri('https://elsewhere.test/'));
      expect(
        w.interceptForAdblock(_req('https://ads.example.com/a')),
        isNotNull,
      );
    });

    test('redirect decision serves the decoded replacement body', () {
      final WebAdblockWiring w = applyAdblockTo(
        InAppWebViewSettings(),
        policy: _FakePolicy(),
        mode: WebAdblockNetworkMode.perRequest,
      );
      final WebResourceResponse? r = w.interceptForAdblock(
        _req('https://redirect.test/ad.js'),
      );
      expect(r!.statusCode, 200);
      expect(r.contentType, 'application/javascript');
      expect(utf8.decode(r.data!), '(function(){})();');
    });
  });

  group('content-blocker platforms', () {
    // 插件的 ContentBlockerActionType 按 defaultTargetPlatform 生成原生值（静态 final，
    // 首次访问时固化）：flutter_test 默认 android 没有 IGNORE_PREVIOUS_RULES，按真实取用
    // 这条路径的平台（iOS）跑。
    setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.iOS);
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    final List<Map<String, Object?>> rules = <Map<String, Object?>>[
      <String, Object?>{
        'trigger': <String, Object?>{'url-filter': 'ads\\.example\\.com'},
        'action': <String, Object?>{'type': 'block'},
      },
      <String, Object?>{
        'trigger': <String, Object?>{
          'url-filter': 'popup\\.test',
          'resource-type': <String>['popup'],
        },
        'action': <String, Object?>{'type': 'block'},
      },
      <String, Object?>{
        'trigger': <String, Object?>{
          'url-filter': 'img\\.test',
          'resource-type': <String>['image', 'popup'],
        },
        'action': <String, Object?>{'type': 'block'},
      },
      <String, Object?>{
        'trigger': <String, Object?>{'url-filter': '.*'},
        'action': <String, Object?>{
          'type': 'css-display-none',
          'selector': '.ad',
        },
      },
      <String, Object?>{
        'trigger': <String, Object?>{'url-filter': 'ok\\.test'},
        'action': <String, Object?>{'type': 'ignore-previous-rules'},
      },
    ];

    test('converts rules: keeps block/ignore, drops css & popup-only', () {
      final WebAdblockWiring w = applyAdblockTo(
        InAppWebViewSettings(),
        policy: _FakePolicy(rules: rules),
        mode: WebAdblockNetworkMode.contentBlockers,
      );
      expect(w.settings.useShouldInterceptRequest, isNot(isTrue));
      expect(w.shouldInterceptRequest, isNull);
      final List<ContentBlocker> cbs = w.settings.contentBlockers!;
      expect(cbs, hasLength(3));
      expect(cbs[0].trigger.urlFilter, 'ads\\.example\\.com');
      expect(cbs[1].trigger.resourceType, <ContentBlockerTriggerResourceType>[
        ContentBlockerTriggerResourceType.IMAGE,
      ]);
      expect(
        cbs.last.action.type,
        ContentBlockerActionType.IGNORE_PREVIOUS_RULES,
      );
    });

    test('truncation drops block rules first, keeps exceptions', () {
      final List<ContentBlocker> cbs = contentBlockersFromRules(
        rules,
        maxRules: 2,
      );
      expect(cbs, hasLength(2));
      expect(cbs.first.action.type, ContentBlockerActionType.BLOCK);
      expect(
        cbs.last.action.type,
        ContentBlockerActionType.IGNORE_PREVIOUS_RULES,
      );
    });

    test('inactive policy adds no content blockers', () {
      final WebAdblockWiring w = applyAdblockTo(
        InAppWebViewSettings(),
        policy: _FakePolicy(active: false, rules: rules),
        mode: WebAdblockNetworkMode.contentBlockers,
      );
      expect(w.settings.contentBlockers ?? const <ContentBlocker>[], isEmpty);
    });
  });

  group('cosmetic handlers', () {
    test('page resources and generic selectors minus exceptions', () {
      final WebAdblockWiring w = applyAdblockTo(
        InAppWebViewSettings(),
        policy: _FakePolicy(),
        mode: WebAdblockNetworkMode.cosmeticOnly,
      );
      final Map<String, Object?>? c = w.cosmeticFor('https://site.test/');
      expect(c!['hideSelectors'], <String>['.site-ad']);
      expect(c['generichide'], isFalse);
      expect(
        w.genericSelectorsFor(<String, Object?>{
          'href': 'https://site.test/',
          'classes': <String>['banner', 'keep-me'],
          'ids': <String>[],
        }),
        <String>['.banner'],
      );
      expect(w.cosmeticFor(42), isNull);
      expect(w.genericSelectorsFor('bad'), isEmpty);
      expect(
        kWebAdblockCosmeticScript,
        allOf(
          contains(kWebAdblockCosmeticHandler),
          contains(kWebAdblockGenericHandler),
        ),
      );
    });
  });

  test('request type inference', () {
    expect(
      inferAdblockRequestType(_req('https://a.test/', mainFrame: true)),
      AdblockRequestType.document,
    );
    expect(
      inferAdblockRequestType(
        _req(
          'https://a.test/x',
          headers: <String, String>{'sec-fetch-dest': 'iframe'},
        ),
      ),
      AdblockRequestType.subdocument,
    );
    expect(
      inferAdblockRequestType(
        _req(
          'https://a.test/x',
          headers: <String, String>{'Accept': 'image/webp,*/*'},
        ),
      ),
      AdblockRequestType.image,
    );
    expect(
      inferAdblockRequestType(_req('https://a.test/x.css?v=1')),
      AdblockRequestType.stylesheet,
    );
    expect(
      inferAdblockRequestType(_req('https://a.test/x.woff2')),
      AdblockRequestType.font,
    );
    expect(
      inferAdblockRequestType(_req('https://a.test/api')),
      AdblockRequestType.other,
    );
  });

  test('allowlist parsing', () {
    final Set<String> a = parseWebAdblockAllowlist(
      ' https://Example.com/path , *.foo.test;bar.test:8080\n.baz.test ',
    );
    expect(a, <String>{'example.com', 'foo.test', 'bar.test', 'baz.test'});
    expect(webAdblockHostAllowlisted('www.example.com', a), isTrue);
    expect(webAdblockHostAllowlisted('notexample.com', a), isFalse);
  });
}

/// shouldInterceptRequest 的 controller 形参在接线里只透传给页面原有拦截器，本测试
/// 的拦截器不读它；用一个不可调用的占位实现满足类型。
class _NoController implements InAppWebViewController {
  _NoController._();
  static final _NoController instance = _NoController._();

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('controller is not used in this test');
}
