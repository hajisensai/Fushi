import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/torrent/builtin_video_resource_sources.dart';
import 'package:fushi/src/media/torrent/public_video_index_provider.dart';
import 'package:fushi/src/media/torrent/nyaa_resource_provider.dart';
import 'package:fushi/src/media/torrent/torznab_client.dart';
import 'package:fushi/src/media/video/download/video_download_path_mapping.dart';
import 'package:fushi/src/media/video/subtitle/open_subtitles_client.dart';
import 'package:fushi/src/pages/implementations/video_external_provider_settings_section.dart';

class _FakeStore implements VideoExternalSettingsStore {
  _FakeStore(this.snapshot);

  final VideoExternalSettingsSnapshot snapshot;
  final List<List<TorznabIndexerConfig>> torznabWrites =
      <List<TorznabIndexerConfig>>[];
  final List<OpenSubtitlesConfig> openSubtitlesWrites = <OpenSubtitlesConfig>[];
  final List<List<VideoDownloadBackendPathMappingConfig>> mappingWrites =
      <List<VideoDownloadBackendPathMappingConfig>>[];
  final List<int?> targetSourceWrites = <int?>[];
  final List<String> languageWrites = <String>[];
  final List<String> jimakuKeyWrites = <String>[];
  final List<bool> jimakuEnabledWrites = <bool>[];
  final List<(String, bool)> builtinSourceWrites = <(String, bool)>[];

  @override
  Future<VideoExternalSettingsSnapshot> load() async => snapshot;

  @override
  Future<void> saveTorznabConfigs(List<TorznabIndexerConfig> configs) async {
    torznabWrites.add(List<TorznabIndexerConfig>.of(configs));
  }

  @override
  Future<void> saveOpenSubtitlesConfig(OpenSubtitlesConfig config) async {
    openSubtitlesWrites.add(config);
  }

  @override
  Future<void> saveJimakuApiKey(String apiKey) async {
    jimakuKeyWrites.add(apiKey);
  }

  @override
  Future<void> saveJimakuEnabled(bool enabled) async {
    jimakuEnabledWrites.add(enabled);
  }

  @override
  Future<void> saveBuiltinSourceEnabled(String sourceId, bool enabled) async {
    builtinSourceWrites.add((sourceId, enabled));
  }

  @override
  Future<void> savePathMappings(
    List<VideoDownloadBackendPathMappingConfig> mappings,
  ) async {
    mappingWrites.add(List<VideoDownloadBackendPathMappingConfig>.of(mappings));
  }

  @override
  Future<void> saveTargetSourceId(int? sourceId) async {
    targetSourceWrites.add(sourceId);
  }

  @override
  Future<void> savePreferredSubtitleLanguage(String language) async {
    languageWrites.add(language);
  }
}

Widget _harness(_FakeStore store, {bool onlySubtitleSources = false}) =>
    ProviderScope(
      child: MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(
          body: SizedBox(
            width: 560,
            child: SingleChildScrollView(
              child: VideoExternalProviderSettingsSection(
                // 同类型无 key 的重挂载会走 didUpdateWidget（不重跑 initState /
                // _load），换 store 的用例会读到上一次的 store。
                key: ValueKey<bool>(onlySubtitleSources),
                store: store,
                onlySubtitleSources: onlySubtitleSources,
              ),
            ),
          ),
        ),
      ),
    );

Finder _textField(Key key) => find.descendant(
      of: find.byKey(key),
      matching: find.byType(TextField),
    );

Future<void> _show(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
}

Future<void> _settleAutosave(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 550));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('secret fields are masked and unsafe remote HTTP is not saved',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 3200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final _FakeStore store = _FakeStore(
      VideoExternalSettingsSnapshot(
        torznabConfigs: <TorznabIndexerConfig>[
          TorznabIndexerConfig(
            id: 'main',
            name: 'Prowlarr',
            endpoint: Uri.parse('https://indexer.example/api/v1'),
            apiKey: 'tor-secret',
          ),
        ],
        openSubtitlesConfig: OpenSubtitlesConfig(
          apiKey: 'sub-secret',
          username: 'alice',
          password: 'password',
        ),
      ),
    );

    await tester.pumpWidget(_harness(store));
    await tester.pumpAndSettle();

    final TextField torznabSecret = tester.widget<TextField>(
      _textField(const ValueKey<String>('video-torznab-0-api-key')),
    );
    final TextField subtitleSecret = tester.widget<TextField>(
      _textField(const ValueKey<String>('video-opensubtitles-api-key')),
    );
    final TextField password = tester.widget<TextField>(
      _textField(const ValueKey<String>('video-opensubtitles-password')),
    );
    expect(torznabSecret.obscureText, isTrue);
    expect(subtitleSecret.obscureText, isTrue);
    expect(password.obscureText, isTrue);

    final Finder endpoint =
        find.byKey(const ValueKey<String>('video-torznab-0-endpoint'));
    await tester.enterText(endpoint, 'http://indexer.example/api/v1');
    await _settleAutosave(tester);
    expect(store.torznabWrites, isEmpty,
        reason: 'remote plain HTTP must fail closed unless explicitly enabled');

    await tester.enterText(
      endpoint,
      'https://indexer.example/api/v1?apikey=must-not-persist',
    );
    await _settleAutosave(tester);
    expect(store.torznabWrites, isEmpty,
        reason: 'credential-bearing endpoint URLs must not be persisted');

    await tester.enterText(endpoint, 'https://new-indexer.example/api/v1');
    await _settleAutosave(tester);
    expect(store.torznabWrites, isNotEmpty);
    expect(store.torznabWrites.last.single.endpoint.scheme, 'https');
    expect(store.torznabWrites.last.single.apiKey, 'tor-secret');

    final Finder subtitleEndpoint =
        find.byKey(const ValueKey<String>('video-opensubtitles-endpoint'));
    await _show(tester, subtitleEndpoint);
    await tester.enterText(subtitleEndpoint, 'https://user:secret@example.com');
    await _settleAutosave(tester);
    expect(store.openSubtitlesWrites, isEmpty,
        reason: 'credentials embedded in an endpoint must never be persisted');
  });

  testWidgets('adds Torznab and path mapping and selects managed target source',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 3600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final String localRoot = Directory.systemTemp.absolute.path;
    final _FakeStore store = _FakeStore(
      VideoExternalSettingsSnapshot(
        managedVideoSources: <ManagedVideoSourceOption>[
          ManagedVideoSourceOption(
            id: 7,
            label: 'Anime',
            rootPath: localRoot,
          ),
          ManagedVideoSourceOption(
            id: 9,
            label: 'Movies',
            rootPath: '$localRoot${Platform.pathSeparator}movies',
          ),
        ],
      ),
    );

    await tester.pumpWidget(_harness(store));
    await _settleAutosave(tester);

    await tester.tap(find.byKey(const ValueKey<String>('video-torznab-add')));
    await _settleAutosave(tester);
    await tester.enterText(
      find.byKey(const ValueKey<String>('video-torznab-0-name')),
      'Jackett',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('video-torznab-0-endpoint')),
      'https://jackett.example/api/v2.0/indexers/all/results/torznab',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('video-torznab-0-api-key')),
      'new-key',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('video-torznab-0-categories')),
      '5000,5040',
    );
    await _settleAutosave(tester);
    expect(store.torznabWrites.last.single.name, 'Jackett');
    expect(store.torznabWrites.last.single.apiKey, 'new-key');
    expect(store.torznabWrites.last.single.categories, <int>[5000, 5040]);

    final Finder mappingAdd =
        find.byKey(const ValueKey<String>('video-path-mapping-add'));
    await _show(tester, mappingAdd);
    await tester.tap(mappingAdd);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('video-path-mapping-0-profile')),
      'qb-home',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('video-path-mapping-0-remote')),
      '/downloads',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('video-path-mapping-0-local')),
      localRoot,
    );
    await _settleAutosave(tester);
    expect(store.mappingWrites.last.single.backendProfileId, 'qb-home');
    expect(store.mappingWrites.last.single.remoteRoot, '/downloads');
    expect(store.mappingWrites.last.single.localRoot, localRoot);

    final Finder target = find.byKey(
      const ValueKey<String>('video-target-source-none'),
    );
    await _show(tester, target);
    await tester.tap(target);
    await tester.pumpAndSettle();
    await tester.tap(
        find.text('Movies — $localRoot${Platform.pathSeparator}movies').last);
    await tester.pumpAndSettle();
    expect(store.targetSourceWrites.last, 9);
  });

  testWidgets('preferred subtitle language is persisted through shared default',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 3200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final _FakeStore store = _FakeStore(
      const VideoExternalSettingsSnapshot(preferredSubtitleLanguage: 'ja'),
    );

    await tester.pumpWidget(_harness(store));
    await tester.pumpAndSettle();
    final Finder language = find.byKey(
      const ValueKey<String>('video-subtitle-default-language'),
    );
    await _show(tester, language);
    await tester.tap(language);
    await tester.pumpAndSettle();
    await tester.tap(find.text('中文').last);
    await tester.pumpAndSettle();
    expect(store.languageWrites.last, 'zh');
  });

  // BUG-1712：字幕来源清单必须两家都在。Jimaku 只在设置 → 视频 → 字幕露过脸，
  // 下载页那一区只有 OpenSubtitles，用户据此以为 app 不支持 Jimaku。
  testWidgets('both subtitle providers are editable in either placement',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 3200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    for (final bool onlySubtitleSources in <bool>[false, true]) {
      final _FakeStore store = _FakeStore(
        const VideoExternalSettingsSnapshot(jimakuApiKey: 'jimaku-secret'),
      );
      await tester.pumpWidget(
        _harness(store, onlySubtitleSources: onlySubtitleSources),
      );
      await tester.pumpAndSettle();

      const ValueKey<String> jimakuKeyId =
          ValueKey<String>('video-jimaku-api-key');
      final Finder jimakuKey = find.byKey(jimakuKeyId);
      expect(
        jimakuKey,
        findsOneWidget,
        reason: 'Jimaku must be listed next to OpenSubtitles '
            '(onlySubtitleSources=$onlySubtitleSources)',
      );
      expect(
        find.byKey(const ValueKey<String>('video-opensubtitles-api-key')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('video-subtitle-default-language')),
        findsOneWidget,
      );
      expect(
        tester.widget<TextField>(_textField(jimakuKeyId)).obscureText,
        isTrue,
      );

      await _show(tester, jimakuKey);
      await tester.enterText(jimakuKey, 'typed-key');
      await _settleAutosave(tester);
      expect(store.jimakuKeyWrites.last, 'typed-key');
    }
  });

  // BUG-1712：内置 Nyaa 一直在跑（动漫），但设置里一个字都没有，用户看到的是
  // 「Torznab（空）」= 这个 app 自己没有任何来源。
  testWidgets('built-in Nyaa source is listed', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 3200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final _FakeStore store = _FakeStore(const VideoExternalSettingsSnapshot());

    await tester.pumpWidget(_harness(store));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('video-builtin-source-nyaa')),
      findsOneWidget,
    );
    expect(find.text('Nyaa'), findsOneWidget);
  });

  testWidgets(
      'every built-in source has a switch that writes through the store',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 3200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final _FakeStore store = _FakeStore(const VideoExternalSettingsSnapshot());

    await tester.pumpWidget(_harness(store));
    await tester.pumpAndSettle();

    // 表驱动：内置源全表都必须有一行开关，而不是只有当年手写的那一行 Nyaa。
    for (final BuiltinVideoResourceSource source
        in kBuiltinVideoResourceSources) {
      final Finder row =
          find.byKey(ValueKey<String>('video-builtin-source-${source.id}'));
      expect(row, findsOneWidget, reason: 'missing row for ${source.id}');
      await _show(tester, row);
      expect(
        tester.widget<SwitchListTile>(row).value,
        isTrue,
        reason: '${source.id} defaults to enabled',
      );
    }

    final Finder apibayRow = find.byKey(
      ValueKey<String>('video-builtin-source-$kApibayResourceProviderId'),
    );
    await _show(tester, apibayRow);
    await tester.tap(apibayRow);
    await tester.pumpAndSettle();

    expect(
      store.builtinSourceWrites,
      <(String, bool)>[(kApibayResourceProviderId, false)],
    );
    // 本地状态立刻翻转，不等下一次 load —— 否则开关会弹回去。
    expect(tester.widget<SwitchListTile>(apibayRow).value, isFalse);
  });

  testWidgets('a disabled built-in source renders as off',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 3200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final _FakeStore store = _FakeStore(
      const VideoExternalSettingsSnapshot(
        disabledBuiltinSourceIds: <String>{kKnabenResourceProviderId},
      ),
    );

    await tester.pumpWidget(_harness(store));
    await tester.pumpAndSettle();

    final Finder knaben = find.byKey(
      ValueKey<String>('video-builtin-source-$kKnabenResourceProviderId'),
    );
    await _show(tester, knaben);
    expect(tester.widget<SwitchListTile>(knaben).value, isFalse);
    final Finder nyaa = find.byKey(
      ValueKey<String>('video-builtin-source-$kNyaaResourceProviderId'),
    );
    await _show(tester, nyaa);
    expect(tester.widget<SwitchListTile>(nyaa).value, isTrue);
  });

  testWidgets('Jimaku has an enabled switch beside its API key, defaulting on',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 3200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // 存量用户：填了 key、从没见过这个开关。默认必须是「开」。
    final _FakeStore store = _FakeStore(
      const VideoExternalSettingsSnapshot(jimakuApiKey: 'legacy-key'),
    );

    await tester.pumpWidget(_harness(store, onlySubtitleSources: true));
    await tester.pumpAndSettle();

    final Finder jimaku =
        find.byKey(const ValueKey<String>('video-jimaku-enabled'));
    await _show(tester, jimaku);
    expect(tester.widget<SwitchListTile>(jimaku).value, isTrue);
    // 与 OpenSubtitles 并列同形：两家都在同一节里各有一个启用开关。
    expect(
      find.byKey(const ValueKey<String>('video-opensubtitles-enabled')),
      findsOneWidget,
    );

    await tester.tap(jimaku);
    await tester.pumpAndSettle();

    expect(store.jimakuEnabledWrites, <bool>[false]);
    // 关掉开关不得清空 key —— 双门控的意义就是留着 key 也能停用。
    expect(store.jimakuKeyWrites, isEmpty);
  });

  testWidgets('compact layout has no horizontal overflow',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(360, 5000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final String localRoot = Directory.systemTemp.absolute.path;
    final _FakeStore store = _FakeStore(
      VideoExternalSettingsSnapshot(
        torznabConfigs: <TorznabIndexerConfig>[
          TorznabIndexerConfig(
            id: 'narrow',
            name: 'Narrow indexer',
            endpoint: Uri.parse('https://indexer.example/torznab'),
            apiKey: 'secret',
            categories: const <int>[5000, 5040],
          ),
        ],
        openSubtitlesConfig: OpenSubtitlesConfig(apiKey: 'subtitle-secret'),
        pathMappings: <VideoDownloadBackendPathMappingConfig>[
          VideoDownloadBackendPathMappingConfig(
            backendProfileId: 'qb-profile',
            remoteRoot: '/downloads',
            localRoot: localRoot,
          ),
        ],
        managedVideoSources: <ManagedVideoSourceOption>[
          ManagedVideoSourceOption(
            id: 1,
            label: 'A very long managed video source label',
            rootPath: localRoot,
          ),
        ],
      ),
    );

    await tester.pumpWidget(_harness(store));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    for (final Element field in find.byType(TextField).evaluate()) {
      expect(
        tester.getSize(find.byWidget(field.widget)).width,
        lessThanOrEqualTo(360),
      );
    }
  });
}
