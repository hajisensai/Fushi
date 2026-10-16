import 'dart:io';

import 'package:path/path.dart' as p;

/// Device-local tutorial receipts survive a backup restore and pack cleanup.
/// They deliberately live outside both the restored database and pack directory.
class RecommendedPackTutorialState {
  RecommendedPackTutorialState(Directory appDirectory)
    : _directory = Directory(p.join(appDirectory.path, 'onboarding_tutorial'));

  final Directory _directory;

  File _marker(String name) => File(p.join(_directory.path, '$name.flag'));

  Future<bool> get shouldPrompt async =>
      await _marker('pending').exists() &&
      !await _marker('completed').exists() &&
      !await _marker('dismissed').exists();

  Future<void> _write(String name) async {
    await _directory.create(recursive: true);
    await _marker(name).writeAsString('1', flush: true);
  }

  /// 本安装是否在新手引导里成功导入过推荐包（[markImportSucceeded] 留下的回执，之后
  /// 不再删除）。复习「挖词目标」的出厂默认判定据此区分「推荐包带来的设置」与「老用户
  /// 自己的设置」（见 `PreferencesRepository.settleSrsMiningTargetInstallDefault`）。
  Future<bool> get hasImportReceipt => _marker('pending').exists();

  Future<void> markImportSucceeded() async {
    if (await _marker('completed').exists() ||
        await _marker('dismissed').exists()) {
      return;
    }
    await _write('pending');
  }

  /// An explicit dismissal is durable, including across another pack import.
  Future<void> dismissPrompt() => _write('dismissed');

  Future<void> markCompleted() => _write('completed');
}
