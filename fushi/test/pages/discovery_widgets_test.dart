import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/discovery/discovery_widgets.dart';
import 'package:fushi_engine/media/external_provider.dart';

import '../helpers/source_guard.dart';

/// 发现页共享交互件（`discovery/discovery_widgets.dart`）的契约：视频 / 漫画 /
/// 书与游戏资源站三张发现页都吃这一份，常量与判据漂了三页一起漂。
void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  ScrollMetrics metrics({
    required double pixels,
    required double max,
    Axis axis = Axis.vertical,
  }) {
    return FixedScrollMetrics(
      minScrollExtent: 0,
      maxScrollExtent: max,
      pixels: pixels,
      viewportDimension: 500,
      axisDirection: axis == Axis.vertical
          ? AxisDirection.down
          : AxisDirection.right,
      devicePixelRatio: 1,
    );
  }

  test('离底不足 600 才预取下一页', () {
    expect(kDiscoveryAutoLoadExtent, 600);
    expect(discoveryShouldLoadMore(metrics(pixels: 0, max: 600)), isFalse);
    expect(discoveryShouldLoadMore(metrics(pixels: 1, max: 600)), isTrue);
    expect(discoveryShouldLoadMore(metrics(pixels: 0, max: 0)), isTrue);
  });

  test('横滑行冒泡上来的滚动通知不触发翻页', () {
    expect(
      discoveryShouldLoadMore(
        metrics(pixels: 1000, max: 1000, axis: Axis.horizontal),
      ),
      isFalse,
    );
  });

  test('防抖 350ms：再次 schedule 重新计时，cancel 后不再触发', () {
    expect(kDiscoverySearchDebounce, const Duration(milliseconds: 350));
    fakeAsync((FakeAsync async) {
      final DiscoverySearchDebouncer debouncer = DiscoverySearchDebouncer();
      int fired = 0;
      debouncer.schedule(() => fired++);
      async.elapse(const Duration(milliseconds: 349));
      debouncer.schedule(() => fired++);
      async.elapse(const Duration(milliseconds: 349));
      expect(fired, 0);
      expect(debouncer.isPending, isTrue);
      async.elapse(const Duration(milliseconds: 1));
      expect(fired, 1);
      expect(debouncer.isPending, isFalse);

      debouncer.schedule(() => fired++);
      debouncer.cancel();
      async.elapse(const Duration(seconds: 1));
      expect(fired, 1);
      debouncer.dispose();
    });
  });

  test('失败按来源 + 操作 + 性质去重', () {
    const ExternalProviderFailure a = ExternalProviderFailure(
      providerId: 'nyaa',
      operation: 'search',
      kind: ExternalProviderFailureKind.timeout,
      message: 'provider request timed out',
    );
    const ExternalProviderFailure b = ExternalProviderFailure(
      providerId: 'nyaa',
      operation: 'search',
      kind: ExternalProviderFailureKind.rateLimited,
      message: 'provider returned HTTP 429',
    );
    expect(
      deduplicateDiscoveryFailures(<ExternalProviderFailure>[a, a, b]),
      <ExternalProviderFailure>[a, b],
    );
  });

  testWidgets('横幅按失败性质选文案，并印来源展示名', (WidgetTester tester) async {
    Future<void> pump(List<ExternalProviderFailure> failures) async {
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: DiscoveryProviderWarningBanner(
                failures: failures,
                displayNameFor: (String id) => id.toUpperCase(),
              ),
            ),
          ),
        ),
      );
    }

    await pump(const <ExternalProviderFailure>[
      ExternalProviderFailure(
        providerId: 'mal',
        operation: 'search',
        kind: ExternalProviderFailureKind.rateLimited,
        message: 'provider returned HTTP 429',
      ),
    ]);
    expect(find.text(t.video_discovery_provider_rate_limited), findsOneWidget);
    expect(find.text('MAL'), findsOneWidget);
    expect(find.text('mal'), findsNothing);

    await pump(const <ExternalProviderFailure>[
      ExternalProviderFailure(
        providerId: 'opds',
        operation: 'browse',
        kind: ExternalProviderFailureKind.unavailable,
        message: 'provider unavailable',
      ),
    ]);
    expect(find.text(t.video_discovery_provider_warning), findsOneWidget);

    await pump(const <ExternalProviderFailure>[
      ExternalProviderFailure(
        providerId: 'a',
        operation: 'search',
        kind: ExternalProviderFailureKind.unavailable,
        message: 'provider unavailable',
      ),
      ExternalProviderFailure(
        providerId: 'b',
        operation: 'search',
        kind: ExternalProviderFailureKind.timeout,
        message: 'provider request timed out',
      ),
    ]);
    expect(find.text(t.video_discovery_provider_failed), findsOneWidget);
    expect(find.text('A · B'), findsOneWidget);
  });

  // 三张发现页各自抄一份 350 / 600 / 横幅判据迟早漂开：守住它们都接的是共享件。
  group('三张发现页共用同一套交互件', () {
    String read(String path) => maskComments(File(path).readAsStringSync());
    const String video =
        'lib/src/pages/implementations/video_discovery_page.dart';
    const String media =
        'lib/src/pages/implementations/media_discovery_page.dart';
    const String manga =
        'lib/src/media/manga/discovery/manga_discovery_page.dart';

    test('失败横幅与滚到底翻页判据只有共享这一份', () {
      for (final String path in <String>[video, media, manga]) {
        final String source = read(path);
        expect(
          source,
          contains('DiscoveryProviderWarningBanner('),
          reason: path,
        );
        expect(source, contains('discoveryShouldLoadMore('), reason: path);
        expect(source, isNot(contains('extentAfter < 600')), reason: path);
      }
    });

    test('原地刷新结果的两页走共享防抖；漫画页只在提交时搜', () {
      for (final String path in <String>[video, media]) {
        expect(read(path), contains('DiscoverySearchDebouncer('), reason: path);
      }
      final String mangaSource = read(manga);
      expect(mangaSource, isNot(contains('DiscoverySearchDebouncer(')));
      expect(mangaSource, contains('MangaGlobalSearchPage('));
    });

    test('横滑行走共享 DiscoveryShelf', () {
      expect(read(video), contains('return DiscoveryShelf('));
      expect(read(manga), contains('return DiscoveryShelf('));
    });
  });
}
