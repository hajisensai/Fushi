import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/downloads/apple/apple_download_list_parts.dart';
import 'package:fushi/src/media/downloads/apple/apple_download_task_row.dart';
import 'package:fushi/src/media/downloads/download_task_browser.dart';
import 'package:fushi/src/media/downloads/download_task_card.dart';
import 'package:fushi/src/media/downloads/download_task_entry.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/video_download_subscriptions_panel.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// 下载页 Apple（Cupertino 方案 A）外观：
/// - `isGlassDesign` 为真时任务页走 Apple 版式：汇总行、默认按状态分组（需要处理
///   在进行中之前）、行尾圆钮、长按 / Shift+F10 行菜单、焦点 + Enter 触发主操作、
///   右滑暂停；macOS 宽窗分出右侧窗格；
/// - M3E 主题下仍是原卡片布局（汇总 hero + 任务卡）；
/// - 订阅页 Apple 下是 inset 行 + 行「⋯」菜单。
void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  Future<void> pump(
    WidgetTester tester,
    Widget child, {
    required bool glass,
    TargetPlatform platform = TargetPlatform.iOS,
    Size size = const Size(420, 1400),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          theme: buildFushiThemeData(
            scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
            textTheme: Typography.material2021().black,
            glassDesign: glass,
          ).copyWith(platform: platform),
          home: FushiGlassScope(child: Scaffold(body: child)),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  }

  DownloadTaskEntry task(
    String id, {
    required DownloadTaskStatus status,
    DownloadTaskActions actions = DownloadTaskActions.none,
    DownloadTaskQuickAction? quick,
    List<DownloadTaskMenuAction> menu = const <DownloadTaskMenuAction>[],
    double? progress,
    int? down,
  }) => DownloadTaskEntry(
    id: id,
    title: 'Task $id',
    kind: DownloadTaskKind.video,
    status: status,
    progress: progress,
    actions: actions,
    downRateBps: down,
    builder: (BuildContext context) => DownloadTaskCard(
      taskId: id,
      title: 'Task $id',
      status: downloadTaskStatusLabel(status),
      progress: progress,
      leading: const Icon(FushiIcons.video),
      quickAction: quick,
      menuActions: menu,
      details: Text('details-$id'),
    ),
  );

  group('Apple download tasks (scheme A)', () {
    testWidgets('summary row, status groups, round button', (
      WidgetTester tester,
    ) async {
      await pump(
        tester,
        DownloadTaskBrowser(
          tasks: <DownloadTaskEntry>[
            task(
              'a',
              status: DownloadTaskStatus.active,
              progress: 0.4,
              down: 2048,
              quick: DownloadTaskQuickAction(
                key: const ValueKey<String>('quick-a'),
                icon: FushiIcons.pause,
                tooltip: 'Pause',
                onPressed: () {},
              ),
            ),
            task('b', status: DownloadTaskStatus.completed),
            task('c', status: DownloadTaskStatus.attention),
          ],
        ),
        glass: true,
      );

      expect(
        find.byKey(const ValueKey<String>('download-summary-apple')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('download-summary-hero')),
        findsNothing,
      );
      // 默认按状态分组，组按生命周期排：需要处理 → 进行中 → 已完成。
      final Finder attention = find.byKey(
        const ValueKey<String>('download-group-status:attention'),
      );
      final Finder active = find.byKey(
        const ValueKey<String>('download-group-status:active'),
      );
      final Finder completed = find.byKey(
        const ValueKey<String>('download-group-status:completed'),
      );
      expect(attention, findsOneWidget);
      expect(active, findsOneWidget);
      expect(completed, findsOneWidget);
      expect(
        tester.getTopLeft(attention).dy,
        lessThan(tester.getTopLeft(active).dy),
      );
      expect(
        tester.getTopLeft(active).dy,
        lessThan(tester.getTopLeft(completed).dy),
      );
      expect(find.byType(AppleDownloadTaskRow), findsNWidgets(3));
      expect(find.byKey(const ValueKey<String>('quick-a')), findsOneWidget);
      expect(
        tester.widget(find.byKey(const ValueKey<String>('quick-a'))),
        isA<AppleDownloadRoundButton>(),
      );
      // 状态 pull-down 与「⋯」。
      expect(
        find.byKey(const ValueKey<String>('download-task-status-filter')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('download-task-more')),
        findsOneWidget,
      );
    });

    testWidgets('focus + Enter runs the primary action; Shift+F10 menu', (
      WidgetTester tester,
    ) async {
      int pressed = 0;
      int opened = 0;
      await pump(
        tester,
        DownloadTaskBrowser(
          tasks: <DownloadTaskEntry>[
            task(
              'a',
              status: DownloadTaskStatus.active,
              progress: 0.5,
              quick: DownloadTaskQuickAction(
                icon: FushiIcons.pause,
                tooltip: 'Pause',
                onPressed: () => pressed++,
              ),
              menu: <DownloadTaskMenuAction>[
                DownloadTaskMenuAction(
                  id: 'open-location',
                  icon: FushiIcons.folderOpen,
                  label: 'Show in folder',
                  onSelected: () => opened++,
                ),
              ],
            ),
          ],
        ),
        glass: true,
      );

      final FocusNode node = Focus.of(
        tester.element(
          find.byKey(const ValueKey<String>('download-task-toggle-a')),
        ),
      );
      node.requestFocus();
      await tester.pump();
      expect(node.hasFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(pressed, 1);

      // 键盘打开行菜单：现有菜单项 + 「详情」。
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.f10);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Show in folder'), findsOneWidget);
      expect(find.text(t.download_task_details), findsOneWidget);
      await tester.tap(find.text('Show in folder'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(opened, 1);
    });

    testWidgets('long press opens the row menu', (WidgetTester tester) async {
      await pump(
        tester,
        DownloadTaskBrowser(
          tasks: <DownloadTaskEntry>[
            task(
              'a',
              status: DownloadTaskStatus.attention,
              menu: <DownloadTaskMenuAction>[
                DownloadTaskMenuAction(
                  id: 'pair-audiobook',
                  icon: FushiIcons.libraryAdd,
                  label: 'Add alignment file',
                  onSelected: () {},
                ),
              ],
            ),
          ],
        ),
        glass: true,
      );
      await tester.longPress(
        find.byKey(const ValueKey<String>('download-task-toggle-a')),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Add alignment file'), findsOneWidget);
    });

    testWidgets('swiping toward the end pauses the task', (
      WidgetTester tester,
    ) async {
      int paused = 0;
      await pump(
        tester,
        DownloadTaskBrowser(
          tasks: <DownloadTaskEntry>[
            task(
              'a',
              status: DownloadTaskStatus.active,
              progress: 0.3,
              actions: DownloadTaskActions(pause: () async => paused++),
            ),
          ],
        ),
        glass: true,
      );
      await tester.drag(
        find.byKey(const ValueKey<String>('download-task-slice-a')),
        const Offset(260, 0),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(paused, 1);
    });

    testWidgets('macOS wide window gets the side pane', (
      WidgetTester tester,
    ) async {
      await pump(
        tester,
        DownloadTaskBrowser(
          tasks: <DownloadTaskEntry>[
            task('a', status: DownloadTaskStatus.active, progress: 0.2),
          ],
        ),
        glass: true,
        platform: TargetPlatform.macOS,
        size: const Size(1280, 900),
      );
      final Finder pane = find.byKey(
        const ValueKey<String>('download-task-side-pane'),
      );
      expect(pane, findsOneWidget);
      expect(
        find.descendant(
          of: pane,
          matching: find.byKey(
            const ValueKey<String>('download-summary-apple'),
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: pane,
          matching: find.byType(AppleDownloadFilterRow),
        ),
        findsNWidgets(DownloadTaskStatusFilter.values.length),
      );
    });
  });

  testWidgets('M3E theme keeps the original card layout', (
    WidgetTester tester,
  ) async {
    await pump(
      tester,
      DownloadTaskBrowser(
        tasks: <DownloadTaskEntry>[
          task('a', status: DownloadTaskStatus.active, progress: 0.4),
        ],
      ),
      glass: false,
    );
    expect(
      find.byKey(const ValueKey<String>('download-summary-hero')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('download-summary-apple')),
      findsNothing,
    );
    expect(find.byType(AppleDownloadTaskRow), findsNothing);
    expect(find.byType(AppleDownloadTaskSlice), findsNothing);
    // M3E 默认按合集分组（不是 Apple 的按状态）。
    expect(
      find.byKey(
        const ValueKey<String>('download-group-collection:unassigned'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('Apple subscriptions: inset row with switch and row menu', (
    WidgetTester tester,
  ) async {
    final VideoDownloadSubscriptionRow row = VideoDownloadSubscriptionRow(
      subscriptionId: 's1',
      resourceProvider: 'nyaa:default',
      metadataProvider: 'anilist',
      externalId: '1',
      mediaKind: 'tv',
      discoveryCategory: 'anime',
      title: 'Example',
      year: null,
      season: null,
      coverUrl: null,
      searchQuery: 'q',
      filterJson: '{}',
      mode: 'ongoing',
      startAfterEpisode: null,
      backendKind: 'embedded',
      backendProfileId: null,
      fingerprint: 'f',
      category: 'fushi-video',
      targetSourceId: null,
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
    int checked = 0;
    await pump(
      tester,
      VideoDownloadSubscriptionsView(
        subscriptions: <VideoDownloadSubscriptionRow>[row],
        checkingAll: false,
        onCheckAll: () async {},
        onToggle: (_, _) async {},
        onCheck: (_) async => checked++,
        onDelete: (_) async {},
      ),
      glass: true,
    );
    expect(
      find.byKey(const ValueKey<String>('video-subscription-card-s1')),
      findsOneWidget,
    );
    expect(
      tester.widget(
        find.byKey(const ValueKey<String>('video-subscription-card-s1')),
      ),
      isA<AppleDownloadTaskSlice>(),
    );
    expect(
      find.byKey(const ValueKey<String>('video-subscription-toggle-s1')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('video-subscription-menu-s1')),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text(t.download_subscription_check_now));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(checked, 1);
  });
}
