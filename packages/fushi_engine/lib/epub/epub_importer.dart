import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/book_title_conflict.dart';
import 'package:fushi_engine/epub/epub_book.dart';
import 'package:fushi_engine/sync/ttu_filename.dart';
import 'package:fushi_engine/utils/misc/fushi_time_format.dart';
import 'package:fushi_engine/epub/epub_parser.dart';
import 'package:fushi_engine/epub/epub_series.dart';
import 'package:fushi_engine/epub/epub_storage.dart';
import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:meta/meta.dart';

class EpubImporter {
  EpubImporter._();

  /// 解包临时目录名（BUG-3337）。只用毫秒戳时，同一毫秒起跑的两次导入（同时
  /// 下载多本对端书、几本几乎同时落地）会解进**同一个** `.tmp-<ms>`，互相覆盖
  /// 解包内容再各自搬走。进程内单调序号保证并发导入各占一个目录。实现在
  /// [EpubStorage.nextStagingDirName]（漫画导入共用同一个序号）。
  @visibleForTesting
  static String nextTempDirName() => EpubStorage.nextStagingDirName();

  /// 建本次导入独占的暂存目录（书库根下的 `.tmp-*`）。先等「上个进程的导入残留」
  /// 清扫跑完（每进程一次，BUG-4841）再建。
  ///
  /// 公开给漫画导入（`MangaImporter` / `MangaArchiveImporter`）共用：所有「往书库根
  /// 落一本书」的入口走同一种暂存 + 同一把落位锁。
  static Future<String> createStagingDir(FushiDatabase db) async {
    await ensureImportResidueSwept(db);
    return EpubStorage.createStagingDirectory();
  }

  /// 本进程（本书库根）的导入残留清扫，活行取自 [db] 的全部 `extract_dir`。每进程
  /// 只真跑一次，之后立即返回；失败只记日志。app 启动开库后调一次（BUG-4841 的启动
  /// 挂点，#3722 c07 遗留），导入入口建暂存目录前也经这里等它跑完。
  static Future<void> ensureImportResidueSwept(FushiDatabase db) =>
      EpubStorage.ensureImportResidueSwept(
        () async => <String>[
          for (final EpubBookMeta b in await db.getEpubBookMetas())
            b.extractDir,
        ],
      );

  /// Import an EPUB file into the database.
  ///
  /// Extracts the EPUB to disk, parses metadata, and inserts into EpubBooks.
  /// Returns the bookKey (the primary key = sanitized title) on success, or
  /// throws on failure (with cleanup).
  static Future<String> import({
    required FushiDatabase db,
    required Uint8List bytes,
    required String fileName,
    DuplicatePolicy policy = const DuplicatePolicy.suffix(),
  }) async {
    final String tempDir = await createStagingDir(db);

    // 解析失败（坏包、OPF 解析不出、字数统计抛出）时 [_persistParsed] 根本没被调到，
    // 它的清理也就轮不到：暂存目录必须在这里自己收（BUG-4841）。
    final _ParseResult result;
    try {
      result = await Isolate.run(
        () => _parseInIsolate(_ParseArgs(bytes: bytes, extractDir: tempDir)),
      );
    } catch (_) {
      _tryDeleteDir(tempDir);
      rethrow;
    }
    return _persistParsed(
      db: db,
      result: result,
      fileName: fileName,
      tempDir: tempDir,
      policy: policy,
    );
  }

  /// Import from a file path on disk.
  ///
  /// Preferred over [import] — the file is read inside the isolate,
  /// avoiding a large byte-array copy across the isolate boundary.
  static Future<String> importFromFile({
    required FushiDatabase db,
    required String filePath,
    DuplicatePolicy policy = const DuplicatePolicy.suffix(),
  }) async {
    return importFromPath(
      db: db,
      filePath: filePath,
      fileName: p.basename(filePath),
      policy: policy,
    );
  }

  /// Import an EPUB by file path — reads inside the isolate to reduce
  /// peak memory on the main isolate.
  static Future<String> importFromPath({
    required FushiDatabase db,
    required String filePath,
    required String fileName,
    DuplicatePolicy policy = const DuplicatePolicy.suffix(),
    int? sourceId,
  }) async {
    final String tempDir = await createStagingDir(db);

    // 同 [import]：解析失败时暂存目录在这里收（BUG-4841）。
    final _ParseResult result;
    try {
      result = await Isolate.run(
        () => _parseFromPathInIsolate(
          _ParseArgsFromPath(filePath: filePath, extractDir: tempDir),
        ),
      );
    } catch (_) {
      _tryDeleteDir(tempDir);
      rethrow;
    }
    return _persistParsed(
      db: db,
      result: result,
      fileName: fileName,
      tempDir: tempDir,
      policy: policy,
      sourceId: sourceId,
    );
  }

  /// Shared post-parse persistence: resolve the title conflict, derive the
  /// bookKey (= sanitized stored title), move the freshly-extracted [tempDir]
  /// to the key-named directory, and insert the EpubBooks row. Returns the
  /// bookKey. On any failure cleans up the row + extracted directories.
  ///
  /// The temp directory is extracted under a `.tmp-<ts>` name BEFORE the title
  /// is known (parsing needs the on-disk extraction); once the unique stored
  /// title is resolved we move it to `bookDirectory(bookKey)` so the on-disk
  /// folder name matches the primary key for freshly-imported books.
  static Future<String> _persistParsed({
    required FushiDatabase db,
    required _ParseResult result,
    required String fileName,
    required String tempDir,
    DuplicatePolicy policy = const DuplicatePolicy.suffix(),
    int? sourceId,
  }) async {
    String? insertedKey;
    String extractDir = tempDir;
    try {
      final EpubBook book = result.book;
      final List<int> characterCounts = result.characterCounts;

      final String resolvedTitle =
          book.title == p.basenameWithoutExtension(tempDir)
          ? p.basenameWithoutExtension(fileName)
          : book.title;

      // 书名定夺 + 落位 + 插行走 [placeUnderResolvedTitle]：同名询问在锁外，
      // 「重取快照 → 挪目录 → 插行」在落位锁内一次做完（BUG-4837）。
      final ({String storedTitle, String bookKey, int importedAtMs})
      placed = await placeUnderResolvedTitle(
        db: db,
        proposedTitle: resolvedTitle,
        policy: policy,
        place:
            (
              String storedTitle,
              String bookKey,
              List<EpubBookMeta> liveBooks,
            ) async {
              // Move the freshly-extracted temp dir to the key-named
              // directory.
              //
              // BUG-564: the target dir may already exist on disk even
              // though no live row owns the key: a crashed import or a
              // failed post-delete disk cleanup leaves an orphan dir, and
              // Linux rename(2) onto a non-empty target throws ENOTEMPTY
              // (errno 39) -- e.g. re-downloading a remote book whose
              // previous copy left a stale folder. Resolved by
              // [EpubStorage.moveDirIntoPlace] (atomic replace with .bak
              // rollback; directories owned by a live row are never
              // touched).
              final String realDir = await EpubStorage.bookPath(bookKey);
              final Directory srcDir = Directory(tempDir);
              if (realDir == tempDir) {
                // Already in place (the key equals the staging name).
              } else if (srcDir.existsSync()) {
                try {
                  extractDir = EpubStorage.moveDirIntoPlace(
                    srcDir: srcDir,
                    targetDir: realDir,
                    liveExtractDirs: liveBooks.map(
                      (EpubBookMeta b) => b.extractDir,
                    ),
                  );
                } catch (e) {
                  engineLog.log('EpubImporter.rename', e, StackTrace.current);
                  rethrow;
                }
              } else {
                extractDir = realDir;
              }

              final int importedAtMs = DateTime.now().millisecondsSinceEpoch;
              insertedKey = await db.insertEpubBook(
                bookRowFor(
                  book: book,
                  characterCounts: characterCounts,
                  bookKey: bookKey,
                  title: storedTitle,
                  epubPath: fileName,
                  extractDir: extractDir,
                  importedAt: importedAtMs,
                  sourceId: sourceId,
                ),
              );
              return (
                storedTitle: storedTitle,
                bookKey: bookKey,
                importedAtMs: importedAtMs,
              );
            },
      );
      final String storedTitle = placed.storedTitle;
      final String bookKey = placed.bookKey;
      final int importedAtMs = placed.importedAtMs;

      // v49：导入一本书写一条「added」活动事件，喂首页 Activity 时间轴。放用户导入
      // 管线（本方法），云同步/备份 MERGE 直接插行不经此路 → 不刷屏。best-effort，
      // 记账失败不影响书已导入。
      try {
        await db.addActivityEvent(
          eventType: kActivityAdded,
          mediaType: kActivityMediaBook,
          title: storedTitle,
          mediaKey: bookKey,
          dateKey: FushiTimeFormat.dayKey(
            DateTime.fromMillisecondsSinceEpoch(importedAtMs),
          ),
          timestampMs: importedAtMs,
        );
      } catch (e) {
        engineLog.log('EpubImporter.addActivityEvent', e, StackTrace.current);
      }

      return bookKey;
    } catch (e) {
      final String? inserted = insertedKey;
      if (inserted != null) {
        try {
          await db.deleteEpubBook(inserted);
        } catch (e, stack) {
          engineLog.log('EpubImporter.rollbackDelete', e, stack);
        }
      }
      _tryDeleteDir(extractDir);
      _tryDeleteDir(tempDir);
      rethrow;
    }
  }

  /// 「定书名 → 落位 → 插行」的**唯一**编排，EPUB 与漫画导入共用（BUG-4837 /
  /// BUG-4840）。
  ///
  /// 1. 锁外：取书库快照，按 [policy] 解决同名（[DuplicatePolicy.ask] 会停在用户
  ///    对话框上，所以这一步绝不能持锁）；随后跑一次 [stage]（调用方把内容备进自己
  ///    的暂存目录，要求幂等——极少数情况下会被再调一次）。
  /// 2. 持 [EpubStorage.withBookPlacementLock]：**重取**快照；定下的书名键若在这
  ///    期间被别的导入占了，放锁回到第 1 步按同一 [policy] 重新定夺（跳过 / 再问 /
  ///    再加后缀）；没被占就调 [place]，由它「挪目录 → 插行」。[place] 拿到的
  ///    `liveBooks` 是锁内的新快照，目录归属只能按它判。
  ///
  /// 判「被占」与 [resolveDuplicateTitle] 用同一口径（净化后的标题），所以回到第 1 步
  /// 必然得到一个不同的结论，不会原地打转。
  static Future<T> placeUnderResolvedTitle<T>({
    required FushiDatabase db,
    required String proposedTitle,
    required DuplicatePolicy policy,
    required Future<T> Function(
      String storedTitle,
      String bookKey,
      List<EpubBookMeta> liveBooks,
    )
    place,
    Future<void> Function()? stage,
  }) async {
    while (true) {
      // 瘦投影：重复检查只要 title（+ 落位时的 extractDir），不拉整库章节 JSON。
      final List<EpubBookMeta> existingBooks = await db.getEpubBookMetas();
      final String storedTitle = await resolveDuplicateTitle(
        existingTitles: existingBooks.map((EpubBookMeta b) => b.title).toList(),
        proposedTitle: proposedTitle,
        policy: policy,
      );
      // bookKey is the EpubBooks primary key (= sanitized stored title). It is
      // unique by construction (resolveDuplicateTitle guarantees no two local
      // books share a sanitized key).
      final String bookKey = sanitizeTtuFilename(storedTitle);
      await stage?.call();
      final ({T value})? placed = await EpubStorage.withBookPlacementLock(
        () async {
          final List<EpubBookMeta> liveBooks = await db.getEpubBookMetas();
          final bool taken = liveBooks.any(
            (EpubBookMeta b) => sanitizeTtuFilename(b.title) == bookKey,
          );
          if (taken) return null;
          return (value: await place(storedTitle, bookKey, liveBooks));
        },
      );
      if (placed != null) return placed.value;
    }
  }

  /// 已解析的 [book] → `EpubBooks` 行：用户导入（[_persistParsed]）与「孤儿书目录
  /// 重新登记」（[registerExtractedBook]，BUG-4701）共用的**唯一**行构造口径，
  /// 两条路径落下的列逐字段同构。
  static EpubBooksCompanion bookRowFor({
    required EpubBook book,
    required List<int> characterCounts,
    required String bookKey,
    required String title,
    required String epubPath,
    required String extractDir,
    required int importedAt,
    int? sourceId,
  }) {
    return EpubBooksCompanion.insert(
      bookKey: bookKey,
      title: title,
      author: book.author != null ? Value(book.author) : const Value.absent(),
      coverPath: book.coverHref != null
          ? Value(book.coverHref)
          : const Value.absent(),
      epubPath: epubPath,
      extractDir: extractDir,
      chapterCount: book.chapters.length,
      chaptersJson: buildChaptersJson(book, characterCounts),
      tocJson: book.toc.isNotEmpty
          ? Value(
              jsonEncode(
                book.toc
                    .map(
                      (e) => <String, Object?>{
                        'title': e.label,
                        'href': e.href,
                      },
                    )
                    .toList(),
              ),
            )
          : const Value.absent(),
      importedAt: importedAt,
      // TODO-817 M1b：扫描器入库时回填来源库 id；手动导入 sourceId==null
      // → Value.absent() 落 NULL（向后兼容）。
      sourceId: sourceId != null ? Value(sourceId) : const Value.absent(),
      // v87：OPF 的 dc:language 回填。`EpubParser` 一直解析着这个字段，但在此
      // 之前全仓没有任何消费方——正文字体因此只能落到 CSS 的裸 `serif`，在
      // Windows 上就是宋体（中文字形），日文书也一样。落库后由
      // `content_font_chain` 选链。包没声明 → NULL → 不猜，保持浏览器默认，
      // 用户可在书籍设置里手动指定。
      language: book.language != null && book.language!.trim().isNotEmpty
          ? Value(book.language!.trim())
          : const Value.absent(),
      // v115：OPF dc:identifier 里校验通过的 ISBN（已规范成 ISBN-13），排行榜
      // 作品匹配的强 ID。没有合法 ISBN → NULL。
      isbn: book.isbn != null ? Value(book.isbn) : const Value.absent(),
      // n4KC1azJvw：OPF 声明的系列（没有也写类型标记，存量回填据此跳过）。
      // 书架系列归组优先认它，标题启发式只兜底。
      sourceMetadata: Value(encodeEpubSeriesMetadata(book.series)),
    );
  }

  /// 把盘上**已解压**、但没有书库行的 EPUB 目录 [extractDir] 重新登记成书
  /// （BUG-4701：覆盖导入换掉书库后，书文件成了孤儿目录）。
  ///
  /// [bookKey] 由调用方给定（= 目录名），**不**按标题重新派生、不做重名后缀——
  /// 卡片背面的来源链接按 uid → bookKey 回退找书，键不变才能重新连上。解析与字数
  /// 统计复用导入的 isolate 内核，不另写一套。不写「added」活动事件（不是新导入）。
  /// 返回插入的 bookKey；同键已有行时由 `insertEpubBook` 的主键约束失败抛出。
  static Future<String> registerExtractedBook({
    required FushiDatabase db,
    required String bookKey,
    required String title,
    required String extractDir,
  }) async {
    final _ParseResult result = await _reparseExtracted(extractDir);
    // 插行持落位锁：导入在锁内按快照判「这个目录有没有活行」，登记若在它的快照与
    // 挪目录之间插进来，导入会把刚登记的书目录当无主的换掉（BUG-4837）。
    return EpubStorage.withBookPlacementLock(
      () => db.insertEpubBook(
        bookRowFor(
          book: result.book,
          characterCounts: result.characterCounts,
          bookKey: bookKey,
          title: title,
          // 原导入文件名已不可知；这一列对 EPUB 只作展示 / 导出文件名用。
          epubPath: '${p.basename(extractDir)}.epub',
          extractDir: extractDir,
          importedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      ),
    );
  }

  /// 在 isolate 里重新解析已解压的书目录。单独成一个只收 [extractDir] 的函数，是
  /// 为了让送进 isolate 的闭包只捕获这一个字符串：调用方函数里只要还有别的闭包捕获
  /// 了库句柄（[registerExtractedBook] 持锁插行的那个），同一函数里的 `Isolate.run`
  /// 闭包就会连带把它带进消息，直接报 unsendable。
  static Future<_ParseResult> _reparseExtracted(String extractDir) =>
      Isolate.run(() => _reparseExtractedInIsolate(extractDir));

  /// 只读解析已解压 EPUB 目录的标题（OPF `dc:title`），在 isolate 里跑。孤儿目录
  /// 扫描用它判断「纯数字 / `~n` 后缀」这类可疑目录名是不是真的 bookKey。
  static Future<String> readExtractedTitle(String extractDir) =>
      Isolate.run(() => EpubParser.parseFromExtracted(extractDir).title);

  /// `EpubBooks.chaptersJson` 的**唯一**序列化口径：每章 `id`/`href`/`mediaType`/
  /// `characters` + 计数口径版本 [kChapterCharCountCaliber]。
  ///
  /// 公开是给「漫画 → 书」转化用的（`book_format_rebuild.dart`）：转成漫画时这一列
  /// 被写成 `'[]'`，转回来只能由重新解析解压树重建。两处各写一份 JSON 结构，字段名
  /// 或 charCaliber 漂一个字，书架字数与 TODO-1192 的口径重算就同时坏掉。
  static String buildChaptersJson(EpubBook book, List<int> characterCounts) {
    return jsonEncode(
      book.chapters
          .asMap()
          .entries
          .map(
            (entry) => <String, Object>{
              'id': entry.value.id,
              'href': entry.value.href,
              'mediaType': entry.value.mediaType,
              'characters': characterCounts[entry.key],
              // TODO-1192: 标记该 characters 计数的口径版本，供开书判定是否需
              // 要按新口径（`countStudyChars`）后台重算并回写（见
              // [kChapterCharCountCaliber] / charCountsFromChaptersJson）。
              'charCaliber': kChapterCharCountCaliber,
            },
          )
          .toList(),
    );
  }

  /// 用 [epubFilePath] 这份新生成的 EPUB **就地重建**一本已入库书的解压树，返回
  /// `(chapterCount, chaptersJson, coverPath)` 三件套供调用方回写 EpubBooks 行。
  ///
  /// 与 [importFromPath] 的区别：不插新行、不派生新 bookKey、不动 `extract_dir`
  /// 列——书的身份（bookKey / extractDir / 合集 / 标签 / 进度）完整保留，只有正文
  /// 内容被换掉。字幕书换字幕（[SrtBooks.srtPath] 换文件 → cue 全变 → 由 cue 生成
  /// 的正文必须跟着重建）是唯一调用方：正文与 cue 靠**文本相等**配对
  /// （`_findCueForSentence`），只换 cue 不换正文会让整本书的高亮同步全断。
  ///
  /// 写盘用与导入同一套原子替换（[moveExtractedDirIntoPlace]）：新树先解到临时
  /// 目录，成功后旧树改名成 `.bak-<ts>` 让位、新树就位、再删 bak；中途失败把 bak
  /// 改回来。绝不先删后建——中间崩一次两份都没了。
  static Future<({int chapterCount, String chaptersJson, String? coverPath})>
  rebuildExtractedInPlace({
    required String epubFilePath,
    required String extractDir,
  }) async {
    // 这里没有库句柄，不触发残留清扫；本进程建的暂存目录清扫认得出、不会碰。
    final String tempDir = await EpubStorage.createStagingDirectory();
    try {
      final _ParseResult result = await Isolate.run(
        () => _parseFromPathInIsolate(
          _ParseArgsFromPath(filePath: epubFilePath, extractDir: tempDir),
        ),
      );
      // chaptersJson / coverHref 都是**相对**解压根的路径，先算再搬位置等价。
      final String chaptersJson = buildChaptersJson(
        result.book,
        result.characterCounts,
      );
      // liveExtractDirs 传空 = 允许覆盖目标目录：这里的目标正是本书自己的解压树，
      // 覆盖它就是本方法的全部意图（导入路径传 live 列表是为了不撞**别的**书）。
      // 持落位锁：与并发导入的「判归属 → 挪目录」串行。
      await EpubStorage.withBookPlacementLock(() async {
        EpubStorage.moveDirIntoPlace(
          srcDir: Directory(tempDir),
          targetDir: extractDir,
          liveExtractDirs: const <String>[],
        );
      });
      return (
        chapterCount: result.book.chapters.length,
        chaptersJson: chaptersJson,
        coverPath: result.book.coverHref,
      );
    } catch (e, stack) {
      engineLog.log('EpubImporter.rebuildInPlace', e, stack);
      _tryDeleteDir(tempDir);
      rethrow;
    }
  }

  /// 重新解析**已解压**的书目录 [extractDir]，返回 `(chapterCount, chaptersJson,
  /// coverPath)` 三件套。
  ///
  /// 用于「漫画 → 书」转回：本仓的 EPUB 在盘上只有解压树、没有独立 `.epub`
  /// （BUG-088），所以「撤销」不存在——只能拿解压树重新算一遍。DOM 解析与字数统计
  /// 放 isolate（与导入同款 [compute]），不卡 UI。
  static Future<({int chapterCount, String chaptersJson, String? coverPath})>
  reparseExtractedBook(String extractDir) async {
    final _ParseResult result = await _reparseExtracted(extractDir);
    return (
      chapterCount: result.book.chapters.length,
      chaptersJson: buildChaptersJson(result.book, result.characterCounts),
      coverPath: result.book.coverHref,
    );
  }

  /// 书目录落位。实现已提到 [EpubStorage.moveDirIntoPlace]（漫画导入共用同一个
  /// 落位原语，BUG-4840），语义见那里；这里保留原名给既有调用方与测试。
  @visibleForTesting
  static String moveExtractedDirIntoPlace({
    required Directory srcDir,
    required String targetDir,
    required Iterable<String> liveExtractDirs,
    bool forceCopyFallback = false,
  }) => EpubStorage.moveDirIntoPlace(
    srcDir: srcDir,
    targetDir: targetDir,
    liveExtractDirs: liveExtractDirs,
    forceCopyFallback: forceCopyFallback,
  );

  static void _tryDeleteDir(String path) {
    final Directory dir = Directory(path);
    if (dir.existsSync()) {
      try {
        dir.deleteSync(recursive: true);
      } catch (e, stack) {
        engineLog.log('EpubImporter.cleanupDir', e, stack);
      }
    }
  }
}

class _ParseArgs {
  const _ParseArgs({required this.bytes, required this.extractDir});
  final Uint8List bytes;
  final String extractDir;
}

class _ParseArgsFromPath {
  const _ParseArgsFromPath({required this.filePath, required this.extractDir});
  final String filePath;
  final String extractDir;
}

/// HBK-AUDIT-035: result carried back from the parse isolate — the parsed
/// [book] plus per-chapter plain-text character counts computed in-isolate.
class _ParseResult {
  const _ParseResult({required this.book, required this.characterCounts});
  final EpubBook book;
  final List<int> characterCounts;
}

/// Compute the per-chapter character counts inside the isolate so the
/// expensive html_parser DOM build never runs on the main/UI isolate.
///
/// TODO-1192: 口径改为 [EpubBook.chapterCharacterCount]（只数假名/汉字/字母数字，
/// 剔标点/括号/空白），与 hoshi 对齐；落库时同时打 [kChapterCharCountCaliber]。
List<int> _computeCharacterCounts(EpubBook book) {
  return List<int>.generate(
    book.chapters.length,
    (int index) => book.chapterCharacterCount(index),
    growable: false,
  );
}

/// 解析一个**已经解压好**的书目录（不解压、不写盘），供「漫画 → 书」转回重算
/// 章节与字数。
_ParseResult _reparseExtractedInIsolate(String extractDir) {
  final EpubBook book = EpubParser.parseFromExtracted(extractDir);
  return _ParseResult(
    book: book,
    characterCounts: _computeCharacterCounts(book),
  );
}

_ParseResult _parseInIsolate(_ParseArgs args) {
  final EpubBook book = EpubParser.parseSync(args.bytes, args.extractDir);
  return _ParseResult(
    book: book,
    characterCounts: _computeCharacterCounts(book),
  );
}

_ParseResult _parseFromPathInIsolate(_ParseArgsFromPath args) {
  final EpubBook book = EpubParser.parseSyncFromPath(
    args.filePath,
    args.extractDir,
  );
  return _ParseResult(
    book: book,
    characterCounts: _computeCharacterCounts(book),
  );
}
