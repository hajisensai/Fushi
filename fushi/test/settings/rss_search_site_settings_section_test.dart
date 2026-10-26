import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/rss_search_site_settings_section.dart';
import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/media/torrent/rss_search_site.dart';

/// 「RSS 搜索站」设置区：空态说明、增 / 改 / 删 / 启用开关、URL 模板实时校验、
/// 真搜自检。写入只看 store 收到了什么（生产 store 落偏好 + 重建运行时）。
class _FakeStore implements RssSearchSiteSettingsStore {
  _FakeStore({
    List<RssSearchSiteConfig> sites = const <RssSearchSiteConfig>[],
    this.torznab = false,
  }) : sites = List<RssSearchSiteConfig>.of(sites);

  List<RssSearchSiteConfig> sites;
  final bool torznab;
  final List<List<RssSearchSiteConfig>> writes = <List<RssSearchSiteConfig>>[];
  final List<(String, String)> tests = <(String, String)>[];
  Object? testOutcome = 3;

  @override
  List<RssSearchSiteConfig> loadSites() => sites;

  @override
  bool hasTorznabIndexers() => torznab;

  @override
  Future<void> saveSites(List<RssSearchSiteConfig> next) async {
    writes.add(List<RssSearchSiteConfig>.of(next));
    sites = List<RssSearchSiteConfig>.of(next);
  }

  @override
  Future<int> testSite(RssSearchSiteConfig site, String query) async {
    tests.add((site.id, query));
    final Object? outcome = testOutcome;
    if (outcome is ExternalProviderFailure) throw outcome;
    return outcome! as int;
  }
}

RssSearchSiteConfig _site({String id = 'a', bool enabled = true}) =>
    RssSearchSiteConfig(
      id: id,
      name: 'Site $id',
      urlTemplate: 'https://$id.example/rss?q={query}',
      enabled: enabled,
      domains: const <RssSearchDomain>[RssSearchDomain.anime],
    );

Widget _harness(_FakeStore store) => ProviderScope(
  child: TranslationProvider(
    child: MaterialApp(
      theme: ThemeData(useMaterial3: true),
      home: Scaffold(
        body: SingleChildScrollView(
          child: RssSearchSiteSettingsSection(store: store),
        ),
      ),
    ),
  ),
);

Finder _key(String key) => find.byKey(ValueKey<String>(key));

Future<void> _pump(WidgetTester tester, _FakeStore store) async {
  tester.view.physicalSize = const Size(900, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_harness(store));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  testWidgets('一个来源都没有：说明 RSS 站与 Torznab 两条路', (WidgetTester tester) async {
    await _pump(tester, _FakeStore());
    expect(_key('video-rss-empty'), findsOneWidget);
    expect(find.text(t.video_rss_empty_hint), findsOneWidget);
  });

  testWidgets('配了 Torznab 或已有 RSS 站时不再显示空态', (WidgetTester tester) async {
    await _pump(tester, _FakeStore(torznab: true));
    expect(_key('video-rss-empty'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await _pump(tester, _FakeStore(sites: <RssSearchSiteConfig>[_site()]));
    expect(_key('video-rss-empty'), findsNothing);
    expect(find.text('Site a'), findsOneWidget);
  });

  testWidgets('添加：URL 模板实时校验，填齐名称 / 模板 / 域才可保存', (WidgetTester tester) async {
    final _FakeStore store = _FakeStore();
    await _pump(tester, store);
    await tester.tap(_key('video-rss-add'));
    await tester.pumpAndSettle();

    // 通用示例占位，不出现任何真实站点。
    expect(find.text(kRssSearchUrlTemplateExample), findsOneWidget);
    Finder save() => _key('video-rss-dialog-save');
    bool saveEnabled() =>
        tester
            .widget<ButtonStyleButton>(
              find
                  .descendant(
                    of: save(),
                    matching: find.byWidgetPredicate(
                      (Widget w) => w is ButtonStyleButton,
                    ),
                  )
                  .first,
            )
            .onPressed !=
        null;
    expect(saveEnabled(), isFalse);

    await tester.enterText(_key('video-rss-dialog-name'), 'My site');
    await tester.enterText(
      _key('video-rss-dialog-url'),
      'https://site.example/rss',
    );
    await tester.pumpAndSettle();
    expect(find.text(t.video_rss_url_missing_query), findsOneWidget);

    await tester.enterText(
      _key('video-rss-dialog-url'),
      'http://site.example/rss?q={query}',
    );
    await tester.pumpAndSettle();
    expect(find.text(t.video_rss_url_needs_http_optin), findsOneWidget);
    await tester.tap(_key('video-rss-dialog-insecure-http'));
    await tester.pumpAndSettle();
    expect(find.text(t.video_rss_url_needs_http_optin), findsNothing);

    // 还没选媒体域：提示至少选一项，不能保存。
    expect(find.text(t.video_rss_domains_required), findsOneWidget);
    expect(saveEnabled(), isFalse);
    await tester.tap(_key('video-rss-dialog-domain-anime'));
    await tester.tap(_key('video-rss-dialog-domain-novel'));
    await tester.pumpAndSettle();
    expect(saveEnabled(), isTrue);

    await tester.tap(save());
    await tester.pumpAndSettle();
    final RssSearchSiteConfig saved = store.writes.single.single;
    expect(saved.name, 'My site');
    expect(saved.urlTemplate, 'http://site.example/rss?q={query}');
    expect(saved.allowInsecureHttp, isTrue);
    expect(saved.domains, <RssSearchDomain>{
      RssSearchDomain.anime,
      RssSearchDomain.novel,
    });
    expect(find.text('My site'), findsOneWidget);
    expect(_key('video-rss-empty'), findsNothing);
  });

  testWidgets('编辑、停用、删除都写穿 store', (WidgetTester tester) async {
    final _FakeStore store = _FakeStore(
      sites: <RssSearchSiteConfig>[
        _site(id: 'a'),
        _site(id: 'b'),
      ],
    );
    await _pump(tester, store);

    await tester.tap(_key('video-rss-0-edit'));
    await tester.pumpAndSettle();
    await tester.enterText(_key('video-rss-dialog-name'), 'Renamed');
    await tester.pumpAndSettle();
    await tester.tap(_key('video-rss-dialog-save'));
    await tester.pumpAndSettle();
    expect(store.writes.last.first.id, 'a');
    expect(store.writes.last.first.name, 'Renamed');
    expect(find.text('Renamed'), findsOneWidget);

    await tester.tap(_key('video-rss-1-enabled'));
    await tester.pumpAndSettle();
    expect(store.writes.last[1].enabled, isFalse);

    await tester.tap(_key('video-rss-0-remove'));
    await tester.pumpAndSettle();
    expect(store.writes.last.map((RssSearchSiteConfig s) => s.id), <String>[
      'b',
    ]);
    expect(find.text('Renamed'), findsNothing);
  });

  testWidgets('测试按钮：用填的关键词真搜一次，报条数或失败原因', (WidgetTester tester) async {
    final _FakeStore store = _FakeStore(sites: <RssSearchSiteConfig>[_site()]);
    await _pump(tester, store);

    await tester.tap(_key('video-rss-0-test'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText).last, 'frieren');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(store.tests.single, ('a', 'frieren'));
    expect(find.text(t.video_rss_test_result(n: 3)), findsOneWidget);

    store.testOutcome = const ExternalProviderFailure(
      providerId: 'rss:a',
      operation: 'search',
      kind: ExternalProviderFailureKind.timeout,
      message: 'timed out',
    );
    await tester.tap(_key('video-rss-0-test'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText).last, 'frieren');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(
      find.text(
        t.video_rss_test_failed(reason: t.video_resource_failure_timeout),
      ),
      findsOneWidget,
    );
  });

  test('模板错误文案：判据与引擎同一份', () {
    expect(
      rssSearchUrlTemplateError(
        'https://x.example/rss?q={query}',
        allowInsecureHttp: false,
      ),
      isNull,
    );
    expect(
      rssSearchUrlTemplateError('', allowInsecureHttp: false),
      t.video_rss_url_required,
    );
    expect(
      rssSearchUrlTemplateError(
        'https://user:pw@x.example/rss?q={query}',
        allowInsecureHttp: false,
      ),
      t.video_rss_url_invalid,
    );
  });
}
