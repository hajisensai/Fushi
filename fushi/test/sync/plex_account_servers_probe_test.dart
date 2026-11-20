// savePlexAccountServers（gap-remote-6）：账号下多台服务器的连接探测同时进行，
// 每台仍取排名最靠前的可达地址，落库保持 plex.tv 给出的顺序。假 plex.tv 走
// MockClient，探测函数用 Completer 模拟「挂着不回」。

import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/plex_settings_widget.dart';
import 'package:fushi/src/sync/plex_video_client.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/media_server/plex/plex_api.dart';
import 'package:fushi_engine/media/video/media_server/plex/plex_tv_auth.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response _json(Object body, [int status = 200]) =>
    http.Response.bytes(utf8.encode(jsonEncode(body)), status);

Map<String, Object?> _server(String name, String mid) => <String, Object?>{
  'name': name,
  'provides': 'server',
  'clientIdentifier': mid,
  'accessToken': 'token-$mid',
  'connections': <Object?>[
    <String, Object?>{'uri': 'https://$mid.relay', 'relay': true},
    <String, Object?>{'uri': 'https://$mid.wan', 'local': false},
    <String, Object?>{'uri': 'http://$mid.lan-a', 'local': true},
    <String, Object?>{'uri': 'http://$mid.lan-b', 'local': true},
  ],
};

void main() {
  test('多台服务器同时探测；各取排名最靠前的可达地址；按 plex.tv 顺序落库', () async {
    final FushiDatabase db = FushiDatabase.forTesting(
      DatabaseConnection(NativeDatabase.memory()),
    );
    addTearDown(db.close);
    final SyncRepository repo = SyncRepository(db);
    const PlexClientInfo info = PlexClientInfo(clientIdentifier: 'client-uuid');
    final PlexTvApi tv = PlexTvApi(
      clientInfo: info,
      client: MockClient((http.Request req) async {
        if (req.url.host == 'plex.tv' && req.url.path == '/api/v2/user') {
          return _json(<String, Object?>{'id': 42, 'username': 'carol'});
        }
        if (req.url.host == 'clients.plex.tv') {
          return _json(<Object?>[_server('A', 'mid-a'), _server('B', 'mid-b')]);
        }
        return http.Response('', 404);
      }),
    );
    addTearDown(tv.close);

    final Map<String, Completer<bool>> pending = <String, Completer<bool>>{};
    final List<(String, String)> probed = <(String, String)>[];
    List<PlexServerConfig>? saved;
    final Future<void> run =
        savePlexAccountServers(
          repo,
          tv: tv,
          accountToken: 'acct-token',
          info: info,
          probe: (String uri, String machineIdentifier) {
            probed.add((uri, machineIdentifier));
            return (pending[uri] = Completer<bool>()).future;
          },
        ).then((List<PlexServerConfig> configs) {
          saved = configs;
        });

    // 两台 × 四条连接全部已发起，没有哪一条在等别的。
    await pumpEventQueue();
    expect(pending.keys.toSet(), <String>{
      for (final String mid in <String>['mid-a', 'mid-b']) ...<String>[
        'http://$mid.lan-a',
        'http://$mid.lan-b',
        'https://$mid.wan',
        'https://$mid.relay',
      ],
    });
    // 每台核对自己的 machineIdentifier（探测拿不到 token，见 BUG-4997）。
    expect(probed.every(((String, String) p) => p.$1.contains(p.$2)), isTrue);

    // 不在家：局域网地址都不通；B 的公网先回，A 的 relay 先回。
    pending['https://mid-b.wan']!.complete(true);
    pending['https://mid-a.relay']!.complete(true);
    await pumpEventQueue();
    expect(saved, isNull, reason: '排在前面的局域网地址还没出结果');

    for (final String mid in <String>['mid-a', 'mid-b']) {
      pending['http://$mid.lan-a']!.completeError(TimeoutException('probe'));
      pending['http://$mid.lan-b']!.complete(false);
    }
    await pumpEventQueue();
    expect(saved, isNull, reason: 'A 的公网地址排在 relay 前面，要等它出结果');
    pending['https://mid-a.wan']!.complete(false);
    await run;

    expect(saved!.map((PlexServerConfig c) => c.machineIdentifier), <String>[
      'mid-a',
      'mid-b',
    ]);
    expect(saved![0].activeServerUrl, 'https://mid-a.relay');
    expect(saved![1].activeServerUrl, 'https://mid-b.wan');
    expect(saved![0].accountName, 'carol');
    // 落库的是各台自己的 token。
    expect(saved![0].token, 'token-mid-a');
    expect(saved![1].token, 'token-mid-b');
    expect(saved![0].connections, <String>[
      'http://mid-a.lan-a',
      'http://mid-a.lan-b',
      'https://mid-a.wan',
      'https://mid-a.relay',
    ]);
    expect(await repo.getMediaServers(), hasLength(2));
  });
}
