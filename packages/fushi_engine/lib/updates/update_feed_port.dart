/// 更新提醒的**投递端口**：引擎侧只需要「投递一批事件」这一件事。
///
/// 为什么是端口而不是直接用 `UpdateFeedService`：那个服务绑 drift 数据库、
/// 偏好仓库与系统通知（都在 app 侧、都拖 Flutter），而下载管线已经住进
/// `fushi_engine`——引擎反向 import app 会把 Flutter 拖进无头服务端的 AOT
/// 编译（守卫 `fushi/test/build/fushi_engine_purity_guard_test.dart`）。
/// 所以纯数据与接口留在引擎，实现留在 app，依赖方向从 app → 引擎，单向。
library;

import 'package:fushi_engine/updates/update_feed_kind.dart';

/// 一条待投递的更新事件。域侧只需填这些，身份拼接与落库由实现负责。
class UpdateFeedDraft {
  const UpdateFeedDraft({
    required this.kind,
    required this.targetKey,
    required this.title,
    this.subtitle,
    this.detailJson,
  });

  final UpdateFeedKind kind;
  final String targetKey;
  final String title;
  final String? subtitle;
  final String? detailJson;

  String get entryId => updateFeedEntryId(kind, targetKey);
}

/// 投递端口。实现见 app 侧的 `UpdateFeedService`。
abstract interface class UpdateFeedPublisher {
  /// 投递一批同域事件。幂等由实现负责（重复投递同一 [UpdateFeedDraft.entryId]
  /// 不产生第二条）。
  Future<void> publishBatch(UpdateFeedKind kind, List<UpdateFeedDraft> drafts);
}
