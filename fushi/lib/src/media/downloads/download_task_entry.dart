import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/media/media_search_text.dart';

/// Presentation metadata only. The source service remains the owner of actions.
enum DownloadTaskKind { video, novel, audiobook, game, manga }

enum DownloadTaskStatus {
  attention,
  active,
  queued,
  paused,
  completed,
  cancelled,
}

/// 一条任务支持的动作集合。
///
/// 槽位为 null 表示**该来源根本没有这个概念**，而不是「此刻不可用」——统一列表里
/// 四类任务的能力天然不齐：任务级优先级只有 video job 的持久化调度器有；
/// mokuro 与直链是单跑道内存队列，一次只跑一个、无调度器、连暂停态都不存在，
/// 所以既没有 [setPriority] 也没有 [resume]（它们的「续传」是 retry 走 Range，
/// 语义上是重跑而非恢复）。
///
/// 「打开所在位置」刻意**不在**本集合里：批量 reveal 会一次弹出 N 个文件管理器
/// 窗口，那是骚扰不是便利。它天生是单条动作，留在各来源的卡片上。
///
/// 批量操作按这些槽位过滤选中集：不支持某动作的条目原样跳过并计入结果报告，
/// 而不是让按钮凭空消失或整批失败。
class DownloadTaskActions {
  const DownloadTaskActions({
    this.pause,
    this.cancel,
    this.resume,
    this.retry,
    this.clear,
    this.delete,
    this.deletesFiles = false,
    this.deleteFilesRemovesLibraryEntries = false,
    this.setPriority,
  });

  /// 不支持任何动作（默认值）。
  static const DownloadTaskActions none = DownloadTaskActions();

  /// 暂停：**可恢复**地中止，已下载的数据留着，之后由 [resume] 原地接上。
  ///
  /// video job 侧的 `cancelJob` 就是这个语义（名为 cancel 实为 pause：它不删已
  /// 下载数据、底层调 pauseTorrent，且 `resumeJob` 只接受被它停下的任务；
  /// `cancelled` 是冻结的 DB 生命周期值，不追改）。
  final Future<void> Function()? pause;

  /// 取消：**不可恢复**地中止，之后只能靠 [retry] 重跑。
  /// 与 [pause] 是两种语义，不要合并——mokuro / 直链只有这一种。
  final Future<void> Function()? cancel;

  /// 从 [pause] 的暂停态原地恢复。Range 断点续传不算——那属于 [retry]。
  final Future<void> Function()? resume;

  /// 失败 / 已取消后重跑（多数来源即断点续传）。
  final Future<void> Function()? retry;

  /// 仅把条目移出列表，不动已落盘文件。
  final Future<void> Function()? clear;

  /// 删除任务；[deleteFiles] 为 true 时连带删除已落盘文件。
  /// 来源做不到连带删文件时不提供本槽位，只提供 [clear]——把「移出列表」伪装成
  /// 「删除」会让用户以为磁盘已经清干净了。
  final Future<void> Function({required bool deleteFiles})? delete;

  /// [delete] 这一次**真的能删掉磁盘文件**吗。
  ///
  /// 与「有没有 delete 槽位」是两回事：torrent 侧删数据只能由下载后端执行，后端
  /// 没配好时槽位仍在（计划行照样删得掉），但 deleteFiles 参数会被丢弃。UI 据此
  /// 决定要不要摆出「同时删除已下载文件」勾选框——兑现不了就不显示，否则用户勾了
  /// 以为盘清干净了，而几十 GB 还在，且再没有第二次机会发现。
  final bool deletesFiles;

  /// `delete(deleteFiles: true)` 会不会顺带把对应的媒体库条目（与封面）一起删掉。
  ///
  /// video job 的删文件走 `deletePersistedVideoDownloadJob`：文件删掉后它登记的
  /// 视频库行随之移除。确认框据此在勾选「同时删除文件」时多说一句，不让用户以为
  /// 只是腾了磁盘、库里的条目还在。
  final bool deleteFilesRemovesLibraryEntries;

  /// 设置任务级调度优先级（1 高 / 0 普通 / -1 低）。
  final Future<void> Function(int priority)? setPriority;
}

/// 一条任务所属作品的元数据身份（provider + externalId），只有来源本身记着
/// 作品身份时才有（video job 的 `metadataProvider` / `externalId`、旧番剧计划的
/// AniList id）。供 [DownloadTaskWorkFocus] 精确定位，不参与展示。
class DownloadTaskWorkIdentity {
  const DownloadTaskWorkIdentity({
    required this.provider,
    required this.externalId,
  });

  final String provider;
  final String externalId;

  /// 两段都非空才成立；任一为空返回 null（没有身份就只能按标题兜底）。
  static DownloadTaskWorkIdentity? maybe(String? provider, String? externalId) {
    final String p = provider?.trim() ?? '';
    final String id = externalId?.trim() ?? '';
    if (p.isEmpty || id.isEmpty) return null;
    return DownloadTaskWorkIdentity(provider: p, externalId: id);
  }
}

/// 「只看某部作品的下载任务」（发现详情页「任务」入口带过来的定位）。
///
/// 匹配口径：任务带 [DownloadTaskEntry.workIdentity] 时**只**按身份精确判定
/// （同名不同季 / 不同作品不会被标题误吸进来）；没有身份的来源（直链、扩展源、
/// 远端任务…）按标题兜底，与搜索框同一归一化口径。
///
/// 构造器刻意不是 const：每次跳转都是新对象，下载页按 identity 识别「新的一次
/// 定位」并据此重置自己的筛选。
class DownloadTaskWorkFocus {
  DownloadTaskWorkFocus({
    required this.title,
    required this.matchesIdentity,
    Iterable<String> titles = const <String>[],
  }) : titles = List<String>.unmodifiable(<String>{
         for (final String value in <String>[title, ...titles])
           if (value.trim().isNotEmpty) value.trim(),
       });

  /// 界面上提示「正在只看哪部」的名字。
  final String title;

  /// 标题兜底的全部候选（含 [title]、原名、别名）。
  final List<String> titles;

  /// 一个作品身份是不是这部作品（跨站 id 的对照由调用方决定）。
  final bool Function(DownloadTaskWorkIdentity identity) matchesIdentity;

  bool matches(DownloadTaskEntry task) {
    final DownloadTaskWorkIdentity? identity = task.workIdentity;
    if (identity != null) return matchesIdentity(identity);
    final List<String> haystack = <String>[
      task.title,
      if (task.collectionTitle != null) task.collectionTitle!,
      ...task.searchTerms,
    ];
    return titles.any(
      (String candidate) =>
          // 归一化后不足两个字符的别名（单字母简称等）会把半个列表都吸进来。
          normalizeMediaSearchText(candidate).length >= 2 &&
          matchesMediaSearch(query: candidate, titles: haystack),
    );
  }
}

class DownloadTaskEntry {
  const DownloadTaskEntry({
    required this.id,
    required this.title,
    required this.kind,
    required this.status,
    required this.builder,
    this.actions = DownloadTaskActions.none,
    this.createdAt,
    this.progress,
    this.collectionKey,
    this.collectionTitle,
    this.searchTerms = const <String>[],
    this.seeding = false,
    this.downRateBps,
    this.upRateBps,
    this.workIdentity,
  });

  /// 所属作品的元数据身份；来源不记身份时为 null（见 [DownloadTaskWorkIdentity]）。
  final DownloadTaskWorkIdentity? workIdentity;

  /// 本条任务支持的动作，由产生它的来源填充。
  final DownloadTaskActions actions;

  final String id;
  final String title;
  final DownloadTaskKind kind;
  final DownloadTaskStatus status;
  final int? createdAt;
  final double? progress;
  final String? collectionKey;
  final String? collectionTitle;
  final List<String> searchTerms;

  /// 已下完、正在做种（只有 torrent 来源报得出来）。[status] 仍是生命周期口径
  /// （完成 / 进行中），这一位只喂「做种」筛选与汇总，不改排序与批量语义。
  final bool seeding;

  /// 实时下载 / 上传速率（字节每秒）；来源报不出实时指标时为 null，汇总时不计。
  final int? downRateBps;
  final int? upRateBps;
  final WidgetBuilder builder;
}

typedef DownloadTasksBuilder =
    Widget Function(BuildContext context, List<DownloadTaskEntry> tasks);
