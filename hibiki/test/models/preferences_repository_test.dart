import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:hibiki/src/models/audio_source_config.dart';
import 'package:hibiki/src/models/preferences_repository.dart';
import 'package:hibiki/src/utils/player/blur_options.dart';

HibikiDatabase _testDb() {
  return HibikiDatabase.forTesting(
    DatabaseConnection(NativeDatabase.memory()),
  );
}

void main() {
  late HibikiDatabase db;
  late PreferencesRepository repo;

  setUp(() async {
    db = _testDb();
    repo = PreferencesRepository(db);
    await repo.loadFromDb();
  });

  tearDown(() async {
    repo.dispose();
    await db.close();
  });

  // ── defaults ─────────────────────────────────────────────────────────

  group('defaults', () {
    test('autoSearchEnabled defaults to true', () {
      expect(repo.autoSearchEnabled, true);
    });

    test('remoteLookupEnabled defaults to false', () {
      expect(repo.remoteLookupEnabled, false);
    });

    test('isFirstTimeSetup defaults to true', () {
      expect(repo.isFirstTimeSetup, true);
    });

    test('currentHomeTabIndex defaults to 0', () {
      expect(repo.currentHomeTabIndex, 0);
    });

    test('dictionaryFontSize defaults to 16.0', () {
      expect(repo.dictionaryFontSize, 16.0);
    });

    test('popupMaxWidth defaults to 400.0', () {
      expect(repo.popupMaxWidth, 400.0);
    });

    test('searchDebounceDelay defaults to 100', () {
      expect(repo.searchDebounceDelay, 100);
    });

    test('isPlayerListeningComprehensionMode defaults to false', () {
      expect(repo.isPlayerListeningComprehensionMode, false);
    });

    test('playerHardwareAcceleration defaults to true', () {
      expect(repo.playerHardwareAcceleration, true);
    });

    test('showPlayBar defaults to true', () {
      expect(repo.showPlayBar, true);
    });

    test('savedTags defaults to empty string', () {
      expect(repo.savedTags, '');
    });

    test('lowMemoryMode defaults to false', () {
      expect(repo.lowMemoryMode, false);
    });

    test('audioSources returns default URL list', () {
      expect(repo.audioSources, PreferencesRepository.defaultAudioSources);
    });

    test('audioSourceConfigs migrates legacy URL list', () {
      expect(
        repo.audioSourceConfigs,
        <AudioSourceConfig>[
          AudioSourceConfig.hibikiRemote(),
          ...AudioSourceConfig.fromLegacyUrls(
            PreferencesRepository.defaultAudioSources,
          ),
        ],
      );
    });

    test('blurOptions returns default values', () {
      final opts = repo.blurOptions;
      expect(opts.width, 200.0);
      expect(opts.height, 200.0);
      expect(opts.left, -1.0);
      expect(opts.top, -1.0);
      expect(opts.blurRadius, 5.0);
      expect(opts.visible, false);
    });

    test('showFloatingDict defaults to false', () {
      expect(repo.showFloatingDict, false);
    });

    test('collapseDictionaries defaults to true', () {
      expect(repo.collapseDictionaries, true);
    });

    test('doubleTapSeekDuration defaults to 5000', () {
      expect(repo.doubleTapSeekDuration, 5000);
    });

    test('maximumTerms defaults to 10', () {
      expect(repo.maximumTerms, 10);
    });

    test('lastSelectedDeckName defaults to Default', () {
      expect(repo.lastSelectedDeckName, 'Default');
    });

    test('lastSelectedModel defaults to null', () {
      expect(repo.lastSelectedModel, isNull);
    });

    test('reverseNavigationBar defaults to false', () {
      expect(repo.reverseNavigationBar, false);
    });
  });

  // ── round-trip persistence ───────────────────────────────────────────

  group('round-trip persistence', () {
    test('toggleAutoSearchEnabled round-trips through DB', () async {
      expect(repo.autoSearchEnabled, true);
      repo.toggleAutoSearchEnabled();
      await Future<void>.delayed(Duration.zero);

      final repo2 = PreferencesRepository(db);
      await repo2.loadFromDb();
      expect(repo2.autoSearchEnabled, false);
      repo2.dispose();
    });

    test('setRemoteLookupEnabled round-trips through DB', () async {
      await repo.setRemoteLookupEnabled(true);

      final repo2 = PreferencesRepository(db);
      await repo2.loadFromDb();
      expect(repo2.remoteLookupEnabled, true);
      repo2.dispose();
    });

    test('setDictionaryFontSize round-trips through DB', () async {
      repo.setDictionaryFontSize(24.0);
      await Future<void>.delayed(Duration.zero);

      final repo2 = PreferencesRepository(db);
      await repo2.loadFromDb();
      expect(repo2.dictionaryFontSize, 24.0);
      repo2.dispose();
    });

    test('setBlurOptions round-trips through DB', () async {
      final opts = BlurOptions(
        width: 300,
        height: 150,
        left: 10,
        top: 20,
        color: const Color.fromRGBO(255, 128, 64, 0.5),
        blurRadius: 12.0,
        visible: true,
      );
      await repo.setBlurOptions(opts);

      final repo2 = PreferencesRepository(db);
      await repo2.loadFromDb();
      expect(repo2.blurOptions.width, 300);
      expect(repo2.blurOptions.height, 150);
      expect(repo2.blurOptions.left, 10);
      expect(repo2.blurOptions.top, 20);
      expect(repo2.blurOptions.blurRadius, 12.0);
      expect(repo2.blurOptions.visible, true);
      repo2.dispose();
    });

    test('setAudioSources persists list', () async {
      repo.setAudioSources(['https://a.com', 'https://b.com']);
      await Future<void>.delayed(Duration.zero);

      final repo2 = PreferencesRepository(db);
      await repo2.loadFromDb();
      expect(repo2.audioSources, ['https://a.com', 'https://b.com']);
      repo2.dispose();
    });

    test('setAudioSourceConfigs persists typed audio sources', () async {
      await repo.setAudioSourceConfigs(<AudioSourceConfig>[
        AudioSourceConfig.hibikiRemote(enabled: true),
        AudioSourceConfig.localAudio(
          label: 'nhk16',
          path: '/tmp/nhk16.db',
          enabled: false,
        ),
        AudioSourceConfig.remoteAudio(url: 'https://a.com/{term}'),
        AudioSourceConfig.remoteAudio(
          label: 'B',
          url: 'https://b.com/{reading}',
          enabled: false,
        ),
      ]);

      final repo2 = PreferencesRepository(db);
      await repo2.loadFromDb();
      expect(repo2.audioSourceConfigs, <AudioSourceConfig>[
        AudioSourceConfig.hibikiRemote(enabled: true),
        AudioSourceConfig.localAudio(
          label: 'nhk16',
          path: '/tmp/nhk16.db',
          enabled: false,
        ),
        AudioSourceConfig.remoteAudio(url: 'https://a.com/{term}'),
        AudioSourceConfig.remoteAudio(
          label: 'B',
          url: 'https://b.com/{reading}',
          enabled: false,
        ),
      ]);
      expect(repo2.audioSources, ['https://a.com/{term}']);
      repo2.dispose();
    });

    test('setCustomCSSForDict persists JSON map', () async {
      await repo.setCustomCSSForDict('myDict', 'body { color: red; }');
      expect(repo.getCustomCSSForDict('myDict'), 'body { color: red; }');

      final repo2 = PreferencesRepository(db);
      await repo2.loadFromDb();
      expect(repo2.getCustomCSSForDict('myDict'), 'body { color: red; }');
      repo2.dispose();
    });

    test('setGlobalDictCSS persists string', () async {
      await repo.setGlobalDictCSS('.entry { margin: 4px; }');

      final repo2 = PreferencesRepository(db);
      await repo2.loadFromDb();
      expect(repo2.globalDictCSS, '.entry { margin: 4px; }');
      repo2.dispose();
    });

    test('setCurrentHomeTabIndex persists int', () async {
      await repo.setCurrentHomeTabIndex(2);

      final repo2 = PreferencesRepository(db);
      await repo2.loadFromDb();
      expect(repo2.currentHomeTabIndex, 2);
      repo2.dispose();
    });

    test('bool toggles cycle correctly (showPlayBar)', () async {
      expect(repo.showPlayBar, true);
      repo.toggleShowPlayBar();
      await Future<void>.delayed(Duration.zero);
      expect(repo.showPlayBar, false);
      repo.toggleShowPlayBar();
      await Future<void>.delayed(Duration.zero);
      expect(repo.showPlayBar, true);
    });

    test('setLastSelectedDeck persists', () async {
      await repo.setLastSelectedDeck('MyDeck');
      final repo2 = PreferencesRepository(db);
      await repo2.loadFromDb();
      expect(repo2.lastSelectedDeckName, 'MyDeck');
      repo2.dispose();
    });

    test('setLastSelectedModelName persists', () async {
      await repo.setLastSelectedModelName('BasicModel');
      final repo2 = PreferencesRepository(db);
      await repo2.loadFromDb();
      expect(repo2.lastSelectedModel, 'BasicModel');
      repo2.dispose();
    });

    test('setMediaItemPreferredAudioIndex persists', () async {
      repo.setMediaItemPreferredAudioIndex('item-1', 3);
      await Future<void>.delayed(Duration.zero);
      expect(repo.getMediaItemPreferredAudioIndex('item-1'), 3);
    });

    test('toggleReverseNavigationBar cycles correctly', () async {
      expect(repo.reverseNavigationBar, false);
      repo.toggleReverseNavigationBar();
      await Future<void>.delayed(Duration.zero);
      expect(repo.reverseNavigationBar, true);
      repo.toggleReverseNavigationBar();
      await Future<void>.delayed(Duration.zero);
      expect(repo.reverseNavigationBar, false);
    });

    test('reverseReaderBottomBar is independent of reverseNavigationBar',
        () async {
      expect(repo.reverseReaderBottomBar, false); // 默认关
      expect(repo.reverseNavigationBar, false);

      repo.toggleReverseReaderBottomBar();
      await Future<void>.delayed(Duration.zero);
      expect(repo.reverseReaderBottomBar, true);
      expect(repo.reverseNavigationBar, false,
          reason:
              'toggling the reader bottom bar must not touch the nav-bar pref');

      repo.toggleReverseNavigationBar();
      await Future<void>.delayed(Duration.zero);
      expect(repo.reverseNavigationBar, true);
      expect(repo.reverseReaderBottomBar, true,
          reason: 'the two prefs are decoupled');
    });
  });

  // ── cache coherence ──────────────────────────────────────────────────

  group('cache coherence', () {
    test('getPref reads from cache without extra DB hit', () {
      final v1 = repo.getPref('auto_search', defaultValue: true);
      final v2 = repo.getPref('auto_search', defaultValue: true);
      expect(v1, v2);
    });

    test('setPref updates cache immediately', () async {
      await repo.setPref('test_key', 42);
      expect(repo.getPref('test_key', defaultValue: 0), 42);
    });

    test('refreshFromDb picks up externally written prefs', () async {
      // Write a known value directly to DB.
      await db.setPref('custom_key_x', PrefCodec.encode(42));
      // Cache doesn't have it yet.
      expect(repo.getPref('custom_key_x'), isNull);
      // Refresh reloads cache from DB.
      await repo.refreshFromDb();
      expect(repo.getPref('custom_key_x', defaultValue: 0), 42);
    });

    test('containsKey reports correctly', () async {
      expect(repo.containsKey('nonexistent_key'), false);
      await repo.setPref('some_key', 'val');
      expect(repo.containsKey('some_key'), true);
    });
  });

  // ── listener notifications ───────────────────────────────────────────

  group('listener notifications', () {
    test('toggleAutoSearchEnabled notifies listeners', () async {
      int count = 0;
      repo.addListener(() => count++);
      repo.toggleAutoSearchEnabled();
      await Future<void>.delayed(Duration.zero);
      expect(count, greaterThan(0));
    });

    test('setDictionaryFontSize notifies listeners', () async {
      int count = 0;
      repo.addListener(() => count++);
      repo.setDictionaryFontSize(20.0);
      await Future<void>.delayed(Duration.zero);
      expect(count, greaterThan(0));
    });

    test('setBlurOptions notifies listeners', () async {
      int count = 0;
      repo.addListener(() => count++);
      await repo.setBlurOptions(repo.blurOptions);
      expect(count, greaterThan(0));
    });

    test('refreshFromDb notifies listeners', () async {
      int count = 0;
      repo.addListener(() => count++);
      await repo.refreshFromDb();
      expect(count, greaterThan(0));
    });
  });

  // ── customDictCSS edge cases ─────────────────────────────────────────

  group('customDictCSS', () {
    test('removing CSS for a dict clears it', () async {
      await repo.setCustomCSSForDict('dict1', 'body { }');
      expect(repo.getCustomCSSForDict('dict1'), 'body { }');

      await repo.setCustomCSSForDict('dict1', '');
      expect(repo.getCustomCSSForDict('dict1'), '');
    });

    test('customDictCSS handles corrupted JSON gracefully', () async {
      await repo.setPref('custom_dict_css', 'not-json');
      expect(repo.customDictCSS, isEmpty);
    });

    test('multiple dicts have independent CSS', () async {
      await repo.setCustomCSSForDict('a', 'css-a');
      await repo.setCustomCSSForDict('b', 'css-b');
      expect(repo.getCustomCSSForDict('a'), 'css-a');
      expect(repo.getCustomCSSForDict('b'), 'css-b');
    });
  });

  // ── floatingLyricFontSize clamping ───────────────────────────────────

  group('floatingLyricFontSize', () {
    test('defaults to 20.0', () {
      expect(repo.floatingLyricFontSize, 20.0);
    });

    test('clamps below 8', () async {
      await repo.setFloatingLyricFontSize(2.0);
      expect(repo.floatingLyricFontSize, 8.0);
    });

    test('clamps above 64', () async {
      await repo.setFloatingLyricFontSize(100.0);
      expect(repo.floatingLyricFontSize, 64.0);
    });
  });
}
