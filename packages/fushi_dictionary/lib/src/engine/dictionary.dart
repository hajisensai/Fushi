import 'dart:convert';

import '../language/language.dart';

enum DictionaryType { term, frequency, pitch, kanji }

/// 一本词典在某个语言下的折叠三态（BUG-2158）。
///
/// 为什么必须是三态而不是一个布尔：**「没有显式折叠」不等于「展开」**。它等于
/// 「按全局默认来」，而全局 `collapse_dictionaries` 默认是 true。修复前只有一个
/// `collapsedLanguages` 名单，两种意思被压成同一个状态，而设置页那个
/// unfold_more / unfold_less 按钮却把它呈现成双态开关——用户给自动展开窗口之外的
/// 词典点「展开」，模型里根本没有那个状态可写，于是视觉上毫无反应。
enum DictionaryCollapseState {
  /// 用户显式展开：压过自动展开窗口和全局折叠开关。
  expanded,

  /// 用户显式折叠：压过自动展开窗口。
  collapsed,

  /// 未表态：按自动展开窗口 + 全局折叠开关决定。
  inherit,
}

/// [Dictionary.metadata] 里记录「启动期类型自愈探测已经做过了」的键。
///
/// 为什么需要一个显式的键，而不是从 `hasKanji` 之类的结果反推：反推会把「没探测过」
/// 和「探测过、结果是什么都不用改」压成同一个状态（都表现为「没有标记」）。启动期
/// 的自愈逻辑于是只能对每一本**每次启动都重探一遍**——而 kanji 词典的探测是把整张
/// hash 表扫完、逐槽随机跳读 blobs.bin，纯 kanji 词典还永远触发不了「term+kanji 都
/// 找到」的提前退出条件，所以扫的是全表。手机冷缓存下这就是每本几万次随机页访问，
/// 词典一多，启动直接卡死在这里（用户报告：一次性导入很多词典后 app 打不开）。
///
/// 把「探测过」变成一等状态后，每本词典一生只探一次；导入路径更是连一次都不用探
/// （native 导入时已经数过 term/kanji 记录，结果直接写进来）。
///
/// 值是**探测器版本号**而不是 `'true'`：将来探测逻辑改了，只要 bump
/// [kDictTypeProbeVersion]，存量词典就会自动重探一轮，而不必再发明一个新键。
const String kDictTypeProbeKey = 'typeProbe';

/// 当前类型探测器的版本。改探测语义时 +1（见 [kDictTypeProbeKey]）。
const String kDictTypeProbeVersion = '1';


/// 改名投影：**真名 -> 显示名**，只含真正改过名的词典。
///
/// 全库唯一的推导处。消费方有五个（弹窗注入、悬浮窗、扩展下发、存储占用、
/// 以及浏览器扩展 CSS 载体的缓存判定），它们要的是同一张表——散开各写一遍就是
/// 五份逐字相同的推导，其中任何一份漏掉 trim 或漏掉空串判断，都会让某一个宿主
/// 的改名行为跟别处不一样。
///
/// 只装改过名的：消费方都要把它序列化进 JS 或存进 memo key，等值条目既占带宽
/// 又让指纹无谓地变。
///
/// 写成作用于 [Iterable] 的纯函数而不是挂在某个仓库上，是因为调用方拿到的词典
/// 列表来路不同（AppModel 的 getter 可被测试替身覆盖），绑死数据源会绕过那些
/// 覆盖点。
Map<String, String> dictionaryDisplayNameOverridesOf(
  Iterable<Dictionary> dictionaries,
) {
  return <String, String>{
    for (final Dictionary d in dictionaries)
      if (d.displayName != null && d.displayName!.trim().isNotEmpty)
        d.name: d.displayName!.trim(),
  };
}

class Dictionary {
  factory Dictionary.fromJson(String json) {
    final map = Map<String, dynamic>.from(jsonDecode(json));
    return Dictionary(
      name: map['name'] as String,
      formatKey: map['formatKey'] as String,
      order: map['order'] as int,
      type: DictionaryType.values.firstWhere(
        (e) => e.name == (map['type'] as String?),
        orElse: () => DictionaryType.term,
      ),
      metadata: Map<String, String>.from(
        jsonDecode(map['metadata'] as String? ?? '{}'),
      ),
      hiddenLanguages: List<String>.from(map['hiddenLanguages'] ?? []),
      collapsedLanguages: List<String>.from(map['collapsedLanguages'] ?? []),
      expandedLanguages: List<String>.from(map['expandedLanguages'] ?? []),
      languageOverride: map['languageOverride'] as String?,
      displayName: map['displayName'] as String?,
    );
  }
  Dictionary({
    required this.name,
    required this.formatKey,
    required this.order,
    this.type = DictionaryType.term,
    this.metadata = const {},
    this.hiddenLanguages = const [],
    this.collapsedLanguages = const [],
    this.expandedLanguages = const [],
    this.languageOverride,
    this.displayName,
  });

  final String name;
  final String formatKey;
  int order;
  final DictionaryType type;
  final Map<String, String> metadata;
  List<String> hiddenLanguages;

  /// 用户**显式折叠**这本词典的语言列表。与 [expandedLanguages] 互斥；两个都不含
  /// 某语言 = 该语言下走 [DictionaryCollapseState.inherit]。见 [collapseStateFor]。
  List<String> collapsedLanguages;

  /// 用户**显式展开**这本词典的语言列表（BUG-2158）。
  ///
  /// 修复前只有 [collapsedLanguages] 一个名单，于是「不在名单里」同时承担了
  /// 「展开」和「继承」两种意思——而全局默认是折叠，用户点「展开」等于什么都没做。
  List<String> expandedLanguages;

  /// 用户**手动指定**的词典内容语言（BCP-47，如 `ja` / `zh-Hant`）。null = 未指定。
  ///
  /// 与 [hiddenLanguages] / [collapsedLanguages] 同属「用户设置」：重导或在线更新
  /// 词典时由 `preservedSettings` 继承，不会被包内 index.json 冲掉。这与
  /// [sourceLanguage]（自动、随包刷新）是两个字段，不要合并。
  String? languageOverride;

  /// 用户给这本词典起的**显示名**（改名）。null / 空 = 没改过。
  ///
  /// 只影响给人看的地方。[name] 是真名，同时是主键、磁盘目录名、引擎装载
  /// 路径，以及 CSS map key / 样式规则 / `data-dictionary` 选择器 / 媒体 URL /
  /// Anki `{single-glossary-<名>}` token / 同步资产名的键——那些一律继续用
  /// [name]，改名不得波及（详见 `tables.dart` 该列注释）。
  ///
  /// 与 [languageOverride] 同属「用户设置」，重导/在线更新时走 `preservedSettings`
  /// 继承，不会被包内 index.json 冲掉。
  String? displayName;

  /// yomitan `index.json` 声明的**词头语言**（词典在解释哪种语言）。
  /// 导入时由 `readSourceMetadataFromIndex` 落进 [metadata]；旧词典/本地包缺则空串。
  String get sourceLanguage => metadata['sourceLanguage'] ?? '';

  /// yomitan `index.json` 声明的**释义语言**（词典用哪种语言解释）。
  ///
  /// 日中词典就是 `sourceLanguage: ja` + `targetLanguage: zh`——这正是「词头日文、
  /// 释义中文」这件事的结构性真值，不需要靠字符检测猜。
  String get targetLanguage => metadata['targetLanguage'] ?? '';

  /// 词头区（`.expression` / 振假名）实际该用的语言：用户指定优先，其次 index.json
  /// 的 sourceLanguage，都没有则 null（调用方不猜，见 `content_font_chain.dart`）。
  String? get effectiveSourceLanguage => _firstNonEmpty(
        <String?>[languageOverride, sourceLanguage],
      );

  /// 释义区实际该用的语言：用户指定优先（用户指定的是「这本词典是什么语言的」，
  /// 对单语词典而言词头和释义同语言），其次 index.json 的 targetLanguage。
  String? get effectiveTargetLanguage => _firstNonEmpty(
        <String?>[languageOverride, targetLanguage],
      );

  /// 该显示给用户看的名字：改过名用改的，否则用真名。**所有面向用户的词典名
  /// 渲染点都必须走这里**，而不是直接读 [name]。
  String get effectiveDisplayName =>
      _firstNonEmpty(<String?>[displayName]) ?? name;

  static String? _firstNonEmpty(List<String?> candidates) {
    for (final String? candidate in candidates) {
      final String trimmed = candidate?.trim() ?? '';
      if (trimmed.isNotEmpty) return trimmed;
    }
    return null;
  }

  /// 启动期类型自愈探测是否已经对这本词典做过（且是当前版本的探测器）。
  ///
  /// false = 需要探一次（老词典、或探测器版本 bump 后的存量）。见
  /// [kDictTypeProbeKey] 里关于「为什么不能从探测结果反推」的说明。
  bool get isTypeProbed => metadata[kDictTypeProbeKey] == kDictTypeProbeVersion;

  /// 在**已有词典对象**上换掉几个字段，其余原样带过。
  ///
  /// 存在的理由是防一类静默数据丢失：[Dictionary] 的构造器把用户设置列
  /// （[languageOverride] / [displayName]）设成可选默认 null，而
  /// `DictionaryRepository._dictionaryToCompanion` 对**每一列**都写
  /// `Value(...)`（不是 absent）——于是「new 一个 Dictionary 再 persist」的写法
  /// 只要漏填一个参数，就是往 DB 里显式写 NULL 把用户设置抹掉，且不报错。
  ///
  /// 类型自愈迁移就这么丢过（`AppModel._migrateDictionaryTypes` 两处只想换
  /// `type`，却把用户手动指定的内容语言和改名一起清了）。补参数治不了本——下一
  /// 列加进来时照样漏，所以那种写法一律改成 [copyWith]。
  Dictionary copyWith({
    DictionaryType? type,
    Map<String, String>? metadata,
    int? order,
  }) {
    return Dictionary(
      name: name,
      formatKey: formatKey,
      order: order ?? this.order,
      type: type ?? this.type,
      metadata: metadata ?? this.metadata,
      hiddenLanguages: hiddenLanguages,
      collapsedLanguages: collapsedLanguages,
      // develop 的 BUG-2158 新增列：漏了它，copyWith 会把「显式展开」名单清空。
      expandedLanguages: expandedLanguages,
      languageOverride: languageOverride,
      displayName: displayName,
    );
  }

  bool isHidden(Language language) {
    return hiddenLanguages.contains(language.languageCode);
  }

  /// 这本词典在 [language] 下的折叠三态（BUG-2158）。
  ///
  /// 「显式展开」排在「显式折叠」之前是**故意**的：两个名单本该互斥（由
  /// `DictionaryRepository.setDictionaryCollapseState` 这个唯一写入点维持），
  /// 但外部写入（同步落库、手改 DB、旧版本写的行）弄出重叠时，这里给出的是
  /// 确定的答案而不是未定义行为。
  DictionaryCollapseState collapseStateFor(Language language) =>
      collapseStateForCode(language.languageCode);

  /// 同 [collapseStateFor]，但直接吃语言码。持久化层与设置页手上只有码，没有
  /// [Language] 实例；让它们各自去造一个实例只会多一条能写错的路径。
  DictionaryCollapseState collapseStateForCode(String languageCode) {
    if (expandedLanguages.contains(languageCode)) {
      return DictionaryCollapseState.expanded;
    }
    if (collapsedLanguages.contains(languageCode)) {
      return DictionaryCollapseState.collapsed;
    }
    return DictionaryCollapseState.inherit;
  }

  /// 用户是否**显式折叠**了这本词典（不含「继承而恰好折叠」）。
  bool isCollapsed(Language language) {
    return collapseStateFor(language) == DictionaryCollapseState.collapsed;
  }

  /// 用户是否**显式展开**了这本词典（压过自动展开窗口与全局折叠开关）。
  bool isExplicitlyExpanded(Language language) {
    return collapseStateFor(language) == DictionaryCollapseState.expanded;
  }

  /// TODO-609：在线来源词典的版本号（yomitan index.json 的 revision），导入时
  /// 由 [readSourceMetadataFromIndex] 落进 [metadata]。本地/旧词典缺则空串。
  String get revision => metadata['revision'] ?? '';

  /// TODO-609：远端 index.json 的可访问 URL（yomidevs releases/latest 天然可更新）。
  String get indexUrl => metadata['indexUrl'] ?? '';

  /// TODO-609：词典包（zip）的下载 URL，更新时据此重新下载并强制重导。
  String get downloadUrl => metadata['downloadUrl'] ?? '';

  /// TODO-609：是否可在线检查更新（三条件与门）。必须 yomitan index 声明
  /// `isUpdatable` 且远端 index URL + 下载 URL 都存在，缺一不可——旧词典 / 本地
  /// 导入词典 metadata 为空 → 三条件全不满足 → false（不显示更新按钮、不崩）。
  bool get isUpdatable =>
      metadata['isUpdatable'] == 'true' &&
      indexUrl.isNotEmpty &&
      downloadUrl.isNotEmpty;

  String toJson() {
    return jsonEncode({
      'name': name,
      'formatKey': formatKey,
      'order': order,
      'type': type.name,
      'metadata': jsonEncode(metadata),
      'hiddenLanguages': hiddenLanguages,
      'collapsedLanguages': collapsedLanguages,
      'expandedLanguages': expandedLanguages,
      'languageOverride': languageOverride,
      'displayName': displayName,
    });
  }

  @override
  bool operator ==(Object other) => other is Dictionary && name == other.name;

  @override
  int get hashCode => name.hashCode;

  @override
  String toString() =>
      'Dictionary(name: $name, format: $formatKey, type: ${type.name})';
}
