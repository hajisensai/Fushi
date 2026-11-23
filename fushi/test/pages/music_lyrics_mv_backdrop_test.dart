import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_background.dart';
import 'package:fushi/src/media/music/metadata/music_video_service.dart';
import 'package:fushi/src/media/music/music_output_backend.dart'
    show MusicPlayItem;
import 'package:fushi/src/pages/implementations/music/music_lyrics_mv_backdrop.dart';
import 'package:path/path.dart' as p;

/// 建一个指定大小的文件（truncate，不真写数据）。
void _sized(String path, int bytes) {
  File(path).parent.createSync(recursive: true);
  final RandomAccessFile f = File(path).openSync(mode: FileMode.write);
  f.truncateSync(bytes);
  f.closeSync();
}

/// 测试里按 KB 量级的文件模拟：下限 20 KB、上限 1 MB（默认是 20 MB–6 GB）。
const int _kb = 1024;
const int _min = 20 * _kb;
const int _max = 1024 * _kb;

List<String> _list(Directory d, {Set<String>? seen}) =>
    listDiscMusicVideoStreams(d, seen: seen, minBytes: _min, maxBytes: _max);

void main() {
  group('planMusicMvBackdropSync', () {
    test('对齐时可见、跟着音频放，不 seek', () {
      final MusicMvBackdropSyncPlan plan = planMusicMvBackdropSync(
        audioPosition: const Duration(seconds: 10),
        audioPlaying: true,
        offsetMs: 2000,
        videoPosition: const Duration(milliseconds: 12100),
        videoDuration: const Duration(minutes: 4),
      );
      expect(plan.visible, isTrue);
      expect(plan.play, isTrue);
      expect(plan.seekTo, isNull);
    });

    test('偏差超过容差 seek 到 曲目时刻 + 偏移', () {
      final MusicMvBackdropSyncPlan plan = planMusicMvBackdropSync(
        audioPosition: const Duration(seconds: 10),
        audioPlaying: false,
        offsetMs: 2000,
        videoPosition: const Duration(seconds: 30),
        videoDuration: const Duration(minutes: 4),
      );
      expect(plan.visible, isTrue);
      expect(plan.play, isFalse);
      expect(plan.seekTo, const Duration(seconds: 12));
    });

    test('MV 开始之前（负偏移的前奏）不显示，画面停在开头', () {
      final MusicMvBackdropSyncPlan plan = planMusicMvBackdropSync(
        audioPosition: const Duration(seconds: 3),
        audioPlaying: true,
        offsetMs: -5000,
        videoPosition: const Duration(seconds: 1),
      );
      expect(plan.visible, isFalse);
      expect(plan.play, isFalse);
      expect(plan.seekTo, Duration.zero);
    });

    test('MV 比歌短：越过 MV 尾部不显示、不 seek', () {
      final MusicMvBackdropSyncPlan plan = planMusicMvBackdropSync(
        audioPosition: const Duration(minutes: 5),
        audioPlaying: true,
        offsetMs: 0,
        videoPosition: const Duration(minutes: 4),
        videoDuration: const Duration(minutes: 4),
      );
      expect(plan.visible, isFalse);
      expect(plan.play, isFalse);
      expect(plan.seekTo, isNull);
    });

    test('时长未知时不判尾部越界', () {
      final MusicMvBackdropSyncPlan plan = planMusicMvBackdropSync(
        audioPosition: const Duration(minutes: 5),
        audioPlaying: true,
        offsetMs: 0,
        videoPosition: Duration.zero,
        videoDuration: Duration.zero,
      );
      expect(plan.visible, isTrue);
      expect(plan.seekTo, const Duration(minutes: 5));
    });
  });

  group('musicMvBackdropSelfSource', () {
    MusicPlayItem item(String path, {int? startMs}) =>
        MusicPlayItem(trackUid: 'u', path: path, title: 't', startMs: startMs);

    test('曲目本身是本机视频：拿自己当背景，偏移 = CUE 起点', () {
      final String path = p.join(Directory.systemTemp.path, 'a', 'song.mkv');
      expect(
        musicMvBackdropSelfSource(item(path)),
        MusicMvBackdropSource(path: path, offsetMs: 0),
      );
      expect(
        musicMvBackdropSelfSource(item(path, startMs: 1500))?.offsetMs,
        1500,
      );
    });

    test('音频文件 / 网络地址不算', () {
      expect(
        musicMvBackdropSelfSource(
          item(p.join(Directory.systemTemp.path, 'song.flac')),
        ),
        isNull,
      );
      expect(
        musicMvBackdropSelfSource(item('https://example.com/a.mp4')),
        isNull,
      );
    });
  });

  group('lyricVisualizerBackgroundYieldsToMv', () {
    test('放 MV 时共享 / 指定背景让位，none / transparent 不变', () {
      expect(
        lyricVisualizerBackgroundYieldsToMv(
          LyricVisualizerBackgroundRequest.selected,
          mvShowing: true,
        ),
        isTrue,
      );
      expect(
        lyricVisualizerBackgroundYieldsToMv(
          const LyricVisualizerBackgroundRequest.specific('monet'),
          mvShowing: true,
        ),
        isTrue,
      );
      expect(
        lyricVisualizerBackgroundYieldsToMv(
          LyricVisualizerBackgroundRequest.none,
          mvShowing: true,
        ),
        isFalse,
      );
      expect(
        lyricVisualizerBackgroundYieldsToMv(
          LyricVisualizerBackgroundRequest.transparent,
          mvShowing: true,
        ),
        isFalse,
      );
      expect(
        lyricVisualizerBackgroundYieldsToMv(
          LyricVisualizerBackgroundRequest.selected,
          mvShowing: false,
        ),
        isFalse,
      );
    });
  });

  group('listDiscMusicVideoStreams', () {
    late Directory root;

    setUp(() {
      root = Directory.systemTemp.createTempSync('fushi_mv_bd_');
    });

    tearDown(() {
      root.deleteSync(recursive: true);
    });

    test('专辑/CD 与 专辑/BD 并列：从 CD 目录找到 BD 里的流，按大小过滤与排序', () {
      final Directory cd = Directory(p.join(root.path, 'CD'))..createSync();
      final String stream = p.join(root.path, 'BD', 'BDMV', 'STREAM');
      _sized(p.join(stream, '00000.m2ts'), 2 * _kb); // 菜单，太小
      _sized(p.join(stream, '00001.m2ts'), 300 * _kb);
      _sized(p.join(stream, '00002.m2ts'), 500 * _kb);
      _sized(p.join(stream, '00003.mkv'), 500 * _kb); // 不是 m2ts
      final List<String> found = _list(cd);
      expect(found.map(p.basename), <String>['00002.m2ts', '00001.m2ts']);
    });

    test('盘在曲目目录的子目录里、或曲目目录本身就是盘根', () {
      final String a = p.join(root.path, 'BD', 'BDMV', 'STREAM', '00001.m2ts');
      _sized(a, 100 * _kb);
      expect(_list(root), <String>[a]);
      final Directory bd = Directory(p.join(root.path, 'BD'));
      expect(_list(bd), <String>[a]);
    });

    test('整场演唱会那种超大流不当候选；seen 里已有的跳过', () {
      final String stream = p.join(root.path, 'BD', 'BDMV', 'STREAM');
      final String big = p.join(stream, '00010.m2ts');
      _sized(big, _max + 1);
      final String ok = p.join(stream, '00011.m2ts');
      _sized(ok, 100 * _kb);
      expect(_list(root), <String>[ok]);
      expect(_list(root, seen: <String>{p.normalize(ok)}), isEmpty);
    });

    test('附近没有盘时为空', () {
      expect(_list(root), isEmpty);
    });
  });
}
