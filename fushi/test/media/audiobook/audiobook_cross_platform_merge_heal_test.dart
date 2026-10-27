import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/audiobook_session_launcher.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

/// BUG-3811（反馈 XDtB1kYT0C）：Windows 备份合并导入到 Android 后，EPUB 配对的
/// 有声书「能出声但字幕不跟、进度归零」。
///
/// 真实链路：合并导入的路径 rebase 保留了源设备的 `\`，`audiobooks` 行与配对的
/// `srtbook_epub_<bookKey>` 行都指着 Android 上不存在的文件。书架列出时
/// [SrtBookRepository.repairMovedPaths] 只自愈了 `srt_books`，`audiobooks` 行仍坏；
/// [AudiobookSessionLauncher] 于是退到配对 srt 行、按 uid 身份起播——cue 与进度
/// 都挂在 bookKey 上，uid 下恒为空。
///
/// 这里不碰 launcher 的回退规则（配对 srt 行自己持有音频与 cue 是合法状态，见
/// `audiobook_session_launcher_heal_test.dart`），锁的是「两张表的同一份路径必须
/// 一起被修」：修完后 launcher 落在 `audiobooks` 行、拿到 bookKey 下的 cue 与进度。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory docs;
  late Directory root;
  late FushiDatabase db;

  setUp(() async {
    docs = await Directory.systemTemp.createTemp('ab_xplat_heal_');
    root = Directory(p.join(docs.path, 'audiobooks'))
      ..createSync(recursive: true);
    // 生产接线同 srt_path_relocate_repair_test：listAll() 走这条根解析路径。
    AudiobookStorage.documentsRootResolver = () async => docs;
    db = FushiDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
    AudiobookStorage.documentsRootResolver = null;
    if (docs.existsSync()) {
      try {
        docs.deleteSync(recursive: true);
      } on FileSystemException {
        // Windows 上偶发句柄未释放，与测试结论无关。
      }
    }
  });

  test(
    'shelf listing heals the audiobooks row together with its paired srt '
    'row, so the session resolves on bookKey with its cues and position',
    () async {
      const String bookKey = 'epub_book_key';
      const String dirName = 'd4515d05';
      // 备份随包的文件按归档相对路径落在本机 audiobooks 根下（_copyTreeIfAbsent）。
      final File audio = File(p.join(root.path, dirName, 'book.m4b'))
        ..createSync(recursive: true)
        ..writeAsStringSync('AUDIO');
      final File srt = File(p.join(root.path, dirName, 'transcript.srt'))
        ..writeAsStringSync('1\n00:00:00,000 --> 00:00:01,000\nHello\n');

      // 源设备（Windows）的路径原样留在行里：两张表指着同一批文件。
      const String winDir =
          r'C:\Users\someone\AppData\Roaming\fushi\audiobooks\' + dirName;
      const String winAudio = '$winDir\\book.m4b';
      const String winSrt = '$winDir\\transcript.srt';

      final AudiobookRepository abRepo = AudiobookRepository(db);
      await abRepo.replaceAlignment(
        bookKey: bookKey,
        format: 'srt',
        path: winSrt,
      );
      // 直写路径列（= 合并引擎逐列插入 + rebase 之后的形态），不经 replaceAudio
      // 的「换音频即归零进度」语义。
      await db.updateAudiobookPaths(
        bookKey,
        audioPathsJson: jsonEncode(<String>[winAudio]),
      );
      final SrtBook paired = SrtBook()
        ..uid = 'srtbook_epub_$bookKey'
        ..title = 'Paired'
        ..srtPath = winSrt
        ..audioPaths = <String>[winAudio]
        ..importedAt = 1
        ..bookKey = bookKey;
      await SrtBookRepository(db).save(paired);

      // cue 与进度挂在 bookKey 上（合并引擎带过来的 audio_cues / audiobook_pos_*）。
      await db.replaceCuesForBook(bookKey, <AudioCuesCompanion>[
        for (int i = 0; i < 3; i++)
          AudioCuesCompanion.insert(
            bookKey: bookKey,
            chapterHref: 'chapter.xhtml',
            sentenceIndex: i,
            textFragmentId: 'f$i',
            cueText: 'cue $i',
            startMs: i * 1000,
            endMs: i * 1000 + 900,
            audioFileIndex: 0,
          ),
      ]);
      await abRepo.updatePositionMs(bookKey: bookKey, positionMs: 1500);

      // 书架列出 = 生产上触发自愈的那一屏。
      await SrtBookRepository(db).listAll();

      final AudiobookRow? abRow = await db.getAudiobookByBookKey(bookKey);
      expect(jsonDecode(abRow!.audioPathsJson!), <String>[
        audio.path,
      ], reason: 'audiobooks 行必须和配对 srt 行一起被修');
      expect(abRow.alignmentPath, srt.path);

      final AudiobookSessionStartRequest? req = await AudiobookSessionLauncher(
        db,
      ).resolve(bookKey);
      expect(req, isNotNull);
      expect(
        req!.isSrtBookSource,
        isFalse,
        reason: '不得退到配对 srt 行（uid 身份下没有 cue / 进度）',
      );
      expect(req.info.bookKey, bookKey);
      expect(req.audioFiles.single.path, audio.path);
      expect(req.cues, hasLength(3), reason: '字幕跟随靠 bookKey 下的 cue');
      expect(req.prefs.positionMs, 1500, reason: '进度不得归零');
    },
  );

  test('a healthy audiobooks row is never rewritten', () async {
    const String bookKey = 'healthy';
    final File audio = File(p.join(root.path, 'h1', 'a.mp3'))
      ..createSync(recursive: true)
      ..writeAsStringSync('A');
    await AudiobookRepository(db).ensureAudiobook(bookKey);
    await db.updateAudiobookPaths(
      bookKey,
      audioPathsJson: jsonEncode(<String>[audio.path]),
    );

    expect(
      await SrtBookRepository(db).repairMovedPaths(
        listEntries: (String _) => throw StateError('健康库不得触发目录扫描'),
      ),
      0,
    );
    final AudiobookRow? row = await db.getAudiobookByBookKey(bookKey);
    expect(jsonDecode(row!.audioPathsJson!), <String>[audio.path]);
  });
}
