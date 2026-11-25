import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:fushi_core/fushi_core.dart'
    show fushiDatabaseFileName, legacyHibikiDatabaseFileName;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fushi/src/diagnostics/previous_exit_log.dart'
    show activityNameFromBreadcrumbFileName;
import 'package:fushi/src/startup/test_environment.dart';
import 'package:fushi/src/storage/android_library_db_witness.dart';
import 'package:fushi/src/storage/directory_move.dart'
    show kDirectoryCopyPartSuffix, moveDirectoryMerging;
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
///     Fushi 专属容器 `<Documents>/Fushi/data`（存量 nested 安装仍是 `Hibiki/data`）；
///     **老安装**仍锚定历史扁平布局
///     `<Documents>` 本身（见 [_resolveDefaultDocumentsRoot]）。
///   - [supportRoot] —— 数据库根（`getApplicationSupportDirectory`，
///     Windows = `%APPDATA%\<pkg>`）。`fushi.db` 与 per-source local-audio DB 落这里。
///   - [tempRoot] —— 可丢弃的临时目录（`getTemporaryDirectory`）。
///
/// **E0 是纯收敛、行为等价**：解析逻辑（先 [fushiTestDirectory] 测试分支，否则
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
    // Android：书库根内部 / 外部的判定（新装外部、老安装内部），外部时解析外部目录。
    await _ensureAndroidDocumentsLocationDecided();
    // 拍板台 nLXhu0d7gV：iOS 的 Documents 改作「文件」App 可见的导入收件箱，书库搬出去。
    // 必须在解析根之前跑完：搬完之后 [_resolveDocumentsRoot] 解析出的新根才有数据，
    // 紧随其后的 `SandboxRelocation.reconcile` 按台账把库里的绝对路径重基过去。
    await _ensureIosSharedDocumentsVacated();
    final Directory documents = await _resolveDocumentsRoot();
    final Directory support = await _resolveSupportRoot();
    final Directory temp = await _resolveTempRoot();
    await _ensureResolvedRootsExist(documents, support);
    return AppPaths._(
      documentsRoot: documents,
      supportRoot: support,
      tempRoot: temp,
    );
  }

  /// BUG-1899：启动期确保两个根**目录真实存在**。
  ///
  /// 默认分支天然满足这个契约：`getApplicationSupportDirectory()` 内部就
  /// `create(recursive: true)`，平台 `Documents` 更是一定在。而 dataRoot 分支
  /// （[rootsForDataRoot] 派生的 `<dataRoot>/documents` 与 `<dataRoot>/support`）
  /// **只是纯路径拼接**——安装向导的首启引导只 `create` 了 dataRoot 本身
  /// （`installer_data_root_bootstrap.dart`），两个子目录从来没人建。
  ///
  /// 后果：sqlite 打开 `<dataRoot>/support/fushi.db` 拿到 SQLITE_CANTOPEN(14)，
  /// 被恢复阶梯当成「侧车/损坏」，用户看到「Database damaged」并被引导去恢复备份或
  /// 清空数据——而磁盘上什么都没坏，只是少一个空目录。设置页换位置那条路不受影响，
  /// 因为 `DataRootMigrator` 搬文件时顺手把目录建了；只有「安装向导选自定义位置 →
  /// 首启」这一条路会踩。
  ///
  /// 修的是**两条分支的契约不一致**，不是给 DB 打补丁：`resolve()` 承诺返回可用的根，
  /// 就必须两条分支都可用。
  ///
  /// 只在 `resolve()` 里做，**绝不下沉进 `_resolve*Root()`**——那三个函数会被运行时的
  /// 静态便捷层高频调用，其中包括 widget 测试里的封面/资源解析；`testWidgets` 跑在
  /// FakeAsync 上，真实文件 IO 的 future 在那里永不完成（同 `_ensureDocumentsLayoutDecided`
  /// 的理由）。
  static Future<void> _ensureResolvedRootsExist(
    Directory documents,
    Directory support,
  ) async {
    for (final Directory dir in <Directory>[documents, support]) {
      try {
        if (await dir.exists()) continue;
        await dir.create(recursive: true);
      } on FileSystemException {
        // 建不出来 = 这个位置真的不可用（无权限 / 只读介质 / 盘断链）。这与「配置的
        // 数据位置不可达」是同一件事，走同一个可操作的逃生屏（重试 / 本次用默认位置），
        // 而不是让它继续走到 DB 层被误报成「数据库损坏」。
        throw DataRootUnavailableException(configuredPath: dir.path);
      }
    }
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
  static const String dataRootDocumentsChild = 'documents';

  /// `<dataRoot>` 下「数据库/支持」子目录名。
  static const String dataRootSupportChild = 'support';

  /// BUG-1115：**默认** documents 根的布局键（SharedPreferences，与 [dataRootPrefKey]
  /// 同一通道，DB 打开前可读）。值只有两个：[documentsLayoutFlat] /
  /// [documentsLayoutNested]。
  ///
  /// 一经写入就是本机的**永久锚点**，不再重新探测：布局若随「Documents 里此刻有没有某个
  /// 目录」漂移，同一台机器两次启动就可能解析出两个不同的内容根 = 用户书库凭空消失。
  static const String documentsLayoutPrefKey = 'documents_layout';

  /// 历史扁平布局：documents 根 = 平台 `Documents` **本身**，16 个 Fushi 子目录直接摊在
  /// 用户文档根下。老安装锚定于此（零迁移，见 [_resolveDefaultDocumentsRoot]）。
  static const String documentsLayoutFlat = 'flat';

  /// 当前默认布局：documents 根 = `<Documents>/Fushi/data`（Fushi 专属容器；存量 nested
  /// 安装的容器名仍是 `Hibiki`，见 [documentsContainerPrefKey]）。
  ///
  /// BUG-1188：迁移把数据归一化到默认位置时，提交阶段必须把这个锚点写成本值——否则下次
  /// 启动仍按 `flat` 把 documents 根解析回共享 `Documents`，而数据已经在 `<容器>/data` 里。
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

  /// nested 容器名：新装 / 已迁移。
  static const String documentsContainerFushi = 'Fushi';

  /// nested 容器名：改名前的存量安装（目录冻结不改）。
  static const String documentsContainerHibiki = 'Hibiki';

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

  // ---- Android：书库根放内部私有目录还是外部 app 专属目录 ----

  /// Android 书库根（documents 根）位置锚点的**旧版** SharedPreferences 键。值
  /// [androidDocumentsLocationInternal] / [androidDocumentsLocationExternal]。
  ///
  /// 现在锚点存在 support 根下的 [androidLibraryAnchorFileName]，这个键只在锚点文件
  /// 还不存在时当种子读一次、不再写。原因（反馈 RCv76PPoiJ）：app 有 `:popup`、
  /// `:second_screen` 等独立进程，每个进程各持一份 SharedPreferences 内存副本，任一
  /// 进程写任何键都会把**整份**副本落盘——长驻的弹窗进程带着迁移前的旧值一写，就把
  /// 主进程刚提交的「外部」锚点冲回去，下次冷启动书库根判回空的内部目录。
  ///
  /// - 外部 = `getExternalFilesDir(null)/data`（`Android/data/<包名>/files/data`）：
  ///   USB / 电脑能直接拿到有声书、下载、字幕与转录结果；不需要任何存储权限，卸载时随
  ///   app 一起删除。**全新安装默认外部**。
  /// - 内部 = `app_flutter` 下的旧布局（flat 或 nested）。**升级上来的老安装锚定内部**、
  ///   一个字节都不自动搬：内部到外部跨挂载点，只能逐文件复制，GB 级书库在启动期悄悄搬
  ///   会卡死启动画面。老用户由首页一次性提示（或设置「数据存储位置」）走带进度的
  ///   `DataRootMigrator` 迁移，迁完提交本锚点。
  ///
  /// 数据库（support 根）两种情况下都留在内部 `filesDir`，不随本锚点移动。
  static const String androidDocumentsLocationPrefKey =
      'android_documents_location';
  static const String androidDocumentsLocationInternal = 'internal';
  static const String androidDocumentsLocationExternal = 'external';

  /// 老安装「把书库移到可访问文件夹」一次性提示已处理（弹过 / 已迁移）的标记。
  static const String androidDocumentsMovePromptedPrefKey =
      'android_documents_move_prompted';

  /// 外部 app 专属目录下书库根的子目录名。不直接用 `files/` 本身：`files/logs`（诊断）、
  /// `files/video_clips`（导出剪辑）、`files/Download`（浏览器下载兜底）与书库并列，
  /// 迁移引擎整树搬书库根时不会把它们卷进去。
  static const String androidExternalDocumentsChild = 'data';

  /// 本进程已判定的 Android 书库位置；[_ensureAndroidDocumentsLocationDecided] 启动期写一次。
  static String? _androidDocumentsLocation;

  /// 启动期解析到的 `getExternalFilesDir(null)`（null：没解析过或外部存储未挂载）。
  static Directory? _androidExternalFilesDir;

  /// 仅供测试：注入 / 清掉进程内的 Android 书库位置判定与外部目录。
  @visibleForTesting
  static void debugSetAndroidDocumentsLocation(
    String? location, {
    Directory? externalFilesDir,
  }) {
    _androidDocumentsLocation = location;
    _androidExternalFilesDir = externalFilesDir;
  }

  /// 纯判定（测试钉住）：已有合法锚点就沿用；否则按「本机是否已有跑过的安装」决定——
  /// 老安装 = 内部（不自动搬），全新安装 = 外部。
  static String decideAndroidDocumentsLocation({
    required String? stored,
    required bool existingInstall,
  }) {
    if (stored == androidDocumentsLocationInternal ||
        stored == androidDocumentsLocationExternal) {
      return stored!;
    }
    return existingInstall
        ? androidDocumentsLocationInternal
        : androidDocumentsLocationExternal;
  }

  /// 外部书库根的展示串（外部存储不可用、拿不到真实路径时给逃生屏用）。
  static String get _androidExternalDocumentsLabel =>
      p.join('Android', 'data', '…', 'files', androidExternalDocumentsChild);

  /// 判定 + 固化 Android 书库位置，外部时顺带解析外部目录。只由 [resolve] 调用一次。
  ///
  /// 锚点读写走 support 根下的 [androidLibraryAnchorFileName]（见
  /// [AndroidLibraryAnchor]），旧版写在 SharedPreferences 的值只在文件还不存在时
  /// 当种子读一次。判定之后再让磁盘作证（[reconcileAndroidDocumentsLocation]）：锚定
  /// 的根里一个书库文件都没有、另一个根里有，就说明锚点错了，以磁盘为准并改正锚点。
  ///
  /// 外部锚定但外部存储本次不可用（`getExternalFilesDir` 返回 null）时抛
  /// [DataRootUnavailableException]——与桌面自定义根不可达同一铁律：绝不静默派生空的
  /// 内部根，让用户看成「书库被清空」。
  static Future<void> _ensureAndroidDocumentsLocationDecided() async {
    if (!Platform.isAndroid) return;
    if (fushiTestDirectory('app-documents') != null) return;
    if (_androidDocumentsLocation == null) {
      final Directory support = await _resolveSupportRoot();
      final AndroidLibraryAnchor? anchor = await readAndroidLibraryAnchor(
        support,
      );
      // 内部书库的布局（flat / nested）与容器名（Fushi / Hibiki）同样以锚点文件为准：
      // 它们在 SharedPreferences 里的那份会被别的进程的旧副本整份冲掉（RCv76PPoiJ），
      // 冲掉后布局判定会因为主库存在而回落成 flat，书库根就指到 `app_flutter` 本身。
      final String? anchoredLayout = anchor?.layout;
      if (anchoredLayout != null) {
        _legacyFlatDocumentsRoot = anchoredLayout == documentsLayoutFlat;
      }
      final String? anchoredContainer = anchor?.container;
      if (anchoredContainer != null) {
        _documentsContainerName = anchoredContainer;
      }
      final String? stored =
          anchor?.location ??
          (await _prefsOrNull())?.getString(androidDocumentsLocationPrefKey);
      final String decided = decideAndroidDocumentsLocation(
        stored: stored,
        existingInstall: stored != null || await existingInstallHasDatabase(),
      );
      _androidExternalFilesDir = await getExternalStorageDirectory();
      final Directory? ext = _androidExternalFilesDir;
      final List<AndroidInternalLibraryCandidate> candidates =
          androidInternalLibraryCandidates(
            platformDocuments: await getApplicationDocumentsDirectory(),
            configuredLayout: await _useLegacyFlatDocumentsRoot()
                ? documentsLayoutFlat
                : documentsLayoutNested,
            configuredContainer: defaultDocumentsChildSegments.first,
          );
      final AndroidLibraryReconciliation result =
          await reconcileAndroidLibraryRoots(
            anchored: decided,
            external: ext == null
                ? null
                : Directory(p.join(ext.path, androidExternalDocumentsChild)),
            internalCandidates: candidates,
            supportRoot: support,
          );
      androidLocationCorrections.addAll(result.notes);
      androidStrayLibraryRoot = result.strayRoot;
      _androidDocumentsLocation = result.location;
      final AndroidInternalLibraryCandidate chosen = result.internal;
      _legacyFlatDocumentsRoot = chosen.layout == documentsLayoutFlat;
      _documentsContainerName = chosen.container;
      final AndroidLibraryAnchor settled = AndroidLibraryAnchor(
        location: result.location,
        layout: chosen.layout,
        container: chosen.container,
      );
      if (anchor != settled) {
        try {
          await writeAndroidLibraryAnchor(support, settled);
        } catch (e) {
          // 写失败只意味着下次启动再判一次（判据与磁盘对账都是确定的）。
          debugPrint('AppPaths: 固化 Android 书库位置失败（下次启动重新判定）: $e');
        }
      }
      if (!identical(chosen, candidates.first)) {
        // 对账改了内部布局 / 容器：prefs 里那份也跟上，免得不经锚点的读者（布局判定
        // 的兜底、桌面共用的 helper）读到旧值。尽力而为，真相源是锚点文件。
        try {
          final SharedPreferences? prefs = await _prefsOrNull();
          await prefs?.setString(documentsLayoutPrefKey, chosen.layout);
          await prefs?.setString(documentsContainerPrefKey, chosen.container);
        } catch (e) {
          debugPrint('AppPaths: 同步纠正后的布局 / 容器到 prefs 失败: $e');
        }
      }
    }
    if (_androidDocumentsLocation != androidDocumentsLocationExternal) return;
    _androidExternalFilesDir ??= await getExternalStorageDirectory();
    if (_androidExternalFilesDir == null) {
      throw DataRootUnavailableException(
        configuredPath: _androidExternalDocumentsLabel,
      );
    }
  }

  /// 内部书库根的所有候选，**第一个是当前配置**（布局锚点 + 容器锚点推出来的那个），
  /// 其后是另外几种历史布局：flat（`app_flutter` 本身）、nested `Fushi/data`、nested
  /// `Hibiki/data`，按根路径去重。
  ///
  /// 布局 / 容器锚点丢过的安装（多进程冲掉 prefs，见 [_ensureAndroidDocumentsLocationDecided]），
  /// 「当前配置」指的是一个空目录，真书库在另一种布局下；对账只看当前配置就永远认定
  /// 「内部没有书库」、不会自愈（#4366 指出，3.4.0-debug.32552 用户复现）。
  static List<AndroidInternalLibraryCandidate>
  androidInternalLibraryCandidates({
    required Directory platformDocuments,
    required String configuredLayout,
    required String configuredContainer,
  }) {
    AndroidInternalLibraryCandidate candidate(
      String layout,
      String container,
    ) => AndroidInternalLibraryCandidate(
      layout: layout,
      container: container,
      root: layout == documentsLayoutFlat
          ? platformDocuments
          : Directory(p.join(platformDocuments.path, container, 'data')),
    );
    final List<AndroidInternalLibraryCandidate> all =
        <AndroidInternalLibraryCandidate>[
          candidate(configuredLayout, configuredContainer),
          candidate(documentsLayoutFlat, configuredContainer),
          candidate(documentsLayoutNested, documentsContainerFushi),
          candidate(documentsLayoutNested, documentsContainerHibiki),
        ];
    final Set<String> seen = <String>{};
    return <AndroidInternalLibraryCandidate>[
      for (final AndroidInternalLibraryCandidate c in all)
        if (seen.add(p.normalize(c.root.path))) c,
    ];
  }

  /// Android 书库位置锚点与磁盘对账（启动期，[_ensureAndroidDocumentsLocationDecided]）。
  ///
  /// [internalCandidates] 第一个是当前配置的内部根（[androidInternalLibraryCandidates]）。
  /// [external] 为 null（外部存储不可用）时不对账（无从比较），原样沿用。
  ///
  ///  - 锚定的根里有书库文件：与对面（外部 ↔ 当前配置的内部根）比，规则见
  ///    [reconcileAndroidDocumentsLocation]；两边都有时让主库作证，落选的根交给散书合并。
  ///  - 锚定的根里**没有**：按顺序探对面与另外几种内部布局，第一个有书库文件的胜出，
  ///    位置、布局、容器一起改正；全都没有就沿用锚点。两种情况都把每个根的探测结论写进
  ///    [AndroidLibraryReconciliation.notes]，反馈日志里能看出书库到底在不在磁盘上。
  static Future<AndroidLibraryReconciliation> reconcileAndroidLibraryRoots({
    required String anchored,
    required Directory? external,
    required List<AndroidInternalLibraryCandidate> internalCandidates,
    required Directory supportRoot,
  }) async {
    final AndroidInternalLibraryCandidate configured = internalCandidates.first;
    if (external == null) {
      return AndroidLibraryReconciliation(
        location: anchored,
        internal: configured,
      );
    }
    final bool anchoredExternal = anchored == androidDocumentsLocationExternal;
    final Directory anchoredRoot = anchoredExternal
        ? external
        : configured.root;
    final LibraryProbe anchoredProbe = await probeLibraryFiles(anchoredRoot);
    if (anchoredProbe == LibraryProbe.found ||
        anchoredProbe == LibraryProbe.unknown) {
      // 探不清锚定的根时按「有书」处理（保守：不因一次 IO 抖动离开它）。
      final Directory otherRoot = anchoredExternal ? configured.root : external;
      final bool otherHasLibrary =
          await probeLibraryFiles(otherRoot) == LibraryProbe.found;
      if (!otherHasLibrary) {
        return AndroidLibraryReconciliation(
          location: anchored,
          internal: configured,
        );
      }
      final AndroidLibraryDbWitness? witness =
          await AndroidLibraryDbWitness.probe(
            supportRoot: supportRoot,
            anchoredRoot: anchoredRoot,
            otherRoot: otherRoot,
          );
      final String location = reconcileAndroidDocumentsLocation(
        anchored: anchored,
        anchoredHasLibrary: true,
        otherHasLibrary: true,
        dbWitness: witness,
      );
      final bool switched = location != anchored;
      return AndroidLibraryReconciliation(
        location: location,
        internal: configured,
        notes: <String>[
          '两个书库根都有书库文件（锚定 $anchored：${anchoredRoot.path}；另一个：'
              '${otherRoot.path}），主库作证 ${witness ?? '无（主库读不到）'} → '
              '${switched ? '改为' : '沿用'} $location',
        ],
        // 只有主库作过证才去合并：读不到主库时谁对谁错没有依据，宁可原样不动。
        strayRoot: witness == null
            ? null
            : (switched ? anchoredRoot : otherRoot),
      );
    }

    // 锚定的根是空的：依次探对面与其余内部布局。
    final List<(String, AndroidInternalLibraryCandidate, Directory)> others =
        <(String, AndroidInternalLibraryCandidate, Directory)>[
          if (!anchoredExternal)
            (androidDocumentsLocationExternal, configured, external),
          for (final AndroidInternalLibraryCandidate c in internalCandidates)
            if (anchoredExternal || !identical(c, configured))
              (androidDocumentsLocationInternal, c, c.root),
        ];
    final List<String> probes = <String>[];
    for (final (
          String location,
          AndroidInternalLibraryCandidate c,
          Directory root,
        )
        in others) {
      final LibraryProbe probe = await probeLibraryFiles(root);
      probes.add('${root.path}=${probe.name}');
      if (probe != LibraryProbe.found) continue;
      return AndroidLibraryReconciliation(
        location: location,
        internal: c,
        notes: <String>[
          '锚点 $anchored 指向的书库根 ${anchoredRoot.path} 里没有书库文件，'
              '$root 里有 → 改为 $location'
              '${location == androidDocumentsLocationInternal ? '（布局 ${c.layout}，容器 ${c.container}）' : ''}'
              '；探测：${probes.join('，')}',
        ],
      );
    }
    return AndroidLibraryReconciliation(
      location: anchored,
      internal: configured,
      notes: <String>[
        '锚点 $anchored 指向的书库根 ${anchoredRoot.path} 里没有书库文件，'
            '其余候选也都没有 → 沿用；探测：${probes.join('，')}',
      ],
    );
  }

  /// 纯判定（测试钉住）：
  ///  - 另一个根里没有书库文件 → 沿用锚点（常态，以及两边都空的全新安装）；
  ///  - 锚定的根里没有、另一个根里有 → 书库实际在另一个根，锚点是错的（反馈
  ///    RCv76PPoiJ：锚点被旧进程副本冲掉，判回空的内部根）；
  ///  - 两边都有：让主库作证（[dbWitness]，拍板台 review-library-anchor-both-roots）。
  ///    主库里的书「只在另一个根存在」的严格多于「只在锚定的根存在」的 → 改到另一个根；
  ///    平局（迁移中断，两边是同一批文件）或没有证据 → 沿用锚点。
  static String reconcileAndroidDocumentsLocation({
    required String anchored,
    required bool anchoredHasLibrary,
    required bool otherHasLibrary,
    AndroidLibraryDbWitness? dbWitness,
  }) {
    if (!otherHasLibrary) return anchored;
    final String other = anchored == androidDocumentsLocationExternal
        ? androidDocumentsLocationInternal
        : androidDocumentsLocationExternal;
    if (!anchoredHasLibrary) return other;
    return (dbWitness?.favorsOther ?? false) ? other : anchored;
  }

  /// 本进程启动期判定时两个根都有书库文件、经主库作证后**落选**的那个根；开库后
  /// `AndroidStrayLibraryMerge` 把散在那里的书并进书库根。null：只有一个根有书（常态）。
  static Directory? androidStrayLibraryRoot;

  /// 书库证据里不算数的顶层项：app 每次冷启动自己就会往里放东西（导出目录的
  /// `.nomedia`）或只放过程性临时物，与「书库在不在这个根」无关。#4366 指出：已中招
  /// 的安装（书库在内部、锚点指向外部）外部根里恰好只有冷启动建出的
  /// `fushiExport/.nomedia`，把它当书库就会让对账认定「锚定的根有书」、永远不自愈。
  static const Set<String> libraryEvidenceIgnoredEntries = <String>{
    'fushiExport',
    'hibikiExport',
    'dictionaryImportWorkingDirectory',
    'recommended_pack',
    'onboarding_tutorial',
  };

  /// 不算书库证据的文件名：`.nomedia` 是排除媒体扫描的占位（0 字节），任何目录都可能被
  /// 顺手放一个；`*.fushi-part` 是中断的跨盘复制留下的半截临时文件，不是书。
  static bool isLibraryEvidenceFileName(String name) =>
      name != '.nomedia' && !name.endsWith(kDirectoryCopyPartSuffix);

  /// [root] 下 Fushi 自有顶层项（[fushiOwnedDocumentsEntries]，去掉
  /// [libraryEvidenceIgnoredEntries]）里是否至少有一个书库**文件**。只认文件不认目录：
  /// 启动期会顺手建出空的派生目录，那不是书库；`.nomedia` 占位也不算。
  /// 遇到第一个文件就停；探不清（出错且没找到文件 / 超时）返回 [onTimeout]（调用方按
  /// 保守方向给）。
  static Future<bool> hasLibraryFiles(
    Directory root, {
    required bool onTimeout,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    switch (await probeLibraryFiles(root, timeout: timeout)) {
      case LibraryProbe.found:
        return true;
      case LibraryProbe.none:
        return false;
      case LibraryProbe.unknown:
        return onTimeout;
    }
  }

  /// [hasLibraryFiles] 的三态版本。逐个目录列举、各自容错：某个子目录列不出来（权限、
  /// 遍历中被删、坏链接）只记一笔，不中断其余目录——旧实现一处出错就整体判「没有书库」，
  /// 别的目录里明明有书也看不见。没找到文件但途中出过错 → [LibraryProbe.unknown]。
  static Future<LibraryProbe> probeLibraryFiles(
    Directory root, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    Future<LibraryProbe> probe() async {
      bool errored = false;
      for (final String name in fushiOwnedDocumentsEntries) {
        if (libraryEvidenceIgnoredEntries.contains(name)) continue;
        final List<Directory> pending = <Directory>[
          Directory(p.join(root.path, name)),
        ];
        while (pending.isNotEmpty) {
          final Directory dir = pending.removeLast();
          try {
            if (!await dir.exists()) continue;
            await for (final FileSystemEntity e in dir.list(
              followLinks: false,
            )) {
              if (e is Directory) {
                pending.add(e);
              } else if (e is File &&
                  isLibraryEvidenceFileName(p.basename(e.path))) {
                return LibraryProbe.found;
              }
            }
          } catch (_) {
            errored = true;
          }
        }
      }
      return errored ? LibraryProbe.unknown : LibraryProbe.none;
    }

    try {
      return await probe().timeout(
        timeout,
        onTimeout: () => LibraryProbe.unknown,
      );
    } catch (_) {
      return LibraryProbe.unknown;
    }
  }

  /// Android 书库迁移前，固定目标 [target] 里第一个「[source] 里没有同名相对路径」的
  /// 文件（相对 [target]）；没有返回 null。
  ///
  /// 目标是固定位置，上次中断的跨盘复制会留下半成品，必须先清掉引擎才肯搬。半成品一定
  /// 是源的子集（复制阶段不删源）；目标里出现源里没有的文件，就说明它**不是**半成品
  /// ——典型是锚点错指空根时，用户点「移回内部」，目标恰好就是真正的书库（#4366 指出）。
  /// 这时绝不能整树删除。`.nomedia` 占位不计。
  static Future<String?> firstAndroidMigrationTargetOnlyFile({
    required Directory target,
    required Directory source,
  }) async {
    if (!await target.exists()) return null;
    await for (final FileSystemEntity e in target.list(
      recursive: true,
      followLinks: false,
    )) {
      if (e is! File) continue;
      if (!isLibraryEvidenceFileName(p.basename(e.path))) continue;
      final String rel = p.relative(e.path, from: target.path);
      if (!await File(p.join(source.path, rel)).exists()) return rel;
    }
    return null;
  }

  /// 本进程启动期对 Android 书库位置做过的纠正（AppModel 写进诊断日志）。
  static final List<String> androidLocationCorrections = <String>[];

  // ---- Android 书库位置锚点文件 ----

  /// support 根（Android `filesDir`）下的锚点文件名。
  static const String androidLibraryAnchorFileName =
      'android_library_location.json';

  /// 读锚点文件；不存在 / 损坏返回 null（按旧版 prefs 种子与安装状态重判）。
  static Future<AndroidLibraryAnchor?> readAndroidLibraryAnchor(
    Directory support,
  ) async {
    try {
      final File f = File(p.join(support.path, androidLibraryAnchorFileName));
      if (!await f.exists()) return null;
      return AndroidLibraryAnchor.tryParse(await f.readAsString());
    } catch (_) {
      return null;
    }
  }

  /// 原子写锚点文件：先写本进程独占的临时文件再 rename，别的进程要么读到旧值要么读到
  /// 新值，读不到半截。
  static Future<void> writeAndroidLibraryAnchor(
    Directory support,
    AndroidLibraryAnchor anchor,
  ) async {
    final File target = File(
      p.join(support.path, androidLibraryAnchorFileName),
    );
    final File tmp = File('${target.path}.$pid.tmp');
    await tmp.writeAsString(anchor.encode(), flush: true);
    await tmp.rename(target.path);
  }

  /// 书库迁移提交时写锚点（Android 位置迁移的唯一提交点）。返回写之前的锚点，供提交
  /// 失败时 [restoreAndroidLibraryAnchor] 原样写回。
  static Future<AndroidLibraryAnchor?> commitAndroidLibraryAnchor(
    AndroidLibraryAnchor anchor,
  ) async {
    final Directory support = await _resolveSupportRoot();
    final AndroidLibraryAnchor? previous = await readAndroidLibraryAnchor(
      support,
    );
    await writeAndroidLibraryAnchor(support, anchor);
    return previous;
  }

  /// 把锚点文件恢复成 [previous]（null = 删掉，回到「按旧 prefs 种子判定」）。
  static Future<void> restoreAndroidLibraryAnchor(
    AndroidLibraryAnchor? previous,
  ) async {
    final Directory support = await _resolveSupportRoot();
    if (previous != null) {
      await writeAndroidLibraryAnchor(support, previous);
      return;
    }
    final File f = File(p.join(support.path, androidLibraryAnchorFileName));
    if (await f.exists()) await f.delete();
  }

  /// 本机 Android 书库是否在外部 app 专属目录。**纯读取、绝不探测文件系统**（理由同
  /// [_useLegacyFlatDocumentsRoot]）：本进程已判定 → 用判定值；否则读锚点；没有锚点 →
  /// 内部（保守：没跑过 [resolve] 的夹具不会被切到一个空的外部根）。
  static Future<bool> androidDocumentsAreExternal() async {
    if (!Platform.isAndroid) return false;
    final String? decided = _androidDocumentsLocation;
    if (decided != null) return decided == androidDocumentsLocationExternal;
    final SharedPreferences? prefs = await _prefsOrNull();
    return prefs?.getString(androidDocumentsLocationPrefKey) ==
        androidDocumentsLocationExternal;
  }

  /// `getExternalFilesDir(null)`（`Android/data/<包名>/files`）；外部存储不可用时 null。
  /// 启动期已解析过就复用，不再走平台通道。
  static Future<Directory?> androidExternalFilesDirectory() async =>
      _androidExternalFilesDir ??= await getExternalStorageDirectory();

  /// Android 外部书库根 `Android/data/<包名>/files/data`（不创建）。外部存储不可用时抛
  /// [DataRootUnavailableException]。
  static Future<Directory> androidExternalDocumentsRoot() async {
    final Directory? ext = await androidExternalFilesDirectory();
    if (ext == null) {
      throw DataRootUnavailableException(
        configuredPath: _androidExternalDocumentsLabel,
      );
    }
    return Directory(p.join(ext.path, androidExternalDocumentsChild));
  }

  /// Android 内部书库根（迁回内部时的目标）= `app_flutter/<容器>/data`（nested 布局）。
  /// 迁回时一律落 nested，提交时把布局锚点一起锚成 nested：老 flat 安装迁出再迁回也不会
  /// 摊回 `app_flutter` 根。
  static Future<Directory> androidInternalDocumentsRoot() async {
    final Directory platformDocuments =
        await getApplicationDocumentsDirectory();
    return Directory(
      p.joinAll(<String>[
        platformDocuments.path,
        ...defaultDocumentsChildSegments,
      ]),
    );
  }

  /// 用户导出物（视频剪辑等）的基目录：Android 落外部 app 专属目录（USB / 电脑可见），
  /// 外部存储不可用时退回 `app_flutter`；其它平台保持 `getApplicationDocumentsDirectory()`
  /// （iOS 那就是「文件」App 可见的 Documents）。
  static Future<Directory> userExportsBaseDirectory() async {
    if (Platform.isAndroid) {
      final Directory? ext = await androidExternalFilesDirectory();
      if (ext != null) return ext;
    }
    return getApplicationDocumentsDirectory();
  }

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
          raw =
              await MacOSDataRootAccess.startAccessingStoredBookmark(prefs) ??
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
      return await dir.exists().timeout(
        const Duration(seconds: 2),
        onTimeout: () => false,
      );
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
  /// **顺序铁律**：[fushiTestDirectory] 测试分支在三个 `_resolve*` 里**优先于**本覆盖
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
    final Directory? test = fushiTestDirectory('app-documents');
    if (test != null) return test;
    final Directory? dataRoot = await _resolveDataRoot();
    if (dataRoot != null) {
      return Directory(p.join(dataRoot.path, dataRootDocumentsChild));
    }
    return _resolveDefaultDocumentsRoot();
  }

  /// BUG-1115：无自定义数据根时的 documents 根。
  ///
  /// 历史上这里直接返回平台 `Documents`，于是 [fushiOwnedDocumentsEntries] 那 16 个目录
  /// 全摊在用户文档根下（TODO-935 E0 收敛十几处 `getApplicationDocumentsDirectory()` 时
  /// 刻意保持零迁移，把「默认根 = 共享用户目录」固化成了常态）。现在默认改为 Fushi 专属
  /// 容器 `<Documents>/Fushi/data`（存量 nested 安装为 `Hibiki/data`）；**老安装保持扁平布局不动**（见
  /// [_useLegacyFlatDocumentsRoot]），一个字节都不搬。
  ///
  /// 老用户要收进子目录，走设置里的「数据存储位置」（[DataRootMigrator] 会连 DB 里的绝对
  /// 路径一起 rebase）；这里绝不自动迁移——启动期搬整个书库既慢又可能被文件锁半途打断。
  static Future<Directory> _resolveDefaultDocumentsRoot() async {
    // iOS 不论 flat / nested：书库一律在 `<Library>/Fushi/data`，Documents 只当收件箱。
    if (Platform.isIOS) return iosDocumentsRoot();
    // Android 外部锚定：书库在 `Android/data/<包名>/files/data`，与 flat/nested 无关。
    if (await androidDocumentsAreExternal()) {
      return androidExternalDocumentsRoot();
    }
    final Directory platformDocuments =
        await getApplicationDocumentsDirectory();
    if (await _useLegacyFlatDocumentsRoot()) return platformDocuments;
    return defaultLocationDocumentsRoot();
  }

  // ---- iOS：Documents = 导入收件箱，书库在 Library 下（拍板台 nLXhu0d7gV） ----

  /// iOS 书库根 `<Library>/Fushi/data` 相对 `Library` 的路径段。
  ///
  /// 为什么不是 `Library/Application Support/...`：那是 support 根（数据库所在），两根
  /// 嵌套会让存储统计把书库重复算一遍，也破坏「两根各有独立子树」的不变式。`Library`
  /// 下的自建目录与 Application Support 同样随 iCloud / 电脑备份、不会被系统清理，
  /// 而且「文件」App 看不到。
  static const List<String> iosDocumentsRootSegments = <String>[
    'Fushi',
    'data',
  ];

  /// iOS 书库根（不创建；[resolve] 的 `_ensureResolvedRootsExist` 负责建）。
  static Future<Directory> iosDocumentsRoot() async =>
      iosDocumentsRootUnder(await getLibraryDirectory());

  /// [iosDocumentsRoot] 的纯派生（测试注入 `Library` 目录）。
  static Directory iosDocumentsRootUnder(Directory library) =>
      Directory(p.joinAll(<String>[library.path, ...iosDocumentsRootSegments]));

  /// iOS 书库搬出 Documents 的台账文件名，放在 `<Library>/Fushi/`（书库根的父目录，不在
  /// documents 根里、也不在「文件」App 可见的 Documents 里）。
  ///
  /// 只按白名单全扫一次：台账一旦存在，Documents 就是用户的收件箱，用户在「文件」App 里
  /// 新建一个叫 `videos` / `browser` 的文件夹是完全正常的事，绝不能再按白名单把它当书库
  /// 收走。台账内容是上次**没搬动**的条目（相对 Documents 的路径，一行一个），之后的启动
  /// 只重试这几项；空台账 = 搬完了。用文件而不是 SharedPreferences：偏好拿不到时锚点永远
  /// 写不进去，每次启动都会重新全扫一遍白名单。
  static const String iosDocumentsVacateLedgerName = 'documents_vacated.txt';

  /// [iosDocumentsVacateLedgerName] 在 [library] 下的位置（纯派生，测试注入）。
  static File iosDocumentsVacateLedgerUnder(Directory library) => File(
    p.join(
      library.path,
      iosDocumentsRootSegments.first,
      iosDocumentsVacateLedgerName,
    ),
  );

  /// iOS 导入收件箱目录 = 平台 `Documents`（Info.plist 开了 `UIFileSharingEnabled` /
  /// `LSSupportsOpeningDocumentsInPlace`，「文件」App 的「我的 iPhone › Fushi」就是它）。
  ///
  /// iOS 没有「只共享 Documents 的某个子目录」的办法，所以收件箱只能是整个 Documents——
  /// 这正是书库必须先搬出 Documents（[iosDocumentsRoot]）的原因。
  static Future<Directory> importInboxDirectory() async =>
      fushiTestDirectory('import-inbox') ??
      await getApplicationDocumentsDirectory();

  /// 启动期把 iOS 存量书库搬出 Documents（只在 [resolve] 里调，见那里的顺序说明）。
  ///
  /// 测试分支（[fushiTestDirectory]）与非 iOS 直接跳过。没搬动的条目记进台账
  /// （[vacateIosDocumentsWithLedger]），下次启动只重试它们——已搬的条目本次就从新根读，
  /// 没搬动的留在原处，库里的路径由 `SandboxRelocation`
  /// 统一重基到新根，重试搬完后两边自然对上（同一个白名单作用域）。失败条目记进
  /// [iosDocumentsVacateFailures]，由错误日志服务就绪后写入，不吞。
  static Future<void> _ensureIosSharedDocumentsVacated() async {
    if (!Platform.isIOS) return;
    if (fushiTestDirectory('app-documents') != null) return;
    final Directory library = await getLibraryDirectory();
    final List<String> failures = await vacateIosDocumentsWithLedger(
      platformDocuments: await getApplicationDocumentsDirectory(),
      target: iosDocumentsRootUnder(library),
      ledger: iosDocumentsVacateLedgerUnder(library),
      legacyFlat: () => _useLegacyFlatDocumentsRoot(),
      containerName: defaultDocumentsChildSegments.first,
    );
    _iosDocumentsVacateFailures
      ..clear()
      ..addAll(failures);
  }

  /// 按台账 [ledger] 搬 iOS 存量书库（见 [iosDocumentsVacateLedgerName]）。返回失败条目。
  ///
  /// - 台账不存在：第一次，按 [vacateLegacyIosDocuments] 全量搬，把没搬动的条目写进台账；
  /// - 台账存在且为空：早已搬完，什么都不碰（Documents 已经是用户的收件箱）；
  /// - 台账存在且非空：只重试台账里那几项，再把仍失败的写回。
  ///
  /// 台账写不进去时记为失败（下次启动会重新全量搬一遍，这是唯一会退化成全扫的情况，
  /// 并且会进错误日志）。
  @visibleForTesting
  static Future<List<String>> vacateIosDocumentsWithLedger({
    required Directory platformDocuments,
    required Directory target,
    required File ledger,
    required Future<bool> Function() legacyFlat,
    required String containerName,
  }) async {
    Set<String>? only;
    if (await ledger.exists()) {
      only = <String>{
        for (final String line in await ledger.readAsLines())
          if (line.trim().isNotEmpty) line.trim(),
      };
      if (only.isEmpty) return const <String>[];
    }
    final List<String> failedEntries = <String>[];
    final List<String> failures = await vacateLegacyIosDocuments(
      platformDocuments: platformDocuments,
      target: target,
      legacyFlat: await legacyFlat(),
      containerName: containerName,
      onlyEntries: only,
      failedEntries: failedEntries,
    );
    try {
      await ledger.parent.create(recursive: true);
      await ledger.writeAsString(
        failedEntries.isEmpty ? '' : '${failedEntries.join('\n')}\n',
        flush: true,
      );
    } on FileSystemException catch (e) {
      return <String>[...failures, '${ledger.path}: $e'];
    }
    return failures;
  }

  /// 启动期 iOS 书库搬迁失败的条目（`路径: 原因`）。由 `ErrorLogService.init` 写进错误日志。
  static List<String> get iosDocumentsVacateFailures =>
      List<String>.unmodifiable(_iosDocumentsVacateFailures);
  static final List<String> _iosDocumentsVacateFailures = <String>[];

  /// 把旧版放在 iOS `Documents` 里的书库搬进 [target]。返回失败条目，全部成功为空。
  ///
  /// - nested 布局（[legacyFlat] = false）：整个 `<Documents>/<容器>/data` 搬成 [target]，
  ///   容器伞变空后删掉（不空说明里面有别的东西，原样留着）；
  /// - flat 布局：Documents 根下**只搬** [fushiOwnedDocumentsEntries] 白名单里的顶层项，
  ///   其它东西（导出的剪辑、用户文件）一律不碰——与数据根迁移对共享根的纪律一致。
  ///
  /// 同一容器内是同卷 `rename`，GB 级书库也是 O(1)；目标里已有同名项（上次搬到一半）
  /// 时走 [moveDirectoryMerging] 的合并语义。
  ///
  /// [onlyEntries] 非 null 时只处理其中的条目（相对 Documents 的路径：nested 为
  /// `<容器>/data`，flat 为白名单顶层名），用于按台账重试；没搬动的条目名追加进
  /// [failedEntries]。
  @visibleForTesting
  static Future<List<String>> vacateLegacyIosDocuments({
    required Directory platformDocuments,
    required Directory target,
    required bool legacyFlat,
    required String containerName,
    Set<String>? onlyEntries,
    List<String>? failedEntries,
  }) async {
    final List<String> failures = <String>[];
    if (p.equals(platformDocuments.path, target.path) ||
        p.isWithin(platformDocuments.path, target.path)) {
      failures.add('${target.path}: target inside shared Documents');
      return failures;
    }
    bool wanted(String entry) => onlyEntries?.contains(entry) ?? true;
    if (!legacyFlat) {
      final String entry = '$containerName/data';
      if (!wanted(entry)) return failures;
      final Directory container = Directory(
        p.join(platformDocuments.path, containerName),
      );
      final Directory legacy = Directory(p.join(container.path, 'data'));
      try {
        if (await legacy.exists()) {
          await moveDirectoryMerging(legacy, target);
        }
        if (await container.exists() && await container.list().isEmpty) {
          await container.delete();
        }
      } on FileSystemException catch (e) {
        failures.add('${legacy.path}: $e');
        failedEntries?.add(entry);
      }
      return failures;
    }
    for (final String name in fushiOwnedDocumentsEntries) {
      if (!wanted(name)) continue;
      final String source = p.join(platformDocuments.path, name);
      final String destination = p.join(target.path, name);
      try {
        switch (await FileSystemEntity.type(source, followLinks: false)) {
          case FileSystemEntityType.directory:
            await moveDirectoryMerging(
              Directory(source),
              Directory(destination),
            );
          case FileSystemEntityType.file:
            await target.create(recursive: true);
            await File(source).rename(destination);
          default:
            break;
        }
      } on FileSystemException catch (e) {
        failures.add('$source: $e');
        failedEntries?.add(name);
      }
    }
    return failures;
  }

  /// BUG-1188：**「默认位置」这个概念本身**的 documents 根 = `<Documents>/<容器>/data`
  /// （新装 `Fushi`、存量 `Hibiki`，见 [defaultDocumentsChildSegments]），与本机布局锚点无关。
  ///
  /// [_resolveDefaultDocumentsRoot] 会因老安装锚定 [documentsLayoutFlat] 而返回平台
  /// `Documents`；而「用户在目录选择器里挑的就是默认位置吗」这个判断问的是**全新安装会落
  /// 在哪**，两者在老安装上并不相等。迁移目标解析（`resolveDataRootMigrationTarget`）必须
  /// 用本函数，否则老安装永远解析不出「默认位置」这个目标。
  ///
  /// [fushiTestDirectory] 测试分支仍优先（与三个 `_resolve*` 的顺序铁律一致）。
  static Future<Directory> defaultLocationDocumentsRoot() async {
    final Directory? test = fushiTestDirectory('app-documents');
    if (test != null) return test;
    if (Platform.isIOS) return iosDocumentsRoot();
    final Directory platformDocuments =
        await getApplicationDocumentsDirectory();
    return Directory(
      p.joinAll(<String>[
        platformDocuments.path,
        ...defaultDocumentsChildSegments,
      ]),
    );
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

  /// BUG-1905：documents 根是不是 **Fushi 专属容器**（而不是与用户共享的平台
  /// `Documents` 文件夹）。
  ///
  /// 存储统计要据此决定敢不敢把「白名单之外的顶层项」也算进占用：
  /// * 自定义 dataRoot（`<dataRoot>/documents`）→ 专属；
  /// * nested 默认布局（`<Documents>/Fushi/data`）→ 专属；
  /// * **移动端**：沙盒里的 `Documents` 本就是 app 私有，扁平与否都专属
  ///   （iOS 系统设置的「文稿与数据」算的也正是整个沙盒）；
  /// * 只有**桌面的老扁平安装**为 false —— 那里 documents 根就是用户自己的文档
  ///   文件夹，把用户的文件算成 app 占用既不准也吓人。
  static Future<bool> documentsRootIsFushiOwned() async {
    if (!isDesktopPlatform) return true;
    if (await _resolveDataRoot() != null) return true;
    return !await _useLegacyFlatDocumentsRoot();
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
    final bool flat = await existingInstallHasDatabase();
    _legacyFlatDocumentsRoot = flat;
    // 固化锚点（best-effort）。写失败只意味着下次启动再探一次，不改变本次结果——而下次
    // 探测的判据（主库文件是否存在）此时只会更成立，不会翻转成新布局。
    try {
      await prefs?.setString(
        documentsLayoutPrefKey,
        flat ? documentsLayoutFlat : documentsLayoutNested,
      );
    } catch (e) {
      debugPrint('AppPaths: 固化 documents 布局失败（下次启动重新判定）: $e');
    }
  }

  /// 供 [resolve] 之前就需要「默认位置」定义的调用方（安装器数据根引导）提前定下容器名，
  /// 保证它算出的 [defaultLocationDocumentsRoot] 与紧随其后的 [resolve] 是同一个；
  /// [resolve] 内再调时已判定、直接沿用。
  static Future<void> ensureDocumentsContainerDecided() async =>
      _ensureDocumentsContainerDecided(await _prefsOrNull());

  /// Fushi 改名（Phase 3）：判定 + 固化 nested 容器名。锚点已有直接用；没有则
  /// 探测一次：老容器 `<Documents>/Hibiki/data` 存在而新容器不存在 → 存量安装，
  /// 锚 `Hibiki`（目录与 DB 内绝对路径都不动）；否则锚 `Fushi`（新装）。
  /// 探测失败按存量处理（保守——误锚 Fushi 会让存量书库集体消失，反向只是新装
  /// 目录名旧了点）。
  static Future<void> _ensureDocumentsContainerDecided(
    SharedPreferences? prefs,
  ) async {
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
      final bool legacyExists = await Directory(
        p.join(platformDocuments.path, 'Hibiki', 'data'),
      ).exists().timeout(const Duration(seconds: 2), onTimeout: () => true);
      final bool newExists = await Directory(
        p.join(platformDocuments.path, 'Fushi', 'data'),
      ).exists().timeout(const Duration(seconds: 2), onTimeout: () => false);
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
  /// 兼看旧文件名 [legacyHibikiDatabaseFileName]：改名前从未升级过的老安装主库还叫
  /// `hibiki.db`。本版本不再改名迁移它（开库时 fushi_core 抛
  /// `UnsupportedLegacySchemaException`，提示先装桥接版本），但这里仍必须认它——
  /// 只认新名会把老安装误判成全新安装、换到新布局的空数据根上。
  static Future<bool> existingInstallHasDatabase() async {
    try {
      final Directory support = await _resolveSupportRoot();
      Future<bool> dbExists(String fileName) => File(
        p.join(support.path, fileName),
      ).exists().timeout(const Duration(seconds: 2), onTimeout: () => true);
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
    final Directory? test = fushiTestDirectory('app-support');
    if (test != null) return test;
    final Directory? dataRoot = await _resolveDataRoot();
    if (dataRoot != null) {
      return Directory(p.join(dataRoot.path, dataRootSupportChild));
    }
    return getApplicationSupportDirectory();
  }

  // tempRoot 永远走系统临时目录（可丢弃、与数据根解耦）：迁移不搬 temp，dataRoot 也不接管它。
  static Future<Directory> _resolveTempRoot() async =>
      fushiTestDirectory('temp') ?? await getTemporaryDirectory();

  static Future<Directory> _resolveAppCacheRoot() async =>
      fushiTestDirectory('app-cache') ?? await getApplicationCacheDirectory();

  /// 给迁移引擎（E1）/ 设置 UI（E2）复用的纯派生：把一个 dataRoot 绝对路径映射成它
  /// 派生的 (documentsRoot, supportRoot) 对，子目录名与 [_resolveDocumentsRoot] /
  /// [_resolveSupportRoot] 的 dataRoot 分支逐字节一致。
  static (Directory documents, Directory support) rootsForDataRoot(
    String dataRootPath,
  ) => (
    Directory(p.join(dataRootPath, dataRootDocumentsChild)),
    Directory(p.join(dataRootPath, dataRootSupportChild)),
  );

  /// TODO-1226：documents 根顶层**属于 Fushi 的目录名全集**（数据根迁移白名单）。
  ///
  /// **老安装（[documentsLayoutFlat]）** 的 documents 根 = 整个用户 `Documents`（共享目录，含
  /// 用户自己的文件和 shell junction）。迁移引擎对共享根**只搬这份白名单里的顶层项**，
  /// 绝不整树搬移 / 整树删除用户 `Documents`。BUG-1115 之后新装走
  /// `<Documents>/Fushi/data`（Fushi 专属根，迁移走整树语义），白名单对它不生效——但
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
  ///  - `mpv_scripts` —— [mpvLuaScriptsDirectory]。
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
  /// **刻意不收**：`video_clips` 与桌面导出目录 `Hibiki`（直连 path_provider 的用户可见
  /// 导出物，属用户文件语义）。错误日志 / 面包屑 / 诊断日志不在 documents 下，见
  /// [diagnosticsDirectory]（4w_veZGiQ7：它们曾直落平台 Documents 根）。
  ///
  /// 守卫测试 `test/storage/documents_whitelist_guard_test.dart` 扫描源码派生点，
  /// 新增 `<documents>/<child>` 派生而漏加这里会红。
  static const Set<String> fushiOwnedDocumentsEntries = <String>{
    'audiobooks',
    'fushi_books',
    'hoshi_books',
    'video_covers',
    'game_covers',
    // 音乐刮削下载的 Cover Art Archive 专辑封面（`<documents>/music_covers/<发行 MBID>.jpg`，
    // music_albums.cover_path 指向它；数据根迁移按 DataRootMigrator._rebaseMusicAlbums 改写）。
    'music_covers',
    'video_subtitles',
    'mpv_shaders',
    'mpv_scripts',
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
    // 新手引导推荐包的下载暂存目录（含 .part 半截文件，随根搬走以免续传丢进度；
    // 导入成功后由向导 initState 整目录删除，常态下为空/不存在）。
    'recommended_pack',
    'onboarding_tutorial',
    // 下载页「手动添加任务」落的 .torrent 元数据，随任务长期持久化，必须随数据根走
    // （留在旧根 = 换根后任务恢复不出种子）。派生点：AppModel 的
    // manualTorrentDirectory。
    'manual_torrents',
    // 卡片来源回看的待回写草稿（临时音频/图片/字段，`card_source_drafts/<sourceId>`），
    // 失败后可恢复提交，必须随数据根走。派生点：card_source_router.dart。
    'card_source_drafts',
    // 删 Profile 前自动做的复习数据备份（`.fushisrs`，撤销途径，BUG-3818），必须随数据根走。
    // 派生点：AppPaths.srsProfileBackupsDirectory（srs_profile_cleanup.dart 使用）。
    'srs_profile_backups',
    // 音频 CD 抓轨产物（BUG-3312，`<documents>/audio_cd/<卷标> (<光盘id>)/`）。导入后的
    // 视频条目 videoPath 指向这里，必须随数据根走。派生点：audio_cd_import.dart。
    'audio_cd',
    // 在线音源插件曲目下载（`<documents>/music_downloads/<插件>/<专辑>/`）。导入后的曲目
    // path 指向这里，必须随数据根走。派生点：music_plugin_download.dart。
    'music_downloads',
    // 旧版复习自动备份（`<documents>/srs_backups/`）。同步 v2 已取消定时备份（时间线 + 归档 + 手动
    // 导出取代），旧文件升级后再留 30 天（srs_legacy_backup_cleanup.dart），这期间仍随数据根走。
    'srs_backups',
    // iOS「文件」App 收件箱收进来的文件（拍板台 nLXhu0d7gV，`<documents>/inbox_imports/<域>/<批次>/`）。
    // 视频 / 曲目条目原地引用这里，必须随数据根走、随容器漂移重基。派生点：
    // AppPaths.inboxImportsDirectory（import_inbox.dart / media_sources_view.dart 使用）。
    'inbox_imports',
  };

  /// BUG-1115：[newDataRoot] 落在**共享** documents 根（老安装的扁平布局 = 平台
  /// `Documents`）内部时，它是否是一个安全的迁移目标。
  ///
  /// 一般规则是「新数据根不能位于旧数据目录内部」（自我嵌套 → 边搬边把目标搬进自己）。
  /// 但共享根是个例外：那里的迁移是**白名单选择性搬移**——只有
  /// [fushiOwnedDocumentsEntries] 里的顶层项会被搬走，别的顶层项一律不碰。所以只要新根
  /// 的顶层段不是白名单里的名字，它在搬移中就是个旁观者，`Documents\Fushi` 这种「把散
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
    final String firstSegment = p
        .split(p.relative(canonNew, from: canonRoot))
        .first
        .toLowerCase();
    return !ownedEntries.any(
      (String owned) => owned.toLowerCase() == firstSegment,
    );
  }

  // ---- 诊断目录（错误日志 / 崩溃面包屑 / 诊断日志） ----

  /// 诊断文件（`error_log.txt`、各 `*_breadcrumb.txt`、`crash_report_state.json`、
  /// `previous_exit_state.json`、`session_marker.json`、`activity_*`、视频 / 学习诊断
  /// 日志）的唯一落点。
  ///
  /// 4w_veZGiQ7：这些文件曾由 `ErrorLogService` / `VideoDiagLog` / `StudyDiagLog` 各自直连
  /// `getApplicationDocumentsDirectory()`。桌面上（macOS 已去沙盒、Windows、Linux）那就是
  /// 用户自己的 `~/Documents` 根——Fushi 的内容早已收进 `<Documents>/Fushi/data`
  /// （BUG-1115），日志却摊在用户文档根里。「不随数据根迁移」是对的（启动最早期就要写、
  /// 数据根可能不可达），但目录选错了：
  /// - 桌面：`<ApplicationSupport>/logs`（macOS `~/Library/Application Support/<bundle>/logs`），
  ///   app 私有、与数据根无关、启动最早期可用；
  /// - iOS：同桌面 `<ApplicationSupport>/logs`。iOS 的 Documents 已是「文件」App 可见的
  ///   导入收件箱（拍板台 nLXhu0d7gV），未脱敏的错误日志不能摊在那里；原生 MetricKit
  ///   落盘 `<ApplicationSupport>/logs/metrickit/` 与它同目录约定（`AppDelegate.swift`），
  ///   旧版留在 `Documents/metrickit/` 的待摘要诊断随诊断文件一起搬过来；
  /// - Android：外部 app 专属目录 `Android/data/<包名>/files/logs`（USB / 电脑可直接拿去
  ///   反馈；其它 app 读不到，分区存储隔离）。旧版留在 `app_flutter` 的诊断文件首次解析时
  ///   搬过来；外部存储本次不可用时退回 `app_flutter`。
  ///
  /// 测试分支与旧实现同一个键（`app-documents`），测试注入不变。首次解析时把旧位置
  /// （平台 Documents 根）残留的诊断文件搬过来（[migrateLegacyDiagnostics]），再交给
  /// `ErrorLogService.init` 读面包屑做崩溃恢复——顺序保证上次的崩溃现场不丢。
  static Future<Directory> diagnosticsDirectory() async {
    final Directory? test = fushiTestDirectory('app-documents');
    if (test != null) return test;
    // 生产分支只解析 + 搬迁一次（多个日志服务并发 init 共用同一个 future）。
    return _diagnosticsDirectory ??= _resolveDiagnosticsDirectory();
  }

  static Future<Directory>? _diagnosticsDirectory;

  /// 启动期把旧诊断文件搬进 [diagnosticsDirectory] 时失败的条目（`文件名: 原因`）。
  /// 搬迁跑在错误日志就绪之前，由 `ErrorLogService.init` 读出写进错误日志，不吞。
  static List<String> get diagnosticsMigrationFailures =>
      List<String>.unmodifiable(_diagnosticsMigrationFailures);
  static final List<String> _diagnosticsMigrationFailures = <String>[];

  @visibleForTesting
  static void resetDiagnosticsDirectoryForTesting() {
    _diagnosticsDirectory = null;
    _diagnosticsMigrationFailures.clear();
  }

  static Future<Directory> _resolveDiagnosticsDirectory() async {
    if (Platform.isAndroid) {
      final Directory legacy = await getApplicationDocumentsDirectory();
      final Directory? ext = await androidExternalFilesDirectory();
      // 外部存储本次不可用：留在 app_flutter（下次可用时再搬）。
      if (ext == null) return legacy;
      final Directory dir = Directory(p.join(ext.path, 'logs'));
      await dir.create(recursive: true);
      _diagnosticsMigrationFailures.addAll(
        await migrateLegacyDiagnostics(from: legacy, to: dir),
      );
      return dir;
    }
    if (!isDesktopPlatform && !Platform.isIOS) {
      return getApplicationDocumentsDirectory();
    }
    final Directory support = await getApplicationSupportDirectory();
    final Directory dir = Directory(p.join(support.path, 'logs'));
    await dir.create(recursive: true);
    final Directory legacy = await getApplicationDocumentsDirectory();
    if (Platform.isIOS) {
      _diagnosticsMigrationFailures.addAll(
        await migrateLegacyMetricKitDirectory(from: legacy, to: dir),
      );
    }
    _diagnosticsMigrationFailures.addAll(
      await migrateLegacyDiagnostics(from: legacy, to: dir),
    );
    return dir;
  }

  /// iOS 原生 MetricKit 落盘子目录名（`AppDelegate.swift` 与 `previous_exit_log.dart` 同名）。
  static const String metricKitDirectoryName = 'metrickit';

  /// 把旧版落在 [from]（iOS Documents）下的 `metrickit/` 合并进 [to] 下的同名目录。
  /// 返回失败条目。旧目录不存在时什么都不做（每次启动只多一次 stat）。
  @visibleForTesting
  static Future<List<String>> migrateLegacyMetricKitDirectory({
    required Directory from,
    required Directory to,
  }) async {
    final Directory legacy = Directory(
      p.join(from.path, metricKitDirectoryName),
    );
    try {
      if (!await legacy.exists()) return const <String>[];
      await moveDirectoryMerging(
        legacy,
        Directory(p.join(to.path, metricKitDirectoryName)),
      );
      return const <String>[];
    } on FileSystemException catch (e) {
      return <String>['$metricKitDirectoryName: $e'];
    }
  }

  /// 旧位置（平台 Documents 根）上属于 Fushi 的诊断文件名。只认这些确切的名字 /
  /// `ActivityBreadcrumb` 的完整文件名形态（`activity_<名>.breadcrumb`，判据与读取端
  /// 共用 [activityNameFromBreadcrumbFileName]）——这是用户自己的文档目录，绝不扫别的东西。
  static const Set<String> legacyDiagnosticFileNames = <String>{
    'error_log.txt',
    'import_crash_breadcrumb.txt',
    'import_step_breadcrumb.txt',
    'lookup_crash_breadcrumb.txt',
    'init_step_breadcrumb.txt',
    'crash_report_state.json',
    'previous_exit_state.json',
    'session_marker.json',
    'video_diag_log.txt',
    'video_mpv_log.txt',
    'study_diag_log.txt',
  };

  /// 搬迁完成标记（落在 [migrateLegacyDiagnostics] 的 `to` 里）。全部条目都搬成功后写入，
  /// 之后启动不再扫用户的 Documents 根——旧位置只可能有升级前留下的文件，扫一次就够；
  /// 有失败条目时不写，下次启动重试。
  static const String legacyDiagnosticsMigratedMarker =
      '.legacy_documents_diagnostics_migrated';

  /// [name] 是否是 Fushi 旧版写在 Documents 根的诊断文件。
  @visibleForTesting
  static bool isLegacyDiagnosticFileName(String name) =>
      legacyDiagnosticFileNames.contains(name) ||
      activityNameFromBreadcrumbFileName(name) != null;

  /// 把 [from] 根下的 Fushi 诊断文件搬进 [to]。返回失败条目（`文件名: 原因`），成功 / 无需
  /// 搬为空。目标已有同名文件（新位置已在用）时以新位置为准、删掉旧文件。
  /// [to] 里已有 [legacyDiagnosticsMigratedMarker] 时直接返回，不再列 [from]。
  @visibleForTesting
  static Future<List<String>> migrateLegacyDiagnostics({
    required Directory from,
    required Directory to,
  }) async {
    final List<String> failures = <String>[];
    if (p.equals(from.path, to.path)) return failures;
    final File marker = File(p.join(to.path, legacyDiagnosticsMigratedMarker));
    if (await marker.exists()) return failures;
    final List<File> candidates = <File>[];
    try {
      if (await from.exists()) {
        await for (final FileSystemEntity e in from.list(followLinks: false)) {
          if (e is! File) continue;
          if (isLegacyDiagnosticFileName(p.basename(e.path))) {
            candidates.add(e);
          }
        }
      }
    } catch (e) {
      failures.add('${from.path}: list failed: $e');
      return failures;
    }
    for (final File legacy in candidates) {
      final String name = p.basename(legacy.path);
      final File target = File(p.join(to.path, name));
      try {
        if (await target.exists()) {
          await legacy.delete();
          continue;
        }
        try {
          await legacy.rename(target.path);
        } on FileSystemException {
          // 跨卷（自定义 Documents 重定向到别的盘）rename 不成：复制后删源。
          await legacy.copy(target.path);
          await legacy.delete();
        }
      } catch (e) {
        failures.add('$name: $e');
      }
    }
    if (failures.isEmpty) {
      try {
        await marker.writeAsString(DateTime.now().toIso8601String());
      } catch (e) {
        failures.add('$legacyDiagnosticsMigratedMarker: $e');
      }
    }
    return failures;
  }

  // ---- 静态便捷层（给无 AppModel 实例的 static 存储助手） ----

  /// 内容/书库根目录。等价于过去散落各处的 `getApplicationDocumentsDirectory()`。
  static Future<Directory> documentsRootDirectory() => _resolveDocumentsRoot();

  /// 数据库根目录。等价于过去的 `getApplicationSupportDirectory()`。
  static Future<Directory> supportRootDirectory() => _resolveSupportRoot();

  /// 临时目录。等价于过去的 `getTemporaryDirectory()`。
  static Future<Directory> tempRootDirectory() => _resolveTempRoot();

  /// 本 app 专属的缓存目录（`getApplicationCacheDirectory()`）。
  ///
  /// 与 [tempRootDirectory] 不同：未沙盒的 macOS 上临时根是全用户共享的
  /// `~/Library/Caches`，这里是追加了 bundle id 的子目录，只属于 Fushi。
  /// 需要「这个目录里的东西全是我们的」时（存储页统计 / 清理）用它。
  static Future<Directory> appCacheRootDirectory() => _resolveAppCacheRoot();

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

  /// 音乐刮削封面目录 `<documents>/music_covers`（文件名 = 发行 MBID）。
  static Future<Directory> musicCoversDirectory() =>
      documentsSubdirectory('music_covers');

  /// 视频外挂字幕副本目录 `<documents>/video_subtitles`。
  static Future<Directory> videoSubtitlesDirectory() =>
      documentsSubdirectory('video_subtitles');

  /// mpv 着色器目录 `<documents>/mpv_shaders`。
  static Future<Directory> mpvShadersDirectory() =>
      documentsSubdirectory('mpv_shaders');

  /// mpv Lua 脚本目录 `<documents>/mpv_scripts`。
  static Future<Directory> mpvLuaScriptsDirectory() =>
      documentsSubdirectory('mpv_scripts');

  /// 远程视频下载目录 `<documents>/remote_videos`。
  static Future<Directory> remoteVideosDirectory() =>
      documentsSubdirectory('remote_videos');

  /// 旧版复习自动备份根 `<documents>/srs_backups`（只剩升级后 30 天的清理在用）。
  static Future<Directory> srsBackupsDirectory() =>
      documentsSubdirectory('srs_backups');

  /// iOS 收件箱批次落点 `<documents>/inbox_imports`（见 `import_inbox.dart`）。
  static Future<Directory> inboxImportsDirectory() =>
      documentsSubdirectory('inbox_imports');

  /// 删 Profile 前自动做的复习数据备份 `<documents>/srs_profile_backups`（`.fushisrs`，撤销途径；
  /// 不进旧备份的 30 天清理，见 `srs_profile_cleanup.dart`）。
  static Future<Directory> srsProfileBackupsDirectory() =>
      documentsSubdirectory('srs_profile_backups');
}

/// Android 书库位置锚点（[AppPaths.androidLibraryAnchorFileName] 的内容）。
///
/// 放在 support 根下的独立小文件里、原子替换，而不是 SharedPreferences：后者在多进程
/// 下会被别的进程的旧内存副本整份覆盖（反馈 RCv76PPoiJ）。内部书库的布局与容器名也
/// 记在这里，理由相同：它们在 prefs 里那份被冲掉后，布局判定会回落成 flat，书库根指到
/// `app_flutter` 本身，书库在 UI 上整体消失。
@immutable
class AndroidLibraryAnchor {
  const AndroidLibraryAnchor({
    required this.location,
    this.layout,
    this.container,
  });

  /// [AppPaths.androidDocumentsLocationInternal] / [AppPaths.androidDocumentsLocationExternal]。
  final String location;

  /// 内部书库的布局 [AppPaths.documentsLayoutFlat] / [AppPaths.documentsLayoutNested]；
  /// null = 不由锚点决定（沿用布局锚点的判定）。
  final String? layout;

  /// 内部 nested 书库的容器名 [AppPaths.documentsContainerFushi] /
  /// [AppPaths.documentsContainerHibiki]；null = 不由锚点决定（沿用容器锚点的判定）。
  final String? container;

  static const Set<String> _locations = <String>{
    AppPaths.androidDocumentsLocationInternal,
    AppPaths.androidDocumentsLocationExternal,
  };
  static const Set<String> _layouts = <String>{
    AppPaths.documentsLayoutFlat,
    AppPaths.documentsLayoutNested,
  };
  static const Set<String> _containers = <String>{
    AppPaths.documentsContainerFushi,
    AppPaths.documentsContainerHibiki,
  };

  /// 解析文件内容；不是合法锚点返回 null。
  static AndroidLibraryAnchor? tryParse(String raw) {
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map<String, Object?>) return null;
      final Object? location = decoded['location'];
      if (location is! String || !_locations.contains(location)) return null;
      final Object? layout = decoded['layout'];
      final Object? container = decoded['container'];
      return AndroidLibraryAnchor(
        location: location,
        layout: layout is String && _layouts.contains(layout) ? layout : null,
        container: container is String && _containers.contains(container)
            ? container
            : null,
      );
    } on FormatException {
      return null;
    }
  }

  String encode() => jsonEncode(<String, String>{
    'location': location,
    if (layout != null) 'layout': layout!,
    if (container != null) 'container': container!,
  });

  @override
  bool operator ==(Object other) =>
      other is AndroidLibraryAnchor &&
      other.location == location &&
      other.layout == layout &&
      other.container == container;

  @override
  int get hashCode => Object.hash(location, layout, container);

  @override
  String toString() => encode();
}

/// [AppPaths.probeLibraryFiles] 的结论。
enum LibraryProbe {
  /// 至少有一个书库文件。
  found,

  /// 全部探完，一个书库文件都没有。
  none,

  /// 没找到书库文件，但途中有目录列不出来或超时：结论不可靠。
  unknown,
}

/// Android 内部书库根的一个候选：布局、容器名与它推出来的目录。
@immutable
class AndroidInternalLibraryCandidate {
  const AndroidInternalLibraryCandidate({
    required this.layout,
    required this.container,
    required this.root,
  });

  /// [AppPaths.documentsLayoutFlat] / [AppPaths.documentsLayoutNested]。
  final String layout;

  /// [AppPaths.documentsContainerFushi] / [AppPaths.documentsContainerHibiki]（flat 布局
  /// 下不影响 [root]，只是沿用当前值，供日后迁回内部 nested 时用）。
  final String container;

  /// 这个候选的书库根。
  final Directory root;

  @override
  String toString() => '$layout/$container ${root.path}';
}

/// [AppPaths.reconcileAndroidLibraryRoots] 的结论。
@immutable
class AndroidLibraryReconciliation {
  const AndroidLibraryReconciliation({
    required this.location,
    required this.internal,
    this.notes = const <String>[],
    this.strayRoot,
  });

  /// 最终的书库位置（internal / external）。
  final String location;

  /// 最终的内部书库根候选（位置是外部时，它是迁回内部时用的布局与容器）。
  final AndroidInternalLibraryCandidate internal;

  /// 写进诊断日志的对账说明（纠正、两边都有、锚定根是空的时各根的探测结论）。
  final List<String> notes;

  /// 两个根都有书、主库作证后落选的根，交给散书合并；null = 不合并。
  final Directory? strayRoot;
}
