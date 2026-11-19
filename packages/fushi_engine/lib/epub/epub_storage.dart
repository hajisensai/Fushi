import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:fushi_engine/epub/epub_image_index_cache.dart';
import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/foundation/engine_paths.dart';
import 'package:meta/meta.dart';

/// Manages on-disk storage of extracted EPUB content.
///
/// Layout: `<appDocDir>/fushi_books/<bookKey>/`
///   - `META-INF/`, OPF, chapter HTML, images, CSS, fonts (extracted from ZIP)
///   - `original.epub` (optional — kept for re-export)
///
/// NOTE: pre-v16 books were stored under `<appDocDir>/fushi_books/<int id>/`.
/// Those directories are NOT renamed on migration — the truth is the
/// `epub_books.extract_dir` column. Use [bookDirectory]/[bookPath] only when
/// importing a NEW book; to locate an EXISTING book read its `extractDir`
/// column and operate on that absolute path (e.g. [deleteBookDir]).
class EpubStorage {
  static String? _cachedBaseDir;

  /// Test-only override for the base directory, used by suites that exercise
  /// the real [EpubImporter] without a Flutter binding / path_provider plugin
  /// (e.g. the interconnect orchestrator tests that download over a real HTTP
  /// server, where installing `TestWidgetsFlutterBinding` would break the
  /// socket). Production never sets this — it stays null and resolution falls
  /// through to [AppPaths.documentsRootDirectory].
  @visibleForTesting
  static set debugBaseDirectoryOverride(String? path) {
    _cachedBaseDir = path == null ? null : p.join(path, 'fushi_books');
  }

  static int _stagingSeq = 0;

  /// 导入暂存目录名的前缀。暂存目录的完整名字见 [_stagingDirName]。
  static const String kStagingDirPrefix = '.tmp-';

  /// [nextStagingDirName] 写出的名字：`.tmp-<毫秒戳>-<序号>`（BUG-3337 之前没有序号
  /// 段）。清扫只认这个形状——书名净化不处理前导点，一本叫 `.tmp-notes` 的书的目录
  /// 同样以 [kStagingDirPrefix] 开头，按前缀认会把它当暂存删掉。
  static final RegExp _stagingDirName = RegExp(r'^\.tmp-\d+(-\d+)?$');

  /// [moveDirIntoPlace] 替换无主目录时旧树让位用的名字：`<目标>.bak-<13 位毫秒戳>`。
  /// 位数钉死在实际写出的形状上，书名恰好以 `.bak-2` 结尾的孤儿目录不会被当成 bak。
  static final RegExp _bakDirName = RegExp(r'^(.+)\.bak-(\d{13})$');

  /// [moveDirIntoPlace] 走「拷贝 + 删源」回退时，目标目录在拷完之前带着的标记文件。
  /// rename 落位是原子的，用不着标记；拷贝不是——进程死在拷贝中途，目标目录看起来
  /// 「已经在了」但只有半本，清扫只有靠这个标记才分得清，不会把旁边那份完整的
  /// `.bak-*` 当成多余的删掉。
  static const String kIncompleteMarkerFileName = '.fushi-incomplete';

  /// 暂存目录名（BUG-3337）。只用毫秒戳时，同一毫秒起跑的两次导入会解进**同一个**
  /// `.tmp-<ms>`，互相覆盖再各自搬走。进程内单调序号保证并发导入各占一个目录。
  static String nextStagingDirName() =>
      '$kStagingDirPrefix${DateTime.now().millisecondsSinceEpoch}-${_stagingSeq++}';

  /// 在书库根下建一个本次导入独占的暂存目录并返回其路径。
  ///
  /// 暂存放书库根而不是系统临时目录，是为了落位（[moveDirIntoPlace]）时与目标同卷：
  /// 一次 rename，不占第二份空间；也让崩溃残留落在 [ensureImportResidueSwept] 管得到
  /// 的地方（桌面端系统临时目录里的残留，app 内既看不见也清不掉）。
  ///
  /// [parentDir] 给「就地改一本已在库的书」用（格式转换）：暂存建成那本书目录的兄弟，
  /// 生产上就是书库根；缺省即书库根。
  static Future<String> createStagingDirectory({String? parentDir}) async {
    final String name = nextStagingDirName();
    _ownStagingNames.add(name);
    final String dir = p.join(parentDir ?? await baseDirectory(), name);
    Directory(dir).createSync(recursive: true);
    return dir;
  }

  /// 本进程经 [createStagingDirectory] 建过的暂存目录名。清扫靠它认出「不是上个
  /// 进程留下的」：不是每个建暂存的入口都先等过清扫（就地重建没有库句柄可查活行），
  /// 清扫又是首次导入时才跑、删除还是异步的，两者可能同时在场。名字先登记再建目录
  /// （中间没有 await），带进程内单调序号，不会复用。
  static final Set<String> _ownStagingNames = <String>{};

  static final _SerialSection _placementSection = _SerialSection();

  /// 进程内的「书目录落位」互斥：`重取书库快照 → 判书名键 / 目录归属 → 挪目录 →
  /// 插行` 必须作为一个整体串行跑（BUG-4837 / BUG-4840）。
  ///
  /// 判重与目录归属都建在 `getEpubBookMetas()` 的快照上；两次导入各拿一份、互相看不见
  /// 对方，就会都认定同一个目标目录「无主」，后到的把先到的目录换掉、插行撞主键、
  /// 回滚时再把目录删掉——先到的那一行从此指向一个不存在的目录。
  ///
  /// **不要把会等用户的东西放进 [body]**（`DuplicatePolicy.ask` 的同名弹窗）：锁要是
  /// 跨过一个没人点的对话框，后台扫描和同步下载就全卡在它后面。进程内静态锁就够——
  /// app 与 `fushi_server` 是两个进程、各自一个库与数据根。
  static Future<T> withBookPlacementLock<T>(Future<T> Function() body) =>
      _placementSection.run(body);

  /// 正在跑的首次清扫（按书库根）。跑完就挪进 [_sweptRoots]、不再留着 Future：
  /// 已完成的 Future 的回调派发在**创建它的 zone** 里，那个 zone 之后不再跑微任务时
  /// （测试里上一条用例的 fake-async zone）再 await 它就永远等不到。
  static final Map<String, Future<void>> _residueSweeps =
      <String, Future<void>>{};
  static final Set<String> _sweptRoots = <String>{};

  /// 每个进程（每个书库根）只跑一次的导入残留清扫（BUG-4841）。导入入口在建自己的
  /// 暂存目录之前 await 它；并发的导入等的是同一个 Future。本进程自己建的暂存目录
  /// 清扫认得出、不碰（见 [sweepImportResidue]）。
  ///
  /// [liveExtractDirs] 取当前书库所有行的 `extract_dir`（只在真的要扫时才调）。
  /// 清扫是整理，不是导入的前置条件：失败只记日志，不让导入跟着失败。
  static Future<void> ensureImportResidueSwept(
    Future<Iterable<String>> Function() liveExtractDirs,
  ) async {
    final String base = await baseDirectory();
    if (_sweptRoots.contains(base)) return;
    await (_residueSweeps[base] ??= _sweepLogged(base, liveExtractDirs));
  }

  static Future<void> _sweepLogged(
    String base,
    Future<Iterable<String>> Function() liveExtractDirs,
  ) async {
    try {
      await sweepImportResidue(
        booksRoot: base,
        liveExtractDirs: await liveExtractDirs(),
      );
    } catch (e, stack) {
      engineLog.log('EpubStorage.sweepImportResidue', e, stack);
    } finally {
      _sweptRoots.add(base);
      _residueSweeps.remove(base);
    }
  }

  static final _SerialSection _sweepSection = _SerialSection();

  /// 清掉书库根 [booksRoot] 下崩溃 / 被杀的导入留下的东西，返回处置清单（测试与
  /// 排查用）。只看根下的直接子目录：
  ///
  /// - 暂存目录（[_stagingDirName]）：没落位的半成品，直接删——本进程经
  ///   [createStagingDirectory] 建的除外（那是正在进行的导入）。
  /// - `<目标>.bak-<ts>`（[_bakDirName]）：[moveDirIntoPlace] 替换时让位的旧树。
  ///   **不能盲删**——进程若死在「旧树改名 bak」与「新树就位」之间，bak 是那本书
  ///   唯一的副本：
  ///   - 目标不在 → 把 bak 改回目标；
  ///   - 目标在但带着 [kIncompleteMarkerFileName]（拷贝回退拷到一半）→ 删掉半成品
  ///     目标，把 bak 改回去；半成品没删干净就不动 bak，留给下一次；
  ///   - 目标完整在场 → bak 才是多余的，删。
  ///
  ///   同一个目标有多份 bak 时从最新的看起（最新那份才是替换前的最后状态）。
  /// - 带 [kIncompleteMarkerFileName]、又没有 bak 可还原的无主目录：新书落位拷到
  ///   一半、行没插进去，删掉——不然孤儿扫描会把半本书列成「可找回」。
  ///
  /// [liveExtractDirs] 里的目录（某个活行的 `extract_dir`）一律不当暂存 / bak /
  /// 半成品处理，哪怕书名恰好长成 `.tmp-1-0` 或 `x.bak-1700000000000`；唯一例外是
  /// 「活行的目录带着未完成标记且旁边有 bak」——那是就地重建拷到一半，bak 才是这本书。
  ///
  /// 递归删除走异步 IO：残留可能是几百页漫画的整份暂存（几个 GB），同步删会把调用方
  /// 所在的 isolate（app 里是 UI）卡到删完。「判定 → 改名」每一步仍是同步的、紧跟在
  /// 现查的磁盘状态之后；[moveDirIntoPlace] 也是同步的，所以清扫看不到本进程「改名
  /// 到一半」的 bak，只可能看到它整步做完之前或之后的样子。同一进程里的多次清扫
  /// 排队跑，不会两趟同时删同一个目录。
  static Future<List<String>> sweepImportResidue({
    required String booksRoot,
    required Iterable<String> liveExtractDirs,
  }) {
    final Set<String> live = <String>{
      for (final String dir in liveExtractDirs)
        if (dir.isNotEmpty) p.canonicalize(dir),
    };
    return _sweepSection.run(() => _sweepImportResidue(booksRoot, live));
  }

  static Future<List<String>> _sweepImportResidue(
    String booksRoot,
    Set<String> live,
  ) async {
    final List<String> actions = <String>[];
    final Directory root = Directory(booksRoot);
    if (!root.existsSync()) return actions;
    bool isLive(String path) => live.contains(p.canonicalize(path));
    bool isIncomplete(String path) =>
        File(p.join(path, kIncompleteMarkerFileName)).existsSync();
    // [run] 的同步部分在 `act(...)` 调用当下就执行，之后才让出。
    Future<bool> act(
      String what,
      String path,
      FutureOr<void> Function() run,
    ) async {
      try {
        await run();
        actions.add('$what ${p.basename(path)}');
        return true;
      } catch (e, stack) {
        engineLog.log('EpubStorage.sweepImportResidue.$what', e, stack);
        return false;
      }
    }

    final List<Directory> staleStaging = <Directory>[];
    final List<({String path, String target, int stamp})> baks =
        <({String path, String target, int stamp})>[];
    for (final FileSystemEntity entity in root.listSync(followLinks: false)) {
      if (entity is! Directory) continue;
      if (isLive(entity.path)) continue;
      final String name = p.basename(entity.path);
      if (_stagingDirName.hasMatch(name)) {
        if (!_ownStagingNames.contains(name)) staleStaging.add(entity);
        continue;
      }
      final RegExpMatch? bak = _bakDirName.firstMatch(name);
      if (bak != null) {
        baks.add((
          path: entity.path,
          target: p.join(booksRoot, bak.group(1)!),
          stamp: int.parse(bak.group(2)!),
        ));
      }
    }

    // bak 先处置：还原唯一副本不该排在几个 GB 的暂存删除后面。
    baks.sort(
      (
        ({String path, String target, int stamp}) a,
        ({String path, String target, int stamp}) b,
      ) => b.stamp.compareTo(a.stamp),
    );
    for (final ({String path, String target, int stamp}) bak in baks) {
      final Directory target = Directory(bak.target);
      if (target.existsSync() && isIncomplete(bak.target)) {
        final bool cleared = await act(
          'deleteIncomplete',
          bak.target,
          () => _deleteIncompleteDir(target),
        );
        // 半成品还在场：bak 仍是这本书唯一完整的副本，不能往下走到「目标在场 →
        // 删 bak」。
        if (!cleared) continue;
      }
      // 从这里到改名 / 发起删除之间没有 await：判定用的是现查的磁盘状态。
      if (!Directory(bak.path).existsSync()) continue;
      if (target.existsSync()) {
        await act(
          'deleteBak',
          bak.path,
          () => Directory(bak.path).delete(recursive: true),
        );
      } else {
        await act('restoreBak', bak.path, () {
          Directory(bak.path).renameSync(bak.target);
        });
      }
    }

    for (final Directory staging in staleStaging) {
      await act(
        'deleteStaging',
        staging.path,
        () => staging.delete(recursive: true),
      );
    }

    for (final FileSystemEntity entity in root.listSync(followLinks: false)) {
      if (entity is! Directory) continue;
      if (isLive(entity.path) || !isIncomplete(entity.path)) continue;
      await act(
        'deleteIncomplete',
        entity.path,
        () => _deleteIncompleteDir(entity),
      );
    }
    return actions;
  }

  /// 删一个带 [kIncompleteMarkerFileName] 的半成品目录，**标记最后删**。递归删除的
  /// 顺序由平台定；标记要是先没了而删除半路失败（Windows 上文件被占用），剩下的
  /// 半本目录看起来就是「完整的」，下一次清扫会把旁边完整的 bak 当多余的删掉。
  static Future<void> _deleteIncompleteDir(Directory dir) async {
    await for (final FileSystemEntity entity in dir.list(followLinks: false)) {
      if (p.basename(entity.path) == kIncompleteMarkerFileName) continue;
      await entity.delete(recursive: true);
    }
    await dir.delete(recursive: true);
  }

  /// Move the freshly-staged [srcDir] to [targetDir]; returns the directory
  /// that finally holds the content (stored as `extract_dir`). The one
  /// placement primitive shared by every local-book importer (EPUB, manga).
  ///
  /// [targetDir] may already exist on disk (BUG-564). Semantics:
  /// - target missing -> move [srcDir] into place (the normal path);
  /// - target listed in [liveExtractDirs] (some live book's `extract_dir`
  ///   points at it -- the column, not the folder name, is the truth for
  ///   existing books) -> never touch it; the new book moves to a unique
  ///   sibling `<targetDir>~<n>` instead;
  /// - target exists but is unowned (leftover of a crashed import / a failed
  ///   post-delete disk cleanup) -> atomic replace: rename it aside to a
  ///   `.bak-<ts>` sibling, move [srcDir] into place, then delete the .bak.
  ///   If the move fails the .bak is renamed back (rollback), so the previous
  ///   content is never lost mid-way. Never delete-then-rename directly: a
  ///   crash in between would lose both copies.
  ///
  /// 无主目录也可能是「找回书库」（BUG-4701）还能恢复的孤儿书。同键的新导入照
  /// BUG-564 的既有取舍把它替换掉——用户此刻要的是这本新书，绕开旧目录只会让新书
  /// 落到 `~n` 去；要保住孤儿，得在导入同名书之前先去「找回书库」登记。
  ///
  /// [liveExtractDirs] 必须是**持有 [withBookPlacementLock] 之后**重取的快照，否则
  /// 「无主」的判断可能已经过期（BUG-4837）。
  ///
  /// TODO-1286: every staging -> destination move goes through [_moveDirInto],
  /// which falls back to a recursive copy+delete when the platform rejects
  /// `rename(2)`. Android's app-storage layer (fuse/sdcardfs and custom data
  /// roots on removable volumes) can reject a directory rename even for a
  /// vacated same-parent sibling (`FileSystemException: Rename failed, path =
  /// '.../fushi_books/.tmp-<ts>'`); a bare `renameSync` there aborts the whole
  /// remote-book download, so the audiobook never downloads and the shelf/sync
  /// marker never updates. Copy+delete is the portable move primitive and
  /// cannot fail with ENOTEMPTY/ENOTDIR/EXDEV the way rename can.
  static String moveDirIntoPlace({
    required Directory srcDir,
    required String targetDir,
    required Iterable<String> liveExtractDirs,
    bool forceCopyFallback = false,
  }) {
    final Directory target = Directory(targetDir);
    if (!target.existsSync()) {
      _moveDirInto(srcDir, targetDir, forceCopy: forceCopyFallback);
      return targetDir;
    }

    final String canonicalTarget = p.canonicalize(targetDir);
    final bool owned = liveExtractDirs.any(
      (String dir) => dir.isNotEmpty && p.canonicalize(dir) == canonicalTarget,
    );
    if (owned) {
      for (int i = 2; ; i++) {
        final String alt = '$targetDir~$i';
        if (!Directory(alt).existsSync()) {
          _moveDirInto(srcDir, alt, forceCopy: forceCopyFallback);
          return alt;
        }
      }
    }

    final String bak =
        '$targetDir.bak-${DateTime.now().millisecondsSinceEpoch}';
    target.renameSync(bak);
    try {
      _moveDirInto(srcDir, targetDir, forceCopy: forceCopyFallback);
    } catch (_) {
      // [_moveDirInto] cleans up any partial destination on failure, so the
      // target path is clean here and the .bak restore lands on empty ground.
      try {
        Directory(bak).renameSync(targetDir);
      } catch (rollbackError, stack) {
        engineLog.log('EpubImporter.replaceRollback', rollbackError, stack);
      }
      rethrow;
    }
    try {
      Directory(bak).deleteSync(recursive: true);
    } catch (e, stack) {
      // A leftover .bak dir is inert (never a future rename target); the next
      // process's [ensureImportResidueSwept] removes it. Log it.
      engineLog.log('EpubImporter.deleteBak', e, stack);
    }
    return targetDir;
  }

  /// Move [src] to [dest] (which MUST NOT exist). Tries `rename(2)` first and,
  /// when the platform rejects it (`FileSystemException`), falls back to a
  /// recursive copy + delete of the source. On a mid-copy failure the partial
  /// [dest] is removed so callers can safely roll back onto a clean path.
  ///
  /// The copy runs under [kIncompleteMarkerFileName], so a process killed
  /// mid-copy leaves a destination that [sweepImportResidue] can tell apart
  /// from a finished one.
  ///
  /// [forceCopy] is a test seam: when true the rename attempt is skipped and
  /// the copy+delete branch is exercised deterministically (real `rename(2)`
  /// failures are not portably reproducible in unit tests).
  static void _moveDirInto(
    Directory src,
    String dest, {
    bool forceCopy = false,
  }) {
    if (!forceCopy) {
      try {
        src.renameSync(dest);
        return;
      } on FileSystemException catch (e) {
        // Rename rejected (Android fuse/sdcardfs, custom data root on another
        // volume, or a residual target): fall through to copy+delete.
        engineLog.log(
          'EpubImporter.moveDirCopyFallback',
          e,
          StackTrace.current,
        );
      }
    }
    final Directory destDir = Directory(dest);
    try {
      destDir.createSync(recursive: true);
      final File marker = File(p.join(dest, kIncompleteMarkerFileName));
      marker.writeAsStringSync('');
      _copyDirSync(src, destDir);
      marker.deleteSync();
      src.deleteSync(recursive: true);
    } catch (_) {
      // Remove the partially-copied destination so callers see a clean path.
      try {
        if (destDir.existsSync()) destDir.deleteSync(recursive: true);
      } catch (cleanupError, stack) {
        engineLog.log('EpubImporter.moveDirCleanup', cleanupError, stack);
      }
      rethrow;
    }
  }

  /// Recursively copy the contents of [src] into [dest] (created if missing).
  /// Staged book trees hold only regular files and directories; any other
  /// entity type (e.g. a symlink) is skipped rather than followed.
  static void _copyDirSync(Directory src, Directory dest) {
    dest.createSync(recursive: true);
    for (final FileSystemEntity entity in src.listSync(followLinks: false)) {
      final String destPath = p.join(dest.path, p.basename(entity.path));
      if (entity is Directory) {
        _copyDirSync(entity, Directory(destPath));
      } else if (entity is File) {
        entity.copySync(destPath);
      }
    }
  }

  /// Base directory for all extracted books.
  static Future<String> baseDirectory() async {
    if (_cachedBaseDir != null) return _cachedBaseDir!;
    // TODO-935 E0：经唯一入口 [AppPaths] 取 documents 根（内部 honor 测试分支），
    // 派生 `<documents>/fushi_books`——与旧解析逐字节等价。
    final Directory appDir = await enginePaths.documentsRootDirectory();
    _cachedBaseDir = p.join(appDir.path, 'fushi_books');
    return _cachedBaseDir!;
  }

  /// Directory for a NEW book (keyed by its bookKey). Creates it if missing.
  static Future<String> bookDirectory(String bookKey) async {
    final String base = await baseDirectory();
    final String dir = p.join(base, bookKey);
    final Directory d = Directory(dir);
    if (!d.existsSync()) {
      d.createSync(recursive: true);
    }
    return dir;
  }

  /// Path for a NEW book — does NOT create the directory.
  static Future<String> bookPath(String bookKey) async {
    final String base = await baseDirectory();
    return p.join(base, bookKey);
  }

  /// Delete an extracted directory by its absolute path (the stored
  /// `extract_dir` column). Use this to remove an existing book whose on-disk
  /// folder name may still be a legacy int id.
  ///
  /// Also drops the book's derived illustration-index cache, which lives under
  /// the support root keyed by this path (BUG-3433) — first, so a locked
  /// extract dir (Windows errno 32) cannot leave it orphaned.
  static Future<void> deleteBookDir(String extractDir) async {
    if (extractDir.isEmpty) return;
    await deleteEpubImageIndexCache(extractDir);
    final Directory dir = Directory(extractDir);
    if (dir.existsSync()) {
      await dir.delete(recursive: true);
    }
  }

  /// Check whether an extracted directory at [extractDir] exists and has
  /// content.
  static Future<bool> bookDirExists(String extractDir) async {
    if (extractDir.isEmpty) return false;
    final Directory dir = Directory(extractDir);
    return dir.existsSync() && dir.listSync().isNotEmpty;
  }
}

/// 进程内先到先得的串行区：[run] 的 body 一次只跑一个，按调用顺序排队。
///
/// 排队靠每个调用方**自己建的** [Completer]，不靠「上一个调用留下的 Future」。
/// Dart 里给一个已完成的 Future 挂回调，派发用的是创建那个 Future 的 zone 的微任务
/// 队列；把上一个调用的 Future 存进静态字段当队尾，后来的调用方就得指望一个与自己
/// 无关的 zone 还在跑微任务——那个 zone 一旦停转（典型是 widget 测试里上一条用例的
/// fake-async zone），后面所有调用永远等不到轮次。这里每个等待者等的是自己 zone 里
/// 建的 Future，轮到它时的唤醒落在它自己的 zone 上。
///
/// body 总是在调用方让出一次之后才开始跑，不在 [run] 的调用栈里同步执行。
class _SerialSection {
  /// 队首是当前持有者，其后是按到达顺序排队的等待者。
  final List<Completer<void>> _turns = <Completer<void>>[];

  Future<T> run<T>(Future<T> Function() body) async {
    final Completer<void> turn = Completer<void>();
    _turns.add(turn);
    if (_turns.length == 1) turn.complete();
    await turn.future;
    try {
      return await body();
    } finally {
      _turns.removeAt(0);
      if (_turns.isNotEmpty) _turns.first.complete();
    }
  }
}
