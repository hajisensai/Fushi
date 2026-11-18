import 'package:flutter/widgets.dart';
import 'package:fushi/main.dart' as app;
import 'package:fushi/src/startup/test_root_shared_preferences.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi/src/storage/legacy_support_dir_migration.dart';
import 'package:fushi_core/fushi_core.dart' show FushiDatabase;

/// Starts the real app after marking the fixture database as an existing,
/// onboarding-complete installation.
///
/// Feature integration tests should not rely on the runtime binding type to
/// suppress first-run UI. They write the same persisted preferences as a user
/// who has completed onboarding. The dedicated clean-install test deliberately
/// calls [app.main] directly so the onboarding path remains covered.
///
/// [seedPrefs] are raw `preferences` rows (`key` → typed value such as
/// `s:material`) written before the app starts, for probes that must reproduce a
/// user's configuration (prefs read once during startup would ignore later
/// writes).
Future<void> launchFushiTestApp({
  Map<String, String> seedPrefs = const <String, String>{},
}) async {
  WidgetsFlutterBinding.ensureInitialized();
  isolateSharedPreferencesUnderTestRoot();
  await migrateLegacySupportDir();
  await recoverLegacyMacosPrefsFromSharedPreferences();
  final AppPaths paths = await AppPaths.resolve();
  final FushiDatabase db = FushiDatabase(paths.supportRoot.path);
  try {
    await db.setPrefTyped<bool>('first_time_setup', false);
    await db.setPrefTyped<bool>('onboarding_completed', true);
    // `first_time_setup = false` 让首页把这份夹具当成「升级上来的存量安装」，
    // 没选过库页布局的存量安装会在首帧弹一次「库页默认改为封面网格」提示
    // （library_layout_default_notice.dart）。提示框的 ModalScope 占住焦点，主导航
    // 的 Tab 遍历一步也到不了。夹具要表达的是「已经用过新版的安装」，所以和真实
    // 用户看过提示后一样把已处理标记落下；要测提示本身的用例用 [seedPrefs] 覆盖
    // 成 `b:false`。
    await db.setPrefTyped<bool>('library_layout_default_notice_handled', true);
    await db.setPrefs(seedPrefs);
  } finally {
    await db.close();
  }
  app.main();
}
