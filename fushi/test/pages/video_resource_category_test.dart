import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/external_provider.dart';
import 'package:fushi/src/media/torrent/torrent_backend.dart';
import 'package:fushi/src/media/torrent/video_resource_provider.dart';
import 'package:fushi/src/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi/src/media/video/download/video_resource_registry.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_models.dart';
import 'package:fushi/src/pages/implementations/video_discovery_acquisition_dialogs.dart';
import 'package:fushi_core/fushi_core.dart';

class _Provider implements VideoResourceProvider {
  final List<VideoResourceSearchRequest> requests =
      <VideoResourceSearchRequest>[];
  Completer<ProviderBatchResult<VideoResourceCandidate>>? first;

  @override
  String get id => 'test';
  @override
  int get priority => 1;
  @override
  Set<VideoDiscoveryCategory> get categories => <VideoDiscoveryCategory>{};
  @override
  Future<ProviderBatchResult<VideoResourceCandidate>> search(
    VideoResourceSearchRequest request,
  ) async {
    requests.add(request);
    if (requests.length == 1 && first != null) return first!.future;
    return ProviderBatchResult<VideoResourceCandidate>.success(
      <VideoResourceCandidate>[_Candidate()],
    );
  }

  @override
  Future<TorrentAddPayload> resolve(VideoResourceCandidate candidate) async =>
      throw UnimplementedError();
  @override
  void close() {}
}

class _Candidate extends VideoResourceCandidate {
  _Candidate()
      : super(
          providerId: 'test',
          providerInstanceId: 'test',
          remoteId: '1',
          title: '[Group] Oniichan wa Oshimai - 01 [1080p]',
          providerPriority: 1,
        );
}

VideoMediaReference _media() => VideoMediaReference(
      providerId: 'tmdb',
      mediaId: '123',
      mediaKind: VideoMetadataMediaKind.tv,
      discoveryCategory: VideoDiscoveryCategory.tv,
      title: 'お兄ちゃんはおしまい!',
      originalTitle: 'お兄ちゃんはおしまい!',
      aliases: <String>['Oniichan wa Oshimai'],
      tmdbId: 123,
      imdbId: 'tt123',
      year: 2023,
      season: 1,
      externalIds: <String, String>{'tmdb': '123'},
    );

Future<void> _switchCategory(WidgetTester tester, String label) async {
  await tester
      .tap(find.byKey(const ValueKey<String>('video-resource-category')));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.zhCn));

  for (final bool subscription in <bool>[false, true]) {
    testWidgets('类型切换用于${subscription ? '订阅' : '下载'}搜索并保留身份',
        (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 850));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final _Provider provider = _Provider();
      final VideoMediaReference original = _media();
      VideoDiscoveryDownloadSelection? submitted;
      await tester.pumpWidget(TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: VideoResourceSearchSurface(
              pageMode: true,
              initialItem: VideoDiscoveryItem(reference: original),
              registry:
                  VideoResourceRegistry(<VideoResourceProvider>[provider]),
              sources: const <MediaSourceRow>[
                MediaSourceRow(
                  videoGroupingMode: 'series',
                  id: 1,
                  label: 'Videos',
                  mediaKind: 'video',
                  transport: 'local',
                  rootPath: 'D:/videos',
                  mediaCount: 0,
                  recursive: true,
                  sortOrder: 0,
                  createdAt: 1,
                ),
              ],
              onSubmit: subscription
                  ? null
                  : (selection) async {
                      submitted = selection;
                    },
              onSubscriptionSubmit: subscription ? (selection) async {} : null,
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(provider.requests.single.media!.discoveryCategory,
          VideoDiscoveryCategory.tv);
      await _switchCategory(tester, t.media_tracking_anime);
      final VideoMediaReference requested = provider.requests.last.media!;
      expect(requested.discoveryCategory, VideoDiscoveryCategory.anime);
      expect(requested.identityKeys, original.identityKeys);
      expect(requested.mediaKind, VideoMetadataMediaKind.tv);
      expect(requested.originalTitle, original.originalTitle);
      expect(requested.aliases, original.aliases);
      expect(requested.externalIds, original.externalIds);
      expect(requested.year, 2023);
      expect(requested.season, 1);
      if (!subscription) {
        await tester.tap(
            find.byKey(const ValueKey<String>('video-resource-flat-toggle')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('[Group] Oniichan wa Oshimai - 01 [1080p]'));
        await tester.pumpAndSettle();
        await tester
            .tap(find.byKey(const ValueKey<String>('video-resource-submit')));
        await tester.pumpAndSettle();
        expect(submitted, isNotNull);
        expect(
            submitted!.media.discoveryCategory, VideoDiscoveryCategory.anime);
        expect(submitted!.media.identityKeys, original.identityKeys);
      }
      await _switchCategory(tester, t.collection_relation_movie);
      expect(provider.requests.last.media!.discoveryCategory,
          VideoDiscoveryCategory.movie);
      expect(
          provider.requests.last.media!.mediaKind, VideoMetadataMediaKind.tv);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('切换类型使旧请求失效，慢返回不能覆盖当前结果', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 850));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final _Provider provider = _Provider()
      ..first = Completer<ProviderBatchResult<VideoResourceCandidate>>();
    await tester.pumpWidget(TranslationProvider(
      child: MaterialApp(
        home: Scaffold(
          body: VideoResourceSearchSurface(
            initialItem: VideoDiscoveryItem(reference: _media()),
            registry: VideoResourceRegistry(<VideoResourceProvider>[provider]),
            sources: const <MediaSourceRow>[],
            onSubmit: (_) async {},
          ),
        ),
      ),
    ));
    await tester.pump();
    // 在旧请求仍加载时操作真实下拉；不能 pumpAndSettle 等待无限进度动画。
    await tester
        .tap(find.byKey(const ValueKey<String>('video-resource-category')));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text(t.media_tracking_anime).last);
    await tester.pumpAndSettle();
    expect(provider.requests.length, 2);
    expect(find.byKey(const ValueKey<String>('video-resource-flat-toggle')),
        findsOneWidget);
    provider.first!
        .complete(ProviderBatchResult<VideoResourceCandidate>.success(
      const <VideoResourceCandidate>[],
    ));
    await tester.pumpAndSettle();
    expect(find.text(t.video_discovery_empty), findsNothing);
    expect(find.byKey(const ValueKey<String>('video-resource-flat-toggle')),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
