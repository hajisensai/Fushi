/// 一轮同步的**身份**与**结局** —— 补上 [SyncProgress] 覆盖不到的那些段落。
///
/// 根因：`syncInProgress` 是个裸 bool，`syncProgress` 只在编排器真正进入某个阶段
/// 后才有值。于是「同步在飞」这一个状态下混着三种完全不同的现实，UI 上却同形
/// （一条不确定进度条 + 零文字）：
///
/// 1. 跑的是合集 / 单本这两条**天生没有阶段结构**的轻量路径；
/// 2. 跑的是全量 sweep，但还停在第一个阶段 tick 之前的准备段（等互斥锁 → 读自动
///    同步开关 → 冷却判断 → `restoreAuth` / `isAuthenticated` 走网络）；
/// 3. 全量 sweep 进去了，但每条通道都没通过认证被 `continue` 跳过 —— 一个阶段都
///    没跑，什么也没同步，条子转一会儿就消失。
///
/// 第 3 种是纯粹的静默空转，跟 1、2 在界面上无法区分。修法不是给进度条加特例，
/// 而是补上缺失的那一层数据：每轮同步都必须先声明自己**是谁**（[SyncActivity]），
/// 结束时都必须留下**结局**（[SyncRunOutcome]）。
library;

/// 当前在飞的这轮同步是哪一种。
///
/// 保持成枚举（而不是预本地化的字符串）把 i18n 留在 widget 层，也让触发器可测。
enum SyncActivityKind {
  /// 全量双向 sweep：开机自动同步、手动「立即同步」、媒体页下拉。
  /// 只有这一种会上报 [SyncProgress] 阶段 tick，且仅在准备段之后。
  fullSweep,

  /// 合集变更防抖后触发的轻量同步（`SyncOrchestrator.runCollectionsOnly`）。
  /// 只含合集维度，没有阶段结构 —— 阶段进度对它永远是 null，这是设计如此。
  collections,

  /// 退出书 / 切后台触发的单本同步（`SyncManager.syncBook`）。
  /// 同样没有阶段结构。
  singleBook,
}

/// 在飞的那轮同步的身份。UI 在没有阶段 tick 可显示时退化到这一层。
class SyncActivity {
  const SyncActivity(this.kind, {this.title});

  final SyncActivityKind kind;

  /// 单本同步的书名（拿到书之前为 null）。其余种类不用。
  final String? title;

  /// 带上书名的副本 —— 单本同步在入口只有 mediaIdentifier，取到书之后才能补名。
  SyncActivity withTitle(String? title) =>
      SyncActivity(kind, title: title ?? this.title);

  @override
  bool operator ==(Object other) =>
      other is SyncActivity && other.kind == kind && other.title == title;

  @override
  int get hashCode => Object.hash(kind, title);
}

/// 一轮同步**为什么**结束。
///
/// 除 [completed] 外每一种都意味着「这轮什么也没同步」，而在补上这层之前它们全都
/// 静默收尾，用户只看到进度条消失。
enum SyncOutcomeReason {
  /// 至少一条通道通过认证并真的跑完了编排。
  completed,

  /// 通道全都没通过认证（没配后端 / 令牌失效 / 互联对端不可达）—— 空转。
  noChannels,

  /// 通道是通的，但本轮没有可同步的对象（单本路径上那本书已不在库里）。
  /// 与 [noChannels] 分开：一个是「连不上」，一个是「没东西可传」，混成一个词就是
  /// 让状态撒谎。
  nothingToSync,

  /// 自动同步开关关着（只可能出现在自动路径；手动同步显式绕过该开关）。
  autoDisabled,

  /// 距上次同步不足冷却窗口，本轮跳过（只可能出现在开机自动 sweep）。
  cooledDown,

  /// 抛异常收场。异常本身仍照旧进日志，这里只留「失败了」这个可见事实。
  failed,
}

/// 一轮同步的结局。设置页据此显示「上次同步」那行，非打断式。
class SyncRunOutcome {
  const SyncRunOutcome({
    required this.kind,
    required this.reason,
    required this.channelsRun,
    required this.finishedAt,
  });

  final SyncActivityKind kind;
  final SyncOutcomeReason reason;

  /// 本轮实际跑完编排的通道数（云备份 / 互联）。[SyncOutcomeReason.completed]
  /// 时必 > 0；其余种类为 0。
  final int channelsRun;

  /// 结束时刻，毫秒（命名遵循仓库约定：时刻列用 `<名>At`，无 `Ms` 后缀）。
  final int finishedAt;
}
