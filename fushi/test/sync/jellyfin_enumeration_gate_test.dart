// BUG-1891「Emby 一添加进去就开始刮削、卡死、封号」的止血阀三件套（真 DB + 真缓存）。
//
// **这不是刮削**：Jellyfin/Emby 条目根本不进任何元数据刮削管线（不是 MediaSources
// 行，本地 sidecar sweep 明确排除 http/https 路径，远端条目只渲染成占位卡、不落
// VideoBooks）。真实来源是「一进视频页就对整台服务器做全库递归枚举」，在几十万条目
// 的公共 Emby 服上，观感与服务器负载与刮削完全一致。
//
// 本文件锁住三条止血阀里落在数据层的两条：
//  [A] `jellyfin_auto_list_videos` 偏好：默认 true（小库用户零感知，
//      Never break userspace），关掉后消费端不取数；
//  [B] `JellyfinServerConfig.libraryIds`：**每服务器**的库点名（库 id 是服务器
//      GUID，所以落在服务器配置 JSON 里，登出随键一起删，不进全局偏好表）；
//  [C] `RemoteLibraryCache.peek`：只读缓存不取数——关掉自动列出后上一次手动刷新
//      的清单还得留在屏幕上，否则切一次 tab 卡片全没了，比自动枚举还糟。

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/models/preference_keys.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/home_video_page.dart'
    show shouldFetchRemoteVideoList;
import 'package:fushi/src/sync/jellyfin_video_client.dart';
import 'package:fushi/src/sync/remote_library_cache.dart';
import 'package:fushi/src/sync/sync_repository.dart';

void main() {
  late FushiDatabase db;
  late PreferencesRepository repo;

  setUp(() async {
    db = FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));
    repo = PreferencesRepository(db);
    await repo.loadFromDb();
  });

  tearDown(() async {
    repo.dispose();
    await db.close();
  });

  group('[A] 自动列出条目开关', () {
    test('键已登记进 kKnownPreferenceKeys（守卫要求）', () {
      expect(kKnownPreferenceKeys, contains('jellyfin_auto_list_videos'));
    });

    test('默认 true：绝大多数用户是自建小库，改默认等于把所有人的远端卡关掉', () {
      expect(repo.jellyfinAutoListVideos, isTrue);
    });

    test('写入的值原样读回并通知监听者', () async {
      int notified = 0;
      void listener() => notified++;
      repo.addListener(listener);
      addTearDown(() => repo.removeListener(listener));

      await repo.setJellyfinAutoListVideos(false);
      expect(repo.jellyfinAutoListVideos, isFalse);
      expect(notified, greaterThan(0), reason: '视频页订阅 prefsRepo 才能在翻转后重取/重渲染');

      await repo.setJellyfinAutoListVideos(true);
      expect(repo.jellyfinAutoListVideos, isTrue);
    });
  });

  group('[B] 每服务器的媒体库点名', () {
    test('libraryIds 随服务器配置整条落 prefs 并原样读回', () async {
      final SyncRepository sync = SyncRepository(db);
      await sync.setJellyfinServer(const JellyfinServerConfig(
        serverUrl: 'http://nas:8096',
        username: 'u',
        userId: 'u1',
        accessToken: 'tok',
        libraryIds: <String>['lib-anime', 'lib-movies'],
      ));

      final JellyfinServerConfig? back = await sync.getJellyfinServer();
      expect(back!.libraryIds, <String>['lib-anime', 'lib-movies']);
      expect(back.buildClient().libraryIds, <String>['lib-anime', 'lib-movies'],
          reason: '配置里点了名，client 却照旧整库递归 = 设置形同虚设');
    });

    test('旧配置（无 libraryIds 字段）读成空 = 全部视频库，老用户行为不变', () async {
      final SyncRepository sync = SyncRepository(db);
      await sync.setJellyfinServer(const JellyfinServerConfig(
        serverUrl: 'http://nas:8096',
        username: 'u',
        userId: 'u1',
        accessToken: 'tok',
      ));
      final JellyfinServerConfig? back = await sync.getJellyfinServer();
      expect(back!.libraryIds, isEmpty);
      // 空集不该被写进 JSON——旧端读到未知键不会炸，但没必要留噪音。
      expect(back.toJson().containsKey('libraryIds'), isFalse);
    });

    test('copyWithLibraryIds 只换库、不动凭据', () {
      const JellyfinServerConfig base = JellyfinServerConfig(
        serverUrl: 'http://nas:8096',
        username: 'u',
        userId: 'u1',
        accessToken: 'tok',
        serverName: 'NAS',
      );
      final JellyfinServerConfig next = base.copyWithLibraryIds(<String>['a']);
      expect(next.libraryIds, <String>['a']);
      expect(next.accessToken, 'tok');
      expect(next.userId, 'u1');
      expect(next.serverName, 'NAS');
    });

    test('脏 JSON 里的非字符串 / 空串库 id 被丢掉，不会拼出空 ParentId', () {
      final JellyfinServerConfig? c =
          JellyfinServerConfig.fromJson(<String, dynamic>{
        'serverUrl': 'http://nas:8096',
        'userId': 'u1',
        'accessToken': 'tok',
        'libraryIds': <Object?>['ok', '', 42, null],
      });
      expect(c!.libraryIds, <String>['ok']);
    });
  });

  group('[C] 只读缓存不取数', () {
    test('peek 命中槽里最后一次成功的值，且不触发任何取数', () async {
      final RemoteLibraryCache cache = RemoteLibraryCache();
      int fetches = 0;
      await cache.read<List<String>>(
        sourceId: 'jellyfin:http://nas:8096|u1',
        key: RemoteLibraryCacheKeys.videos,
        fetch: () async {
          fetches++;
          return <String>['a'];
        },
      );
      expect(fetches, 1);

      final List<String>? peeked = cache.peek<List<String>>(
        sourceId: 'jellyfin:http://nas:8096|u1',
        key: RemoteLibraryCacheKeys.videos,
      );
      expect(peeked, <String>['a']);
      expect(fetches, 1, reason: 'peek 是纯读——关掉自动列出后进页面必须零请求');
    });

    test('peek 不看 TTL：过了新鲜期照样把上一次的清单交出来', () async {
      int now = 0;
      final RemoteLibraryCache cache = RemoteLibraryCache(nowMs: () => now);
      await cache.read<List<String>>(
        sourceId: 's',
        key: 'videos',
        fetch: () async => <String>['a'],
      );
      now = 10 * 60 * 1000; // 远超默认 60s TTL
      expect(cache.isFresh('s', 'videos'), isFalse);
      expect(
          cache.peek<List<String>>(sourceId: 's', key: 'videos'), <String>['a'],
          reason: '过期就交白卷 = 切一次 tab 卡片全没了，比自动枚举还糟');
      expect(
        cache.peek<List<String>>(
          sourceId: 's',
          key: 'videos',
          maxAge: const Duration(seconds: 60),
        ),
        isNull,
        reason: 'maxAge 给了就得照做',
      );
    });

    test('失效之后 peek 返回 null（不是拿着已删条目的幽灵清单）', () async {
      final RemoteLibraryCache cache = RemoteLibraryCache();
      await cache.read<List<String>>(
        sourceId: 's',
        key: 'videos',
        fetch: () async => <String>['a'],
      );
      cache.invalidateSource('s');
      expect(cache.peek<List<String>>(sourceId: 's', key: 'videos'), isNull);
    });

    test('从没取过数的槽 peek 返回 null', () {
      expect(
        RemoteLibraryCache().peek<List<String>>(sourceId: 's', key: 'videos'),
        isNull,
      );
    });
  });

  group('[D] 取数闸门（视频页唯一入口）', () {
    late JellyfinVideoClient jellyfin;
    setUp(() {
      jellyfin = const JellyfinServerConfig(
        serverUrl: 'http://nas:8096',
        username: 'u',
        userId: 'u1',
        accessToken: 'tok',
      ).buildClient();
    });
    tearDown(() => jellyfin.close());

    test('Jellyfin + 关掉自动列出 + 非手动 → 不取数（这是止血的那一格）', () {
      expect(
        shouldFetchRemoteVideoList(
          source: jellyfin,
          forceRefresh: false,
          jellyfinAutoList: false,
        ),
        isFalse,
      );
    });

    test('手动刷新永远放行：开关不挡用户自己按的那一次', () {
      expect(
        shouldFetchRemoteVideoList(
          source: jellyfin,
          forceRefresh: true,
          jellyfinAutoList: false,
        ),
        isTrue,
        reason: '不放行 = 关掉之后清单永远更新不了，用户只能重登服务器',
      );
    });

    test('自动列出开着（默认）→ 照常取数，小库用户零感知', () {
      expect(
        shouldFetchRemoteVideoList(
          source: jellyfin,
          forceRefresh: false,
          jellyfinAutoList: true,
        ),
        isTrue,
      );
    });

    test('非 Jellyfin 源（互联 / 云盘）不受本开关管', () {
      expect(
        shouldFetchRemoteVideoList(
          source: Object(),
          forceRefresh: false,
          jellyfinAutoList: false,
        ),
        isTrue,
        reason: '自家后端一次性全量下发清单，没有第三方媒体服务器那种滥用检测',
      );
      expect(
        shouldFetchRemoteVideoList(
          source: null,
          forceRefresh: false,
          jellyfinAutoList: false,
        ),
        isTrue,
      );
    });
  });
}
