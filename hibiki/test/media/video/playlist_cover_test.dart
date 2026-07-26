import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_cover_extractor.dart';

/// TODO-1237 ①：播放列表封面遍历取首个可用集。用注入的抽取器替身脱离 ffmpeg 测
/// [extractPlaylistCover] 的回退逻辑（首集不可用 -> 退到后续集；全不可用 -> null；
/// maxAttempts 上限；空路径跳过）。
void main() {
  group('extractPlaylistCover', () {
    /// 构造一个记录调用的替身：对 [goodPaths] 里的路径返回封面，其余返回 null。
    ({VideoCoverExtractor fn, List<String> calls}) fake(Set<String> goodPaths) {
      final List<String> calls = <String>[];
      Future<String?> fn({
        required String videoPath,
        required String bookUid,
        double atSeconds = 10.0,
      }) async {
        calls.add(videoPath);
        return goodPaths.contains(videoPath) ? '$videoPath.cover.jpg' : null;
      }

      return (fn: fn, calls: calls);
    }

    test('首集不可用时退到首个可用集（返回该集封面）', () async {
      final f = fake(<String>{'/v/ep2.mkv'});
      final String? cover = await extractPlaylistCover(
        episodePaths: <String>['/v/ep1.mkv', '/v/ep2.mkv', '/v/ep3.mkv'],
        bookUid: 'video/playlist/x',
        extractor: f.fn,
      );
      expect(cover, '/v/ep2.mkv.cover.jpg');
      // 命中 ep2 后立即停止，不再试 ep3。
      expect(f.calls, <String>['/v/ep1.mkv', '/v/ep2.mkv']);
    });

    test('全部集都不可用 -> null（书架占位）', () async {
      final f = fake(<String>{});
      final String? cover = await extractPlaylistCover(
        episodePaths: <String>['/v/ep1.mkv', '/v/ep2.mkv'],
        bookUid: 'video/playlist/x',
        extractor: f.fn,
      );
      expect(cover, isNull);
      expect(f.calls, <String>['/v/ep1.mkv', '/v/ep2.mkv']);
    });

    test('单集列表 -> 一次调用，行为等价单视频', () async {
      final f = fake(<String>{'/v/only.mkv'});
      final String? cover = await extractPlaylistCover(
        episodePaths: <String>['/v/only.mkv'],
        bookUid: 'video/playlist/x',
        extractor: f.fn,
      );
      expect(cover, '/v/only.mkv.cover.jpg');
      expect(f.calls, <String>['/v/only.mkv']);
    });

    test('maxAttempts 上限：只尝试前 N 集，避免整列不可用时拖成分钟级', () async {
      final f = fake(<String>{'/v/ep9.mkv'}); // 只有第 9 集可用，但上限 3
      final String? cover = await extractPlaylistCover(
        episodePaths: List<String>.generate(9, (int i) => '/v/ep${i + 1}.mkv'),
        bookUid: 'video/playlist/x',
        maxAttempts: 3,
        extractor: f.fn,
      );
      expect(cover, isNull, reason: '可用集在上限之外，放弃返回占位');
      expect(f.calls, hasLength(3), reason: '尝试次数受 maxAttempts 硬上限约束');
    });

    // TODO-1237 ②：守卫对话框「导入文件夹」路径保留按物理路径去重（isVideoPathReferenced
    // 命中即跳过），防止未来改动悄悄回退成 uniqueVideoBookUid 加后缀重复导入。
    test('source guard: 文件夹导入 _importGroup 用 isVideoPathReferenced 去重', () {
      final String src = File(
        'lib/src/media/video/video_import_dialog.dart',
      ).readAsStringSync();
      expect(src.contains('isVideoPathReferenced(group.episodes.first.path)'),
          isTrue,
          reason: '_importGroup 必须先按物理路径判重再决定导入');
      expect(src.contains('extractPlaylistCover('), isTrue,
          reason: '播放列表封面必须走遍历各集的 extractPlaylistCover');
    });

    test('空路径跳过且不计入尝试次数', () async {
      final f = fake(<String>{'/v/real.mkv'});
      final String? cover = await extractPlaylistCover(
        episodePaths: <String>['', '', '/v/real.mkv'],
        bookUid: 'video/playlist/x',
        maxAttempts: 1,
        extractor: f.fn,
      );
      expect(cover, '/v/real.mkv.cover.jpg', reason: '空串不占用 maxAttempts=1 的名额');
      expect(f.calls, <String>['/v/real.mkv']);
    });
  });
}
