import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Hibiki → Fushi **桌面原地改名升级**的 app-support 根搬迁。
///
/// 桌面端不是跨包名迁移（那是 Android，见 `lib/src/migration/`），而是同一个
/// AppId / 同一个安装目录的覆盖安装：用户什么都不做，app 就从 Hibiki 变成
/// Fushi。可 app-support 根的路径是**从二进制身份推出来的**，改名把它一起改了：
///
/// - Windows：`path_provider` 返回 `%APPDATA%\<CompanyName>\<ProductName>`，两个
///   字符串取自 exe 版本信息（`windows/runner/Runner.rc`）。
///   `Hibiki\Hibiki` → `Fushi\Fushi`。
/// - macOS：`path_provider` 返回
///   `~/Library/Application Support/<CFBundleIdentifier>`。已发布的 v1.2.0 是
///   `com.example.hibiki`，改名后是 `app.fushi.reader`。
/// - Linux：`path_provider` 返回 XDG_DATA_HOME 下的 `<APPLICATION_ID>`，而
///   `linux/CMakeLists.txt` 的 `APPLICATION_ID` / `BINARY_NAME` **本次改名没动**
///   （仍是 `com.example.hibiki` / `hibiki`）→ 无断裂、无需搬迁。守卫
///   `test/storage/desktop_identity_continuity_guard_test.dart` 锁死这一点：
///   哪天真去改 Linux 身份，守卫会红，逼着在这里补一条旧根。
///
/// 主库、`shared_preferences.json`（数据根配置与 documents 布局锚点都在里面）、
/// TLS 私钥、更新缓存、图标缓存全在这个根下。不搬 = 用户打开一个空 app：书、
/// 词典、进度、统计、设置全部「不见了」，而且**没有任何报错**。
///
/// **必须在进程内第一次 `SharedPreferences.getInstance()` 之前调用**（插件会在新
/// 路径创建并缓存空 prefs，之后搬什么都晚了）。`main()` 在 `ensureInitialized`
/// 之后立刻调。
Future<LegacySupportMigrationOutcome> migrateLegacySupportDir() async {
  if (!Platform.isWindows && !Platform.isMacOS && !Platform.isLinux) {
    return LegacySupportMigrationOutcome.notApplicable;
  }
  try {
    final Directory current = await getApplicationSupportDirectory();
    final Directory? legacy = legacySupportDirFor(
      current,
      isMacOS: Platform.isMacOS,
      isLinux: Platform.isLinux,
    );
    if (legacy == null) return LegacySupportMigrationOutcome.notApplicable;
    final LegacySupportMigrationOutcome outcome =
        migrateSupportDirTree(legacy: legacy, current: current);
    if (outcome.movedData) {
      rebaseSupportPathsInPrefsFile(
        prefsFile: File(p.join(current.path, kDesktopPrefsFileName)),
        legacyRoot: legacy.path,
        newRoot: current.path,
        caseInsensitive: Platform.isWindows,
      );
    }
    return outcome;
  } catch (e) {
    // 搬迁失败不能挡启动：旧位置的数据一字节没动，下次启动重试。
    debugPrint('[fushi-support-migration] failed: $e');
    return LegacySupportMigrationOutcome.failed;
  }
}

/// 搬迁结果。给调用方与测试断言用（`failed` 时旧数据一定完好）。
enum LegacySupportMigrationOutcome {
  /// 平台不在改名影响面内，或 app-support 根不是预期布局（不认识就别动）。
  notApplicable,

  /// 旧根不存在：全新安装，或已经搬完并且旧根被 rename 消费掉了。
  noLegacy,

  /// 新根已有内容：搬过了 / 用户混用过两个版本。**绝不覆盖**。
  alreadyPopulated,

  /// 同卷 rename 成功（原子、O(1)，旧根随之消失）。
  moved,

  /// 跨卷 / 被占用 → 经暂存目录整树复制后 rename 就位。**旧根刻意保留**
  /// （宁可留一份副本，也不在复制后做删除这种不可回滚的动作）。
  copied,

  /// 出错。旧根内容未被修改，下次启动重试。
  failed;

  /// 本次是否真的把数据搬到了新根（`moved` / `copied`）。
  bool get movedData =>
      this == LegacySupportMigrationOutcome.moved ||
      this == LegacySupportMigrationOutcome.copied;
}

/// 桌面 `shared_preferences` 的落盘文件名（`shared_preferences_windows` /
/// `shared_preferences_linux` 都把它写在 `getApplicationSupportPath()` 下）。
/// macOS 走 NSUserDefaults 不落这个文件，[rebaseSupportPathsInPrefsFile] 见不到
/// 文件即 no-op。
const String kDesktopPrefsFileName = 'shared_preferences.json';

/// macOS 存量安装（含已发布的 v1.2.0）的 bundle identifier。
const String kLegacyMacosBundleId = 'com.example.hibiki';

/// macOS 改名后的 bundle identifier（`macos/Runner/Configs/AppInfo.xcconfig`）。
const String kFushiMacosBundleId = 'app.fushi.reader';

/// Windows 改名前的 APPDATA 两段（CompanyName / ProductName 都是 `Hibiki`）。
const List<String> kLegacyWindowsAppDataSegments = <String>['Hibiki', 'Hibiki'];

/// Windows 改名后的 APPDATA 两段（Runner.rc 的 CompanyName / ProductName）。
const List<String> kFushiWindowsAppDataSegments = <String>['Fushi', 'Fushi'];

/// Linux 存量安装的 APPLICATION_ID（改名前 `linux/CMakeLists.txt` 的值）。
const String kLegacyLinuxApplicationId = 'com.example.hibiki';

/// Linux 改名后的 APPLICATION_ID（PR #790 W9 收尾把 CMakeLists 一并换成了
/// fushi 身份——守卫 `desktop_identity_continuity_guard_test.dart` 当场红，
/// 本条 Linux 搬迁分支即它逼出来的补齐：XDG_DATA_HOME 下
/// `com.example.hibiki` → `app.fushi.reader`，与 macOS 同为「同父目录换末段」
/// 布局，共用同一套 migrateSupportDirTree/rebase 管线）。
const String kFushiLinuxApplicationId = 'app.fushi.reader';

/// 由**当前** app-support 根反推同一台机器上改名前的 app-support 根。
///
/// 纯路径推导（不碰文件系统），所以可单测。返回 null = 「这不是我认识的布局」，
/// 调用方一律不动（宁可不搬，也不能对着猜出来的目录做搬迁）。
///
/// [context] 只为测试而存在：`package:path` 的顶层函数按**宿主平台**选路径风格，
/// 于是「Windows 布局」的用例在 Linux CI 上会被 posix 风格切成一段而假绿/假红。
/// 生产恒用平台默认上下文。
Directory? legacySupportDirFor(
  Directory current, {
  required bool isMacOS,
  bool isLinux = false,
  p.Context? context,
}) {
  final p.Context ctx = context ?? p.context;
  final List<String> segments = ctx.split(current.path);
  if (isMacOS) {
    // ~/Library/Application Support/app.fushi.reader → 同级 com.example.hibiki
    if (segments.last != kFushiMacosBundleId) return null;
    return Directory(ctx.join(ctx.dirname(current.path), kLegacyMacosBundleId));
  }
  if (isLinux) {
    // $XDG_DATA_HOME/app.fushi.reader → 同级 com.example.hibiki。
    if (segments.last != kFushiLinuxApplicationId) return null;
    return Directory(
        ctx.join(ctx.dirname(current.path), kLegacyLinuxApplicationId));
  }
  // Windows：Roaming\Fushi\Fushi → Roaming\Hibiki\Hibiki。
  final int depth = kFushiWindowsAppDataSegments.length;
  if (segments.length < depth + 1) return null;
  final List<String> tail = segments.sublist(segments.length - depth);
  for (int i = 0; i < depth; i++) {
    if (tail[i] != kFushiWindowsAppDataSegments[i]) return null;
  }
  final String roaming =
      ctx.joinAll(segments.sublist(0, segments.length - depth));
  return Directory(
      ctx.joinAll(<String>[roaming, ...kLegacyWindowsAppDataSegments]));
}

/// 暂存目录后缀。跨卷复制的落点是「新根 + 本后缀」（与新根同父目录，保证最后
/// 那步 rename 是同卷原子操作）。
const String kSupportMigrationStagingSuffix = '.fushi-migrating';

/// 把 [legacy] 整棵搬到 [current]。**幂等、可中断重入、失败绝不删旧数据。**
///
/// 中断安全的关键是：跨卷回退**不直接往新根里复制**，而是复制进兄弟暂存目录，
/// 全部复制完才 rename 就位。否则「复制到一半断电」会留下一个**非空但残缺**的新
/// 根，下次启动被 [LegacySupportMigrationOutcome.alreadyPopulated] 判定为「已经
/// 搬过」→ 残缺状态被永久固化（库文件缺半截 = 静默丢数据）。暂存目录里的残缺
/// 副本不会被误认为新根，下次启动整个删掉重来。
///
/// 同步实现是有意的：这段跑在 runApp 之前、没有任何并发方，异步只会引入
/// 「搬到一半 prefs 插件已经在新根开写」的时序缝。
/// [debugForceCopyFallback] 只给测试用：跳过同卷 rename 直接走跨卷复制分支。
/// 跨卷失败在单机临时目录里造不出来（`systemTemp` 永远同卷），而暂存目录 +
/// 中断重入的语义全长在那条分支上，没有这个开关就等于零覆盖。
LegacySupportMigrationOutcome migrateSupportDirTree({
  required Directory legacy,
  required Directory current,
  @visibleForTesting bool debugForceCopyFallback = false,
  @visibleForTesting void Function()? debugAfterStagingCopy,
}) {
  final Directory staging =
      Directory(current.path + kSupportMigrationStagingSuffix);
  if (!legacy.existsSync()) {
    _deleteQuietly(staging);
    return LegacySupportMigrationOutcome.noLegacy;
  }
  if (current.existsSync() && current.listSync(followLinks: false).isNotEmpty) {
    _deleteQuietly(staging);
    return LegacySupportMigrationOutcome.alreadyPopulated;
  }
  // 上一轮跨卷复制被中断留下的残缺副本，一律先清掉：它既不能当结果用，留着还会
  // 在磁盘上长期占着一份半截数据。
  _deleteQuietly(staging);
  Directory(p.dirname(current.path)).createSync(recursive: true);
  // path_provider 会在返回前把 app-support 根建出来；空壳挡着 rename，删掉它。
  if (current.existsSync()) current.deleteSync();
  if (!debugForceCopyFallback) {
    try {
      legacy.renameSync(current.path);
      return LegacySupportMigrationOutcome.moved;
    } on FileSystemException {
      // 跨卷 / 目录被占用：走暂存目录整树复制。
    }
  }
  try {
    _copyTreeSync(legacy, staging);
    // 观察点：此刻数据全量落在暂存目录，新根**还不存在**。断电停在这里，下次
    // 启动看到的是「新根不存在」→ 重来一遍；若直接往新根增量复制，同一时刻新根
    // 已经非空但残缺，下次启动会被判成「已经搬过」并把残缺永久固化。
    debugAfterStagingCopy?.call();
    staging.renameSync(current.path);
    return LegacySupportMigrationOutcome.copied;
  } catch (e) {
    debugPrint('[fushi-support-migration] copy fallback failed: $e');
    _deleteQuietly(staging);
    return LegacySupportMigrationOutcome.failed;
  }
}

void _deleteQuietly(Directory dir) {
  try {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  } catch (_) {
    // 暂存目录清不掉不致命：下一轮再试，真数据不在里面。
  }
}

void _copyTreeSync(Directory from, Directory to) {
  to.createSync(recursive: true);
  for (final FileSystemEntity entity
      in from.listSync(recursive: true, followLinks: false)) {
    final String rel = p.relative(entity.path, from: from.path);
    final String dest = p.join(to.path, rel);
    if (entity is Directory) {
      Directory(dest).createSync(recursive: true);
    } else if (entity is File) {
      Directory(p.dirname(dest)).createSync(recursive: true);
      entity.copySync(dest);
    }
  }
}

/// 把 [prefsFile] 里所有**指向旧 app-support 根内部**的绝对路径改写到新根。
///
/// 搬迁只动目录，不动 prefs 里烧死的绝对路径。真实现场（Windows 用户 prefs）：
/// `app_icon_custom_path` 的值是 Roaming\Hibiki\Hibiki 下的
/// `window_icon_custom.png` —— 文件被搬到 Fushi\Fushi 后这个路径失效，`main()`
/// 里的 `File(iconPath).existsSync()` 判 false，用户的自定义窗口图标**静默消失**。
///
/// 只改「以旧根为前缀」的字符串值，别的一律原样；文件不存在 / 不是合法 JSON /
/// 无命中 → no-op（返回 false）。
bool rebaseSupportPathsInPrefsFile({
  required File prefsFile,
  required String legacyRoot,
  required String newRoot,
  required bool caseInsensitive,
}) {
  if (!prefsFile.existsSync()) return false;
  final String? rewritten = rebaseSupportPathsInPrefsJson(
    prefsFile.readAsStringSync(),
    legacyRoot: legacyRoot,
    newRoot: newRoot,
    caseInsensitive: caseInsensitive,
  );
  if (rewritten == null) return false;
  prefsFile.writeAsStringSync(rewritten, flush: true);
  return true;
}

/// [rebaseSupportPathsInPrefsFile] 的纯函数内核。返回 null = 无需改写。
///
/// 前缀比较在 Windows 上大小写不敏感（NTFS 语义；prefs 里的值可能是
/// Roaming\hibiki\hibiki 这种大小写不一致的形态）。分隔符不做归一：写入方是
/// 「dir.path 直接拼子路径」，旧根那一段永远是 dir.path 逐字节原样，前缀匹配
/// 足够；归一反而会把用户手填的路径改坏。
String? rebaseSupportPathsInPrefsJson(
  String jsonText, {
  required String legacyRoot,
  required String newRoot,
  required bool caseInsensitive,
}) {
  final Object? decoded;
  try {
    decoded = jsonDecode(jsonText);
  } on FormatException {
    return null;
  }
  if (decoded is! Map<String, dynamic>) return null;
  final String needle = caseInsensitive ? legacyRoot.toLowerCase() : legacyRoot;
  bool changed = false;
  final Map<String, dynamic> out = <String, dynamic>{};
  decoded.forEach((String key, dynamic value) {
    if (value is String) {
      final String probe = caseInsensitive ? value.toLowerCase() : value;
      if (probe.startsWith(needle)) {
        out[key] = newRoot + value.substring(legacyRoot.length);
        changed = true;
        return;
      }
    }
    out[key] = value;
  });
  return changed ? jsonEncode(out) : null;
}

// 注：local_audio_dbs 等 support 内绝对路径无需搬迁后 rebase——
// LocalAudioManager.resolveInternalPath 对内部副本按文件名归一到当前库目录
// （跨机/跨目录安全），外部用户路径不在 app-support 根下，不受影响。

// ---------------------------------------------------------------------------
// macOS：旧 bundle id 的 NSUserDefaults 域里捞回「数据连续性锚点」
// ---------------------------------------------------------------------------
//
// Windows 的 prefs 是 app-support 根里的一个 JSON 文件，所以上面那次目录搬迁
// 顺手就把配置一起带走了。macOS 不是：`shared_preferences_foundation` 走
// `UserDefaults.standard`，域名 = bundle identifier。bundle id 一改，
// `~/Library/Preferences/com.example.hibiki.plist` 里的配置对新 app 就**完全
// 不可见**——而 `data_root`（用户自选的数据根绝对路径）正在里面。
//
// 后果分两种：
//  - 用默认位置的用户：丢了 `data_root` 也无所谓（本来就是 null），主库随
//    app-support 根一起搬过来了，`documents_layout` / `documents_container`
//    两个锚点会被 [AppPaths] 按磁盘现状重新判定 → 数据全在。
//  - **配置过自定义数据根的用户**：指针没了，app 退回默认根 = 一个空库，而真
//    数据原封不动躺在他选的盘上。这就是「原地消失」，必须捞回来。
//
// 捞法：只读旧域里那几个锚点键（`defaults read` 是只读操作，不写旧域），且**只
// 在新域尚未有该键时**写入——新值永远赢，重复启动幂等。

/// 需要从旧 NSUserDefaults 域捞回的锚点键（不含 `flutter.` 前缀；
/// `shared_preferences` 在 plist 里给每个键都加这个前缀）。
///
/// 刻意只收「丢了会让用户数据看不见」的三个键，不做整域搬运：整域搬运会把窗口
/// 尺寸、Anki 选择这类与身份耦合的旧状态一起带进来，风险远大于收益。
const List<String> kMacosContinuityPrefKeys = <String>[
  'data_root',
  'documents_layout',
  'documents_container',
];

/// `shared_preferences` 写进 NSUserDefaults / JSON 的键前缀。
const String kSharedPreferencesKeyPrefix = 'flutter.';

/// 纯函数：给定新域**已有**的键集合，算出还需要从旧域捞哪些锚点。
///
/// 抽出来是为了让「新域已有就不覆盖」这条不变式能被单测钉死，而不必在测试里
/// 起一个 NSUserDefaults。
List<String> missingMacosContinuityPrefKeys(Set<String> existingKeys) =>
    kMacosContinuityPrefKeys
        .where((String key) => !existingKeys.contains(key))
        .toList(growable: false);

/// 从旧域读一个键的字符串值。null = 没有 / 读不到（旧域不存在时 `defaults`
/// 以非 0 退出，属正常路径，不报错）。
typedef LegacyPrefReader = Future<String?> Function(String prefixedKey);

/// macOS：把 [kMacosContinuityPrefKeys] 里新域缺失的锚点从旧 bundle id 域捞回。
///
/// 返回真正写入的键数（0 = 无事发生）。非 macOS、旧域不存在、`defaults` 不可用
/// 都是 no-op —— 这条路径**只增不改**，任何一步失败都不影响启动。
///
/// [legacyReader] 仅供测试注入；生产走 `defaults read`（只读旧域）。
Future<int> recoverLegacyMacosPrefs({
  required Future<Set<String>> Function() existingKeys,
  required Future<void> Function(String key, String value) writeKey,
  LegacyPrefReader? legacyReader,
  bool? isMacOSOverride,
}) async {
  if (!(isMacOSOverride ?? Platform.isMacOS)) return 0;
  final LegacyPrefReader read = legacyReader ?? _defaultsReadLegacyDomain;
  int written = 0;
  try {
    final List<String> wanted = missingMacosContinuityPrefKeys(
      await existingKeys(),
    );
    for (final String key in wanted) {
      final String? value = await read('$kSharedPreferencesKeyPrefix$key');
      if (value == null || value.trim().isEmpty) continue;
      await writeKey(key, value);
      written++;
    }
  } catch (e) {
    debugPrint('[fushi-support-migration] macOS prefs recovery skipped: $e');
  }
  return written;
}

Future<String?> _defaultsReadLegacyDomain(String prefixedKey) async {
  try {
    final ProcessResult result = await Process.run(
      'defaults',
      <String>['read', kLegacyMacosBundleId, prefixedKey],
    );
    if (result.exitCode != 0) return null; // 旧域 / 旧键不存在。
    final String out = (result.stdout as String).trim();
    return out.isEmpty ? null : out;
  } catch (_) {
    return null;
  }
}

/// [recoverLegacyMacosPrefs] 的生产接线：读写走 `SharedPreferences`。
///
/// 必须在 [AppPaths.resolve] 之前调用（`data_root` 要在解析数据根之前就位），
/// 但可以在 app-support 根搬迁之后 —— macOS 的 prefs 不落在那个根里。
Future<int> recoverLegacyMacosPrefsFromSharedPreferences() async {
  return recoverLegacyMacosPrefs(
    existingKeys: () async {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      return prefs.getKeys();
    },
    writeKey: (String key, String value) async {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString(key, value);
    },
  );
}
