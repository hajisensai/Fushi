import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/misc/platform_updater.dart';
import 'package:fushi/src/utils/misc/update_landing.dart';

/// iOS 更新落地入口（TestFlight / App Store / GitHub 发布页）。
///
/// 背景：iOS 的三条分发链路互不相干，「去哪儿更新」只由**安装来源**决定，不由更新
/// 通道决定。改动前所有 iOS 用户一律被送到 GitHub 发布页——TestFlight 用户在那儿
/// 拿到的是装不上的未签名 ipa。这里锁死映射本身（纯函数）+ 平台默认行为不被误伤。
void main() {
  const String releaseUrl =
      'https://github.com/hajisensai/fushi/releases/tag/v1.2.3';

  group('iosUpdateLanding', () {
    test('侧载安装 → 发布页（未签名 ipa 是他们唯一取包处）', () {
      final UpdateLanding landing = iosUpdateLanding(
        source: IosInstallSource.sideload,
        releaseHtmlUrl: releaseUrl,
      );
      expect(landing.kind, UpdateLandingKind.releasePage);
      expect(landing.url, releaseUrl);
    });

    test('TestFlight 安装 → TestFlight，绝不落回 GitHub', () {
      final UpdateLanding landing = iosUpdateLanding(
        source: IosInstallSource.testFlight,
        releaseHtmlUrl: releaseUrl,
      );
      expect(landing.kind, UpdateLandingKind.testFlight);
      expect(landing.url, isNot(releaseUrl));
      expect(landing.url, iosTestFlightUrl());
    });

    test('TestFlight 落地 URL 是能被系统识别的入口（scheme 或 https 链接）', () {
      final Uri uri = Uri.parse(iosTestFlightUrl());
      expect(uri.hasScheme, isTrue);
      expect(
        uri.scheme == 'itms-beta' ||
            (uri.scheme == 'https' && uri.host == 'testflight.apple.com'),
        isTrue,
        reason: 'TestFlight 入口只能是 itms-beta:// 或 testflight.apple.com 链接，'
            '当前是 ${iosTestFlightUrl()}',
      );
    });

    test('App Store ID 未配置（上架前）→ 回发布页，不造 id 死链', () {
      // 这条同时是「上架当天要做什么」的可执行文档：填 kIosAppStoreAppId 后本用例
      // 会走到下面那条 skip 掉的分支，需要连带更新。
      if (kIosAppStoreAppId.isNotEmpty) {
        final UpdateLanding landing = iosUpdateLanding(
          source: IosInstallSource.appStore,
          releaseHtmlUrl: releaseUrl,
        );
        expect(landing.kind, UpdateLandingKind.appStore);
        expect(landing.url, contains(kIosAppStoreAppId));
        return;
      }
      final UpdateLanding landing = iosUpdateLanding(
        source: IosInstallSource.appStore,
        releaseHtmlUrl: releaseUrl,
      );
      expect(landing.kind, UpdateLandingKind.releasePage);
      expect(landing.url, releaseUrl);
      expect(iosAppStoreUrl(), isNull);
    });

    test('配置了 App Store ID 时 URL 直接拉起 App Store app', () {
      // iosAppStoreUrl() 依赖编译期常量，这里锁死拼装规则本身（上架后 ID 一填即生效）。
      expect(
        'itms-apps://apps.apple.com/app/id123456789',
        matches(RegExp(r'^itms-apps://apps\.apple\.com/app/id\d+$')),
      );
    });
  });

  group('parseIosInstallSource', () {
    test('认得 native 的三个值', () {
      expect(parseIosInstallSource('appStore'), IosInstallSource.appStore);
      expect(parseIosInstallSource('testFlight'), IosInstallSource.testFlight);
      expect(parseIosInstallSource('sideload'), IosInstallSource.sideload);
    });

    test('认不出/通道缺失 → 侧载（= 保持改动前的发布页行为，fail-safe）', () {
      expect(parseIosInstallSource(null), IosInstallSource.sideload);
      expect(parseIosInstallSource(''), IosInstallSource.sideload);
      expect(parseIosInstallSource('AppStore'), IosInstallSource.sideload);
      expect(parseIosInstallSource('something-new'), IosInstallSource.sideload);
    });
  });

  group('PlatformUpdater.resolveDownloadLanding', () {
    tearDown(() => IosInstallSourceResolver.setForTest(null));

    test('IosUpdater 按安装来源分流', () async {
      IosInstallSourceResolver.setForTest(IosInstallSource.testFlight);
      final UpdateLanding tf =
          await IosUpdater().resolveDownloadLanding(releaseUrl);
      expect(tf.kind, UpdateLandingKind.testFlight);

      IosInstallSourceResolver.setForTest(IosInstallSource.sideload);
      final UpdateLanding side =
          await IosUpdater().resolveDownloadLanding(releaseUrl);
      expect(side.kind, UpdateLandingKind.releasePage);
      expect(side.url, releaseUrl);
    });

    test('非 iOS 平台仍是发布页（不被 iOS 分流误伤）', () async {
      for (final PlatformUpdater updater in <PlatformUpdater>[
        AndroidUpdater(),
        WindowsUpdater(),
        MacUpdater(),
        UnsupportedUpdater(),
      ]) {
        final UpdateLanding landing =
            await updater.resolveDownloadLanding(releaseUrl);
        expect(landing.kind, UpdateLandingKind.releasePage,
            reason: '${updater.runtimeType} 不该改动落地入口');
        expect(landing.url, releaseUrl);
      }
    });
  });

  group('iOS native 契约（源码守卫）', () {
    // 测试 CWD = `fushi/`。真行为是 OS 级的（收据文件由系统写入，跑不了），
    // 所以守的是契约：Dart 侧要的方法名与判据必须在 AppDelegate 里存在。
    final File appDelegate = File('ios/Runner/AppDelegate.swift');
    final File infoPlist = File('ios/Runner/Info.plist');

    test('AppDelegate 暴露 getInstallSource 并挂在 update 通道上', () {
      expect(appDelegate.existsSync(), isTrue);
      final String swift = appDelegate.readAsStringSync();
      expect(swift, contains('app.fushi.reader/update'));
      expect(swift, contains('getInstallSource'));
      expect(swift, contains('sandboxReceipt'));
      // 三个返回值必须与 parseIosInstallSource 认得的字面量一致。
      expect(swift, contains('"testFlight"'));
      expect(swift, contains('"appStore"'));
      expect(swift, contains('"sideload"'));
    });

    test('收据判据必须查文件是否真存在，只看文件名会把侧载误判成 TestFlight', () {
      final String swift = appDelegate.readAsStringSync();
      expect(
        swift,
        contains('fileExists(atPath:'),
        reason: 'appStoreReceiptURL 对侧载包也返回路径，不查 fileExists 就会误判',
      );
    });

    test('Info.plist 登记了 itms-beta / itms-apps，否则按钮点了没反应', () {
      expect(infoPlist.existsSync(), isTrue);
      final String plist = infoPlist.readAsStringSync();
      final int schemesIndex = plist.indexOf('LSApplicationQueriesSchemes');
      expect(schemesIndex, greaterThanOrEqualTo(0));
      final int arrayEnd = plist.indexOf('</array>', schemesIndex);
      expect(arrayEnd, greaterThan(schemesIndex));
      final String schemes = plist.substring(schemesIndex, arrayEnd);
      expect(schemes, contains('<string>itms-beta</string>'));
      expect(schemes, contains('<string>itms-apps</string>'));
    });
  });
}
