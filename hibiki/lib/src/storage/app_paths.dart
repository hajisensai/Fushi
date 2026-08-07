import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:fushi_core/fushi_core.dart'
    show fushiDatabaseFileName, legacyHibikiDatabaseFileName;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fushi/src/startup/test_environment.dart';
import 'package:fushi/src/storage/macos_data_root_access.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart';

/// TODO-935 E0：应用数据根目录的**唯一入口**。
///
/// 历史上 ~10+ 模块各自直连 `path_provider`（`getApplicationDocumentsDirectory` /
/// `getApplicationSupportDirectory` / `getTemporaryDirectory`），导致没有单一的「数据
/// 根」真相源——后续 E1（数据迁移）/E2（设置 UI）/E3（重启换根）无从下手。
///
/// [AppPaths] 把三个根的解析收敛到这里：
///   - [documentsRoot] —— 内容/书库根。EPUB 正文、有声书音频、视频封面/字幕、词典资源、
///     缩略图等用户数据都派生自它。默认（未配置自定义数据根）落平台 Documents 下的
///     Hibiki 专属容器 `<Documents>/Hibiki/data`；**老安装**仍锚定历史扁平布局
///     `<Documents>` 本身（见 [_resolveDefaultDocumentsRoot]）。
///   - [supportRoot] —— 数据库根（`getApplicationSupportDirectory`，
///     Windows = `%APPDATA%\<pkg>`）。`fushi.db` 与 per-source local-audio DB 落这里。
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
    // BUG-1115：默认 documents 布局的判定**只在这里**做一次（启动期，真实异步环境）。
    // 判定要探测文件系统，绝不能塞进 [_resolveDocumentsRoot]——那条路径会被运行时的静态
    // 便捷层（`documentsSubdirectory` 等）高频调用，其中就包括 widget 测试里的封面/资源
    // 解析：`testWidgets` 跑在 FakeAsync 上，真实文件 IO 的 future 在那里永不完成、
    // `.timeout()` 还会留下 pending timer，整批页面测试会挂死或报「Timer is still pending」。
    await _ensureDocumentsLayoutDecided();
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

  /// BUG-1115：**默认** documents 根的布局键（SharedPreferences，与 [dataRootPrefKey]
  /// 同一通道，DB 打开前可读）。值只有两个：[documentsLayoutFlat] /
  /// [documentsLayoutNested]。
  ///
  /// 一经写入就是本机的**永久锚点**，不再重新探测：布局若随「Documents 里此刻有没有某个
  /// 目录」漂移，同一台机器两次启动就可能解析出两个不同的内容根 = 用户书库凭空消失。
  static const String documentsLayoutPrefKey = 'documents_layout';

  /// 历史扁平布局：documents 根 = 平台 `Documents` **本身**，16 个 Hibiki 子目录直接摊在
  /// 用户文档根下。老安装锚定于此（零迁移，见 [_resolveDefaultDocumentsRoot]）。
  static const String documentsLayoutFlat = 'flat';

  /// 当前默认布局：documents 根 = `<Documents>/Hibiki/data`（Hibiki 专属容器）。
  ///
  /// BUG-1188：迁移把数据归一化到默认位置时，提交阶段必须把这个锚点写成本值——否则下次
  /// 启动仍按 `flat` 把 documents 根解析回共享 `Documents`，而数据已经在 `Hibiki/data` 里。
  static const String documentsLayoutNested = 'nested';

  /// [documentsLayoutNested] 下平台 Documents 到 documents 根的相对路径段。
  ///
  /// 为什么是 `Hibiki/data` 而不是 `Hibiki`：`<Documents>/Hibiki` 历史上是**用户可见
  /// 导出目录**（旧 `getHibikiExportDirectory` 服务链，W2-4 已删除该死代码——导出实际
  /// 一直走 appDirectory 下的 fallback 目录）。数据根取它下面的 `data/`，用户文档根下
  /// 只多出一个容器伞，内部数据与导出物各占一层、互不淹没。
  /// Fushi 改名（Phase 3）：新装容器名 `Fushi`；存量 nested 安装的目录还叫
  /// `Hibiki`，由 [documentsContainerPrefKey] 锚点冻结（同 flat/nested 锚点
  /// 哲学：存量布局一经判定永不漂移，改名不搬书库——DB 里的绝对路径都指着它）。
  static List<String> get defaultDocumentsChildSegments => <String>[
        _documentsContainerName ?? 'Fushi',
        'data',
      ];

  /// nested 容器名锚点（SharedPreferences，与布局锚点同通道）。值 `Hibiki`
  /// （存量安装）或 `Fushi`（新装/已迁移）。
  static const String documentsContainerPrefKey = 'documents_container';

  /// 本进程已判定的容器名；[_ensureDocumentsLayoutDecided] 启动期写一次。
  static String? _documentsContainerName;

  /// 本进程已判定的默认布局（true=扁平老布局）。由 [_ensureDocumentsLayoutDecided] 在
  /// 启动期写一次，之后所有解析共用——布局在一次运行里必须恒定。
  static bool? _legacyFlatDocumentsRoot;

  /// 仅供测试：清掉进程内布局判定，让同一测试文件里的多个用例能各自注入不同的
  /// prefs / 老安装痕迹（生产永不调用——布局在一次运行里恒定）。
  @visibleForTesting
  static void debugResetDocumentsLayoutCache() {
    _legacyFlatDocumentsRoot = null;
    _documentsContainerName = null;
  }

  /// 仅供测试：直接注入 nested 容器名锚点（模拟存量 `Hibiki` 安装 / 新装
  /// `Fushi`），跳过 [_ensureDocumentsContainerDecided] 的文件系统探测。
  @visibleForTesting
  static void debugSetDocumentsContainer(String? name) =>
      _documentsContainerName = name;

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
    return _resolveDefaultDocumentsRoot();
  }

  /// BUG-1115：无自定义数据根时的 documents 根。
  ///
  /// 历史上这里直接返回平台 `Documents`，于是 [fushiOwnedDocumentsEntries] 那 16 个目录
  /// 全摊在用户文档根下（TODO-935 E0 收敛十几处 `getApplicationDocumentsDirectory()` 时
  /// 刻意保持零迁移，把「默认根 = 共享用户目录」固化成了常态）。现在默认改为 Hibiki 专属
  /// 容器 `<Documents>/Hibiki/data`；**老安装保持扁平布局不动**（见
  /// [_useLegacyFlatDocumentsRoot]），一个字节都不搬。
  ///
  /// 老用户要收进子目录，走设置里的「数据存储位置」（[DataRootMigrator] 会连 DB 里的绝对
  /// 路径一起 rebase）；这里绝不自动迁移——启动期搬整个书库既慢又可能被文件锁半途打断。
  static Future<Directory> _resolveDefaultDocumentsRoot() async {
    final Directory platformDocuments =
        await getApplicationDocumentsDirectory();
    if (await _useLegacyFlatDocumentsRoot()) return platformDocuments;
    return defaultLocationDocumentsRoot();
  }

  /// BUG-1188：**「默认位置」这个概念本身**的 documents 根 = `<Documents>/Hibiki/data`，
  /// 与本机布局锚点无关。
  ///
  /// [_resolveDefaultDocumentsRoot] 会因老安装锚定 [documentsLayoutFlat] 而返回平台
  /// `Documents`；而「用户在目录选择器里挑的就是默认位置吗」这个判断问的是**全新安装会落
  /// 在哪**，两者在老安装上并不相等。迁移目标解析（`resolveDataRootMigrationTarget`）必须
  /// 用本函数，否则老安装永远解析不出「默认位置」这个目标。
  ///
  /// [hibikiTestDirectory] 测试分支仍优先（与三个 `_resolve*` 的顺序铁律一致）。
  static Future<Directory> defaultLocationDocumentsRoot() async {
    final Directory? test = hibikiTestDirectory('app-documents');
    if (test != null) return test;
    final Directory platformDocuments =
        await getApplicationDocumentsDirectory();
    return Directory(p.joinAll(<String>[
      platformDocuments.path,
      ...defaultDocumentsChildSegments,
    ]));
  }

  /// 本机默认布局是否为历史扁平布局。**纯读取、绝不探测文件系统**（见 [resolve] 里对
  /// FakeAsync 的说明）：本进程已判定 → 用判定值；否则读 prefs 里的锚点；连锚点都没有 →
  /// **扁平老布局**。
  ///
  /// 最后那个兜底是保守的一半：没有判定依据时退回 BUG-1115 之前的行为，绝不擅自把一个
  /// 可能装了满库的机器切到新布局（那会让书库、有声书、词典资源在 UI 上集体消失——文件
  /// 还在、DB 里的绝对路径也还指向旧位置，但静态派生点全去了新目录）。生产上
  /// [AppPaths.resolve] 恒在启动最早期跑完 [_ensureDocumentsLayoutDecided]，所以真正走到
  /// 这个兜底的只有「没跑过 resolve 的测试夹具」。
  static Future<bool> _useLegacyFlatDocumentsRoot() async {
    final bool? decided = _legacyFlatDocumentsRoot;
    if (decided != null) return decided;
    final SharedPreferences? prefs = await _prefsOrNull();
    return prefs?.getString(documentsLayoutPrefKey) != documentsLayoutNested;
  }

  /// 判定 + 固化默认布局。**唯一做探测 IO 的地方**，只由 [resolve] 在启动期调用一次；
  /// 已判定（本进程判过 / prefs 有锚点）就直接沿用，不再探测。
  ///
  /// 判据是 support 根下有没有主库文件（`fushi.db`，兼看旧名 `hibiki.db`）——即
  /// 「这台机器上是否已经有一个跑过的安装」。
  /// 刻意**不**看 Documents 里有没有 `videos` / `browser` / `thumbnails` 这类目录：那些
  /// 名字在用户自己的文档目录里撞名概率不低，全新安装会被误判成老安装、继续摊开。
  /// support 根是平台固定落点（`%APPDATA%\<pkg>`），不随本次改动移动，判据稳定。
  ///
  /// 探测失败 / 超时一律当**老安装**（保守，同 [_useLegacyFlatDocumentsRoot] 的兜底）。
  static Future<void> _ensureDocumentsLayoutDecided() async {
    if (_legacyFlatDocumentsRoot != null) return;
    final SharedPreferences? prefs = await _prefsOrNull();
    await _ensureDocumentsContainerDecided(prefs);
    final String? stored = prefs?.getString(documentsLayoutPrefKey);
    if (stored == documentsLayoutFlat || stored == documentsLayoutNested) {
      _legacyFlatDocumentsRoot = stored == documentsLayoutFlat;
      return;
    }
    final bool flat = await _existingInstallHasDatabase();
    _legacyFlatDocumentsRoot = flat;
    // 固化锚点（best-effort）。写失败只意味着下次启动再探一次，不改变本次结果——而下次
    // 探测的判据（主库文件是否存在）此时只会更成立，不会翻转成新布局。
    try {
      await prefs?.setString(documentsLayoutPrefKey,
          flat ? documentsLayoutFlat : documentsLayoutNested);
    } catch (e) {
      debugPrint('AppPaths: 固化 documents 布局失败（下次启动重新判定）: $e');
    }
  }

  /// Fushi 改名（Phase 3）：判定 + 固化 nested 容器名。锚点已有直接用；没有则
  /// 探测一次：老容器 `<Documents>/Hibiki/data` 存在而新容器不存在 → 存量安装，
  /// 锚 `Hibiki`（目录与 DB 内绝对路径都不动）；否则锚 `Fushi`（新装）。
  /// 探测失败按存量处理（保守——误锚 Fushi 会让存量书库集体消失，反向只是新装
  /// 目录名旧了点）。
  static Future<void> _ensureDocumentsContainerDecided(
      SharedPreferences? prefs) async {
    if (_documentsContainerName != null) return;
    final String? stored = prefs?.getString(documentsContainerPrefKey);
    if (stored == 'Hibiki' || stored == 'Fushi') {
      _documentsContainerName = stored;
      return;
    }
    String decided;
    try {
      final Directory platformDocuments =
          await getApplicationDocumentsDirectory();
      final bool legacyExists =
          await Directory(p.join(platformDocuments.path, 'Hibiki', 'data'))
              .exists()
              .timeout(const Duration(seconds: 2), onTimeout: () => true);
      final bool newExists =
          await Directory(p.join(platformDocuments.path, 'Fushi', 'data'))
              .exists()
              .timeout(const Duration(seconds: 2), onTimeout: () => false);
      decided = (legacyExists && !newExists) ? 'Hibiki' : 'Fushi';
    } catch (_) {
      decided = 'Hibiki';
    }
    _documentsContainerName = decided;
    try {
      await prefs?.setString(documentsContainerPrefKey, decided);
    } catch (e) {
      debugPrint('AppPaths: 固化 documents 容器名失败（下次启动重新判定）: $e');
    }
  }

  /// support 根下是否已有主库文件 = 本机已存在跑过的安装。与 [_probeDataRootExists] 同一
  /// 纪律：**只准异步 `exists()` + 超时**，绝不 `existsSync()`（这条路径同样在启动最早期
  /// 的主 isolate 上跑）。超时/抛错都按「老安装」处理（保守）。
  ///
  /// 兼看旧文件名 [legacyHibikiDatabaseFileName]：老安装在第一次开库前主库还叫
  /// `hibiki.db`（开库时 fushi_core 才做一次性改名），这里若只认新名会把老安装
  /// 误判成全新安装。
  static Future<bool> _existingInstallHasDatabase() async {
    try {
      final Directory support = await _resolveSupportRoot();
      Future<bool> dbExists(String fileName) =>
          File(p.join(support.path, fileName))
              .exists()
              .timeout(const Duration(seconds: 2), onTimeout: () => true);
      return await dbExists(fushiDatabaseFileName) ||
          await dbExists(legacyHibikiDatabaseFileName);
    } catch (_) {
      return true;
    }
  }

  /// SharedPreferences 实例；平台通道不可用（纯 Dart 单测 / 极端启动早期）返回 null。
  static Future<SharedPreferences?> _prefsOrNull() async {
    try {
      return await SharedPreferences.getInstance();
    } catch (_) {
      return null;
    }
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
  /// **老安装（[documentsLayoutFlat]）** 的 documents 根 = 整个用户 `Documents`（共享目录，含
  /// 用户自己的文件和 shell junction）。迁移引擎对共享根**只搬这份白名单里的顶层项**，
  /// 绝不整树搬移 / 整树删除用户 `Documents`。BUG-1115 之后新装走
  /// `<Documents>/Hibiki/data`（Hibiki 专属根，迁移走整树语义），白名单对它不生效——但
  /// 老安装可能永远停在扁平布局，故白名单及其守卫**长期有效**，新增
  /// `<documents>/<child>` 派生点仍必须收进来。每一项都必须对应仓库里一个真实的派生点：
  ///
  ///  - `audiobooks` —— [audiobooksDirectory]；`AppModel` 各处
  ///    `join(appDirectory, 'audiobooks')`；`AudiobookStorage.ensurePersistDir`。
  ///  - `fushi_books` —— [epubBooksDirectory]；`EpubStorage`；backup restore。
  ///  - `hoshi_books` —— 上一条的存量旧名。启动就地改名 `fushi_books`
  ///    （W2-7，`books_directory.dart`），改名失败留在旧名时数据根搬迁必须
  ///    继续认它。无派生点是有意的（同 `hibikiExport` 条目）。
  ///  - `video_covers` —— [videoCoversDirectory]；`VideoStorage.coversDirName`。
  ///  - `game_covers` —— [gameCoversDirectory]；游戏库封面（手选 + 自动获取）。
  ///  - `video_subtitles` —— [videoSubtitlesDirectory]；`VideoStorage.subtitlesDirName`。
  ///  - `mpv_shaders` —— [mpvShadersDirectory]。
  ///  - `remote_videos` —— [remoteVideosDirectory]。
  ///  - `videos` —— backup restore 的视频落点（`backup.part.dart`
  ///    `join(appDirectory, 'videos')`）。
  ///  - `custom_fonts` —— 字体导入/加载（`custom_fonts_page.dart` 等
  ///    `join(appDirectory, 'custom_fonts')`）。
  ///  - `fushiExport` —— `AppModel.prepareExportDirectory`（`export_directory.dart`）。
  ///  - `hibikiExport` —— 上一条的存量旧名。启动准备目录时就地改名 `fushiExport`
  ///    （W2-4），但改名可能因句柄占用等失败而留在旧名——数据根搬迁必须继续认它，
  ///    否则旧目录会被留在旧位置（数据分家）。无派生点是有意的（守卫单向：派生点
  ///    必须进白名单，白名单允许含仅存量的旧名）。
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
  static const Set<String> fushiOwnedDocumentsEntries = <String>{
    'audiobooks',
    'fushi_books',
    'hoshi_books',
    'video_covers',
    'game_covers',
    'video_subtitles',
    'mpv_shaders',
    'remote_videos',
    'videos',
    'anime_downloads',
    'custom_fonts',
    'fushiExport',
    'hibikiExport',
    'browser',
    'thumbnails',
    'dictionaryResources',
    'dictionaryImportWorkingDirectory',
    'webArchive',
  };

  /// BUG-1115：[newDataRoot] 落在**共享** documents 根（老安装的扁平布局 = 平台
  /// `Documents`）内部时，它是否是一个安全的迁移目标。
  ///
  /// 一般规则是「新数据根不能位于旧数据目录内部」（自我嵌套 → 边搬边把目标搬进自己）。
  /// 但共享根是个例外：那里的迁移是**白名单选择性搬移**——只有
  /// [fushiOwnedDocumentsEntries] 里的顶层项会被搬走，别的顶层项一律不碰。所以只要新根
  /// 的顶层段不是白名单里的名字，它在搬移中就是个旁观者，`Documents\Hibiki` 这种「把散
  /// 落的 16 个目录收进一个自己的子目录」的迁移是安全的，不该被一刀切拒绝。
  ///
  /// 顶层段比较**大小写不敏感**：`p.canonicalize` 在 Windows 上会把路径转小写，直接与
  /// 白名单原样比对会让 `Documents\hibikiExport` 漏网（它其实是白名单项，会被搬走 →
  /// 目标边搬边消失）。小写比较在 Linux 上只会更保守（多拒绝几个），不会放行危险目标。
  /// [ownedEntries] 是本次搬移真正生效的白名单（引擎传
  /// `DataRootMigrationRequest.documentsTopLevelIncludeNames`，UI 传默认全集）——判定必须
  /// 与实际会被搬走的顶层项同源，否则两边对「哪些名字会消失」的认知会漂开。
  static bool isSafeNestedTargetInSharedDocuments({
    required String sharedDocumentsRoot,
    required String newDataRoot,
    Set<String> ownedEntries = fushiOwnedDocumentsEntries,
  }) {
    final String canonRoot = p.canonicalize(sharedDocumentsRoot);
    final String canonNew = p.canonicalize(newDataRoot);
    if (!p.isWithin(canonRoot, canonNew)) return false;
    final String firstSegment =
        p.split(p.relative(canonNew, from: canonRoot)).first.toLowerCase();
    return !ownedEntries
        .any((String owned) => owned.toLowerCase() == firstSegment);
  }

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

  /// EPUB 解压正文根 `<documents>/fushi_books`。
  static Future<Directory> epubBooksDirectory() =>
      documentsSubdirectory('fushi_books');

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
