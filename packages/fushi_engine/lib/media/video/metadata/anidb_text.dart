/// AniDB 文本与标签树的解码约定（HTTP anime XML、标题目录、UDP 应答共用）。
library;

import 'package:fushi_compute/fushi_compute.dart' show FfcXmlElement;

/// AniDB 全站把撇号存成反引号（`It`s MyGO!!!!!`、`Rāna`s`）：HTTP anime XML、
/// 每日标题目录与 UDP 应答都是这样下发的，原样进库就会在详情页显示
/// 「It`s」。所有给人看的 AniDB 文本（标题、简介、集名、人名、标签、相关作品名）
/// 落进 Fushi 前都经这一处换回 ASCII 撇号，和 TMDB / MAL / 文件名的写法一致。
String aniDbDisplayText(String raw) => raw.replaceAll('`', "'");

/// `<tags>` 是 AniDB 标签树按 id 平铺的结果：每个具体标签的全部祖先（`themes`、
/// `setting`、`elements`、`dynamic`、`time`、`place`、`cast`、`origin`、
/// `technical aspects` 这类分类节点，以及 `Earth` → `Asia` 这种中间层）都会一起
/// 下发，用 `parentid` 串成树。照单全收就是一串「dynamic · themes · setting ·
/// elements · time · place」。这里按结构只留叶子（被同文档里别的标签当 parent
/// 的一律是祖先，含义已由更具体的子标签表达），去掉剧透标签，再按 AniDB 权重
/// 从高到低排（同权重保持文档顺序），与 AniDB 页面的标签呈现一致。
List<String> aniDbLeafTagNames(Iterable<FfcXmlElement> tags) {
  final List<FfcXmlElement> all = tags.toList(growable: false);
  final Set<String> parentIds = <String>{
    for (final FfcXmlElement tag in all)
      if ((tag.getAttribute('parentid') ?? '').trim() case final String id
          when id.isNotEmpty)
        id,
  };
  final List<({String name, int weight, int order})> kept =
      <({String name, int weight, int order})>[];
  for (final FfcXmlElement tag in all) {
    final String id = (tag.getAttribute('id') ?? '').trim();
    if (id.isNotEmpty && parentIds.contains(id)) continue;
    if (_isTrue(tag.getAttribute('localspoiler')) ||
        _isTrue(tag.getAttribute('globalspoiler'))) {
      continue;
    }
    final String name = aniDbDisplayText(
      tag.getElement('name')?.innerText.trim() ?? '',
    );
    if (name.isEmpty) continue;
    kept.add((
      name: name,
      weight: int.tryParse((tag.getAttribute('weight') ?? '').trim()) ?? 0,
      order: kept.length,
    ));
  }
  kept.sort((
    ({String name, int weight, int order}) left,
    ({String name, int weight, int order}) right,
  ) {
    final int byWeight = right.weight.compareTo(left.weight);
    return byWeight != 0 ? byWeight : left.order.compareTo(right.order);
  });
  return <String>[
    for (final ({String name, int weight, int order}) tag in kept) tag.name,
  ];
}

bool _isTrue(String? value) => (value ?? '').trim().toLowerCase() == 'true';
