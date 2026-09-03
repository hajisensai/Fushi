import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/manga/discovery/manga_discovery_detail_page.dart';
import 'package:fushi/src/media/manga/discovery/manga_discovery_models.dart';
import 'package:fushi/src/media/manga/discovery/manga_source_matcher.dart';

/// 发现条目详情页（注入假来源，绕开平台扩展宿主）：
///  - 打开即自动匹配，命中按来源展示（含分数）；
///  - 无命中给「未找到匹配」文案；
///  - 元数据（标题/评分/状态/题材/简介）照实渲染。
void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.zhCn));

  const MangaDiscoveryEntry entry = MangaDiscoveryEntry(
    anilistId: 1,
    titleNative: '葬送のフリーレン',
    titleRomaji: 'Sousou no Frieren',
    averageScore: 8.9,
    status: 'RELEASING',
    genres: <String>['Fantasy'],
    description: '魔王を倒した後の物語。',
  );

  Widget wrap(Widget child) => ProviderScope(
        child: TranslationProvider(
          child: MaterialApp(home: child),
        ),
      );

  testWidgets('打开即自动匹配，命中带来源名与分数展示', (WidgetTester tester) async {
    await tester.pumpWidget(
      wrap(
        MangaDiscoveryDetailPage(
          entry: entry,
          matchSourcesOverride: <MangaMatchSource>[
            MangaMatchSource(
              id: 'fake',
              name: '假来源',
              language: 'ja',
              search: (String query) async => <MangaMatchHit>[
                const MangaMatchHit(title: '葬送のフリーレン', payload: 'p'),
              ],
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('葬送のフリーレン'), findsWidgets);
    expect(find.text('8.9'), findsOneWidget);
    expect(find.text(t.manga_discovery_status_releasing), findsOneWidget);
    expect(find.text('Fantasy'), findsOneWidget);
    expect(find.text('魔王を倒した後の物語。'), findsOneWidget);
    expect(find.textContaining('假来源'), findsOneWidget);
    expect(find.textContaining('100%'), findsOneWidget, reason: '匹配分随命中展示');
  });

  testWidgets('无命中：给「未找到匹配」+ 全局搜索兜底入口', (WidgetTester tester) async {
    await tester.pumpWidget(
      wrap(
        MangaDiscoveryDetailPage(
          entry: entry,
          matchSourcesOverride: const <MangaMatchSource>[],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text(t.manga_discovery_match_none), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('manga_discovery_global_search')),
      findsOneWidget,
    );
  });

  // BUG-1871 复审：本页是全仓第二个（也是漏改的那个）推 [MangaGlobalSearchPage]
  // 的地方。不把「去导入」的去处透传下去，一个源都没有的用户在兜底搜索页里看到的
  // 仍然是「只有文案没有按钮」——与修前一模一样。
  //
  // 去处必须由**调用方**给：本页是 pushed route，挂在 Navigator 下面，
  // `MediaLibraryShellScope.maybeOf(context)` 在这里恒为 null。
  testWidgets('无命中 → 全源搜索页：把「去导入」的去处透传下去', (WidgetTester tester) async {
    int opened = 0;
    await tester.pumpWidget(
      wrap(
        MangaDiscoveryDetailPage(
          entry: entry,
          matchSourcesOverride: const <MangaMatchSource>[],
          onOpenSources: () => opened++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey<String>('manga_discovery_global_search')),
    );
    await tester.pumpAndSettle();

    final Finder button =
        find.byKey(const ValueKey<String>('manga_global_search_open_sources'));
    expect(button, findsOneWidget, reason: '兜底搜索页的空态必须也有「去导入」按钮');
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(opened, 1);
  });

  testWidgets('不在壳里（去处为 null）：兜底搜索页只给文案不给按钮',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      wrap(
        MangaDiscoveryDetailPage(
          entry: entry,
          matchSourcesOverride: const <MangaMatchSource>[],
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('manga_discovery_global_search')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('manga_global_search_open_sources')),
      findsNothing,
    );
  });
}
