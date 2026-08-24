import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi/src/storage/data_root_migrator.dart'
    show DataRootMigrationTarget, resolveDataRootMigrationTarget;
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// Windows 安装包在「数据存储位置」页收到的用户选择，落到 exe 同目录的这个一次性引导
/// 文件里（`windows/installer/fushi.iss` 的 `ssPostInstall` 写；文件名两侧由
/// `test/build/windows_installer_data_root_page_guard_test.dart` 守住一致）。
///
/// 内容：UTF-8 带 BOM（`SaveStringsToUTF8File` 恒写 BOM）、单行绝对目录路径。BOM 由
/// [_readPickedPath] 里的 `String.trim()` 剥掉（Dart 把 U+FEFF 当空白）——**不是** utf8
/// 解码器剥的，动 `trim()` 会把 BOM 留在路径首字符上。
const String installerDataRootBootstrapFileName = 'data_root.bootstrap';

/// 用户挑的目录可能在网络盘 / 移动盘上：所有触碰它的 IO 都封顶，与 [AppPaths] 的
/// `_probeDataRootExists` 同一纪律（启动最早期，绝不让一个掉线的盘挂住主 isolate）。
const Duration _pickedRootIoTimeout = Duration(seconds: 2);

/// 引导文件恒在 **exe 同目录**（`{app}` = 安装目录，安装器就写在那里；app 用
/// [Platform.resolvedExecutable] 定位，不猜安装位置）。非 Windows 没有这个安装器 → null。
///
/// 单独抽出来是因为「目录写错」与「文件名写错」后果完全等价——安装器写了没人读，且全程
/// 无声。文件名两侧由源码守卫钉住，这条目录腿由
/// `test/storage/installer_data_root_bootstrap_test.dart` 直接断言。
@visibleForTesting
File? bootstrapFileForExecutable(
  String executablePath, {
  required bool isWindows,
}) {
  if (!isWindows) return null;
  return File(
    p.join(p.dirname(executablePath), installerDataRootBootstrapFileName),
  );
}

/// 生产落点：[Platform.resolvedExecutable] 同目录。
File? _productionBootstrapFile() => bootstrapFileForExecutable(
  Platform.resolvedExecutable,
  isWindows: Platform.isWindows,
);

/// 进行中的消费。`AppModel.initialise` 的 Retry 可能在上一轮还没跑完（IO 超时被
/// `_guardInitIo` 抛出但底层 future 仍在）时再次进入；两轮各读一次文件、各写一次 pref
/// 就是两个数据根写者。同一进程内只允许一次消费在飞，后来者等它。
Future<void>? _inFlight;

/// 首启前消费安装包写下的数据根引导文件，把用户在安装向导里选的目录变成
/// [AppPaths.dataRootPrefKey]。必须在 [AppPaths.resolve] **之前**调用（数据根解析读的
/// 就是这个 pref），即 `AppModel._prepareRuntimeDirectories` 的第一步。
///
/// 契约（安装器是**一次性**写者，之后唯一真相源仍是 pref）：
///  - 文件不存在 → 无事。
///  - 文件一旦被读到，无论采纳与否都删除——绝不让安装器留下的路径在之后的启动里反复
///    生效（那会变成 pref 之外的第二个数据根写者）。唯一例外是 prefs 通道本身不可用：
///    没法写 pref 就没法消费，留到下次启动。
///  - **只对全新安装生效**：已有 `data_root` pref，或平台 support 根下已有主库
///    （[AppPaths.existingInstallHasDatabase]）→ 忽略。卸载后保留数据再重装、用户在向导里
///    另选了目录时，绝不能让旧书库从新根下「消失」；用户要搬走走设置里的迁移（连 DB 内
///    绝对路径一起 rebase）。
///  - 路径须为绝对路径，且与安装目录**不得相同或互相包含**（比设置页的
///    `containsExecutable` 更严：数据落在 `{app}` 之下会被卸载 / 自更新回滚一起处理）。
///  - 目标下已派生出**非空**的 `documents` / `support` 子树 → 拒绝（同设置页
///    `targetNotEmpty`）：把用户自己的 `D:\Downloads\documents` 当成 Fushi 私有树，
///    之后的整树迁移会连用户文件一起搬走 / 删掉。安装器侧同一位置用的是更严的
///    `DirExists`（**存在**即拒，不看空不空）：安装器不该为了判空去枚举用户目录，
///    严的一侧在前只会多问一次，不会放行本该拒绝的目录。
///  - 归一化与设置页迁移共用 [resolveDataRootMigrationTarget]：用户选中默认位置
///    （`<Documents>\Fushi` 或 `<Documents>\Fushi\data`）= 与全新安装同形 → **不写** pref，
///    DB 留在平台固定落点，而不是派生成 `<Documents>\Fushi\{documents,support}` 第三种布局。
///    归一化前先让 [AppPaths.ensureDocumentsContainerDecided] 定下容器名，与紧随其后的
///    `resolve()` 用同一个「默认位置」。
///  - 目录建不出来 / pref 写失败 → 不采纳，退回默认根并打日志（此时没有任何数据，不构成
///    数据丢失；用户可在设置里再选）。
///
/// [bootstrapFile] / [executablePath] 仅供测试注入；生产走 exe 同目录与
/// [Platform.resolvedExecutable]。
Future<void> consumeInstallerDataRootBootstrap({
  File? bootstrapFile,
  String? executablePath,
}) {
  final Future<void>? running = _inFlight;
  if (running != null) return running;
  late final Future<void> run;
  run =
      _consumeOnce(
        bootstrapFile: bootstrapFile,
        executablePath: executablePath,
      ).whenComplete(() {
        // 只清空「自己这一轮」：无条件置空会把后来者已经装进去的那一轮抹掉，等于放开互斥。
        // 与 AppModel._initInFlight 同一写法。
        if (identical(_inFlight, run)) _inFlight = null;
      });
  _inFlight = run;
  return run;
}

/// 测试用：清掉进行中的消费句柄。库级可变全局在 suite 之间会串味。
@visibleForTesting
void debugResetInstallerBootstrapInFlight() {
  _inFlight = null;
}

Future<void> _consumeOnce({
  required File? bootstrapFile,
  required String? executablePath,
}) async {
  final File? file = bootstrapFile ?? _productionBootstrapFile();
  if (file == null || !await file.exists()) return;

  final SharedPreferences prefs;
  try {
    prefs = await SharedPreferences.getInstance();
  } catch (e) {
    debugPrint('InstallerDataRootBootstrap: prefs 不可用，本次不消费: $e');
    return;
  }

  try {
    final String? picked = _readPickedPath(await file.readAsString());
    if (picked == null) {
      debugPrint('InstallerDataRootBootstrap: 引导文件为空，忽略');
      return;
    }
    await _applyPickedDataRoot(
      picked: picked,
      prefs: prefs,
      executablePath: executablePath ?? Platform.resolvedExecutable,
    );
  } catch (e, stack) {
    debugPrint('InstallerDataRootBootstrap: 消费失败，退回默认根: $e\n$stack');
  } finally {
    await _deleteQuietly(file);
  }
}

/// 取第一个非空行、去首尾空白；没有有效行返回 null。
String? _readPickedPath(String raw) {
  for (final String line in raw.split(RegExp(r'\r?\n'))) {
    final String trimmed = line.trim();
    if (trimmed.isNotEmpty) return trimmed;
  }
  return null;
}

Future<void> _applyPickedDataRoot({
  required String picked,
  required SharedPreferences prefs,
  required String executablePath,
}) async {
  final String? existing = prefs.getString(AppPaths.dataRootPrefKey);
  if (existing != null && existing.trim().isNotEmpty) {
    debugPrint('InstallerDataRootBootstrap: 已有 data_root 配置，忽略安装器选择');
    return;
  }
  if (await AppPaths.existingInstallHasDatabase()) {
    debugPrint('InstallerDataRootBootstrap: 本机已有数据库，忽略安装器选择（要搬走请走设置）');
    return;
  }
  if (!p.isAbsolute(picked)) {
    debugPrint('InstallerDataRootBootstrap: 非绝对路径，忽略: $picked');
    return;
  }
  final String canonPicked = p.canonicalize(picked);
  final String canonExeDir = p.canonicalize(p.dirname(executablePath));
  if (p.equals(canonPicked, canonExeDir) ||
      p.isWithin(canonPicked, canonExeDir) ||
      p.isWithin(canonExeDir, canonPicked)) {
    debugPrint('InstallerDataRootBootstrap: 与安装目录相同或互相包含，忽略: $picked');
    return;
  }

  await AppPaths.ensureDocumentsContainerDecided();
  final Directory defaultDocs = await AppPaths.defaultLocationDocumentsRoot();
  final Directory platformSupport = await getApplicationSupportDirectory();
  final DataRootMigrationTarget target = resolveDataRootMigrationTarget(
    pickedRoot: picked,
    defaultDocumentsRoot: defaultDocs.path,
    platformSupportRoot: platformSupport.path,
  );
  if (target.isDefaultLocation) {
    debugPrint('InstallerDataRootBootstrap: 选中默认位置，按全新安装布局');
    return;
  }
  if (await _hasFiles(target.documentsRoot) ||
      await _hasFiles(target.supportRoot)) {
    debugPrint(
      'InstallerDataRootBootstrap: 目标下已有非空 documents/support 子树，忽略: $picked',
    );
    return;
  }

  final String dataRoot = target.dataRootPrefValue!;
  try {
    await Directory(
      dataRoot,
    ).create(recursive: true).timeout(_pickedRootIoTimeout);
  } catch (e) {
    // release 的 GUI 进程里 debugPrint 落不到任何地方；这两条是真失败（用户选的目录
    // 被静默丢弃），必须进错误日志。ErrorLogService.init() 在 main.dart 里早于
    // AppModel.initialise()，此处一定已就绪。
    ErrorLogService.instance.log(
      'InstallerDataRootBootstrap',
      '建数据根目录失败，退回默认根: $dataRoot: $e',
    );
    return;
  }
  // shared_preferences_windows 写盘失败是返回 false 而非抛错；设置页的提交同样看这个
  // 布尔值（data_root.part.dart）。
  if (!await prefs.setString(AppPaths.dataRootPrefKey, dataRoot)) {
    ErrorLogService.instance.log(
      'InstallerDataRootBootstrap',
      '写 data_root 偏好失败，退回默认根: $dataRoot',
    );
    return;
  }
  debugPrint('InstallerDataRootBootstrap: 采纳安装器数据根: $dataRoot');
}

/// 目录存在且至少有一个条目。探测超时 / 抛错按「有内容」处理（保守：拿不准就不接管）。
/// 注意与安装器侧不同口径：`fushi.iss` 用 `DirExists` 只要**存在**就拒，这里要**非空**才拒。
Future<bool> _hasFiles(Directory dir) async {
  try {
    if (!await dir.exists().timeout(_pickedRootIoTimeout)) return false;
    return !await dir.list().isEmpty.timeout(_pickedRootIoTimeout);
  } catch (_) {
    return true;
  }
}

Future<void> _deleteQuietly(File file) async {
  try {
    await file.delete();
  } catch (e) {
    // 删不掉（安装目录只读等）：pref 已定 / DB 已建，下次启动的门控会再次忽略它，
    // 不会重复生效。
    debugPrint('InstallerDataRootBootstrap: 删除引导文件失败: $e');
  }
}
