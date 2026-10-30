import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_music/fushi_music.dart';

import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/plugin/music_plugin_favorites.dart';
import 'package:fushi/src/media/music/plugin/music_plugins.dart';

/// 歌曲收藏 = 平台账号的「喜欢」：缓存懒加载、同步读、toggle 调插件后才改缓存、未登录 /
/// 本地曲目 / 插件不支持各自的失败形态、在途旧拉取不覆盖刚做的 toggle。
MusicPluginManifest _manifest(String id) =>
    MusicPluginManifest.fromJson(<String, Object?>{
      'id': id,
      'name': id.toUpperCase(),
      'version': '1.0.0',
      'api': 1,
      'capabilities': <String>['search', 'login', 'account', 'like'],
    });

MusicPlayItem _plugin(String pluginId, String trackId) => musicPluginPlayItem(
  pluginId,
  MusicPluginTrack(id: trackId, title: trackId, artists: const []),
);

const MusicPlayItem _local = MusicPlayItem(
  trackUid: 'local-1',
  path: r'C:\music\a.flac',
  title: 'A',
);

class _FakeHost implements MusicPluginLikeHost {
  List<String> plugins = <String>['ne'];

  /// 插件 id → 喜欢集合；缺键 = 未登录。
  final Map<String, Set<String>> liked = <String, Set<String>>{
    'ne': <String>{'1'},
  };
  final List<String> calls = <String>[];
  Exception? setError;

  /// 非空时 likes() 等它完成（模拟在途拉取）。
  Completer<void>? likesGate;

  @override
  Future<List<MusicPluginManifest>> likeCapablePlugins() async =>
      <MusicPluginManifest>[for (final String id in plugins) _manifest(id)];

  @override
  Future<MusicPluginLikes?> likes(String pluginId) async {
    calls.add('likes:$pluginId');
    final Set<String>? snapshot = liked[pluginId] == null
        ? null
        : <String>{...liked[pluginId]!};
    await likesGate?.future;
    if (snapshot == null) return null;
    return MusicPluginLikes(
      trackIds: snapshot,
      playlist: MusicPluginPlaylist(id: 'fav-$pluginId', title: 'Liked'),
    );
  }

  @override
  Future<void> setLiked(
    String pluginId,
    String trackId, {
    required bool liked,
  }) async {
    calls.add('set:$pluginId:$trackId:$liked');
    if (setError case final Exception e) throw e;
    final Set<String> s = this.liked[pluginId]!;
    liked ? s.add(trackId) : s.remove(trackId);
  }
}

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  test('首次同步读触发懒加载，加载后读到喜欢集合并通知', () async {
    final _FakeHost host = _FakeHost();
    final MusicPluginFavorites f = MusicPluginFavorites(host);
    int notified = 0;
    f.addListener(() => notified++);

    expect(f.isFavorite(_plugin('ne', '1')), isFalse, reason: '还没拉到');
    await f.refresh();
    expect(f.loaded, isTrue);
    expect(f.canFavorite(_plugin('ne', '1')), isTrue);
    expect(f.isFavorite(_plugin('ne', '1')), isTrue);
    expect(f.isFavorite(_plugin('ne', '2')), isFalse);
    expect(notified, greaterThan(0));
    expect(f.states.single.loggedIn, isTrue);
    expect(f.states.single.playlist!.id, 'fav-ne');
    expect(
      host.calls.where((String c) => c.startsWith('likes')).length,
      1,
      reason: '同步读触发的加载与显式 refresh 合并成一次',
    );
  });

  test('本地曲目与未声明 like 的插件曲目不能收藏', () async {
    final _FakeHost host = _FakeHost();
    final MusicPluginFavorites f = MusicPluginFavorites(host);
    await f.refresh();
    expect(f.canFavorite(_local), isFalse);
    expect(f.isFavorite(_local), isFalse);
    expect(f.canFavorite(_plugin('other', '1')), isFalse);
    await expectLater(
      f.toggle(_local),
      throwsA(isA<MusicFavoriteUnsupported>()),
    );
    await expectLater(
      f.toggle(_plugin('other', '1')),
      throwsA(isA<MusicFavoriteUnsupported>()),
    );
    expect(host.calls.where((String c) => c.startsWith('set')), isEmpty);
  });

  test('toggle：调插件成功后才改缓存并通知；失败原样抛出、缓存不变', () async {
    final _FakeHost host = _FakeHost();
    final MusicPluginFavorites f = MusicPluginFavorites(host);
    await f.refresh();
    int notified = 0;
    f.addListener(() => notified++);

    await f.toggle(_plugin('ne', '2'));
    expect(host.calls.last, 'set:ne:2:true');
    expect(f.isFavorite(_plugin('ne', '2')), isTrue);
    expect(notified, 1);

    await f.toggle(_plugin('ne', '1'));
    expect(host.calls.last, 'set:ne:1:false');
    expect(f.isFavorite(_plugin('ne', '1')), isFalse);

    host.setError = const MusicPluginException('风控');
    await expectLater(
      f.toggle(_plugin('ne', '2')),
      throwsA(isA<MusicPluginException>()),
    );
    expect(f.isFavorite(_plugin('ne', '2')), isTrue, reason: '失败不改缓存');
  });

  test('未登录：toggle 先重拉一次，仍未登录抛 MusicFavoriteLoginRequired；登录后重拉可用', () async {
    final _FakeHost host = _FakeHost()..liked.remove('ne');
    final MusicPluginFavorites f = MusicPluginFavorites(host);
    await f.refresh();
    expect(f.canFavorite(_plugin('ne', '1')), isTrue);
    expect(f.states.single.loggedIn, isFalse);
    await expectLater(
      f.toggle(_plugin('ne', '1')),
      throwsA(
        isA<MusicFavoriteLoginRequired>().having(
          (MusicFavoriteLoginRequired e) => e.pluginId,
          'pluginId',
          'ne',
        ),
      ),
    );
    expect(host.calls.where((String c) => c.startsWith('set')), isEmpty);

    host.liked['ne'] = <String>{'5'};
    await f.refreshPlugin('ne');
    expect(f.states.single.loggedIn, isTrue);
    expect(f.isFavorite(_plugin('ne', '5')), isTrue);

    host.liked.remove('ne');
    await f.refreshPlugin('ne');
    expect(f.isFavorite(_plugin('ne', '5')), isFalse, reason: '退出后清缓存');
  });

  test('在途的旧拉取不覆盖拉取期间做的 toggle', () async {
    final _FakeHost host = _FakeHost();
    final MusicPluginFavorites f = MusicPluginFavorites(host);
    await f.refresh();
    final Completer<void> gate = Completer<void>();
    host.likesGate = gate;
    final Future<void> stale = f.refreshPlugin('ne');
    await _settle();
    host.likesGate = null;
    await f.toggle(_plugin('ne', '9'));
    expect(f.isFavorite(_plugin('ne', '9')), isTrue);
    // 旧拉取的快照里没有 9：它回来时不能把 9 抹掉。
    gate.complete();
    await stale;
    expect(f.isFavorite(_plugin('ne', '9')), isTrue);
  });

  test('插件卸载后 refresh 清掉它的缓存', () async {
    final _FakeHost host = _FakeHost();
    final MusicPluginFavorites f = MusicPluginFavorites(host);
    await f.refresh();
    expect(f.isFavorite(_plugin('ne', '1')), isTrue);
    host.plugins = <String>[];
    await f.refresh();
    expect(f.canFavorite(_plugin('ne', '1')), isFalse);
    expect(f.isFavorite(_plugin('ne', '1')), isFalse);
    expect(f.states, isEmpty);
  });
}
