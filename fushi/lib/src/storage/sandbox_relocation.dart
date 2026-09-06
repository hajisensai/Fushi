import 'dart:io';

import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi/src/storage/data_root_migrator.dart'
    show DataRootMigrator, DocumentsPathRebaser;

/// 数据根**被平台挪走**之后的启动期自愈。
///
/// ## 为什么需要它
///
/// 库里存的是绝对路径（`epub_books.extract_dir`、`audiobooks.audio_root`、
/// 封面、字幕、字体……覆盖清单见 `path_rebase_coverage.dart`）。这套持久化模型
/// 隐含一个前提：**数据根在两次启动之间不会变**。
///
/// 桌面成立，移动端不成立：
///  - **iOS 每次安装/更新都会换掉 app 容器 UUID**
///    （`/var/mobile/Containers/Data/Application/<UUID>/…`）。容器里的文件被系统
///    原样搬过去，但库里记的那串旧 UUID 路径**集体悬空**——用户看到的症状是
///    「更新一次，整个书架全部『找不到书籍文件』」，且每次更新复发一次。
///  - 从备份/换机恢复同样会换容器。
///
/// `DataRootMigrator` 的文件头写着「仅桌面……不在移动端调用（**沙箱固定**）」——
/// 那个前提就是本 bug 的源头。根不是固定的，只是**谁来改根**不同：桌面是用户主动
/// 换，移动端是系统在背后换。既然「根变了，库里的绝对路径要跟着变」这件事两边
/// 完全一样，改写就必须复用同一套引擎，而不是给移动端另写一份。
///
/// ## 判据：只改写「改完之后在磁盘上真的存在」的那一种映射
///
/// 本模块**不猜**。两条路径都要求先拿到一个可信的旧根：
///
///  1. **有台账**（常态）：上次启动记下的根与本次解析出的根不同 → 旧根就是台账里
///     那个，精确、无推断。台账每次启动都写，所以这条路径覆盖今后所有漂移。
///  2. **无台账**（一次性补救）：本功能上线之前就已经被挪走的安装，台账是空的。
///     此时从存量数据反推：取一条存量绝对路径，若它**已经不存在**、而把它「数据根
///     以下那段」接到**当前**根之后**存在**，那这条映射就被磁盘证实了，旧根 =
///     该路径去掉那一段。找不到证据就什么都不做。
///
/// 「数据根以下那段」的起点由 [AppPaths.fushiOwnedDocumentsEntries] 认定——那是本
/// app 自己在 documents 根下派生的顶层目录白名单，已有守卫测试盯着新增派生点。
///
/// 反推失败、或改写抛错，都**不阻塞启动**：调用方吞掉并上报，用户至多回到修复前
/// 的状态（照旧报「找不到书籍文件」），绝不会因为自愈失败而进不去 app。
class SandboxRelocation {
  const SandboxRelocation._();

  /// 上次启动时的 documents 根。落在 DB 的 `preferences` 表而不是
  /// SharedPreferences：台账描述的就是这个库里的路径，两者必须同生共死。分家的
  /// 后果是「库被恢复到另一台机器、台账却还留在本机」——那正是最需要重基的场合，
  /// 却会被判成「根没变」。
  static const String lastDocumentsRootPrefKey = 'sandbox_last_documents_root';

  /// 上次启动时的 support（数据库）根。
  static const String lastSupportRootPrefKey = 'sandbox_last_support_root';

  /// 反推旧根时最多取样多少条存量路径。取样只为找**一条**能被磁盘证实的映射，
  /// 拿到就停；上限只是为了让「一条都证实不了」的坏情况不至于扫全表。
  static const int deriveSampleLimit = 32;

  /// 启动期对账：根变了就把全库绝对路径重基过去，然后把本次的根记进台账。
  ///
  /// 必须在 DB 打开之后、**任何消费路径的东西读它之前**调用。
  ///
  /// 返回本次实际发生了什么，供调用方写日志/取证；不抛异常由调用方决定，这里
  /// 只负责把 [onError] 喂饱。
  static Future<SandboxRelocationOutcome> reconcile({
    required FushiDatabase db,
    required String documentsRoot,
    required String supportRoot,
    void Function(Object error, StackTrace stack)? onError,
  }) async {
    try {
      final String? recorded = await db.getPref(lastDocumentsRootPrefKey);
      final String? oldRoot;
      final SandboxRelocationSource source;
      if (recorded == null || recorded.isEmpty) {
        // 台账为空：要么是全新安装（没有存量路径，反推自然一无所获），要么是本
        // 功能上线前就已被挪走的老安装（正是要补救的那一批）。两种情形走同一条
        // 反推，靠「磁盘上存不存在」自然分流。
        oldRoot = await deriveOldDocumentsRoot(
          db: db,
          currentDocumentsRoot: documentsRoot,
        );
        source = SandboxRelocationSource.derivedFromData;
      } else if (_sameRoot(recorded, documentsRoot)) {
        oldRoot = null;
        source = SandboxRelocationSource.ledger;
      } else {
        oldRoot = recorded;
        source = SandboxRelocationSource.ledger;
      }

      // 一根套在另一根里面时**绝不重基**：这形状只可能来自 DataRootMigrator
      // （用户把数据收进 `<旧根>/Hibiki/data`，或迁到默认位置 `<Documents>/
      // Hibiki/data`）。那条路径已经把全库路径改写好了，而台账不在
      // `kPathRebasePrefs` 里、仍停在旧根 —— 再按台账重基一次，就会把已经改写
      // 过的 `<新根>/fushi_books/a` 又前缀一遍变成
      // `<新根>/Hibiki/data/fushi_books/a`。这正是 data_root_migrator 里记着的
      // BUG-1174 ③「新根落在旧根内部时会把已改写过的 path 再改一遍」，别让它
      // 从这条新路径原样复活。判据与 `_validateTarget` 的嵌套判据一致。
      if (oldRoot == null ||
          _sameRoot(oldRoot, documentsRoot) ||
          _isNestedRoot(oldRoot, documentsRoot)) {
        await _writeLedger(db, documentsRoot, supportRoot);
        return SandboxRelocationOutcome.unchanged(source);
      }

      await DataRootMigrator.rebaseOpenDatabasePaths(
        db: db,
        docs: DocumentsPathRebaser(
          oldRoot: oldRoot,
          newRoot: documentsRoot,
          // 只重基**数据根自己那几个顶层项**。容器整体被搬走时，库内路径的首段
          // 本来就全在这份白名单里（`deriveOldRootFromPath` 反推旧根时用的正是
          // 同一份判据，两侧必须一致）；传 null 等于在所有平台上放弃迁移引擎
          // 刻意保留的「不碰非 Hibiki 内容」保护 —— 用户自选的外部媒体库只要
          // 恰好落在旧根之下，就会被一起改写。
          scopeTopLevelNames: AppPaths.fushiOwnedDocumentsEntries,
        ),
        newSupportRoot: supportRoot,
      );
      await _writeLedger(db, documentsRoot, supportRoot);
      return SandboxRelocationOutcome.rebased(
        source: source,
        oldDocumentsRoot: oldRoot,
        newDocumentsRoot: documentsRoot,
      );
    } on Object catch (error, stack) {
      onError?.call(error, stack);
      // 自愈失败不能变成「进不去 app」。台账**故意不写**：下次启动还会再试一次。
      return SandboxRelocationOutcome.failed(error);
    }
  }

  /// 从存量数据反推旧 documents 根；拿不到磁盘证据就返回 null。
  ///
  /// 判据（三条全中才算证实）：
  ///  1. 存量路径是绝对路径，且能在其中定位到一个
  ///     [AppPaths.fushiOwnedDocumentsEntries] 顶层段——否则它根本不是「数据根内
  ///     路径」（外部媒体库、用户自选目录等一律不碰）；
  ///  2. 该路径**当前不存在**（存在就说明根没坏，无需重基）；
  ///  3. 把「顶层段及其之后」接到 [currentDocumentsRoot] 之后**存在**。
  ///
  /// 三条同时成立时，旧根 = 该路径去掉那一段。这不是启发式：第 3 条要求改写后的
  /// 目标真的躺在磁盘上，猜错的映射通不过。
  static Future<String?> deriveOldDocumentsRoot({
    required FushiDatabase db,
    required String currentDocumentsRoot,
  }) async {
    for (final String stored in await _sampleStoredPaths(db)) {
      final String? derived = deriveOldRootFromPath(
        storedPath: stored,
        currentDocumentsRoot: currentDocumentsRoot,
        exists: _pathExists,
      );
      if (derived != null) return derived;
    }
    return null;
  }

  /// [deriveOldDocumentsRoot] 的纯函数内核（[exists] 注入以便单测不碰真实磁盘）。
  static String? deriveOldRootFromPath({
    required String storedPath,
    required String currentDocumentsRoot,
    required bool Function(String path) exists,
  }) {
    if (storedPath.isEmpty) return null;
    final String normalized = storedPath.replaceAll('\\', '/');
    if (!normalized.startsWith('/') && !_hasWindowsDrive(normalized)) {
      return null; // 相对路径（裸文件名 / 相对 href）不是数据根内绝对路径。
    }
    final List<String> segments = normalized.split('/');
    // 从**右往左**找白名单段：路径里可能同时出现两个白名单名（例如旧根本身就叫
    // `.../videos/...`），靠右那个才是真正的数据根首段。
    for (int i = segments.length - 1; i > 0; i--) {
      final String segment = segments[i];
      final bool owned = AppPaths.fushiOwnedDocumentsEntries.any(
        (String name) => name.toLowerCase() == segment.toLowerCase(),
      );
      if (!owned) continue;
      final String tail = segments.sublist(i).join('/');
      final String candidateOldRoot = segments.sublist(0, i).join('/');
      if (candidateOldRoot.isEmpty) continue;
      if (_sameRoot(candidateOldRoot, currentDocumentsRoot)) continue;
      if (exists(normalized)) continue; // 老路径还在 → 根没坏，别动。
      final String moved = p.posix.join(
        currentDocumentsRoot.replaceAll('\\', '/'),
        tail,
      );
      if (!exists(moved)) continue; // 磁盘不认这条映射 → 不是它。
      return candidateOldRoot;
    }
    return null;
  }

  /// 取样存量绝对路径。只读 `epub_books`：书是数量最多、也最早被用户碰到的那类
  /// 内容，`extract_dir` 恒为数据根内绝对目录，取样命中率最高。
  static Future<List<String>> _sampleStoredPaths(FushiDatabase db) async {
    final List<String> paths = <String>[];
    for (final EpubBookRow row in await db.getAllEpubBooks()) {
      if (row.extractDir.isNotEmpty) paths.add(row.extractDir);
      if (paths.length >= deriveSampleLimit) break;
    }
    return paths;
  }

  static bool _pathExists(String path) =>
      Directory(path).existsSync() || File(path).existsSync();

  static bool _hasWindowsDrive(String normalized) =>
      normalized.length >= 3 &&
      normalized[1] == ':' &&
      normalized[2] == '/' &&
      RegExp(r'^[A-Za-z]$').hasMatch(normalized[0]);

  /// 根比较：只做分隔符归一 + 去尾分隔符。**不做大小写折叠**——`DocumentsPathRebaser`
  /// 的前缀判据是大小写敏感的，这里放宽会让「判定没变、改写却匹配不上」两边打架。
  static bool _sameRoot(String a, String b) => _canonRoot(a) == _canonRoot(b);

  /// 两个根是否一个套在另一个里面（任一方向）。用 posix 语义比较：两侧都已经过
  /// [_canonRoot] 把 `\` 归一成 `/` 并剪掉尾斜杠。
  static bool _isNestedRoot(String a, String b) {
    final String ca = _canonRoot(a);
    final String cb = _canonRoot(b);
    if (ca.isEmpty || cb.isEmpty) return false;
    return p.posix.isWithin(ca, cb) || p.posix.isWithin(cb, ca);
  }

  static String _canonRoot(String value) {
    final String normalized = value.replaceAll('\\', '/');
    return normalized.endsWith('/')
        ? normalized.substring(0, normalized.length - 1)
        : normalized;
  }

  static Future<void> _writeLedger(
    FushiDatabase db,
    String documentsRoot,
    String supportRoot,
  ) async {
    await db.setPref(lastDocumentsRootPrefKey, documentsRoot);
    await db.setPref(lastSupportRootPrefKey, supportRoot);
  }
}

/// 旧根是怎么拿到的。
enum SandboxRelocationSource {
  /// 上次启动写下的台账（精确）。
  ledger,

  /// 台账为空，从存量数据反推并经磁盘证实（一次性补救）。
  derivedFromData,
}

/// 一次启动期对账的结果。
class SandboxRelocationOutcome {
  const SandboxRelocationOutcome._({
    required this.rebased,
    required this.source,
    this.oldDocumentsRoot,
    this.newDocumentsRoot,
    this.error,
  });

  factory SandboxRelocationOutcome.unchanged(SandboxRelocationSource source) =>
      SandboxRelocationOutcome._(rebased: false, source: source);

  factory SandboxRelocationOutcome.rebased({
    required SandboxRelocationSource source,
    required String oldDocumentsRoot,
    required String newDocumentsRoot,
  }) =>
      SandboxRelocationOutcome._(
        rebased: true,
        source: source,
        oldDocumentsRoot: oldDocumentsRoot,
        newDocumentsRoot: newDocumentsRoot,
      );

  factory SandboxRelocationOutcome.failed(Object error) =>
      SandboxRelocationOutcome._(
        rebased: false,
        source: SandboxRelocationSource.ledger,
        error: error,
      );

  /// 本次是否真的改写了库里的路径。
  final bool rebased;

  final SandboxRelocationSource source;
  final String? oldDocumentsRoot;
  final String? newDocumentsRoot;

  /// 非 null = 本次自愈失败（已上报，启动照常继续，下次启动会再试）。
  final Object? error;

  @override
  String toString() => rebased
      ? 'SandboxRelocation(rebased ${source.name}: '
          '$oldDocumentsRoot -> $newDocumentsRoot)'
      : 'SandboxRelocation(unchanged${error == null ? '' : ', error: $error'})';
}
