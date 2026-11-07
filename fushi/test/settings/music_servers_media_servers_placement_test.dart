import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema_music.dart';
import 'package:fushi/src/settings/settings_schema_services.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/music/server/subsonic_server_config.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/test_platform_services.dart';

/// 反馈 983broef-P 后续（PR #3039 遗留、用户拍板）：音乐的服务器曲库（OpenSubsonic /
/// Apple Music / 混排开关 / 串流音质）从 设置 › 音乐 搬到 设置 › 在线服务 › 媒体服务器，
/// 与 Jellyfin / Plex / Audiobookshelf 同一节、同一种行（`_servicePage` 形态：标题 +
/// 「已配置 / 未配置」状态副标题 + 推子页）。
List<String> _ids(Iterable<SettingsSection> sections) => <String>[
  for (final SettingsSection s in sections)
    for (final SettingsItem i in s.items) i.id,
];

void main() {
  test('服务器曲库住在线服务「媒体服务器」节，紧跟 Audiobookshelf', () {
    final SettingsSection media = buildServicesDestination().sections
        .singleWhere((SettingsSection s) => s.id == 'services.media');
    final List<String> ids = _ids(<SettingsSection>[media]);
    final int abs = ids.indexOf('services.audiobookshelf_servers');
    expect(abs, greaterThanOrEqualTo(0));
    expect(ids.indexOf('services.music_servers'), abs + 1);

    final SettingsNavigationItem row =
        media.items.singleWhere(
              (SettingsItem i) => i.id == 'services.music_servers',
            )
            as SettingsNavigationItem;
    // 与同节 OPDS / Kavita / Audiobookshelf 行同形：无行首图标、状态副标题、推子页。
    expect(row.title, t.music_servers_title);
    expect(row.showIcon, isFalse);
    expect(row.subtitle, isNull);
    expect(row.subtitleBuilder, isNotNull);
    final SettingsDestination page = row.child!();
    expect(page.title, t.music_servers_title);
    expect(page.body, isNotNull, reason: '正文是 MusicServerSettingsBody');
    expect(_ids(page.sections), <String>['services.music_servers.bitrate']);
  });

  test('设置 › 音乐不再挂服务器曲库那一组（编辑面只有一处）', () {
    final SettingsDestination music = buildMusicDestination();
    final List<String> ids = _ids(music.sections);
    expect(ids, isNot(contains('music.servers')));
    expect(ids, isNot(contains('music.server_bitrate')));
    expect(
      music.sections.map((SettingsSection s) => s.title),
      isNot(contains(t.music_servers_title)),
    );
  });

  testWidgets('状态副标题：没配为「未配置」；加了 OpenSubsonic / 开了 Apple Music / '
      '混排了服务器即「已配置」', (WidgetTester tester) async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final PreferencesRepository prefs = PreferencesRepository(db);
    await tester.runAsync(prefs.loadFromDb);
    final AppModel app = AppModel(testPlatformServices())
      ..wireLocalAudioForTesting(
        prefsRepo: prefs,
        databaseDirectory: Directory.systemTemp,
      )
      ..wireDatabaseForTesting(db);
    late SettingsContext settings;
    LocaleSettings.setLocale(AppLocale.en);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appProvider.overrideWith((Ref ref) => app)],
        child: TranslationProvider(
          child: MaterialApp(
            home: Consumer(
              builder: (BuildContext context, WidgetRef ref, Widget? _) {
                settings = SettingsContext(
                  context: context,
                  appModel: app,
                  ref: ref,
                  readerSource: ReaderFushiSource.instance,
                  refresh: () {},
                );
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      ),
    );

    expect(
      musicServersSettingsStatus(settings),
      t.settings_service_not_configured,
    );

    await tester.runAsync(
      () => prefs.setMusicSubsonicServers(<SubsonicServerConfig>[
        SubsonicServerConfig(
          id: 'a',
          name: 'Navidrome',
          serverUrl: Uri.parse('https://a.example.invalid'),
          apiKey: 'k',
        ),
      ]),
    );
    expect(musicServersSettingsStatus(settings), t.settings_service_configured);

    await tester.runAsync(
      () => prefs.setMusicSubsonicServers(const <SubsonicServerConfig>[]),
    );
    await tester.runAsync(() => prefs.setMusicAppleMusicEnabled(true));
    expect(musicServersSettingsStatus(settings), t.settings_service_configured);

    await tester.runAsync(() => prefs.setMusicAppleMusicEnabled(false));
    await tester.runAsync(
      () => prefs.setMusicServerLibraryMix(<String>{'jellyfin-x'}),
    );
    expect(musicServersSettingsStatus(settings), t.settings_service_configured);

    await tester.runAsync(
      () => prefs.setMusicServerLibraryMix(const <String>{}),
    );
    expect(
      musicServersSettingsStatus(settings),
      t.settings_service_not_configured,
    );
  });
}
