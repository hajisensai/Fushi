// BUG-3663 源码守卫：打开 / 播放视频、视频库页与合集详情页这些主 isolate 路径，会碰
// 用户视频文件、视频旁 sidecar、合集 / 视频封面——这些路径常落在网络盘（rclone /
// SMB / WinFsp 挂载）上，冷目录一次同步 stat / list 要数秒，UI 与同 isolate 的互联
// host 端点一起冻结。行为层由 IOOverrides 假网络盘测试钉住
// （test/media/video/video_network_mount_async_io_test.dart、
// test/media/async_file_existence_cache_test.dart、合集卡 / 合集详情页的 BUG-3663
// widget 用例）；本守卫补的是覆盖面：视频播放页体量太大、widget 测试驱动不到每条
// 字幕恢复分支，这里按文件 / 按方法钉住「不许再写同步文件调用」。
//
// 名单里剩下的同步调用只碰 app 自有临时目录（截图 / 缓冲副本 / 抽轨载荷），不在
// 守卫范围内——它们所在的文件按方法守，不按整文件守。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

final RegExp _syncFileApi = RegExp(
  r'\b(existsSync|statSync|lengthSync|listSync|lastModifiedSync|'
  r'readAsBytesSync|readAsStringSync|readAsLinesSync|openSync)\(',
);

/// 整个文件都不许出现同步文件调用。
const List<String> _wholeFiles = <String>[
  'lib/src/pages/implementations/video_fushi_page.dart',
  'lib/src/pages/implementations/video_fushi/danmaku.part.dart',
  'lib/src/pages/implementations/video_fushi/playback_remote.part.dart',
  'lib/src/pages/implementations/media_collection_detail_page.dart',
  'lib/src/pages/implementations/video_work_detail_page.dart',
  'lib/src/media/video/metadata/video_credit_rail.dart',
  'lib/src/media/video/video_danmaku_source.dart',
  'lib/src/media/video/cover_backfill_ledger.dart',
  'lib/src/media/video/subtitle/video_subtitle_generate_sheet.dart',
  'lib/src/media/video/subtitle/video_subtitle_backfill.dart',
  'lib/src/media/async_file_existence_cache.dart',
];

/// 文件里还有只碰临时目录的同步调用，按方法守：(文件, 方法签名开头)。
const List<(String, String)> _methods = <(String, String)>[
  (
    'lib/src/pages/implementations/video_fushi/subtitle.part.dart',
    'Future<void> _restoreSecondarySubtitle(',
  ),
  (
    'lib/src/pages/implementations/video_fushi/subtitle.part.dart',
    'Future<void> _restoreRemoteSecondarySubtitle(',
  ),
  (
    'lib/src/pages/implementations/video_fushi/subtitle.part.dart',
    'Future<String?> _currentExternalSubtitlePath(',
  ),
  (
    'lib/src/pages/implementations/video_fushi/subtitle.part.dart',
    'Future<void> _alignSubtitleToEmbeddedTracks(',
  ),
  (
    'lib/src/pages/implementations/video_fushi/advanced_mining.part.dart',
    'Future<AdvancedMiningSections> _buildAdvancedMiningSectionsImpl(',
  ),
  (
    'lib/src/pages/implementations/home_video_page.dart',
    'Future<void> _maybeBackfillCovers(',
  ),
  ('lib/src/pages/implementations/home_video_page.dart', 'Widget _buildCover('),
  (
    'lib/src/pages/implementations/home_video_page.dart',
    'Widget _buildCollectionCover(',
  ),
  (
    'lib/src/pages/implementations/home_video_page.dart',
    'ImageProvider? _remoteCoverProvider(',
  ),
  (
    'lib/src/media/video/subtitle/app_video_subtitle_service.dart',
    'Future<void> _collectEpisodes(',
  ),
];

/// 从 [signature] 起到下一个同缩进（两格）成员 / 文档注释为止的方法正文。
String _methodBody(String source, String signature) {
  final int start = source.indexOf(signature);
  expect(start, greaterThanOrEqualTo(0), reason: '找不到 $signature');
  final RegExp nextMember = RegExp(r'\n  (?:///|@override|[A-Za-z_])');
  final RegExpMatch? next = nextMember.firstMatch(
    source.substring(start + signature.length),
  );
  final int end = next == null
      ? source.length
      : start + signature.length + next.start;
  return source.substring(start, end);
}

void main() {
  for (final String path in _wholeFiles) {
    test('BUG-3663：$path 不许同步文件调用', () {
      final String source = File(path).readAsStringSync();
      final List<String> hits = <String>[
        for (final RegExpMatch m in _syncFileApi.allMatches(source))
          source.substring(
            source.lastIndexOf('\n', m.start) + 1,
            source.indexOf('\n', m.end),
          ),
      ];
      expect(hits, isEmpty, reason: '网络盘上一次同步 stat 就能冻结 UI isolate');
    });
  }

  for (final (String path, String signature) in _methods) {
    test('BUG-3663：$path › $signature 不许同步文件调用', () {
      final String body = _methodBody(File(path).readAsStringSync(), signature);
      expect(
        _syncFileApi.allMatches(body).map((RegExpMatch m) => m[0]).toList(),
        isEmpty,
      );
    });
  }
}
