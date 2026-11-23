// 首页视图（Home views）真机探针：在真实数据库上逐步验证开关关着时首页不变、
// 开着时头像菜单 / 提示 / 按语言筛选 / 筛空状态 / 管理页与编辑页。每步抓一帧
// （observe-*.png）并打印可 diff 的文本证据；结束时把改过的偏好原样还原。
//
// 需要库里至少有一部带语言的作品（空库会在 B 步断言失败），所以要对一份有数据的
// 隔离副本跑，别对自己的真库跑。在 fushi/ 下：
//   flutter test integration_test/home_views_probe_itest.dart --device-id=windows --no-pub
import 'dart:async';

import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/home_view.dart';
import 'package:fushi/src/models/home_view_lookup.dart';
import 'package:fushi/src/pages/implementations/home_page.dart';
import 'package:fushi/src/pages/implementations/home_view_switcher.dart';
import 'package:fushi/src/pages/implementations/home_views_page.dart';

import 'helpers/focus_driver.dart';
import 'helpers/library_fixture.dart';
import 'helpers/observe_capture.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

/// 屏上所有以 [prefix] 开头的字符串 key（首页条目计数用）。
List<String> _keysWithPrefix(String prefix) => <String>[
  for (final Element e in find.byWidgetPredicate((Widget w) {
    final Key? k = w.key;
    return k is ValueKey<String> && k.value.startsWith(prefix);
  }).evaluate())
    (e.widget.key! as ValueKey<String>).value,
];

/// 屏上含 [needle] 的 Text 文案。
List<String> _textsContaining(String needle) => <String>{
  for (final Element e in find.byType(Text).evaluate())
    if ((e.widget as Text).data case final String s when s.contains(needle)) s,
}.toList();

Future<void> _settle(WidgetTester tester, [int seconds = 3]) async {
  for (int i = 0; i < seconds * 4; i++) {
    await tester.pump(const Duration(milliseconds: 250));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('首页视图：关着不变，开着菜单 / 提示 / 筛选 / 筛空 / 管理页', (
    WidgetTester tester,
  ) async {
    await launchFushiTestApp();
    expect(await waitForHome(tester), isTrue, reason: '主页应在 90s 内出现');
    final AppModel appModel = await readyAppModel(tester);
    HomePage.debugSelectTab?.call(HomeTab.home);
    await _settle(tester, 6);

    final bool wasEnabled = appModel.homeViewsEnabled;
    final List<HomeView> wasViews = appModel.homeViews;
    final String wasActive = appModel.homeViewActiveId;
    final bool wasTip = appModel.homeViewsTipShown;
    final bool wasFocusNav = appModel.experimentalFocusNavigationEnabled;
    try {
      // ── A. 开关关着：没有头像菜单控件，标题不带视图名 ───────────────────────
      await appModel.setHomeViewsEnabled(false);
      await _settle(tester);
      expect(find.byType(HomeViewAvatarControls), findsNothing);
      final List<String> offItems = _keysWithPrefix('home-continue');
      debugPrint(
        '[home-views] A off: continue keys=${offItems.length} '
        'titles=${_textsContaining(t.home_continue)}',
      );
      expect(
        (await captureFlutterFrame(tester, 'hv-01-off', settle: false)).saved,
        isTrue,
      );

      // ── B. 打开开关 + 准备视图（库里真有的语言 + 一个库里没有的语言） ─────────
      final ({List<String> languages, bool hasNoLanguage}) options =
          await loadHomeViewLanguageOptions(appModel.database);
      debugPrint(
        '[home-views] library languages=${options.languages} '
        'hasNoLanguage=${options.hasNoLanguage}',
      );
      expect(options.languages, isNotEmpty, reason: '种子库应有带语言的作品');
      final String lang = options.languages.contains('ja')
          ? 'ja'
          : options.languages.first;
      final String missing = <String>[
        'ko',
        'th',
        'vi',
        'ar',
      ].firstWhere((String l) => !options.languages.contains(l));
      final HomeView langView = HomeView(
        id: 'vprobe-lang',
        languages: <String>{lang},
      );
      final HomeView emptyView = HomeView(
        id: 'vprobe-empty',
        languages: <String>{missing},
      );
      await appModel.setHomeViewsTipShown(false);
      await appModel.setHomeViews(<HomeView>[langView, emptyView]);
      await appModel.setHomeViewActiveId(kHomeViewEverythingId);
      await appModel.setHomeViewsEnabled(true);
      await _settle(tester, 4);
      expect(find.byType(HomeViewAvatarControls), findsOneWidget);
      // 种子库启动时可能弹对话框（如「升级词典格式」）盖住首页：此时提示不该浮在
      // 对话框上；关掉对话框后才出现。
      final bool covered =
          !(ModalRoute.of(
                tester.element(find.byType(HomeViewAvatarControls)),
              )?.isCurrent ??
              true);
      if (covered) {
        final bool tipWhileCovered = find
            .byKey(const ValueKey<String>('home-view-tip'))
            .evaluate()
            .isNotEmpty;
        debugPrint('[home-views] B covered by dialog: tip=$tipWhileCovered');
        expect(
          (await captureFlutterFrame(
            tester,
            'hv-02a-covered',
            settle: false,
          )).saved,
          isTrue,
        );
        expect(tipWhileCovered, isFalse, reason: '对话框盖住首页时不应显示提示');
        Navigator.of(
          tester.element(find.byType(HomeViewAvatarControls)),
          rootNavigator: true,
        ).popUntil((Route<dynamic> r) => r.isFirst);
        await _settle(tester, 3);
      }
      final bool tipShown = find
          .byKey(const ValueKey<String>('home-view-tip'))
          .evaluate()
          .isNotEmpty;
      debugPrint(
        '[home-views] B on/everything: tip=$tipShown '
        'continue keys=${_keysWithPrefix('home-continue').length}',
      );
      expect(
        (await captureFlutterFrame(
          tester,
          'hv-02-on-tip',
          settle: false,
        )).saved,
        isTrue,
      );
      expect(tipShown, isTrue, reason: '第一次打开开关应出现提示');
      await appModel.setHomeViewsTipShown(true);
      await _settle(tester);

      // ── C. 键盘打开菜单：焦点给头像里的可聚焦控件，Shift+F10 ─────────────────
      // 像键盘用户那样按 Tab 走到头像（焦点驱动，不点坐标）。裸 Tab 默认被中和
      // （BUG-1106），先开「键盘/手柄焦点导航」，finally 里还原。
      await enableFocusNavigation(tester);
      final bool onAvatar = await FocusDriver(
        tester,
      ).focusWidget(find.byType(HomeViewAvatarControls));
      debugPrint('[home-views] C tab walk reached avatar=$onAvatar');
      expect(onAvatar, isTrue, reason: 'Tab 应能走到头像');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.f10);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await _settle(tester, 2);
      final bool menuOpen = find
          .text(t.home_view_menu_title)
          .evaluate()
          .isNotEmpty;
      debugPrint(
        '[home-views] C menu open=$menuOpen '
        'items=${_keysWithPrefix('home-view-menu/')}',
      );
      expect(
        (await captureFlutterFrame(tester, 'hv-03-menu', settle: false)).saved,
        isTrue,
      );
      expect(menuOpen, isTrue, reason: 'Shift+F10 应打开「首页显示」菜单');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await _settle(tester, 2);

      // ── D. 选语言视图：标题缀视图名，条目只剩该语言 ─────────────────────────
      await appModel.setHomeViewActiveId(langView.id);
      await _settle(tester, 4);
      final String langName = homeViewNameOf(langView);
      final List<String> viewTitles = _textsContaining(' · $langName');
      debugPrint(
        '[home-views] D view=$langName titles=$viewTitles '
        'continue keys=${_keysWithPrefix('home-continue').length} '
        'badge=${_keysWithPrefix('home-view-poster-badge').length}',
      );
      expect(
        (await captureFlutterFrame(
          tester,
          'hv-04-view-lang',
          settle: false,
        )).saved,
        isTrue,
      );
      expect(
        viewTitles.isNotEmpty ||
            _keysWithPrefix('home-view-poster-badge').isNotEmpty,
        isTrue,
        reason: '视图生效时组件标题或色块标签应显示视图名',
      );

      // ── E. 库里没有的语言：筛空状态 +「显示全部」 ────────────────────────────
      await appModel.setHomeViewActiveId(emptyView.id);
      await _settle(tester, 4);
      final int emptyStates =
          _keysWithPrefix('home-view-show-everything').length +
          _textsContaining(t.home_view_show_everything).length;
      debugPrint(
        '[home-views] E empty view=${homeViewNameOf(emptyView)} '
        'showEverything=$emptyStates',
      );
      expect(
        (await captureFlutterFrame(tester, 'hv-05-empty', settle: false)).saved,
        isTrue,
      );
      expect(emptyStates, greaterThan(0), reason: '筛空的组件应显示「显示全部」');

      // ── F. 管理视图页与编辑页 ──────────────────────────────────────────────
      final BuildContext ctx = tester.element(find.byType(HomePage));
      unawaited(openHomeViewsPage(ctx, appModel));
      await _settle(tester, 3);
      debugPrint(
        '[home-views] F manage rows=${_keysWithPrefix('home-views-').length}',
      );
      expect(
        (await captureFlutterFrame(
          tester,
          'hv-06-manage',
          settle: false,
        )).saved,
        isTrue,
      );
      unawaited(openHomeViewEditor(ctx, appModel, initial: langView));
      await _settle(tester, 4);
      debugPrint(
        '[home-views] F editor lang chips=${_keysWithPrefix('home-view-lang').length} '
        'tag chips=${_keysWithPrefix('home-view-tag/').length}',
      );
      expect(
        (await captureFlutterFrame(
          tester,
          'hv-07-editor',
          settle: false,
        )).saved,
        isTrue,
      );
      Navigator.of(ctx).popUntil((Route<dynamic> r) => r.isFirst);
      await _settle(tester, 2);

      // ── G. 关掉开关：回到原样 ─────────────────────────────────────────────
      await appModel.setHomeViewsEnabled(false);
      await _settle(tester, 4);
      final List<String> offAgain = _keysWithPrefix('home-continue');
      debugPrint(
        '[home-views] G off again: continue keys=${offAgain.length} '
        '(A had ${offItems.length})',
      );
      expect(find.byType(HomeViewAvatarControls), findsNothing);
      expect(
        (await captureFlutterFrame(
          tester,
          'hv-08-off-again',
          settle: false,
        )).saved,
        isTrue,
      );
    } finally {
      await appModel.setHomeViewsEnabled(wasEnabled);
      await appModel.setHomeViews(wasViews);
      await appModel.setHomeViewActiveId(wasActive);
      await appModel.setHomeViewsTipShown(wasTip);
      await appModel.setExperimentalFocusNavigationEnabled(wasFocusNav);
    }
  });
}
