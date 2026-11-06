/// 标签宿主种类值域（v77 五张标签映射表合一后 [TagAssignments].mediaKind 的
/// 唯一真相源）。与合集/书架域的 `MediaKind` 刻意分开：那个域没有
/// `collection`（合集是容器不是媒体），跨域换算走显式映射（media_kind_mappings
/// 范式），禁 UI 层裸字符串比较。
enum TagHostKind {
  epub('epub'),
  srt('srt'),
  video('video'),
  collection('collection'),
  game('game');

  const TagHostKind(this.dbValue);

  /// 落库值（冻结；与 [MediaKind] 重叠的三个值同串同义）。
  final String dbValue;
}

/// 合集在 [TagAssignments].entryKey 里的编码（int id 字符串化）。编解码只许
/// 走这两个函数——散写 toString/int.tryParse 会让任何一处格式漂移把映射变成
/// 全体解码点静默丢弃的孤儿。
String collectionTagEntryKey(int collectionId) => collectionId.toString();

int? collectionIdOfTagEntryKey(String entryKey) => int.tryParse(entryKey);

/// 一个标签宿主的同步时钟：当前标签「名 → 加入毫秒戳」与移除墓碑「名 → 移除
/// 毫秒戳」（LWW-element-set 的两半，互联标签同步清单的载荷单位）。
typedef TagClockSet = ({Map<String, int> addedAt, Map<String, int> tombstones});

/// 一个宿主的「私密」标记时钟（[MediaPrivacyFlags] 一行；互联标签同步清单条目上的
/// `privacy` 载荷）。两只戳都为 null = 从没标过。
typedef MediaPrivacyClock = ({int? privateAt, int? clearedAt});

/// 私密 ⇔ 设为私密的戳比取消的戳新（相等取消胜，与标签墓碑同口径）。
bool isPrivateByClock(MediaPrivacyClock clock) {
  final int? set = clock.privateAt;
  if (set == null) return false;
  final int? cleared = clock.clearedAt;
  return cleared == null || set > cleared;
}

/// 两只私密时钟逐戳取大（LWW 合并；重放幂等、与顺序无关）。
MediaPrivacyClock mergePrivacyClocks(MediaPrivacyClock a, MediaPrivacyClock b) {
  int? maxOf(int? x, int? y) => x == null ? y : (y == null || x >= y ? x : y);
  return (
    privateAt: maxOf(a.privateAt, b.privateAt),
    clearedAt: maxOf(a.clearedAt, b.clearedAt),
  );
}
