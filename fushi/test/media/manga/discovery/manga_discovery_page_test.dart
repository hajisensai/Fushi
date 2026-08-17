import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/manga/discovery/manga_discovery_models.dart';
import 'package:fushi/src/media/manga/discovery/manga_discovery_page.dart';
import 'package:fushi/src/media/manga/discovery/manga_discovery_source_feeds.dart';

/// 发现页视图：注入假 provider，验证四条横滑行渲染、空 feed 整段不出现、
/// 失败态给重试按钮且重试真的重新拉取。
class _FakeProvider implements MangaDiscoveryProvider {
  _FakeProvider(this._results);

  final List<Object> _results;
  int calls = 0;

  @override
  Future<MangaDiscoverySnapshot> fetchSnapshot({int perPage = 20}) async {
    final Object result =
        _results[calls < _results.length ? calls : _results.length - 1];
    calls++;
    if (result is MangaDiscoverySnapshot) return result;
    throw result as Exception;
  }

  @override
  void close() {}
}

MangaDiscoveryEntry _entry(int id, String title, {double? score}) =>
    MangaDiscoveryEntry(
      anilistId: id,
      titleNative: title,
      averageScore: score,
    );

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.zhCn));

  Widget wrap(Widget child) => ProviderScope(
        child: TranslationProvider(
          child: MaterialApp(home: Scaffold(body: child)),
        ),
      );

  testWidgets('四条 feed 渲染成横滑行；空 feed 整段不出现', (WidgetTester tester) async {
    final _FakeProvider provider = _FakeProvider(<Object>[
      MangaDiscoverySnapshot(
        feeds: <MangaDiscoveryFeed, List<MangaDiscoveryEntry>>{
          MangaDiscoveryFeed.trending: <MangaDiscoveryEntry>[
            _entry(1, '趋势作品', score: 8.9),
          ],
          MangaDiscoveryFeed.popular: <MangaDiscoveryEntry>[
            _entry(2, '热门作品'),
          ],
          MangaDiscoveryFeed.topRated: const <MangaDiscoveryEntry>[],
          MangaDiscoveryFeed.latestFinished: const <MangaDiscoveryEntry>[],
        },
      ),
    ]);
    await tester.pumpWidget(wrap(MangaDiscoveryPage(
      provider: provider,
      sourceFeedsOverride: const <MangaDiscoverySourceFeed>[],
    )));
    await tester.pumpAndSettle();

    expect(find.text(t.manga_discovery_section_trending), findsOneWidget);
    expect(find.text(t.manga_discovery_section_popular), findsOneWidget);
    expect(find.text('趋势作品'), findsOneWidget);
    expect(find.text('热门作品'), findsOneWidget);
    expect(find.text('8.9'), findsOneWidget, reason: '评分随卡片展示');
    expect(
      find.text(t.manga_discovery_section_top_rated),
      findsNothing,
      reason: '空 feed 不渲染段标题（没有空壳段）',
    );
  });

  testWidgets('加载失败给重试按钮，重试真的重新拉取', (WidgetTester tester) async {
    final _FakeProvider provider = _FakeProvider(<Object>[
      Exception('network down'),
      MangaDiscoverySnapshot(
        feeds: <MangaDiscoveryFeed, List<MangaDiscoveryEntry>>{
          MangaDiscoveryFeed.trending: <MangaDiscoveryEntry>[
            _entry(1, '重试后出现'),
          ],
        },
      ),
    ]);
    await tester.pumpWidget(wrap(MangaDiscoveryPage(
      provider: provider,
      sourceFeedsOverride: const <MangaDiscoverySourceFeed>[],
    )));
    await tester.pumpAndSettle();

    expect(find.text(t.manga_discovery_load_failed), findsOneWidget);
    await tester
        .tap(find.byKey(const ValueKey<String>('manga_discovery_retry')));
    await tester.pumpAndSettle();
    expect(provider.calls, 2);
    expect(find.text('重试后出现'), findsOneWidget);
  });

  testWidgets('P2 来源热门行：有货的行渲染、可点开，失败的行整行收起', (WidgetTester tester) async {
    int opened = 0;
    // AniList 快照给空：源热门行顶到视口最上方，tap 不受上方行高影响。
    final _FakeProvider provider = _FakeProvider(<Object>[
      const MangaDiscoverySnapshot(
        feeds: <MangaDiscoveryFeed, List<MangaDiscoveryEntry>>{},
      ),
    ]);
    await tester.pumpWidget(wrap(MangaDiscoveryPage(
      provider: provider,
      sourceFeedsOverride: <MangaDiscoverySourceFeed>[
        MangaDiscoverySourceFeed(
          id: 'ok',
          name: '好源',
          language: 'ja',
          loadPopular: () async => <MangaDiscoverySourceItem>[
            MangaDiscoverySourceItem(
              title: '源里的热门作品',
              buildCover: (BuildContext context) =>
                  const ColoredBox(color: Color(0xFF808080)),
              open: (BuildContext context) => opened++,
            ),
          ],
        ),
        MangaDiscoverySourceFeed(
          id: 'broken',
          name: '坏源',
          language: 'ja',
          loadPopular: () async => throw StateError('Cloudflare'),
        ),
      ],
    )));
    await tester.pumpAndSettle();

    expect(
      find.text(t.manga_discovery_source_popular(source: '好源')),
      findsOneWidget,
    );
    expect(find.text('源里的热门作品'), findsOneWidget);
    expect(
      find.text(t.manga_discovery_source_popular(source: '坏源')),
      findsNothing,
      reason: '失败的来源行整行收起，不立错误牌坊',
    );

    await tester.tap(find.text('源里的热门作品'));
    await tester.pump();
    expect(opened, 1, reason: '点卡片走 feed 的 open 动作（生产适配为直进源详情页）');
  });
}
