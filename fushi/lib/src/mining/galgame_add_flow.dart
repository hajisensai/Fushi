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
///
/// [onImported] 在**成功落库之后**回调，给「导入」视图跳转到游戏库用。用户报的
/// 症状是「导成功没反应我还以为失败了重试了好几次」：新游戏出现在**另一个**
/// section 里，停在导入页的屏幕上什么都不变，成功与失败在观感上完全一样。
Future<void> addGameViaFilePicker(
  GalgameRepository repo, {
  void Function()? onImported,
}) async {
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
  FushiToast.show(
    msg: t.game_drop_imported(count: 1),
    severity: ToastSeverity.success,
  );
  unawaited(_autoCoverSilently(repo, entry));
  onImported?.call();
}

/// 批量按路径添加游戏（拖放共用）：筛掉非 exe / 已在库的，落库，toast 汇报数量，
/// 逐条后台补封面。
///
/// 游戏库页的拖放与「导入」视图的拖放走同一条路——两处各写一份的话，只要有一处
/// 忘了 toast 或忘了补封面，用户就会在两个入口拿到不一样的行为。
Future<void> addGamesFromPaths(
  GalgameRepository repo,
  List<String> paths, {
  void Function()? onImported,
}) async {
  await repo.load();
  final List<String> exes = filterOutDuplicateGameExes(repo.games, paths);
  if (exes.isEmpty) {
    FushiToast.show(
      msg: t.game_drop_no_exe,
      severity: ToastSeverity.warning,
    );
    return;
  }
  // 批内 id 用「基准时刻 + 序号微秒」错开，避免同微秒撞 id。
  final DateTime base = DateTime.now();
  final List<GalgameEntry> added = <GalgameEntry>[
    for (int i = 0; i < exes.length; i++)
      newGalgameEntryFromExe(exes[i], now: base.add(Duration(microseconds: i))),
  ];
  await repo.addAll(added);
  FushiToast.show(
    msg: t.game_drop_imported(count: added.length),
    severity: ToastSeverity.success,
  );
  unawaited(_autoCoverAllSilently(repo, added));
  onImported?.call();
}

/// 批量补封面的并行度。每个 exe 图标抽取都是一个后台 isolate 把整个 exe 读进
/// 内存（上限 128 MB）；拖 30 个游戏进来就是 30 个 isolate 同时各抱一个 exe。
const int kGameCoverResolveConcurrency = 3;

/// [_autoCoverSilently] 的有界并行版：同时最多 [kGameCoverResolveConcurrency] 个，
/// 单条失败不影响其余（[_autoCoverSilently] 自身不抛）。
Future<void> _autoCoverAllSilently(
  GalgameRepository repo,
  List<GalgameEntry> games,
) async {
  int next = 0;
  Future<void> worker() async {
    while (next < games.length) {
      await _autoCoverSilently(repo, games[next++]);
    }
  }

  final int workers = games.length < kGameCoverResolveConcurrency
      ? games.length
      : kGameCoverResolveConcurrency;
  await Future.wait<void>(
    List<Future<void>>.generate(workers, (_) => worker()),
  );
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
