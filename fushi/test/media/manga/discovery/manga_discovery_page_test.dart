import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/manga/discovery/manga_discovery_models.dart';
import 'package:fushi/src/media/manga/discovery/manga_discovery_page.dart';

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

  Widget wrap(Widget child) => TranslationProvider(
        child: MaterialApp(home: Scaffold(body: child)),
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
    await tester.pumpWidget(wrap(MangaDiscoveryPage(provider: provider)));
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
    await tester.pumpWidget(wrap(MangaDiscoveryPage(provider: provider)));
    await tester.pumpAndSettle();

    expect(find.text(t.manga_discovery_load_failed), findsOneWidget);
    await tester
        .tap(find.byKey(const ValueKey<String>('manga_discovery_retry')));
    await tester.pumpAndSettle();
    expect(provider.calls, 2);
    expect(find.text('重试后出现'), findsOneWidget);
  });
}
