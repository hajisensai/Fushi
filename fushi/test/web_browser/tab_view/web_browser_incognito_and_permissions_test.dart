import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart'
    show InAppWebViewSettings;
import 'package:flutter_inappwebview_android/flutter_inappwebview_android.dart'
    show AndroidWebViewProfile;
import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler/permission_handler.dart';

import 'package:fushi/src/web_browser/data/memory_web_browser_store.dart';
import 'package:fushi/src/web_browser/data/web_browser_site_settings.dart';
import 'package:fushi/src/web_browser/tab_view/web_browser_incognito_profile.dart';
import 'package:fushi/src/web_browser/tab_view/web_browser_permissions.dart';
import 'package:fushi/src/web_browser/tab_view/web_browser_tab_actions.dart';
import 'package:fushi/src/web_browser/tabs/web_browser_tab.dart';
import 'package:fushi/src/web_browser/tabs/web_browser_tabs_controller.dart';

class _FakeBackend implements WebBrowserProfileBackend {
  _FakeBackend({this.supported = true, this.throwOnProbe});

  final bool supported;
  final Exception? throwOnProbe;
  int probes = 0;
  final List<String> deleted = <String>[];
  final List<String> cleanedPrefixes = <String>[];
  final Map<String, String> cookies = <String, String>{};

  @override
  Future<bool> isSupported() async {
    probes++;
    final Exception? error = throwOnProbe;
    if (error != null) throw error;
    return supported;
  }

  @override
  Future<bool> deleteProfile(String name) async {
    deleted.add(name);
    return true;
  }

  @override
  Future<List<String>> deleteUnusedProfiles(String prefix) async {
    cleanedPrefixes.add(prefix);
    return <String>[];
  }

  @override
  Future<String?> cookieHeader(String profile, Uri url) async =>
      cookies[profile];
}

WebBrowserIncognitoProfiles _profiles(
  _FakeBackend backend, {
  TargetPlatform platform = TargetPlatform.android,
}) {
  int tick = 0;
  return WebBrowserIncognitoProfiles(
    backend: backend,
    platform: () => platform,
    clock: () => DateTime.fromMicrosecondsSinceEpoch(1000 + tick++),
  );
}

Uri _u(String s) => Uri.parse('https://$s/');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('无痕判据', () {
    test('Android 只在系统 WebView 支持多 Profile 时提供；其它平台照旧', () {
      expect(webBrowserIncognitoSupportedOn(TargetPlatform.android), isFalse);
      expect(
        webBrowserIncognitoSupportedOn(
          TargetPlatform.android,
          androidMultiProfile: true,
        ),
        isTrue,
      );
      expect(webBrowserIncognitoSupportedOn(TargetPlatform.fuchsia), isFalse);
      for (final TargetPlatform p in <TargetPlatform>[
        TargetPlatform.iOS,
        TargetPlatform.macOS,
        TargetPlatform.windows,
        TargetPlatform.linux,
      ]) {
        expect(webBrowserIncognitoSupportedOn(p), isTrue, reason: '$p');
      }
    });
  });

  group('WebBrowserIncognitoProfiles', () {
    test('探测只跑一次并缓存；支持时清掉崩溃遗留的旧无痕 Profile', () async {
      final _FakeBackend backend = _FakeBackend();
      final WebBrowserIncognitoProfiles p = _profiles(backend);
      expect(p.multiProfileSupported, isNull);
      expect(await p.ensureProbed(), isTrue);
      expect(await p.ensureProbed(), isTrue);
      expect(backend.probes, 1);
      expect(p.multiProfileSupported, isTrue);
      expect(backend.cleanedPrefixes, <String>[
        WebBrowserIncognitoProfiles.profilePrefix,
      ]);
    });

    test('不支持 / 没有原生实现：判不支持，不清理', () async {
      final _FakeBackend unsupported = _FakeBackend(supported: false);
      final WebBrowserIncognitoProfiles a = _profiles(unsupported);
      expect(await a.ensureProbed(), isFalse);
      expect(unsupported.cleanedPrefixes, isEmpty);

      final _FakeBackend missing = _FakeBackend(
        throwOnProbe: MissingPluginException(),
      );
      final WebBrowserIncognitoProfiles b = _profiles(missing);
      expect(await b.ensureProbed(), isFalse);
      expect(b.multiProfileSupported, isFalse);
    });

    test('非 Android 不需要具名 Profile，也不探测', () async {
      final _FakeBackend backend = _FakeBackend();
      final WebBrowserIncognitoProfiles p = _profiles(
        backend,
        platform: TargetPlatform.windows,
      );
      expect(p.needsNamedProfile, isFalse);
      expect(await p.ensureProbed(), isFalse);
      expect(backend.probes, 0);
    });

    test('同一会话共用一个名字；结束后删掉它，下一会话换新名字', () async {
      final _FakeBackend backend = _FakeBackend();
      final WebBrowserIncognitoProfiles p = _profiles(backend);
      final String first = p.sessionProfileName();
      expect(first, startsWith(WebBrowserIncognitoProfiles.profilePrefix));
      expect(p.sessionProfileName(), first);
      await p.endSession();
      expect(backend.deleted, <String>[first]);
      expect(p.currentSessionProfileName, isNull);
      final String second = p.sessionProfileName();
      expect(second, isNot(first));
      await p.endSession();
      await p.endSession(); // 没有会话时不重复删。
      expect(backend.deleted, <String>[first, second]);
    });

    test('无痕下载取本会话 Profile 的 cookie；没有会话 / 空串返回 null', () async {
      final _FakeBackend backend = _FakeBackend();
      final WebBrowserIncognitoProfiles p = _profiles(backend);
      expect(await p.cookieHeader(_u('a')), isNull);
      final String name = p.sessionProfileName();
      backend.cookies[name] = 'sid=1';
      expect(await p.cookieHeader(_u('a')), 'sid=1');
      backend.cookies[name] = '';
      expect(await p.cookieHeader(_u('a')), isNull);
    });

    test('标签页 cookie 按会话取：无痕页绝不读持久罐', () async {
      final List<Uri> persistentReads = <Uri>[];
      Future<String?> persistent(Uri url) async {
        persistentReads.add(url);
        return 'login=normal';
      }

      // 普通标签页：任何平台都走持久罐。
      for (final TargetPlatform platform in TargetPlatform.values) {
        final WebBrowserIncognitoProfiles p = _profiles(
          _FakeBackend(),
          platform: platform,
        );
        expect(
          await p.tabCookieHeader(
            _u('a'),
            incognito: false,
            persistent: persistent,
          ),
          'login=normal',
        );
      }
      persistentReads.clear();

      // 非 Android 无痕页：没有可读的隔离罐 → 不带 cookie，也不碰持久罐。
      for (final TargetPlatform platform in <TargetPlatform>[
        TargetPlatform.windows,
        TargetPlatform.iOS,
        TargetPlatform.macOS,
        TargetPlatform.linux,
      ]) {
        final WebBrowserIncognitoProfiles p = _profiles(
          _FakeBackend(),
          platform: platform,
        );
        p.sessionProfileName();
        expect(
          await p.tabCookieHeader(
            _u('a'),
            incognito: true,
            persistent: persistent,
          ),
          isNull,
          reason: '$platform',
        );
      }
      expect(persistentReads, isEmpty);

      // Android 无痕页：取本会话具名 Profile 的 cookie。
      final _FakeBackend backend = _FakeBackend();
      final WebBrowserIncognitoProfiles android = _profiles(backend);
      backend.cookies[android.sessionProfileName()] = 'sid=incog';
      expect(
        await android.tabCookieHeader(
          _u('a'),
          incognito: true,
          persistent: persistent,
        ),
        'sid=incog',
      );
      expect(persistentReads, isEmpty);
    });

    test('applyWebBrowserIncognito：Android 关掉插件 incognito、挂会话 Profile', () {
      final WebBrowserIncognitoProfiles p = _profiles(_FakeBackend());
      final InAppWebViewSettings incognito = InAppWebViewSettings(
        incognito: true,
      );
      applyWebBrowserIncognito(incognito, incognito: true, profiles: p);
      expect(incognito.incognito, isFalse);
      expect(
        AndroidWebViewProfile.profileNameOf(incognito),
        p.currentSessionProfileName,
      );
      expect(AndroidWebViewProfile.profileNameOf(incognito), isNotNull);
      // 设置副本（adblock）不带具名 Profile，要对交给 WebView 的那份再接一次。
      expect(AndroidWebViewProfile.profileNameOf(incognito.copy()), isNull);

      final InAppWebViewSettings normal = InAppWebViewSettings();
      applyWebBrowserIncognito(normal, incognito: false, profiles: p);
      expect(normal.incognito, isFalse);
      expect(AndroidWebViewProfile.profileNameOf(normal), isNull);
    });

    test('applyWebBrowserIncognito：其它平台交给插件 incognito', () {
      final WebBrowserIncognitoProfiles p = _profiles(
        _FakeBackend(),
        platform: TargetPlatform.iOS,
      );
      final InAppWebViewSettings s = InAppWebViewSettings();
      applyWebBrowserIncognito(s, incognito: true, profiles: p);
      expect(s.incognito, isTrue);
      expect(AndroidWebViewProfile.profileNameOf(s), isNull);
      expect(p.currentSessionProfileName, isNull);
    });
  });

  group('标签控制器结束无痕会话', () {
    late _FakeBackend backend;
    late WebBrowserIncognitoProfiles profiles;
    late WebBrowserTabsController c;

    setUp(() {
      backend = _FakeBackend();
      profiles = _profiles(backend);
      c = WebBrowserTabsController(
        store: MemoryWebBrowserStore(),
        saveDebounce: Duration.zero,
        incognitoProfiles: profiles,
      );
    });

    test('关掉最后一个无痕标签页才删 Profile；普通标签页不影响', () async {
      final WebBrowserTab normal = c.openTab(_u('n'));
      final WebBrowserTab a = c.openTab(_u('a'), incognito: true);
      final WebBrowserTab b = c.openTab(_u('b'), incognito: true);
      final String name = profiles.sessionProfileName();
      c.closeTab(a);
      await Future<void>.delayed(Duration.zero);
      expect(backend.deleted, isEmpty);
      c.closeTab(normal);
      await Future<void>.delayed(Duration.zero);
      expect(backend.deleted, isEmpty);
      c.closeTab(b);
      await Future<void>.delayed(Duration.zero);
      expect(backend.deleted, <String>[name]);
      c.dispose();
    });

    test('浏览页销毁时还有无痕标签页：结束会话', () async {
      c.openTab(_u('a'), incognito: true);
      final String name = profiles.sessionProfileName();
      c.dispose();
      await Future<void>.delayed(Duration.zero);
      expect(backend.deleted, <String>[name]);
    });

    test('支持多 Profile 时探测完通知壳重建（入口出现）', () async {
      int notified = 0;
      c.addListener(() => notified++);
      await profiles.ensureProbed();
      await Future<void>.delayed(Duration.zero);
      expect(notified, 1);
      c.dispose();
    });
  });

  group('网页摄像头 / 麦克风的系统权限', () {
    test('只有 Android 的摄像头 / 麦克风要 app 自己申请', () {
      expect(
        webBrowserSystemPermissionsFor(<WebBrowserSitePermission>[
          WebBrowserSitePermission.camera,
          WebBrowserSitePermission.microphone,
        ], platform: TargetPlatform.android),
        <Permission>[Permission.camera, Permission.microphone],
      );
      expect(
        webBrowserSystemPermissionsFor(<WebBrowserSitePermission>[
          WebBrowserSitePermission.geolocation,
          WebBrowserSitePermission.notifications,
        ], platform: TargetPlatform.android),
        isEmpty,
      );
      expect(
        webBrowserSystemPermissionsFor(<WebBrowserSitePermission>[
          WebBrowserSitePermission.camera,
        ], platform: TargetPlatform.iOS),
        isEmpty,
      );
    });

    test('全部给了才允许；任一项拒绝 / 永久拒绝 / 抛错都拒绝', () async {
      Future<bool> run(
        Map<Permission, PermissionStatus> Function(List<Permission>) answer,
      ) => ensureWebBrowserSystemPermissions(
        <WebBrowserSitePermission>[
          WebBrowserSitePermission.camera,
          WebBrowserSitePermission.microphone,
        ],
        platform: TargetPlatform.android,
        request: (List<Permission> asked) async => answer(asked),
      );

      expect(
        await run(
          (List<Permission> asked) => <Permission, PermissionStatus>{
            for (final Permission p in asked) p: PermissionStatus.granted,
          },
        ),
        isTrue,
      );
      expect(
        await run(
          (_) => <Permission, PermissionStatus>{
            Permission.camera: PermissionStatus.granted,
            Permission.microphone: PermissionStatus.denied,
          },
        ),
        isFalse,
      );
      expect(
        await run(
          (_) => <Permission, PermissionStatus>{
            Permission.camera: PermissionStatus.permanentlyDenied,
            Permission.microphone: PermissionStatus.granted,
          },
        ),
        isFalse,
      );
      expect(
        await run(
          (_) => throw PlatformException(code: 'ERROR_ALREADY_REQUESTING'),
        ),
        isFalse,
      );
    });

    test('不涉及系统权限（iOS / 定位）时不弹系统框、直接放行', () async {
      int asked = 0;
      Future<Map<Permission, PermissionStatus>> request(
        List<Permission> p,
      ) async {
        asked++;
        return <Permission, PermissionStatus>{};
      }

      expect(
        await ensureWebBrowserSystemPermissions(
          <WebBrowserSitePermission>[WebBrowserSitePermission.camera],
          platform: TargetPlatform.iOS,
          request: request,
        ),
        isTrue,
      );
      expect(
        await ensureWebBrowserSystemPermissions(
          <WebBrowserSitePermission>[WebBrowserSitePermission.geolocation],
          platform: TargetPlatform.android,
          request: request,
        ),
        isTrue,
      );
      expect(asked, 0);
    });
  });
}
