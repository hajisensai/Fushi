/// 假 Anki 的 `findNotes`：只实现媒体去重真正会发出的几种检索式。
///
/// - `deck:*`：全部笔记（建本地引用对照表）；
/// - `nid:1,2`：其中仍存在的笔记（确认读不到字段的笔记是否已被删）；
/// - 带引号的文件名项（`"a.mp3" OR "b.mp3"`），可选地由 `edited:N` /
///   `nid:...` 限定范围（删除前复核）。
///
/// 文本匹配与真 Anki 一样是**大小写不敏感的朴素子串**，不判文件名边界。
/// `edited:N` 的「最近改过」由调用方维护的 [edited] 集合表示（假服务在
/// `updateNoteFields` 时把 id 加进去）。认不出的检索式直接抛错，免得测试在
/// 一个被静默当成「零命中」的检索上假绿。
List<int> fakeAnkiFindNotes(
  String query,
  Map<int, Map<String, String>> notes, {
  Set<int> edited = const <int>{},
}) {
  final List<int> all = notes.keys.toList()..sort();
  if (query == 'deck:*') return all;
  final Set<int> nids = <int>{
    for (final RegExpMatch m in RegExp(r'nid:([\d,]+)').allMatches(query))
      ...m.group(1)!.split(',').map(int.parse),
  };
  final List<String> terms = <String>[
    for (final RegExpMatch m in RegExp(r'"([^"]*)"').allMatches(query))
      m.group(1)!.toLowerCase(),
  ];
  if (terms.isEmpty) {
    if (RegExp(r'^nid:[\d,]+$').hasMatch(query)) {
      return all.where(nids.contains).toList();
    }
    throw ArgumentError('fake Anki does not understand query: $query');
  }
  final bool scoped = query.contains('edited:');
  bool inScope(int id) => !scoped || edited.contains(id) || nids.contains(id);
  bool matches(int id) => notes[id]!.values.any((String v) {
    final String lower = v.toLowerCase();
    return terms.any(lower.contains);
  });
  return all.where((int id) => inScope(id) && matches(id)).toList();
}
