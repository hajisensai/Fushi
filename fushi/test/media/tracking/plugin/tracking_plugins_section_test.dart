import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/tracking/plugin/plugin_tracking_provider.dart';
import 'package:fushi/src/media/tracking/plugin/tracking_plugin_labels.dart';
import 'package:fushi/src/media/tracking/plugin/tracking_plugin_manager.dart';
import 'package:fushi/src/media/tracking/plugin/tracking_plugin_models.dart';
import 'package:fushi/src/media/tracking/plugin/tracking_plugins_section.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/tracking/media_tracking_repository.dart';
import 'package:fushi_engine/media/tracking/media_tracking_service.dart';
import 'package:material_ui/material_ui.dart';

import 'tracking_plugin_test_support.dart' show fakeManifest, fakeSiteId;
import 'tracking_plugins_ui_test_support.dart';

/// Settings › Media tracking › Tracking plugins on the real
/// [TrackingPluginManager] and [PluginTrackingProviders], with an in-memory
/// engine ([FakeTrackingPluginEngine]) instead of the native sandbox.
void main() {
  late Directory root;
  late FakeTrackingPluginEngine engine;
  late TrackingPluginManager manager;
  late PluginTrackingProviders providers;
  late FushiDatabase db;
  late PreferencesRepository preferences;
  late MediaTrackingService service;
  late List<Uri> openedUrls;
  Uint8List? nextPick;

  const String pluginId = 'moe.test.tracking.fake';

  setUp(() async {
    root = Directory.systemTemp.createTempSync('fushi-tracking-plugins-ui-');
    engine = FakeTrackingPluginEngine();
    manager = TrackingPluginManager(rootDir: root, engine: engine);
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    preferences = PreferencesRepository(db);
    await preferences.loadFromDb();
    service = MediaTrackingService(
      repository: MediaTrackingRepository(db),
      preferences: preferences,
      userAgent: 'test-agent',
      retryTimerFactory: (Duration delay, void Function() callback) =>
          Timer(const Duration(days: 1), () {}),
    );
    providers = PluginTrackingProviders(
      manager: manager,
      onAccountChanged: service.notifyStatusChanged,
    );
    openedUrls = <Uri>[];
    nextPick = null;
  });

  /// The manager and database were closed inside the test's fake zone.
  bool closed = false;

  tearDown(() async {
    // A failed test left them open: their futures belong to the test's fake
    // zone and would never complete if awaited here.
    if (!closed) {
      unawaited(manager.dispose());
      unawaited(db.close());
    }
    closed = false;
    service.dispose();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  /// A widget test that closes the manager and database while the fake zone
  /// still runs (see [drive]).
  void testSection(
    String description,
    Future<void> Function(WidgetTester tester) body,
  ) {
    testWidgets(description, (WidgetTester tester) async {
      await body(tester);
      await tester.pumpWidget(const SizedBox.shrink());
      await drive(tester, manager.dispose());
      await drive(tester, db.close());
      closed = true;
    });
  }

  /// Installs a package outside the UI (before the section is shown).
  Future<void> preinstall(
    WidgetTester tester,
    Map<String, Object?> manifest, {
    String? signer,
  }) async {
    final Uint8List zip = engine.package(manifest, signer: signer);
    await tester.runAsync(() async {
      await manager.install(zip, (await manager.inspect(zip)).digest);
    });
  }

  /// [pageController]: lay the section out like the settings page shell
  /// (`settings_kit_core.dart`): one page scroll controller that is also the
  /// PrimaryScrollController inherited on every platform.
  Future<void> pumpSection(
    WidgetTester tester, {
    ScrollController? pageController,
    Size size = const Size(1000, 2600),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final Widget section = TrackingPluginsSection(
      manager: manager,
      providers: providers,
      service: service,
      pickPackage: (BuildContext context) async => nextPick,
      openUrl: (Uri url) async => openedUrls.add(url),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(
          body: pageController == null
              ? SingleChildScrollView(child: section)
              : PrimaryScrollController(
                  controller: pageController,
                  automaticallyInheritForPlatforms: TargetPlatform.values
                      .toSet(),
                  child: SingleChildScrollView(
                    controller: pageController,
                    child: section,
                  ),
                ),
        ),
      ),
    );
    await settle(tester);
  }

  Finder tile(String id) => find.byKey(ValueKey<String>('tracking-plugin-$id'));

  /// Every text drawn in a plugin's tile (titles and subtitles may be rich
  /// text, so the painted text is read).
  String subtitleOf(WidgetTester tester, String id) => tester
      .widgetList<RichText>(
        find.descendant(of: tile(id), matching: find.byType(RichText)),
      )
      .map((RichText text) => text.text.toPlainText())
      .join('\n');

  /// The title of the account row (its first non-empty text).
  String accountText(WidgetTester tester, String id) => tester
      .widgetList<Text>(
        find.descendant(
          of: find.byKey(ValueKey<String>('tracking-plugin-account-$id')),
          matching: find.byType(Text),
        ),
      )
      .map((Text text) => text.data ?? '')
      .firstWhere((String text) => text.isNotEmpty, orElse: () => '');

  Future<void> tapKey(WidgetTester tester, String key) async {
    await tester.tap(find.byKey(ValueKey<String>(key)));
    await settle(tester);
  }

  Future<void> signInDirectly(WidgetTester tester, String token) async {
    await tester.runAsync(() async {
      final PluginTrackingProvider provider = providers.byPluginId(pluginId)!;
      final TrackingPluginLoginChallenge step = await provider.beginLogin(
        'token',
      );
      await provider.submitLogin(
        'token',
        session: step.session,
        action: 'ok',
        inputs: <String, String>{'token': token},
      );
    });
  }

  testSection('nothing installed: explanation, empty state, install button', (
    WidgetTester tester,
  ) async {
    await pumpSection(tester);
    expect(find.text(t.media_tracking_plugins_title), findsOneWidget);
    expect(find.text(t.media_tracking_plugins_intro_hint), findsOneWidget);
    // T1 F11 a: the trust note is about installing a file: it sits right
    // above the install button, below every installed plugin.
    expect(
      tester
          .getTopLeft(
            find.byKey(const ValueKey<String>('tracking-plugins-install-hint')),
          )
          .dy,
      greaterThan(
        tester
            .getTopLeft(
              find.byKey(const ValueKey<String>('tracking-plugins-empty')),
            )
            .dy,
      ),
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('tracking-plugins-empty')),
        matching: find.text(t.media_tracking_plugins_empty_label),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('tracking-plugins-install')),
      findsOneWidget,
    );
    expect(manager.installed, isEmpty);
  });

  testSection('install from a file: confirmation lists what the plugin may do, '
      'confirming adds a tile', (WidgetTester tester) async {
    await pumpSection(tester);
    nextPick = engine.package(fakeManifest());
    await tapKey(tester, 'tracking-plugins-install');

    expect(find.text(t.media_tracking_plugins_install_title), findsOneWidget);
    expect(find.text('Fake Site'), findsOneWidget);
    expect(
      find.text(t.media_tracking_plugins_version_label(version: '0.1.0')),
      findsOneWidget,
    );
    expect(find.text('example.org'), findsOneWidget);
    expect(
      find.text(
        '${t.media_tracking_anime} · ${t.media_tracking_manga} · '
        '${t.media_tracking_novel}',
      ),
      findsOneWidget,
    );
    expect(
      find.text(
        <String>[
          t.media_tracking_plugins_perm_network,
          t.media_tracking_plugins_perm_storage,
          t.media_tracking_plugins_perm_credentials,
        ].join('\n'),
      ),
      findsOneWidget,
    );
    expect(find.text('api.example.org'), findsOneWidget);
    expect(find.text(t.media_tracking_plugins_signer_unsigned), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('tracking-plugin-signer-changed')),
      findsNothing,
    );
    expect(
      engine.installs,
      isEmpty,
      reason: 'nothing before the user confirms',
    );

    await tester.tap(find.text(t.media_tracking_plugins_install_confirm));
    await settle(tester);

    expect(engine.installs, <String>[pluginId]);
    expect(Directory('${root.path}/$pluginId').existsSync(), isTrue);
    expect(
      find.byKey(const ValueKey<String>('tracking-plugins-empty')),
      findsNothing,
    );
    expect(tile(pluginId), findsOneWidget);
    expect(
      subtitleOf(tester, pluginId),
      contains(
        '${t.media_tracking_plugins_version_label(version: '0.1.0')} · '
        'example.org · ${t.media_tracking_plugins_state_signed_out}',
      ),
    );
    expect(
      find.text(t.media_tracking_plugins_installed_done(name: 'Fake Site')),
      findsOneWidget,
    );
    expect(
      accountText(tester, pluginId),
      t.media_tracking_plugins_account_signed_out,
    );
  });

  testSection(
    'a new signer for an installed id: Update, with the erase warning',
    (WidgetTester tester) async {
      await preinstall(tester, fakeManifest());
      await signInDirectly(tester, 't1');
      await pumpSection(tester);
      expect(
        accountText(tester, pluginId),
        t.media_tracking_plugins_account_signed_in(name: 'user-t1'),
      );

      nextPick = engine.package(
        fakeManifest(version: '0.2.0'),
        signer: 'ABCDEFGHIJKLMNOPQRSTUVWXYZ',
      );
      await tapKey(tester, 'tracking-plugins-install');

      expect(find.text(t.media_tracking_plugins_update_title), findsOneWidget);
      expect(
        find.text(
          t.media_tracking_plugins_signer_signed(key: 'ABCDEFGHIJKLMNOP…'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(
            const ValueKey<String>('tracking-plugin-signer-changed'),
          ),
          matching: find.text(t.media_tracking_plugins_signer_changed),
        ),
        findsOneWidget,
      );
      expect(find.text(t.media_tracking_plugins_install_confirm), findsNothing);

      await tester.tap(find.text(t.media_tracking_plugins_update_confirm));
      await settle(tester);

      expect(engine.cleared, <String>[pluginId], reason: 'old sign-in erased');
      expect(
        subtitleOf(tester, pluginId),
        contains(t.media_tracking_plugins_version_label(version: '0.2.0')),
      );
      expect(
        accountText(tester, pluginId),
        t.media_tracking_plugins_account_signed_out,
      );
      expect(
        find.text(t.media_tracking_plugins_updated_done(name: 'Fake Site')),
        findsOneWidget,
      );
    },
  );

  testSection('a package that is not a tracking plugin: translated snackbar', (
    WidgetTester tester,
  ) async {
    await pumpSection(tester);
    nextPick = engine.package(fakeManifest(kind: 'music'));
    await tapKey(tester, 'tracking-plugins-install');
    expect(find.text(t.media_tracking_plugins_install_title), findsNothing);
    expect(
      find.text(t.media_tracking_plugins_error_not_tracking_plugin),
      findsOneWidget,
    );
    expect(engine.installs, isEmpty);
  });

  testSection('the switch disables and re-enables the plugin', (
    WidgetTester tester,
  ) async {
    await preinstall(tester, fakeManifest());
    await pumpSection(tester);
    expect(
      find.byKey(const ValueKey<String>('tracking-plugin-account-$pluginId')),
      findsOneWidget,
    );

    await tester.tap(
      find.descendant(of: tile(pluginId), matching: find.byType(Switch)),
    );
    await settle(tester);
    expect(manager.installed.single.enabled, isFalse);
    expect(manager.installed.single.registered, isFalse);
    expect(
      subtitleOf(tester, pluginId),
      contains(t.media_tracking_plugins_state_disabled),
    );
    expect(
      find.byKey(const ValueKey<String>('tracking-plugin-account-$pluginId')),
      findsNothing,
      reason: 'no sign-in for a plugin that is off',
    );
    expect(
      File('${root.path}/.state.json').readAsStringSync(),
      contains('"$pluginId":false'),
    );

    await tester.tap(
      find.descendant(of: tile(pluginId), matching: find.byType(Switch)),
    );
    await settle(tester);
    expect(manager.installed.single.registered, isTrue);
    // T1 F11 d: on but not signed in is not "In use".
    expect(
      subtitleOf(tester, pluginId),
      contains(t.media_tracking_plugins_state_signed_out),
    );
    expect(
      subtitleOf(tester, pluginId),
      isNot(contains(t.media_tracking_plugins_state_active)),
    );
  });

  testSection('remove asks first; confirming removes the plugin', (
    WidgetTester tester,
  ) async {
    await preinstall(tester, fakeManifest());
    await pumpSection(tester);

    await tapKey(tester, 'tracking-plugin-remove-$pluginId');
    expect(
      find.text(t.media_tracking_plugins_remove_title(name: 'Fake Site')),
      findsOneWidget,
    );
    expect(find.text(t.media_tracking_plugins_remove_message), findsOneWidget);
    await tester.tap(
      find.descendant(of: find.byType(Dialog), matching: find.text(t.cancel)),
    );
    await settle(tester);
    expect(manager.installed, hasLength(1), reason: 'cancel keeps it');
    expect(Directory('${root.path}/$pluginId').existsSync(), isTrue);

    await tapKey(tester, 'tracking-plugin-remove-$pluginId');
    await tester.tap(
      find.descendant(
        of: find.byType(Dialog),
        matching: find.text(t.media_tracking_plugins_remove_action),
      ),
    );
    await settle(tester);
    expect(manager.installed, isEmpty);
    expect(Directory('${root.path}/$pluginId').existsSync(), isFalse);
    expect(engine.cleared, <String>[pluginId]);
    expect(tile(pluginId), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('tracking-plugins-empty')),
      findsOneWidget,
    );
  });

  testSection('the bundled plugin is shown as built in: it can be turned off, '
      'not removed', (WidgetTester tester) async {
    const String bundledId = 'moe.fushi.tracking.bangumi';
    await tester.runAsync(
      () => manager.ensureBundled(
        engine.package(
          fakeManifest(id: bundledId, name: 'Bangumi', siteId: 'bangumi'),
        ),
      ),
    );
    await pumpSection(tester);

    expect(
      subtitleOf(tester, bundledId),
      contains(t.media_tracking_plugins_built_in_label),
    );
    expect(
      find.byKey(const ValueKey<String>('tracking-plugin-remove-$bundledId')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('tracking-plugin-details-$bundledId')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('tracking-plugin-account-$bundledId')),
      findsOneWidget,
    );
    final Finder toggle = find.byKey(
      const ValueKey<String>('tracking-plugin-$bundledId'),
    );
    expect(toggle, findsOneWidget);
  });

  testSection('installing a package that claims a built-in site says why it '
      'is refused', (WidgetTester tester) async {
    nextPick = engine.package(
      fakeManifest(id: 'moe.evil.bangumi', siteId: 'bangumi'),
    );
    await pumpSection(tester);
    await tapKey(tester, 'tracking-plugins-install');
    expect(find.text(t.media_tracking_plugins_install_title), findsNothing);
    expect(
      find.text(t.media_tracking_plugins_error_reserved_site),
      findsOneWidget,
    );
    expect(engine.installs, isEmpty);
  });

  testSection(
    'tile states: conflict, reserved site, unusable; details read-only',
    (WidgetTester tester) async {
      await preinstall(tester, fakeManifest(id: 'a.alpha', name: 'Alpha'));
      await preinstall(tester, fakeManifest(id: 'b.beta', name: 'Beta'));
      // The installer refuses a reserved site; copied in by hand it is
      // listed but never used.
      await tester.runAsync(() async {
        final Uint8List zip = engine.package(
          fakeManifest(id: 'c.reserved', name: 'Reserved', siteId: 'mal'),
        );
        await engine.install(
          zip,
          root.path,
          (await engine.inspect(zip)).digest,
        );
      });
      Directory('${root.path}/d.broken').createSync();
      await pumpSection(tester);

      expect(
        subtitleOf(tester, 'a.alpha'),
        contains(t.media_tracking_plugins_state_signed_out),
      );
      expect(
        subtitleOf(tester, 'b.beta'),
        contains(t.media_tracking_plugins_state_conflict(name: 'Alpha')),
      );
      expect(
        subtitleOf(tester, 'c.reserved'),
        contains(t.media_tracking_plugins_state_reserved),
      );
      expect(
        subtitleOf(tester, 'd.broken'),
        contains(
          t.media_tracking_plugins_state_unusable(error: 'files do not match'),
        ),
      );
      // Only the registered one gets a sign-in row; the broken one no details.
      expect(
        find.byKey(const ValueKey<String>('tracking-plugin-account-a.alpha')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('tracking-plugin-account-b.beta')),
        findsNothing,
      );
      expect(
        find.byKey(
          const ValueKey<String>('tracking-plugin-account-c.reserved'),
        ),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey<String>('tracking-plugin-details-d.broken')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey<String>('tracking-plugin-remove-d.broken')),
        findsOneWidget,
      );

      await tapKey(tester, 'tracking-plugin-details-b.beta');
      expect(
        find.descendant(
          of: find.byType(Dialog),
          matching: find.text('api.example.org'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(Dialog),
          matching: find.text(t.media_tracking_plugins_install_confirm),
        ),
        findsNothing,
      );
      await tester.tap(find.text(t.media_tracking_close));
      await settle(tester);
      expect(find.byType(Dialog), findsNothing);
    },
  );

  testSection('sign-in: form rendered, rejected token keeps the dialog open, '
      'a good one closes it and shows the account', (
    WidgetTester tester,
  ) async {
    await preinstall(tester, fakeManifest());
    await pumpSection(tester);
    final FakeTrackingSite site = engine.siteOf(pluginId);

    await tapKey(tester, 'tracking-plugin-sign-in-$pluginId');
    expect(
      find.text(t.media_tracking_plugins_login_title(name: 'Fake Site')),
      findsOneWidget,
    );
    expect(site.loginCalls.map((Map<String, Object?> c) => c['op']), <Object?>[
      'methods',
      'begin',
    ], reason: 'one method: begun straight away');
    expect(find.text('Paste the token from your profile'), findsOneWidget);

    final Finder tokenField = find.byKey(
      const ValueKey<String>('tracking-plugin-login-field-token'),
    );
    EditableText tokenText() => tester.widget<EditableText>(
      find.descendant(of: tokenField, matching: find.byType(EditableText)),
    );
    expect(tokenText().obscureText, isTrue);
    expect(
      find.descendant(of: tokenField, matching: find.text('Token')),
      findsOneWidget,
    );
    final EditableText note = tester.widget<EditableText>(
      find.descendant(
        of: find.byKey(
          const ValueKey<String>('tracking-plugin-login-field-note'),
        ),
        matching: find.byType(EditableText),
      ),
    );
    expect(note.obscureText, isFalse);
    expect(note.maxLines, 6);
    expect(note.controller.text, 'hello', reason: 'initial value');

    // Show / hide toggle of the secret field.
    await tester.tap(find.byTooltip(t.text_field_password_show));
    await tester.pumpAndSettle();
    expect(tokenText().obscureText, isFalse);
    await tester.tap(find.byTooltip(t.text_field_password_hide));
    await tester.pumpAndSettle();
    expect(tokenText().obscureText, isTrue);

    final FilledButton? primary = tester
        .widgetList<FilledButton>(
          find.descendant(
            of: find.byKey(
              const ValueKey<String>('tracking-plugin-login-action-ok'),
            ),
            matching: find.byType(FilledButton),
          ),
        )
        .firstOrNull;
    expect(primary, isNotNull, reason: 'the primary action is a filled button');

    await tapKey(tester, 'tracking-plugin-login-open-site');
    expect(openedUrls, <Uri>[Uri.parse('https://api.example.org/token')]);

    await tester.enterText(
      find.descendant(of: tokenField, matching: find.byType(EditableText)),
      'bad',
    );
    await tapKey(tester, 'tracking-plugin-login-action-ok');
    expect(find.text('Token rejected by site'), findsOneWidget);
    expect(find.byType(Dialog), findsOneWidget);
    expect(site.token, isNull);
    expect(
      site.loginCalls.last['session'],
      's1',
      reason: 'the session of the shown step goes back',
    );
    expect(
      tester
          .widget<EditableText>(
            find.descendant(
              of: tokenField,
              matching: find.byType(EditableText),
            ),
          )
          .controller
          .text,
      isEmpty,
      reason: 'a new step starts with empty secret fields',
    );

    await tester.enterText(
      find.descendant(of: tokenField, matching: find.byType(EditableText)),
      'good',
    );
    await tapKey(tester, 'tracking-plugin-login-action-ok');
    expect(find.byType(Dialog), findsNothing);
    expect(site.token, 'good');
    expect(site.loginCalls.last['session'], 's2');
    expect(manager.accountOf(pluginId).name, 'user-good');
    expect(
      accountText(tester, pluginId),
      t.media_tracking_plugins_account_signed_in(name: 'user-good'),
    );
    expect(
      find.descendant(
        of: find.byWidgetPredicate((Widget w) => w is SnackBar),
        matching: find.text(
          t.media_tracking_plugins_signed_in_done(name: 'user-good'),
        ),
      ),
      findsOneWidget,
    );
    expect(find.text('good'), findsNothing, reason: 'the secret is not shown');
  });

  testSection(
    'sign-in: no Open site without appUrl; failed step offers a retry',
    (WidgetTester tester) async {
      await preinstall(tester, fakeManifest());
      await pumpSection(tester);
      final FakeTrackingSite site = engine.siteOf(pluginId)
        ..offerAppUrl = false;

      await tapKey(tester, 'tracking-plugin-sign-in-$pluginId');
      expect(
        find.byKey(const ValueKey<String>('tracking-plugin-login-field-token')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('tracking-plugin-login-open-site')),
        findsNothing,
      );

      await tapKey(tester, 'tracking-plugin-login-action-ok');
      expect(
        tester
            .widget<Text>(
              find.byKey(
                const ValueKey<String>('tracking-plugin-login-failed'),
              ),
            )
            .data,
        'Empty token',
      );
      expect(
        find.byKey(const ValueKey<String>('tracking-plugin-login-field-token')),
        findsNothing,
      );

      await tapKey(tester, 'tracking-plugin-login-retry');
      expect(
        site.loginCalls.where((Map<String, Object?> c) => c['op'] == 'begin'),
        hasLength(2),
      );
      expect(
        find.byKey(const ValueKey<String>('tracking-plugin-login-field-token')),
        findsOneWidget,
      );

      await tapKey(tester, 'tracking-plugin-login-close');
      expect(find.byType(Dialog), findsNothing);
      expect(
        accountText(tester, pluginId),
        t.media_tracking_plugins_account_signed_out,
      );
    },
  );

  testSection('sign-in: several methods are offered to choose from', (
    WidgetTester tester,
  ) async {
    await preinstall(tester, fakeManifest());
    await pumpSection(tester);
    final FakeTrackingSite site = engine.siteOf(pluginId)
      ..methods = <Map<String, Object?>>[
        <String, Object?>{
          'id': 'token',
          'type': 'form',
          'label': 'Paste a token',
        },
        <String, Object?>{
          'id': 'code',
          'type': 'form',
          'label': 'Enter a code',
          'description': 'From the app',
        },
      ];

    await tapKey(tester, 'tracking-plugin-sign-in-$pluginId');
    expect(find.text('Paste a token'), findsOneWidget);
    expect(find.text('Enter a code'), findsOneWidget);
    expect(find.text('From the app'), findsOneWidget);
    expect(site.loginCalls.map((Map<String, Object?> c) => c['op']), <Object?>[
      'methods',
    ]);

    await tapKey(tester, 'tracking-plugin-login-method-code');
    expect(site.loginCalls.last['op'], 'begin');
    expect(site.loginCalls.last['method'], 'code');
    expect(
      find.byKey(const ValueKey<String>('tracking-plugin-login-field-token')),
      findsOneWidget,
    );

    await tapKey(tester, 'tracking-plugin-login-methods');
    expect(find.text('Paste a token'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('tracking-plugin-login-field-token')),
      findsNothing,
    );
  });

  testSection('sign out asks first, then the account row says not signed in', (
    WidgetTester tester,
  ) async {
    await preinstall(tester, fakeManifest());
    await signInDirectly(tester, 't1');
    await pumpSection(tester);
    expect(
      accountText(tester, pluginId),
      t.media_tracking_plugins_account_signed_in(name: 'user-t1'),
    );
    expect(
      subtitleOf(tester, pluginId),
      contains(t.media_tracking_plugins_state_active),
    );

    await tapKey(tester, 'tracking-plugin-sign-out-$pluginId');
    expect(
      find.text(t.media_tracking_plugins_sign_out_title(name: 'Fake Site')),
      findsOneWidget,
    );
    await tester.tap(
      find.descendant(
        of: find.byType(Dialog),
        matching: find.text(t.media_tracking_plugins_sign_out_action),
      ),
    );
    await settle(tester);

    expect(engine.siteOf(pluginId).token, isNull);
    expect(manager.accountOf(pluginId).loggedIn, isFalse);
    expect(
      accountText(tester, pluginId),
      t.media_tracking_plugins_account_signed_out,
    );
    expect(
      find.byKey(const ValueKey<String>('tracking-plugin-sign-in-$pluginId')),
      findsOneWidget,
    );
  });

  testSection(
    'the service reporting the site unauthorized asks to sign in again',
    (WidgetTester tester) async {
      await preinstall(tester, fakeManifest());
      await signInDirectly(tester, 't1');
      service.setExtraProviders(providers.current());
      // The sync the new site starts would store "accepted": let it finish
      // before the rejection is recorded.
      await drive(tester, service.syncNow());
      await tester.runAsync(
        () => preferences.setPref(
          TrackingProviderPrefKeys.forProvider(fakeSiteId).lastSyncUnauthorized,
          true,
        ),
      );
      await pumpSection(tester);
      expect(
        accountText(tester, pluginId),
        t.media_tracking_plugins_account_rejected,
      );
      expect(
        find.byKey(const ValueKey<String>('tracking-plugin-sign-in-$pluginId')),
        findsOneWidget,
      );
    },
  );

  test(
    'error codes have their own messages; plugin text only for plugin_error',
    () {
      String text(TrackingPluginErrorCode code, [String message = 'm']) =>
          trackingPluginErrorText(TrackingPluginException(code, message));
      expect(
        text(TrackingPluginErrorCode.unauthorized),
        t.media_tracking_plugins_error_unauthorized,
      );
      expect(
        text(TrackingPluginErrorCode.rateLimited),
        t.media_tracking_plugins_error_rate_limited,
      );
      expect(
        text(TrackingPluginErrorCode.notFound),
        t.media_tracking_plugins_error_not_found,
      );
      expect(
        text(TrackingPluginErrorCode.kindMismatch),
        t.media_tracking_plugins_error_kind_mismatch,
      );
      expect(
        text(TrackingPluginErrorCode.runtimeStopped),
        t.media_tracking_plugins_error_runtime_stopped,
      );
      expect(
        text(TrackingPluginErrorCode.timeout),
        t.media_tracking_plugins_error_timeout,
      );
      expect(
        text(TrackingPluginErrorCode.invalidPackage),
        t.media_tracking_plugins_error_invalid_package,
      );
      expect(
        text(TrackingPluginErrorCode.notTrackingPlugin),
        t.media_tracking_plugins_error_not_tracking_plugin,
      );
      expect(
        text(TrackingPluginErrorCode.reservedSite),
        t.media_tracking_plugins_error_reserved_site,
      );
      expect(
        text(TrackingPluginErrorCode.pluginError, 'boom\nstack'),
        t.media_tracking_plugins_error_plugin_error(message: 'boom'),
      );
      expect(
        text(TrackingPluginErrorCode.disabled),
        t.media_tracking_plugins_error_generic,
      );
      expect(
        trackingPluginErrorText(StateError('x')),
        t.media_tracking_plugins_error_generic,
      );
    },
  );

  testSection('desktop: no scroll controller is shared by two scroll views '
      '(Scrollbar) while installing, viewing details and signing in', (
    WidgetTester tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      final ScrollController page = ScrollController();
      addTearDown(page.dispose);
      await pumpSection(
        tester,
        pageController: page,
        size: const Size(900, 500),
      );

      void expectOnePositionEach(String step) {
        for (final ScrollableState state in tester.stateList<ScrollableState>(
          find.byType(Scrollable),
        )) {
          final ScrollController? controller = state.widget.controller;
          if (controller == null) continue;
          expect(
            controller.positions.length,
            1,
            reason:
                '$step: ${state.widget.axisDirection} scrollable shares '
                'its controller',
          );
        }
        expect(tester.takeException(), isNull, reason: step);
      }

      expectOnePositionEach('settings page');
      nextPick = engine.package(fakeManifest());
      await tapKey(tester, 'tracking-plugins-install');
      expectOnePositionEach('install confirmation');
      await tester.tap(find.text(t.media_tracking_plugins_install_confirm));
      await settle(tester);
      expectOnePositionEach('installed');

      await tapKey(tester, 'tracking-plugin-details-$pluginId');
      expectOnePositionEach('details');
      await tester.tap(find.text(t.media_tracking_close));
      await settle(tester);

      await tapKey(tester, 'tracking-plugin-sign-in-$pluginId');
      expectOnePositionEach('sign-in');
      await tapKey(tester, 'tracking-plugin-login-close');
      expectOnePositionEach('after sign-in');
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testSection('sign-in: the paste button replaces the field with the trimmed '
      'clipboard; an empty clipboard says so and keeps the text', (
    WidgetTester tester,
  ) async {
    await preinstall(tester, fakeManifest());
    await pumpSection(tester);
    String? clipboard = '  pasted-token \n';
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall call) async => call.method == 'Clipboard.getData'
          ? (clipboard == null ? null : <String, Object?>{'text': clipboard})
          : null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    await tapKey(tester, 'tracking-plugin-sign-in-$pluginId');
    final Finder tokenEditable = find.descendant(
      of: find.byKey(
        const ValueKey<String>('tracking-plugin-login-field-token'),
      ),
      matching: find.byType(EditableText),
    );
    String tokenText() =>
        tester.widget<EditableText>(tokenEditable).controller.text;
    await tester.enterText(tokenEditable, 'old');

    final Finder paste = find.byKey(
      const ValueKey<String>('tracking-plugin-login-paste-token'),
    );
    expect(paste, findsOneWidget);
    expect(
      find.descendant(
        of: paste,
        matching: find.byTooltip(t.media_tracking_token_paste),
      ),
      findsOneWidget,
    );
    final SemanticsHandle semantics = tester.ensureSemantics();
    expect(find.bySemanticsLabel(t.media_tracking_token_paste), findsWidgets);
    semantics.dispose();

    await tapKey(tester, 'tracking-plugin-login-paste-token');
    expect(tokenText(), 'pasted-token');

    for (final String? empty in <String?>[null, '  \n']) {
      clipboard = empty;
      await tapKey(tester, 'tracking-plugin-login-paste-token');
      expect(tokenText(), 'pasted-token', reason: 'not cleared ($empty)');
      expect(find.text(t.media_tracking_token_paste_empty), findsOneWidget);
    }
    await tapKey(tester, 'tracking-plugin-login-close');
  });
}
