// 反馈 4s8SaBMfyY：Cupertino 下库页页名画两遍——外壳大标题条（iOS 根页大标题）
// 画一行「Video」，库页的页头大字（`FushiFloatingChromeOverlay(masthead: true)`）
// 又用外壳下发的同一个页面名画一行大字。
//
// 页面名（[homeShellTitleFor]，经 FushiShellTitleScope 下发给页头大字）与外壳条
// 自己画不画（[homeShellBarTitleFor]）是两件事：前者库页必须有，后者在页头大字
// 生效时必须没有。逐格钉住，并钉住「后台任务」入口随之退回 FAB、不丢。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/home_page.dart';

/// 库页根 overlay 挂着 `masthead: true` 的 tab（重设计外壳下页名由页头大字画）。
const List<HomeTab> _mastheadTabs = <HomeTab>[
  HomeTab.books,
  HomeTab.manga,
  HomeTab.video,
  HomeTab.games,
  HomeTab.music,
  HomeTab.browse,
  HomeTab.web,
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  test('重设计外壳下页头大字库页：外壳条不画页名（两套设计系统、宽窄窗）', () {
    for (final HomeTab tab in _mastheadTabs) {
      for (final bool apple in <bool>[true, false]) {
        for (final bool compact in <bool>[true, false]) {
          expect(
            homeShellBarTitleFor(
              tab,
              apple: apple,
              compact: compact,
              redesign: true,
            ),
            isNull,
            reason: '$tab apple=$apple compact=$compact：页头大字已画页名',
          );
          // 页面名本身照常下发：页头大字就靠它画这一行。
          expect(
            homeShellTitleFor(
              tab,
              apple: apple,
              compact: compact,
              redesign: true,
            ),
            isNotNull,
            reason: '$tab：页头大字的页名来自外壳下发的页面名',
          );
        }
      }
    }
  });

  test('Apple 页头大字库页：后台任务入口不进栏（退回右下 FAB）', () {
    for (final HomeTab tab in _mastheadTabs) {
      expect(
        homeBackgroundTasksHostedByChrome(
          apple: true,
          shellTitleVisible:
              homeShellBarTitleFor(
                tab,
                apple: true,
                compact: true,
                redesign: true,
              ) !=
              null,
        ),
        isFalse,
        reason: '$tab：外壳条不画时入口不能被收走',
      );
    }
  });

  test('墨水屏（无页头大字）：Apple 外壳条照常画库页页名', () {
    for (final HomeTab tab in _mastheadTabs) {
      expect(
        homeShellBarTitleFor(tab, apple: true, compact: true),
        homeShellTitleFor(tab, apple: true, compact: true),
        reason: '$tab',
      );
      expect(homeShellBarTitleFor(tab, apple: true, compact: true), isNotNull);
    }
  });

  test('非库页 tab 与页面名判据一致', () {
    for (final HomeTab tab in <HomeTab>[
      HomeTab.home,
      HomeTab.srs,
      HomeTab.settings,
      HomeTab.dictionaries,
    ]) {
      for (final bool redesign in <bool>[true, false]) {
        expect(
          homeShellBarTitleFor(
            tab,
            apple: true,
            compact: false,
            redesign: redesign,
          ),
          homeShellTitleFor(
            tab,
            apple: true,
            compact: false,
            redesign: redesign,
          ),
          reason: '$tab redesign=$redesign',
        );
      }
    }
  });
}
