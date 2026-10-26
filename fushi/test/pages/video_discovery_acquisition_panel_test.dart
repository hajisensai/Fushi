import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/video/discovery/video_work_acquisition_controller.dart';
import 'package:fushi/src/pages/implementations/video_discovery_detail_page.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:material_ui/material_ui.dart';

VideoDiscoveryItem _item() => VideoDiscoveryItem(
  reference: VideoMediaReference(
    providerId: 'tmdb',
    mediaId: '100',
    mediaKind: VideoMetadataMediaKind.tv,
    discoveryCategory: VideoDiscoveryCategory.tv,
    title: '星环纪元',
    originalTitle: 'Star Ring',
    year: 2026,
  ),
  overview: '简介。',
);

/// 假渠道：每次 lookup 交出一个测试控制完成时机的 Completer。
class _FakeBackend implements VideoAcquisitionChannelBackend {
  _FakeBackend(this.channel);

  @override
  final VideoAcquisitionChannel channel;

  final List<Completer<VideoAcquisitionLookup>> calls =
      <Completer<VideoAcquisitionLookup>>[];

  @override
  Future<VideoAcquisitionLookup> lookup(VideoMediaReference reference) {
    final Completer<VideoAcquisitionLookup> completer =
        Completer<VideoAcquisitionLookup>();
    calls.add(completer);
    return completer.future;
  }
}

Widget _harness(VideoDiscoveryDetailPage page) => TranslationProvider(
  child: MaterialApp(theme: ThemeData.dark(useMaterial3: true), home: page),
);

void _tallView(WidgetTester tester) {
  tester.view.physicalSize = const Size(1280, 2600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// 骨架闪光与转圈是无限动画，pumpAndSettle 不会停：按固定时长推帧。
Future<void> _settle(WidgetTester tester) =>
    tester.pump(const Duration(milliseconds: 900));

Finder _key(String value) => find.byKey(ValueKey<String>(value));

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.zhCn));

  testWidgets('四组各自独立呈现 加载中 / 有结果 / 未配置 / 失败（可重试） / 无结果', (
    WidgetTester tester,
  ) async {
    _tallView(tester);
    final Map<VideoAcquisitionChannel, _FakeBackend> backends =
        <VideoAcquisitionChannel, _FakeBackend>{
          for (final VideoAcquisitionChannel channel
              in VideoAcquisitionChannel.values)
            channel: _FakeBackend(channel),
        };
    int builds = 0;
    bool searchedResource = false;
    int libraryOpened = 0;
    int configureOpened = 0;
    final VideoDiscoveryActions actions = VideoDiscoveryActions(
      onSearchResource: (_, __) async => searchedResource = true,
      acquisitionChannels: (VideoDiscoveryItem item) {
        builds++;
        return backends.values.toList();
      },
    );

    await tester.pumpWidget(
      _harness(VideoDiscoveryDetailPage(item: _item(), actions: actions)),
    );
    await _settle(tester);

    expect(builds, 1);
    expect(_key('video-acquisition-section'), findsOneWidget);
    // 四组同时发起，全在加载中。
    for (final VideoAcquisitionChannel channel
        in VideoAcquisitionChannel.values) {
      expect(backends[channel]!.calls, hasLength(1));
      expect(_key('video-acquisition-${channel.name}-loading'), findsOneWidget);
    }
    expect(find.text(t.video_acquisition_channel_library), findsOneWidget);
    expect(
      find.text(t.video_acquisition_channel_online_source),
      findsOneWidget,
    );
    expect(find.text(t.video_acquisition_channel_torrent), findsOneWidget);
    expect(find.text(t.video_acquisition_channel_media_server), findsOneWidget);

    // 媒体库：有结果；在线源：失败；BT：未配置；媒体服务器：仍在加载。
    backends[VideoAcquisitionChannel.library]!.calls.single.complete(
      VideoAcquisitionLookup.hits(<VideoAcquisitionHit>[
        VideoAcquisitionHit(
          id: 'book-1',
          title: '星环纪元（本地）',
          open: (BuildContext context) async => libraryOpened++,
        ),
      ]),
    );
    backends[VideoAcquisitionChannel.onlineSource]!.calls.single.completeError(
      StateError('runtime down'),
    );
    backends[VideoAcquisitionChannel.torrent]!.calls.single.complete(
      VideoAcquisitionLookup.unconfigured(
        configure: (BuildContext context) async => configureOpened++,
      ),
    );
    await _settle(tester);

    expect(_key('video-acquisition-library-hit-book-1'), findsOneWidget);
    expect(_key('video-acquisition-onlineSource-failed'), findsOneWidget);
    expect(_key('video-acquisition-torrent-unconfigured'), findsOneWidget);
    expect(find.text(t.video_acquisition_torrent_unconfigured), findsOneWidget);
    expect(find.text(t.video_acquisition_torrent_add_site), findsOneWidget);
    expect(_key('video-acquisition-mediaServer-loading'), findsOneWidget);

    // 命中可直接打开。
    await tester.ensureVisible(_key('video-acquisition-library-hit-book-1'));
    await tester.tap(_key('video-acquisition-library-hit-book-1'));
    await _settle(tester);
    expect(libraryOpened, 1);

    // 未配置给引导动作。
    await tester.ensureVisible(_key('video-acquisition-torrent-configure'));
    await tester.tap(_key('video-acquisition-torrent-configure'));
    await _settle(tester);
    expect(configureOpened, 1);

    // 失败可重试：重试只重查这一组。
    await tester.ensureVisible(_key('video-acquisition-onlineSource-retry'));
    await tester.tap(_key('video-acquisition-onlineSource-retry'));
    await _settle(tester);
    final _FakeBackend online = backends[VideoAcquisitionChannel.onlineSource]!;
    expect(online.calls, hasLength(2));
    expect(backends[VideoAcquisitionChannel.library]!.calls, hasLength(1));
    expect(_key('video-acquisition-onlineSource-loading'), findsOneWidget);
    online.calls.last.complete(
      const VideoAcquisitionLookup.hits(<VideoAcquisitionHit>[
        VideoAcquisitionHit(id: 'src-1', title: 'Star Ring', subtitle: 'Src'),
      ], failedSourceCount: 2),
    );
    await _settle(tester);
    expect(_key('video-acquisition-onlineSource-hit-src-1'), findsOneWidget);
    expect(
      _key('video-acquisition-onlineSource-partial-failure'),
      findsOneWidget,
    );

    // 媒体服务器最后才回来：无结果。
    backends[VideoAcquisitionChannel.mediaServer]!.calls.single.complete(
      const VideoAcquisitionLookup.hits(<VideoAcquisitionHit>[]),
    );
    await _settle(tester);
    expect(_key('video-acquisition-mediaServer-empty'), findsOneWidget);
    expect(find.text(t.video_acquisition_results_empty), findsOneWidget);

    // hero 的「搜索资源」接了面板后改为跳到面板，不再直进 BT 搜索。
    final Finder resource = _key('video-discovery-search-resource');
    expect(
      find.descendant(
        of: resource,
        matching: find.text(t.video_acquisition_section_title),
      ),
      findsOneWidget,
    );
    await tester.ensureVisible(resource);
    await tester.tap(resource);
    await _settle(tester);
    expect(searchedResource, isFalse);
    expect(builds, 1, reason: '页面重建不应重建面板 / 重查');
  });

  testWidgets('BT 有结果时预览 + 总数 + 进完整资源搜索的入口', (WidgetTester tester) async {
    _tallView(tester);
    final _FakeBackend torrent = _FakeBackend(VideoAcquisitionChannel.torrent);
    int searchOpened = 0;
    await tester.pumpWidget(
      _harness(
        VideoDiscoveryDetailPage(
          item: _item(),
          actions: VideoDiscoveryActions(
            acquisitionChannels: (_) => <VideoAcquisitionChannelBackend>[
              torrent,
            ],
          ),
        ),
      ),
    );
    await _settle(tester);
    torrent.calls.single.complete(
      VideoAcquisitionLookup.hits(
        const <VideoAcquisitionHit>[
          VideoAcquisitionHit(id: 'r1', title: '[Group] Star Ring 01'),
        ],
        totalCount: 12,
        entry: (BuildContext context) async => searchOpened++,
      ),
    );
    await _settle(tester);
    expect(find.text(t.video_acquisition_torrent_found(count: 12)), findsOne);
    expect(_key('video-acquisition-torrent-hit-r1'), findsOneWidget);
    await tester.ensureVisible(_key('video-acquisition-torrent-entry'));
    await tester.tap(_key('video-acquisition-torrent-entry'));
    await _settle(tester);
    expect(searchOpened, 1);
    // 只传了 BT：其余渠道整组不出现（合规门关掉时同理）。
    expect(_key('video-acquisition-group-library'), findsNothing);
    expect(_key('video-acquisition-group-onlineSource'), findsNothing);
    expect(_key('video-acquisition-group-mediaServer'), findsNothing);
  });

  testWidgets('没接获取面板时 hero「搜索资源」照旧直进 BT 搜索', (WidgetTester tester) async {
    _tallView(tester);
    bool searchedResource = false;
    await tester.pumpWidget(
      _harness(
        VideoDiscoveryDetailPage(
          item: _item(),
          actions: VideoDiscoveryActions(
            onSearchResource: (_, __) async => searchedResource = true,
          ),
        ),
      ),
    );
    await _settle(tester);
    expect(_key('video-acquisition-section'), findsNothing);
    await tester.tap(_key('video-discovery-search-resource'));
    await _settle(tester);
    expect(searchedResource, isTrue);
  });
}
