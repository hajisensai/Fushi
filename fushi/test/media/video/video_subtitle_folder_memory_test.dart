import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/video/subtitle/video_subtitle_folder_memory.dart';

/// 反馈 0PZAhFd1RO：按系列记住字幕文件夹，之后各集按集号自动匹配。
void main() {
  group('videoSubtitleFolderSeriesKey', () {
    test('在合集里以合集为系列，与视频所在目录无关', () {
      expect(
        videoSubtitleFolderSeriesKey(
          collectionId: 7,
          videoPath: p.join('a', 'ep01', 'Show - 01.mkv'),
        ),
        videoSubtitleFolderSeriesKey(
          collectionId: 7,
          videoPath: p.join('b', 'ep02', 'Show - 02.mkv'),
        ),
      );
      expect(
        videoSubtitleFolderSeriesKey(collectionId: 7, videoPath: 'x.mkv'),
        'collection:7',
      );
    });

    test('不在合集里以视频所在目录为系列', () {
      final String a = videoSubtitleFolderSeriesKey(
        collectionId: null,
        videoPath: p.join('lib', 'Show', 'Show - 01.mkv'),
      );
      final String b = videoSubtitleFolderSeriesKey(
        collectionId: null,
        videoPath: p.join('lib', 'Show', 'Show - 02.mkv'),
      );
      final String other = videoSubtitleFolderSeriesKey(
        collectionId: null,
        videoPath: p.join('lib', 'Other', 'Other - 01.mkv'),
      );
      expect(a, b);
      expect(a, isNot(other));
      expect(a, startsWith('dir:'));
    });
  });

  group('编解码', () {
    test('往返保留目录与模板；没有模板时不写 template', () {
      final Map<String, VideoSubtitleFolder> folders =
          <String, VideoSubtitleFolder>{
            'collection:1': const VideoSubtitleFolder(
              directory: '/subs/show',
              templateFileName: '[A] Show - 01.ja.ass',
            ),
            'dir:/videos/other': const VideoSubtitleFolder(
              directory: '/subs/other',
            ),
          };
      final String raw = encodeVideoSubtitleFolders(folders);
      expect(raw.contains('"template"'), isTrue);
      expect(decodeVideoSubtitleFolders(raw), folders);
      expect(
        const VideoSubtitleFolder(directory: '/subs/other').toJson(),
        <String, Object?>{'dir': '/subs/other'},
      );
    });

    test('空串是空表；单条坏记录跳过，不拖垮整张表', () {
      expect(decodeVideoSubtitleFolders(''), isEmpty);
      final Map<String, VideoSubtitleFolder> decoded =
          decodeVideoSubtitleFolders(
            '{"ok":{"dir":"/subs"},"noDir":{"template":"a.srt"},'
            '"blank":{"dir":"  "},"notMap":3}',
          );
      expect(decoded.keys, <String>['ok']);
      expect(decoded['ok']!.templateFileName, isNull);
    });

    test('整体不是 JSON map 时抛 FormatException（调用方记诊断后当空表）', () {
      expect(
        () => decodeVideoSubtitleFolders('[1,2]'),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('接线守卫', () {
    String read(String path) => File(path).readAsStringSync();

    test('本机加载链：同名 sidecar 之后、内封轨兜底之前试字幕文件夹', () {
      final String page = read(
        'lib/src/pages/implementations/video_fushi_page.dart',
      );
      final int load = page.indexOf(
        'Future<void> _loadSingle(VideoBookRow row)',
      );
      expect(load, greaterThanOrEqualTo(0));
      final int sidecar = page.indexOf('await _detectSidecar(', load);
      final int folder = page.indexOf(
        'await _detectSubtitleFolderMatch(',
        load,
      );
      final int embeddedFallback = page.indexOf(
        '!SubtitleSource.isEmbeddedPersisted(externalSub)',
        load,
      );
      expect(sidecar, greaterThan(load));
      expect(folder, greaterThan(sidecar));
      expect(embeddedFallback, greaterThan(folder));
    });

    test('导入字幕仍是系统选择器（board 1360），只是带出处判断能不能记文件夹', () {
      final String part = read(
        'lib/src/pages/implementations/video_fushi/subtitle.part.dart',
      );
      final int start = part.indexOf(
        'Future<void> _pickAndImportSubtitle(VideoPlayerController controller)',
      );
      expect(start, greaterThanOrEqualTo(0));
      final int end = part.indexOf('String _subtitleFolderSeriesKey(', start);
      final String body = part.substring(start, end);
      expect(body, contains('pickSystemFilePathDetailed('));
      expect(RegExp(r'pickRealFilePath(Detailed)?\(').hasMatch(body), isFalse);
      expect(body, contains('picked.isRealPath'));
      expect(body, contains('_rememberSubtitleFolderFromPick('));
    });

    test('字幕面板对本机视频给出「字幕文件夹」入口', () {
      final String part = read(
        'lib/src/pages/implementations/video_fushi/subtitle.part.dart',
      );
      expect(
        part,
        contains(
          'if (!_isRemote && _currentVideoPath != null)\n'
          '        _subtitleFolderTile(controller),',
        ),
      );
      expect(part, contains("ValueKey<String>('video-subtitle-folder')"));
      expect(part, contains("ValueKey<String>('video-subtitle-folder-clear')"));
    });
  });
}
