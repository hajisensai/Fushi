import 'package:fushi_core/fushi_core.dart' show ProfileMediaKind;

import 'package:fushi/src/profile/profile_repository.dart'
    show ComboEditorData, WorkComboTable;

/// 组合编辑页与作品「作品配置」要的编辑动作（拍板台 design-combo-node-split 阶段 6）。
///
/// 实现是 `ProfileViewModel`（动作都在配置变更锁里做）；两处界面只认这个窄接口、由调用方注入，
/// 不直接 import 视图模型——视图模型连着 AppModel，界面文件 import 它会被拉进最大 import 环
/// （`import_cycle_guard_test`）。
abstract interface class ComboEditing {
  /// 组合编辑页的数据（`ProfileRepository.loadComboEditor`）。
  Future<ComboEditorData?> loadComboEditor(int profileId);

  /// 「单独设置」节点 [nodeId]（叶子或子组），复制此刻的生效值。
  Future<void> splitComboNode(int profileId, String nodeId);

  /// 「恢复继承」节点 [nodeId]；[profileId] 是激活配置时重新应用。
  Future<void> restoreComboNode(int profileId, String nodeId);

  /// 「拆成独立复习库」。
  Future<void> splitComboSrsLibrary(int profileId);

  /// 切换激活配置（编辑页「切换到这个组合」再去设置里改值）。
  Future<void> switchProfile(int profileId);

  /// 作品的「最终生效值」表。
  Future<WorkComboTable> loadWorkComboTable({
    required String bookUid,
    String? languageTag,
    required ProfileMediaKind? mediaType,
  });

  /// 作品上直接「单独设置」节点 [nodeId]。
  Future<void> splitWorkNode({
    required String bookUid,
    String? languageTag,
    required ProfileMediaKind? mediaType,
    required String nodeId,
    required String anonymousName,
  });

  /// 作品上「恢复继承」节点 [nodeId]。
  Future<void> restoreWorkNode({
    required String bookUid,
    required String nodeId,
  });

  /// 作品上的匿名组合「存成组合」。
  Future<void> saveWorkComboAs({required String bookUid, required String name});
}
