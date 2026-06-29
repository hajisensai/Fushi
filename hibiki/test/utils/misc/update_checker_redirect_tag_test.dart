import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/misc/platform_updater.dart';
import 'package:hibiki/src/utils/misc/update_checker.dart';

void main() {
  group('parseLatestTagFromRedirectLocation (302 Location -> tag, 纯函数)', () {
    test('直连 Location（releases/tag/<tag>）抽出原始 tag 段（保留前导 v）', () {
      const String location =
          'https://github.com/hajisensai/hibiki/releases/tag/v0.4.1';
      expect(parseLatestTagFromRedirectLocation(location), 'v0.4.1');
    });

    test('镜像前缀改写后的 Location 仍只认 releases/tag 段、丢弃域名', () {
      // 镜像可能把 Location 改写成「镜像域名 + 真实 github URL」形式。
      const String location =
          'https://ghfast.top/https://github.com/hajisensai/hibiki/releases/tag/v0.4.1';
      expect(parseLatestTagFromRedirectLocation(location), 'v0.4.1');
    });

    test('相对路径 Location 也能解析（GitHub 有时返回相对跳转）', () {
      const String location = '/hajisensai/hibiki/releases/tag/v1.2.3';
      expect(parseLatestTagFromRedirectLocation(location), 'v1.2.3');
    });

    test('带查询/锚点片段时只取 tag 段、截到 ?/# 前', () {
      const String location =
          'https://github.com/x/y/releases/tag/v0.5.0?foo=bar#section';
      expect(parseLatestTagFromRedirectLocation(location), 'v0.5.0');
    });

    test('不带 v 前缀的 tag 也接受', () {
      const String location = 'https://github.com/x/y/releases/tag/0.6.0';
      expect(parseLatestTagFromRedirectLocation(location), '0.6.0');
    });

    test('无 releases/tag 段（落到 releases 列表页）返回 null', () {
      const String location = 'https://github.com/x/y/releases';
      expect(parseLatestTagFromRedirectLocation(location), isNull);
    });

    test('tag 段不是合法版本串（如登录跳转）返回 null', () {
      const String location = 'https://github.com/login?return_to=%2Fx%2Fy';
      expect(parseLatestTagFromRedirectLocation(location), isNull);
      const String notVersion =
          'https://github.com/x/y/releases/tag/not-a-version!!';
      expect(parseLatestTagFromRedirectLocation(notVersion), isNull);
    });

    test('入参为 null / 空串返回 null', () {
      expect(parseLatestTagFromRedirectLocation(null), isNull);
      expect(parseLatestTagFromRedirectLocation(''), isNull);
    });
  });

  group('synthesizeStableAssetNames (资产命名重建，纯函数)', () {
    test('合成 Windows setup + 全 Android ABI 的 apk 名', () {
      final List<String> names = synthesizeStableAssetNames('0.4.1');
      expect(names, contains('hibiki-0.4.1-windows-setup.exe'));
      for (final String abi in kAndroidReleaseAbis) {
        expect(names, contains('hibiki-0.4.1-$abi.apk'));
      }
    });

    test('返回不可变列表（防误改单一真相源）', () {
      final List<String> names = synthesizeStableAssetNames('1.0.0');
      expect(() => names.add('x'), throwsUnsupportedError);
    });
  });

  group('buildStableReleaseFromTag (302 tag -> API 同构 release map)', () {
    test(
        'stable release URL helpers prefer canonical repo with legacy fallback',
        () {
      expect(kStableReleasesLatestUrl,
          'https://github.com/hajisensai/hibiki/releases/latest');
      expect(kLegacyStableReleasesLatestUrl,
          'https://github.com/hdjsadgfwtg/hibiki/releases/latest');
      expect(stableReleasesLatestUrlForRepo(kLegacyGitHubRepo),
          'https://github.com/hdjsadgfwtg/hibiki/releases/latest');
    });

    test('用原始 tag（含 v）拼 download URL，version 去前导 v', () {
      final Map<String, dynamic> release = buildStableReleaseFromTag('v0.4.1');
      expect(release['tag_name'], 'v0.4.1');
      expect(release['prerelease'], isFalse);
      expect(release['draft'], isFalse);
      expect(release['body'], '');
      expect(release['html_url'], contains('/releases/tag/v0.4.1'));

      final List<dynamic> assets = release['assets'] as List<dynamic>;
      final Map<String, dynamic> windows = assets
          .cast<Map<String, dynamic>>()
          .firstWhere((Map<String, dynamic> a) =>
              (a['name'] as String).endsWith('-windows-setup.exe'));
      expect(
        windows['browser_download_url'],
        'https://github.com/hajisensai/hibiki/releases/download/v0.4.1/hibiki-0.4.1-windows-setup.exe',
      );
    });

    test('legacy repo override preserves installable fallback download URLs',
        () {
      final Map<String, dynamic> release = buildStableReleaseFromTag(
        'v0.4.1',
        repo: kLegacyGitHubRepo,
      );
      expect(
        release['html_url'],
        'https://github.com/hdjsadgfwtg/hibiki/releases/tag/v0.4.1',
      );
      final List<dynamic> assets = release['assets'] as List<dynamic>;
      final Map<String, dynamic> windows = assets
          .cast<Map<String, dynamic>>()
          .firstWhere((Map<String, dynamic> a) =>
              (a['name'] as String).endsWith('-windows-setup.exe'));
      expect(
        windows['browser_download_url'],
        'https://github.com/hdjsadgfwtg/hibiki/releases/download/v0.4.1/hibiki-0.4.1-windows-setup.exe',
      );
    });

    test('合成的 release 能通过 stable 通道匹配（直接喂现有挑包链路）', () {
      final Map<String, dynamic> release = buildStableReleaseFromTag('v0.4.1');
      expect(
        releaseMatchesUpdateChannel(release, UpdateChannel.stable),
        isTrue,
      );
    });

    test('Windows updater 能从合成 release 选出 setup 下载 URL', () async {
      final Map<String, dynamic> release = buildStableReleaseFromTag('v0.4.1');
      final List<Map<String, dynamic>> assets =
          (release['assets'] as List<dynamic>).cast<Map<String, dynamic>>();
      final UpdateAsset? asset = await WindowsUpdater().selectAsset(assets);
      expect(
        asset?.url,
        'https://github.com/hajisensai/hibiki/releases/download/v0.4.1/hibiki-0.4.1-windows-setup.exe',
      );
    });

    test('Android updater 按设备 ABI 从合成 release 选出对应 apk', () async {
      final Map<String, dynamic> release = buildStableReleaseFromTag('v0.4.1');
      final List<Map<String, dynamic>> assets =
          (release['assets'] as List<dynamic>).cast<Map<String, dynamic>>();
      final UpdateAsset? asset = await AndroidUpdater(
        abiProvider: () async => <String>['arm64-v8a'],
      ).selectAsset(assets);
      expect(
        asset?.url,
        'https://github.com/hajisensai/hibiki/releases/download/v0.4.1/hibiki-0.4.1-arm64-v8a.apk',
      );
    });
  });

  group('302 候选并发竞速（直连恒首位 + 并发选最快活源，注入 fetcher）', () {
    test('直连首位 302 失败时镜像候选胜出（候选并发发起，不串行逐个等）', () async {
      final List<String> attempted = <String>[];
      final List<String> urls =
          updateCheckUrls('https://github.com/x/y/releases/latest');
      expect(urls.first, 'https://github.com/x/y/releases/latest',
          reason: '直连必须恒为首候选');

      // 模拟：直连本身被 GFW 切断（返回 null），镜像透传 302 拿到 tag。
      final String? tag = await fetchFirstSuccessfulBody(
        urls,
        fetch: (String u) async {
          attempted.add(u);
          if (u == urls.first) return null; // 直连失败
          return parseLatestTagFromRedirectLocation(
            'https://github.com/x/y/releases/tag/v0.4.1',
          );
        },
      );
      expect(tag, 'v0.4.1');
      // TODO-821：并发竞速 → 所有候选都被并发发起（不再串行「直连失败才试镜像」）。
      // 直连失败、镜像成功 → 镜像胜出。
      expect(attempted, unorderedEquals(urls), reason: '并发竞速：全部候选并发发起');
      expect(attempted.length, urls.length);
    });

    test('全候选 302 都失败则整体返回 null（回退到 API 直连由上层负责）', () async {
      final List<String> urls =
          updateCheckUrls('https://github.com/x/y/releases/latest');
      final String? tag = await fetchFirstSuccessfulBody(
        urls,
        fetch: (String _) async => null,
      );
      expect(tag, isNull);
    });
  });
}
