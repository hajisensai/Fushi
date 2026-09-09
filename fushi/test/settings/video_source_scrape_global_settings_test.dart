import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_models.dart';
import 'package:fushi/src/media/video/metadata/video_source_scrape_config.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema_services.dart';
import 'package:fushi/src/settings/settings_schema_video.dart';

void main() {
  // AniDB 身份 / TMDB key 是第三方凭据，住「在线服务」分区；刮削语言是刮削行为
  // 偏好，留在视频·媒体库。两处合起来才是完整的刮削运行期偏好面。
  Iterable<SettingsItem> descendants(SettingsDestination destination) sync* {
    for (final SettingsSection section in destination.sections) {
      for (final SettingsItem item in section.items) {
        yield item;
        if (item is SettingsNavigationItem && item.child != null) {
          yield* descendants(item.child!());
        }
      }
    }
  }

  List<SettingsItem> allScrapeSettings() => <SettingsItem>[
    ...descendants(buildVideoDestination()),
    ...descendants(buildServicesDestination()),
  ];

  SettingsItem item(String id) => allScrapeSettings().singleWhere(
    (SettingsItem candidate) => candidate.id == id,
  );

  // 这条原本断言「主源写死、不给用户选」。用户 2026-09-08 推翻了那半条裁决
  // （BUG-2268）：中文目录名在 MAL 上只搜得到「类型年份合格但标题不符」的候选，
  // 而旧链路「主源歧义即短路」让 TMDB 永远问不到，整批番剧记成识别失败。
  //
  // 但那条测试真正护住的不变式没变，只是被「不给选」连带写死了：**作品资料源
  // 只有 MAL 与 TMDB 两家**。所以这里改成钉住可选范围与历史值的处置——
  // 退役的 Bangumi / Douban / AniList 不得借「可选」回潮，AniDB 也不得升格成
  // 作品资料主源（它只做文件身份识别，见 CLAUDE.md 的 provider 边界）。
  test('primary metadata source is selectable, but only MAL and TMDB', () {
    expect(
      kSelectableVideoMetadataProviders,
      <VideoMetadataProviderKind>[
        VideoMetadataProviderKind.mal,
        VideoMetadataProviderKind.tmdb,
      ],
      reason: '作品资料源只有这两家；加第三家是 provider 边界变更，要先过用户',
    );

    // 下拉的选项必须**由白名单生成**，不能另抄一份可选值——抄一份就会出现
    // 「白名单收窄了、UI 还给得出旧值」这种两套真相。
    final SettingsSegmentedItem<String> primary =
        item('video.library.metadata_primary_provider')
            as SettingsSegmentedItem<String>;
    expect(
      primary.options.map((SettingsSegmentOption<String> o) => o.value),
      kSelectableVideoMetadataProviders.map(
        (VideoMetadataProviderKind k) => k.name,
      ),
    );

    // 已退役资料源的历史持久化值必须回落默认，不得被当成合法主源复活。
    for (final String retired in <String>[
      'bangumi',
      'douban',
      'anilist',
      'anidb',
      'fanart',
      '',
      'nonsense',
    ]) {
      expect(
        parseSelectableVideoMetadataProvider(retired),
        isNull,
        reason: '$retired 不是可选主源，历史值必须回落全局默认',
      );
    }
  });

  test('AniDB identity, TMDB key, and locale are reachable from settings', () {
    final Map<String, bool> expectedSecret = <String, bool>{
      'services.metadata.anidb_client': false,
      'services.metadata.anidb_client_version': false,
      'services.metadata.anidb_username': false,
      'services.metadata.anidb_password': true,
      'services.metadata.tmdb_api_key': true,
      'video.library.metadata_locale': false,
    };

    for (final MapEntry<String, bool> entry in expectedSecret.entries) {
      final SettingsTextItem textItem = item(entry.key) as SettingsTextItem;
      expect(
        textItem.secret,
        entry.value,
        reason: '${entry.key} secret rendering mismatch',
      );
    }
  });

  test('metadata runtime preferences rebuild the download scraper snapshot', () {
    final String videoSource = File(
      'lib/src/settings/settings_schema_video.dart',
    ).readAsStringSync();
    final String servicesSource = File(
      'lib/src/settings/settings_schema_services.dart',
    ).readAsStringSync();
    final String actionsSource = File(
      'lib/src/media/video/video_settings_actions.dart',
    ).readAsStringSync();
    final RegExp call = RegExp(r'commitVideoMetadataRuntimePreference\(');
    expect(
      call.allMatches(videoSource).length,
      3,
      reason:
          '刮削语言、刮削主源与识别词三处运行期偏好都必须走共享 helper —— 只有它'
          '会重建下载管线的刮削快照；漏一处就是「设置改了、下一批还用旧值」。'
          '这里数的是「视频·媒体库」分区里的运行期刮削偏好数，再加一项要同步 +1',
    );
    expect(
      call.allMatches(servicesSource).length,
      5,
      reason:
          'AniDB client/version/account + TMDB key must use the shared helper',
    );
    expect(
      call.allMatches(actionsSource).length,
      1,
      reason: 'the helper is defined once, in video_settings_actions.dart',
    );
    expect(
      actionsSource,
      contains(
        'await settingsContext.appModel.'
        'reloadVideoDownloadPipelineRuntime();',
      ),
    );
  });

  test('invalid AniDB versions disable the HTTP API safely', () {
    expect(parseAniDbClientVersion('1'), 1);
    expect(parseAniDbClientVersion(' 42 '), 42);
    expect(parseAniDbClientVersion('0'), isNull);
    expect(parseAniDbClientVersion('-1'), isNull);
    expect(parseAniDbClientVersion('not-a-number'), isNull);
    expect(parseAniDbClientVersion(null), isNull);
  });

  test(
    'hash identification is opt-in and requires all registration fields',
    () {
      expect(
        item('services.metadata.anidb_hash_enabled'),
        isA<SettingsSwitchItem>(),
      );
      const VideoSourceScrapeGlobalConfig empty =
          VideoSourceScrapeGlobalConfig();
      expect(empty.hashEnabled, isFalse);
      expect(empty.anidbUdpConfig.isAvailable, isFalse);
      const VideoSourceScrapeGlobalConfig configured =
          VideoSourceScrapeGlobalConfig(
            hashEnabled: true,
            anidbUsername: 'tester',
            anidbPassword: ' spaced password ',
            anidbClientName: 'fushitest',
            anidbClientVersion: 1,
          );
      expect(configured.anidbUdpConfig.isAvailable, isTrue);
      expect(configured.anidbUdpConfig.password, ' spaced password ');
    },
  );

  test('obsolete provider settings are no longer exposed', () {
    final Set<String> ids = allScrapeSettings()
        .map((SettingsItem candidate) => candidate.id)
        .toSet();
    for (final String obsolete in <String>{
      'video.library.metadata_fanart_api_key',
      'video.library.metadata_bangumi_token',
      'video.library.metadata_douban_endpoint',
      'video.library.metadata_douban_token',
      // metadata_primary_provider 曾在此列（主源写死那一版把设置项也撤了）。
      // 用户 2026-09-08 让它回来了，可选范围由上面那条测试钉住，不在这里。
    }) {
      expect(ids, isNot(contains(obsolete)));
    }
  });
}
