import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/media_server/media_server_browser.dart';
import 'package:fushi/src/media/video/media_server/media_server_config.dart';
import 'package:fushi/src/media/video/media_server/media_server_library.dart';
import 'package:fushi/src/sync/remote_video_client.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show RemoteVideoInfo;
import 'package:http/http.dart' as http;

import '../../../pages/media_server/fake_media_server_browser.dart';

/// 记录 `close` 的播放客户端：验证没命中的那几台服务器的现建客户端被关掉。
class _ClosableClient
    implements RemoteVideoClient, RemoteVideoClientConnections {
  int closeCalls = 0;

  @override
  void close() => closeCalls++;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _ClosableBrowser extends FakeMediaServerBrowser {
  _ClosableBrowser(String serverId) : super(serverId: serverId);

  final _ClosableClient client = _ClosableClient();

  @override
  RemoteVideoClient get playbackClient => client;
}

class _Config implements MediaServerConfig {
  _Config(this.browser);

  final MediaServerBrowser browser;
  int buildCalls = 0;

  @override
  MediaServerKind get kind => MediaServerKind.jellyfin;
  @override
  String get sourceId => browser.serverId;
  @override
  String get accountName => 'u1';
  @override
  List<String> get routeUrls => const <String>['http://srv'];
  @override
  String get effectiveServerUrl => 'http://srv';
  @override
  MediaServerConfig withActiveRoute(String url) => this;
  @override
  Map<String, Object?> toJson() => const <String, Object?>{};
  @override
  MediaServerBrowser buildBrowser({http.Client? httpClient}) {
    buildCalls++;
    return browser;
  }
}

const String _itemId = '5f0c1a2b3c4d5e6f7a8b9c0d1e2f3a4b';

/// BUG-5379：从媒体服务器浏览页直接串流（没入库）时收藏的句子，bookKey 是服务器
/// 条目 id、本机没有库行。收藏夹 / 遥控跳收藏靠 [resolveMediaServerItemLaunch] 到
/// 已登录的服务器上把它找回来。
void main() {
  test('first signed-in server that returns a playable item wins; the client '
      'of a server that does not know the id is closed', () async {
    final _ClosableBrowser other = _ClosableBrowser('jellyfin:other|u1');
    final _ClosableBrowser owner = _ClosableBrowser('jellyfin:owner|u1')
      ..details[_itemId] = const MediaServerItem(
        id: _itemId,
        name: 'Episode 3',
        type: MediaServerItemType.episode,
      );

    final ({RemoteVideoClient client, RemoteVideoInfo info})? launch =
        await resolveMediaServerItemLaunch(
          itemId: _itemId,
          loadConfigs: () async => <MediaServerConfig>[
            _Config(other),
            _Config(owner),
          ],
        );

    expect(launch, isNotNull);
    expect(identical(launch!.client, owner.client), isTrue);
    expect(launch.info.id, _itemId);
    expect(launch.info.title, 'Episode 3');
    // 起播用的详情：命中的那一次留给随后的取流（LaunchItemDetailMemo）。
    expect(owner.launchItemDetailCalls, 1);
    expect(other.launchItemDetailCalls, 1);
    expect(other.client.closeCalls, 1, reason: '没命中的现建客户端要关');
    expect(owner.client.closeCalls, 0, reason: '命中的客户端交给播放页');
  });

  test('a non-playable item (series / folder) is skipped', () async {
    final _ClosableBrowser browser = _ClosableBrowser('jellyfin:a|u1')
      ..details[_itemId] = const MediaServerItem(
        id: _itemId,
        name: 'The Show',
        type: MediaServerItemType.series,
      );

    expect(
      await resolveMediaServerItemLaunch(
        itemId: _itemId,
        loadConfigs: () async => <MediaServerConfig>[_Config(browser)],
      ),
      isNull,
    );
    expect(browser.client.closeCalls, 1);
  });

  test('no server knows the id, or none is signed in: null (caller tells the '
      'user)', () async {
    final _ClosableBrowser browser = _ClosableBrowser('jellyfin:a|u1');
    expect(
      await resolveMediaServerItemLaunch(
        itemId: _itemId,
        loadConfigs: () async => <MediaServerConfig>[_Config(browser)],
      ),
      isNull,
    );
    expect(
      await resolveMediaServerItemLaunch(
        itemId: _itemId,
        loadConfigs: () async => const <MediaServerConfig>[],
      ),
      isNull,
    );
  });

  test('an empty id never asks any server', () async {
    final _Config config = _Config(_ClosableBrowser('jellyfin:a|u1'));
    expect(
      await resolveMediaServerItemLaunch(
        itemId: '',
        loadConfigs: () async => <MediaServerConfig>[config],
      ),
      isNull,
    );
    expect(config.buildCalls, 0);
  });

  test('a failing config source is not swallowed', () async {
    await expectLater(
      resolveMediaServerItemLaunch(
        itemId: _itemId,
        loadConfigs: () async => throw StateError('prefs unreadable'),
      ),
      throwsStateError,
    );
  });
}
