// 订阅面板默认值契约：
// ① 「加入订阅」开关默认打开——进这个页面本来就是为了订阅，提交按钮不该因为一
//    个没人点的确认开关而一直禁用；
// ② 集数框默认「1」——代表发布的标题里解析不出集号时也不留空，否则 helper 写着
//    「从第 1 集开始」而框里空着，用户看不出起点在哪；
// ③ 起始集号框只对追更有意义：整包订阅一次下完，没有起点可言（BUG-2619）。
//    注意 ② 与 ③ 的交界——`subscriptionReleaseIsBatch` 的定义就是「解析不出集号
//    即整包」，所以 ② 只在「这条规则覆盖的发布里还有单集」（组 batchOnly=false）
//    时才可达：代表条恰好是无集号的那个整包。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/media/torrent/torrent_backend.dart'
    show TorrentAddPayload;
import 'package:fushi_engine/media/torrent/video_resource_provider.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/download/video_resource_registry.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi/src/pages/implementations/video_discovery_acquisition_dialogs.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';
import 'package:fushi_core/fushi_core.dart' show MediaSourceRow;

class _FakeResource extends VideoResourceCandidate {
  /// 字幕组 + 清晰度必须齐（`deriveStrictVideoSubscriptionFilter` 缺一个就返回
  /// null，开关行会换成「无法订阅」警告），所以在这里写死而不留参数——同时这也
  /// 让同一测试里的多条候选天然落进同一个订阅组（分组键就是这张 filter）。
  _FakeResource({
    required super.title,
    String remoteId = 'r1',
    int seeders = 30,
  }) : super(
          remoteId: remoteId,
          providerId: 'nyaa',
          providerInstanceId: 'nyaa',
          providerPriority: 100,
          releaseGroup: 'SubsPlease',
          resolution: '1080p',
          seeders: seeders,
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

  /// 订阅面板 + 候选。[candidate] 是要点选的那条（做种最多者当组代表，所以它得
  /// 是 seeders 最大的）；[others] 是同组里的其它发布，用来把组的 batchOnly 压成
  /// false。
  Future<void> pumpSubscription(
    WidgetTester tester,
    VideoResourceCandidate candidate, {
    List<VideoResourceCandidate> others = const <VideoResourceCandidate>[],
  }) async {
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
              _SeededProvider(<VideoResourceCandidate>[candidate, ...others]),
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

  final Finder startAfterField = find.byKey(
    const ValueKey<String>('video-subscription-start-after'),
  );

  String startAfterText(WidgetTester tester) =>
      tester.widget<TextField>(startAfterField).controller!.text;

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

  testWidgets('代表条无集号但同组里还有单集时，集数框仍是 1，不留空', (
    WidgetTester tester,
  ) async {
    // 代表条 = 做种最多的那条，这里是无集号的整包；组里还有一条单集，于是
    // batchOnly=false、按追更建订阅，起始集号框照常出现。
    await pumpSubscription(
      tester,
      _FakeResource(title: '[SubsPlease] Show (1080p)', seeders: 80),
      others: <VideoResourceCandidate>[
        _FakeResource(
          title: '[SubsPlease] Show - 05 (1080p)',
          remoteId: 'r2',
          seeders: 10,
        ),
      ],
    );
    expect(
      startAfterText(tester),
      '1',
      reason: 'helper 写着「从第 1 集开始」，框里就不该是空的',
    );
  });

  testWidgets('整包订阅不显示起始集号框（BUG-2619）', (WidgetTester tester) async {
    // 标题解析不出集号 ⇒ subscriptionReleaseIsBatch ⇒ 这条规则覆盖的全是整包。
    // 整包一次下完，没有「从第几集开始」可言；框留着只会让用户以为在追更。
    await pumpSubscription(
      tester,
      _FakeResource(title: '[SubsPlease] Show (1080p)'),
    );
    expect(startAfterField, findsNothing);
  });
}
