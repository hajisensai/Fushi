import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/music_session.dart'
    show musicMediaSessionArtUri;
import 'package:fushi_engine/media/music/youtube/youtube_music_client.dart';
import 'package:fushi_engine/media/video/youtube_source_resolver.dart';

/// BUG-5614：内置 YouTube 音源的封面曾是 4:3 的 `hqdefault`（16:9 视频上下带黑边），方形封面
/// `BoxFit.cover` 居中裁切后黑边进画面。现在给 16:9 无黑边的高清 `maxresdefault`，取字节层
/// 404 退 `mqdefault`；系统媒体卡片没有 404 回退，直接给恒存在的 `mqdefault`。
void main() {
  const String id = 'S7S4gUjXKjo';
  final YoutubeMusicClient client = YoutubeMusicClient(
    displayName: 'YouTube',
    search: (String q, {int limit = 10}) async => const <YoutubeSearchHit>[],
  );

  test('coverUri 给 16:9 高清缩略图，不是 4:3 带黑边的 hqdefault', () {
    final String cover = client.coverUri(id).toString();
    expect(cover, 'https://i.ytimg.com/vi/$id/maxresdefault.jpg');
    expect(cover, isNot(contains('hqdefault')));
    expect(cover, isNot(contains('sddefault')));
    // 高清图 404 时有恒存在的 16:9 退路，绝不无封面。
    expect(
      youtubeThumbnailFallbackUrl(cover),
      'https://i.ytimg.com/vi/$id/mqdefault.jpg',
    );
  });

  test('系统媒体卡片：可能 404 的高清缩略图换成恒存在的 mqdefault', () {
    expect(
      musicMediaSessionArtUri(client.coverUri(id).toString()),
      Uri.parse('https://i.ytimg.com/vi/$id/mqdefault.jpg'),
    );
  });

  test('系统媒体卡片：其它在线封面原样、本地封面要文件存在', () async {
    const String jellyfin = 'http://jf.test/Items/a/Images/Primary?api_key=T';
    expect(musicMediaSessionArtUri(jellyfin), Uri.parse(jellyfin));
    expect(musicMediaSessionArtUri(null), isNull);
    final Directory dir = await Directory.systemTemp.createTemp('bug5614_');
    addTearDown(() => dir.delete(recursive: true));
    final File cover = File('${dir.path}${Platform.pathSeparator}cover.jpg');
    expect(musicMediaSessionArtUri(cover.path), isNull);
    await cover.writeAsBytes(<int>[0xFF, 0xD8, 0xFF, 0xD9]);
    expect(musicMediaSessionArtUri(cover.path), Uri.file(cover.path));
  });
}
