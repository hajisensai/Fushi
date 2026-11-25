/// 本机 profile（集合）的绑定状态：这台设备上的这个 uid 是不是已经定下了「就是这个集合」。
///
/// 集合身份就是 `profiles.uid`（不拆分）。状态由内核持有（native/fushi_fsrs/src/store/binding.rs，`srs_meta` 键
/// `srs_collection_bound/<uid>`，命令 `binding_get` / `binding_set`），Dart 每次现读、不存镜像；删 / 换 uid 时
/// `profile_purge` 一并删掉。
///
/// - [SrsCollectionBindingState.provisional]：想先加入同步位置上已有的集合但没赶上（离线、超时、还没确认同步），
///   照常写入，之后由合并兜底；对关联判定没有约束。
/// - [SrsCollectionBindingState.settled]：已经在 [SrsCollectionBinding.via] 这个位置上跑完关联。之后在**别的**位置上
///   看到别的集合只交给用户选、不再自动采用（[srsDecideProfileLink] 的 `settled`），免得一台设备的几个位置各自判出
///   不同答案、来回改 uid。同一个位置上照常按规则收敛（两台都只有内置行的设备收敛到 uid 最小的那个）。
///
/// 没有记录 = 没绑定过（升级不迁移）。「有用户数据」本身就让关联不会自动采用（[SrsDbStore.hasUserData]），所以老用户
/// 不需要补写任何状态。
library;

/// 绑定状态。
enum SrsCollectionBindingState {
  provisional('provisional'),
  settled('settled');

  const SrsCollectionBindingState(this.wire);

  final String wire;

  static SrsCollectionBindingState? tryParse(Object? wire) {
    for (final SrsCollectionBindingState s in values) {
      if (s.wire == wire) return s;
    }
    return null;
  }
}

/// `via` 的保留值：从备份恢复时定下的（不对应任何同步位置）。
const String kSrsBindingViaBackup = 'backup';

/// 一条绑定状态（内核 `binding_get` 的 `binding`）。
class SrsCollectionBinding {
  const SrsCollectionBinding({
    required this.state,
    required this.via,
    required this.at,
  });

  final SrsCollectionBindingState state;

  /// 在哪定下 / 想在哪加入：同步位置的身份（directoryKey），或 [kSrsBindingViaBackup]。
  final String via;

  /// 写下的时刻（毫秒）。
  final int at;

  bool get settled => state == SrsCollectionBindingState.settled;

  /// 已经在 [directoryKey] 以外的地方定下了：在 [directoryKey] 上不再自动采用别的集合。[directoryKey] 为 null（调用方
  /// 不知道在哪个位置）时按「别处」算，保守。
  bool settledElsewhere(String? directoryKey) =>
      settled && (directoryKey == null || via != directoryKey);

  /// 解析内核返回的 `binding`（null / 认不出 = 没有记录）。
  static SrsCollectionBinding? fromJson(Object? json) {
    if (json is! Map) return null;
    final SrsCollectionBindingState? state = SrsCollectionBindingState.tryParse(
      json['state'],
    );
    if (state == null) return null;
    final Object? via = json['via'];
    final Object? at = json['at'];
    return SrsCollectionBinding(
      state: state,
      via: via is String ? via : '',
      at: at is int ? at : 0,
    );
  }

  @override
  String toString() =>
      'SrsCollectionBinding(${state.wire}, via: $via, at: $at)';
}
