import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/import/sidecar_finder.dart';
import 'package:path/path.dart' as p;

void main() {
  group('selectSidecarNames (pure)', () {
    test('完全同名字幕命中', () {
      final r = selectSidecarNames(
        mainFileName: 'book.epub',
        siblingNames: <String>['book.epub', 'book.srt', 'other.srt'],
      );
      expect(r.subtitle, 'book.srt');
    });

    test('多个同名字幕按优先级取 srt（srt > vtt > ass > ssa > lrc）', () {
      final r = selectSidecarNames(
        mainFileName: 'book.epub',
        siblingNames: <String>['book.lrc', 'book.vtt', 'book.srt', 'book.ass'],
      );
      expect(r.subtitle, 'book.srt');
    });

    test('无 srt 时退到 vtt', () {
      final r = selectSidecarNames(
        mainFileName: 'book.epub',
        siblingNames: <String>['book.ass', 'book.vtt', 'book.ssa'],
      );
      expect(r.subtitle, 'book.vtt');
    });

    test('多段音频（同前缀）全收并自然排序', () {
      final r = selectSidecarNames(
        mainFileName: 'book.epub',
        siblingNames: <String>[
          'book 10.mp3',
          'book 2.mp3',
          'book 01.mp3',
          'book 3.mp3',
        ],
      );
      // 自然排序：01 < 2 < 3 < 10（数字段按值比较，非字典序）
      expect(r.audio,
          <String>['book 01.mp3', 'book 2.mp3', 'book 3.mp3', 'book 10.mp3']);
    });

    test('完全同名单段音频命中', () {
      final r = selectSidecarNames(
        mainFileName: 'book.epub',
        siblingNames: <String>['book.mp3'],
      );
      expect(r.audio, <String>['book.mp3']);
    });

    test('同前缀但无分隔/数字的不算（bookkeeping.mp3 被排除）', () {
      final r = selectSidecarNames(
        mainFileName: 'book.epub',
        siblingNames: <String>['bookkeeping.mp3', 'booked.flac'],
      );
      expect(r.audio, isEmpty);
    });

    test('book01.mp3（数字直接跟随）算多段', () {
      final r = selectSidecarNames(
        mainFileName: 'book.epub',
        siblingNames: <String>['book01.mp3', 'book02.mp3'],
      );
      expect(r.audio, <String>['book01.mp3', 'book02.mp3']);
    });

    test('同名 .mp4 不当音频（视频容器，避免误把视频当有声书音轨）', () {
      final r = selectSidecarNames(
        mainFileName: 'book.epub',
        siblingNames: <String>['book.mp4', 'book.srt'],
      );
      expect(r.audio, isEmpty);
      expect(r.subtitle, 'book.srt');
    });

    test('真音频容器 .m4a / .m4b 仍命中', () {
      final r = selectSidecarNames(
        mainFileName: 'book.epub',
        siblingNames: <String>['book.m4b', 'book 01.m4a'],
      );
      expect(r.audio, <String>['book 01.m4a', 'book.m4b']);
    });

    test('大小写不敏感', () {
      final r = selectSidecarNames(
        mainFileName: 'Book.EPUB',
        siblingNames: <String>['BOOK.SRT', 'book 01.MP3'],
      );
      expect(r.subtitle, 'BOOK.SRT');
      expect(r.audio, <String>['book 01.MP3']);
    });

    test('wantAudio:false 不返回音频，只返回字幕', () {
      final r = selectSidecarNames(
        mainFileName: 'video.mkv',
        siblingNames: <String>['video.srt', 'video.mp3'],
        wantAudio: false,
      );
      expect(r.subtitle, 'video.srt');
      expect(r.audio, isEmpty);
    });

    test('subtitleExts 收紧后不收 lrc（视频路径）', () {
      final r = selectSidecarNames(
        mainFileName: 'video.mkv',
        siblingNames: <String>['video.lrc', 'video.srt'],
        wantAudio: false,
        subtitleExts: const <String>{'srt', 'vtt', 'ass', 'ssa'},
      );
      expect(r.subtitle, 'video.srt');
    });

    test('subtitleExts 收紧后只有 lrc 则字幕为空', () {
      final r = selectSidecarNames(
        mainFileName: 'video.mkv',
        siblingNames: <String>['video.lrc'],
        wantAudio: false,
        subtitleExts: const <String>{'srt', 'vtt', 'ass', 'ssa'},
      );
      expect(r.subtitle, isNull);
    });

    test('默认含 lrc（书籍路径）', () {
      final r = selectSidecarNames(
        mainFileName: 'book.epub',
        siblingNames: <String>['book.lrc'],
      );
      expect(r.subtitle, 'book.lrc');
    });

    test('无命中返回空', () {
      final r = selectSidecarNames(
        mainFileName: 'book.epub',
        siblingNames: <String>['unrelated.srt', 'foo.mp3'],
      );
      expect(r.subtitle, isNull);
      expect(r.audio, isEmpty);
    });

    test('跳过主文件自身（不把 book.epub 当 sidecar）', () {
      final r = selectSidecarNames(
        mainFileName: 'book.mp3', // 假想主文件本身是音频
        siblingNames: <String>['book.mp3', 'book 01.mp3'],
      );
      expect(r.audio, <String>['book 01.mp3']);
    });
  });

  group('findSidecars (IO)', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('sidecar_test_');
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('回填同目录同名字幕+多段音频的绝对路径', () async {
      final String epub = p.join(tmp.path, 'book.epub');
      await File(epub).writeAsString('x');
      await File(p.join(tmp.path, 'book.srt')).writeAsString('x');
      await File(p.join(tmp.path, 'book 01.mp3')).writeAsString('x');
      await File(p.join(tmp.path, 'book 02.mp3')).writeAsString('x');

      final SidecarMatch m = await findSidecars(epub);
      expect(m.subtitlePath, p.join(tmp.path, 'book.srt'));
      expect(m.audioPaths, <String>[
        p.join(tmp.path, 'book 01.mp3'),
        p.join(tmp.path, 'book 02.mp3'),
      ]);
    });

    test('视频 wantAudio:false 只回填字幕', () async {
      final String video = p.join(tmp.path, 'ep.mkv');
      await File(video).writeAsString('x');
      await File(p.join(tmp.path, 'ep.srt')).writeAsString('x');
      await File(p.join(tmp.path, 'ep.mp3')).writeAsString('x');

      final SidecarMatch m = await findSidecars(video, wantAudio: false);
      expect(m.subtitlePath, p.join(tmp.path, 'ep.srt'));
      expect(m.audioPaths, isEmpty);
    });

    test('目录不存在返回空且不抛', () async {
      final SidecarMatch m =
          await findSidecars(p.join(tmp.path, 'nope', 'book.epub'));
      expect(m.isEmpty, isTrue);
    });

    test('无 sidecar 返回空', () async {
      final String epub = p.join(tmp.path, 'lonely.epub');
      await File(epub).writeAsString('x');
      final SidecarMatch m = await findSidecars(epub);
      expect(m.isEmpty, isTrue);
    });
  });
}
