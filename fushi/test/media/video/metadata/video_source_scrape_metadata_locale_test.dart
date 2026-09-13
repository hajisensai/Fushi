import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/source_library/source_library_row.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_resolver.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_config.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_coordinator.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_task.dart';
import 'package:fushi_core/fushi_core.dart';

/// v99 来源级资料语言（`video_source_scrape_settings.metadata_locale`）。
///
/// TMDB provider 的 `language` 是构造期参数，所以「这一趟用哪个 locale」的唯一
/// 可观察证据就是「用哪个 locale 建了这一趟的 registry」。测试注入假工厂来记它。
void main() {
  late FushiDatabase db;

  setUp(() {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  Future<SourceLibraryRow> seedSource({String? metadataLocale}) async {
    final int sourceId =
        await db.insertMediaSource(MediaSourcesCompanion.insert(
      label: 'Anime',
      mediaKind: 'video',
      rootPath: r'D:\anime',
      createdAt: 1,
    ));
    await db.upsertVideoSourceScrapeSettings(
      VideoSourceScrapeSettingsCompanion.insert(
        sourceId: Value<int>(sourceId),
        metadataLocale: Value<String?>(metadataLocale),
        updatedAt: 1,
      ),
    );
    return (await db.getMediaSourceById(sourceId))!;
  }

  /// 跑一趟空来源的刮削，返回 (工厂收到的 locale 序列, 那些 registry 是否都关了)。
  Future<(List<String>, List<_FakeRegistry>)> scrapeAndRecord({
    required String globalLocale,
    String? metadataLocale,
  }) async {
    final SourceLibraryRow source =
        await seedSource(metadataLocale: metadataLocale);
    final List<String> locales = <String>[];
    final List<_FakeRegistry> built = <_FakeRegistry>[];
    final VideoSourceScrapeCoordinator coordinator =
        VideoSourceScrapeCoordinator(
      database: db,
      config: VideoSourceScrapeGlobalConfig(locale: globalLocale),
      registry: VideoMetadataProviderRegistry(const <VideoMetadataProvider>[]),
      localeRegistryFactory: (String locale) {
        locales.add(locale);
        final _FakeRegistry registry = _FakeRegistry();
        built.add(registry);
        return registry;
      },
    );
    addTearDown(coordinator.close);
    await coordinator.scrapeSource(
      source,
      cancellationToken: VideoSourceScrapeCancellationToken(),
      onProgress: (VideoSourceScrapeProgress _) {},
    );
    return (locales, built);
  }

  test('来源级 locale 与全局不同 → 这一趟用来源 locale 另建 registry，跑完关掉', () async {
    final (List<String> locales, List<_FakeRegistry> built) =
        await scrapeAndRecord(globalLocale: 'zh-CN', metadataLocale: 'ja');
    expect(locales, <String>['ja']);
    expect(built.single.closed, isTrue,
        reason: '本方法自己建的 registry 必须自己关，否则每刮一次漏一套 HTTP client');
  });

  test('metadata_locale 为 NULL / 空白 → 跟随全局，不另建 registry', () async {
    for (final String? value in <String?>[null, '', '   ']) {
      final (List<String> locales, _) =
          await scrapeAndRecord(globalLocale: 'zh-CN', metadataLocale: value);
      expect(locales, isEmpty, reason: 'metadataLocale=$value 应当跟随全局');
    }
  });

  test('来源级 locale 与全局相同 → 复用全局 registry，不重复建', () async {
    final (List<String> locales, _) =
        await scrapeAndRecord(globalLocale: 'ja', metadataLocale: 'ja');
    expect(locales, isEmpty);
  });

  test('来源 locale 首尾空白被裁掉后再比较', () async {
    final (List<String> locales, _) =
        await scrapeAndRecord(globalLocale: 'zh-CN', metadataLocale: '  ja  ');
    expect(locales, <String>['ja'], reason: '裁剪后的值才是有效 locale');
  });
}

class _FakeRegistry implements VideoMetadataProviderRegistry {
  bool closed = false;

  @override
  Iterable<VideoMetadataProvider> get providers =>
      const <VideoMetadataProvider>[];

  @override
  void close() => closed = true;

  @override
  VideoMetadataProvider? provider(VideoMetadataProviderKind kind) => null;
}
