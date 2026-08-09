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

  static TagHostKind? tryParse(String raw) {
    for (final TagHostKind kind in TagHostKind.values) {
      if (kind.dbValue == raw) return kind;
    }
    return null;
  }
}
