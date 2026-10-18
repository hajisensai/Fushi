// applyAdblockTo 接线 helper 的测试。判定本身在 Rust（见 web_adblock_service_test 与 Rust 单测）；
// 这里用记录调用的假策略钉接线自己的职责：平台模式、哪些请求交给策略（顶层导航 / 非 http 不交）、
// 来源与类型怎么推断、页面原有拦截器先跑、cosmetic 两个 JS handler 把 Rust 的 JSON 原样回给 JS、
// contentBlockers 的插件对象映射。
import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/web_adblock/web_adblock_capability.dart';
import 'package:fushi/src/web_adblock/web_adblock_wiring.dart';
import 'package:fushi_web_core/fushi_web_core.dart';

class _FakePolicy implements WebAdblockPolicy {
  _FakePolicy({
    this.active = true,
    this.rules = const <Map<String, Object?>>[],
  });

  bool active;
  final List<Map<String, Object?>> rules;
  final List<({String url, String? source, Uri? page, AdblockRequestType type})>
  checks =
      <({String url, String? source, Uri? page, AdblockRequestType type})>[];
  final List<({String href, Uri? page, String classes, String ids})> generic =
      <({String href, Uri? page, String classes, String ids})>[];

  @override
  bool get isActive => active;

  @override
  AdblockDecision check(
    String url, {
    String? sourceUrl,
    Uri? pageUrl,
    AdblockRequestType type = AdblockRequestType.other,
  }) {
    checks.add((url: url, source: sourceUrl, page: pageUrl, type: type));
    return url.contains('ads.') ? AdblockDecision.block : AdblockDecision.allow;
  }

  @override
  String? cosmeticPayload(String href, {Uri? pageUrl}) =>
      '{"hideSelectors":[".site-ad"],"injectedScript":"","generichide":false}';

  @override
  String? genericPayload(
    String href, {
    Uri? pageUrl,
    required String classes,
    required String ids,
  }) {
    generic.add((href: href, page: pageUrl, classes: classes, ids: ids));
    return '[".banner"]';
  }

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
      expect(policy.checks.last.source, 'https://news.test/article');
      expect(policy.checks.last.page, Uri.parse('https://news.test/article'));
      expect(policy.checks.last.type, AdblockRequestType.script);

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
      expect(policy.checks.where((c) => c.url.startsWith('data:')), isEmpty);
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

    test('every request asks the policy with the current top-level page', () {
      final _FakePolicy policy = _FakePolicy(active: false);
      final WebAdblockWiring w = applyAdblockTo(
        InAppWebViewSettings(),
        policy: policy,
        mode: WebAdblockNetworkMode.perRequest,
      )..onLoadStart(WebUri('https://shop.example.org/'));
      // 开关 / 白名单 / 引擎就绪由策略（Rust）判，接线不预先短路。
      expect(
        w.interceptForAdblock(_req('https://ads.example.com/a')),
        isNotNull,
      );
      expect(policy.checks.last.page, Uri.parse('https://shop.example.org/'));
      w.onUpdateVisitedHistory(WebUri('https://elsewhere.test/'));
      w.interceptForAdblock(
        _req(
          'https://cdn.test/a',
          headers: <String, String>{'Referer': 'https://frame.test/'},
        ),
      );
      expect(policy.checks.last.page, Uri.parse('https://elsewhere.test/'));
      expect(policy.checks.last.source, 'https://frame.test/');
    });
  });

  group('content-blocker platforms', () {
    // 插件的 ContentBlockerActionType 按 defaultTargetPlatform 生成原生值（静态 final，
    // 首次访问时固化）：flutter_test 默认 android 没有 IGNORE_PREVIOUS_RULES，按真实取用
    // 这条路径的平台（iOS）跑。
    setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.iOS);
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    // Rust 核心（adblock::content_blocking::export）筛选后的形状。
    final List<Map<String, Object?>> rules = <Map<String, Object?>>[
      <String, Object?>{
        'trigger': <String, Object?>{'url-filter': 'ads\\.example\\.com'},
        'action': <String, Object?>{'type': 'block'},
      },
      <String, Object?>{
        'trigger': <String, Object?>{
          'url-filter': 'img\\.test',
          'resource-type': <String>['image'],
          'load-type': <String>['third-party'],
        },
        'action': <String, Object?>{'type': 'block'},
      },
      <String, Object?>{
        'trigger': <String, Object?>{'url-filter': 'ok\\.test'},
        'action': <String, Object?>{'type': 'ignore-previous-rules'},
      },
    ];

    test('maps the Rust-filtered rules one to one', () {
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
      expect(cbs[1].trigger.loadType, <ContentBlockerTriggerLoadType>[
        ContentBlockerTriggerLoadType.THIRD_PARTY,
      ]);
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
    test('hand the Rust JSON text straight back to the page', () {
      final _FakePolicy policy = _FakePolicy();
      final WebAdblockWiring w = applyAdblockTo(
        InAppWebViewSettings(),
        policy: policy,
        mode: WebAdblockNetworkMode.cosmeticOnly,
      )..onLoadStart(WebUri('https://site.test/'));
      expect(w.cosmeticFor('https://site.test/'), contains('.site-ad'));
      expect(
        w.genericSelectorsFor(<String, Object?>{
          'href': 'https://frame.test/',
          'classes': 'banner\nkeep-me',
          'ids': '',
        }),
        '[".banner"]',
      );
      expect(policy.generic.single.classes, 'banner\nkeep-me');
      expect(policy.generic.single.page, Uri.parse('https://site.test/'));
      expect(w.cosmeticFor(42), isNull);
      expect(w.genericSelectorsFor('bad'), isNull);
      expect(
        kWebAdblockCosmeticScript,
        allOf(
          contains(kWebAdblockCosmeticHandler),
          contains(kWebAdblockGenericHandler),
          contains('JSON.parse'),
          contains(".join('\\n')"),
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
