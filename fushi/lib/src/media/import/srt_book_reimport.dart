import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:fushi/src/epub/epub_importer.dart';
import 'package:fushi/src/media/audiobook/audiobook_alignment_service.dart'
    show parseCuesForFormat;
import 'package:fushi/src/media/import/epub_backed_srt_book.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// 字幕书重新导入的进度回调（与 [AudiobookAlignmentProgress] 同形）。
typedef SrtBookReimportProgress = void Function(
  double fraction,
  String message,
);

/// 步骤文案注入（非 UI 层不碰 i18n，范式仿 `AudiobookAlignmentMessages`）。
class SrtBookReimportMessages {
  const SrtBookReimportMessages({
    this.parsing = '',
    this.buildingEpub = '',
    this.persisting = '',
    this.saving = '',
    this.done = '',
    this.copyingFile,
  });

  final String parsing;
  final String buildingEpub;
  final String persisting;
  final String saving;
  final String done;

  /// 复制某文件时的文案构造器（参数为 basename）；null 时复用 [persisting]。
  final String Function(String name)? copyingFile;

  String copying(String name) => copyingFile?.call(name) ?? persisting;
}

/// 正文重建的注入点（测试接缝）。生产恒为 null，走 [_rebuildGeneratedBody]。
typedef SrtBookBodyRebuilder = Future<bool> Function({
  required FushiDatabase db,
  required EpubBookRow row,
  required SrtBook book,
  required List<AudioCue> cues,
});

/// 覆写正文重建实现。真实实现要跑 isolate 解压 + path_provider 临时目录，单测里
/// 跑不动；接缝让「什么时候**该**重建、什么时候**绝不**重建」这条判据可以被正反
/// 两个方向的测试钉住（负向那条是全文件最关键的一条：EPUB 有声书的配对行重建
/// 正文 = 毁用户的书）。
@visibleForTesting
SrtBookBodyRebuilder? debugBodyRebuilder;

/// 新字幕解析不出任何 cue —— 这本书换上去就是一本没有时间轴的哑书，必须中止
/// 而不是落一份空 cue 把原来能用的对齐冲掉。
class SrtBookReimportEmptyCuesException implements Exception {
  const SrtBookReimportEmptyCuesException(this.subtitlePath);

  final String subtitlePath;

  @override
  String toString() =>
      'SrtBookReimportEmptyCuesException: no cues parsed from $subtitlePath';
}

/// 一次重新导入实际改了什么，供调用方决定后续动作（换了正文就得让阅读器重开）。
class SrtBookReimportOutcome {
  const SrtBookReimportOutcome({
    required this.audioReplaced,
    required this.subtitleReplaced,
    required this.bodyRebuilt,
    required this.cueCount,
  });

  final bool audioReplaced;
  final bool subtitleReplaced;

  /// 是否重建了配对 EPUB 的正文解压树（换字幕且该书正文由 cue 生成时才为真）。
  final bool bodyRebuilt;

  /// 换字幕后落库的 cue 条数；没换字幕时为 0。
  final int cueCount;
}

/// 字幕书（`srt_books`）的**重新导入**唯一写入路径：换音频、换字幕，或两者一起换。
///
/// 为什么必须是一个函数而不是两个入口：字幕书的正文不是用户给的文件，而是首次导入
/// 时由 cue 现生成的 EPUB（`BookImportDialog._importSubtitleBook` 的
/// `CuesToEpub.convert` -> `EpubImporter.importFromPath`）。阅读器把 cue 配回正文靠
/// **文本相等**（`_findCueForSentence`：`allCues[i].text.trim() == needle`），所以
/// 「换字幕」= 换 cue + 换正文，两者必须同一次写入对齐；只写 `SrtBooks.srtPath` 和
/// cue 会让整本书的高亮/跟读/制卡句子全部对不上。这也是此前根本没有换字幕入口的
/// 原因——它不是「再加一个 file picker」那么浅。
///
/// [audioPaths] / [subtitlePath] 为 null 表示该项不变。两者皆 null 时直接返回
/// 全 false 的 outcome（无副作用）。
///
/// 顺序刻意为「先解析新字幕 -> 再重建正文（磁盘，原子替换可回滚）-> 最后写库」：
/// 解析失败或 cue 为空时库与磁盘都还没动；正文重建失败时库也还没动，旧树由
/// [EpubImporter.rebuildExtractedInPlace] 的 `.bak` 回滚复位。
///
/// [uid] 必须命中既有字幕书，否则抛 [StateError]。
Future<SrtBookReimportOutcome> reimportSrtBook({
  required FushiDatabase db,
  required SrtBookRepository repo,
  required String uid,
  List<String>? audioPaths,
  String? subtitlePath,
  SrtBookReimportProgress? onProgress,
  SrtBookReimportMessages messages = const SrtBookReimportMessages(),
}) async {
  final bool wantAudio = audioPaths != null && audioPaths.isNotEmpty;
  final bool wantSubtitle = subtitlePath != null && subtitlePath.isNotEmpty;
  if (!wantAudio && !wantSubtitle) {
    return const SrtBookReimportOutcome(
      audioReplaced: false,
      subtitleReplaced: false,
      bodyRebuilt: false,
      cueCount: 0,
    );
  }

  final SrtBook? book = await repo.findByUid(uid);
  if (book == null) {
    throw StateError('reimportSrtBook: no SRT book for uid=$uid');
  }

  void report(double f, String m) => onProgress?.call(f, m);

  bool bodyRebuilt = false;
  int cueCount = 0;

  if (wantSubtitle) {
    report(0.05, messages.parsing);
    // cue 的命名空间是 uid（与 `SrtBookRepository.cuesFor` / 首次导入同源），
    // 不是 bookKey——两者在字幕书上是不同的键，写错整本书查不到 cue。
    final List<AudioCue> cues =
        await parseCuesForFormat(File(subtitlePath), uid, 0);
    if (cues.isEmpty) {
      throw SrtBookReimportEmptyCuesException(subtitlePath);
    }
    cueCount = cues.length;

    // ① 正文重建（只动磁盘，可回滚）。
    final EpubBookRow? bodyRow = await _rebuildableBodyRow(db, book);
    if (bodyRow != null) {
      report(0.3, messages.buildingEpub);
      bodyRebuilt = await (debugBodyRebuilder ?? _rebuildGeneratedBody)(
        db: db,
        row: bodyRow,
        book: book,
        cues: cues,
      );
    }

    // ② 持久化新字幕文件。先删旧的：`persistFileWithProgress` 撞同名会退让成
    // `<stem> _1.<ext>`，不删旧文件就会在持久目录里越堆越多，且旧文件仍占着
    // 用户以为已经被替换掉的名字。
    report(0.6, messages.persisting);
    final Directory persistDir = await AudiobookStorage.ensurePersistDir(uid);
    await _deleteOldSubtitle(persistDir: persistDir, oldPath: book.srtPath);
    final String persistedSrt = await AudiobookStorage.persistFileWithProgress(
      File(subtitlePath),
      persistDir,
      onProgress: (int copied, int total) =>
          report(0.6, messages.copying(p.basename(subtitlePath))),
    );

    // ③ 落库：cue 整组替换 + 新 srtPath。
    report(0.8, messages.saving);
    await repo.saveCues(uid: uid, cues: cues);
    book.srtPath = persistedSrt;
    await repo.save(book);
  }

  if (wantAudio) {
    report(0.85, messages.persisting);
    // 音频照旧走 `replaceAudio` 唯一写入路径（内部重新 findByUid，故排在字幕
    // 落库之后不会把刚写的 srtPath 覆盖回旧值）。
    await repo.replaceAudio(
      uid: uid,
      pickedPaths: audioPaths,
      onProgress: (int copied, int total) => report(0.85, messages.persisting),
    );
  }

  report(1, messages.done);
  return SrtBookReimportOutcome(
    audioReplaced: wantAudio,
    subtitleReplaced: wantSubtitle,
    bodyRebuilt: bodyRebuilt,
    cueCount: cueCount,
  );
}

/// 返回「正文由 cue 生成、因此换字幕时必须跟着重建」的那条 EpubBooks 行；
/// 不该重建时返回 null。
///
/// 三道闸门，任何一道不过就只换 cue 不动正文：
/// 1. [SrtBook.bookKey] 为空 = 没有配对正文（cue 解析不出来时首次导入就不生成
///    EPUB），无正文可重建；
/// 2. **uid 形态**：`srtbook_epub_<bookKey>` 是 EPUB 有声书的配对行
///    （[epubBackedSrtBookUid]），那本书的正文是用户自己的 EPUB，用 cue 重新
///    生成会**直接毁掉用户的书**——这是本文件最重要的一条负向判据；
/// 3. EpubBooks 行不存在（孤儿字幕书）→ 无处可写。
Future<EpubBookRow?> _rebuildableBodyRow(
  FushiDatabase db,
  SrtBook book,
) async {
  final String bookKey = book.bookKey;
  if (bookKey.isEmpty) return null;
  if (book.uid == epubBackedSrtBookUid(bookKey)) return null;
  return db.getEpubBook(bookKey);
}

/// 用 [cues] 重新生成正文 EPUB 并就地替换 [row] 的解压树 + 章节元数据。
/// 返回是否真的替换成功；失败只记日志并返回 false（旧正文已由原子替换回滚复位，
/// 此时 cue 与正文不一致但书仍可读，比让整次导入炸掉好）。
Future<bool> _rebuildGeneratedBody({
  required FushiDatabase db,
  required EpubBookRow row,
  required SrtBook book,
  required List<AudioCue> cues,
}) async {
  String? epubPath;
  try {
    final Directory tmpDir = await getTemporaryDirectory();
    epubPath = p.join(tmpDir.path, 'cues_to_epub_${book.uid}_rebuild.epub');
    await CuesToEpub.convert(
      title: book.title,
      cues: cues,
      outputPath: epubPath,
      author: book.author,
    );
    final ({int chapterCount, String chaptersJson, String? coverPath}) parsed =
        await EpubImporter.rebuildExtractedInPlace(
      epubFilePath: epubPath,
      extractDir: row.extractDir,
    );
    await db.updateEpubBookChapters(
      row.bookKey,
      chapterCount: parsed.chapterCount,
      chaptersJson: parsed.chaptersJson,
    );
    debugPrint('[fushi-import] srt reimport: body rebuilt key=${row.bookKey} '
        'chapters=${parsed.chapterCount} cues=${cues.length}');
    return true;
  } catch (e, stack) {
    ErrorLogService.instance.log('SrtBookReimport.rebuildBody', e, stack);
    debugPrint('[fushi-import] srt reimport: body rebuild failed: $e');
    return false;
  } finally {
    try {
      final String? tmpPath = epubPath;
      if (tmpPath != null) {
        final File tmp = File(tmpPath);
        if (tmp.existsSync()) tmp.deleteSync();
      }
    } catch (_) {}
  }
}

/// 删掉持久目录里的旧字幕文件。只删**落在持久目录内**的（引用导入模式下
/// `srtPath` 可能是用户原始文件，绝不能删用户的东西）。
Future<void> _deleteOldSubtitle({
  required Directory persistDir,
  required String oldPath,
}) async {
  if (oldPath.isEmpty) return;
  try {
    if (!p.isWithin(p.canonicalize(persistDir.path), p.canonicalize(oldPath))) {
      return;
    }
    final File old = File(oldPath);
    if (old.existsSync()) old.deleteSync();
  } catch (e, stack) {
    // 删不掉只是留了个孤儿文件，不该让重新导入失败。
    ErrorLogService.instance.log('SrtBookReimport.deleteOldSrt', e, stack);
  }
}
