import 'package:flutter/widgets.dart';
import 'package:fushi/main.dart' as app;
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
Future<void> launchFushiTestApp() async {
  WidgetsFlutterBinding.ensureInitialized();
  await migrateLegacySupportDir();
  await recoverLegacyMacosPrefsFromSharedPreferences();
  final AppPaths paths = await AppPaths.resolve();
  final FushiDatabase db = FushiDatabase(paths.supportRoot.path);
  try {
    await db.setPrefTyped<bool>('first_time_setup', false);
    await db.setPrefTyped<bool>('onboarding_completed', true);
  } finally {
    await db.close();
  }
  app.main();
}
