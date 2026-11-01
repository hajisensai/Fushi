import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/foundation/pref_store.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/video/web_video_sites.dart';
import 'package:fushi/src/web_browser/features/open_in_fushi/web_page_content.dart';
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

  test('「用 Fushi 播放本站视频」按 host 匹配（www. / 子域名同站），只在有播放器层的平台', () {
    final List<WebBrowserSite> sites = <WebBrowserSite>[
      WebBrowserSite(
        name: 'YouTube',
        url: Uri.parse('https://www.youtube.com/'),
        openInPlayer: true,
      ),
      WebBrowserSite(name: 'Example', url: example),
    ];
    bool auto(String url, {TargetPlatform p = TargetPlatform.windows}) =>
        webBrowserSiteAutoPlays(sites, Uri.parse(url), platform: p);
    expect(auto('https://www.youtube.com/watch?v=x'), isTrue);
    expect(auto('https://m.youtube.com/watch?v=x'), isTrue);
    expect(auto('https://youtube.com/watch?v=x'), isTrue);
    expect(auto('https://example.com/video'), isFalse, reason: '没标');
    expect(auto('https://notyoutube.com/'), isFalse);
    expect(
      auto('https://www.youtube.com/watch?v=x', p: TargetPlatform.android),
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

  test('浏览器播不了的观看页：只有 Netflix /watch/ 自动交给播放页', () {
    // 2026-10-27 用户：Netflix 在浏览器里黑屏、卡，要再点「用 Fushi 播放」。
    expect(
      webBrowserWatchPageNeedsPlayer(
        Uri.parse('https://www.netflix.com/watch/81915938?trackId=1'),
      ),
      isTrue,
    );
    expect(
      webBrowserWatchPageNeedsPlayer(Uri.parse('https://netflix.com/watch/1')),
      isTrue,
    );
    // 浏览 / 详情页（预告片）是在选集，不交。
    expect(webBrowserWatchPageNeedsPlayer(netflix), isFalse);
    expect(
      webBrowserWatchPageNeedsPlayer(
        Uri.parse('https://www.netflix.com/title/81915938'),
      ),
      isFalse,
    );
    // YouTube 在浏览器里播得了：照旧按钮交接，不自动跳。
    expect(
      webBrowserWatchPageNeedsPlayer(
        Uri.parse('https://www.youtube.com/watch?v=dQw4w9WgXcQ'),
      ),
      isFalse,
    );
    expect(
      webBrowserWatchPageNeedsPlayer(
        Uri.parse('https://evilnetflix.com/watch/1'),
      ),
      isFalse,
    );
    expect(webBrowserWatchPageNeedsPlayer(null), isFalse);
  });

  group('「用 Fushi 播放」扩到任意网页', () {
    Future<List<WebBrowserAction>> actionsFor(
      WidgetTester tester,
      String url, {
      bool player = true,
      bool incognito = false,
      WebPageContentKind? kind,
      bool autoPlay = false,
    }) async {
      late List<WebBrowserAction> out;
      final WebPageContentFeature content = WebPageContentFeature();
      final WebBrowserTab tab = WebBrowserTab(
        id: 't',
        url: Uri.parse(url),
        incognito: incognito,
      );
      content.debugSetKind(tab, kind);
      await tester.pumpWidget(
        Builder(
          builder: (BuildContext context) {
            out = PlayInFushiFeature(
              repository: () => throw StateError('not used'),
              youtubeTargetHeight: () => null,
              playerAvailable: () => player,
              pageContent: content,
              autoPlaySite: (Uri _) => autoPlay,
            ).actions(context, tab);
            return const SizedBox.shrink();
          },
        ),
      );
      content.dispose();
      return out;
    }

    testWidgets('有播放页：视频站观看页放工具栏，其它网页收进菜单', (WidgetTester tester) async {
      final List<WebBrowserAction> netflixActions = await actionsFor(
        tester,
        'https://www.netflix.com/watch/81234567',
      );
      expect(netflixActions.single.id, 'open_in_fushi.video');
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

    testWidgets('有观看页形状的站点的浏览 / 详情页不给（选集在浏览器里做）', (WidgetTester tester) async {
      expect(
        await actionsFor(tester, 'https://www.netflix.com/browse'),
        isEmpty,
      );
      expect(await actionsFor(tester, 'https://www.youtube.com/'), isEmpty);
    });

    testWidgets('页面里探到大视频 / 站点标了自动播放：其它网页也上工具栏', (WidgetTester tester) async {
      expect(
        (await actionsFor(
          tester,
          'https://example.com/ep1',
          kind: WebPageContentKind.video,
        )).single.placement,
        WebBrowserActionPlacement.toolbar,
      );
      expect(
        (await actionsFor(
          tester,
          'https://example.com/ep1',
          autoPlay: true,
        )).single.placement,
        WebBrowserActionPlacement.toolbar,
      );
      // 探成漫画 / 小说的页面：播放留在「⋯」里。
      expect(
        (await actionsFor(
          tester,
          'https://example.com/ep1',
          kind: WebPageContentKind.comic,
        )).single.placement,
        WebBrowserActionPlacement.menu,
      );
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
