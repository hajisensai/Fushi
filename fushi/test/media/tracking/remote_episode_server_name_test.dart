import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/jellyfin_video_client.dart';
import 'package:fushi_engine/media/tracking/remote_anime_link.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A remembered media server episode carries the server's own name, never
/// its address: [JellyfinVideoClient.displayName] falls back to the host,
/// and the Tracking page showed that (a LAN IP) next to the row.
void main() {
  JellyfinVideoClient client({String? serverName}) => JellyfinVideoClient(
    api: JellyfinApi(
      serverUrl: 'http://media.example:8096',
      accessToken: 'test',
      client: MockClient(
        (http.Request request) async => http.Response(
          jsonEncode(<String, Object?>{
            'Id': 'm1',
            'Name': 'A Film',
            'Type': 'Movie',
            'ProviderIds': <String, String>{},
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        ),
      ),
    ),
    userId: 'u1',
    serverName: serverName,
  );

  test('no saved server name: no name, and never the host', () async {
    final RemoteAnimeEpisode? episode = await client()
        .remoteVideoTrackingEpisode('m1');
    expect(episode, isNotNull);
    expect(episode!.serverName, '');
  });

  test('remoteServerShownName keeps names and drops addresses', () {
    for (final String name in <String>['Living room', 'nas', 'Home server 2']) {
      expect(remoteServerShownName(name), name, reason: name);
    }
    for (final String address in <String>[
      '',
      '  ',
      '192.0.2.10',
      '198.51.100.7:8096',
      'media.example',
      'nas.local',
      'jellyfin.example.org:443',
      'http://media.example:8096',
      'localhost',
      '[fe80::1]',
      'fe80::1',
    ]) {
      expect(remoteServerShownName(address), '', reason: address);
    }
  });

  test('a saved server name wins', () async {
    final RemoteAnimeEpisode? episode = await client(
      serverName: 'Living room',
    ).remoteVideoTrackingEpisode('m1');
    expect(episode!.serverName, 'Living room');
  });
}
