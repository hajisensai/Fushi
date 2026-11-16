import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/import/import_inbox.dart';

/// 拍板台 nLXhu0d7gV：iOS「文件」App 收件箱——收走本域认的文件 / 目录，留下不认的。
void main() {
  late Directory sandbox;
  late Directory inbox;
  late Directory staging;

  File touch(String path) => File(path)
    ..createSync(recursive: true)
    ..writeAsStringSync('x');

  setUp(() {
    sandbox = Directory.systemTemp.createTempSync('import_inbox_');
    inbox = Directory(p.join(sandbox.path, 'Documents'))..createSync();
    staging = Directory(p.join(sandbox.path, 'data', 'inbox_imports'));
  });

  tearDown(() {
    if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
  });

  test('ensureKindFolders 建出三个分类子目录，重复调用不炸', () async {
    await ImportInbox.ensureKindFolders(inbox);
    await ImportInbox.ensureKindFolders(inbox);
    for (final String name in ImportInbox.kindFolderNames.values) {
      expect(Directory(p.join(inbox.path, name)).existsSync(), isTrue);
    }
  });

  test('acceptsFile 按页面种类取导入实际认的扩展名', () {
    expect(ImportInbox.acceptsFile('video', 'a/EP01.MKV'), isTrue);
    expect(ImportInbox.acceptsFile('video', 'a/EP01.ass'), isTrue);
    expect(ImportInbox.acceptsFile('video', 'a/list.m3u8'), isTrue);
    expect(
      ImportInbox.acceptsFile('video', 'a/song.flac'),
      isTrue,
      reason: '视频来源扫到的纯音频交给音乐库，与「导入文件夹」同一结果',
    );
    expect(ImportInbox.acceptsFile('video', 'a/book.epub'), isFalse);
    expect(ImportInbox.acceptsFile('book', 'a/book.epub'), isTrue);
    expect(ImportInbox.acceptsFile('book', 'a/book.m4b'), isTrue);
    expect(ImportInbox.acceptsFile('book', 'a/EP01.mkv'), isFalse);
    expect(ImportInbox.acceptsFile('manga', 'a/vol1.cbz'), isTrue);
    expect(ImportInbox.acceptsFile('manga', 'a/vol1.mokuro'), isTrue);
    expect(ImportInbox.acceptsFile('manga', 'a/p001.webp'), isTrue);
    expect(ImportInbox.acceptsFile('manga', 'a/notes.docx'), isFalse);
    expect(
      ImportInbox.acceptsFile('music', 'a/song.flac'),
      isFalse,
      reason: '没有收件箱子目录的种类一律不收',
    );
    expect(ImportInbox.acceptsFile('video', 'a/noext'), isFalse);
  });

  test('takeBatch 收走认的文件与子目录，不认的 / 隐藏项留在收件箱', () async {
    final String video = p.join(inbox.path, 'Video');
    touch(p.join(video, 'EP01.mkv'));
    touch(p.join(video, 'EP01.ja.srt'));
    touch(p.join(video, 'Season 2', 'EP01.mkv'));
    touch(p.join(video, 'notes.docx'));
    touch(p.join(video, '.DS_Store'));

    final ImportInboxBatch? batch = await ImportInbox.takeBatch(
      inbox: inbox,
      stagingRoot: staging,
      mediaKind: 'video',
      now: DateTime(2026, 11, 16, 9, 5, 7),
    );

    expect(batch, isNotNull);
    expect(batch!.failures, isEmpty);
    expect(
      batch.movedEntries,
      unorderedEquals(<String>['EP01.mkv', 'EP01.ja.srt', 'Season 2']),
    );
    expect(
      p.equals(
        batch.directory.path,
        p.join(staging.path, 'video', '20261116-090507'),
      ),
      isTrue,
    );
    expect(File(p.join(batch.directory.path, 'EP01.mkv')).existsSync(), isTrue);
    expect(
      File(p.join(batch.directory.path, 'EP01.ja.srt')).existsSync(),
      isTrue,
    );
    expect(
      File(p.join(batch.directory.path, 'Season 2', 'EP01.mkv')).existsSync(),
      isTrue,
    );
    // 收件箱里：认的被移走，不认的与隐藏项原样留着。
    expect(File(p.join(video, 'EP01.mkv')).existsSync(), isFalse);
    expect(Directory(p.join(video, 'Season 2')).existsSync(), isFalse);
    expect(File(p.join(video, 'notes.docx')).existsSync(), isTrue);
    expect(File(p.join(video, '.DS_Store')).existsSync(), isTrue);

    // 再收一次：只剩不认的 → 没有批次。
    expect(
      await ImportInbox.takeBatch(
        inbox: inbox,
        stagingRoot: staging,
        mediaKind: 'video',
      ),
      isNull,
    );
  });

  test('子目录不存在 / 为空 → 没有批次，也不建空批次目录', () async {
    expect(
      await ImportInbox.takeBatch(
        inbox: inbox,
        stagingRoot: staging,
        mediaKind: 'book',
      ),
      isNull,
    );
    Directory(p.join(inbox.path, 'Books')).createSync();
    expect(
      await ImportInbox.takeBatch(
        inbox: inbox,
        stagingRoot: staging,
        mediaKind: 'book',
      ),
      isNull,
    );
    expect(staging.existsSync(), isFalse);
  });

  test('同一秒内收两批：批次目录不合并（否则一次性扫描会把上一批再扫一遍）', () async {
    final DateTime now = DateTime(2026, 11, 16, 9, 5, 7);
    touch(p.join(inbox.path, 'Manga', 'vol1.cbz'));
    final ImportInboxBatch? first = await ImportInbox.takeBatch(
      inbox: inbox,
      stagingRoot: staging,
      mediaKind: 'manga',
      now: now,
    );
    touch(p.join(inbox.path, 'Manga', 'vol2.cbz'));
    final ImportInboxBatch? second = await ImportInbox.takeBatch(
      inbox: inbox,
      stagingRoot: staging,
      mediaKind: 'manga',
      now: now,
    );

    expect(first!.directory.path, isNot(second!.directory.path));
    expect(second.movedEntries, <String>['vol2.cbz']);
    expect(
      first.directory.listSync().map(
        (FileSystemEntity e) => p.basename(e.path),
      ),
      <String>['vol1.cbz'],
    );
  });
}
