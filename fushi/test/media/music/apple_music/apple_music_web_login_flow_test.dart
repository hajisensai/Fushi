import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/music/apple_music/apple_music_web_bridge.dart';
import 'package:fushi/src/media/music/apple_music/apple_music_web_login_flow.dart';
import 'package:fushi/src/media/music/apple_music/apple_music_web_login_page.dart';

/// 2026-11-04 HiBreak 真机抓到的无订阅账号弹窗路径（query 已去掉）。
final List<Uri> _noSubscriptionRun = <Uri>[
  Uri.parse('https://authorize.music.apple.com/woa?a=x&referrer=y'),
  Uri.parse('https://activate.apple.com/mkauth?jwtToken=secret'),
  Uri.parse('https://idmsa.apple.com/IDMSWebAuth/auth?oauth_token=secret'),
  Uri.parse(
    'https://p57-buy.itunes.apple.com/commerce/account/validateMusicKitToken?t=secret',
  ),
  Uri.parse('https://authorize.music.apple.com/?cid=1&jwt=secret'),
  Uri.parse('https://authorize.music.apple.com/upsell?cid=1&jwt=secret'),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  group('appleMusicPopupOpenerSeedJs', () {
    test('只在 Apple 授权页、ac 缺失时写入托管页地址', () {
      final String js = appleMusicPopupOpenerSeedJs(kAppleMusicWebBridgePage);
      expect(js, contains("location.hostname !== 'authorize.music.apple.com'"));
      expect(
        js,
        contains("if (sessionStorage.getItem('ac')) return 'present'"),
      );
      expect(
        js,
        contains(
          "sessionStorage.setItem('ac', 'https://rank.fushi.moe/musickit/')",
        ),
      );
    });

    test('地址里的单引号被转义，不会截断脚本', () {
      final String js = appleMusicPopupOpenerSeedJs(
        Uri.parse("https://example.com/a'b"),
      );
      expect(js, contains(r"https://example.com/a\'b"));
    });
  });

  group('appleMusicLoginBlockerOf', () {
    test('Apple 授权页的结论页映射到原因', () {
      AppleMusicLoginBlocker? of(String u) =>
          appleMusicLoginBlockerOf(Uri.parse(u));
      expect(
        of('https://authorize.music.apple.com/upsell?jwt=x'),
        AppleMusicLoginBlocker.noSubscription,
      );
      expect(
        of('https://authorize.music.apple.com/error/no-subscription'),
        AppleMusicLoginBlocker.noSubscription,
      );
      expect(
        of('https://authorize.music.apple.com/error/unsupported-country'),
        AppleMusicLoginBlocker.unsupportedCountry,
      );
      expect(
        of('https://authorize.music.apple.com/error/unsupported-device'),
        AppleMusicLoginBlocker.unsupportedDevice,
      );
    });

    test('其它页面与其它主机不算结论', () {
      expect(
        appleMusicLoginBlockerOf(
          Uri.parse('https://authorize.music.apple.com/woa'),
        ),
        isNull,
      );
      expect(
        appleMusicLoginBlockerOf(Uri.parse('https://example.com/upsell')),
        isNull,
      );
    });
  });

  group('AppleMusicLoginTrace', () {
    test('真机无订阅路径：判成无订阅，日志只有主机与路径、不带 query', () {
      final AppleMusicLoginTrace trace = AppleMusicLoginTrace();
      for (final Uri u in _noSubscriptionRun) {
        trace.popupPage(u);
        trace.popupPage(u); // 同一页多次 loadStop 只记一次。
      }
      trace.openerSeed('seeded');
      trace.openerSeed('present');
      trace.popupClosed();
      expect(trace.blocker, AppleMusicLoginBlocker.noSubscription);
      final String line = trace.describe('authorize failed: x');
      expect(line, isNot(contains('secret')));
      expect(line, isNot(contains('?')));
      expect(trace.steps, <String>[
        'page authorize.music.apple.com/woa',
        'page activate.apple.com/mkauth',
        'page idmsa.apple.com/IDMSWebAuth/auth',
        'page p57-buy.itunes.apple.com/commerce/account/validateMusicKitToken',
        'page authorize.music.apple.com/',
        'page authorize.music.apple.com/upsell',
        'opener seeded',
        'popup closed',
      ]);
    });

    test('没开出弹窗时日志写明', () {
      expect(
        AppleMusicLoginTrace().describe('init timeout'),
        'init timeout; no popup',
      );
    });
  });

  group('appleMusicLoginFailureText', () {
    test('有结论页给明确原因，否则原样给错误', () {
      expect(
        appleMusicLoginFailureText(
          blocker: AppleMusicLoginBlocker.noSubscription,
          error: 'AUTHORIZATION_ERROR: Unauthorized',
        ),
        t.music_apple_music_login_no_subscription,
      );
      expect(appleMusicLoginFailureText(blocker: null, error: 'boom'), 'boom');
      expect(appleMusicLoginFailureText(blocker: null, error: null), 'unknown');
    });
  });

  // D69n21etZ1：init 超时一律报「DRM 无响应」是误报——该设备连 Fushi 服务器本身就在超时。
  group('appleMusicInitFailureText', () {
    test('只有卡在 configure 才说 DRM', () {
      expect(
        appleMusicInitFailureText(stage: 'configure', timedOut: true),
        t.music_apple_music_login_init_timeout,
      );
    });

    test('卡在取 token / 加载 MusicKit JS：报网络段，不提 DRM', () {
      expect(
        appleMusicInitFailureText(stage: 'token', timedOut: true),
        t.music_apple_music_login_init_token_failed,
      );
      expect(
        appleMusicInitFailureText(stage: 'musickit_js', timedOut: true),
        t.music_apple_music_login_init_musickit_js_failed,
      );
      expect(
        appleMusicInitFailureText(
          stage: 'token',
          timedOut: false,
          error: 'Error: token_timeout',
        ),
        '${t.music_apple_music_login_init_token_failed} (Error: token_timeout)',
      );
    });

    test('不知道卡在哪段（旧版托管页）：只说超时', () {
      for (final String? stage in <String?>[null, 'idle', 'ready']) {
        expect(
          appleMusicInitFailureText(stage: stage, timedOut: true),
          t.music_apple_music_login_init_timeout_unknown,
        );
      }
    });

    test('configure 自己抛错（非超时）：原样给错误', () {
      expect(
        appleMusicInitFailureText(
          stage: 'configure',
          timedOut: false,
          error: 'MKError: DRM_UNSUPPORTED',
        ),
        'MKError: DRM_UNSUPPORTED',
      );
    });
  });
}
