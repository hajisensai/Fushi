/// 「把标签拖到一个媒体/合集上」的共享落库编排（书 / 字幕书 / 视频 / 合集共用）。
///
/// 与 `collection_drag.dart` 的 [addMediaRefToCollection] 是同一个范式的另一半：
/// 合集行头上并排挂着两个 `DragTarget`，落下 `MediaRef` 走那边，落下 [BookTagRow]
/// 走这边。那边早就把「查重 → 幂等提示 → 落库 → **失败提示**」收口了，这边却仍在
/// 五处各抄一遍，且**五处都没有 try/catch**。
library;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/utils.dart';

/// [addTagToTarget] 的结果：三种结局各自对应一条不同的用户可见提示。
enum TagAddOutcome {
  /// 真的写进去了。调用方据此刷新并报成功。
  added,

  /// 该目标本就有这个标签（`addTagToX` 幂等，静默 no-op 对用户就是「拖了没反应」）。
  /// 已提示，调用方不必刷新。
  alreadyPresent,

  /// 落库失败（DB 锁 / 磁盘满 / 外键异常……）。已提示，**没有**写进去。
  failed,
}

/// 提示通道。默认 [FushiToast.show]；测试注入自己的收集器。
///
/// 与 `CollectionAddNotifier` 不同，这里**带** [ToastSeverity]：本通道要送的
/// 「已存在」是 warning、「落库失败」是 error，而这两条语义上就该被用户一眼分开
/// （e-ink / 色觉障碍下靠图标区分，见 `toast_severity.dart`）。那边不带 severity
/// 是为了不打断既有注入式测试，是历史包袱而非更好的形状，不要照抄。
typedef TagAddNotifier = void Function(String message, ToastSeverity severity);

/// 把 [tag] 打到某个目标上：查重 → 幂等提示 → 落库 → 失败提示。
///
/// 本函数**永不抛出**：任何失败都归到 [TagAddOutcome.failed] 并给出明确提示。
/// 这正是它存在的理由——五个调用点原本都是
/// `await db.addTagToX(...)` 裸奔，又都以 unawaited Future 挂在 `onTagDropped`
/// 这个 `void` 回调上：写失败时异常直接漂进 zone，用户看到的只是「拖了没反应」。
/// 而「拖了没反应」在这里恰好又是**成功幂等**的样子，他会以为标签打上了，其实
/// 一个都没写进去——比单纯没反馈更糟。
///
/// [isAlreadyTagged] / [addToDb] 都可能碰 DB，所以一起收进 try 里；调用方拿到
/// [TagAddOutcome.added] 后再自己失效 provider + 报成功（与 [addMediaRefToCollection]
/// 同款分工：刷新要 `ref`、成功提示要 `mounted`，都属于 widget 层）。
Future<TagAddOutcome> addTagToTarget({
  required BookTagRow tag,
  required Future<bool> Function() isAlreadyTagged,
  required Future<void> Function() addToDb,
  required String alreadyTaggedMessage,
  TagAddNotifier? notify,
}) async {
  final TagAddNotifier tell = notify ??
      (String message, ToastSeverity severity) =>
          FushiToast.show(msg: message, severity: severity);
  try {
    if (await isAlreadyTagged()) {
      tell(alreadyTaggedMessage, ToastSeverity.warning);
      return TagAddOutcome.alreadyPresent;
    }
    await addToDb();
    return TagAddOutcome.added;
  } catch (error, stackTrace) {
    debugPrint('addTagToTarget failed: $error\n$stackTrace');
    tell(t.tag_add_failed, ToastSeverity.error);
    return TagAddOutcome.failed;
  }
}

/// 标签重排落库，返回是否真的写进去了；**永不抛出**。
///
/// 与 [addTagToTarget] 同一类缺陷的另一处：三个库页（书架 / 视频库 / 游戏库）各抄
/// 一份「重排 → 落库 → 失效 provider」，都没有 try/catch，也都挂在拖放的 `void`
/// 回调上。写失败时用户看到的是「松手后顺序自己弹回去了」，没有任何解释——他会
/// 反复重试同一个动作。成功路径**不**提示（顺序当场变了就是反馈），只有失败才说话。
Future<bool> reorderTagsSafely({
  required Future<void> Function() write,
  TagAddNotifier? notify,
}) async {
  try {
    await write();
    return true;
  } catch (error, stackTrace) {
    debugPrint('reorderTagsSafely failed: $error\n$stackTrace');
    (notify ??
        (String message, ToastSeverity severity) =>
            FushiToast.show(msg: message, severity: severity))(
      t.tag_reorder_failed,
      ToastSeverity.error,
    );
    return false;
  }
}
