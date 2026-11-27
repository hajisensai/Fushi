import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart' show fushiDatabaseFileName;
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite;

import 'package:fushi/src/pages/implementations/android_storage_move_prompt.dart'
    show libraryContentMissingFeedbackPrefill;
import 'package:fushi/src/pages/implementations/feedback/feedback_compose_prefill.dart';
import 'package:fushi/src/storage/library_content_audit.dart';
import 'package:fushi/src/storage/library_sentinel.dart';
import 'package:fushi_engine/feedback/feedback_models.dart';

/// BUG-5570（反馈 1DaVBFXQEI / #4521）：受管书库里 94 个解包书目录丢了 82 个、74 个有声书
/// 音频 / 字幕文件丢了，数据库行都在，哨兵文件也在——[LibrarySentinel] 判 intact，启动期
/// 没有任何告警。书库内容对账拿数据库当账本，发现「有行、没文件」成片缺失就留现场；
/// 存储不可读不误报；全程不动任何行与文件。
void main() {
  late Directory tmp;
  late Directory library;
  late Directory support;
  late sqlite.Database db;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('fushi_library_content_audit_');
    library = Directory(p.join(tmp.path, 'library'))..createSync();
    support = Directory(p.join(tmp.path, 'support'))..createSync();
    db = sqlite.sqlite3.open(p.join(support.path, fushiDatabaseFileName));
    db.execute('CREATE TABLE epub_books (extract_dir TEXT, format TEXT)');
    db.execute(
      'CREATE TABLE audiobooks (audio_root TEXT, audio_paths_json TEXT, '
      'alignment_path TEXT)',
    );
    db.execute(
      'CREATE TABLE srt_books (srt_path TEXT, audio_root TEXT, '
      'audio_paths_json TEXT)',
    );
    db.execute('CREATE TABLE video_books (video_path TEXT)');
  });

  tearDown(() {
    db.dispose();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  String bookDir(int i) => p.join(library.path, 'fushi_books', 'book_$i');

  /// [n] 本解包书：数据库一行 + 磁盘一个目录（里面一个章节文件）。
  void addBooks(int n, {String format = 'epub'}) {
    for (int i = 0; i < n; i++) {
      final Directory dir = Directory(bookDir(i))..createSync(recursive: true);
      File(p.join(dir.path, 'ch1.xhtml')).writeAsStringSync('x');
      db.execute('INSERT INTO epub_books VALUES (?, ?)', <Object?>[
        dir.path,
        format,
      ]);
    }
  }

  /// 一本有声书：音频目录里 [files] 个音频 + 一个字幕，路径列表进 audio_paths_json。
  List<String> addAudiobook(String key, int files) {
    final Directory dir = Directory(p.join(library.path, 'audiobooks', key))
      ..createSync(recursive: true);
    final List<String> audio = <String>[
      for (int i = 0; i < files; i++) p.join(dir.path, '$i.mp3'),
    ];
    for (final String a in audio) {
      File(a).writeAsStringSync('a');
    }
    final String srt = p.join(dir.path, 'book.srt');
    File(srt).writeAsStringSync('1');
    db.execute('INSERT INTO audiobooks VALUES (?, ?, ?)', <Object?>[
      null,
      jsonEncode(audio),
      srt,
    ]);
    return <String>[...audio, srt];
  }

  Future<LibraryContentAuditResult> run(DateTime at) => LibraryContentAudit.run(
    libraryRoot: library,
    supportRoot: support,
    now: at,
  );

  test('哨兵还在、解包书目录成片被删：哨兵判 intact，对账留下现场', () async {
    addBooks(94);
    final List<String> audio = addAudiobook('ab', 74);
    // 第一次启动：哨兵布防。
    await LibrarySentinel.check(
      libraryRoot: library,
      supportRoot: support,
      now: DateTime(2026, 11, 1),
    );
    expect(
      (await run(DateTime(2026, 11, 1))).status,
      LibraryContentAuditStatus.clean,
    );
    // 外部工具删掉 82 个书目录与全部有声书音频 / 字幕，哨兵文件与书库根都还在。
    for (int i = 0; i < 82; i++) {
      Directory(bookDir(i)).deleteSync(recursive: true);
    }
    for (final String a in audio) {
      File(a).deleteSync();
    }

    final LibrarySentinelResult sentinel = await LibrarySentinel.check(
      libraryRoot: library,
      supportRoot: support,
      now: DateTime(2026, 11, 2),
    );
    // 缺口本身：哨兵看不出部分丢失。
    expect(sentinel.status, LibrarySentinelStatus.intact);
    expect(await LibrarySentinel.pendingIncident(support), isNull);

    final LibraryContentAuditResult audit = await run(DateTime(2026, 11, 2));
    expect(audit.status, LibraryContentAuditStatus.incident);
    final LibraryContentLoss loss = audit.loss!;
    final LibraryContentKindTally books = loss.kinds[LibraryContentKind.books]!;
    expect(books.checkedRows, 94);
    expect(books.missingRows, 82);
    expect(books.samples, hasLength(LibraryContentAudit.maxSamplesPerKind));
    final LibraryContentKindTally ab =
        loss.kinds[LibraryContentKind.audiobooks]!;
    expect(ab.checkedRows, 1);
    expect(ab.missingRows, 1);
    expect(ab.missingPaths, 75);
    expect(loss.isSignificant, isTrue);
    expect(loss.describe(), contains('books 缺 82/94 行'));
    expect(loss.describe(), contains(library.path));

    // 现场留给首页；不动任何行与剩下的文件。
    final LibraryContentLoss? pending = await LibraryContentAudit.pendingLoss(
      support,
    );
    expect(pending?.missingRows, 83);
    expect(db.select('SELECT COUNT(*) AS n FROM epub_books').first['n'], 94);
    expect(db.select('SELECT COUNT(*) AS n FROM audiobooks').first['n'], 1);
    for (int i = 82; i < 94; i++) {
      expect(Directory(bookDir(i)).existsSync(), isTrue);
    }
  });

  test('同一批缺失提示过就不再提示；再丢更多才重新提示；恢复后清零', () async {
    addBooks(10);
    for (int i = 0; i < 5; i++) {
      Directory(bookDir(i)).deleteSync(recursive: true);
    }
    expect(
      (await run(DateTime(2026, 11, 1))).status,
      LibraryContentAuditStatus.incident,
    );
    await LibraryContentAudit.clearPending(support);
    expect(await LibraryContentAudit.pendingLoss(support), isNull);

    expect(
      (await run(DateTime(2026, 11, 2))).status,
      LibraryContentAuditStatus.alreadyReported,
    );
    expect(await LibraryContentAudit.pendingLoss(support), isNull);

    Directory(bookDir(5)).deleteSync(recursive: true);
    final LibraryContentAuditResult more = await run(DateTime(2026, 11, 3));
    expect(more.status, LibraryContentAuditStatus.incident);
    expect((await LibraryContentAudit.pendingLoss(support))?.missingRows, 6);
    await LibraryContentAudit.clearPending(support);

    // 用户重新扫描 / 同步恢复了全部：基线清零，之后再丢会重新提示。
    for (int i = 0; i < 6; i++) {
      Directory(bookDir(i)).createSync(recursive: true);
    }
    expect(
      (await run(DateTime(2026, 11, 4))).status,
      LibraryContentAuditStatus.clean,
    );
    for (int i = 0; i < 3; i++) {
      Directory(bookDir(i)).deleteSync(recursive: true);
    }
    expect(
      (await run(DateTime(2026, 11, 5))).status,
      LibraryContentAuditStatus.incident,
    );
  });

  test('零星一两条残行不提示（只进日志）', () async {
    addBooks(50);
    Directory(bookDir(0)).deleteSync(recursive: true);
    final LibraryContentAuditResult audit = await run(DateTime(2026, 11, 1));
    expect(audit.status, LibraryContentAuditStatus.minor);
    expect(audit.loss!.missingRows, 1);
    expect(await LibraryContentAudit.pendingLoss(support), isNull);
  });

  test('书库根不在（外部卷未挂载 / 权限被收回）不判缺失', () async {
    addBooks(10);
    library.deleteSync(recursive: true);
    final LibraryContentAuditResult audit = await run(DateTime(2026, 11, 1));
    expect(audit.status, LibraryContentAuditStatus.rootUnreadable);
    expect(await LibraryContentAudit.pendingLoss(support), isNull);
    expect(
      File(p.join(support.path, LibraryContentAudit.fileName)).existsSync(),
      isFalse,
    );
  });

  test('顶层受管目录整个不在（书库根可读）是真缺失', () async {
    addBooks(10);
    Directory(p.join(library.path, 'fushi_books')).deleteSync(recursive: true);
    File(p.join(library.path, 'keep.txt')).writeAsStringSync('x');
    final LibraryContentAuditResult audit = await run(DateTime(2026, 11, 1));
    expect(audit.status, LibraryContentAuditStatus.incident);
    expect(audit.loss!.missingRows, 10);
  });

  test('库里记的是旧根前缀、文件在本次书库根下：不算缺失', () async {
    for (int i = 0; i < 5; i++) {
      Directory(bookDir(i)).createSync(recursive: true);
      db.execute('INSERT INTO epub_books VALUES (?, ?)', <Object?>[
        p.join(tmp.path, 'old_root', 'fushi_books', 'book_$i'),
        'epub',
      ]);
    }
    final LibraryContentAuditResult audit = await run(DateTime(2026, 11, 1));
    expect(audit.status, LibraryContentAuditStatus.clean);
    expect(audit.loss!.kinds[LibraryContentKind.books]!.checkedRows, 5);
  });

  test('书库外的路径（外部来源、原地播放视频）不参与对账', () async {
    for (int i = 0; i < 5; i++) {
      db.execute('INSERT INTO video_books VALUES (?)', <Object?>[
        p.join(tmp.path, 'Movies', 'v$i.mkv'),
      ]);
      db.execute('INSERT INTO epub_books VALUES (?, ?)', <Object?>[
        'relative/dir_$i',
        'epub',
      ]);
    }
    final LibraryContentAuditResult audit = await run(DateTime(2026, 11, 1));
    expect(audit.status, LibraryContentAuditStatus.clean);
    expect(audit.loss!.checkedRows, 0);
  });

  test('漫画单独计数', () async {
    addBooks(4, format: 'manga');
    for (int i = 0; i < 4; i++) {
      Directory(bookDir(i)).deleteSync(recursive: true);
    }
    final LibraryContentAuditResult audit = await run(DateTime(2026, 11, 1));
    expect(audit.status, LibraryContentAuditStatus.incident);
    expect(audit.loss!.kinds.keys, <LibraryContentKind>[
      LibraryContentKind.manga,
    ]);
  });

  test('主库不在：报 error，不写现场', () async {
    db.dispose();
    File(p.join(support.path, fushiDatabaseFileName)).deleteSync();
    db = sqlite.sqlite3.openInMemory();
    final LibraryContentAuditResult audit = await run(DateTime(2026, 11, 1));
    expect(audit.status, LibraryContentAuditStatus.error);
    expect(await LibraryContentAudit.pendingLoss(support), isNull);
  });

  test('顶层目录存在却列不出来：其下条目记不可读，不算缺失', () {
    final String root = p.join('R', 'lib');
    final LibraryContentLoss loss = LibraryContentAudit.tally(
      rows: <LibraryContentRow>[
        for (int i = 0; i < 5; i++)
          (
            kind: LibraryContentKind.books,
            paths: <String>['/R/lib/fushi_books/b$i'],
          ),
        (
          kind: LibraryContentKind.audiobooks,
          paths: <String>['/R/lib/audiobooks/a/1.mp3'],
        ),
      ],
      libraryRoot: root,
      exists: (String _) => false,
      bucketReadable: (String bucket) =>
          p.basename(bucket) == 'fushi_books' ? null : true,
      at: DateTime(2026, 11, 1),
    );
    expect(loss.kinds[LibraryContentKind.books]!.missingRows, 0);
    expect(loss.kinds[LibraryContentKind.books]!.unreadableRows, 5);
    expect(loss.kinds[LibraryContentKind.audiobooks]!.missingRows, 1);
    expect(loss.unreadableBuckets, <String>['fushi_books']);
    expect(loss.isSignificant, isFalse);
  });

  test('现场 JSON 往返；反馈预填带现场摘要', () {
    final LibraryContentLoss loss = LibraryContentLoss(
      detectedAt: DateTime(2026, 11, 2),
      libraryRoot: '/lib',
      kinds: <LibraryContentKind, LibraryContentKindTally>{
        LibraryContentKind.books: LibraryContentKindTally(
          checkedRows: 94,
          missingRows: 82,
          missingPaths: 82,
          samples: <String>['/lib/fushi_books/a'],
        ),
      },
      unreadableBuckets: const <String>['audiobooks'],
    );
    expect(LibraryContentLoss.fromJson(loss.toJson())?.toJson(), loss.toJson());
    final FeedbackComposePrefill prefill = libraryContentMissingFeedbackPrefill(
      loss,
    );
    expect(prefill.category, FeedbackCategory.bug);
    expect(prefill.body, contains(loss.describe()));
  });
}
