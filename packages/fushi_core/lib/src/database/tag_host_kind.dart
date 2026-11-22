/// 标签宿主种类值域（v77 五张标签映射表合一后 [TagAssignments].mediaKind 的
/// 唯一真相源）。与合集/书架域的 `MediaKind` 刻意分开：那个域没有
/// `collection`（合集是容器不是媒体），跨域换算走显式映射（media_kind_mappings
/// 范式），禁 UI 层裸字符串比较。
enum TagHostKind {
  epub('epub'),
  srt('srt'),
  video('video'),
  collection('collection'),
  game('game'),

  /// 本地音乐专辑（`music_albums.album_uid`）。目前只当 NSFW 标记宿主（拍板台
  /// NCzkl6oLnf-adult-cover：DLsite 资料补的 R-18 主图要能被「模糊 NSFW 封面」管到），
  /// 不挂标签、不挂私密。
  musicAlbum('music_album');

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

/// 一个宿主的「NSFW」标记时钟（[MediaNsfwFlags] 一行；互联标签同步清单条目上的
/// `nsfw` 载荷）。两只戳都为 null = 从没标过。语义与 [MediaPrivacyClock] 相同。
typedef MediaNsfwClock = ({int? nsfwAt, int? clearedAt});

/// NSFW ⇔ 标 NSFW 的戳比取消的戳新（相等取消胜）。
bool isNsfwByClock(MediaNsfwClock clock) {
  final int? set = clock.nsfwAt;
  if (set == null) return false;
  final int? cleared = clock.clearedAt;
  return cleared == null || set > cleared;
}

/// 两只 NSFW 时钟逐戳取大（LWW 合并；重放幂等、与顺序无关）。
MediaNsfwClock mergeNsfwClocks(MediaNsfwClock a, MediaNsfwClock b) {
  int? maxOf(int? x, int? y) => x == null ? y : (y == null || x >= y ? x : y);
  return (
    nsfwAt: maxOf(a.nsfwAt, b.nsfwAt),
    clearedAt: maxOf(a.clearedAt, b.clearedAt),
  );
}

/// 两只私密时钟逐戳取大（LWW 合并；重放幂等、与顺序无关）。
MediaPrivacyClock mergePrivacyClocks(MediaPrivacyClock a, MediaPrivacyClock b) {
  int? maxOf(int? x, int? y) => x == null ? y : (y == null || x >= y ? x : y);
  return (
    privateAt: maxOf(a.privateAt, b.privateAt),
    clearedAt: maxOf(a.clearedAt, b.clearedAt),
  );
}

/// 一个宿主的「上锁」标记时钟（[MediaLockedFlags] 一行；互联标签同步清单条目上的
/// `locked` 载荷）。两只戳都为 null = 从没上过锁。语义与 [MediaPrivacyClock] 相同。
typedef MediaLockClock = ({int? lockedAt, int? clearedAt});

/// 上锁 ⇔ 上锁的戳比解除的戳新（相等解除胜）。
bool isLockedByClock(MediaLockClock clock) {
  final int? set = clock.lockedAt;
  if (set == null) return false;
  final int? cleared = clock.clearedAt;
  return cleared == null || set > cleared;
}

/// 解锁口令摘要的一份记录（[MediaLockCredentials] 那一行；互联标签清单顶层的
/// `lockCredential`）。[verifier] 为 null = 口令已删除。
typedef MediaLockCredential = ({String? verifier, int updatedAt});

/// 两份口令记录的 LWW 合并：[MediaLockCredential.updatedAt] 大的胜，相等时按
/// verifier 文本取大（null 视为空串），与顺序无关、重放幂等。
MediaLockCredential mergeLockCredentials(
  MediaLockCredential a,
  MediaLockCredential b,
) {
  if (a.updatedAt != b.updatedAt) return a.updatedAt > b.updatedAt ? a : b;
  return (a.verifier ?? '').compareTo(b.verifier ?? '') >= 0 ? a : b;
}

/// 两只上锁时钟逐戳取大（LWW 合并；重放幂等、与顺序无关）。
MediaLockClock mergeLockClocks(MediaLockClock a, MediaLockClock b) {
  int? maxOf(int? x, int? y) => x == null ? y : (y == null || x >= y ? x : y);
  return (
    lockedAt: maxOf(a.lockedAt, b.lockedAt),
    clearedAt: maxOf(a.clearedAt, b.clearedAt),
  );
}
