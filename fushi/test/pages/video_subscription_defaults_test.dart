// 订阅面板默认值契约：
// ① 「加入订阅」开关默认打开——进这个页面本来就是为了订阅，提交按钮不该因为一
//    个没人点的确认开关而一直禁用；
// ② 集数框默认「1」——release 标题里解析不出集号时也不留空，否则 helper 写着
//    「从第 1 集开始」而框里空着，用户看不出起点在哪。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/external_provider.dart';
import 'package:fushi/src/media/torrent/torrent_backend.dart'
    show TorrentAddPayload;
import 'package:fushi/src/media/torrent/video_resource_provider.dart';
import 'package:fushi/src/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi/src/media/video/download/video_resource_registry.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_models.dart';
import 'package:fushi/src/pages/implementations/video_discovery_acquisition_dialogs.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';
import 'package:fushi_core/fushi_core.dart' show MediaSourceRow;

class _FakeResource extends VideoResourceCandidate {
  /// 字幕组 + 清晰度必须齐（`deriveStrictVideoSubscriptionFilter` 缺一个就返回
  /// null，开关行会换成「无法订阅」警告），所以在这里写死而不留参数。
  _FakeResource({required super.title})
      : super(
          remoteId: 'r1',
          providerId: 'nyaa',
          providerInstanceId: 'nyaa',
          providerPriority: 100,
          releaseGroup: 'SubsPlease',
          resolution: '1080p',
          seeders: 30,
        );
}

class _SeededProvider implements VideoResourceProvider {
  _SeededProvider(this.items);

  final List<VideoResourceCandidate> items;

  @override
  String get id => 'nyaa';

  @override
  Set<VideoDiscoveryCategory> get categories =>
      const <VideoDiscoveryCategory>{};

  @override
  int get priority => 10;

  @override
  Future<ProviderBatchResult<VideoResourceCandidate>> search(
    VideoResourceSearchRequest request,
  ) async =>
      ProviderBatchResult<VideoResourceCandidate>.success(items);

  @override
  Future<TorrentAddPayload> resolve(VideoResourceCandidate candidate) async =>
      throw UnimplementedError();

  @override
  void close() {}
}

VideoDiscoveryItem _item() => VideoDiscoveryItem(
      reference: VideoMediaReference(
        providerId: 'anilist',
        mediaId: '42',
        mediaKind: VideoMetadataMediaKind.tv,
        discoveryCategory: VideoDiscoveryCategory.anime,
        title: 'Show',
        anilistId: 42,
      ),
    );

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.zhCn));

  /// 订阅面板 + 单条候选（单条组点卡直选，不必展开）。
  Future<void> pumpSubscription(
    WidgetTester tester,
    VideoResourceCandidate candidate,
  ) async {
    tester.view.physicalSize = const Size(1100, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: VideoDiscoverySubscriptionPage(
            item: _item(),
            registry: VideoResourceRegistry(<VideoResourceProvider>[
              _SeededProvider(<VideoResourceCandidate>[candidate]),
            ]),
            sources: const <MediaSourceRow>[
              MediaSourceRow(
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
              ),
            ],
            defaultSourceId: 1,
            onSubmit: (VideoDiscoverySubscriptionSelection selection) async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // 订阅模式恒用平铺列表（见 `_buildFlatResults` 的文档），行 key 按候选身份。
    await tester.tap(
      find.byKey(ValueKey<String>('video-resource-${candidate.identityKey}')),
    );
    await tester.pumpAndSettle();
  }

  String startAfterText(WidgetTester tester) => tester
      .widget<TextField>(
        find.byKey(const ValueKey<String>('video-subscription-start-after')),
      )
      .controller!
      .text;

  bool strictConfirmed(WidgetTester tester) => tester
      .widget<AdaptiveSettingsSwitchRow>(
        find.byKey(
          const ValueKey<String>('video-subscription-strict-confirm'),
        ),
      )
      .value;

  testWidgets('选中候选后「加入订阅」默认打开，提交按钮直接可用', (
    WidgetTester tester,
  ) async {
    await pumpSubscription(
      tester,
      _FakeResource(title: '[SubsPlease] Show - 05 (1080p)'),
    );
    expect(strictConfirmed(tester), isTrue, reason: '默认打开，不必手动确认一次');
    final FilledButton submit = tester.widget<FilledButton>(
      find.byKey(const ValueKey<String>('video-subscription-submit')),
    );
    expect(
      submit.onPressed,
      isNotNull,
      reason: '开关默认关时按钮恒禁用，用户只能看着一个能点的开关猜',
    );
  });

  testWidgets('集数用选中 release 解析出的集号', (WidgetTester tester) async {
    await pumpSubscription(
      tester,
      _FakeResource(title: '[SubsPlease] Show - 05 (1080p)'),
    );
    expect(startAfterText(tester), '5', reason: '选中的 release 集号优先');
  });

  testWidgets('标题无集号时集数框仍是 1，不留空', (WidgetTester tester) async {
    await pumpSubscription(
      tester,
      _FakeResource(title: '[SubsPlease] Show (1080p)'),
    );
    expect(
      startAfterText(tester),
      '1',
      reason: 'helper 写着「从第 1 集开始」，框里就不该是空的',
    );
  });
}
