import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_book_repository.dart';
import 'package:hibiki/src/media/video/video_subtitle_attach.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:path/path.dart' as p;

/// TODO-079: 主页把字幕拖到视频卡 -> 字幕应挂到**那张卡所代表的现有视频**
/// （不新建 `video/<name> (2)` 重复条目）。这一层钉死「附加」核心：解析 cue +
/// 对命中卡 bookUid 原子 saveSubtitleSelection（外挂源指针 + cue），单视频 / 播放列表
/// / 坏字幕 / 不支持格式各走对应分支。
void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('hibiki_sub_attach_');
  });
  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  Future<File> writeSrt(String name, String content) async {
    final File f = File(p.join(tmp.path, name));
    await f.writeAsString(content);
    return f;
  }

  test('single video: attaches subtitle to the SAME bookUid (no duplicate row)',
      () async {
    final db = HibikiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = VideoBookRepository(db);

    // 现有单视频卡（无字幕）。
    await repo.saveVideoBook(const VideoBooksCompanion(
      bookUid: Value('video/My Movie'),
      title: Value('My Movie'),
      videoPath: Value('/movies/My Movie.mkv'),
    ));
    final VideoBookRow book = (await repo.getByBookUid('video/My Movie'))!;

    final File srt = await writeSrt(
      'My Movie.srt',
      '1\n00:00:00,000 --> 00:00:02,000\nこんにちは\n\n'
          '2\n00:00:02,000 --> 00:00:04,000\nさようなら\n',
    );
    final String destDir = p.join(tmp.path, 'video_subtitles');

    final SubtitleAttachResult result = await attachSubtitleToVideoBook(
      repo: repo,
      book: book,
      subtitlePath: srt.path,
      destDirOverride: destDir,
    );

    expect(result.outcome, SubtitleAttachOutcome.attached);
    expect(result.cueCount, 2);

    // 没有新建任何视频书：仍然只有 1 行，且就是原 bookUid。
    final all = await repo.listAll();
    expect(all, hasLength(1));
    expect(all.single.bookUid, 'video/My Movie');

    // 字幕源指针 + cue 都落到了原视频书上（saveSubtitleSelection 原子写）。
    final updated = (await repo.getByBookUid('video/My Movie'))!;
    expect(updated.subtitleSource, p.join(destDir, 'My Movie.srt'));
    final cues = await repo.loadCues('video/My Movie');
    expect(cues, hasLength(2));
    expect(cues.first.text, 'こんにちは');

    // 字幕文件被拷进持久目录（源被移走也能恢复，BUG-132 同处）。
    expect(File(p.join(destDir, 'My Movie.srt')).existsSync(), isTrue);
  });

  test('playlist card: does NOT persist, asks to attach per-episode in player',
      () async {
    final db = HibikiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = VideoBookRepository(db);

    await repo.saveVideoBook(const VideoBooksCompanion(
      bookUid: Value('video/playlist/Show'),
      title: Value('Show'),
      videoPath: Value('/show/e0.mkv'),
      playlistJson: Value('[{"title":"e0","path":"/show/e0.mkv"},'
          '{"title":"e1","path":"/show/e1.mkv"}]'),
    ));
    final VideoBookRow book = (await repo.getByBookUid('video/playlist/Show'))!;

    final File srt = await writeSrt(
      'sub.srt',
      '1\n00:00:00,000 --> 00:00:01,000\nhi\n',
    );

    final SubtitleAttachResult result = await attachSubtitleToVideoBook(
      repo: repo,
      book: book,
      subtitlePath: srt.path,
      destDirOverride: p.join(tmp.path, 'video_subtitles'),
    );

    expect(result.outcome, SubtitleAttachOutcome.playlistNeedsPlayer);
    // 不落库：源指针仍为 null，cue 仍为空。
    final row = (await repo.getByBookUid('video/playlist/Show'))!;
    expect(row.subtitleSource, isNull);
    expect(await repo.loadCues('video/playlist/Show'), isEmpty);
  });

  test('unsupported extension -> unsupported, nothing written', () async {
    final db = HibikiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = VideoBookRepository(db);
    await repo.saveVideoBook(const VideoBooksCompanion(
      bookUid: Value('video/x'),
      title: Value('X'),
      videoPath: Value('/x.mkv'),
    ));
    final book = (await repo.getByBookUid('video/x'))!;

    final File notSub = await writeSrt('cover.png', 'not a subtitle');
    final result = await attachSubtitleToVideoBook(
      repo: repo,
      book: book,
      subtitlePath: notSub.path,
      destDirOverride: p.join(tmp.path, 'video_subtitles'),
    );

    expect(result.outcome, SubtitleAttachOutcome.unsupported);
    expect((await repo.getByBookUid('video/x'))!.subtitleSource, isNull);
  });

  test('empty/garbage subtitle parses 0 cues -> emptyCues, not persisted',
      () async {
    final db = HibikiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = VideoBookRepository(db);
    await repo.saveVideoBook(const VideoBooksCompanion(
      bookUid: Value('video/e'),
      title: Value('E'),
      videoPath: Value('/e.mkv'),
    ));
    final book = (await repo.getByBookUid('video/e'))!;

    // .srt 扩展名但内容无任何有效 cue。
    final File empty = await writeSrt('garbage.srt', 'no timestamps here\n');
    final result = await attachSubtitleToVideoBook(
      repo: repo,
      book: book,
      subtitlePath: empty.path,
      destDirOverride: p.join(tmp.path, 'video_subtitles'),
    );

    expect(result.outcome, SubtitleAttachOutcome.emptyCues);
    // 不覆盖现有（此处本就空）：源指针仍 null、无 cue。
    expect((await repo.getByBookUid('video/e'))!.subtitleSource, isNull);
    expect(await repo.loadCues('video/e'), isEmpty);
  });
}
