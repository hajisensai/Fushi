import 'package:hibiki_core/hibiki_core.dart';

/// TODO-1166：内置默认书籍标签是 5 档星级评分（`1⭐`..`5⭐`）。
///
/// 名称是纯符号（星号 emoji + 数字），在所有语言下完全一致，因此**不走 i18n**
/// （否则要在 17 个语言文件里各塞 5 条完全相同的键，纯属噪声）。这里是这 5 个
/// 标签名的唯一真相源，播种与「一键补齐」入口都引用它。
const List<String> kBuiltInStarTagNames = <String>[
  '1⭐',
  '2⭐',
  '3⭐',
  '4⭐',
  '5⭐',
];

/// 与 [kBuiltInStarTagNames] 一一对应的颜色（Material amber 由浅到深，视觉上
/// 对应评分由低到高）。索引 i 的颜色配 `${i + 1}⭐`。
const List<int> kBuiltInStarTagColors = <int>[
  0xFFFFE082, // amber 200
  0xFFFFD54F, // amber 300
  0xFFFFCA28, // amber 400
  0xFFFFB300, // amber 600
  0xFFFF8F00, // amber 800
];

/// 幂等地把缺失的星级标签补入标签池，返回本次新增的数量。
///
/// **只增不删**：命中同名已存在标签就跳过（既不新建重复行，也不覆盖用户改过的
/// 颜色/排序），因此绝不会误删用户自建标签或其书籍映射。既用于新装首次播种
/// （空池时一次性种入全部 5 个），也用于老用户在标签管理页「一键补齐星级标签」。
Future<int> seedStarRatingTags(HibikiDatabase db) async {
  final List<BookTagRow> existing = await db.getAllTags();
  final Set<String> existingNames =
      existing.map((BookTagRow row) => row.name).toSet();
  int added = 0;
  for (int i = 0; i < kBuiltInStarTagNames.length; i++) {
    final String name = kBuiltInStarTagNames[i];
    if (existingNames.contains(name)) continue;
    await db.createTag(name, kBuiltInStarTagColors[i]);
    added++;
  }
  return added;
}
