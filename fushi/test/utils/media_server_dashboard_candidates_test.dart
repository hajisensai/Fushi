import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/misc/dashboard_remote_merge.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';

RemoteVideoInfo _ep(
  String id, {
  required String series,
  required int index,
  int positionMs = 0,
  int positionUpdatedAtMs = 0,
  int? completedAt,
}) => RemoteVideoInfo(
  id: id,
  title: '$series E$index',
  coverUrl: 'http://nas/Items/$id/Images/Primary',
  seriesCoverUrl: 'http://nas/Items/$series/Images/Primary',
  positionMs: positionMs,
  positionUpdatedAtMs: positionUpdatedAtMs,
  completedAt: completedAt,
  collection: RemoteCollectionMembership(
    collectionName: series,
    collectionType: 'playlist',
    sortIndex: index,
  ),
);

/// 首页「继续」的媒体服务器（整库混排）候选：每部剧一张，封面用剧封面。
void main() {
  test('继续：每部剧取最近播放的那集；看完的、本地已有的不出', () {
    final List<RemoteContinueCandidate> result = mediaServerContinueCandidates(
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
        _ep('d1', series: 'D', index: 1),
      ],
      localVideoUids: const <String>{'c1'},
      sourceLabel: 'Samu',
    );
    expect(result.map((RemoteContinueCandidate c) => c.id), <String>['a2']);
    final RemoteContinueCandidate a = result.single;
    expect(a.recentMs, 9);
    expect(a.coverUrl, 'http://nas/Items/A/Images/Primary', reason: '剧封面优先');
    expect(a.collectionName, 'A');
    expect(a.sourceLabel, 'Samu');
  });
}
