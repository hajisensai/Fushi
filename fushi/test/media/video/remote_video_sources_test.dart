import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/remote_video_source_resolver.dart';
import 'package:fushi/src/media/video/remote_video_sources.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/sync/cloud_remote_video_client.dart';
import 'package:fushi/src/sync/jellyfin_video_client.dart';
import 'package:fushi/src/sync/remote_video_client.dart';
import 'package:fushi_core/fushi_core.dart' show FushiDatabase;
import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show RemoteVideoInfo;

/// 反馈 k5Ey2AglAf：远端视频来源从「三选一」改成并存，开了 Jellyfin 混排后云盘
/// 视频不再从视频库消失。
void main() {
  RemoteVideoInfo video(String id) => RemoteVideoInfo(id: id, title: id);

  group('mergeRemoteVideoListings', () {
    test('按来源优先级合并：同一 id 只留第一个来源的那一条，归属随之', () {
      final _Source live = _Source('interconnect');
      final _Source cloud = _Source('cloud:webdav');
      final MergedRemoteVideos merged = mergeRemoteVideoListings(
        <RemoteVideoSourceListing>[
          RemoteVideoSourceListing(
            source: live,
            videos: <RemoteVideoInfo>[video('a'), video('b')],
          ),
          RemoteVideoSourceListing(
            source: cloud,
            videos: <RemoteVideoInfo>[video('b'), video('c')],
          ),
        ],
      );
      expect(
        <String>[for (final RemoteVideoInfo v in merged.videos) v.id],
        <String>['a', 'b', 'c'],
      );
      expect(merged.owners['a'], same(live));
      expect(merged.owners['b'], same(live), reason: '重复条目归优先级高的来源');
      expect(merged.owners['c'], same(cloud));
    });

    test('groupRemoteVideosBySource：按归属分组、组内保序，不认识的略去', () {
      final _Source a = _Source('a');
      final _Source b = _Source('b');
      final Map<String, RemoteVideoSource> owners = <String, RemoteVideoSource>{
        '1': a,
        '2': b,
        '3': a,
      };
      final Map<RemoteVideoSource, List<RemoteVideoInfo>> groups =
          groupRemoteVideosBySource(<RemoteVideoInfo>[
            video('1'),
            video('2'),
            video('3'),
            video('x'),
          ], (String id) => owners[id]);
      expect(groups.keys, <RemoteVideoSource>[a, b]);
      expect(
        <String>[for (final RemoteVideoInfo v in groups[a]!) v.id],
        <String>['1', '3'],
      );
      expect(
        <String>[for (final RemoteVideoInfo v in groups[b]!) v.id],
        <String>['2'],
      );
    });
  });

  group('RoutedRemoteVideoPlayedMark', () {
    test('按 id 派给归属来源；来源不支持时 supports 为假、调用抛错', () async {
      final _MarkingSource server = _MarkingSource('jellyfin');
      final _Source cloud = _Source('cloud:webdav');
      final Map<String, RemoteVideoSource> owners = <String, RemoteVideoSource>{
        'jf-1': server,
        'cloud-1': cloud,
      };
      final RoutedRemoteVideoPlayedMark marker = RoutedRemoteVideoPlayedMark(
        (String id) => remoteVideoPlayedMarkOf(owners[id]),
      );
      expect(marker.supports('jf-1'), isTrue);
      expect(marker.supports('cloud-1'), isFalse);
      expect(marker.supports('unknown'), isFalse);
      await marker.setRemoteVideoPlayed('jf-1', played: true);
      expect(server.marked, <String>['jf-1:true']);
      expect(
        () => marker.setRemoteVideoPlayed('cloud-1', played: true),
        throwsUnsupportedError,
      );
    });
  });

  group('resolveRemoteVideoSources', () {
    late FushiDatabase db;
    late PreferencesRepository prefs;
    setUp(() async {
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      prefs = PreferencesRepository(db);
      await prefs.loadFromDb();
    });
    tearDown(() => db.close());

    final _FakeJellyfin jellyfin = _FakeJellyfin();
    final _FakeCloud cloud = _FakeCloud();
    final _FakeLive live = _FakeLive();

    Future<List<RemoteVideoSource>> resolve({
      RemoteVideoClient? interconnect,
    }) => resolveRemoteVideoSources(
      prefs: prefs,
      database: db,
      interconnect: () async => interconnect,
      jellyfin: () async => jellyfin,
      cloud: () async => cloud,
    );

    test('Jellyfin 混排开：与云盘并存（此前三选一，云盘被顶掉）', () async {
      await prefs.setJellyfinShowInLibrary(true);
      expect(await resolve(), <RemoteVideoSource>[jellyfin, cloud]);
    });

    test('Jellyfin 混排关：只有云盘，Jellyfin 连问都不问', () async {
      int asked = 0;
      final List<RemoteVideoSource> sources = await resolveRemoteVideoSources(
        prefs: prefs,
        database: db,
        interconnect: () async => null,
        jellyfin: () async {
          asked++;
          return jellyfin;
        },
        cloud: () async => cloud,
      );
      expect(sources, <RemoteVideoSource>[cloud]);
      expect(asked, 0);
    });

    test('互联在线：互联优先于云盘（与书架同一判据），Jellyfin 照样混入', () async {
      await prefs.setJellyfinShowInLibrary(true);
      expect(await resolve(interconnect: live), <RemoteVideoSource>[
        live,
        jellyfin,
      ]);
    });

    test('「显示远端条目」关：一个来源都没有', () async {
      await prefs.setShowRemoteEntries(false);
      expect(
        await resolveVisibleRemoteVideoSources(prefs: prefs, database: db),
        isEmpty,
      );
    });
  });
}

class _Source implements RemoteVideoSource {
  _Source(this.remoteLibrarySourceId);

  @override
  final String remoteLibrarySourceId;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _MarkingSource extends _Source implements RemoteVideoPlayedMark {
  _MarkingSource(super.remoteLibrarySourceId);

  final List<String> marked = <String>[];

  @override
  Future<void> setRemoteVideoPlayed(String id, {required bool played}) async {
    marked.add('$id:$played');
  }
}

class _FakeJellyfin implements JellyfinVideoClient {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _FakeCloud implements CloudRemoteVideoClient {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _FakeLive implements RemoteVideoClient {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}
