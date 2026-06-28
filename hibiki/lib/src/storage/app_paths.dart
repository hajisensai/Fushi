import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hibiki/src/startup/test_environment.dart';
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
  static Future<AppPaths> resolve() async {
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

  /// 读取桌面自定义数据根（绝对路径）。无覆盖 / 非桌面 / 目录不存在 → 返回 null，
  /// 调用方退回 `path_provider` 默认根（老用户逐字节零变化）。
  ///
  /// **顺序铁律**：[hibikiTestDirectory] 测试分支在三个 `_resolve*` 里**优先于**本覆盖
  /// （测试根始终赢），保证现有测试与 E0 行为等价的断言不被 dataRoot 改动破坏。
  static Future<Directory?> _resolveDataRoot() async {
    if (!isDesktopPlatform) return null;
    final Future<String?> Function()? reader = debugDataRootReader;
    String? raw;
    if (reader != null) {
      raw = await reader();
    } else {
      try {
        raw =
            (await SharedPreferences.getInstance()).getString(dataRootPrefKey);
      } catch (_) {
        // SharedPreferences 平台通道不可用（无插件注册的纯 Dart 测试环境 / 极端
        // 启动早期）→ 按「无覆盖」处理，退回 path_provider 默认根，与 E1 前行为
        // 逐字节一致。生产端插件恒注册，正常读到 data_root 覆盖值。
        return null;
      }
    }
    if (raw == null || raw.trim().isEmpty) return null;
    final Directory dir = Directory(raw);
    if (!dir.existsSync()) return null; // 失效路径（盘符没挂/被删）→ 退回默认根
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
