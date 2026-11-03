// BUG-3569：MD3 手机上查词页顶部仍有一整行「查词」大标题。
//
// 标题由首页外壳的大标题条画（页头见到同名外壳标题就不重复画），10-18 只删了
// 查词页自己的页头，外壳这行没动。判据抽成纯函数 [homeShellTitleFor]，逐格钉住。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/home_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  test('MD3 窄窗：查词不画外壳标题（底部导航已标明）', () {
    expect(
      homeShellTitleFor(HomeTab.dictionaries, apple: false, compact: true),
      isNull,
    );
  });

  test('MD3 宽窗 / Apple：查词照常有外壳标题', () {
    expect(
      homeShellTitleFor(HomeTab.dictionaries, apple: false, compact: false),
      t.nav_lookup,
    );
    for (final bool compact in <bool>[false, true]) {
      expect(
        homeShellTitleFor(HomeTab.dictionaries, apple: true, compact: compact),
        t.nav_lookup,
        reason: 'Apple 保留 iOS 根页大标题（compact=$compact）',
      );
    }
  });

  test('叠放浮动工具区的库页不受影响：标题名仍下发给页头作同名判据', () {
    for (final HomeTab tab in <HomeTab>[
      HomeTab.books,
      HomeTab.manga,
      HomeTab.video,
      HomeTab.games,
      HomeTab.browse,
      HomeTab.web,
    ]) {
      expect(
        homeShellTitleFor(tab, apple: false, compact: true),
        isNotNull,
        reason: '$tab：窄窗本来就不叠这条标题，但页头靠它判「外壳已画同名标题」',
      );
    }
  });
}
