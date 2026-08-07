import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Windows 改名（Fushi Phase 3）的 `%APPDATA%` 一次性搬迁。
///
/// `path_provider` 的 support 目录 = `%APPDATA%\<CompanyName>\<ProductName>`
/// （取自 exe 版本信息）。Runner.rc 把两者改成 `Fushi` 后，存量用户的
/// DB / SharedPreferences 还留在 `%APPDATA%\Hibiki\Hibiki`——不搬即等于丢库。
///
/// **必须在进程内第一次 `SharedPreferences.getInstance()` 之前调用**（插件会
/// 在新路径创建并缓存空 prefs，之后搬什么都晚了——数据根配置与 documents
/// 布局锚点都在里面）。[main] 在 `ensureInitialized` 后立刻调。
///
/// 幂等：新位置已有内容（已搬过 / 全新安装已落数据）或旧位置不存在时为 no-op。
/// 同盘 rename 原子且瞬时；跨盘或被占用时回退逐文件复制（复制成功不删旧目录，
/// 宁可留副本不可丢数据）。
Future<void> migrateWindowsLegacySupportDir() async {
  if (!Platform.isWindows) return;
  try {
    final Directory support = await getApplicationSupportDirectory();
    // …\AppData\Roaming\Fushi\Fushi → 旧位置 …\AppData\Roaming\Hibiki\Hibiki
    final String roaming = p.dirname(p.dirname(support.path));
    if (p.basename(support.path) != 'Fushi') return; // 非预期布局，不动。
    final Directory legacy = Directory(p.join(roaming, 'Hibiki', 'Hibiki'));
    if (!legacy.existsSync()) return;
    if (support.existsSync() &&
        support.listSync(followLinks: false).isNotEmpty) {
      return; // 新位置已有数据：已搬过或用户混用过，绝不覆盖。
    }
    final Directory newParent = Directory(p.dirname(support.path));
    newParent.createSync(recursive: true);
    if (support.existsSync()) support.deleteSync(); // 只删空壳。
    try {
      legacy.renameSync(support.path);
    } on FileSystemException {
      _copyTreeSync(legacy, Directory(support.path));
    }
  } catch (_) {
    // 搬迁失败不能挡启动：留在旧位置的数据不会被破坏，下次启动重试。
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

/// 搬迁后修复 Drift `preferences` 表里指向旧 support 目录的绝对路径
/// （`local_audio_dbs` 等）。开 DB 后由 AppModel 调一次；[oldPrefix] /
/// [newPrefix] 为 support 根新旧绝对路径。返回改写后的值，无命中返回 null。
String? rebaseSupportPathValue(
  String value, {
  required String oldPrefix,
  required String newPrefix,
}) {
  if (!value.contains(oldPrefix)) return null;
  return value.replaceAll(oldPrefix, newPrefix);
}
