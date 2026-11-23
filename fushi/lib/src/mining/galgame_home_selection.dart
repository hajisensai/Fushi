import 'package:fushi/src/media/privacy/media_visibility.dart';
import 'package:fushi/src/mining/gal_hook_session_controller.dart'
    show GalHookSessionState;
import 'package:fushi/src/mining/galgame_library.dart';
import 'package:fushi/src/mining/galgame_library_query.dart'
    show galgameHiddenByNsfwPref;

/// 游戏首页与侧栏游戏速览共用的「可见」与「继续」口径（纯函数）：速览展示的就是
/// 点进去的游戏首页首块那一套，不另算一份。

/// [g] 在游戏首页（及侧栏速览）可见：没被「隐藏成人向」偏好藏（与库页筛选同一
/// 判据 [galgameHiddenByNsfwPref]），也不是上锁（未解锁）的作品。
bool galgameShownOnHome(
  GalgameEntry g, {
  required bool hideNsfw,
  required MediaVisibility visibility,
}) =>
    !galgameHiddenByNsfwPref(g, hideNsfw: hideNsfw) &&
    !visibility.hidesGame(g.id);

/// 本机 Hook 会话正在跑的 exe；会话没在跑（或是 attach、没有 launch exe）为 null。
String? galHookRunningExe(GalHookSessionState? state) {
  final String? exe = state?.launchExe;
  if (state == null || !state.isActive || exe == null || exe.isEmpty) {
    return null;
  }
  return exe;
}

/// Windows 路径比较口径：分隔符统一、大小写不敏感。
String _exeKey(String path) => path.replaceAll('/', r'\').toLowerCase();

/// [visible] 里 exe 就是 [runningExe] 的那条（正在运行的游戏）；没有为 null。
GalgameEntry? galgameRunningEntry(
  Iterable<GalgameEntry> visible,
  String? runningExe,
) {
  if (runningExe == null || runningExe.isEmpty) return null;
  final String key = _exeKey(runningExe);
  for (final GalgameEntry g in visible) {
    if (g.exePath.isNotEmpty && _exeKey(g.exePath) == key) return g;
  }
  return null;
}

/// [visible] 里玩过的游戏，按最后游玩时刻倒序。
List<GalgameEntry> galgamePlayedByRecency(Iterable<GalgameEntry> visible) =>
    visible.where((GalgameEntry g) => g.lastPlayedMs > 0).toList()..sort(
      (GalgameEntry a, GalgameEntry b) =>
          b.lastPlayedMs.compareTo(a.lastPlayedMs),
    );

/// 游戏首页的「继续」：首块 = 正在运行的游戏（从没玩过也算），否则最近玩过的
/// 那个；其余 = 玩过的游戏去掉首块，按最近游玩倒序。都没有时首块为 null（首页
/// 再退到随机推荐，速览就不出「继续」）。
({GalgameEntry? hero, List<GalgameEntry> rest}) galgameHomeContinue(
  Iterable<GalgameEntry> visible, {
  required String? runningExe,
}) {
  final GalgameEntry? running = galgameRunningEntry(visible, runningExe);
  final List<GalgameEntry> played = galgamePlayedByRecency(visible);
  final GalgameEntry? hero = running ?? played.firstOrNull;
  return (
    hero: hero,
    rest: <GalgameEntry>[
      for (final GalgameEntry g in played)
        if (g.id != hero?.id) g,
    ],
  );
}
