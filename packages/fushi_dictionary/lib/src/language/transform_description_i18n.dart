/// 词形变化语法说明的界面语言本地化（BUG-2038）。
///
/// 说明原文来自 `assets/transforms/<lang>.json` 的 `description`——上游 Yomitan 的
/// 英文文案，经引擎随变形链一路走到弹窗标签上。这里既不改那份资产、也不碰引擎：
/// 只在**显示边界**把英文原文整段换成译文，查表的键就是英文原文本身。
///
/// 为什么用英文原文当键，而不是 `(语言, 变形名)` 二元组：
///  · 变形名跨语言会撞（`-s` 在 en 和 eo 里都有、含义完全不同），二元组键得让调用
///    方一路把「这是哪门语言的变形」带到显示层，凭空多一条上下文；
///  · 同一段英文说明本来就在多处复用（`-ちゃう` / `-ちまう` 共用一整段），按原文作
///    键天然合并，不必逐变形名重复抄同一份译文；
///  · 上游改了英文原文 → 查不到 → 原样回落英文。永远不会出现「英文换了意思、中文还
///    是老意思」的错译，代价只是暂时不翻译。漂移由守卫测试盯住。
///
/// **只在显示路径调用**。持久化路径（[buildLookupEntryExtra] 把变形链写进
/// `DictionaryEntry.extra`）必须原样保留英文：那份 extra 会被缓存并复用，写进译文
/// 就等于把「写入时的界面语言」腌进数据里，用户换语言后旧条目还是上一种语言。
class TransformDescriptionCatalog {
  const TransformDescriptionCatalog._();

  /// 英文原文 → 当前界面语言译文。空表 = 不翻译（英文界面，或该语言没有译文资产）。
  static Map<String, String> _translations = const <String, String>{};

  static String? _localeTag;

  /// 当前生效的译文语言标签（`zh-CN` 之类）；没装载译文时为 null。
  static String? get localeTag => _localeTag;

  /// 装载某个界面语言的译文表。再次调用直接整表替换（换界面语言即时生效，无需重启，
  /// 也不必重新初始化词典引擎——引擎里那份 JSON 始终是英文原文）。
  static void apply({
    required String localeTag,
    required Map<String, String> translations,
  }) {
    _localeTag = localeTag;
    _translations = Map<String, String>.unmodifiable(translations);
  }

  /// 卸载译文，回落英文原文（界面语言切到英文、或该语言没有译文资产时）。
  static void clear() {
    _localeTag = null;
    _translations = const <String, String>{};
  }

  /// 英文原文 → 译文；查不到原样返回。
  ///
  /// 幂等：译文自身不是表里的键，所以重复调用不会二次替换——这让「显示路径上多处
  /// 各调一次」是安全的，不必去证明某条链路只经过一次。
  static String localize(String description) {
    if (description.isEmpty || _translations.isEmpty) return description;
    return _translations[description] ?? description;
  }
}
