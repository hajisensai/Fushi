/// 远端视频「在同一播放会话里重载当前集」的次序（HBK-AUDIT-005）。
///
/// 换线路（断流故障转移）、手动换档、自适应换档、换版本都是同一件事：丢掉本次播放的
/// 流 → 上报停止（会 await 网络）→ 按发起时的位置重新取当前这一集。它们都是
/// fire-and-forget 的异步任务，期间用户可以换集 / 连播推进 / 再换一次档，页面的远端
/// 播放代际随之前进。
///
/// 此前各处只在第一个 await 之前查一次代际，停止上报回来后只查 `mounted`，就拿着旧集
/// 的毫秒位置去载**当时的**当前集，并抢走更新的加载序号：用户刚切到的新集被作废，换成
/// 旧集或「新集 + 旧集断点」。这里把重载绑定在发起时的会话 [generation] 上，每个异步
/// 边界之后都复核：会话已被别的加载接管就整程放弃，不再动播放器。
library;

/// 在第 [generation] 次远端播放会话里重载当前集。
///
/// - [currentGeneration]：页面此刻的远端播放代际；
/// - [isMounted]：页面是否还在；
/// - [release]：同步释放本次会话在服务端占的资源（不等结果，BUG-4461）；
/// - [reportStopped]：上报本次会话已停止（会 await）；
/// - [load]：重新载入当前集。必须在**第一个 await 之前**同步推进代际（页面的
///   `_loadRemoteEpisode` 第一句就是 `++_remotePlaybackGeneration`），这里据此认出
///   这一程自己的代际，判断它有没有被更新的加载接管。
///
/// 返回重载是否以本程收尾（页面还在、没有被更新的加载接管）。返回 false 时调用方不得
/// 弹「已切换」之类的提示，也不得把失败归到当前播放上。
Future<bool> reloadRemoteEpisodeInSession({
  required int generation,
  required int Function() currentGeneration,
  required bool Function() isMounted,
  required void Function() release,
  required Future<void> Function() reportStopped,
  required Future<void> Function() load,
}) async {
  if (!isMounted() || currentGeneration() != generation) return false;
  release();
  await reportStopped();
  if (!isMounted() || currentGeneration() != generation) return false;
  final Future<void> loading = load();
  final int reloadGeneration = currentGeneration();
  await loading;
  return isMounted() && currentGeneration() == reloadGeneration;
}
