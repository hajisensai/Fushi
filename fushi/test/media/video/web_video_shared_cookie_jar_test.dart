import 'dart:io';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/cookie/manga_web_view_environment.dart';
import 'package:fushi/src/media/video/web_video_hosting.dart';
import 'package:fushi/src/media/video/web_video_login_migration.dart';
import 'package:fushi_engine/utils/net/app_proxy.dart';

import '../../helpers/source_guard.dart';

/// 播放器网页（原生播放器页窗口宿主 4K 档）与 app 内浏览器共用一个 WebView2 cookie 罐：
/// fork 剥掉窗口宿主哨兵后两边浏览器参数逐字一致，可以住同一个 user data folder。
void main() {
  group('浏览器参数：窗口宿主档 = 浏览器参数 + 哨兵，剥完逐字一致', () {
    final List<(String, String?)> proxies = <(String, String?)>[
      (kProxyModeDirect, null),
      ('manual', '127.0.0.1:34151'),
      ('auto', null),
      ('auto', '10.0.0.2:8080'),
    ];
    for (final (String mode, String? hostPort) in proxies) {
      test('mode=$mode proxy=$hostPort', () {
        final String browser = MangaWebViewEnvironment.browserArguments(
          mode: mode,
          proxyHostPort: hostPort,
        );
        // 窗口宿主档要无手势自动播放，同目录参数一致 → 浏览器也必须带。
        expect(browser, startsWith(MangaWebViewEnvironment.kAutoplayArgument));
        expect(browser, isNot(contains('  ')));
        expect(browser.trim(), browser);
        final ({String arguments, bool found}) stripped =
            stripWindowedHostingSentinel(windowedHostingArguments(browser));
        expect(stripped.found, isTrue);
        expect(stripped.arguments, browser);
        // 浏览器自己那套没有哨兵：原样交给 WebView2。
        final ({String arguments, bool found}) plain =
            stripWindowedHostingSentinel(browser);
        expect(plain.found, isFalse);
        expect(plain.arguments, browser);
      });
    }
  });

  test('哨兵剥离：开头 / 中间多空白 / 结尾 / 只是更长开关的子串', () {
    const String s = kWebVideoWindowedHostingSentinel;
    expect(stripWindowedHostingSentinel(s), (arguments: '', found: true));
    expect(stripWindowedHostingSentinel('$s  --a'), (
      arguments: '--a',
      found: true,
    ));
    expect(stripWindowedHostingSentinel('--a   $s --b'), (
      arguments: '--a --b',
      found: true,
    ));
    expect(stripWindowedHostingSentinel('--a $s'), (
      arguments: '--a',
      found: true,
    ));
    expect(stripWindowedHostingSentinel('--a $s-x'), (
      arguments: '--a $s-x',
      found: false,
    ));
    expect(stripWindowedHostingSentinel('--a'), (
      arguments: '--a',
      found: false,
    ));
  });

  group('共享 cookie 罐目录', () {
    test('生产：%LOCALAPPDATA%\\Fushi\\MangaWebView2（沿用浏览器既有目录，保住已有登录）', () {
      expect(
        MangaWebViewEnvironment.sharedUserDataFolder(
          environment: <String, String>{'LOCALAPPDATA': r'C:\L'},
        ),
        r'C:\L\Fushi\MangaWebView2',
      );
      expect(
        MangaWebViewEnvironment.sharedUserDataFolder(
          environment: <String, String>{'LOCALAPPDATA': r'C:\L'},
          suffix: '-ab',
        ),
        r'C:\L\Fushi\MangaWebView2-ab',
      );
    });

    test('itest 隔离根 / BUG-1483 回落：FUSHI_WEBVIEW2_USER_DATA_FOLDER-manga', () {
      expect(
        MangaWebViewEnvironment.sharedUserDataFolder(
          environment: <String, String>{
            'LOCALAPPDATA': r'C:\L',
            'FUSHI_WEBVIEW2_USER_DATA_FOLDER': r'D:\t\wv',
          },
        ),
        r'D:\t\wv-manga',
      );
    });

    test('网页视频 itest 覆盖（PlayReady 要 LOCALAPPDATA）优先于隔离根', () {
      expect(
        MangaWebViewEnvironment.sharedUserDataFolder(
          environment: <String, String>{
            'LOCALAPPDATA': r'C:\L',
            'FUSHI_WEBVIEW2_USER_DATA_FOLDER': r'D:\t\wv',
            'FUSHI_WEB_VIDEO_4K_USER_DATA_FOLDER': r'C:\L\Fushi\itest-4k',
          },
          suffix: '-1',
        ),
        r'C:\L\Fushi\itest-4k-1',
      );
    });
  });

  group('旧 4K profile 登录迁移', () {
    test('旧目录 = 可捕获档目录 + -4k；4K 覆盖时没有旧目录', () {
      expect(
        webVideoLegacyWindowedUserDataFolder(
          environment: const <String, String>{},
          capturableFolder: r'C:\L\Fushi\WebVideoWebView2',
        ),
        r'C:\L\Fushi\WebVideoWebView2-4k',
      );
      expect(
        webVideoLegacyWindowedUserDataFolder(
          environment: const <String, String>{
            'FUSHI_WEB_VIDEO_4K_USER_DATA_FOLDER': r'C:\x',
          },
          capturableFolder: r'C:\L\Fushi\WebVideoWebView2',
        ),
        isNull,
      );
    });

    test('判据：有 profile、没标记、不是共享罐本身才迁', () {
      bool needs({
        String? legacy = r'C:\a-4k',
        String shared = r'C:\m',
        bool profile = true,
        bool marker = false,
      }) => webVideoLegacyLoginNeedsMigration(
        legacyFolder: legacy,
        sharedFolder: shared,
        legacyProfileExists: profile,
        markerExists: marker,
      );
      expect(needs(), isTrue);
      expect(needs(legacy: null), isFalse);
      expect(needs(profile: false), isFalse);
      expect(needs(marker: true), isFalse);
      expect(needs(legacy: r'C:\M', shared: r'c:\m'), isFalse);
    });

    test('只补缺：共享罐已有同名同域同路径的不覆盖；空值 / 无域名跳过', () {
      final List<Cookie> legacy = <Cookie>[
        Cookie(name: 'NetflixId', value: 'old', domain: '.netflix.com'),
        Cookie(name: 'nfvdid', value: 'v', domain: '.netflix.com', path: '/'),
        Cookie(name: 'SID', value: 's', domain: '.youtube.com', path: '/'),
        Cookie(name: 'empty', value: '', domain: '.youtube.com'),
        Cookie(name: 'nodomain', value: 'x'),
      ];
      final List<Cookie> shared = <Cookie>[
        // 浏览器里已登录：不被旧值盖掉（域有无前导点算同一条）。
        Cookie(name: 'NetflixId', value: 'new', domain: 'netflix.com'),
        // 同名不同路径不算同一条。
        Cookie(name: 'SID', value: 'z', domain: '.youtube.com', path: '/x'),
      ];
      expect(
        <String>[
          for (final Cookie c in webVideoLegacyCookiesToMigrate(
            legacy: legacy,
            shared: shared,
          ))
            c.name,
        ],
        <String>['nfvdid', 'SID'],
      );
    });

    test('写 cookie 的地址：去前导点、Secure 走 https、带路径', () {
      expect(
        webVideoCookieUrl(
          Cookie(
            name: 'a',
            value: '1',
            domain: '.netflix.com',
            path: '/watch',
            isSecure: true,
          ),
        ).toString(),
        'https://netflix.com/watch',
      );
      expect(
        webVideoCookieUrl(
          Cookie(name: 'a', value: '1', domain: 'x.test', isSecure: false),
        ).toString(),
        'http://x.test/',
      );
    });
  });

  group('源码守卫', () {
    const String fork = '../packages/flutter_inappwebview_windows/windows';

    test('fork 建环境时剥掉哨兵再交给 WebView2（不再原样 put 进 AdditionalBrowserArguments）', () {
      final String src = maskComments(
        File(
          '$fork/webview_environment/webview_environment.cpp',
        ).readAsStringSync(),
      );
      expect(src, contains('StripWindowedHostingSentinel('));
      expect(
        src,
        isNot(
          contains(
            'put_AdditionalBrowserArguments(utf8_to_wide(settings->additionalBrowserArguments.value())',
          ),
        ),
        reason: '哨兵原样交给 WebView2 → 与浏览器参数不同 → 不能共用 user data folder',
      );
      expect(src, contains('windowedHosting = sentinel;'));
    });

    test('无头 WebView 静音（浏览器共享环境允许无手势有声自动播放）', () {
      final String src = maskComments(
        File(
          '$fork/headless_in_app_webview/headless_in_app_webview.cpp',
        ).readAsStringSync(),
      );
      expect(src, contains('put_IsMuted(TRUE)'));
    });

    test('窗口宿主档环境由共享罐提供，不再自建独立目录', () {
      final String src = maskComments(
        File('lib/src/media/video/web_video_session.dart').readAsStringSync(),
      );
      expect(src, contains('MangaWebViewEnvironment.obtainWindowedHosting()'));
      expect(src, isNot(contains('kWebVideoWindowedHostingSentinel')));
      expect(src, isNot(contains("'-4k'")));
      expect(src, isNot(contains('}-4k')));
    });
  });
}
