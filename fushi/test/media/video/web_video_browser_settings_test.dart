// 网页播放器网页档与 app 内浏览器共享站点设置（web_video_browser_settings.dart）：
// · 同一份浏览器设置在浏览器标签页与播放器页得到一致结果（广告拦截接线、网页深色脚本、网站设置权限）；
// · 播放器必需项（JS / 免手势起播 / 无右键菜单 / 不缩放 / 共享 cookie）不被共享设置覆盖；
// · 播放器档不套网页深色；
// · 播放器页的 WebView 真的接了这几样（源码接线守卫）。
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/foundation/pref_store.dart';
import 'package:fushi_web_core/fushi_web_core.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/video/web_video_browser_settings.dart';
import 'package:fushi/src/web_adblock/web_adblock_capability.dart';
import 'package:fushi/src/web_adblock/web_adblock_wiring.dart';
import 'package:fushi/src/web_browser/data/web_browser_site_settings.dart';
import 'package:fushi/src/web_browser/tab_view/web_browser_page_settings.dart';
import 'package:fushi/src/web_browser/tab_view/web_browser_permissions.dart';
import 'package:fushi/src/web_browser/web_browser_prefs.dart';

class _MemPrefs implements PrefStore {
  final Map<String, Object?> values = <String, Object?>{};

  @override
  dynamic getPref(String key, {dynamic defaultValue}) =>
      values.containsKey(key) ? values[key] : defaultValue;

  @override
  Future<void> setPref(String key, dynamic value) async => values[key] = value;
}

class _Policy implements WebAdblockPolicy {
  _Policy({this.rules = const <Map<String, Object?>>[]});

  final List<Map<String, Object?>> rules;

  @override
  bool get isActive => true;

  @override
  AdblockDecision check(
    String url, {
    String? sourceUrl,
    Uri? pageUrl,
    AdblockRequestType type = AdblockRequestType.other,
  }) => url.contains('ads.') ? AdblockDecision.block : AdblockDecision.allow;

  @override
  String? cosmeticPayload(String href, {Uri? pageUrl}) => null;

  @override
  String? genericPayload(
    String href, {
    Uri? pageUrl,
    required String classes,
    required String ids,
  }) => null;

  @override
  List<Map<String, Object?>> get contentBlockingRules => rules;
}

const List<Map<String, Object?>> _rules = <Map<String, Object?>>[
  <String, Object?>{
    'trigger': <String, Object?>{'url-filter': 'ads\\.example'},
    'action': <String, Object?>{'type': 'block'},
  },
];

void _expectRequired(InAppWebViewSettings s) {
  expect(s.javaScriptEnabled, isTrue);
  expect(s.mediaPlaybackRequiresUserGesture, isFalse);
  expect(s.disableContextMenu, isTrue);
  expect(s.supportZoom, isFalse);
  expect(s.sharedCookiesEnabled, isTrue);
}

void main() {
  group('广告拦截：与浏览器同一份接线', () {
    for (final WebAdblockNetworkMode mode in WebAdblockNetworkMode.values) {
      test('$mode：网络层开关与 cosmetic 脚本和浏览器一致，必需项不被覆盖', () {
        // ContentBlocker 的动作枚举按 defaultTargetPlatform 生成原生值：contentBlockers 只在
        // iOS / macOS 出现，按那边算（与 web_adblock_wiring_test 同法）。
        if (mode == WebAdblockNetworkMode.contentBlockers) {
          debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
          addTearDown(() => debugDefaultTargetPlatformOverride = null);
        }
        final _Policy policy = _Policy(rules: _rules);
        final WebAdblockWiring browser = applyAdblockTo(
          InAppWebViewSettings(javaScriptEnabled: true),
          policy: policy,
          mode: mode,
        );
        final WebAdblockWiring video = webVideoSurfaceWiring(
          policy: policy,
          mode: mode,
        );
        expect(
          video.settings.useShouldInterceptRequest,
          browser.settings.useShouldInterceptRequest,
        );
        expect(
          video.settings.contentBlockers?.length,
          browser.settings.contentBlockers?.length,
        );
        expect(
          video.userScripts.map((UserScript s) => s.source).toList(),
          browser.userScripts.map((UserScript s) => s.source).toList(),
        );
        expect(
          video.shouldInterceptRequest == null,
          browser.shouldInterceptRequest == null,
        );
        _expectRequired(video.settings);
      });
    }

    test('逐请求平台：同一个请求两边判定相同（拦广告子资源、放行顶层导航）', () {
      final _Policy policy = _Policy();
      final WebAdblockWiring browser = applyAdblockTo(
        InAppWebViewSettings(),
        policy: policy,
        mode: WebAdblockNetworkMode.perRequest,
      );
      final WebAdblockWiring video = webVideoSurfaceWiring(
        policy: policy,
        mode: WebAdblockNetworkMode.perRequest,
      );
      for (final WebResourceRequest r in <WebResourceRequest>[
        WebResourceRequest(
          url: WebUri('https://ads.example/x.js'),
          isForMainFrame: false,
        ),
        WebResourceRequest(
          url: WebUri('https://ads.example/'),
          isForMainFrame: true,
        ),
        WebResourceRequest(
          url: WebUri('https://rr1.googlevideo.com/videoplayback'),
          isForMainFrame: false,
        ),
      ]) {
        expect(
          video.interceptForAdblock(r)?.statusCode,
          browser.interceptForAdblock(r)?.statusCode,
          reason: r.url.toString(),
        );
      }
    });

    test('必需项被改坏也会压回（enforceWebVideoRequiredSettings）', () {
      final InAppWebViewSettings s = InAppWebViewSettings(
        javaScriptEnabled: false,
        mediaPlaybackRequiresUserGesture: true,
        disableContextMenu: false,
        supportZoom: true,
        sharedCookiesEnabled: false,
      );
      enforceWebVideoRequiredSettings(s);
      _expectRequired(s);
    });
  });

  group('网页深色：浏览器偏好 × 网页档', () {
    test('网页档与浏览器标签页（100% 文字）得到同一段脚本', () {
      for (final TargetPlatform p in TargetPlatform.values) {
        for (final bool dark in <bool>[true, false]) {
          expect(
            webVideoPageStyleScript(
              platform: p,
              browserForceDark: dark,
              playerMode: false,
            ),
            webBrowserPageStyleScript(
              platform: p,
              textZoom: 100,
              forceDark: dark,
            ),
          );
        }
      }
    });

    test('播放器档一律不套深色', () {
      expect(
        webVideoPageForceDark(browserForceDark: true, playerMode: true),
        isFalse,
      );
      expect(
        webVideoPageStyleScript(
          platform: TargetPlatform.windows,
          browserForceDark: true,
          playerMode: true,
        ),
        webBrowserPageStyleScript(
          platform: TargetPlatform.windows,
          textZoom: 100,
          forceDark: false,
        ),
      );
      expect(
        webVideoPageForceDark(browserForceDark: true, playerMode: false),
        isTrue,
      );
      expect(
        webVideoPageForceDark(browserForceDark: false, playerMode: false),
        isFalse,
      );
    });

    test('读的是浏览器同一个偏好键', () async {
      final _MemPrefs prefs = _MemPrefs();
      expect(webVideoBrowserForceDark(prefs), kWebBrowserForceDarkDefault);
      await setWebBrowserForceDark(prefs, true);
      expect(webVideoBrowserForceDark(prefs), isTrue);
      expect(webBrowserForceDark(prefs), isTrue);
    });
  });

  group('网站设置权限：共享应答函数', () {
    Future<PermissionResponse> resolve(
      WidgetTester tester,
      WebBrowserSiteSettings settings,
      List<PermissionResourceType> resources,
    ) async {
      late BuildContext ctx;
      await tester.pumpWidget(
        Builder(
          builder: (BuildContext c) {
            ctx = c;
            return const SizedBox.shrink();
          },
        ),
      );
      return resolveWebBrowserPermissionRequest(
        context: ctx,
        settings: settings,
        request: PermissionRequest(
          origin: WebUri('https://www.youtube.com/watch?v=x'),
          resources: resources,
        ),
        platform: TargetPlatform.windows,
      );
    }

    testWidgets('记住的允许 / 阻止原样作答，认不出的资源拒绝', (WidgetTester tester) async {
      final WebBrowserSiteSettings settings = WebBrowserSiteSettings(
        _MemPrefs(),
      );
      await settings.setDecision(
        'https://www.youtube.com',
        WebBrowserSitePermission.notifications,
        WebBrowserPermissionDecision.allow,
      );
      await settings.setDecision(
        'https://www.youtube.com',
        WebBrowserSitePermission.microphone,
        WebBrowserPermissionDecision.block,
      );
      expect(
        (await resolve(tester, settings, <PermissionResourceType>[
          PermissionResourceType.NOTIFICATIONS,
        ])).action,
        PermissionResponseAction.GRANT,
      );
      expect(
        (await resolve(tester, settings, <PermissionResourceType>[
          PermissionResourceType.MICROPHONE,
        ])).action,
        PermissionResponseAction.DENY,
      );
      expect(
        (await resolve(tester, settings, <PermissionResourceType>[
          PermissionResourceType.MIDI_SYSEX,
        ])).action,
        PermissionResponseAction.DENY,
      );
    });
  });

  test('播放器页 WebView 接了共享设置（源码接线守卫）', () {
    final String src = File(
      'lib/src/media/video/web_video_session.dart',
    ).readAsStringSync();
    expect(src, contains('initialSettings: session._surfaceSettings()'));
    expect(src, contains('initialUserScripts: session._surfaceUserScripts()'));
    expect(
      src,
      contains(
        'shouldInterceptRequest: session._adblock?.shouldInterceptRequest',
      ),
    );
    expect(src, contains('session._onPermissionRequest(context, request)'));
    expect(src, contains('webVideoSurfaceWiring(policy: policy)'));
    // 必需项只在 web_video_browser_settings.dart 写一次，宿主不再手写一份 InAppWebViewSettings。
    expect(src, isNot(contains('mediaPlaybackRequiresUserGesture: false')));
    final String page = File(
      'lib/src/pages/implementations/video_fushi/web_source.part.dart',
    ).readAsStringSync();
    expect(page, contains('adblock: adblock,'));
    expect(page, contains('browserPrefs: appModel.prefsRepo,'));
    // 播放器层不再是第二个浏览器：没有地址栏 / 档位切换 / 自己的设置入口，站点设置只在
    // app 内浏览器里改（docs/specs/2026-11-01-one-browser.md）。
    expect(page, isNot(contains('FushiSearchField')));
    expect(page, isNot(contains('adaptiveSegmentedButton')));
    expect(page, isNot(contains('openWebBrowserSettings(')));
  });
}
