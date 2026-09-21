import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/media/torrent/torrent_backend.dart';
import 'package:fushi_engine/media/torrent/video_resource_provider.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/download/video_resource_registry.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi/src/pages/implementations/video_discovery_acquisition_dialogs.dart';
import 'package:fushi/src/sync/interconnect_download_client.dart';

/// 资源搜索页的「下载到」下拉（设计 §3.3，手机让电脑下）：与订阅页的「运行位置」
/// 同一范式——有宣告代下载能力的已配对 host 时多出下拉；没有本地落地源时默认落到
/// host（且本地来源下拉不渲染）；「下载执行设备」偏好命中时默认选它；提交走
/// `onRemoteSubmit` 而不是本地 `onSubmit`。
class _OneCandidateProvider implements VideoResourceProvider {
  @override
  String get id => 'nyaa';

  @override
  Set<VideoDiscoveryCategory> get categories =>
      const <VideoDiscoveryCategory>{VideoDiscoveryCategory.anime};

  @override
  int get priority => 10;

  @override
  Future<ProviderBatchResult<VideoResourceCandidate>> search(
    VideoResourceSearchRequest request,
  ) async =>
      ProviderBatchResult<VideoResourceCandidate>.success(
        <VideoResourceCandidate>[
          _ResourceCandidate(
            providerId: 'nyaa',
            providerInstanceId: 'nyaa.si',
            remoteId: '1',
            title: '[Grp] Frieren - 01 [1080p]',
            infoHash: 'c12fe1c06bba254a9dc9f519b335aa7c1367a88a',
            magnetUri:
                'magnet:?xt=urn:btih:c12fe1c06bba254a9dc9f519b335aa7c1367a88a',
          ),
        ],
      );

  @override
  Future<TorrentAddPayload> resolve(VideoResourceCandidate candidate) async =>
      throw UnimplementedError();

  @override
  void close() {}
}

class _ResourceCandidate extends VideoResourceCandidate {
  _ResourceCandidate({
    required super.providerId,
    required super.providerInstanceId,
    required super.remoteId,
    required super.title,
    super.infoHash,
    super.magnetUri,
    super.providerPriority = 10,
  });
}

VideoMediaReference _reference() => VideoMediaReference(
      providerId: 'anilist',
      mediaId: '100',
      mediaKind: VideoMetadataMediaKind.tv,
      discoveryCategory: VideoDiscoveryCategory.anime,
      title: 'Frieren',
      year: 2026,
      anilistId: 100,
    );

const MediaSourceRow _source = MediaSourceRow(
  videoGroupingMode: 'series',
  id: 1,
  label: 'videos',
  mediaKind: 'video',
  transport: 'local',
  rootPath: r'D:\media',
  mediaCount: 0,
  recursive: true,
  sortOrder: 0,
  createdAt: 1,
);

const HostDownloadTarget _pc = HostDownloadTarget(
  baseUrl: 'http://192.168.1.2:47233',
  deviceName: 'PC',
  backend: 'embedded',
  kinds: <String>['video', 'novel', 'manga', 'audiobook', 'game'],
);

const ValueKey<String> _runLocation =
    ValueKey<String>('video-download-run-location');

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  Widget page({
    List<MediaSourceRow> sources = const <MediaSourceRow>[],
    String? defaultRemoteTargetUrl,
    required VideoDiscoveryDownloadSubmit onSubmit,
    required VideoDiscoveryRemoteDownloadSubmit onRemoteSubmit,
  }) =>
      TranslationProvider(
        child: MaterialApp(
          home: VideoDiscoveryResourceSearchPage(
            item: VideoDiscoveryItem(reference: _reference()),
            registry: VideoResourceRegistry(
              <VideoResourceProvider>[_OneCandidateProvider()],
            ),
            sources: sources,
            defaultSourceId: sources.isEmpty ? null : sources.first.id,
            onSubmit: onSubmit,
            remoteTargets: const <HostDownloadTarget>[_pc],
            defaultRemoteTargetUrl: defaultRemoteTargetUrl,
            onRemoteSubmit: onRemoteSubmit,
          ),
        ),
      );

  testWidgets('没有本地落地源：只剩 host 一档、本地来源下拉不渲染、提交走远端',
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final List<VideoDiscoveryRemoteDownloadSelection> remote =
        <VideoDiscoveryRemoteDownloadSelection>[];
    int local = 0;
    await tester.pumpWidget(page(
      onSubmit: (_) async => local++,
      onRemoteSubmit: (VideoDiscoveryRemoteDownloadSelection s) async =>
          remote.add(s),
    ));
    await tester.pumpAndSettle();

    expect(find.byKey(_runLocation), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('video-resource-source')),
        findsNothing,
        reason: '落点在 host，本地来源不参与');
    expect(find.text(t.download_target_remote(device: 'PC')), findsOneWidget);
    expect(find.text(t.download_target_local), findsNothing,
        reason: '没有本地来源就不该给一个提交不了的「本机」档');

    // 平铺视图里点候选 → 提交按钮亮 → 走远端。
    await tester
        .tap(find.byKey(const ValueKey<String>('video-resource-flat-toggle')));
    await tester.pumpAndSettle();
    // identityKey 对合法 infoHash 是 `torrent:<hash>`。
    await tester.tap(find.byKey(const ValueKey<String>(
        'video-resource-torrent:c12fe1c06bba254a9dc9f519b335aa7c1367a88a')));
    await tester.pumpAndSettle();
    await tester
        .tap(find.byKey(const ValueKey<String>('video-resource-submit')));
    await tester.pumpAndSettle();

    expect(local, 0);
    expect(remote, hasLength(1));
    expect(remote.single.target.baseUrl, _pc.baseUrl);
    expect(remote.single.resource.infoHash,
        'c12fe1c06bba254a9dc9f519b335aa7c1367a88a');
    expect(remote.single.media.mediaKind, VideoMetadataMediaKind.tv);
    expect(tester.takeException(), isNull);
  });

  testWidgets('有本地来源：默认本机；「下载执行设备」偏好命中时默认选 host', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(page(
      sources: const <MediaSourceRow>[_source],
      onSubmit: (_) async {},
      onRemoteSubmit: (_) async {},
    ));
    await tester.pumpAndSettle();
    expect(find.byKey(_runLocation), findsOneWidget);
    expect(find.text(t.download_target_local), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('video-resource-source')),
        findsOneWidget);

    // 同类型 widget 原位替换不会重跑 initState，先拆掉再装新的。
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(page(
      sources: const <MediaSourceRow>[_source],
      defaultRemoteTargetUrl: _pc.baseUrl,
      onSubmit: (_) async {},
      onRemoteSubmit: (_) async {},
    ));
    await tester.pumpAndSettle();
    expect(find.text(t.download_target_remote(device: 'PC')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('video-resource-source')),
        findsNothing,
        reason: '选了 host 后本地来源下拉收起（与订阅页同一行为）');
    expect(tester.takeException(), isNull);
  });
}
