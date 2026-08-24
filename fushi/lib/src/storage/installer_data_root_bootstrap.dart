import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi/src/storage/data_root_migrator.dart'
    show DataRootMigrationTarget, resolveDataRootMigrationTarget;

/// Windows 安装包在「数据存储位置」页收到的用户选择，落到 exe 同目录的这个一次性引导
/// 文件里（`windows/installer/fushi.iss` 的 `ssPostInstall` 写；文件名两侧由
/// `test/build/windows_installer_data_root_page_guard_test.dart` 守住一致）。
///
/// 内容：UTF-8（安装器写 BOM）、单行绝对目录路径。
const String installerDataRootBootstrapFileName = 'data_root.bootstrap';

/// 生产：引导文件恒在 exe 同目录（`{app}` = 安装目录，安装器就写在那里，app 用
/// [Platform.resolvedExecutable] 定位，不猜安装位置）。非 Windows 没有这个安装器 → null。
File? _productionBootstrapFile() {
  if (!Platform.isWindows) return null;
  return File(
    p.join(
      p.dirname(Platform.resolvedExecutable),
      installerDataRootBootstrapFileName,
    ),
  );
}

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
///  - 路径须为绝对路径，且不能是安装目录或其祖先（与 `validateDataRootTarget` 的
///    `containsExecutable` 同一条规则：自动更新/回滚会整体处理安装目录，数据不能压在下面）。
///  - 归一化与设置页迁移共用 [resolveDataRootMigrationTarget]：用户选中默认位置
///    （`<Documents>\Fushi` 或 `<Documents>\Fushi\data`）= 与全新安装同形 → **不写** pref，
///    DB 留在平台固定落点，而不是派生成 `<Documents>\Fushi\{documents,support}` 第三种布局。
///  - 目录建不出来 → 不写 pref，退回默认根并打日志（此时没有任何数据，不构成数据丢失；
///    用户可在设置里再选）。
///
/// [bootstrapFile] / [executablePath] 仅供测试注入；生产走 exe 同目录与
/// [Platform.resolvedExecutable]。
Future<void> consumeInstallerDataRootBootstrap({
  File? bootstrapFile,
  String? executablePath,
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

/// 剥 BOM、取第一个非空行、去首尾空白；没有有效行返回 null。
String? _readPickedPath(String raw) {
  // U+FEFF：Inno 的 SaveStringsToUTF8File 会写 BOM。
  final String bom = String.fromCharCode(0xFEFF);
  final String text = raw.startsWith(bom) ? raw.substring(bom.length) : raw;
  for (final String line in text.split(RegExp(r'\r?\n'))) {
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
  if (p.isWithin(canonPicked, p.canonicalize(executablePath))) {
    debugPrint('InstallerDataRootBootstrap: 路径包含安装目录，忽略: $picked');
    return;
  }

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

  final String dataRoot = target.dataRootPrefValue!;
  try {
    await Directory(dataRoot).create(recursive: true);
  } catch (e) {
    debugPrint('InstallerDataRootBootstrap: 建目录失败，退回默认根: $dataRoot: $e');
    return;
  }
  await prefs.setString(AppPaths.dataRootPrefKey, dataRoot);
  debugPrint('InstallerDataRootBootstrap: 采纳安装器数据根: $dataRoot');
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
