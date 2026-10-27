import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/ai_web_knowledge_sites_section.dart';
import 'package:fushi/src/ops/ctl_settings_body_items.dart';
import 'package:fushi/src/ops/ctl_settings_body_media_server.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema_ai.dart';
import 'package:fushi/src/settings/settings_schema_services.dart';
import 'package:fushi/src/sync/jellyfin_settings_widget.dart';
import 'package:fushi/src/sync/jellyfin_video_client.dart';
import 'package:fushi/src/sync/plex_video_client.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/test_platform_services.dart';

/// Jellyfin / Plex / 联网资料自定义站点的 `cliList`：list 不带凭据、增删改真写穿。
void main() {
  late FushiDatabase db;
  late PreferencesRepository prefs;
  late AppModel appModel;
  late SettingsContext sc;
  late SyncRepository repo;

  SettingsCliList cliOf(Iterable<SettingsItem> items, String id) {
    final SettingsCustomItem item =
        items.singleWhere((SettingsItem i) => i.id == id) as SettingsCustomItem;
    return item.cliList!;
  }

  Iterable<SettingsItem> servicesItems() => buildServicesDestination().sections
      .expand((SettingsSection s) => s.items);

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    final Directory tempDir = Directory.systemTemp.createTempSync(
      'fushi_ms_cli_',
    );
    addTearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });
    appModel = AppModel(testPlatformServices())
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: tempDir)
      ..wireDatabaseForTesting(db);
    repo = SyncRepository(db);
  });

  tearDown(() => db.close());

  Future<void> pumpContext(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Consumer(
            builder: (BuildContext context, WidgetRef ref, _) {
              sc = SettingsContext(
                context: context,
                appModel: appModel,
                ref: ref,
                readerSource: ReaderFushiSource.instance,
                refresh: () {},
              );
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
  }

  testWidgets('jellyfin cliList: list omits token, set/rm write through', (
    WidgetTester tester,
  ) async {
    await pumpContext(tester);
    final SettingsCliList cli = cliOf(
      servicesItems(),
      'services.media_server.jellyfin',
    );
    expect(cli.add, isNotNull);
    expect(
      cli.fields
          .singleWhere((SettingsCliParam p) => p.name == 'password')
          .secret,
      isTrue,
    );
    await repo.upsertJellyfinServer(
      const JellyfinServerConfig(
        serverUrl: 'http://a.test:8096',
        username: 'u',
        userId: 'uid1',
        accessToken: 'SECRET-TOKEN',
        serverName: 'Home',
        alternateUrls: <String>['http://b.test:8096'],
      ),
    );

    final List<Map<String, Object?>> rows = await cli.list(sc);
    expect(rows, hasLength(1));
    expect(jsonEncode(rows), isNot(contains('SECRET-TOKEN')));
    expect(rows.single['serverName'], 'Home');
    expect(rows.single['alternateUrls'], <String>['http://b.test:8096']);
    final String id = rows.single['id']! as String;

    final Object? updated = await cli.update!(sc, id, <String, String>{
      'switch_route': 'http://b.test:8096',
    });
    expect(
      (updated! as Map<String, Object?>)['activeServerUrl'],
      'http://b.test:8096',
    );
    expect(
      (await repo.getJellyfinServers()).single.effectiveServerUrl,
      'http://b.test:8096',
    );

    await expectLater(
      cli.update!(sc, id, <String, String>{'switch_route': 'http://x.test'}),
      throwsArgumentError,
    );
    await expectLater(
      cli.update!(sc, id, <String, String>{
        'remove_route': 'http://a.test:8096',
      }),
      throwsArgumentError,
      reason: '登录地址是身份锚',
    );
    await cli.update!(sc, id, <String, String>{
      'remove_route': 'http://b.test:8096',
    });
    final JellyfinServerConfig after = (await repo.getJellyfinServers()).single;
    expect(after.alternateUrls, isEmpty);
    expect(after.effectiveServerUrl, 'http://a.test:8096');

    await expectLater(cli.remove!(sc, 'nope'), throwsArgumentError);
    await cli.remove!(sc, id);
    expect(await repo.getJellyfinServers(), isEmpty);
  });

  testWidgets('jellyfin sign-in rejects empty input before any network', (
    WidgetTester tester,
  ) async {
    await pumpContext(tester);
    final SettingsCliList cli = cliOf(
      servicesItems(),
      'services.media_server.jellyfin',
    );
    await expectLater(
      cli.add!(sc, <String, String>{'url': 'http://a.test'}),
      throwsArgumentError,
    );
    await expectLater(
      signInJellyfinServer(repo, url: '', username: 'u', password: 'p'),
      throwsArgumentError,
    );
  });

  testWidgets('plex cliList: list omits token, switch route and rm', (
    WidgetTester tester,
  ) async {
    await pumpContext(tester);
    final SettingsCliList cli = cliOf(
      servicesItems(),
      'services.media_server.plex',
    );
    await repo.upsertMediaServer(
      const PlexServerConfig(
        machineIdentifier: 'm1',
        token: 'PLEX-SECRET',
        clientIdentifier: 'c1',
        connections: <String>['http://p1.test:32400', 'http://p2.test:32400'],
        serverName: 'Plex Home',
        accountId: '7',
        accountName: 'me',
      ),
    );
    final List<Map<String, Object?>> rows = await cli.list(sc);
    expect(rows, hasLength(1));
    expect(jsonEncode(rows), isNot(contains('PLEX-SECRET')));
    expect(rows.single['kind'], 'plex');
    final String id = rows.single['id']! as String;

    final Object? updated = await cli.update!(sc, id, <String, String>{
      'switch_route': 'http://p2.test:32400',
    });
    expect(
      (updated! as Map<String, Object?>)['activeServerUrl'],
      'http://p2.test:32400',
    );
    await expectLater(
      cli.update!(sc, id, <String, String>{'switch_route': 'http://zz.test'}),
      throwsArgumentError,
    );
    await expectLater(
      cli.add!(sc, <String, String>{'url': 'http://p1.test'}),
      throwsArgumentError,
    );
    await cli.remove!(sc, id);
    expect(await repo.getMediaServers(), isEmpty);
  });

  testWidgets('web knowledge custom cliList: add / set / rm write through', (
    WidgetTester tester,
  ) async {
    await pumpContext(tester);
    final SettingsCliList cli = cliOf(
      buildAiDestination().sections.expand((SettingsSection s) => s.items),
      'ai.web_knowledge.custom',
    );
    expect(await cli.list(sc), isEmpty);

    await expectLater(
      cli.add!(sc, <String, String>{'label': 'x', 'endpoint': 'ftp://bad'}),
      throwsFormatException,
    );
    await expectLater(cli.add!(sc, <String, String>{}), throwsArgumentError);

    final Map<String, Object?> added =
        (await cli.add!(sc, <String, String>{
              'label': 'My Wiki',
              'endpoint': 'https://wiki.example.com/api.php',
            }))!
            as Map<String, Object?>;
    final String id = added['id']! as String;
    expect(added['label'], 'My Wiki');
    expect(added['enabled'], isTrue);
    expect(prefs.aiWebKnowledgeCustomSites.single.id, id);
    expect(prefs.aiWebKnowledgeEnabledSiteIds, contains(id));

    final Map<String, Object?> off =
        (await cli.update!(sc, id, <String, String>{'enabled': 'false'}))!
            as Map<String, Object?>;
    expect(off['enabled'], isFalse);
    expect(prefs.aiWebKnowledgeEnabledSiteIds, isNot(contains(id)));

    final Map<String, Object?> renamed =
        (await cli.update!(sc, id, <String, String>{'label': 'Renamed'}))!
            as Map<String, Object?>;
    expect(renamed['label'], 'Renamed');
    expect(renamed['endpoint'], 'https://wiki.example.com/api.php');
    await expectLater(
      cli.update!(sc, id, <String, String>{'enabled': 'maybe'}),
      throwsArgumentError,
    );
    await expectLater(
      cli.update!(sc, 'custom:0', <String, String>{}),
      throwsArgumentError,
    );

    await cli.remove!(sc, id);
    expect(prefs.aiWebKnowledgeCustomSites, isEmpty);
    expect(prefs.aiWebKnowledgeEnabledSiteIds, isNot(contains(id)));
    await expectLater(cli.remove!(sc, id), throwsArgumentError);
  });

  testWidgets('media server body page switches write through prefs', (
    WidgetTester tester,
  ) async {
    await pumpContext(tester);
    final CtlBodyPage page = buildCtlMediaServerBodyPages().single;
    final List<SettingsSwitchItem> items = page.items
        .cast<SettingsSwitchItem>()
        .toList();
    expect(items.map((SettingsSwitchItem i) => i.id), <String>[
      'services.media_server.jellyfin.show_in_library',
      'services.media_server.jellyfin.auto_list_videos',
    ]);
    expect(items[0].value(sc), isFalse);
    await items[0].onChanged(sc, true);
    expect(prefs.jellyfinShowInLibrary, isTrue);
    expect(items[1].value(sc), isTrue);
    await items[1].onChanged(sc, false);
    expect(prefs.jellyfinAutoListVideos, isFalse);
  });

  test('web knowledge helpers share the page validation', () {
    expect(
      () => buildWebKnowledgeCustomSiteOrThrow(
        id: newWebKnowledgeCustomSiteId(),
        label: '',
        endpoint: 'nope',
      ),
      throwsFormatException,
    );
  });
}
