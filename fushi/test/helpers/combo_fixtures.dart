import 'package:fushi/src/profile/combo/combo_repository.dart';
import 'package:fushi/src/profile/combo/fushi_settings_tree.dart';
import 'package:fushi/src/profile/profile_repository.dart';

/// 测试夹具：把此刻的 live 设置整份「冻结」进组合 [profileId]——每个可比较叶子都单独设置、
/// 值 = live（合成叶子不动）。
///
/// 组合迁移（拍板台 design-combo-node-split 阶段 3）之后，新建的配置是什么都没拆的组合，
/// 「切走时快照」只记与默认组合不同的叶子，往它的行里直接写一个没拆的叶子的键不生效。旧测试
/// 「先把 live 摆成某样、快照进一份配置、再把 live 摆回来」要的是一份独立于默认组合的配置：
/// 用它冻结后，默认组合怎么改都不影响这些值，再往它的行里写键（叶子都已拆开）照样生效。
Future<void> freezeLiveIntoCombo(ProfileRepository repo, int profileId) async {
  final Map<String, Map<SettingKey, String>> grouped = groupByLeaf(
    fushiSettingsTree,
    await repo.currentSettings(),
  );
  await repo.combos.saveDocument(
    profileId,
    ComboDocument(<String, Map<SettingKey, String>>{
      for (final SettingsNode leaf in fushiSettingsTree.leaves)
        if (leaf.diffable)
          leaf.id: grouped[leaf.id] ?? const <SettingKey, String>{},
    }),
  );
}
