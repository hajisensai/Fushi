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
///
/// 字幕解析出 0 条 cue 时与对话框历史行为一致：不生成正文，仍落一条只有字幕
/// 与音频的书（`bookKey` 为空串）。需要「0 条即失败」语义的调用方（转录产物）
/// 自己在调用前判。
Future<SrtBook> importStandaloneSubtitleBook({
  required FushiDatabase db,
  required SrtBookRepository repo,
  required String title,
  String? author,
  required String subtitlePath,
  List<String> audioPaths = const <String>[],
  bool copyAudio = true,
  required DuplicatePolicy policy,
  Directory? tempDir,
  Future<String?> Function(Directory persistDir)? persistCover,
  StandaloneSubtitleBookProgress? onProgress,
}) async {
  void report(double f, StandaloneSubtitleBookStep step, [String? name]) =>
      onProgress?.call(f, step, name);

  final String uid = 'srtbook_${DateTime.now().millisecondsSinceEpoch}';
  report(0.1, StandaloneSubtitleBookStep.parsing);

  final List<AudioCue> cues = await parseCuesForFormat(
    File(subtitlePath),
    uid,
    0,
  );
  fushiDebugPrint('[fushi-import] subtitleBook: parsed ${cues.length} cues');

  String bookKey = '';
  if (cues.isNotEmpty) {
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

  report(0.7, StandaloneSubtitleBookStep.persisting);
  final Directory persistDir = await AudiobookStorage.ensurePersistDir(uid);
  final String persistedSrt = await AudiobookStorage.persistFileWithProgress(
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
  await repo.saveCues(uid: uid, cues: cues);
  report(1, StandaloneSubtitleBookStep.done);
  return book;
}
