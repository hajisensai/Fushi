/// 独立字幕书：只有字幕（+ 可选音频）、没有正文时，用字幕行生成 EPUB 当正文，
/// 落一条带音频的 `SrtBook`。
///
/// 原先是 `BookImportDialog._importSubtitleBook` 的私有实现；发现页自动入库
/// （字幕 + 音频的包、设备端转录的产物）要同一条路，抽到这里成为唯一真相，
/// 对话框改调本函数。UI 相关的东西（文案、同名书弹窗、封面抽取）经参数注入。
library;

import 'dart:io';

import 'package:fushi_audio/fushi_audio_core.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/book_title_conflict.dart';
import 'package:fushi_engine/epub/epub_importer.dart';
import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/foundation/engine_paths.dart';
import 'package:fushi_engine/media/audiobook/audiobook_alignment_service.dart';
import 'package:path/path.dart' as p;

/// 导入进行到哪一步（调用方翻译成文案）。
enum StandaloneSubtitleBookStep {
  parsing,
  buildingEpub,
  importingEpub,
  persisting,
  copyingFile,
  saving,
  done,
}

/// 进度回调：[fileName] 只在 [StandaloneSubtitleBookStep.copyingFile] 时给。
typedef StandaloneSubtitleBookProgress =
    void Function(
      double fraction,
      StandaloneSubtitleBookStep step,
      String? fileName,
    );

/// 导入一本独立字幕书，返回落库的 [SrtBook]。
///
/// - [policy]：正文 EPUB 同名时的处置。取消/跳过以
///   `DuplicateImportCancelledException` 冒泡，**不会**落任何行。
/// - [copyAudio]：false = 引用原始路径（桌面「不复制」模式）。
/// - [persistCover]：拿到持久目录后写封面，返回封面路径（写不了返回 null）。
/// - [tempDir]：生成 EPUB 的临时目录；缺省取 `enginePaths` 的临时根。
/// - [cueTransform]：解析出 cue 之后、生成正文与落库之前对 cue 做一次改写。远端
///   （流式）音频用它把整本书时间轴上的字幕按音轨切成各文件内的本地时间；缺省不改。
///
/// [adoptSubtitleFile]：[subtitlePath] 是调用方放在 [AudiobookStorage.stagingDir]
/// 里的暂存文件（如从服务器下载的字幕），持久化时 rename 进持久目录
/// （[AudiobookStorage.adoptFile]）而不是复制，导入成功后它就不在原处了，调用方
/// 不用再清理；导入失败时它可能还在暂存目录（未被接管）或已随回滚删掉，调用方在
/// 失败路径上删掉仍在的那份。
///
/// 正文 EPUB 落库之后任何一步失败，都由 [rollbackStandaloneSubtitleBook] 撤掉
/// 已落的 SrtBook、正文 EPUB 与持久目录再抛，不留孤儿行。
///
/// [subtitlePath] 为 null = 没有字幕（纯听书）：不解析、不落字幕文件，但仍生成一份
/// 只有标题的正文 EPUB，阅读器才打得开；之后补字幕走 `reimportSrtBook`，它会重建正文。
///
/// 字幕解析出 0 条 cue 时与对话框历史行为一致：不生成正文，仍落一条只有字幕
/// 与音频的书（`bookKey` 为空串）。需要「0 条即失败」语义的调用方（转录产物）
/// 自己在调用前判。
Future<SrtBook> importStandaloneSubtitleBook({
  required FushiDatabase db,
  required SrtBookRepository repo,
  required String title,
  String? author,
  String? subtitlePath,
  bool adoptSubtitleFile = false,
  List<String> audioPaths = const <String>[],
  bool copyAudio = true,
  required DuplicatePolicy policy,
  Directory? tempDir,
  Future<String?> Function(Directory persistDir)? persistCover,
  List<AudioCue> Function(List<AudioCue> cues)? cueTransform,
  StandaloneSubtitleBookProgress? onProgress,
}) async {
  void report(double f, StandaloneSubtitleBookStep step, [String? name]) =>
      onProgress?.call(f, step, name);

  final String uid = 'srtbook_${DateTime.now().millisecondsSinceEpoch}';
  report(0.1, StandaloneSubtitleBookStep.parsing);

  final List<AudioCue> parsed = subtitlePath == null
      ? const <AudioCue>[]
      : await parseCuesForFormat(File(subtitlePath), uid, 0);
  final List<AudioCue> cues = cueTransform?.call(parsed) ?? parsed;
  fushiDebugPrint('[fushi-import] subtitleBook: parsed ${cues.length} cues');

  String bookKey = '';
  if (cues.isNotEmpty || subtitlePath == null) {
    try {
      report(0.3, StandaloneSubtitleBookStep.buildingEpub);
      final Directory tmp = tempDir ?? await enginePaths.tempRootDirectory();
      final String epubPath = p.join(tmp.path, 'cues_to_epub_$uid.epub');
      await CuesToEpub.convert(
        title: title,
        cues: cues,
        outputPath: epubPath,
        author: author,
      );
      report(0.5, StandaloneSubtitleBookStep.importingEpub);
      bookKey = await EpubImporter.importFromPath(
        db: db,
        filePath: epubPath,
        fileName: '${title.replaceAll(RegExp(r'[^\w\s\-]'), '')}.epub',
        policy: policy,
      );
      fushiDebugPrint(
        '[fushi-import] subtitleBook: EPUB import done, key=$bookKey',
      );
    } on DuplicateImportCancelledException {
      // 取消/跳过必须冒泡到顶层中止整次导入，不能被吞成 bookKey='' 继续。
      rethrow;
    } catch (e, stack) {
      // BUG-439：坏 EPUB（FormatException 等）以前在这里被吞掉、bookKey 留空串，
      // 下面仍无条件 save 出一条没有 EpubBooks 行的孤儿 SrtBook 壳行——书架有卡
      // 却打不开（reader 定位磁盘返回 exists:false → book_file_not_found）。
      // EPUB 是字幕书的正文载体，载体生成/导入失败这本书就不可读，必须让整次
      // 导入失败而不是落孤儿壳行。与上面的取消同理冒泡到顶层报错。
      engineLog.log('importStandaloneSubtitleBook.epubImport', e, stack);
      rethrow;
    }
  }

  // 正文 EPUB 此时已经落库。之后任何一步（持久化字幕 / 音频、封面、落 SrtBook 与
  // cue）失败都要撤掉已落的东西再抛：否则库里留一条没有 SrtBook 的正文孤儿行，
  // 持久目录里留着已复制 / 已接管的文件，用户却只看到「导入失败」。
  Directory? persistDir;
  bool savedBook = false;
  try {
    report(0.7, StandaloneSubtitleBookStep.persisting);
    persistDir = await AudiobookStorage.ensurePersistDir(uid);
    final String persistedSrt = subtitlePath == null
        ? ''
        : adoptSubtitleFile
        ? await AudiobookStorage.adoptFile(File(subtitlePath), persistDir)
        : await AudiobookStorage.persistFileWithProgress(
            File(subtitlePath),
            persistDir,
            onProgress: (int copied, int total) => report(
              0.7,
              StandaloneSubtitleBookStep.copyingFile,
              p.basename(subtitlePath),
            ),
          );

    // 持久目录音频的唯一写入原语（同步成恰好这一组，幂等、不会先删掉自己的源）。
    final List<String> persistedAudioPaths =
        await AudiobookStorage.syncAudioFiles(
          persistDir,
          audioPaths,
          copy: copyAudio,
          onFile: (String name) =>
              report(0.8, StandaloneSubtitleBookStep.copyingFile, name),
        );

    report(0.9, StandaloneSubtitleBookStep.saving);
    final SrtBook book = SrtBook()
      ..uid = uid
      ..title = title
      ..srtPath = persistedSrt
      ..importedAt = DateTime.now().millisecondsSinceEpoch
      ..bookKey = bookKey;
    if (persistedAudioPaths.isNotEmpty) {
      book.audioPaths = persistedAudioPaths;
    }
    if (author != null) {
      book.author = author;
    }
    final String? coverPath = await persistCover?.call(persistDir);
    if (coverPath != null) {
      book.coverPath = coverPath;
    }

    fushiDebugPrint(
      '[fushi-import] SrtBook save: uid=$uid title="$title" '
      'bookKey=$bookKey cues=${cues.length}',
    );

    await repo.save(book);
    savedBook = true;
    await repo.saveCues(uid: uid, cues: cues);
    report(1, StandaloneSubtitleBookStep.done);
    return book;
  } catch (e, stack) {
    engineLog.log('importStandaloneSubtitleBook.persist', e, stack);
    await rollbackStandaloneSubtitleBook(
      db: db,
      repo: repo,
      uid: uid,
      bookKey: bookKey,
      savedBook: savedBook,
      persistDir: persistDir,
    );
    rethrow;
  }
}

/// [importStandaloneSubtitleBook] 正文落库之后失败时的回滚：删已落的 `SrtBook`
/// （[savedBook]，连带它的持久目录）、正文 EPUB 行与解包目录、这本书的持久目录
/// [persistDir]。每步各自记日志、不打断后续步骤，原始错误由调用方照常抛出（回滚
/// 失败不能盖掉导入失败的真实原因）。建书成功后外层再失败（如远端绑定写不进去）
/// 也走这里，保证同一种回滚只有一份实现。
Future<void> rollbackStandaloneSubtitleBook({
  required FushiDatabase db,
  required SrtBookRepository repo,
  required String uid,
  required String bookKey,
  required bool savedBook,
  required Directory? persistDir,
}) async {
  if (savedBook) {
    try {
      await repo.delete(uid);
    } catch (e, stack) {
      engineLog.log('importStandaloneSubtitleBook.rollbackSrtBook', e, stack);
    }
  }
  if (bookKey.isNotEmpty) {
    try {
      final EpubBookRow? row = await db.getEpubBook(bookKey);
      await db.deleteEpubBook(bookKey);
      if (row != null && row.extractDir.isNotEmpty) {
        final Directory dir = Directory(row.extractDir);
        if (dir.existsSync()) await dir.delete(recursive: true);
      }
    } catch (e, stack) {
      engineLog.log('importStandaloneSubtitleBook.rollbackEpub', e, stack);
    }
  }
  if (persistDir != null) {
    try {
      if (persistDir.existsSync()) await persistDir.delete(recursive: true);
    } catch (e, stack) {
      engineLog.log(
        'importStandaloneSubtitleBook.rollbackPersistDir',
        e,
        stack,
      );
    }
  }
}
