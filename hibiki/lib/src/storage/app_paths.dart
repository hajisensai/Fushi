import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hibiki/src/startup/test_environment.dart';
import 'package:hibiki/src/storage/macos_data_root_access.dart';
import 'package:hibiki/src/utils/misc/platform_utils.dart';

/// TODO-935 E0：应用数据根目录的**唯一入口**。
///
/// 历史上 ~10+ 模块各自直连 `path_provider`（`getApplicationDocumentsDirectory` /
/// `getApplicationSupportDirectory` / `getTemporaryDirectory`），导致没有单一的「数据
/// 根」真相源——后续 E1（数据迁移）/E2（设置 UI）/E3（重启换根）无从下手。
///
/// [AppPaths] 把三个根的解析收敛到这里：
///   - [documentsRoot] —— 内容/书库根（`getApplicationDocumentsDirectory`，
///     Windows = `%USERPROFILE%\Documents`）。EPUB 正文、有声书音频、视频封面/字幕、
///     词典资源、缩略图等用户数据都派生自它。
///   - [supportRoot] —— 数据库根（`getApplicationSupportDirectory`，
///     Windows = `%APPDATA%\<pkg>`）。`hibiki.db` 与 per-source local-audio DB 落这里。
///   - [tempRoot] —— 可丢弃的临时目录（`getTemporaryDirectory`）。
///
/// **E0 是纯收敛、行为等价**：解析逻辑（先 [hibikiTestDirectory] 测试分支，否则
/// `path_provider` 默认）与各模块原先逐字节一致，所有派生子目录名不变，旧数据零迁移。
/// E1/E2/E3 只需在 [_resolveDocumentsRoot] / [_resolveSupportRoot] 内插入「读
/// SharedPreferences 里的 dataRoot（仅桌面）」一处，全仓库自动跟随。
///
/// 解析既提供**实例 API**（[AppPaths] 在启动期由 [AppPaths.resolve] 构造一次、由
/// `AppModel` 持有并派生其 `appDirectory` / `databaseDirectory` / `temporaryDirectory`
/// 等 getter），也提供**静态便捷层**（[documentsRootDirectory] /
/// [audiobooksDirectory] 等），给 `EpubStorage` / `VideoStorage` /
/// `mpvShaderDirectory` 这些无法持有 `AppModel` 实例的 `static` 存储助手用。两条路径
/// 共用同一份解析函数（[_resolveDocumentsRoot] 等），不存在两套缓存打架。
/// BUG-815：桌面端**配置了自定义数据根、但本次启动它不可达**（休眠 / 高负载 / 掉线 /
/// 拔出的盘）时由 [AppPaths.resolve] 抛出。
///
/// 铁律：这种情况**绝不**静默派生空的 `path_provider` 默认根——那会让用户看到「全空」
/// 误以为数据被清空，甚至在空态里把新内容写进错误位置，而真实数据其实原封不动躺在配置
/// 的盘上。UI 接住本异常，改显「数据位置未响应」逃生屏（重试 / 由用户显式选择用默认位置
/// 启动），而不是把空当真。
class DataRootUnavailableException implements Exception {
  DataRootUnavailableException({required this.configuredPath});

  /// 用户在设置里配置的自定义数据根绝对路径（本次不可达，但数据仍在此处）。
  final String configuredPath;

  @override
  String toString() =>
      'DataRootUnavailableException(configuredPath: $configuredPath)';
}

class AppPaths {
  AppPaths._({
    required this.documentsRoot,
    required this.supportRoot,
    required this.tempRoot,
  });

  /// 内容/书库根（`getApplicationDocumentsDirectory` 或测试分支）。
  final Directory documentsRoot;

  /// 数据库根（`getApplicationSupportDirectory` 或测试分支）。
  final Directory supportRoot;

  /// 可丢弃临时目录（`getTemporaryDirectory` 或测试分支）。
  final Directory tempRoot;

  /// 解析三个根一次，返回不可变快照。在启动期 `_prepareRuntimeDirectories` 调用。
  ///
  /// BUG-815 预检（桌面）：若**配置了**自定义数据根但本次探测不可达，**抛
  /// [DataRootUnavailableException]**，绝不静默派生空默认根（那等于把用户数据「弄没」
  /// 的观感）。仅当用户已显式选择「本次用默认位置启动」（[forceDefaultRootForSession]）
  /// 时跳过预检、走默认根。无自定义根的普通用户（configured==null）不受影响。
  static Future<AppPaths> resolve() async {
    if (isDesktopPlatform && !forceDefaultRootForSession) {
      final String? configured = await _configuredDataRootPath();
      if (configured != null &&
          !await _probeDataRootExists(Directory(configured))) {
        throw DataRootUnavailableException(configuredPath: configured);
      }
    }
    final Directory documents = await _resolveDocumentsRoot();
    final Directory support = await _resolveSupportRoot();
    final Directory temp = await _resolveTempRoot();
    return AppPaths._(
      documentsRoot: documents,
      supportRoot: support,
      tempRoot: temp,
    );
  }

  // ---- 单一真相源：三个根的解析函数（实例 + 静态层共用） ----

  /// TODO-935 E1：SharedPreferences 里「自定义数据根」的键名。值是一个**绝对目录路径**
  /// （仅桌面有效）。把它落 SharedPreferences 而非 Drift `preferences` 表，是因为数据根
  /// 配置必须在 DB 打开*之前*可读——而 DB 自身正是要被迁移的对象（鸡生蛋）。
  /// SharedPreferences 在桌面是固定平台落点（不随数据根迁移），启动早期即可读
  /// （`desktop_window_placement.dart` 已证明 DB 打开前 `getInstance()` 可用）。
  static const String dataRootPrefKey = 'data_root';

  /// `<dataRoot>` 下「内容/书库」子目录名。dataRoot 覆盖生效时，documentsRoot 落这里，
  /// 不与 supportRoot 子目录冲突（两根共一个 dataRoot 时仍各有独立子树）。
  static const String _dataRootDocumentsChild = 'documents';

  /// `<dataRoot>` 下「数据库/支持」子目录名。
  static const String _dataRootSupportChild = 'support';

  /// 测试注入钩子：覆盖「读 SharedPreferences 的 data_root」这一步，使 [AppPaths] 的
  /// dataRoot 派生在纯 Dart 单测里可断言（无需平台 SharedPreferences 通道）。返回 null
  /// 时走真实读取；返回空串视为「无覆盖」。仅供测试设置，生产恒 null。
  static Future<String?> Function()? debugDataRootReader;

  /// BUG-815：用户在「数据位置未响应」逃生屏上**显式选择**「仍用默认位置启动」时置真。
  /// 置真后本次启动跳过 [resolve] 的不可达预检、[_resolveDataRoot] 直接返回 null（走
  /// `path_provider` 默认根），让配置了自定义根但盘暂时不可达的用户能主动进入空态而不被
  /// 锁在门外——**绝不自动置真**（默认 false）。仅本次进程有效：下次启动重新探测配置根，
  /// 盘醒了即自动用回真实数据；用户的 `data_root` 配置与原盘数据一字节不动。
  static bool forceDefaultRootForSession = false;

  /// 读取桌面自定义数据根**配置路径**（绝对路径，不做存在性探测）。无覆盖 / 非桌面 /
  /// 未设 / 空白 / prefs 通道不可用 → 返回 null（调用方退回默认根）。macOS 下顺带激活
  /// 安全域书签。存在性探测分离到 [_probeDataRootExists]。
  static Future<String?> _configuredDataRootPath() async {
    if (!isDesktopPlatform) return null;
    final Future<String?> Function()? reader = debugDataRootReader;
    String? raw;
    if (reader != null) {
      raw = await reader();
    } else {
      try {
        final SharedPreferences prefs = await SharedPreferences.getInstance();
        raw = prefs.getString(dataRootPrefKey);
        if (raw != null && raw.trim().isNotEmpty && Platform.isMacOS) {
          raw = await MacOSDataRootAccess.startAccessingStoredBookmark(prefs) ??
              raw;
        }
      } catch (_) {
        // SharedPreferences 平台通道不可用（无插件注册的纯 Dart 测试环境 / 极端
        // 启动早期）→ 按「无覆盖」处理，退回 path_provider 默认根，与 E1 前行为
        // 逐字节一致。生产端插件恒注册，正常读到 data_root 覆盖值。
        return null;
      }
    }
    if (raw == null || raw.trim().isEmpty) return null;
    return raw;
  }

  /// TODO-1260 / BUG-572：对数据根目录做**带 2s 超时的异步存在性探测**。自定义数据根可能
  /// 落在网络盘 / 移动盘上，盘**掉线**时旧代码的同步 `existsSync()`（阻塞式 `stat`）会在
  /// **主 isolate** 卡到 OS 层超时（Windows 对断链网络盘可达数十秒），而它跑在 app 启动
  /// 最早期 → 无限加载。异步 `exists()` 不阻塞主 isolate，再叠 2s 超时兜底断链盘连异步
  /// stat 都不回的极端情况。**铁律**：只准 `exists().timeout(...)`，永不 `existsSync()`
  /// （守卫 `test/storage/app_paths_data_root_timeout_test.dart`）。超时 / 抛错 / 不存在
  /// 都返回 false。
  static Future<bool> _probeDataRootExists(Directory dir) async {
    try {
      return await dir
          .exists()
          .timeout(const Duration(seconds: 2), onTimeout: () => false);
    } catch (_) {
      // 断链盘的异步 stat 也可能直接抛（而非挂起）→ 同样当作不可用。
      return false;
    }
  }

  /// 解析桌面自定义数据根（可用时返回目录，否则 null → 调用方退回默认根）。
  ///
  /// **数据安全语义**：返回 null 只代表「本次启动用默认根」，pref 里的自定义根路径与原盘
  /// 数据一字节不动，盘恢复后下次启动自动用回。**注意**：启动期真正的「配置了但不可达」
  /// 由 [resolve] 预检提前抛 [DataRootUnavailableException] 拦截（不静默回退）；本函数保持
  /// 宽容仅服务于 [forceDefaultRootForSession] 用户显式回退，以及无 AppModel 实例的运行时
  /// 静态便捷层（`documentsRootDirectory` 等，此时根已在 init 期确认可用）。
  ///
  /// **顺序铁律**：[hibikiTestDirectory] 测试分支在三个 `_resolve*` 里**优先于**本覆盖
  /// （测试根始终赢），保证现有测试与 E0 行为等价的断言不被 dataRoot 改动破坏。
  static Future<Directory?> _resolveDataRoot() async {
    if (!isDesktopPlatform) return null;
    // BUG-815：用户已显式选择本次用默认位置启动（配置根不可达时）→ 直接退回默认根。
    if (forceDefaultRootForSession) return null;
    final String? raw = await _configuredDataRootPath();
    if (raw == null) return null;
    final Directory dir = Directory(raw);
    if (!await _probeDataRootExists(dir)) return null;
    return dir;
  }

  static Future<Directory> _resolveDocumentsRoot() async {
    final Directory? test = hibikiTestDirectory('app-documents');
    if (test != null) return test;
    final Directory? dataRoot = await _resolveDataRoot();
    if (dataRoot != null) {
      return Directory(p.join(dataRoot.path, _dataRootDocumentsChild));
    }
    return getApplicationDocumentsDirectory();
  }

  static Future<Directory> _resolveSupportRoot() async {
    final Directory? test = hibikiTestDirectory('app-support');
    if (test != null) return test;
    final Directory? dataRoot = await _resolveDataRoot();
    if (dataRoot != null) {
      return Directory(p.join(dataRoot.path, _dataRootSupportChild));
    }
    return getApplicationSupportDirectory();
  }

  // tempRoot 永远走系统临时目录（可丢弃、与数据根解耦）：迁移不搬 temp，dataRoot 也不接管它。
  static Future<Directory> _resolveTempRoot() async =>
      hibikiTestDirectory('temp') ?? await getTemporaryDirectory();

  /// 给迁移引擎（E1）/ 设置 UI（E2）复用的纯派生：把一个 dataRoot 绝对路径映射成它
  /// 派生的 (documentsRoot, supportRoot) 对，子目录名与 [_resolveDocumentsRoot] /
  /// [_resolveSupportRoot] 的 dataRoot 分支逐字节一致。
  static (Directory documents, Directory support) rootsForDataRoot(
    String dataRootPath,
  ) =>
      (
        Directory(p.join(dataRootPath, _dataRootDocumentsChild)),
        Directory(p.join(dataRootPath, _dataRootSupportChild)),
      );

  /// TODO-1226：documents 根顶层**属于 Hibiki 的目录名全集**（数据根迁移白名单）。
  ///
  /// 默认数据根时 documents 根 = 整个用户 `Documents`（共享目录，含用户自己的文件和
  /// shell junction）。迁移引擎对共享根**只搬这份白名单里的顶层项**，绝不整树搬移 /
  /// 整树删除用户 `Documents`。每一项都必须对应仓库里一个真实的派生点：
  ///
  ///  - `audiobooks` —— [audiobooksDirectory]；`AppModel` 各处
  ///    `join(appDirectory, 'audiobooks')`；`AudiobookStorage.ensurePersistDir`。
  ///  - `hoshi_books` —— [epubBooksDirectory]；`EpubStorage`；backup restore。
  ///  - `video_covers` —— [videoCoversDirectory]；`VideoStorage.coversDirName`。
  ///  - `game_covers` —— [gameCoversDirectory]；游戏库封面（手选 + 自动获取）。
  ///  - `video_subtitles` —— [videoSubtitlesDirectory]；`VideoStorage.subtitlesDirName`。
  ///  - `mpv_shaders` —— [mpvShadersDirectory]。
  ///  - `remote_videos` —— [remoteVideosDirectory]。
  ///  - `videos` —— backup restore 的视频落点（`backup.part.dart`
  ///    `join(appDirectory, 'videos')`）。
  ///  - `custom_fonts` —— 字体导入/加载（`custom_fonts_page.dart` 等
  ///    `join(appDirectory, 'custom_fonts')`）。
  ///  - `hibikiExport` —— `AppModel.prepareFallbackHibikiDirectory`。
  ///  - `browser` / `thumbnails` / `dictionaryResources` /
  ///    `dictionaryImportWorkingDirectory` / `webArchive` ——
  ///    `AppModel` 运行时目录系列派生。
  ///
  /// **刻意不收**：`error_log.txt` / `*_breadcrumb.txt`（`ErrorLogService` 直连
  /// `getApplicationDocumentsDirectory()`，固定落平台 Documents、不随数据根走，搬走
  /// 反而让服务失去续写目标）；`video_clips` 与桌面导出目录 `Hibiki`（同样直连
  /// path_provider 的用户可见导出物，属用户文件语义）。
  ///
  /// 守卫测试 `test/storage/documents_whitelist_guard_test.dart` 扫描源码派生点，
  /// 新增 `<documents>/<child>` 派生而漏加这里会红。
  static const Set<String> hibikiOwnedDocumentsEntries = <String>{
    'audiobooks',
    'hoshi_books',
    'video_covers',
    'game_covers',
    'video_subtitles',
    'mpv_shaders',
    'remote_videos',
    'videos',
    'anime_downloads',
    'custom_fonts',
    'hibikiExport',
    'browser',
    'thumbnails',
    'dictionaryResources',
    'dictionaryImportWorkingDirectory',
    'webArchive',
  };

  // ---- 静态便捷层（给无 AppModel 实例的 static 存储助手） ----

  /// 内容/书库根目录。等价于过去散落各处的 `getApplicationDocumentsDirectory()`。
  static Future<Directory> documentsRootDirectory() => _resolveDocumentsRoot();

  /// 数据库根目录。等价于过去的 `getApplicationSupportDirectory()`。
  static Future<Directory> supportRootDirectory() => _resolveSupportRoot();

  /// 临时目录。等价于过去的 `getTemporaryDirectory()`。
  static Future<Directory> tempRootDirectory() => _resolveTempRoot();

  /// `<documents>/<child>` 的绝对路径目录（不创建）。集中派生点，保证各模块对同一
  /// 子目录名拿到逐字节一致的绝对路径。
  static Future<Directory> documentsSubdirectory(String child) async {
    final Directory root = await _resolveDocumentsRoot();
    return Directory(p.join(root.path, child));
  }

  /// 有声书音频持久根 `<documents>/audiobooks`（复制导入的统一落点）。
  static Future<Directory> audiobooksDirectory() =>
      documentsSubdirectory('audiobooks');

  /// EPUB 解压正文根 `<documents>/hoshi_books`。
  static Future<Directory> epubBooksDirectory() =>
      documentsSubdirectory('hoshi_books');

  /// 视频封面目录 `<documents>/video_covers`。
  static Future<Directory> videoCoversDirectory() =>
      documentsSubdirectory('video_covers');

  /// 游戏库封面目录 `<documents>/game_covers`（手动设置与自动获取的统一落点，
  /// 文件名是 `<GalgameEntry.id>.<ext>`）。
  static Future<Directory> gameCoversDirectory() =>
      documentsSubdirectory('game_covers');

  /// 视频外挂字幕副本目录 `<documents>/video_subtitles`。
  static Future<Directory> videoSubtitlesDirectory() =>
      documentsSubdirectory('video_subtitles');

  /// mpv 着色器目录 `<documents>/mpv_shaders`。
  static Future<Directory> mpvShadersDirectory() =>
      documentsSubdirectory('mpv_shaders');

  /// 远程视频下载目录 `<documents>/remote_videos`。
  static Future<Directory> remoteVideosDirectory() =>
      documentsSubdirectory('remote_videos');
}
