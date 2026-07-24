import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:hibiki/src/media/video/episode_thumbnail_cache.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('ep_thumb_cache_');
  });
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('已有 coverPath 且文件存在 → 直接返回，不抽帧', () async {
    final File cover = File(p.join(tmp.path, 'cover.jpg'))
      ..writeAsBytesSync(<int>[1, 2, 3]);
    int calls = 0;
    final EpisodeThumbnailCache cache = EpisodeThumbnailCache(
      coversDirectoryOverride: tmp,
      extractor: ({
        required String inputPath,
        required String outputPath,
        double atSeconds = 10.0,
      }) async {
        calls++;
        return outputPath;
      },
    );

    final String? out = await cache.resolve(VideoEpisodeEntry(
      title: 'e',
      coverPath: cover.path,
      videoPath: '/whatever.mkv',
      thumbnailKey: 'k',
    ));

    expect(out, cover.path);
    expect(calls, 0, reason: '已有封面不应触发抽帧');
  });

  test('coverPath 文件缺失但有本地视频 → 懒抽帧并落缓存', () async {
    int calls = 0;
    final EpisodeThumbnailCache cache = EpisodeThumbnailCache(
      coversDirectoryOverride: tmp,
      extractor: ({
        required String inputPath,
        required String outputPath,
        double atSeconds = 10.0,
      }) async {
        calls++;
        // 模拟 ffmpeg 写出封面。
        File(outputPath)
          ..createSync(recursive: true)
          ..writeAsBytesSync(<int>[9, 9]);
        return outputPath;
      },
    );

    final VideoEpisodeEntry entry = VideoEpisodeEntry(
      title: 'e',
      coverPath: p.join(tmp.path, 'does_not_exist.jpg'),
      videoPath: '/movie.mkv',
      thumbnailKey: 'book-uid-1',
    );
    final String? out = await cache.resolve(entry);

    expect(out, isNotNull);
    expect(File(out!).existsSync(), isTrue);
    expect(p.basename(out), 'ep_book-uid-1.jpg');
    expect(p.dirname(out), p.join(tmp.path, 'episodes'));
    expect(calls, 1);

    // 第二次解析命中缓存，不再抽帧。
    final String? again = await cache.resolve(entry);
    expect(again, out);
    expect(calls, 1, reason: '缓存命中不应重复抽帧');
  });

  test('key 里的非法文件名字符归一成 _', () async {
    final EpisodeThumbnailCache cache = EpisodeThumbnailCache(
      coversDirectoryOverride: tmp,
      extractor: ({
        required String inputPath,
        required String outputPath,
        double atSeconds = 10.0,
      }) async {
        File(outputPath)
          ..createSync(recursive: true)
          ..writeAsBytesSync(<int>[1]);
        return outputPath;
      },
    );
    final String? out = await cache.resolve(VideoEpisodeEntry(
      title: 'e',
      videoPath: '/movie.mkv',
      thumbnailKey: 'video/playlist:S1E1',
    ));
    expect(out, isNotNull);
    expect(p.basename(out!), 'ep_video_playlist_S1E1.jpg');
  });

  test('并发解析同 key 只抽一次（in-flight 去重）', () async {
    int calls = 0;
    final Completer<void> gate = Completer<void>();
    final EpisodeThumbnailCache cache = EpisodeThumbnailCache(
      coversDirectoryOverride: tmp,
      extractor: ({
        required String inputPath,
        required String outputPath,
        double atSeconds = 10.0,
      }) async {
        calls++;
        await gate.future; // 拖住第一次调用，制造并发窗口。
        File(outputPath)
          ..createSync(recursive: true)
          ..writeAsBytesSync(<int>[7]);
        return outputPath;
      },
    );

    final VideoEpisodeEntry entry = VideoEpisodeEntry(
      title: 'e',
      videoPath: '/movie.mkv',
      thumbnailKey: 'same-key',
    );
    final Future<String?> a = cache.resolve(entry);
    final Future<String?> b = cache.resolve(entry);
    gate.complete();
    final List<String?> res = await Future.wait(<Future<String?>>[a, b]);

    expect(calls, 1, reason: '同 key 并发只应抽一次');
    expect(res[0], res[1]);
    expect(res[0], isNotNull);
  });

  test('抽帧失败（extractor 返回 null）→ 返回 null，可重试', () async {
    int calls = 0;
    final EpisodeThumbnailCache cache = EpisodeThumbnailCache(
      coversDirectoryOverride: tmp,
      extractor: ({
        required String inputPath,
        required String outputPath,
        double atSeconds = 10.0,
      }) async {
        calls++;
        return null; // 抽帧失败。
      },
    );
    final VideoEpisodeEntry entry = VideoEpisodeEntry(
      title: 'e',
      videoPath: '/movie.mkv',
      thumbnailKey: 'k',
    );
    expect(await cache.resolve(entry), isNull);
    // 失败未落缓存 → in-flight 已清，可再次尝试。
    expect(await cache.resolve(entry), isNull);
    expect(calls, 2);
  });

  test('无本地视频路径（远端集）→ 返回 null，不抽帧', () async {
    int calls = 0;
    final EpisodeThumbnailCache cache = EpisodeThumbnailCache(
      coversDirectoryOverride: tmp,
      extractor: ({
        required String inputPath,
        required String outputPath,
        double atSeconds = 10.0,
      }) async {
        calls++;
        return outputPath;
      },
    );
    final String? out = await cache.resolve(const VideoEpisodeEntry(
      title: 'remote-ep',
      // coverPath / videoPath / thumbnailKey 全空（远端集）。
    ));
    expect(out, isNull);
    expect(calls, 0);
  });
}
