import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fushi/src/anki/source_review_navigation.dart';
import 'package:fushi/src/floating_ball/app_floating_ball_host.dart'
    show pendingCameraOcr, pendingClipboardLookup;
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/home_tab.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/models/module_registry.dart';
import 'package:fushi/src/pages/implementations/home_page.dart'
    show homeShellTabNotifier;
import 'package:fushi/src/pages/implementations/srs/srs_review_page.dart';
import 'package:fushi/src/pages/implementations/statistics_center_page.dart';
import 'package:fushi/src/platform/app_shortcut_router.dart'
    show unwindToHomeRoute;
import 'package:fushi/src/platform/home_widgets/home_widget_continue_feed.dart';
import 'package:fushi/src/platform/home_widgets/home_widget_link.dart';
import 'package:fushi/src/platform/home_widgets/home_widgets_host.dart';
import 'package:fushi/src/srs/srs_navigation.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';

/// 小组件深链落地（main.dart `handleIncomingUrl` 排队后、app 初始化完成才调）。
///
/// 每条都排在 [ExternalMediaNavigation] 队列里，与卡片出处回跳 / 图标快捷菜单同一条，
/// 外部入口不会同时去收同一个媒体页。关掉的模块不落地（与快捷方式同口径）。
Future<void> runHomeWidgetLink(HomeWidgetLink link, WidgetRef ref) async {
  final AppModel app = ref.read(appProvider);
  final ModuleVisibility visibility = app.moduleVisibility;
  final NavigatorState? navigator = app.navigatorKey.currentState;
  final ExternalMediaNavigation media = ExternalMediaNavigation.instance;

  Future<void> backToHome(HomeTab tab) async {
    homeShellTabNotifier.value = tab;
    if (navigator != null) await unwindToHomeRoute(navigator, media: media);
  }

  switch (link) {
    case HomeWidgetReviewLink():
      if (!visibility.isEnabled(ModuleId.srs)) return;
      await media.navigate(() async {
        await backToHome(HomeTab.srs);
        final SrsDeckListData? decks = await ref.read(
          srsDeckListProvider.future,
        );
        final BuildContext? context = app.navigatorKey.currentContext;
        final deck = decks?.firstRootWithWork;
        if (deck == null || context == null || !context.mounted) return;
        await srsPushPage<void>(
          context,
          (_) => SrsReviewPage(deckId: deck.deck.id, deckName: deck.fullName),
        );
        bumpSrsRevision(ref);
      });
    case HomeWidgetStatsLink():
      await media.navigate(() async {
        if (navigator == null) return;
        await unwindToHomeRoute(navigator, media: media);
        final BuildContext? context = app.navigatorKey.currentContext;
        if (context == null || !context.mounted) return;
        unawaited(
          navigator.push(
            adaptivePageRoute<void>(
              context: context,
              builder: (_) => const StatisticsCenterPage(),
            ),
          ),
        );
      });
    case HomeWidgetContinueLink(:final String key):
      if (!isHomeTabVisible(HomeTab.home, visibility)) return;
      await media.navigate(() async {
        await backToHome(HomeTab.home);
        // 首页用自己的打开函数处理（与点「继续」卡片同一条路径）。
        HomeWidgetContinueFeed.instance.requestOpen(key);
      });
    case HomeWidgetCameraLookupLink():
      if (!visibility.isEnabled(ModuleId.lookup)) return;
      pendingCameraOcr.value = true;
    case HomeWidgetClipboardLookupLink():
      if (!visibility.isEnabled(ModuleId.lookup)) return;
      pendingClipboardLookup.value = true;
    case HomeWidgetResumeAudiobookLink():
      final HomeWidgetsHostState? host = HomeWidgetsHostState.current;
      if (host != null && await host.resumeAudiobook()) return;
      final String? key = host?.lastAudiobookContinueKey;
      if (key == null || !isHomeTabVisible(HomeTab.home, visibility)) return;
      await media.navigate(() async {
        await backToHome(HomeTab.home);
        HomeWidgetContinueFeed.instance.requestOpen(key);
      });
  }
}
