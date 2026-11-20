import 'package:flutter/widgets.dart';
import 'package:fushi/main.dart' as app;
import 'package:fushi/src/startup/test_root_shared_preferences.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi/src/storage/legacy_support_dir_migration.dart';
import 'package:fushi_core/fushi_core.dart' show FushiDatabase;

import 'existing_install_prefs.dart';

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
    // 已走完引导、首帧一次性提示都已处理的安装（见 existingInstallSeedPrefs）；
    // 要测某个提示本身的用例用 [seedPrefs] 覆盖对应的键。
    await db.setPrefs(existingInstallSeedPrefs());
    await db.setPrefs(seedPrefs);
  } finally {
    await db.close();
  }
  app.main();
}
