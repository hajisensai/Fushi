import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/foundation/pref_store.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/video/web_video_sites.dart';
import 'package:fushi/src/web_browser/features/play_in_fushi/play_in_fushi_feature.dart';
import 'package:fushi/src/web_browser/features/web_browser_feature.dart';
import 'package:fushi/src/web_browser/tabs/web_browser_tab.dart';
import 'package:fushi/src/web_browser/web_browser_site_launch.dart';
import 'package:fushi/src/web_browser/web_browser_sites.dart';

class _MemoryPrefs implements PrefStore {
  final Map<String, dynamic> values = <String, dynamic>{};

  @override
  dynamic getPref(String key, {dynamic defaultValue}) =>
      values.containsKey(key) ? values[key] : defaultValue;

  @override
  Future<void> setPref(String key, dynamic value) async => values[key] = value;
}

/// 2026-10-26 用户：「这个站点和视频站点有什么关系？有必要分开吗？」——两份站点表
/// 合成一份，站点可标「用播放页打开」，浏览页上任意网页都能「用 Fushi 播放」（Windows）。
void main() {
  final Uri netflix = Uri.parse('https://www.netflix.com/browse');
  final Uri example = Uri.parse('https://example.com/');

  test('「用播放页打开」随站点表存取；老数据没有这个字段 = 用浏览器', () {
    final WebBrowserSite site = WebBrowserSite(
      name: 'Netflix',
      url: netflix,
      openInPlayer: true,
    );
    expect(
      parseWebBrowserSites(encodeWebBrowserSites(<WebBrowserSite>[site])),
      <WebBrowserSite>[site],
    );
    expect(
      parseWebBrowserSites(
        '[{"name":"Ex","url":"https://example.com/"}]',
      ).single.openInPlayer,
      isFalse,
    );
    expect(
      encodeWebBrowserSites(<WebBrowserSite>[
        WebBrowserSite(name: 'Ex', url: example),
      ]),
      isNot(contains('player')),
    );
  });

  test('只在有播放页的平台进播放页', () {
    final WebBrowserSite site = WebBrowserSite(
      name: 'Netflix',
      url: netflix,
      openInPlayer: true,
    );
    expect(
      webBrowserSiteOpensInPlayer(site, platform: TargetPlatform.windows),
      isTrue,
    );
    expect(
      webBrowserSiteOpensInPlayer(site, platform: TargetPlatform.android),
      isFalse,
    );
    expect(
      webBrowserSiteOpensInPlayer(
        site.copyWith(openInPlayer: false),
        platform: TargetPlatform.windows,
      ),
      isFalse,
    );
  });

  test('新加站点：Netflix 默认进播放页，其它站 / 没播放页的平台默认浏览器', () {
    expect(
      webBrowserSiteDefaultsToPlayer(netflix, playerAvailable: true),
      isTrue,
    );
    expect(
      webBrowserSiteDefaultsToPlayer(netflix, playerAvailable: false),
      isFalse,
    );
    expect(
      webBrowserSiteDefaultsToPlayer(example, playerAvailable: true),
      isFalse,
    );
  });

  test('旧「视频站点」自加站点并进站点表、标成播放页，只迁一次', () async {
    final _MemoryPrefs prefs = _MemoryPrefs()
      ..values[kWebVideoSitesPrefKey] = encodeWebVideoSites(<WebVideoSite>[
        const WebVideoSite(title: 'TVer', url: 'https://tver.jp/'),
        const WebVideoSite(title: 'Ex', url: 'https://example.com/'),
      ]);
    String stored = encodeWebBrowserSites(<WebBrowserSite>[
      WebBrowserSite(name: 'Mine', url: example),
    ]);
    Future<void> write(String json) async => stored = json;

    final List<WebBrowserSite> merged = await settleLegacyVideoSites(
      prefs,
      sitesJson: stored,
      writeSitesJson: write,
    );
    expect(
      merged.map((WebBrowserSite s) => (s.name, '${s.url}', s.openInPlayer)),
      <(String, String, bool)>[
        ('Mine', 'https://example.com/', true),
        ('TVer', 'https://tver.jp/', true),
      ],
    );
    expect(parseWebBrowserSites(stored), merged);
    expect(prefs.values[kWebVideoSitesPrefKey], '');

    final List<WebBrowserSite> again = await settleLegacyVideoSites(
      prefs,
      sitesJson: stored,
      writeSitesJson: (_) async => fail('迁过就不再写'),
    );
    expect(again, merged);
  });

  group('「用 Fushi 播放」扩到任意网页', () {
    Future<List<WebBrowserAction>> actionsFor(
      WidgetTester tester,
      String url, {
      bool player = true,
      bool incognito = false,
    }) async {
      late List<WebBrowserAction> out;
      await tester.pumpWidget(
        Builder(
          builder: (BuildContext context) {
            out =
                PlayInFushiFeature(
                  repository: () => throw StateError('not used'),
                  youtubeTargetHeight: () => null,
                  playerAvailable: () => player,
                ).actions(
                  context,
                  WebBrowserTab(
                    id: 't',
                    url: Uri.parse(url),
                    incognito: incognito,
                  ),
                );
            return const SizedBox.shrink();
          },
        ),
      );
      return out;
    }

    testWidgets('有播放页：视频站放工具栏，其它网页收进菜单', (WidgetTester tester) async {
      final List<WebBrowserAction> netflixActions = await actionsFor(
        tester,
        'https://www.netflix.com/browse',
      );
      expect(netflixActions.single.id, 'play_in_fushi');
      expect(
        netflixActions.single.placement,
        WebBrowserActionPlacement.toolbar,
      );
      final List<WebBrowserAction> other = await actionsFor(
        tester,
        'https://example.com/',
      );
      expect(other.single.placement, WebBrowserActionPlacement.menu);
    });

    testWidgets('没播放页 / 无痕 / 非 http(s)：不给', (WidgetTester tester) async {
      expect(
        await actionsFor(tester, 'https://www.netflix.com/', player: false),
        isEmpty,
      );
      expect(
        await actionsFor(tester, 'https://www.netflix.com/', incognito: true),
        isEmpty,
      );
      expect(await actionsFor(tester, 'about:blank'), isEmpty);
    });

    testWidgets('YouTube 观看页照旧（五端，无痕也给）', (WidgetTester tester) async {
      final List<WebBrowserAction> watch = await actionsFor(
        tester,
        'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
        player: false,
        incognito: true,
      );
      expect(watch.single.placement, WebBrowserActionPlacement.toolbar);
    });
  });
}
