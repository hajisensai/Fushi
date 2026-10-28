import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/misc/dashboard_remote_merge.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';

RemoteVideoInfo _ep(
  String id, {
  required String series,
  required int index,
  int positionMs = 0,
  int positionUpdatedAtMs = 0,
  int? importedAt,
  int? completedAt,
}) => RemoteVideoInfo(
  id: id,
  title: '$series E$index',
  coverUrl: 'http://nas/Items/$id/Images/Primary',
  seriesCoverUrl: 'http://nas/Items/$series/Images/Primary',
  positionMs: positionMs,
  positionUpdatedAtMs: positionUpdatedAtMs,
  importedAt: importedAt,
  completedAt: completedAt,
  collection: RemoteCollectionMembership(
    collectionName: series,
    collectionType: 'playlist',
    sortIndex: index,
  ),
);

/// 首页「继续 / 最近添加」的媒体服务器候选：每部剧一张，封面用剧海报。
void main() {
  test('最近添加：每部剧一张、指向第一集、封面是剧海报、按加入时刻', () {
    final result = mediaServerDashboardCandidates(
      videos: <RemoteVideoInfo>[
        _ep('a2', series: 'A', index: 2, importedAt: 500),
        _ep('a1', series: 'A', index: 1, importedAt: 500),
        _ep('b1', series: 'B', index: 1),
      ],
      localVideoUids: const <String>{},
      sourceLabel: 'Samu',
    );
    expect(result.recentlyAdded, hasLength(1), reason: '没加入时刻的 B 不出');
    final RemoteContinueCandidate a = result.recentlyAdded.single;
    expect(a.id, 'a1');
    expect(a.recentMs, 500);
    expect(a.coverUrl, 'http://nas/Items/A/Images/Primary');
    expect(a.collectionName, 'A');
    expect(a.sourceLabel, 'Samu');
  });

  test('继续：每部剧取最近播放的那集；看完的、本地已有的不出', () {
    final result = mediaServerDashboardCandidates(
      videos: <RemoteVideoInfo>[
        _ep(
          'a1',
          series: 'A',
          index: 1,
          positionMs: 10,
          positionUpdatedAtMs: 1,
        ),
        _ep(
          'a2',
          series: 'A',
          index: 2,
          positionMs: 10,
          positionUpdatedAtMs: 9,
        ),
        _ep('b1', series: 'B', index: 1, positionMs: 10, completedAt: 5),
        _ep(
          'c1',
          series: 'C',
          index: 1,
          positionMs: 10,
          positionUpdatedAtMs: 3,
        ),
      ],
      localVideoUids: const <String>{'c1'},
    );
    expect(
      result.continueWatching.map((RemoteContinueCandidate c) => c.id),
      <String>['a2'],
    );
  });
}
