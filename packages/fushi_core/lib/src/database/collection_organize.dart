/// 合集「由谁建 / 归谁管」与整理分组身份的纯值层（schema v124，AI 整理库 spec
/// `docs/specs/2026-10-20-ai-library-organize-design.md` §5 / §6 / §8）。
///
/// DB 列 [MediaCollections.origin] / `organizeKey` / `organizeAliases` 与同步清单
/// 同名字段都只经这里编码、比较，DAO、同步引擎、整理器不各写一份。
library;

import '../utils/media_title_fold.dart';
import '../utils/stable_hash.dart';

/// 合集来源。wire / DB 值固定为 [dbValue]。
enum CollectionOrigin {
  /// AI 整理建的。整理器可以继续改它（并入、合并、移出自己加的成员）。
  ai('ai', 0),

  /// 规则归组器（`BookSeriesGrouper` / `VideoFolderGroupCoordinator` 的系列模式）建的。
  rule('rule', 1),

  /// 目录自动合集（`sourceFolderPath` 非空）。整理器只把它当并入目标。
  folder('folder', 2),

  /// 用户建的，或用户编辑过的，或其它非整理器路径（下载、IPTV、刮削拆分…）建的。
  /// 整理器 / 导入器只可能直接往里**加**散条目；要移出它的成员、把它合并掉（收敛）
  /// 或改它的名字，一律记成待确认建议，等用户逐条「同意 / 这次不 / 永远不」
  /// （`library_organize_apply.dart`）。用户 2026-11-24 拍板取消原「永不移出 / 永不
  /// 并掉」的硬禁令：「用户的合集整理器永远不能往外移成员 取消这个设定吧，我觉得让
  /// 用户显式同意就行了吧，用户可以永远拒绝」。「永远不」= 钉住相关成员
  /// （`pinned_by_user`），随同步各端生效。
  user('user', 3);

  const CollectionOrigin(this.dbValue, this.rank);

  final String dbValue;

  /// 跨端合并秩：取大者胜。`ai` < `rule` < `folder` < `user`，用户一旦接手永不回退。
  final int rank;

  /// 整理器管着的合集（可被合并、可移出成员、参与收敛）。
  bool get isOrganizerManaged =>
      this == CollectionOrigin.ai || this == CollectionOrigin.rule;

  /// 认不出 / 缺失一律当 [user]：旧库、旧对端没有这一列时最安全的解读。
  static CollectionOrigin parse(String? raw) {
    for (final CollectionOrigin o in CollectionOrigin.values) {
      if (o.dbValue == raw) return o;
    }
    return CollectionOrigin.user;
  }

  /// 两端各自认为的来源合并：秩取大（交换、结合、幂等）。
  static CollectionOrigin merge(CollectionOrigin a, CollectionOrigin b) =>
      a.rank >= b.rank ? a : b;
}

/// [MediaCollections.organizeAliases] 的编码：换行分隔、字典序、去重、去空。
String encodeOrganizeAliases(Iterable<String> aliases) {
  final List<String> sorted = <String>{
    for (final String a in aliases)
      if (a.trim().isNotEmpty) a.trim(),
  }.toList()..sort();
  return sorted.join('\n');
}

/// [encodeOrganizeAliases] 的逆。
Set<String> decodeOrganizeAliases(String? raw) {
  if (raw == null || raw.isEmpty) return <String>{};
  return <String>{
    for (final String a in raw.split('\n'))
      if (a.trim().isNotEmpty) a.trim(),
  };
}

/// 媒体服务器剧名派生分组（BUG-5601）在 [MediaCollections.organizeAliases] 里的别名：
/// `series:<collectionType>:<剧名>`。
///
/// 懒收养下，媒体服务器的剧在用户第一次写它时才物化成真合集。物化时把**目录里的
/// 原剧名**记成真合集吸收过的分组键：之后用户改了名、移出了集，视频库的叠加仍按这个
/// 别名把同一部剧的集挂到这个真合集上（新集归进来，移出的集按它的成员墓碑判），不会
/// 以旧剧名另起一组；按原剧名物化（「加入媒体库」、下载落地）也落到它上面，不另建。
/// 别名列跨端按并集同步，所以重启、换设备后同样成立。
///
/// 与整理器的分组键同列而不冲突：整理键只有外部 id（`anilist:` 等）与标题键（`t:`）
/// 两种，`series:` 前缀不会撞上；别名永远不会被选成主键（[mergeOrganizeIdentity] 只从
/// 主键里挑），用户合集（`organizeKey` 为空）也不参与整理收敛。
String derivedSeriesOrganizeAlias(String name, String collectionType) =>
    'series:$collectionType:${name.trim()}';

/// [alias] 是不是 [derivedSeriesOrganizeAlias] 写的别名。
bool isDerivedSeriesOrganizeAlias(String alias) => alias.startsWith('series:');

/// 两端各自认为的分组键合并成一个（同一自然键两端键不同时）：取字典序最小者为
/// 主键，其余并进别名。外部 id 键（不以 `t:` 开头）优先于标题键——两端独立算出的
/// 外部 id 必然相同，标题键可能不同。返回 `(key, aliases)`。
({String? key, Set<String> aliases}) mergeOrganizeIdentity({
  required String? keyA,
  required Set<String> aliasesA,
  required String? keyB,
  required Set<String> aliasesB,
}) {
  final Set<String> keys = <String>{
    if (keyA != null && keyA.isNotEmpty) keyA,
    if (keyB != null && keyB.isNotEmpty) keyB,
  };
  final Set<String> aliases = <String>{...aliasesA, ...aliasesB};
  if (keys.isEmpty) return (key: null, aliases: aliases);
  final String key = pickCanonicalOrganizeKey(keys);
  return (key: key, aliases: <String>{...aliases, ...keys}..remove(key));
}

/// 一组分组键里的规范键：外部 id 键优先，同类取字典序最小。
String pickCanonicalOrganizeKey(Iterable<String> keys) {
  String? best;
  for (final String k in keys) {
    if (best == null || compareOrganizeKeys(k, best) < 0) best = k;
  }
  return best!;
}

/// 分组键全序：外部 id 键（非 `t:` 前缀）排在标题键前，同类字典序。
int compareOrganizeKeys(String a, String b) {
  final bool aTitle = isTitleOrganizeKey(a);
  final bool bTitle = isTitleOrganizeKey(b);
  if (aTitle != bTitle) return aTitle ? 1 : -1;
  return a.compareTo(b);
}

/// 标题键（`t:<domain>:<归一化原名>`）：AI 给的原语言正式名归一化而来，两端可能不同。
bool isTitleOrganizeKey(String key) => key.startsWith('t:');

/// 标题分组键：`t:<domain>:<foldMediaTitle(title)>`。[domain] 是
/// `CollectionShelfDomain.name`（books / manga / video / games）。规则归组器用系列名、
/// AI 整理用作品的原语言正式名算同一个键——日文作品两者一致时天然认成一个。
/// 折叠后为空（标题全是标点）返回 null。
String? titleOrganizeKey(String domain, String title) {
  final String folded = foldMediaTitle(title);
  if (folded.isEmpty) return null;
  return 't:$domain:$folded';
}

/// 同名但不同分组的整理器合集改用的名字：`<name> · <键的 4 位短哈希>`。只由
/// [name] 与 [organizeKey] 决定——持有同一分组的每台设备独立算出同一个名字，改名后
/// 仍按自然键对齐（spec §8.7：合集名是 wire 自然键，两个系列不能同名）。
String disambiguatedOrganizeName(String name, String organizeKey) =>
    '$name · ${fnv1a32Hex(organizeKey.codeUnits).substring(0, 4)}';
