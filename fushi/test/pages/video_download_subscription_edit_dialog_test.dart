import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/video_download_subscription_edit_dialog.dart';

/// 订阅「窄合并编辑」对话框的行为守卫。
///
/// 这个对话框此前零测试覆盖，而它一次保存会无条件写四列，是典型的
/// 「整行覆盖 upsert 清空没碰的列」风险面（本仓库反复出现的 bug 形态：
/// 「改 A 之后 B 没了」）。
VideoDownloadSubscriptionRow _subscription({int? targetSourceId}) =>
    VideoDownloadSubscriptionRow(
      subscriptionId: 'subscription-1',
      resourceProvider: 'nyaa:default',
      metadataProvider: 'anilist',
      externalId: '100',
      mediaKind: 'tv',
      discoveryCategory: 'anime',
      title: 'Example Anime',
      year: 2026,
      season: 1,
      coverUrl: null,
      searchQuery: 'Example anime',
      filterJson: '{"strict":true}',
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
                    holder.add(await showVideoDownloadSubscriptionEditDialog(
                      context: context,
                      subscription: subscription,
                      sources: sources,
                    ));
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
    await tester
        .tap(find.byKey(const ValueKey<String>('subscription-edit-save')));
    await tester.pumpAndSettle();

    expect(holder, hasLength(1));
    final VideoDownloadSubscriptionEdit edit = holder.single!;
    expect(edit.searchQuery, 'New query');
    expect(edit.targetSourceId, isNull,
        reason: '用户没动目标来源 ⇒ 必须返回 null，宿主据此不写这一列');
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

    await tester
        .tap(find.byKey(const ValueKey<String>('subscription-edit-source')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Library B').last);
    await tester.pumpAndSettle();
    await tester
        .tap(find.byKey(const ValueKey<String>('subscription-edit-save')));
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
        find.byKey(const ValueKey<String>('subscription-edit-save')),
      );
      expect(save.onPressed, isNull, reason: '非法起始集「$bad」必须禁用保存');
      expect(find.text(t.download_subscription_start_episode_invalid),
          findsOneWidget,
          reason: '必须显式报错，而不是静默把起始集清空');
    }

    // 改回合法值后恢复可保存。
    await tester.enterText(
      find.byKey(const ValueKey<String>('subscription-edit-start-after')),
      '5',
    );
    await tester.pumpAndSettle();
    await tester
        .tap(find.byKey(const ValueKey<String>('subscription-edit-save')));
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
    await tester
        .tap(find.byKey(const ValueKey<String>('subscription-edit-save')));
    await tester.pumpAndSettle();
    expect(holder.single!.startAfterEpisode, isNull);
  });
}
