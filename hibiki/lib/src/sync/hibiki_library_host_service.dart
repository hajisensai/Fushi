import 'dart:io';

/// host 实时词典的清单条目（不含 contentHash：Phase 1 按名 union，与现有暂存
/// 路径同语义，避免引入跨设备哈希一致性的新风险；overwrite-by-hash 列为 follow-up）。
class RemoteDictionaryInfo {
  const RemoteDictionaryInfo({required this.name, required this.type});
  final String name;
  final String type;

  Map<String, Object?> toJson() => <String, Object?>{'name': name, 'type': type};

  static RemoteDictionaryInfo fromJson(Map<String, Object?> json) =>
      RemoteDictionaryInfo(
        name: json['name']?.toString() ?? '',
        type: json['type']?.toString() ?? '',
      );
}

/// 按名 union 的 diff 结果。删除不在此处推断（交给 BUG-086 A 的删除传播）。
class DictionarySyncDiff {
  const DictionarySyncDiff({required this.toPull, required this.toPush});

  /// 对端有 ∧ 本端无 → 需要从对端拉取。
  final Set<String> toPull;

  /// 本端有 ∧ 对端无 → 需要推送到对端。
  final Set<String> toPush;
}

/// 按名 union 计算词典同步 diff。
///
/// [localNames]  本端已安装的词典名集合。
/// [remoteNames] 对端已安装的词典名集合。
DictionarySyncDiff computeDictionarySyncDiff({
  required Set<String> localNames,
  required Set<String> remoteNames,
}) {
  return DictionarySyncDiff(
    toPull: remoteNames.difference(localNames),
    toPush: localNames.difference(remoteNames),
  );
}

/// host 侧「库感知」服务：把 host 的实时库即时 export/import/delete/list。
/// 抽象不依赖 AppModel，便于测试用 fake 注入。所有实现里的库变动必须串行
/// （经 runExclusiveWithSync）——见 AppModelLibraryHostService（后续任务实现）。
abstract class HibikiLibraryHostService {
  /// host 当前实时词典清单（从 DictionaryMeta 表读，不是从任何暂存目录）。
  Future<List<RemoteDictionaryInfo>> listDictionaries();

  /// 即时把名为 [name] 的实时词典打包成 .hibikidict 临时文件，返回该文件。
  /// 调用方负责删除返回的临时文件（及其父临时目录）。词典不存在抛 [StateError]。
  Future<File> exportDictionary(String name);

  /// 把 [packageFile]（.hibikidict）导入 host 实时库（幂等：同名覆盖资源 + upsert 元数据）。
  Future<void> importDictionary(File packageFile);

  /// 从 host 实时库删除名为 [name] 的词典（DB 元数据 + 资源目录）。
  Future<void> deleteDictionary(String name);
}
