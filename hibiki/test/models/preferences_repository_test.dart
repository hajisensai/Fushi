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

    test('popupMaxHeight defaults to 360.0', () {
      expect(repo.popupMaxHeight, 360.0);
    });

    test('popupInstantScroll defaults to false (smooth/animated scroll)', () {
      // TODO-076: instant (no-animation) jump scrolling is an e-ink opt-in,
      // so a fresh / never-toggled install must default to smooth scrolling.
      expect(repo.popupInstantScroll, false);
    });

    test('popupDictionaryColumns defaults to 1 (classic single column)', () {
      // TODO-776: a fresh install renders one dictionary per row (N=1), which
      // is the untouched classic vertical layout.
      expect(repo.popupDictionaryColumns, 1);
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

    test(
        'audioSourceConfigs on a fresh install ships the default remote '
        'audio source DISABLED (TODO-083)', () {
      // 纯新装（两个 audio pref 都没写过）：内置远端音频源（manhhaoo worker）
      // 必须默认关闭，hibikiRemote 也默认关闭。任何源都不应自动启用。
      final List<AudioSourceConfig> configs = repo.audioSourceConfigs;
      expect(
        configs,
        <AudioSourceConfig>[
          AudioSourceConfig.hibikiRemote(),
          ...AudioSourceConfig.fromLegacyUrls(
            PreferencesRepository.defaultAudioSources,
          ).map((AudioSourceConfig s) => s.copyWith(enabled: false)),
        ],
      );
      // 没有任何源默认启用。
      expect(
        configs.where((AudioSourceConfig s) => s.enabled),
        isEmpty,
      );
    });

    test(
        'a configured user keeps their enabled legacy audio_sources '
        '(backward compatible, TODO-083)', () async {
      // 老用户曾保存过 legacy audio_sources（只存已启用的 URL）。即便没有
      // typed audio_source_configs，这些 URL 必须仍然 enabled，不被新装默认关。
      repo.setAudioSources(<String>[
        'https://legacy.test/?term={term}&reading={reading}',
      ]);
      // setAudioSources 是 fire-and-forget（void async）：等一个微任务让落盘完成，
      // 与本文件 'setAudioSources persists list' 用例同范式。
      await Future<void>.delayed(Duration.zero);

      final PreferencesRepository repo2 = PreferencesRepository(db);
      await repo2.loadFromDb();
      final List<AudioSourceConfig> remotes = repo2.audioSourceConfigs
          .where((AudioSourceConfig s) => s.kind == AudioSourceKind.remoteAudio)
          .toList();
      expect(remotes, hasLength(1));
      expect(
        remotes.single.url,
        'https://legacy.test/?term={term}&reading={reading}',
      );
      expect(remotes.single.enabled, isTrue);
      repo2.dispose();
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

    test('startupDefaultDictionaryTab defaults to false', () {
      expect(repo.startupDefaultDictionaryTab, false);
    });

    test('videoSubtitleListAutoScroll defaults to true (TODO-613)', () {
      // 字幕列表「自动滚动到当前播放句」默认开，与历史面板纯内存默认 true 一致。
      expect(repo.videoSubtitleListAutoScroll, true);
    });

    test('audiobookBackgroundPlay defaults to false (TODO-702 exit stops)', () {
      // 有声书退出即停是默认：新装 / 从未切过开关的用户退出阅读页就停止播放。
      expect(repo.audiobookBackgroundPlay, false);
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

    test('setPopupMaxHeight round-trips through DB', () async {
      repo.setPopupMaxHeight(560.0);
      await Future<void>.delayed(Duration.zero);

      final repo2 = PreferencesRepository(db);
      await repo2.loadFromDb();
      expect(repo2.popupMaxHeight, 560.0);
      repo2.dispose();
    });

    test('setPopupDictionaryColumns round-trips through DB', () async {
      await repo.setPopupDictionaryColumns(3);

      final repo2 = PreferencesRepository(db);
      await repo2.loadFromDb();
      expect(repo2.popupDictionaryColumns, 3);
      repo2.dispose();
    });

    test('setPopupDictionaryColumns clamps out-of-range writes to 1..4',
        () async {
      // TODO-776: an absurd column count must never reach the CSS grid. Both
      // over- and under-range writes are clamped on the way into storage.
      await repo.setPopupDictionaryColumns(99);
      expect(repo.popupDictionaryColumns, 4);

      await repo.setPopupDictionaryColumns(0);
      expect(repo.popupDictionaryColumns, 1);

      await repo.setPopupDictionaryColumns(-5);
      expect(repo.popupDictionaryColumns, 1);

      // The clamped value also survives a reload (storage holds the clamped
      // number, not the raw out-of-range input).
      await repo.setPopupDictionaryColumns(10);
      final repo2 = PreferencesRepository(db);
      await repo2.loadFromDb();
      expect(repo2.popupDictionaryColumns, 4);
      repo2.dispose();
    });

    test(
        'setPopupInstantScroll round-trips and preserves a stored true '
        '(backward compatibility after the default flip to false)', () async {
      // An existing e-ink user enabled instant scroll before the default
      // changed to false; their stored value must survive, not fall back to
      // the new default.
      await repo.setPopupInstantScroll(true);

      final repo2 = PreferencesRepository(db);
      await repo2.loadFromDb();
      expect(repo2.popupInstantScroll, true);
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

    test('setStartupDefaultDictionaryTab persists bool', () async {
      await repo.setStartupDefaultDictionaryTab(true);

      final repo2 = PreferencesRepository(db);
      await repo2.loadFromDb();
      expect(repo2.startupDefaultDictionaryTab, true);
      repo2.dispose();
    });

    test('yomitan api server prefs round-trip', () async {
      expect(repo.yomitanApiServerEnabled, false);
      expect(repo.yomitanApiPort, 19633);
      expect(repo.yomitanApiKey, '');

      await repo.setYomitanApiServerEnabled(true);
      await repo.setYomitanApiPort(19999);
      await repo.setYomitanApiKey('k');

      expect(repo.yomitanApiServerEnabled, true);
      expect(repo.yomitanApiPort, 19999);
      expect(repo.yomitanApiKey, 'k');

      final repo2 = PreferencesRepository(db);
      await repo2.loadFromDb();
      expect(repo2.yomitanApiServerEnabled, true);
      expect(repo2.yomitanApiPort, 19999);
      expect(repo2.yomitanApiKey, 'k');
      repo2.dispose();
    });

    test('texthooker prefs round-trip', () async {
      expect(repo.texthookerEnabled, false);
      expect(repo.texthookerUrls, [
        'ws://localhost:6677',
        'ws://localhost:9001',
        'ws://localhost:2333',
      ]);

      await repo.setTexthookerEnabled(true);
      await repo.setTexthookerUrls(['ws://localhost:6677']);

      expect(repo.texthookerEnabled, true);
      expect(repo.texthookerUrls, ['ws://localhost:6677']);

      // 跨实例 reload，验换行编码经 DB 字符串往返后能正确 split 回 List
      final repo2 = PreferencesRepository(db);
      await repo2.loadFromDb();
      expect(repo2.texthookerEnabled, true);
      expect(repo2.texthookerUrls, ['ws://localhost:6677']);
      repo2.dispose();
    });

    test('desktop clipboard prefs round-trip', () async {
      expect(repo.desktopClipboardEnabled, false);
      expect(
          repo.desktopClipboardWindowMode, DesktopClipboardWindowMode.normal);
      await repo.setDesktopClipboardEnabled(true);
      await repo
          .setDesktopClipboardWindowMode(DesktopClipboardWindowMode.always);
      expect(repo.desktopClipboardEnabled, true);
      expect(
          repo.desktopClipboardWindowMode, DesktopClipboardWindowMode.always);
      final repo2 = PreferencesRepository(db);
      await repo2.loadFromDb();
      expect(repo2.desktopClipboardEnabled, true);
      expect(
        repo2.desktopClipboardWindowMode,
        DesktopClipboardWindowMode.always,
      );
      repo2.dispose();
    });

    test('legacy desktop clipboard always-on-top pref maps to lookup mode',
        () async {
      await repo.setPref('desktop_clipboard_always_on_top', true);

      expect(
        repo.desktopClipboardWindowMode,
        DesktopClipboardWindowMode.lookup,
      );
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

    test('setVideoSubtitleListAutoScroll round-trips through DB (TODO-613)',
        () async {
      // 默认 true；关掉后跨实例 reload 仍为 false（落 Drift preferences、记住设置）。
      expect(repo.videoSubtitleListAutoScroll, true);
      await repo.setVideoSubtitleListAutoScroll(false);
      expect(repo.videoSubtitleListAutoScroll, false);

      final PreferencesRepository repo2 = PreferencesRepository(db);
      await repo2.loadFromDb();
      addTearDown(repo2.dispose);
      expect(repo2.videoSubtitleListAutoScroll, false,
          reason: '自动滚动开关必须跨实例 reload 记住（TODO-613）');

      // 再开回 true 也持久。
      await repo.setVideoSubtitleListAutoScroll(true);
      final PreferencesRepository repo3 = PreferencesRepository(db);
      await repo3.loadFromDb();
      addTearDown(repo3.dispose);
      expect(repo3.videoSubtitleListAutoScroll, true);
    });

    test('setAudiobookBackgroundPlay round-trips through DB (TODO-702)',
        () async {
      // 默认 false；开启后跨实例 reload 仍为 true（落 Drift preferences、记住设置）。
      expect(repo.audiobookBackgroundPlay, false);
      await repo.setAudiobookBackgroundPlay(value: true);
      expect(repo.audiobookBackgroundPlay, true);

      final PreferencesRepository repo2 = PreferencesRepository(db);
      await repo2.loadFromDb();
      addTearDown(repo2.dispose);
      expect(repo2.audiobookBackgroundPlay, true,
          reason: '后台续播开关必须跨实例 reload 记住（TODO-702）');

      // 关回 false 也持久。
      await repo.setAudiobookBackgroundPlay(value: false);
      final PreferencesRepository repo3 = PreferencesRepository(db);
      await repo3.loadFromDb();
      addTearDown(repo3.dispose);
      expect(repo3.audiobookBackgroundPlay, false);
    });
  });

  // ── jimaku per-series language memory (TODO-674) ──────────────────────

  group('jimakuPreferredLanguages (TODO-674)', () {
    test('defaults to empty map', () {
      expect(repo.jimakuPreferredLanguages, isEmpty);
    });

    test('round-trips a single series language through DB', () async {
      await repo.setJimakuPreferredLanguage('naruto', 'ja');
      expect(repo.jimakuPreferredLanguages['naruto'], 'ja');

      final PreferencesRepository repo2 = PreferencesRepository(db);
      await repo2.loadFromDb();
      addTearDown(repo2.dispose);
      expect(repo2.jimakuPreferredLanguages['naruto'], 'ja');
    });

    test('multiple series do not overwrite each other', () async {
      await repo.setJimakuPreferredLanguage('naruto', 'ja');
      await repo.setJimakuPreferredLanguage('one piece', 'zh');
      await repo.setJimakuPreferredLanguage('naruto', 'en'); // 覆盖同系列

      final PreferencesRepository repo2 = PreferencesRepository(db);
      await repo2.loadFromDb();
      addTearDown(repo2.dispose);
      final Map<String, String> langs = repo2.jimakuPreferredLanguages;
      expect(langs['naruto'], 'en');
      expect(langs['one piece'], 'zh');
      expect(langs, hasLength(2));
    });

    test('corrupted JSON falls back to empty map', () async {
      await repo.setPref('jimaku_pref_langs', 'not-json');
      expect(repo.jimakuPreferredLanguages, isEmpty);
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

  group('floatingLyricClickLookup', () {
    test('defaults to true so existing overlays keep lookup behavior', () {
      expect(repo.floatingLyricClickLookup, true);
    });

    test('round-trips through DB', () async {
      await repo.setFloatingLyricClickLookup(false);
      expect(repo.floatingLyricClickLookup, false);

      final PreferencesRepository repo2 = PreferencesRepository(db);
      await repo2.loadFromDb();
      addTearDown(repo2.dispose);
      expect(repo2.floatingLyricClickLookup, false);
    });
  });

  // TODO-370: 悬浮字幕透明度（文字 / 按钮底色），0..100%，默认 100=保持现观感。
  group('floatingLyric opacity (TODO-370)', () {
    test('text and button-bg opacity default to 100 (unchanged look)', () {
      expect(repo.floatingLyricTextOpacity, 100);
      expect(repo.floatingLyricButtonBgOpacity, 100);
    });

    test('clamps out-of-range values into 0..100', () async {
      await repo.setFloatingLyricTextOpacity(140);
      expect(repo.floatingLyricTextOpacity, 100);
      await repo.setFloatingLyricTextOpacity(-20);
      expect(repo.floatingLyricTextOpacity, 0);

      await repo.setFloatingLyricButtonBgOpacity(999);
      expect(repo.floatingLyricButtonBgOpacity, 100);
      await repo.setFloatingLyricButtonBgOpacity(-1);
      expect(repo.floatingLyricButtonBgOpacity, 0);
    });

    test('round-trip through DB', () async {
      await repo.setFloatingLyricTextOpacity(60);
      await repo.setFloatingLyricButtonBgOpacity(40);

      final PreferencesRepository repo2 = PreferencesRepository(db);
      await repo2.loadFromDb();
      addTearDown(repo2.dispose);
      expect(repo2.floatingLyricTextOpacity, 60);
      expect(repo2.floatingLyricButtonBgOpacity, 40);
    });
  });
}
