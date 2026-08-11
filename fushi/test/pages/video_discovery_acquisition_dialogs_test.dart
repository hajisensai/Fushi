import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/media/torrent/video_resource_provider.dart';
import 'package:fushi/src/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi/src/media/video/download/video_resource_registry.dart';
import 'package:fushi/src/media/video/download/video_subtitle_registry.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_models.dart';
import 'package:fushi/src/media/video/subtitle/video_subtitle_provider.dart';
import 'package:fushi/src/pages/implementations/video_discovery_acquisition_dialogs.dart';

class _ResourceCandidate extends VideoResourceCandidate {
  _ResourceCandidate({
    required super.providerId,
    required super.providerInstanceId,
    required super.remoteId,
    required super.title,
    super.providerPriority = 10,
    super.resolution,
    super.releaseGroup,
    super.trusted,
  });
}

VideoMediaReference _reference() => VideoMediaReference(
      providerId: 'anilist',
      mediaId: '100',
      mediaKind: VideoMetadataMediaKind.tv,
      discoveryCategory: VideoDiscoveryCategory.anime,
      title: '测试动画',
      originalTitle: 'テストアニメ',
      aliases: const <String>['Test Anime'],
      year: 2026,
      anilistId: 100,
    );

VideoDownloadJobRow _job({
  String lifecycle = VideoDownloadJobLifecycle.active,
  String stage = VideoDownloadJobStage.subtitle,
  String provider = 'anilist',
  String externalId = '100',
}) =>
    VideoDownloadJobRow(
      jobId: 'job-1',
      resourceProvider: 'nyaa:default',
      selectedResourceId: 'release-1',
      magnetUri: null,
      resourceTitle: '[Group] 测试动画 - 03 [1080p]',
      torrentHash: null,
      metadataProvider: provider,
      externalId: externalId,
      mediaKind: 'tv',
      discoveryCategory: 'anime',
      title: '测试动画',
      year: 2026,
      season: 1,
      coverUrl: null,
      backendKind: 'embedded',
      backendTaskId: null,
      backendProfileId: null,
      fingerprint: 'embedded-test',
      category: 'fushi-video',
      targetSourceId: null,
      collectionId: null,
      organizationPolicy: 'library',
      subtitlePolicy: 'bestEffort',
      observedSavePath: null,
      targetRelativeRoot: null,
      lifecycle: lifecycle,
      stage: stage,
      stageProgress: 0.5,
      priority: 0,
      attemptCount: 0,
      maxAttempts: 3,
      nextAttemptAt: null,
      claimedBy: null,
      claimExpiresAt: null,
      lastError: null,
      createdAt: 1,
      updatedAt: 1,
      completedAt: null,
    );

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.zhCn));

  test('严格订阅规则锁定所选 release 且只锁定有证据的语言', () {
    final StrictVideoSubscriptionFilter? nyaa =
        deriveStrictVideoSubscriptionFilter(
      _ResourceCandidate(
        providerId: 'nyaa',
        providerInstanceId: 'nyaa',
        remoteId: '1',
        title: '[Group] Show - 03 [1080p]',
        releaseGroup: 'Group',
        resolution: '1080p',
        trusted: true,
      ),
    );

    expect(nyaa, isNotNull);
    expect(nyaa!.json, contains('"strict":true'));
    expect(nyaa.json, contains('"releaseGroup":"Group"'));
    expect(nyaa.json, contains('"resolution":"1080p"'));
    expect(nyaa.json, contains('"trusted":true'));
    expect(episodeNumberFromReleaseTitle('[Group] Show - 03 [1080p]'), 3);
    expect(
      deriveStrictVideoSubscriptionFilter(
        _ResourceCandidate(
          providerId: 'nyaa',
          providerInstanceId: 'nyaa',
          remoteId: '2',
          title: 'unknown release',
        ),
      ),
      isNull,
    );

    final StrictVideoSubscriptionFilter? torznab =
        deriveStrictVideoSubscriptionFilter(
      _ResourceCandidate(
        providerId: 'torznab',
        providerInstanceId: 'indexer',
        remoteId: '3',
        title: 'Show.S01E03.1080p.WEB-DL.Dual.Audio.HEVC-Group',
        releaseGroup: 'Group',
        resolution: '1080p',
      ),
    );
    expect(torznab, isNotNull);
    expect(torznab!.json, contains('"language":"Dual.Audio"'));

    final StrictVideoSubscriptionFilter? noLanguage =
        deriveStrictVideoSubscriptionFilter(
      _ResourceCandidate(
        providerId: 'torznab',
        providerInstanceId: 'indexer',
        remoteId: '4',
        title: 'Show.S01E03.1080p.WEB-DL.HEVC-Group',
        releaseGroup: 'Group',
        resolution: '1080p',
      ),
    );
    expect(noLanguage!.json, isNot(contains('language')));
  });

  test('下载资源自由搜索必须提供可精确刮削的 provider ID 与年份', () {
    expect(
      buildManualVideoMediaReference(
        providerId: 'manual',
        mediaId: '100',
        title: '测试动画',
        yearText: '2026',
        category: VideoDiscoveryCategory.anime,
        mediaKind: VideoMetadataMediaKind.tv,
      ),
      isNull,
    );
    expect(
      buildManualVideoMediaReference(
        providerId: 'anilist',
        mediaId: '',
        title: '测试动画',
        yearText: '2026',
        category: VideoDiscoveryCategory.anime,
        mediaKind: VideoMetadataMediaKind.tv,
      ),
      isNull,
    );
    final VideoMediaReference reference = buildManualVideoMediaReference(
      providerId: 'anilist',
      mediaId: '100',
      title: '测试动画',
      yearText: '2026',
      category: VideoDiscoveryCategory.anime,
      mediaKind: VideoMetadataMediaKind.tv,
    )!;
    expect(reference.providerId, 'anilist');
    expect(reference.mediaId, '100');
    expect(reference.anilistId, 100);
    expect(reference.year, 2026);
    expect(reference.mediaKind, VideoMetadataMediaKind.tv);

    final VideoMediaReference animeMovie = buildManualVideoMediaReference(
      providerId: 'anilist',
      mediaId: '200',
      title: '动画电影',
      yearText: '2026',
      category: VideoDiscoveryCategory.anime,
      mediaKind: VideoMetadataMediaKind.movie,
    )!;
    expect(animeMovie.discoveryCategory, VideoDiscoveryCategory.anime);
    expect(animeMovie.mediaKind, VideoMetadataMediaKind.movie);
  });

  test('活动任务字幕只接受强身份一致且未越过 subtitle 的任务', () {
    expect(isAttachableVideoDownloadJob(_job(), _reference()), isTrue);
    expect(
      isAttachableVideoDownloadJob(
        _job(lifecycle: VideoDownloadJobLifecycle.needsAttention),
        _reference(),
      ),
      isTrue,
    );
    expect(
      isAttachableVideoDownloadJob(
        _job(stage: VideoDownloadJobStage.import),
        _reference(),
      ),
      isFalse,
    );
    expect(
      isAttachableVideoDownloadJob(
        _job(lifecycle: VideoDownloadJobLifecycle.failed),
        _reference(),
      ),
      isFalse,
    );
    expect(
      isAttachableVideoDownloadJob(
        _job(externalId: 'different'),
        _reference(),
      ),
      isFalse,
    );
  });

  test('字幕安装遇到不同内容不覆盖并对相同内容保持幂等', () async {
    final Directory root =
        await Directory.systemTemp.createTemp('subtitle-safe');
    addTearDown(() => root.delete(recursive: true));
    final VideoSubtitleDownload first = VideoSubtitleDownload(
      bytes: Uint8List.fromList(<int>[1, 2, 3]),
      fileName: 'same.srt',
      language: 'zh',
    );
    final VideoSubtitleDownload second = VideoSubtitleDownload(
      bytes: Uint8List.fromList(<int>[4, 5, 6]),
      fileName: 'same.srt',
      language: 'zh',
    );

    final String firstPath = await installDiscoverySubtitle(
      download: first,
      target: SubtitleInstallTarget.directory,
      selectedPath: root.path,
    );
    final String samePath = await installDiscoverySubtitle(
      download: first,
      target: SubtitleInstallTarget.directory,
      selectedPath: root.path,
    );
    final String secondPath = await installDiscoverySubtitle(
      download: second,
      target: SubtitleInstallTarget.directory,
      selectedPath: root.path,
    );

    expect(samePath, firstPath);
    expect(firstPath, isNot(secondPath));
    expect(await File(firstPath).readAsBytes(), <int>[1, 2, 3]);
    expect(await File(secondPath).readAsBytes(), <int>[4, 5, 6]);
  });

  testWidgets('BUG-1482 资源对话框双下拉框在窄宽度不横向溢出', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(700, 760));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: VideoDiscoveryResourceSearchDialog(
              item: VideoDiscoveryItem(reference: _reference()),
              registry: VideoResourceRegistry(const <VideoResourceProvider>[]),
              sources: const <MediaSourceRow>[
                MediaSourceRow(
                  id: 1,
                  label: 'himoto',
                  mediaKind: 'video',
                  transport: 'local',
                  rootPath: r'D:\\media',
                  mediaCount: 0,
                  recursive: true,
                  sortOrder: 0,
                  createdAt: 1,
                ),
              ],
              defaultSourceId: 1,
              onSubmit: (VideoDiscoveryDownloadSelection selection) async {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey<String>('video-resource-source')),
        findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('video-resource-subtitle-policy')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('资源搜索使用独立页并默认展示罗马字和日文查询', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 760));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: VideoDiscoveryResourceSearchPage(
            item: VideoDiscoveryItem(reference: _reference()),
            registry: VideoResourceRegistry(const <VideoResourceProvider>[]),
            sources: const <MediaSourceRow>[
              MediaSourceRow(
                id: 1,
                label: 'himoto',
                mediaKind: 'video',
                transport: 'local',
                rootPath: r'D:\\media',
                mediaCount: 0,
                recursive: true,
                sortOrder: 0,
                createdAt: 1,
              ),
            ],
            onSubmit: (VideoDiscoveryDownloadSelection selection) async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final TextField query = tester.widget<TextField>(
      find.byKey(const ValueKey<String>('video-resource-query')),
    );
    expect(query.controller!.text, 'Test Anime');
    expect(find.widgetWithText(ActionChip, 'Test Anime'), findsOneWidget);
    expect(find.widgetWithText(ActionChip, 'テストアニメ'), findsOneWidget);
    expect(find.byType(Scaffold), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('订阅使用与资源搜索相同的独立全屏页面', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 760));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: VideoDiscoverySubscriptionPage(
            item: VideoDiscoveryItem(reference: _reference()),
            registry: VideoResourceRegistry(
              const <VideoResourceProvider>[],
            ),
            sources: const <MediaSourceRow>[
              MediaSourceRow(
                id: 1,
                label: 'himoto',
                mediaKind: 'video',
                transport: 'local',
                rootPath: r'D:\\media',
                mediaCount: 0,
                recursive: true,
                sortOrder: 0,
                createdAt: 1,
              ),
            ],
            onSubmit: (VideoDiscoverySubscriptionSelection selection) async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(Scaffold), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.text(t.video_discovery_subscribe),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('video-resource-query')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('video-subscription-submit')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('字幕搜索使用独立页而不是居中对话框', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 760));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: VideoDiscoverySubtitleSearchPage(
            item: VideoDiscoveryItem(reference: _reference()),
            registry: VideoSubtitleRegistry(const <VideoSubtitleProvider>[]),
            pickVideo: (BuildContext context) async => null,
            pickDirectory: (BuildContext context) async => null,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(Scaffold), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('video-subtitle-target')),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
