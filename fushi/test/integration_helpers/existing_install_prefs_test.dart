import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/library_layout_default_notice.dart'
    show LibraryLayoutDefaultNoticeDecision, decideLibraryLayoutDefaultNotice;
import 'package:fushi/src/pages/implementations/shell_layout_choice_dialog.dart'
    show shouldShowShellLayoutChoice;
import 'package:fushi/src/utils/adaptive/shell_style.dart'
    show ShellLayoutInstallDefault;
import 'package:fushi_core/fushi_core.dart' show PrefCodec;

import '../../integration_test/support/existing_install_prefs.dart';

/// 集成测试夹具（[existingInstallSeedPrefs]）必须让首页首帧的一次性模态框一个都
/// 不弹：框的 ModalScope 会占住焦点，appSmoke 的 Tab 遍历只在框内循环、到不了
/// 主导航（#3515 加了「选一种库页布局」框而夹具没记已处理，windows / macos
/// appSmoke 因此红）。判定输入全部取夹具真实写入的编码值。
void main() {
  final Map<String, String> seed = existingInstallSeedPrefs();

  T read<T>(String key, T fallback) {
    final String? raw = seed[key];
    expect(raw, isNotNull, reason: 'fixture must seed `$key`');
    return PrefCodec.decode<T>(raw!, fallback);
  }

  test('fixture is an onboarded existing install', () {
    expect(read<bool>('first_time_setup', true), isFalse);
    expect(read<bool>('onboarding_completed', false), isTrue);
  });

  test('shell layout choice dialog is already settled and never shows', () {
    final ShellLayoutInstallDefault? settled =
        ShellLayoutInstallDefault.fromPref(
          read<String>(ShellLayoutInstallDefault.prefKey, ''),
        );
    // 非 null = ThemeNotifier 启动时不再重判（重判会因 first_time_setup 已在
    // 而落成 upgradeChoicePending）。
    expect(settled, isNotNull);
    expect(
      shouldShowShellLayoutChoice(
        pending: settled!.choicePending,
        redesignActive: true,
      ),
      isFalse,
    );
  });

  test('library layout default notice is already handled', () {
    expect(
      decideLibraryLayoutDefaultNotice(
        handled: read<bool>('library_layout_default_notice_handled', false),
        freshInstall: read<bool>('first_time_setup', true),
        layoutChosen: false,
        layoutActive: true,
      ),
      LibraryLayoutDefaultNoticeDecision.none,
    );
  });
}
