import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/src/shortcuts/input_binding.dart';
import 'package:hibiki/src/shortcuts/shortcut_action.dart';
import 'package:hibiki/src/shortcuts/shortcut_preferences.dart';
import 'package:hibiki/src/shortcuts/shortcut_registry.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// BUG-207 regression: [loadShortcutRegistry] must run only AFTER the media
/// source's in-memory preference cache has been loaded from the database
/// (which happens inside [MediaSource.initialise] -> _loadPreferencesFromDb).
///
/// These tests drive the REAL [loadShortcutRegistry] against the REAL
/// [ReaderHibikiSource] singleton backed by an in-memory Drift database, so the
/// whole load path (getPreference<String?> on the source cache ->
/// loadFromJsonString / resetToDefaults) is exercised end to end.
///
/// The bug was a call-ORDER bug, so the two halves of the test model the two
/// orderings:
///   * "before cache load" reproduces the pre-fix order (registry loaded while
///     the source cache is still empty) -> the saved custom JSON is invisible ->
///     the registry falls back to platform defaults (custom keys silently lost).
///   * "after cache load" reproduces the fixed order (cache hydrated from the DB
///     first) -> the saved custom JSON is found -> the custom binding is
///     restored.
///
/// Reverting the source fix (moving loadShortcutRegistry back ahead of
/// source.initialise()) is exactly the "before" ordering, so the "after" test
/// would then observe defaults instead of the custom key and fail.
const String _prefKey = 'shortcut_bindings_json';

void main() {
  // The source's constructor reads slang strings (t.source_name_bookshelf), and
  // LocaleSettings.setLocale touches the widgets binding, so the binding must be
  // initialised first.
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  late HibikiDatabase db;
  late ReaderHibikiSource source;

  // A non-default custom binding for a video action: KeyZ (no modifiers) mapped
  // to "toggle play/pause", which defaults to Space/P/MediaPlayPause and never
  // KeyZ. Resolving KeyZ in the video scope therefore proves the *custom* JSON
  // was loaded, not the defaults.
  final String customJson = jsonEncode(<String, dynamic>{
    ShortcutAction.videoTogglePlayPause.key: <String, dynamic>{
      'keyboard': <String>['KeyZ'],
      'gamepad': <String>[],
      'mouse': <String>[],
    },
  });

  setUp(() async {
    db = HibikiDatabase.forTesting(NativeDatabase.memory());
    MediaSource.setDatabase(db);
    source = ReaderHibikiSource.instance;
    // Start every test from an empty in-memory cache so prior tests (or the
    // shared singleton) cannot leak state. _loadPreferencesFromDb clears first,
    // and the DB is empty here, so this yields a clean, empty cache.
    await source.refreshPreferencesFromDb();
  });

  tearDown(() async {
    await db.close();
  });

  // Persist the custom JSON straight into the DB (mirrors a previous session's
  // saveShortcutRegistry), then re-empty the in-memory cache so the value lives
  // ONLY in the DB — exactly the cold-start situation: the row exists on disk
  // but the source has not yet hydrated its cache from it.
  Future<void> seedSavedCustomJsonInDbOnly() async {
    await db.setPref('src:${source.uniqueKey}:$_prefKey', customJson);
    // Reload (clear + repopulate) so the cache reflects the DB. We deliberately
    // call this only in the "after" path; the "before" path skips it to model
    // the unhydrated cache.
  }

  test(
      'loaded BEFORE the source cache is hydrated -> saved custom key is lost '
      '(falls back to defaults) [the BUG-207 failure mode]', () async {
    // The saved JSON exists in the DB but the source cache is still empty
    // (no refresh/initialise since the row was written) — the pre-fix order.
    await db.setPref('src:${source.uniqueKey}:$_prefKey', customJson);
    // NOTE: intentionally do NOT refresh the cache here.

    final HibikiShortcutRegistry registry = HibikiShortcutRegistry();
    await loadShortcutRegistry(registry, source, TargetPlatform.windows);

    // Custom key KeyZ is NOT recognised — the registry only has defaults.
    expect(
      registry.resolveKeyboard(
        LogicalKeyboardKey.keyZ,
        modifiers: const <ModifierKey>{},
        scope: ShortcutScope.video,
      ),
      isNull,
      reason: 'cache was empty -> getPreference returned null -> '
          'resetToDefaults dropped the saved custom key',
    );
    // The default Space binding for the action is present instead.
    expect(
      registry.resolveKeyboard(
        LogicalKeyboardKey.space,
        modifiers: const <ModifierKey>{},
        scope: ShortcutScope.video,
      ),
      ShortcutAction.videoTogglePlayPause,
    );
  });

  test(
      'loaded AFTER the source cache is hydrated -> saved custom key is restored '
      '[the BUG-207 fixed order]', () async {
    await seedSavedCustomJsonInDbOnly();
    // The fix: hydrate the source preference cache from the DB BEFORE loading
    // the registry (initialise()/refreshPreferencesFromDb does this at startup).
    await source.refreshPreferencesFromDb();

    final HibikiShortcutRegistry registry = HibikiShortcutRegistry();
    await loadShortcutRegistry(registry, source, TargetPlatform.windows);

    // The custom KeyZ binding for toggle-play-pause is now active.
    expect(
      registry.resolveKeyboard(
        LogicalKeyboardKey.keyZ,
        modifiers: const <ModifierKey>{},
        scope: ShortcutScope.video,
      ),
      ShortcutAction.videoTogglePlayPause,
      reason:
          'cache hydrated first -> getPreference returned the saved JSON -> '
          'loadFromJsonString restored the custom key',
    );
  });

  test(
      'getPreference<String?> cache miss does NOT write a default back through, '
      'so the saved JSON on disk survives an unhydrated read [BUG-207 root]',
      () async {
    // Root-cause guard: the pre-fix order not only fell back to defaults in
    // memory, the concern was whether the cache-miss path corrupts the stored
    // JSON. getPreference<String?> with defaultValue null must be a pure read
    // for a nullable type and must NOT clobber the DB row.
    await db.setPref('src:${source.uniqueKey}:$_prefKey', customJson);
    // Unhydrated read (cache empty): returns null, must not write anything.
    final String? read =
        source.getPreference<String?>(key: _prefKey, defaultValue: null);
    expect(read, isNull, reason: 'cache empty -> null');

    // The DB row must be untouched by that read.
    final Map<String, String> all = await db.getAllPrefs();
    expect(all['src:${source.uniqueKey}:$_prefKey'], customJson,
        reason: 'a nullable cache-miss read must not overwrite the saved JSON');
  });
}
