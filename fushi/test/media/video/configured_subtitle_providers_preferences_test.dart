import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/subtitle/configured_subtitle_providers.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/subtitle/open_subtitles_client.dart';
import 'package:fushi_engine/media/video/subtitle/video_subtitle_provider.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _TrackedClient extends MockClient {
  _TrackedClient()
    : super((http.Request request) async {
        fail('Provider construction must not perform HTTP: ${request.url}');
      });

  bool closed = false;

  @override
  void close() {
    closed = true;
    super.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'AJATT preference changes configured providers and skips disabled resources',
    () async {
      final FushiDatabase db = FushiDatabase.forTesting(
        NativeDatabase.memory(),
      );
      final PreferencesRepository prefs = PreferencesRepository(db);
      final Directory scratch = Directory.systemTemp.createTempSync(
        'fushi_ajatt_preference_',
      );
      final List<_TrackedClient> clients = <_TrackedClient>[];
      final List<VideoSubtitleProvider> created = <VideoSubtitleProvider>[];
      int supportRootReads = 0;
      try {
        await prefs.loadFromDb();
        // A configured neighbour must survive the AJATT toggle. All credentials
        // are synthetic; the client fails immediately if construction uses HTTP.
        await prefs.setJimakuEnabled(true);
        await prefs.setJimakuApiKey('test-jimaku-key');
        await prefs.setVideoSubtitleOpenSubtitlesConfig(
          OpenSubtitlesConfig(apiKey: '', enabled: false),
        );
        await prefs.setVideoSubtitleSubdlEnabled(false);
        expect(prefs.videoSubtitleAjattEnabled, isTrue);

        for (final bool enabled in <bool>[true, false, true]) {
          await prefs.setVideoSubtitleAjattEnabled(enabled);
          final int previousClients = clients.length;
          final int previousRoots = supportRootReads;
          final List<VideoSubtitleProvider> providers =
              await createConfiguredVideoSubtitleProviders(
                prefs: prefs,
                httpClientFactory: () async {
                  final _TrackedClient client = _TrackedClient();
                  clients.add(client);
                  return client;
                },
                supportRootProvider: () async {
                  supportRootReads++;
                  return scratch;
                },
              );
          created.addAll(providers);
          expect(
            providers.map((VideoSubtitleProvider provider) => provider.id),
            enabled ? <String>['jimaku', 'ajatt'] : <String>['jimaku'],
          );
          expect(clients.length - previousClients, enabled ? 2 : 1);
          expect(
            supportRootReads - previousRoots,
            enabled ? 1 : 0,
            reason: 'Disabled AJATT must not acquire its cache root.',
          );
          for (final VideoSubtitleProvider provider in providers) {
            provider.close();
          }
          created.clear();
          expect(
            clients.every((_TrackedClient client) => client.closed),
            isTrue,
          );
        }
      } finally {
        for (final VideoSubtitleProvider provider in created) {
          provider.close();
        }
        for (final _TrackedClient client in clients) {
          if (!client.closed) client.close();
        }
        prefs.dispose();
        await db.close();
        scratch.deleteSync(recursive: true);
      }
    },
  );
}
