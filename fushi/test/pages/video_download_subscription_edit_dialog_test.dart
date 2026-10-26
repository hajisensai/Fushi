import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/video_download_subscription_edit_dialog.dart';
import 'package:fushi_engine/media/torrent/rss_search_site.dart';
import '../helpers/glass_unwrap.dart';

/// 订阅「窄合并编辑」对话框的行为守卫。
///
/// 这个对话框此前零测试覆盖，而它一次保存会无条件写四列，是典型的
/// 「整行覆盖 upsert 清空没碰的列」风险面（本仓库反复出现的 bug 形态：
/// 「改 A 之后 B 没了」）。
VideoDownloadSubscriptionRow _subscription({
  int? targetSourceId,
  String filterJson = '{"strict":true}',
  String resourceProvider = 'rss:site1',
}) => VideoDownloadSubscriptionRow(
  subscriptionId: 'subscription-1',
  resourceProvider: resourceProvider,
  metadataProvider: 'anilist',
  externalId: '100',
  mediaKind: 'tv',
  discoveryCategory: 'anime',
  title: 'Example Anime',
  year: 2026,
  season: 1,
  coverUrl: null,
  searchQuery: 'Example anime',
  filterJson: filterJson,
  mode: 'ongoing',
  startAfterEpisode: 3,
  backendKind: 'embedded',
  backendProfileId: null,
  fingerprint: 'embedded-test',
  category: 'fushi-video',
  targetSourceId: targetSourceId,
  collectionId: null,
  organizationPolicy: 'library',
  subtitlePolicy: 'bestEffort',
  enabled: true,
  nextCheckAt: null,
  claimedBy: null,
  claimExpiresAt: null,
  retryCount: 0,
  lastCheckedAt: null,
  lastMatchedAt: null,
  fulfilledAt: null,
  lastError: null,
  createdAt: 1,
  updatedAt: 2,
);

MediaSourceRow _source({required int id, required String label}) =>
    MediaSourceRow(
      videoGroupingMode: 'series',
      id: id,
      label: label,
      mediaKind: 'video',
      transport: 'local',
      rootPath: '/tmp/$label',
      configJson: '{}',
      mediaCount: 0,
      lastScannedAt: null,
      lastScanError: null,
      recursive: true,
      sortOrder: 0,
      createdAt: 1,
    );

void main() {
  /// 打开对话框；调用方 tap 保存/取消后读 holder。
  Future<List<VideoDownloadSubscriptionEdit?>> open(
    WidgetTester tester, {
    required VideoDownloadSubscriptionRow subscription,
    required List<MediaSourceRow> sources,
    List<RssSearchSiteConfig> rssSites = const <RssSearchSiteConfig>[],
  }) async {
    // 对话框在默认 800x600 画布上会横向溢出（与被测行为无关），放大视口。
    tester.view.physicalSize = const Size(1200, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final List<VideoDownloadSubscriptionEdit?> holder =
        <VideoDownloadSubscriptionEdit?>[];
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: Builder(
            builder: (BuildContext context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () async {
                    holder.add(
                      await showVideoDownloadSubscriptionEditDialog(
                        context: context,
                        subscription: subscription,
                        sources: sources,
                        rssSites: rssSites,
                      ),
                    );
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return holder;
  }

  // 回归锚：目标库在外置盘，盘一拔就被 getManagedVideoDownloadSources 的
  // existsSync 过滤掉。旧实现此时把选中值退到「列表第一个」，用户只改搜索词、
  // 一保存目标库被静默改写到无关的库，之后整季新集全导进错地方且没有提示。
  testWidgets('原绑定当前不可用：只改搜索词保存，不得改写目标来源', (WidgetTester tester) async {
    final List<VideoDownloadSubscriptionEdit?> holder = await open(
      tester,
      subscription: _subscription(targetSourceId: 42), // 42 不在可用列表里
      sources: <MediaSourceRow>[_source(id: 7, label: 'Some Other Library')],
    );

    await tester.enterText(
      find.byKey(const ValueKey<String>('subscription-edit-query')),
      'New query',
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('subscription-edit-save')),
    );
    await tester.pumpAndSettle();

    expect(holder, hasLength(1));
    final VideoDownloadSubscriptionEdit edit = holder.single!;
    expect(edit.searchQuery, 'New query');
    expect(
      edit.targetSourceId,
      isNull,
      reason: '用户没动目标来源 ⇒ 必须返回 null，宿主据此不写这一列',
    );
  });

  testWidgets('主动改目标来源：才返回新值', (WidgetTester tester) async {
    final List<VideoDownloadSubscriptionEdit?> holder = await open(
      tester,
      subscription: _subscription(targetSourceId: 7),
      sources: <MediaSourceRow>[
        _source(id: 7, label: 'Library A'),
        _source(id: 9, label: 'Library B'),
      ],
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('subscription-edit-source')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Library B').last);
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('subscription-edit-save')),
    );
    await tester.pumpAndSettle();

    expect(holder.single!.targetSourceId, 9);
  });

  // 负数会违反 CHECK(start_after_episode IS NULL OR >= 0)，而宿主的 _edit 没有
  // catch —— 旧实现下对话框已关、界面毫无反应，用户以为保存成功了。
  testWidgets('起始集非法（负数 / 非数字）：禁用保存，不静默清空也不静默失败', (WidgetTester tester) async {
    final List<VideoDownloadSubscriptionEdit?> holder = await open(
      tester,
      subscription: _subscription(targetSourceId: 7),
      sources: <MediaSourceRow>[_source(id: 7, label: 'Library A')],
    );

    for (final String bad in <String>['-1', '12話']) {
      await tester.enterText(
        find.byKey(const ValueKey<String>('subscription-edit-start-after')),
        bad,
      );
      await tester.pumpAndSettle();
      final FilledButton save = tester.widget<FilledButton>(
        glassUnwrap<FilledButton>(
          find.byKey(const ValueKey<String>('subscription-edit-save')),
        ),
      );
      expect(save.onPressed, isNull, reason: '非法起始集「$bad」必须禁用保存');
      expect(
        find.text(t.download_subscription_start_episode_invalid),
        findsOneWidget,
        reason: '必须显式报错，而不是静默把起始集清空',
      );
    }

    // 改回合法值后恢复可保存。
    await tester.enterText(
      find.byKey(const ValueKey<String>('subscription-edit-start-after')),
      '5',
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('subscription-edit-save')),
    );
    await tester.pumpAndSettle();
    expect(holder.single!.startAfterEpisode, 5);
  });

  testWidgets('起始集留空 = 不限（合法）', (WidgetTester tester) async {
    final List<VideoDownloadSubscriptionEdit?> holder = await open(
      tester,
      subscription: _subscription(targetSourceId: 7),
      sources: <MediaSourceRow>[_source(id: 7, label: 'Library A')],
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('subscription-edit-start-after')),
      '',
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('subscription-edit-save')),
    );
    await tester.pumpAndSettle();
    expect(holder.single!.startAfterEpisode, isNull);
  });

  // 换字幕组：以前只能删掉重订。现在字幕组 / 分辨率 / 标题关键词可改，其余规则
  // （strict、trusted、分类）原样保留；没动规则时不写 filterJson。
  testWidgets('改字幕组与排除词：只改这几项，其余规则保留', (WidgetTester tester) async {
    final List<VideoDownloadSubscriptionEdit?> holder = await open(
      tester,
      subscription: _subscription(
        targetSourceId: 7,
        filterJson:
            '{"strict":true,"releaseGroup":"Old","resolution":"1080p",'
            '"trustedOnly":true,"nyaaCategory":"1_2"}',
      ),
      sources: <MediaSourceRow>[_source(id: 7, label: 'Library A')],
    );
    final Finder group = find.byKey(
      const ValueKey<String>('subscription-edit-release-group'),
    );
    expect(
      tester
          .widget<EditableText>(
            find.descendant(of: group, matching: find.byType(EditableText)),
          )
          .controller
          .text,
      'Old',
    );
    await tester.enterText(group, 'New, Other');
    await tester.enterText(
      find.byKey(const ValueKey<String>('subscription-edit-title-exclude')),
      'HEVC',
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('subscription-edit-save')),
    );
    await tester.pumpAndSettle();
    final Map<String, Object?> filter =
        (jsonDecode(holder.single!.filterJson!) as Map).cast<String, Object?>();
    expect(filter['releaseGroup'], <String>['New', 'Other']);
    expect(filter['titleExclude'], 'HEVC');
    expect(filter['resolution'], '1080p');
    expect(filter['strict'], isTrue);
    expect(filter['trustedOnly'], isTrue);
    expect(filter['nyaaCategory'], '1_2');
  });

  testWidgets('RSS 订阅清空字幕组与分辨率：禁用保存并说明至少一条版本规则', (WidgetTester tester) async {
    await open(
      tester,
      subscription: _subscription(
        targetSourceId: 7,
        filterJson:
            '{"strict":true,"releaseGroup":"Old","resolution":"1080p",'
            '"trustedOnly":true}',
      ),
      sources: <MediaSourceRow>[_source(id: 7, label: 'Library A')],
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('subscription-edit-release-group')),
      '',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('subscription-edit-resolution')),
      '',
    );
    await tester.pumpAndSettle();
    final FilledButton save = tester.widget<FilledButton>(
      glassUnwrap<FilledButton>(
        find.byKey(const ValueKey<String>('subscription-edit-save')),
      ),
    );
    expect(save.onPressed, isNull);
    expect(find.text(t.subscription_edit_rule_required), findsOneWidget);
  });

  testWidgets('没动规则：filterJson 返回 null（宿主不写这一列）', (WidgetTester tester) async {
    final List<VideoDownloadSubscriptionEdit?> holder = await open(
      tester,
      subscription: _subscription(targetSourceId: 7),
      sources: <MediaSourceRow>[_source(id: 7, label: 'Library A')],
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('subscription-edit-save')),
    );
    await tester.pumpAndSettle();
    expect(holder.single!.filterJson, isNull);
  });

  group('绑在已移除的内置搜索站上的旧订阅', () {
    RssSearchSiteConfig site(
      String id, {
      bool enabled = true,
      List<RssSearchDomain> domains = const <RssSearchDomain>[
        RssSearchDomain.anime,
      ],
    }) => RssSearchSiteConfig(
      id: id,
      name: 'Site $id',
      urlTemplate: 'https://$id.example/rss?q={query}',
      enabled: enabled,
      domains: domains,
    );

    testWidgets('提示来源已失效，可改选启用且勾了视频域的 RSS 站', (WidgetTester tester) async {
      final List<VideoDownloadSubscriptionEdit?> holder = await open(
        tester,
        subscription: _subscription(
          targetSourceId: 7,
          resourceProvider: 'nyaa:default',
          filterJson: '{"strict":true,"releaseGroup":"Old"}',
        ),
        sources: <MediaSourceRow>[_source(id: 7, label: 'Library A')],
        rssSites: <RssSearchSiteConfig>[
          site('a'),
          site('off', enabled: false),
          site(
            'books',
            domains: const <RssSearchDomain>[RssSearchDomain.novel],
          ),
        ],
      );
      expect(
        find.byKey(
          const ValueKey<String>('subscription-edit-provider-removed'),
        ),
        findsOneWidget,
      );
      expect(find.text(t.video_subscription_provider_removed), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey<String>('subscription-edit-rss-site')),
      );
      await tester.pumpAndSettle();
      // 停用的站、只勾了发现页域的站都不能选：选了订阅检查也会报「站不在场」。
      expect(find.text('Site off'), findsNothing);
      expect(find.text('Site books'), findsNothing);
      await tester.tap(find.text('Site a').last);
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('subscription-edit-save')),
      );
      await tester.pumpAndSettle();
      expect(holder.single!.resourceProvider, 'rss:a');
    });

    testWidgets('本机没有可选的 RSS 站：说明先去添加，不换源也能保存其它字段', (
      WidgetTester tester,
    ) async {
      final List<VideoDownloadSubscriptionEdit?> holder = await open(
        tester,
        subscription: _subscription(
          targetSourceId: 7,
          resourceProvider: 'apibay',
        ),
        sources: <MediaSourceRow>[_source(id: 7, label: 'Library A')],
      );
      expect(
        find.text(
          '${t.video_subscription_provider_removed} '
          '${t.video_subscription_provider_no_rss_site}',
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('subscription-edit-rss-site')),
        findsNothing,
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('subscription-edit-save')),
      );
      await tester.pumpAndSettle();
      expect(holder.single!.resourceProvider, isNull);
    });

    testWidgets('仍在用的 RSS 订阅不出现失效提示', (WidgetTester tester) async {
      await open(
        tester,
        subscription: _subscription(targetSourceId: 7),
        sources: <MediaSourceRow>[_source(id: 7, label: 'Library A')],
        rssSites: <RssSearchSiteConfig>[site('site1')],
      );
      expect(
        find.byKey(
          const ValueKey<String>('subscription-edit-provider-removed'),
        ),
        findsNothing,
      );
    });
  });
}
