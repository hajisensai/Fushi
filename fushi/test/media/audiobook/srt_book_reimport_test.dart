import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/import/epub_backed_srt_book.dart';
import 'package:fushi/src/media/import/srt_book_reimport.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

/// 用户报「有声书没办法重新导入 / 导入音频没用 / 导不了字幕文件」的写入侧回归。
///
/// 这里守的是 [reimportSrtBook] 的四条不变式：
/// 1. 换字幕真的把 cue 整组换掉并改写 `SrtBooks.srtPath`（旧代码全仓没有这条路径）；
/// 2. 新字幕解析不出 cue 时**整次中止**，旧 cue / 旧 srtPath 一个字节都不动；
/// 3. **EPUB 有声书的配对行（`srtbook_epub_<bookKey>`）绝不重建正文**——那本书的
///    正文是用户自己的 EPUB，用 cue 重生成等于毁书；
/// 4. 换音频仍走 `replaceAudio` 的整组替换语义。
void main() {
  late FushiDatabase db;
  late SrtBookRepository repo;
  late Directory docsRoot;
  late Directory workDir;
  late List<({String bookKey, List<String> cueTexts})> rebuildCalls;

  setUp(() {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    repo = SrtBookRepository(db);
    docsRoot = Directory.systemTemp.createTempSync('fushi_srt_reimport_docs');
    workDir = Directory.systemTemp.createTempSync('fushi_srt_reimport_work');
    AudiobookStorage.documentsRootResolver = () async => docsRoot;
    // 真实重建要跑 isolate 解压 + path_provider 临时目录，单测跑不动；这里只记录
    // 「有没有被调用、拿到的是不是新 cue」，判据本身照常由生产代码决定。
    rebuildCalls = <({String bookKey, List<String> cueTexts})>[];
    debugBodyRebuilder = ({
      required FushiDatabase db,
      required EpubBookRow row,
      required SrtBook book,
      required List<AudioCue> cues,
    }) async {
      rebuildCalls.add((
        bookKey: row.bookKey,
        cueTexts: cues.map((AudioCue c) => c.text).toList(),
      ));
      return true;
    };
  });

  tearDown(() async {
    AudiobookStorage.documentsRootResolver = null;
    debugBodyRebuilder = null;
    await db.close();
    for (final Directory dir in <Directory>[docsRoot, workDir]) {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    }
  });

  File writeSubtitle(
      String name, List<(String start, String end, String text)> lines) {
    final StringBuffer buf = StringBuffer();
    for (int i = 0; i < lines.length; i++) {
      final (String start, String end, String text) = lines[i];
      buf.writeln('${i + 1}');
      buf.writeln('$start --> $end');
      buf.writeln(text);
      buf.writeln();
    }
    final File file = File(p.join(workDir.path, name));
    file.writeAsStringSync(buf.toString());
    return file;
  }

  File writeAudio(String name) {
    final File file = File(p.join(workDir.path, name));
    file.writeAsBytesSync(<int>[0, 1, 2, 3]);
    return file;
  }

  Future<SrtBook> seedBook({
    required String uid,
    required String bookKey,
    required String srtPath,
    List<String>? audioPaths,
  }) async {
    final SrtBook book = SrtBook()
      ..uid = uid
      ..title = 'Demo'
      ..srtPath = srtPath
      ..bookKey = bookKey
      ..importedAt = 1
      ..audioPaths = audioPaths;
    await repo.save(book);
    return (await repo.findByUid(uid))!;
  }

  test('换字幕：cue 整组换掉且 srtPath 指向持久目录里的新文件', () async {
    final File oldSrt = writeSubtitle('old.srt', <(String, String, String)>[
      ('00:00:01,000', '00:00:02,000', '旧句一'),
    ]);
    await seedBook(uid: 'srtbook_1', bookKey: '', srtPath: oldSrt.path);
    await repo.saveCues(
      uid: 'srtbook_1',
      cues: await SrtParser.parse(
          srtFile: oldSrt, bookKey: 'srtbook_1', audioFileIndex: 0),
    );

    final File newSrt = writeSubtitle('new.srt', <(String, String, String)>[
      ('00:00:03,000', '00:00:04,000', '新句一'),
      ('00:00:05,000', '00:00:06,000', '新句二'),
    ]);

    final SrtBookReimportOutcome outcome = await reimportSrtBook(
      db: db,
      repo: repo,
      uid: 'srtbook_1',
      subtitlePath: newSrt.path,
    );

    expect(outcome.subtitleReplaced, isTrue);
    expect(outcome.audioReplaced, isFalse);
    // bookKey 为空 = 没有配对正文，重建无从谈起。
    expect(outcome.bodyRebuilt, isFalse);
    expect(outcome.cueCount, 2);

    final List<AudioCue> cues = await repo.cuesFor('srtbook_1');
    expect(cues.map((AudioCue c) => c.text).toList(), <String>['新句一', '新句二']);

    final SrtBook? saved = await repo.findByUid('srtbook_1');
    expect(saved, isNotNull);
    expect(p.basename(saved!.srtPath), 'new.srt');
    expect(File(saved.srtPath).existsSync(), isTrue,
        reason: '新字幕必须被复制进持久目录，而不是只记下用户的原始路径');
    expect(
      p.isWithin(p.canonicalize(docsRoot.path), p.canonicalize(saved.srtPath)),
      isTrue,
    );
  });

  test('新字幕解析不出 cue：整次中止，旧 cue 与旧 srtPath 原样不动', () async {
    final File oldSrt = writeSubtitle('old.srt', <(String, String, String)>[
      ('00:00:01,000', '00:00:02,000', '旧句一'),
    ]);
    await seedBook(uid: 'srtbook_2', bookKey: '', srtPath: oldSrt.path);
    await repo.saveCues(
      uid: 'srtbook_2',
      cues: await SrtParser.parse(
          srtFile: oldSrt, bookKey: 'srtbook_2', audioFileIndex: 0),
    );

    final File junk = File(p.join(workDir.path, 'junk.srt'))
      ..writeAsStringSync('这不是字幕，没有任何时间码');

    await expectLater(
      reimportSrtBook(
          db: db, repo: repo, uid: 'srtbook_2', subtitlePath: junk.path),
      throwsA(isA<SrtBookReimportEmptyCuesException>()),
    );

    final List<AudioCue> cues = await repo.cuesFor('srtbook_2');
    expect(cues.map((AudioCue c) => c.text).toList(), <String>['旧句一']);
    expect((await repo.findByUid('srtbook_2'))!.srtPath, oldSrt.path);
  });

  test('EPUB 有声书的配对行换字幕：绝不重建正文（不碰 epub_books 章节列）', () async {
    const String bookKey = 'user-epub-book';
    const String chaptersJson = '[{"id":"c1","href":"c1.xhtml"}]';
    await db.insertEpubBook(EpubBooksCompanion.insert(
      bookKey: bookKey,
      title: 'User EPUB',
      epubPath: 'user.epub',
      extractDir: p.join(workDir.path, 'extract'),
      chapterCount: 1,
      chaptersJson: chaptersJson,
      importedAt: 1,
    ));

    final File oldSrt =
        writeSubtitle('paired-old.srt', <(String, String, String)>[
      ('00:00:01,000', '00:00:02,000', '旧句一'),
    ]);
    final String uid = epubBackedSrtBookUid(bookKey);
    await seedBook(uid: uid, bookKey: bookKey, srtPath: oldSrt.path);

    final File newSrt =
        writeSubtitle('paired-new.srt', <(String, String, String)>[
      ('00:00:03,000', '00:00:04,000', '新句一'),
    ]);

    final SrtBookReimportOutcome outcome = await reimportSrtBook(
      db: db,
      repo: repo,
      uid: uid,
      subtitlePath: newSrt.path,
    );

    expect(outcome.subtitleReplaced, isTrue);
    expect(outcome.bodyRebuilt, isFalse,
        reason: '配对行的正文是用户自己的 EPUB，用 cue 重生成会直接毁书');
    expect(rebuildCalls, isEmpty, reason: '不是「重建失败」而是**根本不该走到重建**');

    final EpubBookRow? row = await db.getEpubBook(bookKey);
    expect(row, isNotNull);
    expect(row!.chaptersJson, chaptersJson);
    expect(row.chapterCount, 1);
  });

  test('普通字幕书换字幕：正文必须跟着用新 cue 重建', () async {
    const String bookKey = 'generated-body-book';
    await db.insertEpubBook(EpubBooksCompanion.insert(
      bookKey: bookKey,
      title: 'Generated',
      epubPath: 'generated.epub',
      extractDir: p.join(workDir.path, 'gen-extract'),
      chapterCount: 1,
      chaptersJson: '[]',
      importedAt: 1,
    ));

    final File oldSrt = writeSubtitle('gen-old.srt', <(String, String, String)>[
      ('00:00:01,000', '00:00:02,000', '旧句一'),
    ]);
    // uid 是 `srtbook_<ts>` 形态（首次导入由 cue 生成正文），不是配对行形态。
    await seedBook(uid: 'srtbook_gen', bookKey: bookKey, srtPath: oldSrt.path);

    final File newSrt = writeSubtitle('gen-new.srt', <(String, String, String)>[
      ('00:00:03,000', '00:00:04,000', '新句一'),
      ('00:00:05,000', '00:00:06,000', '新句二'),
    ]);

    final SrtBookReimportOutcome outcome = await reimportSrtBook(
      db: db,
      repo: repo,
      uid: 'srtbook_gen',
      subtitlePath: newSrt.path,
    );

    expect(outcome.bodyRebuilt, isTrue);
    expect(rebuildCalls, hasLength(1));
    expect(rebuildCalls.single.bookKey, bookKey);
    // 正文必须由**新**字幕的 cue 生成——阅读器把 cue 配回正文靠文本相等，
    // 拿旧 cue 重建等于什么都没换。
    expect(rebuildCalls.single.cueTexts, <String>['新句一', '新句二']);
  });

  test('换音频：audioPaths 整组替换并复制进持久目录', () async {
    final File srt = writeSubtitle('a.srt', <(String, String, String)>[
      ('00:00:01,000', '00:00:02,000', '句一'),
    ]);
    await seedBook(
      uid: 'srtbook_3',
      bookKey: '',
      srtPath: srt.path,
      audioPaths: <String>['/gone/old.m4a'],
    );

    final File a1 = writeAudio('01.m4a');
    final File a2 = writeAudio('02.m4a');

    final SrtBookReimportOutcome outcome = await reimportSrtBook(
      db: db,
      repo: repo,
      uid: 'srtbook_3',
      audioPaths: <String>[a1.path, a2.path],
    );

    expect(outcome.audioReplaced, isTrue);
    expect(outcome.subtitleReplaced, isFalse);

    final SrtBook saved = (await repo.findByUid('srtbook_3'))!;
    expect(saved.audioPaths, hasLength(2));
    expect(saved.audioRoot, isNull);
    for (final String path in saved.audioPaths!) {
      expect(File(path).existsSync(), isTrue);
      expect(
        p.isWithin(p.canonicalize(docsRoot.path), p.canonicalize(path)),
        isTrue,
      );
    }
  });

  test('两边都不给：无副作用直接返回', () async {
    final File srt = writeSubtitle('b.srt', <(String, String, String)>[
      ('00:00:01,000', '00:00:02,000', '句一'),
    ]);
    await seedBook(uid: 'srtbook_4', bookKey: '', srtPath: srt.path);

    final SrtBookReimportOutcome outcome =
        await reimportSrtBook(db: db, repo: repo, uid: 'srtbook_4');

    expect(outcome.audioReplaced, isFalse);
    expect(outcome.subtitleReplaced, isFalse);
    expect((await repo.findByUid('srtbook_4'))!.srtPath, srt.path);
  });
}
