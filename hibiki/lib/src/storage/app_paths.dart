import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:hibiki/src/startup/test_environment.dart';

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

  static Future<Directory> _resolveDocumentsRoot() async =>
      hibikiTestDirectory('app-documents') ??
      await getApplicationDocumentsDirectory();

  static Future<Directory> _resolveSupportRoot() async =>
      hibikiTestDirectory('app-support') ??
      await getApplicationSupportDirectory();

  static Future<Directory> _resolveTempRoot() async =>
      hibikiTestDirectory('temp') ?? await getTemporaryDirectory();

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
