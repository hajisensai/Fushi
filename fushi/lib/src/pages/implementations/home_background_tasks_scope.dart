/// 首页头像上的同步状态（设计稿 H3）：外壳把「后台任务」（同步 / 复习同步 / 补刮，
/// [BackgroundTask]）的数据源与明细入口往下广播，首页仪表盘的头像据此画外圈
/// ——有任务在跑时转着的分段进度环，有失败时右上角一枚红点。
///
/// 此前首页与别的 tab 一样在右下（MD3 手机叠在悬浮底栏 FAB 正上方）挂一颗
/// 「后台任务」FAB，首页内容本来就挤，这颗悬浮球正好盖在复习 / 统计卡上。首页
/// 有头像（页头主按钮位 / 浮动工具栏起始侧），状态挪进头像外圈后首页不再挂那颗
/// FAB（[homeBackgroundTasksOnAvatar]）；其余 tab 照旧。
library;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/models/home_tab.dart';
import 'package:fushi/src/sync/background_tasks_indicator.dart'
    show BackgroundTask, activeBackgroundTasks;

/// 外壳广播的「后台任务」数据源与入口。
class HomeBackgroundTasksScope extends InheritedWidget {
  const HomeBackgroundTasksScope({
    super.key,
    required this.listenable,
    required this.tasks,
    required this.onOpen,
    required super.child,
  });

  /// 任务变化时通知（与外壳 FAB / 明细弹层听的同一个）。
  final Listenable listenable;

  /// 此刻的任务（含已结束但有失败的那几轮）。
  final List<BackgroundTask> Function() tasks;

  /// 打开后台任务明细弹层。
  final VoidCallback onOpen;

  static HomeBackgroundTasksScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<HomeBackgroundTasksScope>();

  @override
  bool updateShouldNotify(HomeBackgroundTasksScope oldWidget) =>
      listenable != oldWidget.listenable ||
      tasks != oldWidget.tasks ||
      onOpen != oldWidget.onOpen;
}

/// 可见 tab 为 [visible] 时「后台任务」是否改由首页头像外圈承载（外壳因此不画
/// 右下 FAB）：只有首页（仪表盘有头像）。
bool homeBackgroundTasksOnAvatar(HomeTab visible) => visible == HomeTab.home;

/// 头像外圈该画的状态。
enum HomeAvatarSyncState {
  /// 没有任务在跑、也没有失败：只画头像。
  idle,

  /// 有任务在跑：外圈进度环。
  running,

  /// 有一轮记下了失败（在跑或已结束）：右上角红点（在跑时环照画）。
  failed,
}

/// [tasks] → 头像外圈状态。失败优先于在跑（红点要一直提醒到用户打开明细）。
HomeAvatarSyncState homeAvatarSyncStateOf(List<BackgroundTask> tasks) {
  if (tasks.any((BackgroundTask t) => t.errors.isNotEmpty)) {
    return HomeAvatarSyncState.failed;
  }
  return activeBackgroundTasks(tasks).isEmpty
      ? HomeAvatarSyncState.idle
      : HomeAvatarSyncState.running;
}
