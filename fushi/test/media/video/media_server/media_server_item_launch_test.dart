import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/media_server/media_server_browser.dart';
import 'package:fushi/src/media/video/media_server/media_server_config.dart';
import 'package:fushi/src/media/video/media_server/media_server_library.dart';
import 'package:fushi/src/sync/jellyfin_video_client.dart';
import 'package:fushi/src/sync/plex_video_client.dart';
import 'package:fushi/src/sync/remote_video_client.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_engine/media/video/media_server/plex/plex_api.dart'
    show PlexApiException;
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

/// 缺详情时按真实服务器的样子回答：默认「没有这个条目」（Jellyfin 404），
/// [failure] 非 null 时抛它（连不上 / 拒绝访问……）。
class _ClosableBrowser extends FakeMediaServerBrowser {
  _ClosableBrowser(String serverId, {this.failure}) : super(serverId: serverId);

  final Exception? failure;
  final _ClosableClient client = _ClosableClient();

  @override
  RemoteVideoClient get playbackClient => client;

  @override
  Future<MediaServerItem> itemDetail(
    String itemId, {
    bool forLaunch = false,
  }) async {
    final Exception? error = failure;
    if (error != null) {
      itemDetailCalls++;
      if (forLaunch) launchItemDetailCalls++;
      throw error;
    }
    if (!details.containsKey(itemId)) {
      itemDetailCalls++;
      if (forLaunch) launchItemDetailCalls++;
      throw const JellyfinApiException(404, '/Items');
    }
    return super.itemDetail(itemId, forLaunch: forLaunch);
  }
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

/// Plex ratingKey / Emby id 是各服务器自增数字：两台服务器上同一个 id 是两部
/// 毫不相干的视频（BUG-5402 审查缺口）。
const String _itemId = '1234';

MediaServerItem _episode(String name) =>
    MediaServerItem(id: _itemId, name: name, type: MediaServerItemType.episode);

/// BUG-5402：从媒体服务器浏览页直接串流（没入库）时收藏的句子，bookKey 是服务器
/// 条目 id、本机没有库行。收藏记下来源身份（`FavoriteSentence.originSourceId`），
/// 跳回原处按它回到那一台；旧收藏挨台问，必须核对标题。
void main() {
  setUp(() => ErrorLogService.instance.clear());

  group('收藏记着来源身份：只问那一台', () {
    test('两台服务器同 id 不同片：回到收藏时那一台，另一台根本不问', () async {
      final _ClosableBrowser other = _ClosableBrowser('jellyfin:other|u1')
        ..details[_itemId] = _episode('Unrelated movie');
      final _ClosableBrowser owner = _ClosableBrowser('jellyfin:owner|u1')
        ..details[_itemId] = _episode('Episode 3');
      final _Config otherConfig = _Config(other);

      final MediaServerItemLaunchResult result =
          await resolveMediaServerItemLaunch(
            itemId: _itemId,
            originSourceId: 'jellyfin:owner|u1',
            expectedTitle: 'Episode 3',
            loadConfigs: () async => <MediaServerConfig>[
              otherConfig,
              _Config(owner),
            ],
          );

      expect(result.failure, isNull);
      expect(identical(result.launch!.client, owner.client), isTrue);
      expect(result.launch!.info.title, 'Episode 3');
      // 起播用的详情：命中的那一次留给随后的取流（LaunchItemDetailMemo）。
      expect(owner.launchItemDetailCalls, 1);
      expect(otherConfig.buildCalls, 0, reason: '别台服务器不建客户端、不问');
      expect(owner.client.closeCalls, 0, reason: '命中的客户端交给播放页');
    });

    test('服务器标题改了也照样打开（身份已精确，不再核对标题）', () async {
      final _ClosableBrowser owner = _ClosableBrowser('plex:m1|a1')
        ..details[_itemId] = _episode('Renamed on server');
      final MediaServerItemLaunchResult result =
          await resolveMediaServerItemLaunch(
            itemId: _itemId,
            originSourceId: 'plex:m1|a1',
            expectedTitle: 'Old title',
            loadConfigs: () async => <MediaServerConfig>[_Config(owner)],
          );
      expect(result.launch, isNotNull);
    });

    test('那一台没登录（退出 / 删了）：serverSignedOut，别台同 id 不顶替', () async {
      final _ClosableBrowser other = _ClosableBrowser('jellyfin:other|u1')
        ..details[_itemId] = _episode('Episode 3');
      final _Config otherConfig = _Config(other);
      final MediaServerItemLaunchResult result =
          await resolveMediaServerItemLaunch(
            itemId: _itemId,
            originSourceId: 'jellyfin:owner|u1',
            expectedTitle: 'Episode 3',
            loadConfigs: () async => <MediaServerConfig>[otherConfig],
          );
      expect(result.launch, isNull);
      expect(result.failure, MediaServerItemLaunchFailure.serverSignedOut);
      expect(otherConfig.buildCalls, 0);
    });

    test('服务器答「没有」（404 / Plex 404）：itemMissing，不记错误日志', () async {
      for (final Exception? failure in <Exception?>[
        null,
        const PlexApiException(404, '/library/metadata/1234'),
      ]) {
        final _ClosableBrowser owner = _ClosableBrowser(
          'jellyfin:owner|u1',
          failure: failure,
        );
        final MediaServerItemLaunchResult result =
            await resolveMediaServerItemLaunch(
              itemId: _itemId,
              originSourceId: 'jellyfin:owner|u1',
              expectedTitle: 'Episode 3',
              loadConfigs: () async => <MediaServerConfig>[_Config(owner)],
            );
        expect(result.failure, MediaServerItemLaunchFailure.itemMissing);
        expect(owner.client.closeCalls, 1, reason: '没命中的现建客户端要关');
      }
      expect(ErrorLogService.instance.entries, isEmpty);
    });

    test('不可播（剧 / 文件夹）：itemMissing', () async {
      final _ClosableBrowser owner = _ClosableBrowser('jellyfin:owner|u1')
        ..details[_itemId] = const MediaServerItem(
          id: _itemId,
          name: 'The Show',
          type: MediaServerItemType.series,
        );
      final MediaServerItemLaunchResult result =
          await resolveMediaServerItemLaunch(
            itemId: _itemId,
            originSourceId: 'jellyfin:owner|u1',
            expectedTitle: 'The Show',
            loadConfigs: () async => <MediaServerConfig>[_Config(owner)],
          );
      expect(result.failure, MediaServerItemLaunchFailure.itemMissing);
      expect(owner.client.closeCalls, 1);
    });

    test('连不上 / 拒绝访问：serverUnreachable，记错误日志', () async {
      for (final Exception failure in <Exception>[
        const JellyfinTransportException('connection refused'),
        const JellyfinApiException(401, '/Items'),
      ]) {
        await ErrorLogService.instance.clear();
        final _ClosableBrowser owner = _ClosableBrowser(
          'jellyfin:owner|u1',
          failure: failure,
        );
        final MediaServerItemLaunchResult result =
            await resolveMediaServerItemLaunch(
              itemId: _itemId,
              originSourceId: 'jellyfin:owner|u1',
              expectedTitle: 'Episode 3',
              loadConfigs: () async => <MediaServerConfig>[_Config(owner)],
            );
        expect(result.failure, MediaServerItemLaunchFailure.serverUnreachable);
        expect(owner.client.closeCalls, 1);
        expect(ErrorLogService.instance.entries, hasLength(1));
        expect(
          ErrorLogService.instance.entries.single.source,
          contains('MediaServerLibrary.resolveItemLaunch'),
        );
      }
    });
  });

  group('旧收藏（没记来源）：挨台问，必须核对标题', () {
    test('同 id 的别台无关视频不算命中，标题对得上的那台胜出', () async {
      final _ClosableBrowser other = _ClosableBrowser('plex:m-other|a1')
        ..details[_itemId] = _episode('Unrelated movie');
      final _ClosableBrowser owner = _ClosableBrowser('plex:m-owner|a1')
        ..details[_itemId] = _episode('Episode 3');
      final MediaServerItemLaunchResult result =
          await resolveMediaServerItemLaunch(
            itemId: _itemId,
            originSourceId: null,
            expectedTitle: ' Episode 3 ',
            loadConfigs: () async => <MediaServerConfig>[
              _Config(other),
              _Config(owner),
            ],
          );
      expect(identical(result.launch!.client, owner.client), isTrue);
      expect(other.client.closeCalls, 1, reason: '标题对不上的那台客户端要关');
      expect(owner.client.closeCalls, 0);
    });

    test('哪台的标题都对不上：itemMissing，不跳到无关视频', () async {
      final _ClosableBrowser other = _ClosableBrowser('jellyfin:a|u1')
        ..details[_itemId] = _episode('Unrelated movie');
      final MediaServerItemLaunchResult result =
          await resolveMediaServerItemLaunch(
            itemId: _itemId,
            originSourceId: null,
            expectedTitle: 'Episode 3',
            loadConfigs: () async => <MediaServerConfig>[_Config(other)],
          );
      expect(result.launch, isNull);
      expect(result.failure, MediaServerItemLaunchFailure.itemMissing);
    });

    test('没对上且有一台连不上：serverUnreachable（可能就在那台上）', () async {
      final _ClosableBrowser down = _ClosableBrowser(
        'jellyfin:down|u1',
        failure: const JellyfinTransportException('timeout'),
      );
      final _ClosableBrowser other = _ClosableBrowser('jellyfin:a|u1');
      final MediaServerItemLaunchResult result =
          await resolveMediaServerItemLaunch(
            itemId: _itemId,
            originSourceId: null,
            expectedTitle: 'Episode 3',
            loadConfigs: () async => <MediaServerConfig>[
              _Config(down),
              _Config(other),
            ],
          );
      expect(result.failure, MediaServerItemLaunchFailure.serverUnreachable);
    });

    test('一台都没登录：serverSignedOut', () async {
      final MediaServerItemLaunchResult result =
          await resolveMediaServerItemLaunch(
            itemId: _itemId,
            originSourceId: null,
            expectedTitle: 'Episode 3',
            loadConfigs: () async => const <MediaServerConfig>[],
          );
      expect(result.failure, MediaServerItemLaunchFailure.serverSignedOut);
    });
  });

  test('空 id 不问任何服务器', () async {
    final _Config config = _Config(_ClosableBrowser('jellyfin:a|u1'));
    final MediaServerItemLaunchResult result =
        await resolveMediaServerItemLaunch(
          itemId: '',
          originSourceId: null,
          expectedTitle: '',
          loadConfigs: () async => <MediaServerConfig>[config],
        );
    expect(result.failure, MediaServerItemLaunchFailure.itemMissing);
    expect(config.buildCalls, 0);
  });

  test('配置源自己抛出不吞', () async {
    await expectLater(
      resolveMediaServerItemLaunch(
        itemId: _itemId,
        originSourceId: null,
        expectedTitle: '',
        loadConfigs: () async => throw StateError('prefs unreadable'),
      ),
      throwsStateError,
    );
  });

  test('isMediaServerSourceId：认得各家 sourceIdFor，不认互联 / 在线源', () {
    expect(
      isMediaServerSourceId(
        JellyfinVideoClient.sourceIdFor(
          serverUrl: 'http://192.168.1.2:8096',
          userId: 'u1',
        ),
      ),
      isTrue,
    );
    expect(
      isMediaServerSourceId(
        PlexVideoClient.sourceIdFor(machineIdentifier: 'm1', accountId: 'a1'),
      ),
      isTrue,
    );
    expect(isMediaServerSourceId('interconnect'), isFalse);
    expect(isMediaServerSourceId('url_stream'), isFalse);
  });
}
