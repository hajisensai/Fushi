import 'dart:async';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/sync/sync_settings_schema.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/test_platform_services.dart';

// Real credential form + Drift save; hold only the URL preference DELETE.
// The URL stays empty so the probe performs validation without network IO.
class _HeldUrlSave extends QueryInterceptor {
  final Completer<void> entered = Completer<void>();
  final Completer<void> release = Completer<void>();
  bool armed = false;
  int heldWrites = 0;

  @override
  Future<int> runDelete(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    if (armed &&
        statement.toLowerCase().contains('preferences') &&
        args.contains('sync_webdav_url')) {
      heldWrites++;
      if (!entered.isCompleted) entered.complete();
      await release.future;
    }
    return executor.runDelete(statement, args);
  }
}

SettingsCustomItem _webDavItem() {
  final SettingsNavigationItem serverPage = buildSyncBackupDestination()
      .sections
      .expand((SettingsSection section) => section.items)
      .whereType<SettingsNavigationItem>()
      .singleWhere(
        (SettingsNavigationItem item) => item.id == 'sync.server_settings',
      );
  return serverPage.child!().sections
      .expand((SettingsSection section) => section.items)
      .whereType<SettingsCustomItem>()
      .singleWhere(
        (SettingsCustomItem item) => item.id == 'sync.webdav_config',
      );
}

void main() {
  for (final bool leave in <bool>[false, true]) {
    testWidgets(
      leave
          ? 'leaving credential form during save cancels the UI continuation'
          : 'control: mounted credential form completes the empty-URL validation',
      (WidgetTester tester) async {
        final _HeldUrlSave held = _HeldUrlSave();
        final FushiDatabase db = FushiDatabase.forTesting(
          NativeDatabase.memory().interceptWith(held),
        );
        await db.customSelect('SELECT 1').get();
        final AppModel app = AppModel(testPlatformServices())
          ..wireDatabaseForTesting(db);
        Object? operationError;
        try {
          final SettingsCustomItem item = _webDavItem();
          await tester.pumpWidget(
            ProviderScope(
              child: TranslationProvider(
                child: MaterialApp(
                  home: Scaffold(
                    body: Consumer(
                      builder:
                          (BuildContext context, WidgetRef ref, Widget? _) =>
                              item.builder(
                                SettingsContext(
                                  context: context,
                                  appModel: app,
                                  ref: ref,
                                  readerSource: ReaderFushiSource.instance,
                                  refresh: () {},
                                ),
                              ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final FushiFilledButton button = tester.widget<FushiFilledButton>(
            find.byKey(const ValueKey<String>('test')),
          );
          final Future<void> Function() onPressed =
              button.onPressed! as Future<void> Function();
          held.armed = true;
          // Capture the Future from the actual onPressed tear-off so a thrown
          // async lifecycle error can be asserted without leaking to the zone.
          final Future<void> operation = onPressed().then<void>(
            (_) {},
            onError: (Object error, StackTrace stack) {
              operationError = error;
            },
          );
          await tester.pump();
          await held.entered.future;
          expect(find.byKey(const ValueKey<String>('testing')), findsOneWidget);
          await onPressed();
          expect(
            held.heldWrites,
            1,
            reason: 'a stale callback cannot start a second save/probe',
          );
          if (leave) {
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.pumpAndSettle();
          }
          held.release.complete();
          await operation;
          debugPrint('round8 sync probe leave=$leave error=$operationError');
        } finally {
          if (!held.release.isCompleted) held.release.complete();
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
          await db.close();
        }
        expect(operationError, isNull);
      },
    );
  }
}
