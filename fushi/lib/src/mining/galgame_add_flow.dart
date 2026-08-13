import 'dart:async' show unawaited;

import 'package:file_picker/file_picker.dart';

import 'package:fushi/src/mining/galgame_cover_resolver.dart';
import 'package:fushi/src/mining/galgame_library.dart';
import 'package:fushi/src/mining/galgame_repository.dart';
import 'package:fushi/utils.dart';

/// 「添加游戏」共用动作：文件选择器选一个 `.exe` → 查重 → 落库 → 后台补封面。
///
/// 两个消费方：游戏库页（独立使用时的 FAB / 空态兜底）与游戏「导入」视图的快速
/// 导入区。落库经 [GalgameRepository]（ChangeNotifier）广播，游戏库页监听仓储
/// 自动刷新，调用方无须再手动刷列表。
///
/// 封面补齐与库页 `_autoCover(silent: true)` 同语义：添加即返回（卡片先用占位
/// 图出现），目录封面图 / exe 图标解析在后台跑完回填，失败静默。
Future<void> addGameViaFilePicker(GalgameRepository repo) async {
  // 「导入」视图可能先于游戏库打开，仓储此刻未必载入过；查重需要全量列表。
  await repo.load();
  final FilePickerResult? picked = await FilePicker.platform.pickFiles(
    type: FileType.custom,
    allowedExtensions: <String>['exe'],
  );
  final String? exe = (picked != null && picked.files.isNotEmpty)
      ? picked.files.first.path
      : null;
  if (exe == null || exe.isEmpty) {
    return; // 用户取消
  }
  if (filterOutDuplicateGameExes(repo.games, <String>[exe]).isEmpty) {
    FushiToast.show(
      msg: t.game_already_added,
      severity: ToastSeverity.warning,
    );
    return; // 已在库里：不重复添加
  }
  final GalgameEntry entry = newGalgameEntryFromExe(exe);
  await repo.addAll(<GalgameEntry>[entry]);
  unawaited(_autoCoverSilently(repo, entry));
}

/// 后台补封面（静默版）：目录封面图 → exe 内嵌图标；期间条目被删则空操作。
Future<void> _autoCoverSilently(
  GalgameRepository repo,
  GalgameEntry game,
) async {
  final ResolvedGameCover? resolved = await autoResolveGameCover(
    gameId: game.id,
    gameName: game.displayName,
    exePath: game.exePath,
    workdir: game.workdir,
  );
  if (resolved == null) return;
  if (repo.byId(game.id) == null) return;
  await repo.setCoverPath(game.id, resolved.path);
}
